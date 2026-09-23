import Foundation
import AVFoundation
import os
import SarangiKit

/// The String voice: an `AVAudioSourceNode` pulling stereo buffers from a
/// `SarangiKit.BowEngine` — the pure-physics bowed gut string whose kernel
/// is the whole instrument (strings + taraf + body + room), rendered straight
/// to the mix. The long-lived `BowControlMapper` controls it; structural
/// changes build a fresh engine off the render thread (`buildEngine`) and
/// publish it via `setEngine`. Native 48 kHz; the mixer input converts.
public extension BowControlMapper {
    /// The idle operating point the mapper seeds (the Setup-tab sliders' initial values).
    static let defaultExpr = 0.251
    static let defaultPress = 0.562
    static let defaultPos = 0.45
    static let defaultTilt = -tiltMinDb / (tiltMaxDb - tiltMinDb)
}

public final class StringVoiceSource {
    /// Live defaults for keys the artifact does not carry (absent = the
    /// bit-exact mono path): the stereo image. Overrides win; also merged
    /// into `StringParamStore`'s baseline.
    public static let liveParamSeeds: [String: Double] = [
        // one width law: the instrument heard from two observation points
        "bow_st_width": 0.2,      // instrument width (two-ear diffuse)
        "bow_rev_width": 0.8,     // room tail L/R decorrelation
    ]

    public let mapper = BowControlMapper()
    public let node: AVAudioSourceNode
    public let modelSR: Double

    private final class State: @unchecked Sendable {
        var lock = os_unfair_lock()
        // render-deadline telemetry (a late callback glitches at the device; a WAV never shows it)
        var maxRenderNs: UInt64 = 0
        var overruns: UInt64 = 0
        var callbacks: UInt64 = 0
    }
    private let state = State()
    /// The published engine and the crossfade out of its predecessor.
    private let fader: EngineCrossfader<BowEngine>

    // MARK: - Live control knobs (the plumbing table)

    /// ONE live String-voice knob: clamp it, cache it, push it. `neutral` is
    /// the value at which the engine sits in its build-time state, so
    /// `setEngine` re-applies only the knobs that differ from it and a fresh
    /// engine stays byte-null. `push` writes the cached value onto an engine;
    /// the multi-field cap reads its siblings through `read`.
    private struct ControlKnob {
        /// Whether `setEngine` re-applies this knob itself.
        enum Reapply {
            /// Push when the cached value differs from `neutral`.
            case whenChanged
            /// Never — a sibling entry pushes this field (the cap pair).
            case viaSibling
        }
        let key: String
        let clamp: (Double) -> Double
        /// The value a fresh engine has built in — the registry's default
        /// through the knob's own clamp (the LP knob maps its 20 kHz
        /// "bypass" default to 0). A knob at neutral is never re-pushed.
        let neutral: Double
        let reapply: Reapply
        let push: (BowEngine, Double, _ read: (String) -> Double) -> Void

        /// Single-field knob.
        init(_ key: String, _ clamp: @escaping (Double) -> Double,
             _ push: @escaping (BowEngine, Double) -> Void) {
            self.key = key; self.clamp = clamp
            self.neutral = clamp(ParamRegistry.spec(key)?.def ?? 0)
            self.reapply = .whenChanged
            self.push = { engine, v, _ in push(engine, v) }
        }
        /// Multi-field knob: pushes the whole group from the cache.
        init(_ key: String, reapply: Reapply,
             _ clamp: @escaping (Double) -> Double,
             group: @escaping (BowEngine, _ read: (String) -> Double) -> Void) {
            self.key = key; self.clamp = clamp
            self.neutral = clamp(ParamRegistry.spec(key)?.def ?? 0)
            self.reapply = reapply
            self.push = { engine, _, read in group(engine, read) }
        }
    }

    private static func unit(_ x: Double) -> Double { min(max(x, 0.0), 1.0) }
    private static func bipolar(_ x: Double) -> Double { min(max(x, -1.0), 1.0) }
    private static func nonNegative(_ x: Double) -> Double { max(x, 0.0) }

