import Foundation

/// THE CONTROL-AXIS EVALUATOR — everything between a raw axis value and a
/// list of `(target, native value)` applications. Extracted from
/// `AppController` (which stays the owner/wiring layer: it feeds axes in
/// and applies the emitted batch through the unified parameter apply).
///
/// It owns three things:
///
///  * **the swing law and its binding snapshot** — every target reads
///    `rest + Σ swing_i`, clamped: the target's resting value (a
///    composite's `ParameterMapping.defaultValue`, a parameter's resting
///    store value) plus each bound curve's offset (`DimensionBinding.swing`).
///    Several axes on one target add instead of overwriting each other;
///    a one-way axis at zero input contributes its first edited offset.
///    The snapshot (`DimensionMapping` flattened per target,
///    the last curve-x per axis) lives under its own lock, so the link and
///    CoreMIDI threads never touch the `@Published` mapping;
///  * **the strike→acceleration blend** — the `.strike` / `.acceleration`
///    pair share ONE measurement and are evaluated JOINTLY (never through
///    `applyAxis`, which would double-apply): their contribution to a
///    target's sum is `(1−w)·swing_strike + w·swing_accel` with `w` from
///    `StrikeBlendWindow` (an unbound side swings 0), plus the 30 Hz
///    weight timer that keeps the ramp moving while the measurement is
///    still;
///  * **the `.fingerAccel` and `.touchSize` dimensions** — ONE
///    sounding-touch registry (two lanes: the wire and the local pump, so
///    their u16 id spaces cannot collide) carrying each touch's latest
///    pitch and fingertip radius; the NEWEST entry drives a
///    `FingerAccelTracker` and a `TouchSizeTracker`, each with its own
///    30 Hz tick (both laws need time steps between wire frames — one to
///    decay, one to ramp).
///
/// The timing laws themselves live in `StrikeBlendWindow`,
/// `FingerAccelTracker` and `TouchSizeTracker`; this type owns the
/// bookkeeping and the gating.
public final class ControlAxisEvaluator {

    /// The two touch id spaces feeding the finger registry. Only the WIRE
    /// lane anchors the strike blend's per-note windows (the strike byte
    /// is a wire measurement — the local pads have none).
    public enum TouchLane: Int {
        case wire = 0
        case local = 1
    }

    /// One evaluated application: a target and its value in native units.
    public typealias Application = (target: MapTarget, value: Double)

    // MARK: Axis indices (into `ControlAxes.dims`)

    public static let strikeAxisIndex =
        ControlAxes.dims.firstIndex(of: .strike)!
    public static let accelAxisIndex =
        ControlAxes.dims.firstIndex(of: .acceleration)!
    public static let fingerAxisIndex =
        ControlAxes.dims.firstIndex(of: .fingerAccel)!
    public static let fretPositionAxisIndex =
        ControlAxes.dims.firstIndex(of: .fretPosition)!
    /// TOUCH SIZE — UNIPOLAR 0…1, driven as `2·level − 1` like `.jcAccel`.
    public static let touchSizeAxisIndex =
        ControlAxes.dims.firstIndex(of: .touchSize)!
    /// Joy-Con Accel — UNIPOLAR 0…1, the caller maps it as `2·level − 1`.
    public static let jcAccelAxisIndex =
        ControlAxes.dims.firstIndex(of: .jcAccel)!

    // MARK: Sinks

    /// Where evaluated applications go (any thread). The owner drives the
    /// composites / parameters and funnels the rebuild-path values.
    public var onApply: ([Application]) -> Void = { _ in }

    /// A parameter target's RESTING value (the owner's store value, native
    /// units) — resolved on the caller's thread when the mapping is
    /// snapshotted; later changes arrive through `setParamRest`.
    public var paramRest: (String) -> Double = { _ in 0 }

    // MARK: Binding snapshot

