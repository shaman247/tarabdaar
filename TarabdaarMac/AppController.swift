import AppKit
import Combine
import CoreAudioKit
import Foundation
import SarangiKit
import TarabdaarCore

/// Mac-side wiring: owns every Mac-side knob (voice physics, tarab table,
/// Fret Pad layout, composites, bindings), evaluates every control axis,
/// and pushes settings into `AudioEngine`. The iPad streams TLP frames in
/// (`MIDIInput` → `TarabLink` → `LinkIngest` → `AudioEngine`); the Mac
/// pushes back the scale + layout (`startScaleSync`) and JOYCON_STATE.

final class AppController: ObservableObject {
    let audio: AudioEngine
    let midi: MIDIEngine
    let midiIn: MIDIInput
    /// The TarabLink host end: `midiIn` reassembles inbound TLP SysEx,
    /// `midi` sends outbound (wired-first); frames diff through `ingest`.
    let link = TarabLink(role: .host)
    let ingest: LinkIngest

    /// Headless iPad simulator behind the audition pipeline. Owns its own
    /// `NoteManager` + `MockMotionSource`.
    let simulator: IPadSimulator
    let audition: AuditionRunner
    /// Joy-Con / game-controller input, wired in `start()` into the same
    /// funnels the iPad drives (control axes, drone buttons, strum).
    let joyCon = JoyConInput()
    /// The shared scale/tonic model — the Fret Pad reads from it; the
    /// keyboard player and the strum play through it.
    let pitchPad: PitchPadEngine
    /// The Fret Pad engine — the sole playing surface (fret segments whose
    /// x-position is their pitch, onset-only snapping).
    let fretPad: PitchPadEngine
    /// Computer-keyboard note input. App-wide while enabled; plays the
    /// active scale through `pitchPad`. See `KeyboardNotePlayer`.
    let keyboard: KeyboardNotePlayer

    /// The Fret Pad's fret segments (Mac-only). Auto-saved to disk (debounced)
    /// by a sink in `start()`; edited live from the tab.
    @Published var fretArrangement = FretArrangement(segments: [])

    /// The saved layout the working arrangement came from (Layout menu
    /// checkmark); `nil` = unsaved. Hand edits don't clear it. Not persisted.
    @Published var fretLayoutName: String? = nil

    /// Which surface the iPad shows; rides the synced scale state. Persisted
    /// (always forced to `.fretPad` in `init`).
    @Published var ipadLayout: PadLayout =
        PadLayout(rawValue: UserDefaults.standard
            .integer(forKey: "tarabdaar.ipadLayout")) ?? .pitchPad {
        didSet {
            UserDefaults.standard.set(ipadLayout.rawValue, forKey: "tarabdaar.ipadLayout")
        }
    }

    /// The played voice: the String bow (default), or Tanpura / Sitar plucks
    /// at the exact bent onset. NOT persisted — every launch starts on the
    /// String voice; presets can switch it. Live tab picker.
    @Published var mainInstrument: AudioEngine.MainInstrument = .string {
        didSet {
            audio.setMainInstrument(mainInstrument)
        }
    }

    /// Which voice the drone buttons drive: the tanpura (default — press =
    /// pluck, hold = re-pluck cycle, release = ring out) or the sympathetic
    /// jt swell. Persisted; Strings tab.
    @Published var droneVoice: AudioEngine.DroneVoiceMode =
        AudioEngine.DroneVoiceMode(rawValue: UserDefaults.standard
            .string(forKey: "tarabdaar.droneVoice.v1") ?? "") ?? .tanpura {
        didSet {
            UserDefaults.standard.set(droneVoice.rawValue,
                                      forKey: "tarabdaar.droneVoice.v1")
            audio.setDroneVoiceMode(droneVoice)
        }
    }

    /// Control-axis bindings, Mac-owned and Mac-evaluated (`applyTiltAxis`):
    /// per axis a set of targets with transfer curves, edited in the
    /// Controls tab. Nothing syncs to the iPad. Persisted.
    @Published var tiltMapping: DimensionMapping = DimensionMapping.load() {
        didSet {
            tiltMapping.save()
            rebuildTiltEvalSnapshot()
        }
    }

    /// Per axis: the bound targets (composite or parameter) + curves,
    /// snapshotted under `compositeLock` for the link/CoreMIDI threads.
    private var tiltEvalByAxis: [[(target: MapTarget,
                                   binding: DimensionBinding)]] =
        Array(repeating: [], count: ControlAxes.dims.count)

    /// Last value per iPad wire axis (CoreMIDI thread only) — duplicate-drop
    /// for the uncalibrated passthrough.
    private var lastRawArmTilt: [Double?] = [nil, nil, nil]

    /// THE STRIKE→ACCELERATION BLEND. `.strike` and `.acceleration` share
    /// ONE measurement (the PERF_STATE strike byte) and are evaluated
    /// JOINTLY in `evaluateStrikeBlend`: per target (1−w)·strike + w·accel,
    /// w ramping 0→1 over the per-note window (`StrikeBlendWindow`). NEVER
    /// fed through `applyTiltAxis` (double-apply). State under `strikeLock`.
    static let strikeAxisIndex =
        ControlAxes.dims.firstIndex(of: .strike) ?? 5
    static let accelAxisIndex =
        ControlAxes.dims.firstIndex(of: .acceleration) ?? 6
    /// The live `ctl_fret_warp` value, written only by the `applyParamToVoice`
    /// interception (main); read by the Mac pad, relayed over JOYCON_STATE.
    @Published private(set) var fretFieldWarp: Double = 0

    private let strikeLock = NSLock()
    private var strikeWindow = StrikeBlendWindow(windowS: 2.0)
    private var strikeMeasure = 0.0        // last wire value 0…1
    private var lastBlendOut: [MapTarget: Double] = [:]
    /// 30 Hz re-evaluation while strike/accel bindings exist: the WEIGHT
    /// moves through the note window even when the measurement is still.
    private var strikeTimer: DispatchSourceTimer?

    /// THE FINGER-ACCEL DIMENSION: the newest sounding finger's pitch
    /// acceleration (−1…+1, `FingerAccelTracker`), fed from the ingest touch
    /// taps (wire + local lanes) plus a 30 Hz decay tick while bound (frames
    /// are change-gated). A plain bipolar axis via `applyTiltAxis`.
    static let fingerAxisIndex =
        ControlAxes.dims.firstIndex(of: .fingerAccel) ?? 7
    /// THE JOY-CON WRIST + ACCELERATION AXES. Wrist ↕/↔/⟲ from
    /// `JoyConInput.wristCal`, bipolar; Joy-Con Accel is UNIPOLAR 0…1,
    /// mapped onto the axis as `2·level − 1` so the curve reads rest at x 0.
    static let wristAxisIndices = (
        ControlAxes.dims.firstIndex(of: .tilt4) ?? 8,
        ControlAxes.dims.firstIndex(of: .wrist2) ?? 9,
        ControlAxes.dims.firstIndex(of: .wrist3) ?? 10)
    static let jcAccelAxisIndex =
        ControlAxes.dims.firstIndex(of: .jcAccel) ?? 11
    private let fingerLock = NSLock()
    private var fingerTracker = FingerAccelTracker()
    private var fingerOrder: [Int] = []          // sounding keys, old→new
    private var fingerPitch: [Int: Double] = [:]
    private var fingerLast = 0.0
    private var fingerActive = false
    private var fingerTimer: DispatchSourceTimer?

    /// Every touch currently DOWN with its latest finger pitch, oldest first
    /// — the finger's truth ABOVE the glide queue (parked fingers included).
    func currentTouches() -> [(id: Int, pitchSemis: Double)] {
        fingerLock.lock()
        defer { fingerLock.unlock() }
        return fingerOrder.compactMap { k in fingerPitch[k].map { (k, $0) } }
    }

    private func fingerGate(_ source: Int, _ id: UInt16, _ on: Bool) {
        let key = source << 16 | Int(id)
        fingerLock.lock()
        fingerOrder.removeAll { $0 == key }
        if on { fingerOrder.append(key) } else { fingerPitch[key] = nil }
        fingerLock.unlock()
        fingerEvaluate()
    }

