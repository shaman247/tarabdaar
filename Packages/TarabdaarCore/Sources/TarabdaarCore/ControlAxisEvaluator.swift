import Foundation

/// THE CONTROL-AXIS EVALUATOR — everything between a raw axis value and a
/// list of `(target, native value)` applications. Extracted from
/// `AppController` (which stays the owner/wiring layer: it feeds axes in
/// and applies the emitted batch through the unified parameter apply).
///
/// It owns three things:
///
///  * **the per-axis binding snapshot** — `DimensionMapping` flattened to
///    `[axis][(target, binding)]` under its own lock, so the link and
///    CoreMIDI threads never touch the `@Published` mapping;
///  * **the strike→acceleration blend** — the `.strike` / `.acceleration`
///    pair share ONE measurement and are evaluated JOINTLY (never through
///    `applyAxis`, which would double-apply): per target
///    `(1−w)·strike + w·accel` with `w` from `StrikeBlendWindow`, plus the
///    30 Hz weight timer that keeps the ramp moving while the measurement
///    is still;
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
    /// TOUCH SIZE — UNIPOLAR 0…1, driven as `2·level − 1` like `.jcAccel`.
    public static let touchSizeAxisIndex =
        ControlAxes.dims.firstIndex(of: .touchSize)!
    /// THE JOY-CON WRIST AXES ↕/↔/⟲ (bipolar).
    public static let wristAxisIndices = (
        ControlAxes.dims.firstIndex(of: .tilt4)!,
        ControlAxes.dims.firstIndex(of: .wrist2)!,
        ControlAxes.dims.firstIndex(of: .wrist3)!)
    /// Joy-Con Accel — UNIPOLAR 0…1, the caller maps it as `2·level − 1`.
    public static let jcAccelAxisIndex =
        ControlAxes.dims.firstIndex(of: .jcAccel)!

    // MARK: Sinks

    /// Where evaluated applications go (any thread). The owner drives the
    /// composites / parameters and funnels the rebuild-path values.
    public var onApply: ([Application]) -> Void = { _ in }

    /// The registry default for a parameter target — what an UNBOUND side
    /// of the strike pair reads.
    public var paramDefault: (String) -> Double = { _ in 0 }

    // MARK: Binding snapshot

    private let bindLock = NSLock()
    private var byAxis: [[(target: MapTarget, binding: DimensionBinding)]] =
        Array(repeating: [], count: ControlAxes.dims.count)

    /// Last value per iPad wire axis (CoreMIDI thread only) — duplicate-drop
    /// for the uncalibrated passthrough.
    private var lastRawArmTilt: [Double?] = [nil, nil, nil]

    // MARK: Strike blend state

    private let strikeLock = NSLock()
    private var strikeWindow = StrikeBlendWindow(windowS: 2.0)
    private var strikeMeasure = 0.0        // last wire value 0…1
    private var lastBlendOut: [MapTarget: Double] = [:]
    private var strikeTimer: DispatchSourceTimer?

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
    private var sizeLast = 0.0
    private var sizeActive = false
    private var sizeTimer: DispatchSourceTimer?

    public init() {}

    deinit {
        strikeTimer?.cancel()
        fingerTimer?.cancel()
        sizeTimer?.cancel()
    }

    // MARK: - Bindings

    /// Re-snapshot the per-axis bindings and re-arm the three auxiliary
    /// timers (blend weight, finger decay, touch-size estimate). Call on every
    /// mapping edit.
    public func setMapping(_ mapping: DimensionMapping) {
        var snapshot: [[(target: MapTarget, binding: DimensionBinding)]] =
            Array(repeating: [], count: ControlAxes.dims.count)
        for target in mapping.boundTargets {
            for (axis, dim) in ControlAxes.dims.enumerated() {
                if let b = mapping.mapping(for: target).binding(for: dim) {
                    snapshot[axis].append((target, b))
                }
            }
        }
        bindLock.lock()
        byAxis = snapshot
        bindLock.unlock()
        // Strike/accel blend: clear the change gate (an edit must re-apply)
        // and run the weight timer only while the pair has bindings.
        let strikeActive = !(snapshot[Self.strikeAxisIndex].isEmpty
                             && snapshot[Self.accelAxisIndex].isEmpty)
        strikeLock.lock()
        lastBlendOut.removeAll()
        strikeLock.unlock()
        updateStrikeTimer(active: strikeActive)
        // Finger-accel: track/tick only while bound; a fresh binding starts
        // from a clean tracker.
        let fingerBound = !snapshot[Self.fingerAxisIndex].isEmpty
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
        let sizeBound = !snapshot[Self.touchSizeAxisIndex].isEmpty
        fingerLock.lock()
        if sizeBound != sizeActive {
            sizeTracker.reset()
            sizeLast = 0
        }
        sizeActive = sizeBound
        fingerLock.unlock()
        updateSizeTimer(active: sizeBound)
    }

    /// The bindings snapshotted for one axis (test/introspection).
    public func bindings(forAxis axis: Int)
        -> [(target: MapTarget, binding: DimensionBinding)] {
        guard axis >= 0, axis < ControlAxes.dims.count else { return [] }
        bindLock.lock()
        defer { bindLock.unlock() }
        return byAxis[axis]
    }

    // MARK: - Axis drive

    /// Apply one control-axis value (−1…+1, rest 0 ↔ curve x 0…1): every
    /// bound target is evaluated in native units and emitted as one batch.
    /// Off-main; downstream is thread-safe.
    public func applyAxis(_ axis: Int, _ value: Double) {
        guard axis >= 0, axis < ControlAxes.dims.count else { return }
        bindLock.lock()
        let bindings = byAxis[axis]
        bindLock.unlock()
        let curveX = (value + 1) / 2                     // −1…+1 → curve 0…1
        onApply(bindings.map { ($0.target, $0.binding.evaluate(curveX)) })
    }

    /// The iPad's raw (uncalibrated) arm axes 0–2, duplicate-dropped.
    /// CoreMIDI thread only, like the value it drops against.
    public func applyRawArmAxis(_ axis: Int, _ value: Double) {
        guard axis >= 0, axis < lastRawArmTilt.count,
              lastRawArmTilt[axis] != value else { return }
        lastRawArmTilt[axis] = value
        applyAxis(axis, value)
    }

    // MARK: - The strike → acceleration pair

    /// The blend window length, `ctl_strike_window` (clamped ≥ 50 ms).
    /// Anchors survive the change — only the ramp length moves — and the
    /// change gate is cleared so the next evaluation re-applies.
    public func setStrikeWindow(_ seconds: Double) {
        strikeLock.lock()
        strikeWindow.windowS = max(seconds, 0.05)
        lastBlendOut.removeAll()
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
        strikeLock.unlock()
        evaluateStrikeBlend()
    }

    /// Evaluate the pair: for every target bound on EITHER dimension,
    /// (1−w)·strikeOut + w·accelOut, an unbound side reading the target's
    /// DEFAULT. Change-gated per target. Link thread + blend timer.
    public func evaluateStrikeBlend() {
        bindLock.lock()
        let sBind = byAxis[Self.strikeAxisIndex]
        let aBind = byAxis[Self.accelAxisIndex]
        bindLock.unlock()
        guard !sBind.isEmpty || !aBind.isEmpty else { return }
        var sBy: [MapTarget: DimensionBinding] = [:]
        for (t, b) in sBind { sBy[t] = b }
        var aBy: [MapTarget: DimensionBinding] = [:]
        for (t, b) in aBind { aBy[t] = b }
        func defaultOut(_ t: MapTarget) -> Double {
            switch t.kind {
            case .composite: return 0.0    // composite rest convention
            case .param(let key): return paramDefault(key)
            }
        }
        strikeLock.lock()
        let m = strikeMeasure
        let w = strikeWindow.weight(at: ProcessInfo.processInfo.systemUptime)
        var changed: [Application] = []
        for target in Set(sBy.keys).union(aBy.keys) {
            let s = sBy[target].map { $0.evaluate(m) } ?? defaultOut(target)
            let a = aBy[target].map { $0.evaluate(m) } ?? defaultOut(target)
            let v = (1.0 - w) * s + w * a
            if let prev = lastBlendOut[target], abs(prev - v) < 1e-9 {
                continue
            }
            lastBlendOut[target] = v
            changed.append((target, v))
        }
        strikeLock.unlock()
        guard !changed.isEmpty else { return }
        onApply(changed)
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
            let now = ProcessInfo.processInfo.systemUptime
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
        }
        fingerLock.unlock()
        fingerEvaluate()
        sizeEvaluate()
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