    /// One target's bound curves: the plain axes by index, the strike pair
    /// apart (they blend), the rest the swings add to, and the clamp
    /// (the target's range widened to any endpoint drawn outside it).
    private struct TargetBindings {
        var rest: Double
        var bounds: ClosedRange<Double>
        var plain: [(axis: Int, binding: DimensionBinding)] = []
        var strike: DimensionBinding?
        var accel: DimensionBinding?
    }

    private let bindLock = NSLock()
    private var targets: [MapTarget: TargetBindings] = [:]
    /// The targets bound on each axis (strike pair axes included, for the
    /// blend's gating).
    private var axisTargets: [[MapTarget]] =
        Array(repeating: [], count: ControlAxes.dims.count)
    /// The last curve-x per axis — rest until the axis is first driven.
    private var axisX: [Double] = ControlAxes.dims.map(\.restX)
    /// Change gate per target (cleared on every mapping edit).
    private var lastOut: [MapTarget: Double] = [:]
    public enum TiltSource { case iPad, controller }
    private var controllerConnected = false
    private var iPadTilt = SIMD3<Double>.zero
    private var controllerTilt = SIMD3<Double>.zero

    /// Connection edges immediately select all three cached axes together.
    public func setControllerConnected(_ connected: Bool) {
        let (m, w) = strikeState()
        bindLock.lock()
        guard connected != controllerConnected else { bindLock.unlock(); return }
        controllerConnected = connected
        if !connected { controllerTilt = .zero }
        let apps = applySelectedTiltLocked(strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    /// Calibrations keep feeding independent caches while only the selected source plays.
    public func applyTilt(_ source: TiltSource, _ values: SIMD3<Double>) {
        let (m, w) = strikeState()
        bindLock.lock()
        switch source {
        case .iPad: iPadTilt = values
        case .controller: controllerTilt = values
        }
        let active = (source == .controller) == controllerConnected
        let apps = active ? applySelectedTiltLocked(strikeM: m, strikeW: w) : []
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    private func applySelectedTiltLocked(strikeM m: Measurements,
                                         strikeW w: Double) -> [Application] {
        let values = controllerConnected ? controllerTilt : iPadTilt
        var affected: Set<MapTarget> = []
        for axis in 0..<3 {
            axisX[axis] = (min(max(values[axis], -1), 1) + 1) / 2
            affected.formUnion(axisTargets[axis])
        }
        return changedLocked(affected, strikeM: m, strikeW: w)
    }

    // MARK: Strike blend state

    private let strikeLock = NSLock()
    private var strikeWindow = StrikeBlendWindow(windowS: 2.0)
    private var strikeMeasure = 0.0        // last wire value 0…1
    private var strikeTimer: DispatchSourceTimer?
    private var ipadSmoothing = AccelerationSmoother()
    private var joyConSmoothing = AccelerationSmoother()
    private let now: () -> TimeInterval
    private typealias Measurements = (strike: Double, accel: Double, joyCon: Double)

    // MARK: Finger-accel state

    private let fingerLock = NSLock()
    private var fingerTracker = FingerAccelTracker()
    private var fingerOrder: [Int] = []          // sounding keys, old→new
    private var fingerPitch: [Int: Double] = [:]
    private var fingerLast = 0.0
    private var fingerActive = false
    private var fingerTimer: DispatchSourceTimer?

    // MARK: Touch-size state (shares `fingerLock` + `fingerOrder`)

    private var sizeTracker = TouchSizeTracker()
    private var touchRadiusPt: [Int: Double] = [:]
    private var touchFretPositions: [Int: Double] = [:]
    private var sizeLast = 0.0
    private var sizeActive = false
    private var sizeTimer: DispatchSourceTimer?

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    deinit {
        strikeTimer?.cancel()
        fingerTimer?.cancel()
        sizeTimer?.cancel()
    }

    // MARK: - Bindings

    /// Re-snapshot the bindings per target (resolving each parameter
    /// target's rest through `paramRest` here, on the caller's thread), clear
    /// the change gate (an edit must re-apply) and re-arm the three auxiliary
    /// timers (blend weight, finger decay, touch-size estimate). Call on every
    /// mapping edit.
    public func setMapping(_ mapping: DimensionMapping) {
        var snapshot: [MapTarget: TargetBindings] = [:]
        var byAxis: [[MapTarget]] =
            Array(repeating: [], count: ControlAxes.dims.count)
        for target in mapping.boundTargets {
            let pm = mapping.mapping(for: target)
            let range = target.defaultRange
            var lo = min(range.0, range.1), hi = max(range.0, range.1)
            var tb = TargetBindings(
                rest: target.paramKey.map(paramRest) ?? pm.defaultValue,
                bounds: lo...hi)
            for (axis, dim) in ControlAxes.dims.enumerated() {
                guard let b = pm.binding(for: dim) else { continue }
                byAxis[axis].append(target)
                for pt in b.controlPoints {
                    lo = min(lo, pt.y); hi = max(hi, pt.y)
                }
                switch axis {
                case Self.strikeAxisIndex: tb.strike = b
                case Self.accelAxisIndex:  tb.accel = b
                default: tb.plain.append((axis, b))
                }
            }
            tb.bounds = lo...hi
            snapshot[target] = tb
        }
        bindLock.lock()
        targets = snapshot
        axisTargets = byAxis
        lastOut.removeAll()
        bindLock.unlock()
        // Strike/accel blend: run the weight timer only while the pair has
        // bindings.
        let strikeActive = !(byAxis[Self.strikeAxisIndex].isEmpty
                             && byAxis[Self.accelAxisIndex].isEmpty
                             && byAxis[Self.jcAccelAxisIndex].isEmpty)
        updateStrikeTimer(active: strikeActive)
        // Finger-accel: track/tick only while bound; a fresh binding starts
        // from a clean tracker.
        let fingerBound = !byAxis[Self.fingerAxisIndex].isEmpty
        fingerLock.lock()
        if fingerBound != fingerActive {
            fingerTracker.reset()
            fingerLast = 0
        }
        fingerActive = fingerBound
        fingerLock.unlock()
        updateFingerTimer(active: fingerBound)
        // Touch size: same gate — a fresh binding starts from a rested
        // ramp, and the tick runs while bound so the limiter keeps moving
        // between (and after) wire frames.
        let sizeBound = !byAxis[Self.touchSizeAxisIndex].isEmpty
        fingerLock.lock()
        if sizeBound != sizeActive {
            sizeTracker.reset()
            sizeLast = 0
        }
        sizeActive = sizeBound
        fingerLock.unlock()
        updateSizeTimer(active: sizeBound)
    }

    public func reapply() {
        // Edits must be audible even when a change-gated input is stationary.
        let (m, w) = strikeState()
        bindLock.lock()
        let apps = changedLocked(Array(targets.keys), strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    /// A parameter's resting store value changed (main, where the store is
    /// written): re-anchor its bindings' sum and re-evaluate.
    public func setParamRest(_ key: String, _ rest: Double) {
        let target = MapTarget(paramKey: key)
        let (m, w) = strikeState()
        bindLock.lock()
        guard targets[target] != nil else { bindLock.unlock(); return }
        targets[target]!.rest = rest
        // The owner's knob path has already applied the base to the voice.
        // Restore the combined value even if saturation kept it unchanged.
        lastOut.removeValue(forKey: target)
        let apps = changedLocked([target], strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    // MARK: - The swing law

    /// One target under `bindLock`: `rest + Σ swing(axis x)` over the plain
    /// bindings, plus the strike pair's blended swing, clamped.
    private func evaluateLocked(_ target: MapTarget, _ tb: TargetBindings,
                                strikeM m: Measurements, strikeW w: Double) -> Double {
        var v = tb.rest
        for (axis, b) in tb.plain {
            v += b.swing(atX: axis == Self.jcAccelAxisIndex ? m.joyCon : axisX[axis])
        }
        if tb.strike != nil || tb.accel != nil {
            let s = tb.strike?.swing(atX: m.strike) ?? 0.0
            let a = tb.accel?.swing(atX: m.accel) ?? 0.0
            v += (1.0 - w) * s + w * a
        }
        return min(max(v, tb.bounds.lowerBound), tb.bounds.upperBound)
    }

    /// Evaluate the given targets under `bindLock`, returning only those
    /// whose value moved (the per-target change gate).
    private func changedLocked<S: Sequence>(_ ts: S, strikeM m: Measurements,
                                            strikeW w: Double) -> [Application]
        where S.Element == MapTarget {
        var out: [Application] = []
        for t in ts {
            guard let tb = targets[t] else { continue }
            let v = evaluateLocked(t, tb, strikeM: m, strikeW: w)
            if let prev = lastOut[t], abs(prev - v) < 1e-9 { continue }
            lastOut[t] = v
            out.append((t, v))
        }
        return out
    }

    /// The strike pair's shared inputs: the measurement and the blend
    /// weight now.
    private func strikeState() -> (Measurements, Double) {
        strikeLock.lock()
        defer { strikeLock.unlock() }
        let t = now()
        return ((strikeMeasure, ipadSmoothing.value(at: t), joyConSmoothing.value(at: t)),
                strikeWindow.weight(at: t))
    }

    // MARK: - Axis drive

    private static let stickIndices = ControlAxes.stickDimensions.map {
        ControlAxes.dims.firstIndex(of: $0)!
    }

    /// Update all four directions before emitting, including when crossing the centre.
    public func applyStick(x: Double, y: Double) {
        let levels = [max(0, -x), max(0, x), max(0, y), max(0, -y)]
        let (m, w) = strikeState()
        bindLock.lock()
        var affected: [MapTarget] = []
        for (axis, level) in zip(Self.stickIndices, levels) {
            axisX[axis] = min(level, 1)
            for target in axisTargets[axis] where !affected.contains(target) {
                affected.append(target)
            }
        }
        let apps = changedLocked(affected, strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    /// Apply one control-axis value (−1…+1, rest 0 ↔ curve x 0…1): the
    /// axis' new x is stored and every target bound on it is re-summed in
    /// native units and emitted as one batch. The strike pair's axes are
    /// refused here (they blend through `evaluateStrikeBlend`). Off-main;
    /// downstream is thread-safe.
    public func applyAxis(_ axis: Int, _ value: Double) {
        guard axis >= 0, axis < ControlAxes.dims.count,
              axis != Self.strikeAxisIndex, axis != Self.accelAxisIndex
        else { return }
        if axis == Self.jcAccelAxisIndex {
            strikeLock.lock()
            joyConSmoothing.setInput((value + 1) / 2, at: now())
            strikeLock.unlock()
            evaluateStrikeBlend()
            return
        }
        let x = (value + 1) / 2                          // −1…+1 → curve 0…1
        let (m, w) = strikeState()
        bindLock.lock()
        axisX[axis] = x
        let apps = changedLocked(axisTargets[axis], strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    /// Uncalibrated iPad passthrough shares the same source selection and cache.
    public func applyRawArmAxis(_ axis: Int, _ value: Double) {
        guard (0..<3).contains(axis) else { return }
        let (m, w) = strikeState()
        bindLock.lock()
        iPadTilt[axis] = value
        let apps = controllerConnected ? [] : applySelectedTiltLocked(strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    // MARK: - The strike → acceleration pair

    /// The blend window length, `ctl_strike_window` (clamped ≥ 50 ms).
    /// Anchors survive the change — only the ramp length moves; the next
    /// evaluation re-applies whatever it changes.
    public func setStrikeWindow(_ seconds: Double) {
        strikeLock.lock()
        strikeWindow.windowS = max(seconds, 0.05)
        strikeLock.unlock()
    }

    public var strikeWindowS: Double {
        strikeLock.lock()
        defer { strikeLock.unlock() }
        return strikeWindow.windowS
    }

    /// The shared measurement (the PERF_STATE strike byte, 0…1), which
    /// immediately re-evaluates the pair.
    public func setStrikeMeasure(_ v: Double) {
        strikeLock.lock()
        strikeMeasure = v
        ipadSmoothing.setInput(v, at: now())
        strikeLock.unlock()
        evaluateStrikeBlend()
    }

    /// Re-sum every target bound on EITHER side of the pair with the
    /// current measurement and weight (the pair's swing is
    /// (1−w)·swing_strike + w·swing_accel, an unbound side 0). Change-gated
    /// per target. Link thread + blend timer.
    public func evaluateStrikeBlend() {
        let (m, w) = strikeState()
        bindLock.lock()
        var ts = axisTargets[Self.strikeAxisIndex]
        for t in axisTargets[Self.accelAxisIndex] + axisTargets[Self.jcAccelAxisIndex]
            where !ts.contains(t) {
            ts.append(t)
        }
        let apps = changedLocked(ts, strikeM: m, strikeW: w)
        bindLock.unlock()
        if !apps.isEmpty { onApply(apps) }
    }

    /// Mac-owned low-pass times; zero bypasses the additional smoothing exactly.
    public func setAccelerationSmoothing(_ dimension: InputDimension, milliseconds: Double) {
        guard milliseconds.isFinite else { return }
        strikeLock.lock()
        let t = now()
        if dimension == .acceleration {
            ipadSmoothing.setTime(milliseconds / 1000, at: t)
        } else if dimension == .jcAccel {
            joyConSmoothing.setTime(milliseconds / 1000, at: t)
        }
        strikeLock.unlock()
    }

    /// Disconnects clear the filter tail immediately.
    public func resetAcceleration(_ dimension: InputDimension) {
        strikeLock.lock()
        if dimension == .acceleration {
            strikeMeasure = 0
            ipadSmoothing.reset()
        } else if dimension == .jcAccel {
            joyConSmoothing.reset()
        }
        strikeLock.unlock()
        evaluateStrikeBlend()
    }

    private func updateStrikeTimer(active: Bool) {
        if active, strikeTimer == nil {
            let t = DispatchSource.makeTimerSource(
                queue: .global(qos: .userInitiated))
            t.schedule(deadline: .now(), repeating: 1.0 / 30.0,
                       leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.evaluateStrikeBlend() }
            t.resume()
            strikeTimer = t
        } else if !active, let t = strikeTimer {
            t.cancel()
            strikeTimer = nil
        }
    }

    // MARK: - Touch lifecycle (blend anchors + the finger registry)

    /// A note-on / note-off (or retrigger) on one lane. The WIRE lane also
    /// anchors the per-note blend window.
    public func touchGate(lane: TouchLane, id: UInt16, on: Bool) {
        if lane == .wire {
            let now = now()
            strikeLock.lock()
            if on { strikeWindow.noteOn(id, at: now) }
            else { strikeWindow.noteOff(id) }
            strikeLock.unlock()
        }
        let key = lane.rawValue << 16 | Int(id)
        fingerLock.lock()
        fingerOrder.removeAll { $0 == key }
        if on {
            fingerOrder.append(key)
        } else {
            fingerPitch[key] = nil
            touchRadiusPt[key] = nil
            touchFretPositions[key] = nil
        }
        fingerLock.unlock()
        fingerEvaluate()
        sizeEvaluate()
        if !on { fretPositionEvaluate() }
        if lane == .wire { evaluateStrikeBlend() }
    }

    /// A touch's latest pitch (fractional MIDI semitones).
    public func touchPitch(lane: TouchLane, id: UInt16, pitch: Double) {
        let key = lane.rawValue << 16 | Int(id)
        fingerLock.lock()
        fingerPitch[key] = pitch
        let isNewest = fingerOrder.last == key
        fingerLock.unlock()
        if isNewest { fingerEvaluate() }
    }

    /// A touch's latest FINGERTIP RADIUS in points (`UITouch.majorRadius`
    /// off the wire; 0 = unknown, the Mac pads have no touchscreen) — the
    /// `.touchSize` feed. Only the newest sounding touch drives the axis.
    public func touchRadius(lane: TouchLane, id: UInt16, radiusPt: Double) {
        let key = lane.rawValue << 16 | Int(id)
        fingerLock.lock()
        touchRadiusPt[key] = radiusPt
        let isNewest = fingerOrder.last == key
        fingerLock.unlock()
        if isNewest { sizeEvaluate() }
    }

    /// The newest held finger drives the unipolar fret-position axis.
    public func touchFretPosition(lane: TouchLane, id: UInt16, value: Double) {
        let key = lane.rawValue << 16 | Int(id)
        fingerLock.lock()
        touchFretPositions[key] = value.isFinite ? min(1, max(0, value)) : 0
        let isNewest = fingerOrder.last == key
        fingerLock.unlock()
        if isNewest { fretPositionEvaluate() }
    }

    private func fretPositionEvaluate() {
        fingerLock.lock()
        let value = fingerOrder.last.flatMap { touchFretPositions[$0] } ?? 0
        fingerLock.unlock()
        applyAxis(Self.fretPositionAxisIndex, value * 2 - 1)
    }

    /// Every touch currently DOWN with its latest finger pitch, oldest
    /// first — the finger's truth ABOVE the glide queue (parked fingers
    /// included).
    public func currentTouches() -> [(id: Int, pitchSemis: Double)] {
        fingerLock.lock()
        defer { fingerLock.unlock() }
        return fingerOrder.compactMap { k in fingerPitch[k].map { (k, $0) } }
    }

    /// Sample the tracker and drive the axis on change. Re-feeding the
    /// same pitch decays it, so the tick alone relaxes a rest finger to 0.
    private func fingerEvaluate() {
        fingerLock.lock()
        guard fingerActive else { fingerLock.unlock(); return }
        let newest = fingerOrder.last
        let v = fingerTracker.sample(
            id: newest, pitchSemis: newest.flatMap { fingerPitch[$0] },
            at: ProcessInfo.processInfo.systemUptime)
        let changed = abs(v - fingerLast) > 1e-3
        if changed { fingerLast = v }
        fingerLock.unlock()
        if changed { applyAxis(Self.fingerAxisIndex, v) }
    }

    private func updateFingerTimer(active: Bool) {
        if active, fingerTimer == nil {
            let t = DispatchSource.makeTimerSource(
                queue: .global(qos: .userInitiated))
            t.schedule(deadline: .now(), repeating: 1.0 / 30.0,
                       leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.fingerEvaluate() }
            t.resume()
            fingerTimer = t
        } else if !active, let t = fingerTimer {
            t.cancel()
            fingerTimer = nil
        }
    }

    /// Estimate the finger behind the newest sounding touch's quantised
    /// radius and drive the axis on change. No touch down = no finger, so
    /// the tick alone relaxes the axis back to rest.
    private func sizeEvaluate() {
        fingerLock.lock()
        guard sizeActive else { fingerLock.unlock(); return }
        let newest = fingerOrder.last
        let v = sizeTracker.sample(
            radiusPt: newest.flatMap { touchRadiusPt[$0] },
            at: ProcessInfo.processInfo.systemUptime)
        let changed = abs(v - sizeLast) > 1e-4
        if changed { sizeLast = v }
        fingerLock.unlock()
        // UNIPOLAR: 0…1 → the curve's own x through `applyAxis`'s
        // (value + 1) / 2 (the `.jcAccel` convention).
        if changed { applyAxis(Self.touchSizeAxisIndex, v * 2 - 1) }
    }

    private func updateSizeTimer(active: Bool) {
        if active, sizeTimer == nil {
            let t = DispatchSource.makeTimerSource(
                queue: .global(qos: .userInitiated))
            t.schedule(deadline: .now(), repeating: 1.0 / 30.0,
                       leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.sizeEvaluate() }
            t.resume()
            sizeTimer = t
        } else if !active, let t = sizeTimer {
            t.cancel()
            sizeTimer = nil
        }
    }
}