    private func fingerPitchUpdate(_ source: Int, _ id: UInt16,
                                   _ pitch: Double) {
        let key = source << 16 | Int(id)
        fingerLock.lock()
        fingerPitch[key] = pitch
        let isNewest = fingerOrder.last == key
        fingerLock.unlock()
        if isNewest { fingerEvaluate() }
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
        if changed { applyTiltAxis(Self.fingerAxisIndex, v) }
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

    private func rebuildTiltEvalSnapshot() {
        var byAxis: [[(MapTarget, DimensionBinding)]] =
            Array(repeating: [], count: ControlAxes.dims.count)
        for target in tiltMapping.boundTargets {
            for (axis, dim) in ControlAxes.dims.enumerated() {
                if let b = tiltMapping.mapping(for: target).binding(for: dim) {
                    byAxis[axis].append((target, b))
                }
            }
        }
        compositeLock.lock()
        tiltEvalByAxis = byAxis
        compositeLock.unlock()
        // Strike/accel blend: clear the change gate (an edit must re-apply)
        // and run the weight timer only while the pair has bindings.
        let strikeActive = !(byAxis[Self.strikeAxisIndex].isEmpty
                             && byAxis[Self.accelAxisIndex].isEmpty)
        strikeLock.lock()
        lastBlendOut.removeAll()
        strikeLock.unlock()
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

    /// Evaluate the pair: for every target bound on EITHER dimension,
    /// (1−w)·strikeOut + w·accelOut, an unbound side reading the target's
    /// DEFAULT. Change-gated per target. Link thread + blend timer.
    private func evaluateStrikeBlend() {
        compositeLock.lock()
        let sBind = tiltEvalByAxis[Self.strikeAxisIndex]
        let aBind = tiltEvalByAxis[Self.accelAxisIndex]
        compositeLock.unlock()
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
        var changed: [(MapTarget, Double)] = []
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
        var rebuild: [String: Double] = [:]
        for (target, v) in changed {
            switch target.kind {
            case .composite(let slot):
                applyComposite(slot: slot, value: v)
            case .param(let key):
                if let pending = applyParamToVoice(key, v) {
                    rebuild[key] = pending
                }
            }
        }
        queueRebuildValues(rebuild)
    }

    /// Relay the axis values to the iPad as the latest-wins JOYCON_STATE
    /// frame (link-paced); `force` skips pacing for the STATE fields.
    private func sendJoyConDisplay(force: Bool = false) {
        let s = lastStickAxes
        strikeLock.lock()
        let win = strikeWindow.windowS
        strikeLock.unlock()
        link.setJoyConState(JoyConTiltDisplay(
            stickX: s.0, stickY: s.1,
            wrist1: lastWristTilt?.0 ?? 0,
            wrist2: lastWristTilt?.1 ?? 0,
            stickLive: abs(s.0) > 0.04 || abs(s.1) > 0.04,
            bodyLive: lastWristTilt != nil,
            connected: joyCon.connectedName != nil,
            wrist3: lastWristTilt?.2 ?? 0,
            arm1: lastArmAxes?.0 ?? 0,
            arm2: lastArmAxes?.1 ?? 0,
            arm3: lastArmAxes?.2 ?? 0,
            armLive: lastArmAxes != nil,
            strikeWindowS: win,
            fieldWarp: fretFieldWarp,
            octaveShift: pitchPad.octaveShift), force: force)
    }

    /// Dpad ←/→: step the playing range one octave (clamped). The shift
    /// lives in the shared pad engine — the ONE outbound-pitch point — and
    /// reaches the iPad as the forced JOYCON_STATE `octave` byte. Main thread.
    private func shiftOctave(_ delta: Int) {
        let next = min(max(pitchPad.octaveShift + delta,
                           PitchPadEngine.octaveShiftRange.lowerBound),
                       PitchPadEngine.octaveShiftRange.upperBound)
        guard next != pitchPad.octaveShift else { return }
        pitchPad.octaveShift = next
        sendJoyConDisplay(force: true)
    }

    /// The iPad raw-tilt funnel: an arm calibration consumes the report and
    /// drives axes 0–2; otherwise the raw axes pass through, duplicate-dropped.
    private func handleRawTilt(_ axis: Int, _ value: Double) {
        if !joyCon.feedArmTilt(axis, value) {
            if axis >= 0, axis < lastRawArmTilt.count,
               lastRawArmTilt[axis] != value {
                lastRawArmTilt[axis] = value
                applyTiltAxis(axis, value)
            }
        }
    }

    /// Apply one control-axis value (−1…+1, rest 0 ↔ curve x 0…1): drive each
    /// bound target in native units — a composite via `applyComposite`, a
    /// parameter via the unified apply. Off-main; downstream is thread-safe.
    private func applyTiltAxis(_ axis: Int, _ value: Double) {
        guard axis >= 0, axis < ControlAxes.dims.count else { return }
        compositeLock.lock()
        let bindings = tiltEvalByAxis[axis]
        compositeLock.unlock()
        let curveX = (value + 1) / 2                     // −1…+1 → curve 0…1
        var rebuild: [String: Double] = [:]
        for (target, binding) in bindings {
            let out = binding.evaluate(curveX)           // native units
            switch target.kind {
            case .composite(let slot):
                applyComposite(slot: slot, value: out)
            case .param(let key):
                if let pending = applyParamToVoice(key, out) {
                    rebuild[key] = pending
                }
            }
        }
        queueRebuildValues(rebuild)
    }

    /// COMPOSITE PARAMETERS: named 0…1 controls whose members each sweep
    /// their own lo→hi range. Controls tab; axes bind by slot. Persisted.
    @Published var composites: [CompositeParam] = AppController.loadComposites() {
        didSet {
            AppController.saveComposites(composites)
            rebuildCompositeSnapshot()
        }
    }

    private static let compositesKey = "tarabdaar.compositeParams.v1"

    private static func loadComposites() -> [CompositeParam] {
        if let data = UserDefaults.standard.data(forKey: compositesKey),
           let c = try? JSONDecoder().decode([CompositeParam].self, from: data) {
            return c
        }
        return CompositeParam.defaults()
    }

    private static func saveComposites(_ c: [CompositeParam]) {
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: compositesKey)
        }
    }

    /// Off-main-readable snapshot of the composite member sets, keyed by
    /// slot CC.
    private let compositeLock = NSLock()
    private var compositeMembersByCC: [UInt8: [CompositeMember]] = [:]
    /// Rebuild-path member values pending a (debounced) main-thread apply.
    private var pendingRebuildMembers: [String: Double] = [:]
    private var rebuildFlushScheduled = false

    /// RESTING VALUES for every `.live`/`.hybrid` parameter (`.rebuild` ones
    /// live in `StringParamStore`). Parameters tab; composites and bindings
    /// modulate ON TOP of these. Persisted as JSON.
    @Published var paramValues: [String: Double] = AppController.loadParamValues() {
        didSet {
            AppController.saveParamValues(paramValues)
            applyRestingParams()
        }
    }

    private static let paramValuesKey = "tarabdaar.controlDefaults.v1"