    /// The `.live` knobs the source owns, in the order `setEngine` republishes
    /// them. `bow_jt_inject` is internal (the inject-ring arm has no registry
    /// key); everything else is a `ParamRegistry` key.
    private static let controlKnobs: [ControlKnob] = [
        ControlKnob("bow_attack_sharpness", unit, { $0.setAttackSharpness($1) }),
        // top of range = bypass: hand the engine 0 so it restores the exact
        // build-time coefficient (byte-null) — this one rests at 20 kHz
        ControlKnob("bow_jt_lp", { $0 >= 20000 ? 0 : nonNegative($0) },
                    { $0.setJtToneLp(hz: $1) }),
        ControlKnob("bow_jt_hp", nonNegative, { $0.setJtToneHp(hz: $1) }),
        ControlKnob("bow_jt_body", unit, { $0.setJtBody($1) }),
        ControlKnob("bow_jt_couple", unit, { $0.setJtCouple($1) }),
        ControlKnob("bow_jt_damp", unit, { $0.setTarafDamp($1) }),
        ControlKnob("bow_tone_tilt", bipolar, { $0.setToneTilt($1) }),
        // neutral = the calibrated level
        ControlKnob("bow_gain", nonNegative,
                    { $0.setMasterGain($1) }),
        // neutral = the fitted recruitment profile
        ControlKnob("bow_jt_sel", unit,
                    { $0.setTarafSelectivity($1) }),
        // neutral = the fitted graze operating point
        ControlKnob("bow_jt_drive", nonNegative, { $0.setJtDrive($1) }),
        ControlKnob("bow_jt_drive_norm", unit, { $0.setJtDriveNorm($1) }),
        ControlKnob("bow_jt_pulse", reapply: .whenChanged, unit, group: pushJtPulse),
        ControlKnob("bow_jt_dual_lp", { min(max($0, 2000), 20000) },
                    { $0.setJtDualTone(hz: $1) }),
        ControlKnob("bow_jt_dual_select", unit,
                    { $0.setJtDualSelectivity($1) }),
        ControlKnob("bow_jt_bow_bloom", unit,
                    { $0.setJtBowBloom($1) }),
        ControlKnob("bow_jt_dual_mm", unit,
                    { $0.setJtDualDisplacement(mm: $1) }),
        ControlKnob("bow_jt_pluck", reapply: .whenChanged,
                    { min(max($0, 0), 0.3) }, group: pushJtPluck),
        ControlKnob("bow_jt_pluck_decay_ms", reapply: .viaSibling,
                    { min(max($0, 1), 100) }, group: pushJtPluck),
        ControlKnob("bow_jt_pulse_attack_ms", reapply: .viaSibling,
                    { min(max($0, 1), 100) }, group: pushJtPulse),
        ControlKnob("bow_jt_pulse_decay_ms", reapply: .viaSibling,
                    { min(max($0, 10), 2000) }, group: pushJtPulse),
        // neutral = uniform bone across the register
        ControlKnob("bow_jt_ev_reg", bipolar, { $0.setJtEvolveRegister($1) }),
        // neutral = the chromatic bridge's fitted bone
        ControlKnob("bow_jtc_evolve", unit,
                    { $0.setJtEvolveChromatic($1) }),
        // inject-ring arm: 0 = no foreign drive (byte-null)
        ControlKnob("bow_jt_inject", nonNegative, { $0.setJtInjectGain($1) }),
        ControlKnob("bow_bal", bipolar, { $0.setBusBalance($1) }),
        // the cap's two fields are pushed together; hard 0 = off (byte-null)
        ControlKnob("bow_jt_cap", reapply: .whenChanged, unit,
                    group: pushJtCap),
        ControlKnob("bow_jt_cap_ratio", reapply: .viaSibling,
                    { max($0, 0.01) }, group: pushJtCap),
    ]

    private static func pushJtCap(_ engine: BowEngine,
                                  _ read: (String) -> Double) {
        engine.setJtCap(hard: read("bow_jt_cap"),
                        ratio: read("bow_jt_cap_ratio"))
    }

    private static func pushJtPulse(_ engine: BowEngine,
                                    _ read: (String) -> Double) {
        engine.setJtEvolutionPulse(amount: read("bow_jt_pulse"),
                                   attackMs: read("bow_jt_pulse_attack_ms"),
                                   decayMs: read("bow_jt_pulse_decay_ms"))
    }

    private static func pushJtPluck(_ engine: BowEngine,
                                   _ read: (String) -> Double) {
        engine.setJtPluck(drive: read("bow_jt_pluck"),
                          decayMs: read("bow_jt_pluck_decay_ms"))
    }