    private static func loadParamValues() -> [String: Double] {
        var d: [String: Double] = [:]
        if let data = UserDefaults.standard.data(forKey: paramValuesKey),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            // Only non-rebuild keys the registry still knows; retired keys
            // in a saved profile drop out here.
            for (k, v) in saved where ParamRegistry.spec(k)?.apply != .rebuild {
                if ParamRegistry.spec(k) != nil { d[k] = v }
            }
        }
        return d
    }

    private static func saveParamValues(_ d: [String: Double]) {
        if let data = try? JSONEncoder().encode(d) {
            UserDefaults.standard.set(data, forKey: paramValuesKey)
        }
    }

    // MARK: - Unified parameter access (Parameters tab / composites / tilts)

    /// A `.hybrid` parameter's build-time headroom (override, else artifact,
    /// else default), cached under `compositeLock` for off-main reads.
    private var hybridHeadroom: [String: Double] = [:]

    /// Re-read the headroom cache. Pass `values` from a `@Published` sink
    /// (which fires before the store's own property updates).
    private func refreshHybridHeadroom(from values: [String: Double]? = nil) {
        let v = values ?? stringParams.values
        var h: [String: Double] = [:]
        for spec in ParamRegistry.all where spec.apply == .hybrid {
            h[spec.key] = v[spec.key]
                ?? stringParams.artifactValue(spec.key) ?? spec.def
        }
        compositeLock.lock()
        hybridHeadroom = h
        compositeLock.unlock()
    }

    private func headroom(_ key: String) -> Double {
        compositeLock.lock()
        let h = hybridHeadroom[key]
        compositeLock.unlock()
        return h ?? ParamRegistry.spec(key)?.def ?? 0
    }

    /// The resting value of any parameter, native units: `.rebuild` reads
    /// the physics store, `.live`/`.hybrid` read `paramValues` — a hybrid
    /// with no stored value rests at `restFraction × headroom`.
    func paramValue(_ key: String) -> Double {
        guard let spec = ParamRegistry.spec(key) else { return 0 }
        switch spec.apply {
        case .rebuild:
            return stringParams.values[key] ?? spec.def
        case .live:
            return paramValues[key] ?? spec.def
        case .hybrid:
            if let v = paramValues[key] { return v }
            return (spec.restFraction ?? 0) * headroom(key)
        }
    }

    /// The value `paramValue` falls back to — what a reset restores.
    func paramDefault(_ key: String) -> Double {
        guard let spec = ParamRegistry.spec(key) else { return 0 }
        switch spec.apply {
        case .rebuild: return stringParams.artifactValue(key) ?? spec.def
        case .live:    return spec.def
        case .hybrid:  return (spec.restFraction ?? 0) * headroom(key)
        }
    }

    func paramIsDefault(_ key: String) -> Bool {
        abs(paramValue(key) - paramDefault(key)) <= 1e-9
    }

    /// Set a parameter's resting value (Parameters tab / audition script).
    /// Routes to whichever store owns it and applies to the voice.
    func setParamValue(_ key: String, _ value: Double) {
        guard let spec = ParamRegistry.spec(key) else { return }
        switch spec.apply {
        case .rebuild:
            stringParams.set(key, value)
        case .live:
            paramValues[key] = value           // didSet applies
        case .hybrid:
            // Above the built headroom the build scalar must move (rebuild);
            // at or below it the kernel's scaler covers it.
            if value > headroom(key) + 1e-12 {
                stringParams.set(key, value)   // raises the headroom
                refreshHybridHeadroom()
            }
            paramValues[key] = value
        }
    }

    /// Restore a parameter to its default and re-apply.
    func resetParam(_ key: String) {
        guard let spec = ParamRegistry.spec(key) else { return }
        switch spec.apply {
        case .rebuild:
            stringParams.reset(key)
        case .live:
            paramValues.removeValue(forKey: key)
        case .hybrid:
            // Drop a RAISED headroom first — but only touch the physics store
            // if it actually moved, so a plain reset costs no rebuild.
            if stringParams.values[key] != stringParams.artifactValue(key) {
                stringParams.reset(key)
                refreshHybridHeadroom()
            }
            paramValues.removeValue(forKey: key)
        }
    }

    /// Reset every parameter: clears the physics overrides and every
    /// resting value.
    func resetAllParams() {
        stringParams.resetToDefault()
        refreshHybridHeadroom()
        paramValues.removeAll()
    }

    /// Push every `.live`/`.hybrid` resting value to the voice — the
    /// baseline composites and bindings modulate on top of.
    func applyRestingParams() {
        for spec in ParamRegistry.storedKeys {
            _ = applyParamToVoice(spec.key, paramValue(spec.key))
        }
    }

    /// THE unified apply (thread-safe). Returns nil when the value took
    /// effect, else the value to funnel through the debounced rebuild path.
    @discardableResult
    func applyParamToVoice(_ key: String, _ value: Double) -> Double? {
        guard let spec = ParamRegistry.spec(key) else { return nil }
        // Control-layer key: the strike→acceleration blend window. Updates
        // the window, forces a blend re-evaluation, relays to the iPad.
        if key == "ctl_strike_window" {
            strikeLock.lock()
            strikeWindow.windowS = max(value, 0.05)
            lastBlendOut.removeAll()
            strikeLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.sendJoyConDisplay(force: true)
            }
            return nil
        }
        // Control-layer keys: the strum chord's expression (pushed live to
        // the held notes) and the accel-trigger threshold (0–127; ≥127 = off).
        if key == "ctl_strum_expr" {
            let v = min(max(value, 0), 1)
            strumExpr = v
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for h in self.strumHeld {
                    self.pitchPad.setTouchExpr(touchId: h.id,
                                               exprScale: v * h.weight)
                }
            }
            return nil
        }
        if key == "ctl_strum_thresh" {
            strumThresh01 = value >= 126.5 ? .infinity : value / 127.0
            return nil
        }
        // Control-layer keys: the glide queue's sequencer.
        if key.hasPrefix("ctl_glide_") {
            audio.glideQueue.setControl(key, value)
            return nil
        }
        // Control-layer key: the fret pitch warp — published for the Mac pad,
        // relayed to the iPad (link-paced), shapes the glide queue.
        if key == "ctl_fret_warp" {
            let v = min(max(value, 0), 1)
            audio.glideQueue.setWarp(v)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fretFieldWarp != v else { return }
                self.fretFieldWarp = v
                self.sendJoyConDisplay()
            }
            return nil
        }
        switch spec.apply {
        case .live:
            audio.setStringControlParam(key, value)
            return nil
        case .rebuild:
            return value
        case .hybrid:
            guard let scaler = ParamRegistry.hybridScaler(key) else { return value }
            let h = headroom(key)
            guard h > 1e-12 else { return value > 1e-12 ? value : nil }
            if value > h + 1e-12 {
                audio.setStringHybridScaler(scaler, 1.0)
                return value                    // needs a taller headroom
            }
            audio.setStringHybridScaler(scaler, value / h)
            return nil
        }
    }

    // jt overload watchdog (see start())
    private var jtStatsTimer: Timer?

    /// VOLUME READOUT relay: 60 Hz poll of `AudioEngine.volumeLevels`
    /// (integrate-and-dump — the ONE poller) → JOYCON_STATE, change-gated.
    private var volMeterTimer: DispatchSourceTimer?
    private var lastVolBytes: (UInt8, UInt8) = (0, 0)  // timer queue only

    private func startVolMeterRelay() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0,
                   leeway: .milliseconds(3))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let l = self.audio.volumeLevels()
            let bytes = (TLPVolume.byte(fromLinear: l.voice),
                         TLPVolume.byte(fromLinear: l.taraf))
            guard bytes != self.lastVolBytes else { return }
            self.lastVolBytes = bytes
            self.link.setVolumeLevels(voice: bytes.0, taraf: bytes.1)
        }
        t.resume()
        volMeterTimer = t
    }

    // MARK: - Controller strum (Joy-Con L)

    /// CONTROLLER STRUM (main queue only): a HELD CHORD sounded as ordinary
    /// notes in the MAIN voice through the shared `pitchPad` engine (fresh
    /// strings, taraf charge, firm strike velocity). Held by the L button
    /// (`strumLHeld`) and/or the ACCEL TRIGGER (`strumAccelHeld` — the strike
    /// envelope crossing `ctl_strum_thresh`); a press always closes any
    /// chord still held; ids are GENERATION-scoped so a re-press retriggers.
    /// THE CHORD BAR's ACTIVE selection (iPad taps via the PERF_STATE chord
    /// bytes, Mac taps via `tapChord` → the local pump) is what the strum
    /// plays, else the Strings tab's configured set; a change while ringing
    /// retunes in place. Performance state, never persisted.
    @Published var strumChord: ChordSelection?

    private var strumGen = 0
    /// The ringing chord's touches + Shepard weights (1.0 for the configured
    /// set); each note's live expression is `strumExpr × weight`.
    private var strumHeld: [(id: Int, weight: Double)] = []
    private var strumLHeld = false
    private var strumAccelHeld = false
    private var strumExpr = 1.0                 // ctl_strum_expr
    /// `ctl_strum_thresh` in the 0…1 strike domain; ≥127 = off (.infinity).
    private var strumThresh01 = Double.infinity
    /// Accel-trigger cooldown deadline (systemUptime): 100 ms after each
    /// accel release so a jittery envelope can't re-strike. Main-queue only.
    private var strumAccelCooldownUntil: TimeInterval = 0
    /// Distinct touchId namespace on the shared engine (the keyboard player
    /// uses 1_000_000).
    private static let strumTouchBase = 2_000_000

    func strum(pressed: Bool) {
        strumLHeld = pressed
        if pressed {
            strikeStrumChord()      // a press always retriggers
        } else if !strumAccelHeld {
            releaseStrum()
        }
    }

    /// The Mac chord bar's tap: toggles against the ACTIVE chord through
    /// the shared engine's edge path. Octave-agnostic (stored as octave 0).
    func tapChord(_ sel: ChordSelection) {
        pitchPad.setChordSelection(strumChord?.degree == sel.degree
            ? nil : ChordSelection(degree: sel.degree, octave: 0))
    }

    /// What the next strum sounds, as (ratio, weight): the active chord under
    /// the SHEPARD REGISTER LAW (`shepardChordNotes` — centered in the octave
    /// below the tonic, raised-cosine weights), else the configured set at 1.
    private func strumNotes() -> [(ratio: Double, weight: Double)] {
        if let sel = strumChord {
            let degs = scaleDegrees(from: pitchPad.scale)
            if sel.degree >= 0, sel.degree < degs.count {
                return shepardChordNotes(
                    rootRatio: degs[sel.degree].ratio,
                    intervals: scaleChords(degrees: degs)[sel.degree].intervals)
            }
        }
        return sarangi.state.strumStringRatios.map { ($0, 1.0) }
    }

    private func strikeStrumChord() {
        releaseStrum()
        strumGen += 1
        let gen = strumGen
        for (i, note) in strumNotes().enumerated() {
            let touch = Self.strumTouchBase + (gen % 1024) * 64 + i
            // A fixed-register anchor: exempt from the octave shift and from
            // the glide queue (near-simultaneous onsets must not chain).
            pitchPad.noteOn(touchId: touch, ratio: note.ratio,
                            velocity01: 0.9, octaveShifted: false,
                            exprScale: strumExpr * note.weight,
                            glideExempt: true)
            strumHeld.append((touch, note.weight))
        }
    }

    private func releaseStrum() {
        for h in strumHeld { pitchPad.noteOff(touchId: h.id) }
        strumHeld.removeAll()
    }

    /// A selection change while RINGING retunes the held notes in place (no
    /// new attack); a shrinking chord note-offs the surplus, a growing one
    /// strikes the extra members. Ids are index-deterministic per generation.
    private func retuneStrumChord() {
        guard !strumHeld.isEmpty else { return }
        let notes = strumNotes()
        for i in strumHeld.indices where i < notes.count {
            pitchPad.glide(touchId: strumHeld[i].id, ratio: notes[i].ratio)
            if strumHeld[i].weight != notes[i].weight {
                strumHeld[i].weight = notes[i].weight
                pitchPad.setTouchExpr(touchId: strumHeld[i].id,
                                      exprScale: strumExpr * notes[i].weight)
            }
        }
        if strumHeld.count > notes.count {
            for h in strumHeld[notes.count...] {
                pitchPad.noteOff(touchId: h.id)
            }
            strumHeld.removeSubrange(notes.count...)
        }
        while strumHeld.count < notes.count {
            let i = strumHeld.count
            let touch = Self.strumTouchBase + (strumGen % 1024) * 64 + i
            pitchPad.noteOn(touchId: touch, ratio: notes[i].ratio,
                            velocity01: 0.9, octaveShifted: false,
                            exprScale: strumExpr * notes[i].weight,
                            glideExempt: true)
            strumHeld.append((touch, notes[i].weight))
        }
    }

    /// The accel trigger's edge detector (link receive queue): rising
    /// through the threshold strikes; falling below releases (unless L
    /// holds) and arms the cooldown. Edges hop to main, which re-tests.
    private func strumAccelSense(_ v: Double) {
        let up = !strumAccelHeld && v >= strumThresh01
        let down = strumAccelHeld && v < strumThresh01
        guard up || down else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if !self.strumAccelHeld, v >= self.strumThresh01,
               now >= self.strumAccelCooldownUntil {
                self.strumAccelHeld = true
                self.strikeStrumChord()
            } else if self.strumAccelHeld, v < self.strumThresh01 {
                self.strumAccelHeld = false
                self.strumAccelCooldownUntil = now + 0.1
                if !self.strumLHeld { self.releaseStrum() }
            }
        }
    }

    /// Latest axis values for the iPad display relay (main queue). Wrist is
    /// nil until the fusion runs; arm is nil while no calibration drives.
    private var lastStickAxes: (Double, Double) = (0, 0)
    private var lastWristTilt: (Double, Double, Double)?
    private var lastArmAxes: (Double, Double, Double)?
    private var lastJtDrops = 0.0
    private var jtGateLogTicks = 0
    private var lastJtFlat = 0.0
    private var lastRenderOverruns: UInt64 = 0

    // MARK: - Sarangi model
    //
    // The String voice's document is owned by `sarangi` (`SarangiStore`): the
    // sympathetic-string table that tunes the in-kernel taraf (Strings tab).

    /// The sarangi document's editable state + engine bridge (tarab tuning).
    let sarangi: SarangiStore

    /// Store for the `.rebuild` (and `.hybrid` headroom) parameters: artifact
    /// scalars + persisted overrides, applied through a debounced rebuild.
    let stringParams: StringParamStore

    // MARK: - Init / lifecycle

    init() {
        let audio = AudioEngine()
        let midi = MIDIEngine()
        let midiIn = MIDIInput()
        self.audio = audio
        self.midi = midi
        self.midiIn = midiIn
        self.ingest = LinkIngest(sink: audio)
        midiIn.audioEngine = audio
        // Simulator + audition runner (back-ref wired after init).
        let sim = IPadSimulator(audio: audio)
        self.simulator = sim
        self.audition = AuditionRunner(simulator: sim, audio: audio)
        self.pitchPad = PitchPadEngine(audio: audio)
        self.fretPad = PitchPadEngine(audio: audio)
        self.fretPad.tonicMidi = self.pitchPad.tonicMidi
        // Fret Pad Snap: 24 px (not the shared 16), fitted to real iPad
        // onsets — ≈43¢, under the 40 px minimum fret gap. Synced to the iPad.
        self.fretPad.marginPixels = 24
        self.keyboard = KeyboardNotePlayer(engine: self.pitchPad)
        // Restore the last-edited arrangement, or build a starter from the
        // scale. (The autosave sink is wired in `start()`.)
        self.fretArrangement = FretArrangementStore.loadCurrent()
            ?? FretArrangement.keyboardArrangement(
                degrees: scaleDegrees(from: self.pitchPad.scale))
        // Loads the persisted/default document and builds the tarab tuning.
        self.sarangi = SarangiStore(audio: audio)
        // Physics overrides — seeds the engine before the first BowEngine.
        self.stringParams = StringParamStore(audio: audio)

        // Restore the output device rate on a clean quit (the engine forces
        // 44.1 kHz to drop the output resampler). SIGKILL skips this.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.audio.restoreOutputDeviceRate()
        }

        // Arm the String voice. The Mac pads hold a flat CC11 per note; 32 ≈
        // the fitted expression median (the surfaces span ~16 dB around it).
        audio.setSarangiModelVoiceEnabled(true)
        pitchPad.macExpressionLevel = 32
        fretPad.macExpressionLevel = 32

        // The tanpura voice is always armed beside the String voice; its JI
        // slot grid builds off-main in `start()`. Restore the routing choices.
        audio.setTanpuraVoiceEnabled(true)
        audio.setMainInstrument(mainInstrument)
        audio.setDroneVoiceMode(droneVoice)

        // Wire the simulator's CC route back to this controller.
        simulator.controller = self

        // The Fret Pad is the only surface — force the synced layout.
        ipadLayout = .fretPad
    }

    /// Combine subscriptions (scale sync, autosaves, tarab/tanpura pushes).
    private var cancellables = Set<AnyCancellable>()

    func start() {
        midi.start()
        midiIn.start()
        simulator.start()
        pitchPad.start()
        fretPad.start()
        audition.start()
        startScaleSync()
        // Snapshots for the off-main deliveries, then the baseline values.
        rebuildCompositeSnapshot()
        rebuildTiltEvalSnapshot()
        refreshHybridHeadroom()      // build depths behind the hybrid knobs
        applyRestingParams()         // resting values for every live param
        // A physics edit can move a hybrid's headroom — keep the cache in step
        // (`@Published` fires before the property updates: use the sink value).
        stringParams.$values
            .sink { [weak self] v in self?.refreshHybridHeadroom(from: v) }
            .store(in: &cancellables)
        // The iPad's raw tilt: the TarabLink state frame (change-gated in
        // LinkIngest) and the in-process tilt CCs (audition scores).
        ingest.onTiltAxis = { [weak self] axis, value in
            self?.handleRawTilt(axis, value)
        }
        audio.onTiltAxis = { [weak self] axis, value in
            self?.handleRawTilt(axis, value)
        }
        // Raw accelerometer off the same frames — display only.
        ingest.onAccel = { [weak self] x, y, z in
            self?.joyCon.feedAccel(x, y, z)
        }
        // The strike envelope: the measurement behind the `.strike` /
        // `.acceleration` pair. Change-gated in LinkIngest.
        ingest.onStrike = { [weak self] v in
            guard let self else { return }
            self.strikeLock.lock()
            self.strikeMeasure = v
            self.strikeLock.unlock()
            self.evaluateStrikeBlend()
            // The strum accel trigger rides the same envelope.
            self.strumAccelSense(v)
        }
        // Note-lifecycle edges anchor the per-note blend windows (a
        // retrigger re-anchors; releases fall back to the survivor's age).
        ingest.onTouchGate = { [weak self] id, on in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.strikeLock.lock()
            if on { self.strikeWindow.noteOn(id, at: now) }
            else { self.strikeWindow.noteOff(id) }
            self.strikeLock.unlock()
            self.fingerGate(0, id, on)
        }
        // The `.fingerAccel` pitch feed — wire lane (source 0) + the local
        // pads/auditions lane (source 1), so the u16 id spaces can't collide.
        ingest.onTouchPitch = { [weak self] id, pitch in
            self?.fingerPitchUpdate(0, id, pitch)
        }
        pitchPad.localIngest?.onTouchGate = { [weak self] id, on in
            self?.fingerGate(1, id, on)
        }
        pitchPad.localIngest?.onTouchPitch = { [weak self] id, pitch in
            self?.fingerPitchUpdate(1, id, pitch)
        }
        // Chord-bar selection edges from both lanes (iPad taps, the Mac bar via
        // `tapChord`) land in `strumChord`; a RINGING chord retunes in place.
        let chordEdge: (ChordSelection?) -> Void = { [weak self] sel in
            DispatchQueue.main.async {
                guard let self, self.strumChord != sel else { return }
                self.strumChord = sel
                self.retuneStrumChord()
            }
        }
        ingest.onChordSelect = chordEdge
        pitchPad.localIngest?.onChordSelect = chordEdge
        // TarabLink: inbound TLP SysEx from MIDIInput's reassembler; outbound via
        // the wired-first SysEx send ("iPad" name match; BLE bypasses the
        // filter). Events fall back to send-to-all; state frames just drop.
        midiIn.onSysEx = { [weak self] bytes in
            self?.link.receivedSysEx(bytes)
        }
        link.sendRaw = { [weak self] bytes, isEvent in
            self?.midi.sendSysEx(bytes, toDestinationsMatching: "iPad",
                                 fallbackToAll: isEvent)
        }
        link.onPerfState = { [weak self] frame in
            self?.ingest.apply(frame)
        }
        link.onLinkDrop = { [weak self] in
            guard let self else { return }
            NSLog("Tarabdaar: link stale — releasing everything held")
            self.ingest.linkDidDrop()
            // No more frames: the strike measurement rests at 0.
            self.strikeLock.lock()
            self.strikeMeasure = 0
            self.strikeLock.unlock()
            self.evaluateStrikeBlend()
            // An accel-held strum chord must not outlive the link.
            self.strumAccelSense(0)
        }
        link.onEvent = { [weak self] event in
            switch event {
            case .resyncRequest:
                DispatchQueue.main.async { self?.pushCurrentState() }
            case .panic:
                // Kill the WIRE's touches/drones only — never the Mac's pads.
                NSLog("TarabLink: panic from pad")
                self?.ingest.linkDidDrop()
            default:
                break
            }
        }
        link.onStatus = { status in
            NSLog("TarabLink: up=%d stale=%d rtt=%@",
                  status.isUp ? 1 : 0, status.isStale ? 1 : 0,
                  status.rttMs.map { String(format: "%.1fms", $0) } ?? "–")
        }
        // A destination appearing/vanishing → re-greet; scale sync re-pushes.
        midi.$destinationCount
            .removeDuplicates()
            .sink { [weak self] _ in self?.link.kick() }
            .store(in: &cancellables)
        link.start()
        // TLPDBG_SELFTEST: env-gated headless self-test of the fret pad path.
        if ProcessInfo.processInfo.environment["TLPDBG_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                NSLog("TLPDBG selftest: noteOn")
                self.fretPad.noteOn(touchId: 999, ratio: 1.25)
                for step in 1...20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.1) {
                        self.fretPad.glide(touchId: 999,
                                           ratio: 1.25 + 0.01 * Double(step))
                        let r = self.audio.performanceReadout()
                        NSLog("TLPDBG selftest step=%d active=%d pitchHz=%.2f",
                              step, r.active ? 1 : 0, r.pitchHz)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    NSLog("TLPDBG selftest: noteOff")
                    self.fretPad.noteOff(touchId: 999)
                }
            }
        }
        audio.onCompositeCC = { [weak self] cc, value in
            self?.applyComposite(slotCC: cc, value: value)
        }
        // Joy-Con. Control axes: arm 0–2 (the iPad's tilts), stick 3/4, wrist
        // + acceleration (`wristAxisIndices` / `jcAccelAxisIndex`).
        joyCon.onArmAxes = { [weak self] t1, t2, t3 in
            guard let self else { return }
            self.applyTiltAxis(0, t1)
            self.applyTiltAxis(1, t2)
            self.applyTiltAxis(2, t3)
            // Mirror the calibrated arm axes to the iPad's arm square (main
            // thread; the link paces the sends).
            self.lastArmAxes = (t1, t2, t3)
            self.sendJoyConDisplay()
        }
        joyCon.onWristAttitude = { [weak self] wrist in
            guard let self else { return }
            self.lastWristTilt = wrist
            self.sendJoyConDisplay()
        }
        joyCon.onStickAxes = { [weak self] x01, y01 in
            guard let self else { return }
            self.applyTiltAxis(3, x01)
            self.applyTiltAxis(4, y01)
            self.lastStickAxes = (x01, y01)
            self.sendJoyConDisplay()
        }
        joyCon.onWristAxes = { [weak self] w1, w2, w3 in
            guard let self else { return }
            self.applyTiltAxis(Self.wristAxisIndices.0, w1)
            self.applyTiltAxis(Self.wristAxisIndices.1, w2)
            self.applyTiltAxis(Self.wristAxisIndices.2, w3)
        }
        joyCon.onJoyConAccel = { [weak self] level in
            self?.applyTiltAxis(Self.jcAccelAxisIndex, level * 2 - 1)
        }
        joyCon.onButton = { [weak self] control, pressed in
            guard let self else { return }
            switch control {
            case .dpadLeft:
                // ←/→ step the playing range an octave.
                guard pressed else { return }
                self.shiftOctave(-1)
            case .dpadDown:
                // During a capture, ↓ steps BACK one phase (↑ advances); it is
                // drone button 1 otherwise. The release still clears the drone.
                if self.joyCon.capturingCalibrator != nil {
                    if pressed { self.joyCon.redoPreviousCalibrationStep() }
                    else { self.audio.setDronePressed(1, false) }
                } else {
                    self.audio.setDronePressed(1, pressed)
                }
            case .dpadRight:
                guard pressed else { return }
                self.shiftOctave(+1)
            case .l:
                // L holds the strum chord — see `strum(pressed:)`.
                self.strum(pressed: pressed)
            case .zl:
                // ZL re-zeroes the arm AND wrist axes at the current poses.
                guard pressed else { return }
                self.joyCon.recenterBody()
            case .sl, .sr, .stickClick, .minus, .capture:
                // Unassigned — visible in the panel chips.
                break
            case .dpadUp:
                // Advances a running calibration (no-op otherwise).
                guard pressed else { return }
                self.joyCon.advanceCalibration()
            }
        }
        // The `connected` bit hides the drone buttons on both surfaces, so
        // its edges must arrive even when no axis moves: force a push.
        joyCon.$connectedName
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sendJoyConDisplay(force: true) }
            .store(in: &cancellables)
        joyCon.start()
        // Voice/taraf volume readout → iPad (JOYCON_STATE vol bytes).
        startVolMeterRelay()
        // jt overload watchdog: the async jawari web drops blocks / flat-fills
        // past its realtime budget (audible clicking). Log when counters GROW.
        jtStatsTimer = Timer.scheduledTimer(withTimeInterval: 5.0,
                                            repeats: true) { [weak self] _ in
            guard let self else { return }
            if let s = self.audio.stringVoiceJtStats(), s.on > 0.5 {
                if s.drops > self.lastJtDrops || s.flat > self.lastJtFlat {
                    NSLog("Tarabdaar: jt OVERLOAD — +%.0f dropped blocks, +%.0f flat-filled samples (totals %.0f/%.0f, fifo %.0f)",
                          s.drops - self.lastJtDrops, s.flat - self.lastJtFlat,
                          s.drops, s.flat, s.fill)
                    self.lastJtDrops = s.drops
                    self.lastJtFlat = s.flat
                } else if s.drops < self.lastJtDrops || s.flat < self.lastJtFlat {
                    // engine rebuilt — counters reset
                    self.lastJtDrops = s.drops
                    self.lastJtFlat = s.flat
                }
            }
            // Quiescence-gate probe: what keeps the idle web awake (ring = rows
            // above the floor, drive = bridge drive, drone). Ratios > 1 block.
            let g = self.audio.stringVoiceJtGateProbe()
            let awake = g.map { $0.total > 0 && $0.asleep < $0.total } ?? false
            // The first ~30 s log unconditionally; then only while awake.
            if self.jtGateLogTicks < 6 || awake {
                self.jtGateLogTicks += 1
                if let g {
                    NSLog("Tarabdaar: jt gate — asleep=%d/%d ring×%.2f drive×%.2f%@",
                          g.asleep, g.total, g.ringR, g.driveR,
                          g.droneHot ? " drone" : "")
                } else {
                    NSLog("Tarabdaar: jt gate — no String voice")
                }
            }
            // Render overruns glitch at the DEVICE (an audition WAV can't
            // show them) — log whenever they grow.
            if let r = self.audio.stringVoiceRenderStats() {
                if r.overruns > self.lastRenderOverruns {
                    NSLog("Tarabdaar: render OVERRUN — +%llu late callbacks (worst %.2f ms this period, total %llu/%llu)",
                          r.overruns - self.lastRenderOverruns, r.maxMs,
                          r.overruns, r.callbacks)
                }
                self.lastRenderOverruns = r.overruns
            }
        }
        // Keep the Fret Pad engine's tonic locked to the scale engine's.
        pitchPad.$tonicMidi
            .sink { [weak self] in self?.fretPad.tonicMidi = $0 }
            .store(in: &cancellables)
        pitchPad.$tonicCents
            .sink { [weak self] in self?.fretPad.tonicCents = $0 }
            .store(in: &cancellables)

        // The tonic starts at D4 every launch — DELIBERATELY not persisted: a
        // stale restored tonic silently retunes the whole instrument.

        // Auto-save the Fret Pad arrangement (debounced).
        $fretArrangement
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { FretArrangementStore.saveCurrent($0) }
            .store(in: &cancellables)

        // Drone-button DISPLAY ratios: the buttons pluck MAPPED tarab strings,
        // so `droneRatios` are purely visual (labels/colors on both surfaces).
        // An unmapped slot keeps its last ratio and is inert.
        Publishers.CombineLatest3(
            sarangi.$state.map(\.droneStringFreqs).removeDuplicates(),
            pitchPad.$tonicMidi.removeDuplicates(),
            pitchPad.$tonicCents.removeDuplicates()
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] freqs, _, _ in
            guard let self else { return }
            let tonic = self.pitchPad.tonicHz
            var ratios = self.fretArrangement.droneRatios
            for i in ratios.indices where freqs.indices.contains(i) {
                if let f = freqs[i] {
                    ratios[i] = max(0.25, min(4.0, f / tonic))
                }
            }
            if ratios != self.fretArrangement.droneRatios {
                self.fretArrangement.droneRatios = ratios
            }
        }
        .store(in: &cancellables)

        // Push the scale into the tarab document. Pitches ALWAYS follow; the
        // row LAYOUT regenerates only when the degree count changes.
        Publishers.MergeMany([
            pitchPad.$scale.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicMidi.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicCents.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] in self?.syncTarabFromScale() }
        .store(in: &cancellables)
        syncTarabFromScale()        // match the scale on launch

        // Rebuild the tanpura's JI slot grid on a scale/tonic change. Heavier
        // debounce than the tarab push — a tanpura build is ~seconds of CPU.
        Publishers.MergeMany([
            pitchPad.$scale.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicMidi.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicCents.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .milliseconds(750), scheduler: RunLoop.main)
        .sink { [weak self] in self?.syncTanpuraFromScale() }
        .store(in: &cancellables)
        syncTanpuraFromScale()      // arm the drone voice on launch
    }

    /// Last tuning pushed into the tanpura, for the unchanged-skip above.
    private var lastTanpuraSync: (tonic: Double, ratios: [Double])?

    /// Push the centralized scale into the tanpura's slot grid (no-op when
    /// the tuning hasn't actually moved — the build is seconds of CPU).
    func syncTanpuraFromScale() {
        let ratios = scaleDegrees(from: pitchPad.scale).map(\.ratio)
        let tonic = pitchPad.tonicHz
        if let last = lastTanpuraSync, last.tonic == tonic,
           last.ratios == ratios { return }
        lastTanpuraSync = (tonic, ratios)
        audio.rebuildTanpura(tonic: tonic, scaleRatios: ratios)
        // The sitar mounts the same JI grid from its own artifact — a no-op
        // until the voice has been armed (first switch to Sitar).
        audio.rebuildSitar(tonic: tonic, scaleRatios: ratios)
    }

    // MARK: - Fret layouts (Fret Pad tab's Layout menu)

    /// The scale degrees the layouts are built against — the one scale.
    private var fretDegrees: [(ratio: Double, label: String)] {
        scaleDegrees(from: pitchPad.scale)
    }

    /// Build a **built-in** layout from the current scale. It becomes an
    /// unsaved working layout (no name), like loading a `ScalePreset`.
    func loadFretLayout(preset: FretLayoutPreset) {
        fretPad.panic()
        fretArrangement = preset.arrangement(degrees: fretDegrees)
        fretLayoutName = nil
    }

    /// Save the working arrangement under `name` and adopt the name.
    /// Silently no-ops on an empty/reserved name or a failed write.
    func saveFretLayout(name: String) {
        guard let saved = try? FretArrangementStore.save(fretArrangement,
                                                         name: name) else { return }
        fretLayoutName = saved
    }

    /// Load a saved layout. Stops sounding touches first — the frets a held
    /// note was resolved against are about to be replaced.
    func loadFretLayout(name: String) {
        guard let loaded = try? FretArrangementStore.load(name: name) else { return }
        fretPad.panic()
        fretArrangement = loaded
        fretLayoutName = name
    }

    /// Delete a saved layout. If it was the loaded one, the working
    /// arrangement stays put and just loses its name.
    func deleteFretLayout(name: String) {
        try? FretArrangementStore.delete(name: name)
        if fretLayoutName == name { fretLayoutName = nil }
    }

    // MARK: - Sarangi tarab ↔ Pitch Pad scale

    /// Push the scale into the tarab document. Pitches always follow; the row
    /// layout regenerates when the degree count changed or under `force`.
    func syncTarabFromScale(force: Bool = false) {
        let ratios = scaleDegrees(from: pitchPad.scale).map(\.ratio)
        sarangi.syncTarabToScale(tonicHz: pitchPad.tonicHz, ratios: ratios, force: force)
    }

    // MARK: - iPad scale sync (Mac → iPad over TLP events)

    /// Push the scale state and the fret arrangement to the iPad whenever
    /// any of it changes (debounced) or a MIDI destination appears. One-way;
    /// the only cross-device state.
    private func startScaleSync() {
        let triggers: [AnyPublisher<Void, Never>] = [
            pitchPad.$scale.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicMidi.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicCents.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$marginPixels.map { _ in () }.eraseToAnyPublisher(),
            fretPad.$marginPixels.map { _ in () }.eraseToAnyPublisher(),
            $fretArrangement.map { _ in () }.eraseToAnyPublisher(),
            $ipadLayout.map { _ in () }.eraseToAnyPublisher(),
            midi.$destinationCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.pushCurrentState() }
            .store(in: &cancellables)
    }

    /// Rate limit for `pushCurrentState` (≥300 ms apart — a peer requesting
    /// resync per frame must not storm the wire). Coalescing, not dropping.
    private var lastStatePush: CFAbsoluteTime = 0
    private var statePushScheduled = false

    private func pushCurrentState() {
        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - lastStatePush
        if gap < 0.3 {
            if !statePushScheduled {
                statePushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.3 - gap)) {
                    [weak self] in
                    self?.statePushScheduled = false
                    self?.pushCurrentState()
                }
            }
            return
        }
        lastStatePush = now
        pushCurrentStateNow()
    }

    private func pushCurrentStateNow() {
        // The active surface's margin (the Fret Pad's Snap slider).
        let margin = ipadLayout == .fretPad ? fretPad.marginPixels
                                            : pitchPad.marginPixels
        let state = SyncedScaleState(points: pitchPad.scale.points,
                                     tonicMidi: pitchPad.tonicMidi,
                                     tonicCents: pitchPad.tonicCents,
                                     marginPixels: margin,
                                     layout: ipadLayout)
        link.send(event: .scaleState(blob: PitchScaleSysEx.encodeBlob(state)))
        if ipadLayout == .fretPad {
            link.send(event: .fretArrangement(
                blob: FretArrangementSysEx.encodeBlob(fretArrangement)))
        }
        // A freshly-linked iPad must also learn the JOYCON_STATE fields.
        sendJoyConDisplay(force: true)
    }

    // MARK: - Composite parameters

    private func rebuildCompositeSnapshot() {
        compositeLock.lock()
        compositeMembersByCC = Dictionary(
            uniqueKeysWithValues: composites.map { ($0.slotCC, $0.members) })
        compositeLock.unlock()
    }

    /// Apply a composite's value 0…1: every member sweeps its lo→hi range via
    /// the unified apply; rebuild members go through the debounced flush.
    func applyComposite(slotCC: UInt8, value: Double) {
        compositeLock.lock()
        let members = compositeMembersByCC[slotCC] ?? []
        compositeLock.unlock()
        guard !members.isEmpty else { return }
        var rebuild: [String: Double] = [:]
        for m in members {
            if let pending = applyParamToVoice(m.key, m.value(at: value)) {
                rebuild[m.key] = pending
            }
        }
        queueRebuildValues(rebuild)
    }

    /// Funnel rebuild-path values (from a composite or a direct tilt
    /// binding) into one debounced main-thread flush. Thread-safe.
    private func queueRebuildValues(_ values: [String: Double]) {
        guard !values.isEmpty else { return }
        compositeLock.lock()
        pendingRebuildMembers.merge(values) { _, new in new }
        let schedule = !rebuildFlushScheduled
        rebuildFlushScheduled = true
        compositeLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.compositeLock.lock()
            let flush = self.pendingRebuildMembers
            self.pendingRebuildMembers.removeAll()
            self.rebuildFlushScheduled = false
            self.compositeLock.unlock()
            for (key, v) in flush {
                self.stringParams.setAuditionParam(key, v)
            }
            self.refreshHybridHeadroom()
        }
    }

    /// Convenience: apply by slot index.
    func applyComposite(slot: Int, value: Double) {
        guard slot >= 0, slot < CompositeParam.slotCCs.count else { return }
        applyComposite(slotCC: CompositeParam.slotCCs[slot], value: value)
    }

    /// The user-facing name for a target: the composite's name (or
    /// "Composite N (empty)"), else the parameter's registry label.
    func targetDisplayName(_ t: MapTarget) -> String {
        guard let slot = t.compositeSlot else { return t.label }
        if let c = composites.first(where: { $0.slot == slot }) {
            return c.name
        }
        return "Composite \(slot + 1) (empty)"
    }

    /// Parameter catalog for the composite editor + tilt Add menus: every
    /// registry parameter, grouped, with its native range.
    static let paramCatalog: [(key: String, label: String,
                               lo: Double, hi: Double)] =
        ParamRegistry.all.map {
            (key: $0.key, label: $0.label, lo: $0.lo, hi: $0.hi)
        }

    static func paramInfo(_ key: String)
        -> (key: String, label: String, lo: Double, hi: Double) {
        paramCatalog.first { $0.key == key }
            ?? (key: key, label: key, lo: 0, hi: 1)
    }

    // MARK: - Composite editing (Controls tab)

    /// Create a composite on the next free slot (nil when all 8 in use).
    @discardableResult
    func addComposite() -> CompositeParam? {
        let used = Set(composites.map(\.slot))
        guard let slot = (0..<CompositeParam.maxSlots).first(where: { !used.contains($0) })
        else { return nil }
        let c = CompositeParam(name: "Composite \(slot + 1)", slot: slot,
                               members: [])
        composites.append(c)
        return c
    }

    func removeComposite(_ id: CompositeParam.ID) {
        composites.removeAll { $0.id == id }
    }

    func renameComposite(_ id: CompositeParam.ID, to name: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }) else { return }
        composites[i].name = name
    }

    func addCompositeMember(_ id: CompositeParam.ID, key: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }),
              !composites[i].members.contains(where: { $0.key == key })
        else { return }
        let info = AppController.paramInfo(key)
        composites[i].members.append(
            CompositeMember(key: key, lo: info.lo, hi: info.hi))
    }

    func removeCompositeMember(_ id: CompositeParam.ID, key: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }) else { return }
        composites[i].members.removeAll { $0.key == key }
    }

    func setCompositeMemberRange(_ id: CompositeParam.ID, key: String,
                                 lo: Double, hi: Double) {
        guard let i = composites.firstIndex(where: { $0.id == id }),
              let j = composites[i].members.firstIndex(where: { $0.key == key })
        else { return }
        composites[i].members[j].lo = lo
        composites[i].members[j].hi = hi
    }

    // MARK: - Tilt-control binding edits (Controls tab / Parameters tab)

    /// The targets bound to one tilt (composites first, then parameters).
    func tiltBindings(for dim: InputDimension) -> [MapTarget] {
        tiltMapping.targets(for: dim)
    }

    /// Every tilt a given target is bound to — the Parameters tab's
    /// per-row mapping badge reads this.
    func tiltDimensions(for target: MapTarget) -> [InputDimension] {
        ControlAxes.dims.filter { tiltMapping.isConnected(target, $0) }
    }

    /// Bind a target to an axis over its full native range; endpoints are
    /// draggable afterwards.
    func addTiltBinding(_ target: MapTarget, dim: InputDimension) {
        var m = tiltMapping
        let r = target.defaultRange
        var pm = m.mapping(for: target)
        pm.bindings.removeAll { $0.dimension == dim }
        pm.bindings.append(DimensionBinding(dimension: dim,
                                            rangeMin: r.0, rangeMax: r.1))
        m.mappings[target.storageKey] = pm
        tiltMapping = m
    }

    func removeTiltBinding(_ target: MapTarget, dim: InputDimension) {
        var m = tiltMapping
        var pm = m.mapping(for: target)
        pm.bindings.removeAll { $0.dimension == dim }
        m.mappings[target.storageKey] = pm
        tiltMapping = m
        // An undriven parameter falls back to its resting value.
        if let key = target.paramKey, pm.bindings.isEmpty {
            _ = applyParamToVoice(key, paramValue(key))
        }
    }

    func toggleTiltBinding(_ target: MapTarget, dim: InputDimension) {
        if tiltMapping.isConnected(target, dim) {
            removeTiltBinding(target, dim: dim)
        } else {
            addTiltBinding(target, dim: dim)
        }
    }

    /// Set a binding's endpoints. `fromCenter` = flat at `lo` through the
    /// resting half, sweeping to `hi` past neutral; off = plain linear.
    func setTiltBinding(_ target: MapTarget, dim: InputDimension,
                        lo: Double, hi: Double, fromCenter: Bool) {
        var m = tiltMapping
        var pm = m.mapping(for: target)
        pm.bindings.removeAll { $0.dimension == dim }
        let pts = fromCenter
            ? [ControlPoint(x: 0, y: lo), ControlPoint(x: 0.5, y: lo),
               ControlPoint(x: 1, y: hi)]
            : [ControlPoint(x: 0, y: lo), ControlPoint(x: 1, y: hi)]
        pm.bindings.append(DimensionBinding(dimension: dim, controlPoints: pts))
        m.mappings[target.storageKey] = pm
        tiltMapping = m
    }

    /// Composites a parameter is a member of (the Parameters tab's
    /// mapping menu ticks these).
    func compositesContaining(_ key: String) -> [CompositeParam] {
        composites.filter { $0.members.contains { $0.key == key } }
    }

    func toggleCompositeMember(_ id: CompositeParam.ID, key: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }) else { return }
        if composites[i].members.contains(where: { $0.key == key }) {
            removeCompositeMember(id, key: key)
        } else {
            addCompositeMember(id, key: key)
        }
    }

    // MARK: - Presets

    /// Capture the whole rig: sarangi document, physics overrides, resting
    /// values, composites, bindings, voice routing. One preset = one rig.
    func capturePreset(name: String) -> TarabdaarPreset {
        var p = TarabdaarPreset()
        p.name = name
        p.savedAt = ISO8601DateFormatter().string(from: Date())
        p.instrument = sarangi.state
        p.stringOverrides = stringParams.overridesSnapshot
        p.paramValues = paramValues
        p.composites = composites
        p.tiltMapping = tiltMapping
        p.mainInstrument = mainInstrument.rawValue
        p.droneVoice = droneVoice.rawValue
        return p
    }

    /// Apply whatever sections `p` carries; missing sections are skipped.
    func applyPreset(_ p: TarabdaarPreset) {
        if let inst = p.instrument {
            sarangi.replaceState(inst)
        }
        if let ov = p.stringOverrides {
            stringParams.replaceOverrides(ov)
            refreshHybridHeadroom()
        }
        if let pv = p.paramValues {
            // Keep only keys this build still knows; `didSet` re-applies.
            paramValues = pv.filter {
                guard let spec = ParamRegistry.spec($0.key) else { return false }
                return spec.apply != .rebuild
            }
        }
        if let c = p.composites { composites = c }
        if let t = p.tiltMapping { tiltMapping = t }
        if let m = p.mainInstrument,
           let inst = AudioEngine.MainInstrument(rawValue: m) {
            mainInstrument = inst
        }
        if let d = p.droneVoice,
           let mode = AudioEngine.DroneVoiceMode(rawValue: d) {
            droneVoice = mode
        }
    }

    /// The shipped default as a full rig: generated bank, artifact physics,
    /// default composites and bindings, String voice, tanpura drones.
    func loadFactoryPreset(_ preset: Preset) {
        sarangi.loadSarangiLiveDefault(preset)
        resetAllParams()
        composites = CompositeParam.defaults()
        tiltMapping = DimensionMapping.makeDefault()
        mainInstrument = .string
        droneVoice = .tanpura
    }

    // MARK: The preset library — no file panels

    /// Saved presets live in the app-managed library (one `.tarabdaar` file
    /// each) and appear in the Load-preset menu by name. No file panels.
    let presetLibrary = PresetLibrary.standard()

    /// The library's preset names, refreshed on save/delete and whenever
    /// the toolbar appears.
    @Published private(set) var savedPresetNames: [String] = []

    func refreshPresetLibrary() {
        savedPresetNames = presetLibrary.names()
    }

    /// Save the current rig into the library under `name` (overwrites a
    /// same-named preset). Returns the saved (sanitized) name.
    @discardableResult
    func savePresetToLibrary(name: String) throws -> String {
        let clean = try PresetLibrary.sanitized(name)
        try presetLibrary.save(capturePreset(name: clean), name: clean)
        refreshPresetLibrary()
        return clean
    }

    /// Load and apply a library preset, returning the decoded document so
    /// the caller can report what landed (`sections()`).
    @discardableResult
    func loadPresetFromLibrary(name: String) throws -> TarabdaarPreset {
        let p = try presetLibrary.load(name: name)
        applyPreset(p)
        return p
    }

    func deletePresetFromLibrary(name: String) throws {
        try presetLibrary.delete(name: name)
        refreshPresetLibrary()
    }

    /// No-op kept for the simulator's call site.
    func handleSimulatorCC(cc: Int, value: Int) {}

    /// Entry point for audition scores' `voiceParam` events, values in each
    /// parameter's natural units. Unknown names log and no-op.
    func setVoiceParam(name: String, value: Double) {
        switch name {
        // Drone buttons: "drone1".."drone3", value > 0.5 = press.
        case "drone1", "drone2", "drone3":
            let i = Int(String(name.dropFirst(5)))! - 1
            audio.setDronePressed(i, value > 0.5)
        // Strum: > 0.5 = press (chord holds), ≤ 0.5 = release — send both.
        case "strum":
            strum(pressed: value > 0.5)
        // Chord bar: value = degree index (octave 0), negative = deselect.
        case "chord":
            pitchPad.setChordSelection(value < 0 ? nil
                : ChordSelection(degree: Int(value), octave: 0))
        // Main instrument: 0 = String, 1 = Tanpura, 2 = Sitar (the sitar arms
        // + builds on first switch — give the score a few seconds).
        case "instrument":
            let all: [AudioEngine.MainInstrument] = [.string, .tanpura, .sitar]
            let i = Int(value.rounded())
            if all.indices.contains(i) { mainInstrument = all[i] }
        case "stringPurity":     applyComposite(slot: 0, value: clamp(value, 0, 1))
        case "stringTarafDecay": applyComposite(slot: 1, value: clamp(value, 0, 1))
        case "stringToneTilt":   applyComposite(slot: 2, value: (clamp(value, -1, 1) + 1) / 2)
        // Composites: the default-slot names above (stringToneTilt takes
        // −1…1) or "composite1".."composite8" with 0…1.
        case let n where n.hasPrefix("composite") && Int(n.dropFirst(9)) != nil:
            applyComposite(slot: Int(n.dropFirst(9))! - 1,
                           value: clamp(value, 0, 1))
        default:
            // Any registry parameter: "string.<key>" or "param.<key>", via the
            // unified setter (the Parameters-tab path: visible, persisted, live).
            for prefix in ["string.", "param."] where name.hasPrefix(prefix) {
                let key = String(name.dropFirst(prefix.count))
                if ParamRegistry.spec(key) != nil {
                    setParamValue(key, value)
                } else {
                    // Not in the registry but possibly a real artifact scalar
                    // — keep the raw override path.
                    stringParams.setAuditionParam(key, value)
                }
                return
            }
            NSLog("Tarabdaar: setVoiceParam unknown name '\(name)'")
        }
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }
}