    private static let knobByKey: [String: ControlKnob] =
        Dictionary(uniqueKeysWithValues: controlKnobs.map { ($0.key, $0) })

    /// Runtime playing state (`.live` params), cached here so a rebuild
    /// republishes it onto the fresh engine. Absent = the knob's neutral,
    /// i.e. the fitted sound.
    ///
    /// Written from every control thread at once (the link queue's tilt
    /// bindings, the main thread's sliders/composites/preset loads, the
    /// evaluator's timers), so every read and write goes under
    /// `cacheLock`; engine pushes read from a snapshot taken inside it.
    private var controlValues: [String: Double] = [:]
    private let cacheLock = NSLock()
    /// Diagnostic snapshot only; absent cached controls resolve to their fitted neutral.
    func diagnosticControls() -> [String: Double] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return Dictionary(uniqueKeysWithValues: Self.controlKnobs.map {
            ($0.key, Self.controlValue($0.key, in: controlValues))
        })
    }
    func diagnosticFX() -> [String: Any] {
        cacheLock.lock()
        let settings = fxSettings
        cacheLock.unlock()
        return Dictionary(uniqueKeysWithValues: FXPoint.allCases.map { point in
            let s = settings[point.rawValue]
            let values: [String: Any] = [
                "eqOn": s.eqOn, "eqAmount": s.eqAmount,
                "eqPoints": s.eqPoints.map { ["hz": $0.hz, "db": $0.db] },
                "revOn": s.revOn, "revKind": s.revKind, "revMix": s.revMix,
                "revSize": s.revSize, "revCutoff": s.revCutoff
            ]
            return (point.keyPrefix, values)
        })
    }
    private var performanceProfile: (tonic: Double, ratios: [Double], gains: [Double], unmatchedGain: Double) = (1, [], [], 1)

    public func setPerformanceProfile(tonic: Double, ratios: [Double], gains: [Double], unmatchedGain: Double) {
        cacheLock.lock()
        performanceProfile = (tonic, ratios, gains, unmatchedGain)
        cacheLock.unlock()
        if let engine = currentEngine() { republishPerformanceProfile(to: engine) }
    }

    private func republishPerformanceProfile(to engine: BowEngine) {
        cacheLock.lock()
        let profile = performanceProfile
        cacheLock.unlock()
        let values = engine.jtRowFreqs.map { hz -> Double in
            guard !profile.gains.isEmpty else { return 1 }
            guard let d = PerformancePitchProfile.nearestDegree(ratio: hz / profile.tonic,
                                                                scale: profile.ratios),
                  profile.gains.indices.contains(d) else { return profile.unmatchedGain }
            return profile.gains[d]
        }
        engine.setPerformanceGains(values)
    }

    /// The cached (clamped) value of one knob, or its neutral, from a snapshot.
    private static func controlValue(_ key: String,
                                     in values: [String: Double]) -> Double {
        values[key] ?? knobByKey[key]?.neutral ?? 0
    }

    /// True when `setControl` owns `key` (the caller can report success even
    /// with no voice armed yet).
    public static func handlesControl(_ key: String) -> Bool {
        knobByKey[key] != nil
    }

    /// Apply one live knob: clamp, cache, push onto the running engine.
    /// False for a key the table does not own. Control-thread safe.
    @discardableResult
    public func setControl(_ key: String, _ value: Double) -> Bool {
        guard let knob = Self.knobByKey[key] else { return false }
        let v = knob.clamp(value)
        cacheLock.lock()
        controlValues[key] = v
        let snapshot = controlValues
        cacheLock.unlock()
        if let engine = currentEngine() {
            knob.push(engine, v) { Self.controlValue($0, in: snapshot) }
        }
        return true
    }

    /// Re-publish every non-neutral knob onto a freshly built engine.
    private func republishControls(to engine: BowEngine) {
        cacheLock.lock()
        let snapshot = controlValues
        cacheLock.unlock()
        for knob in Self.controlKnobs where knob.reapply == .whenChanged {
            let v = Self.controlValue(knob.key, in: snapshot)
            if v != knob.neutral {
                knob.push(engine, v) { Self.controlValue($0, in: snapshot) }
            }
        }
    }

    // Named wrappers for the knobs other files drive directly.

    /// Radiated-jt tone LP corner (`bow_jt_lp`; Hz, ≥ 20 kHz or ≤ 0 = the
    /// build-time state). Control-thread safe.
    public func setJtToneLp(hz: Double) { setControl("bow_jt_lp", hz) }

    /// Taraf damping 0..1 (`bow_jt_damp`): 0 = natural ring, 1 = choked. Control-thread safe.
    public func setTarafDamp(_ amt01: Double) { setControl("bow_jt_damp", amt01) }

    /// Tone tilt -1..1 (`bow_tone_tilt`): bass … flat … treble. Control-thread safe.
    public func setToneTilt(_ t: Double) { setControl("bow_tone_tilt", t) }

    /// Voice→taraf inject-ring arm: 1 while any foreign voice drives the jt
    /// web (levels scale at the taps), else 0. The ring allocates on the first
    /// non-zero push; 0, or armed with nothing written, is byte-null.
    public func setJtInjectGain(_ g: Double) { setControl("bow_jt_inject", g) }

    // MARK: - Telemetry & meters (not knobs)

    /// Rows asleep under the quiescence gate (0 unarmed). Any thread.
    public func jtGateAsleep() -> Int {
        currentEngine()?.jtGateAsleep() ?? 0
    }

    /// Gate probe telemetry (see `BowEngine.jtGateProbe`); nil unarmed. Any thread.
    public func jtGateProbe() -> (asleep: Int, total: Int, ringR: Double,
                                  driveR: Double, droneHot: Bool)? {
        currentEngine()?.jtGateProbe()
    }

    private var busMeterOn = false  // bus volume meter (voice/taraf readout)
    private var scopeOn = false     // Scope tab telemetry (display only)

    /// Arm the kernel's display-only meters (`BowEngine.setScopeArmed`). Control thread.
    public func setScopeArmed(_ on: Bool) {
        scopeOn = on
        currentEngine()?.setScopeArmed(on)
    }

    /// The taraf rows' scope read (`BowEngine.scopeRows`); empty unarmed. Any thread.
    public func scopeRows() -> [BowEngine.ScopeRow] {
        currentEngine()?.scopeRows() ?? []
    }

    /// The played strings' scope read (`BowEngine.scopeSlots`). Any thread.
    public func scopeSlots() -> [BowEngine.ScopeSlot] {
        currentEngine()?.scopeSlots() ?? []
    }

    /// Arm the voice/taraf bus meter (the volume readout); the metered
    /// render is bit-exact (`BusMeterTests`). Control-thread safe.
    public func setBusMeter(_ on: Bool) {
        busMeterOn = on
        currentEngine()?.setBusMeter(on)
    }

    /// The (voice, taraf) bus RMS since the previous call (integrate-and-
    /// dump); (0, 0) unarmed or meter off. One poller. Any thread.
    public func busLevels() -> (voice: Double, taraf: Double) {
        currentEngine()?.busLevels() ?? (0, 0)
    }

    /// Voice→taraf inject write — the ONE render-thread entry point: a
    /// foreign voice's callback appends its mono block to the current
    /// engine's ring (brief state lock). Mid-rebuild it lands on the incoming engine only.
    public func jtInjectWrite(_ x: UnsafePointer<Double>, _ n: Int) {
        fader.current?.jtInjectWrite(x, n)
    }

    // The four FX insert points' settings, cached like the runtime state
    // above (tails restart across a rebuild; settings never snap back).
    // Same writers as `controlValues`, same `cacheLock`.
    private var fxSettings = FXPoint.allCases.map { _ in FXSettings() }

    /// Apply one FX registry parameter and push the whole point: ONE
    /// prefix parse (`fx_<point>_` → `FXPoint`) plus one field write
    /// (`FXSettings.apply`). Every key the registry derives from its
    /// single insert definition lands here; false for an unrecognised
    /// key (`FXRackTests` pins the two sides in sync). Control-thread safe.
    @discardableResult
    public func setFXParam(_ key: String, _ value: Double) -> Bool {
        guard let (point, field) = FXPoint.parse(key: key) else { return false }
        cacheLock.lock()
        let applied = fxSettings[point.rawValue].apply(field: field, value: value)
        let settings = fxSettings[point.rawValue]
        cacheLock.unlock()
        guard applied else { return false }
        currentEngine()?.setFX(point, settings)
        return true
    }

    /// Replace one point's EQ curve (the FX tab's points, normalised) and
    /// push the whole point. Control-thread safe, same cache as the knobs.
    public func setEQCurve(_ point: FXPoint, _ points: [EQPoint]) {
        cacheLock.lock()
        fxSettings[point.rawValue].eqPoints = EQCurve.normalize(points)
        let settings = fxSettings[point.rawValue]
        cacheLock.unlock()
        currentEngine()?.setFX(point, settings)
    }

    private var axisTransforms: [BowAxis: BowAxisTransform] = [:]

    public func setAxisTransforms(_ curves: [String: [BowAxisPoint]]) {
        var transforms: [BowAxis: BowAxisTransform] = [:]
        for axis in BowAxis.allCases {
            transforms[axis] = BowAxisTransform(points: curves[axis.rawValue] ?? BowAxisTransform.identity)
        }
        cacheLock.lock()
        axisTransforms = transforms
        currentEngine()?.setAxisTransforms(transforms)
        cacheLock.unlock()
    }

    public init(sr: Double = Config.sampleRate) {
        modelSR = sr
        let st = state
        let fader = EngineCrossfader<BowEngine>(sr: sr)
        self.fader = fader
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            guard out.count > 0, let l0 = out[0].mData else { return noErr }
            let outL = l0.assumingMemoryBound(to: Float.self)
            let outR = (out.count > 1 ? out[1].mData! : l0)
                .assumingMemoryBound(to: Float.self)
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard fader.render(frames: n, outL: outL, outR: outR) else {
                for ch in 0..<out.count {
                    if let d = out[ch].mData { memset(d, 0, Int(out[ch].mDataByteSize)) }
                }
                return noErr
            }
            let dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
            let budget = UInt64(Double(n) / sr * 0.9e9)
            os_unfair_lock_lock(&st.lock)
            st.callbacks += 1
            if dt > st.maxRenderNs { st.maxRenderNs = dt }
            if dt > budget { st.overruns += 1 }
            os_unfair_lock_unlock(&st.lock)
            return noErr
        }
    }

    /// Zero-allocation variant for the realtime harness (caller-owned buffers).
    func renderForTesting(frames: Int, into l: inout [Float],
                          _ r: inout [Float]) {
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                fader.render(frames: frames, outL: lb.baseAddress!,
                             outR: rb.baseAddress!)
            }
        }
    }

    /// Pull `frames` through the exact audio-callback path (tests / offline).
    func renderForTesting(frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        renderForTesting(frames: frames, into: &l, &r)
        return (l, r)
    }

    /// Publish a freshly built engine (brief lock; control thread). nil
    /// silences the node; the outgoing engine crossfades out.
    public func setEngine(_ engine: BowEngine?, crossfadeMs: Double? = nil) {
        if let engine {
            // re-apply the runtime playing state (a rebuild must not snap to defaults)
            republishControls(to: engine)
            republishPerformanceProfile(to: engine)
            if busMeterOn { engine.setBusMeter(true) }
            if scopeOn { engine.setScopeArmed(true) }
            cacheLock.lock()
            let fx = fxSettings
            cacheLock.unlock()
            for point in FXPoint.allCases where fx[point.rawValue] != FXSettings() {
                engine.setFX(point, fx[point.rawValue])
            }
        }
        cacheLock.lock()
        engine?.setAxisTransforms(axisTransforms)
        fader.publish(engine, crossfadeMs: crossfadeMs ?? EngineCrossfade.defaultMs)
        cacheLock.unlock()
    }

    public var isArmed: Bool { fader.isArmed }

    /// The currently published engine (brief lock); nil unarmed.
    public func currentEngine() -> BowEngine? { fader.current }

    /// Async-jt overload telemetry (dropped drive blocks, flat-filled samples,
    /// FIFO fill, async flag); growing drops = the web misses realtime. Any thread.
    public func jtStats() -> (drops: Double, flat: Double,
                              fill: Double, on: Double)? {
        fader.current?.jtAsyncStats()
    }

    /// Render-deadline telemetry: (worst callback ms since last call, callbacks
    /// over 90% of their budget, total). Resets the max on read.
    public func renderStats() -> (maxMs: Double, overruns: UInt64,
                                  callbacks: UInt64) {
        os_unfair_lock_lock(&state.lock)
        let r = (Double(state.maxRenderNs) / 1e6, state.overruns,
                 state.callbacks)
        state.maxRenderNs = 0
        os_unfair_lock_unlock(&state.lock)
        return r
    }

    /// All notes off (panic / instrument switch); the strings ring out.
    public func reset() {
        mapper.touchAllOff()
    }

    /// Minimum warmup blocks for a stationary bank; publication additionally verifies silence.
    static var settleBlocks = 1

    /// Apply an edit to the RUNNING engine (`BowEngine.setLiveParams`) —
    /// nothing is reset, no pre-roll or crossfade. False when no engine
    /// exists yet. Only valid for `ParamRegistry.inPlaceKeys` (caller's check).
    @discardableResult
    public func applyLiveParams(tonicHz: Double,
                                strings: [ResolvedString],
                                overrides: [String: Double],
                                follower: (gain: Double, t60: Double)? = nil,
                                needsJawariTables: Bool = true) -> Bool {
        guard let engine = currentEngine(),
              var bp = Presets.bowedStringParams() else { return false }
        for (k, v) in overrides { bp.num[k] = v }
        for (k, v) in Self.liveParamSeeds where bp.num[k] == nil {
            bp.num[k] = v
        }
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        // the same builder as the engine's
        var tables = BowTables.buildOpenString(sr: modelSR * Double(osf),
                                               tonic: tonicHz, bp: bp)
        // the jawari tables are the expensive part — only when a jt key moved
        if needsJawariTables {
            let plan = Self.jawariRowPlan(bp: bp, tonicHz: tonicHz,
                                          strings: strings, follower: follower)
            tables.jt = BowTables.buildJawariTables(
                rows: plan.rows, srk: modelSR * Double(osf), bp: bp,
                trackRowIndex: follower != nil ? plan.rows.count - 1 : nil,
                chromatic: plan.chromatic)
        }
        engine.setLiveParams(bp: bp, scalars: tables.scalars, tables: tables)
        return true
    }

    /// The modal-jawari ROW SELECTION for one bridge: rows ≥ `bow_jt_gmin`,
    /// playing-register rows first (one 60 ¢ pitch class each, nearest the
    /// class median), remaining `bow_jt_max` slots by gain. The ONE
    /// implementation for `buildEngine` and the in-place path — a shape
    /// mismatch makes the kernel silently refuse a live jt reload.
    ///
    /// `follower`: the melody-follower string, appended LAST (outside the
    /// selection; built at tonic/2 so the mode allocation covers the low
    /// register — the kernel only trims modes as pitch rises).
    static func jawariRows(bp: BowParams, tonicHz: Double,
                           taraf: [(f: Double, gain: Double, t60: Double)],
                           follower: (gain: Double, t60: Double)? = nil)
        -> [(f: Double, gain: Double, t60: Double)] {
        func cents(_ f: Double) -> Double {
            var c = (1200.0 * log2(f / tonicHz))
                .truncatingRemainder(dividingBy: 1200.0)
            if c < 0 { c += 1200.0 }
            return c
        }
        let gmin = bp.v("bow_jt_gmin", 0.5)
        let jtMax = Int(bp.v("bow_jt_max", 0.0) + 0.5)
        var elig = taraf.filter { $0.gain >= gmin }
        elig.sort { $0.gain != $1.gain ? $0.gain > $1.gain
                                       : $0.f < $1.f }
        let cap = jtMax > 0 ? jtMax : elig.count
        let reg = elig.filter {
            $0.f >= 0.85 * tonicHz && $0.f <= 2.1 * tonicHz
        }
        var groups: [Int: [(f: Double, gain: Double, t60: Double)]] = [:]
        for r in reg {
            let pc = Int((cents(r.f) / 60.0).rounded()) % 20
            groups[pc, default: []].append(r)
        }
        let order = groups.sorted { a, b in
            let ga = a.value.map(\.gain).max() ?? 0
            let gb = b.value.map(\.gain).max() ?? 0
            if ga != gb { return ga > gb }
            return (a.value.map(\.f).min() ?? 0)
                 < (b.value.map(\.f).min() ?? 0)
        }
        var jtRows: [(f: Double, gain: Double, t60: Double)] = []
        for (_, members) in order {
            if jtRows.count >= cap { break }
            let cs = members.map { cents($0.f) }.sorted()
            let med = cs.count % 2 == 1 ? cs[cs.count / 2]
                : 0.5 * (cs[cs.count / 2 - 1] + cs[cs.count / 2])
            let best = members.min { a, b in
                let da = abs(cents(a.f) - med), db = abs(cents(b.f) - med)
                if da != db { return da < db }
                if a.gain != b.gain { return a.gain > b.gain }
                return a.f < b.f
            }!
            jtRows.append(best)
        }
        for r in elig {
            if jtRows.count >= cap { break }
            if !jtRows.contains(where: { $0.f == r.f && $0.gain == r.gain
                                         && $0.t60 == r.t60 }) {
                jtRows.append(r)
            }
        }
        if let fw = follower {
            jtRows.append((f: tonicHz * 0.5, gain: fw.gain, t60: fw.t60))
        }
        return jtRows
    }

    /// The row plan for both bridges (`jawariRows` PER BRIDGE): raga rows,
    /// chromatic rows, then the follower (index `rows.count - 1`). Shared by
    /// `buildEngine` and the in-place path.
    static func jawariRowPlan(bp: BowParams, tonicHz: Double,
                              strings: [ResolvedString],
                              follower: (gain: Double, t60: Double)? = nil)
        -> (rows: [(f: Double, gain: Double, t60: Double)], chromatic: [Bool]) {
        let enabled = strings.filter(\.enabled)
        let raga = enabled.filter { !$0.chromatic }
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        let chrom = enabled.filter(\.chromatic)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        let ragaRows = jawariRows(bp: bp, tonicHz: tonicHz, taraf: raga)
        let chromRows = chrom.isEmpty ? []
            : jawariRows(bp: bp, tonicHz: tonicHz, taraf: chrom)
        var rows = ragaRows + chromRows
        var flags = [Bool](repeating: false, count: ragaRows.count)
            + [Bool](repeating: true, count: chromRows.count)
        if let fw = follower {
            rows.append((f: tonicHz * 0.5, gain: fw.gain, t60: fw.t60))
            flags.append(true)
        }
        return (rows, flags)
    }

    public static func buildEngine(tonicHz: Double,
                                   strings: [ResolvedString],
                                   mapper: BowControlMapper,
                                   sr: Double = Config.sampleRate,
                                   overrides: [String: Double] = [:],
                                   follower: (gain: Double, t60: Double)? = nil)
        -> BowEngine? {
        guard var bp = Presets.bowedStringParams() else { return nil }
        for (k, v) in overrides { bp.num[k] = v }
        // live seeds for keys the artifact doesn't carry; overrides win
        for (k, v) in liveParamSeeds where bp.num[k] == nil {
            bp.num[k] = v
        }
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonicHz, bp: bp)
        // the shared row plan; the follower is the LAST row, marked for live retune
        let plan = jawariRowPlan(bp: bp, tonicHz: tonicHz, strings: strings,
                                 follower: follower)
        tables.jt = BowTables.buildJawariTables(
            rows: plan.rows, srk: sr * Double(osf), bp: bp,
            trackRowIndex: follower != nil ? plan.rows.count - 1 : nil,
            chromatic: plan.chromatic)
        tables.jt?.dualRows = plan.rows.indices.filter {
            !plan.chromatic[$0] && (follower == nil || $0 != plan.rows.count - 1)
        }
        bp.num.removeValue(forKey: "bow_jt_dual_row")
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               // width-decorrelated wet pair (cancels in L+R)
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: bp.v("bow_rev_predelay", 15.0),
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: bp.v("bow_rev_width", 0.6),
                               maxPoly: Int(bp.v("bow_live_poly", 8.0).rounded()))
        guard Set(tables.jt?.dualRows ?? []) == engine.jtDualRows else { return nil }
        // trim = the fitted calibration; `bow_gain` is re-applied by `setEngine`
        engine.outGain = bp.v("bow_live_trim", 0.05)
        engine.seedLiveGains()   // ramp starts from the built values
        // Use a quiet control snapshot during setup; held touches remain on
        // the mapper and mount on the first published render. A failed solve
        // retains the five-block damped warmup. Never publish a noisy build.
        guard engine.settleForPublication(minimumBlocks: settleBlocks) != nil else { return nil }
        return engine
    }
}
