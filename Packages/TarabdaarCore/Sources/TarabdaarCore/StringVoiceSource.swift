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
        var engine: BowEngine?
        /// The engine being crossfaded out (keeps rendering so its ring decays).
        var fading: BowEngine?
        var fadePos = 0
        var fadeLen = 0
        let maxFrames = 4096
        var bufL: [Double]
        var bufR: [Double]
        /// Second buffer pair, used only while a crossfade is running.
        var fadeL: [Double]
        var fadeR: [Double]
        // render-deadline telemetry (a late callback glitches at the device; a WAV never shows it)
        var maxRenderNs: UInt64 = 0
        var overruns: UInt64 = 0
        var callbacks: UInt64 = 0
        init() {
            bufL = [Double](repeating: 0, count: maxFrames)
            bufR = [Double](repeating: 0, count: maxFrames)
            fadeL = [Double](repeating: 0, count: maxFrames)
            fadeR = [Double](repeating: 0, count: maxFrames)
        }

        /// Render `frames`, equal-power crossfaded with the outgoing engine
        /// while a fade runs. The audio callback's body; tests share it.
        func renderMix(engine: BowEngine, fading: BowEngine?, frames n: Int,
                       outL: UnsafeMutablePointer<Float>,
                       outR: UnsafeMutablePointer<Float>) {
            var done = 0
            while done < n {
                let m = min(maxFrames, n - done)
                bufL.withUnsafeMutableBufferPointer { lb in
                    bufR.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                if let fading {
                    // 2x voice CPU for the fade window only.
                    fadeL.withUnsafeMutableBufferPointer { lb in
                        fadeR.withUnsafeMutableBufferPointer { rb in
                            fading.render(frames: m, outL: lb.baseAddress!,
                                          outR: rb.baseAddress!)
                        }
                    }
                    let len = max(fadeLen, 1)
                    for i in 0..<m {
                        let t = min(Double(fadePos + i) / Double(len), 1.0)
                        let gIn = sin(t * Double.pi / 2)
                        let gOut = cos(t * Double.pi / 2)
                        outL[done + i] = Float(bufL[i] * gIn + fadeL[i] * gOut)
                        outR[done + i] = Float(bufR[i] * gIn + fadeR[i] * gOut)
                    }
                    fadePos += m
                } else {
                    for i in 0..<m {
                        outL[done + i] = Float(bufL[i])
                        outR[done + i] = Float(bufR[i])
                    }
                }
                done += m
            }
            if fading != nil, fadePos >= fadeLen {
                // Fade finished. `recentEngines` still holds the object, so
                // this never deallocates on the audio thread.
                os_unfair_lock_lock(&lock)
                if self.fading === fading { self.fading = nil }
                os_unfair_lock_unlock(&lock)
            }
        }
    }
    private let state = State()
    // strong refs keep swapped-out engines alive past any in-flight buffer
    private var recentEngines: [BowEngine] = []

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
        let neutral: Double
        let reapply: Reapply
        let push: (BowEngine, Double, _ read: (String) -> Double) -> Void

        /// Single-field knob.
        init(_ key: String, neutral: Double = 0,
             _ clamp: @escaping (Double) -> Double,
             _ push: @escaping (BowEngine, Double) -> Void) {
            self.key = key; self.neutral = neutral; self.clamp = clamp
            self.reapply = .whenChanged
            self.push = { engine, v, _ in push(engine, v) }
        }
        /// Multi-field knob: pushes the whole group from the cache.
        init(_ key: String, neutral: Double, reapply: Reapply,
             _ clamp: @escaping (Double) -> Double,
             group: @escaping (BowEngine, _ read: (String) -> Double) -> Void) {
            self.key = key; self.neutral = neutral; self.clamp = clamp
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
        // top of range = bypass: hand the engine 0 so it restores the exact
        // build-time coefficient (byte-null) — this one rests at 20 kHz
        ControlKnob("bow_jt_lp", { $0 >= 20000 ? 0 : nonNegative($0) },
                    { $0.setJtToneLp(hz: $1) }),
        ControlKnob("bow_jt_hp", nonNegative, { $0.setJtToneHp(hz: $1) }),
        ControlKnob("bow_jt_body", unit, { $0.setJtBody($1) }),
        ControlKnob("bow_jt_drive_term", unit, { $0.setJtDriveTerm($1) }),
        ControlKnob("bow_jt_couple", nonNegative, { $0.setJtCouple($1) }),
        ControlKnob("bow_jt_damp", unit, { $0.setTarafDamp($1) }),
        ControlKnob("bow_tone_tilt", bipolar, { $0.setToneTilt($1) }),
        // neutral = the calibrated level
        ControlKnob("bow_gain", neutral: 1.0, nonNegative,
                    { $0.setMasterGain($1) }),
        // neutral = the fitted recruitment profile
        ControlKnob("bow_jt_sel", neutral: 0.5, unit,
                    { $0.setTarafSelectivity($1) }),
        // neutral = the fitted bone
        ControlKnob("bow_jt_evolve", neutral: 0.5, unit,
                    { $0.setJtEvolve($1) }),
        // neutral = uniform bone across the register
        ControlKnob("bow_jt_ev_reg", bipolar, { $0.setJtEvolveRegister($1) }),
        // neutral = the chromatic bridge's fitted bone
        ControlKnob("bow_jtc_evolve", neutral: 0.5, unit,
                    { $0.setJtEvolveChromatic($1) }),
        // inject-ring arm: 0 = no foreign drive (byte-null)
        ControlKnob("bow_jt_inject", nonNegative, { $0.setJtInjectGain($1) }),
        ControlKnob("bow_bal", bipolar, { $0.setBusBalance($1) }),
        // the cap's two fields are pushed together; hard 0 = off (byte-null)
        ControlKnob("bow_jt_cap", neutral: 0, reapply: .whenChanged, unit,
                    group: pushJtCap),
        ControlKnob("bow_jt_cap_ratio", neutral: 1.0, reapply: .viaSibling,
                    { max($0, 0.01) }, group: pushJtCap),
    ]

    private static func pushJtCap(_ engine: BowEngine,
                                  _ read: (String) -> Double) {
        engine.setJtCap(hard: read("bow_jt_cap"),
                        ratio: read("bow_jt_cap_ratio"))
    }

    private static let knobByKey: [String: ControlKnob] =
        Dictionary(uniqueKeysWithValues: controlKnobs.map { ($0.key, $0) })

    /// Runtime playing state (`.live` params), cached here so a rebuild
    /// republishes it onto the fresh engine. Absent = the knob's neutral,
    /// i.e. the fitted sound.
    private var controlValues: [String: Double] = [:]

    /// The cached (clamped) value of one knob, or its neutral.
    private func controlValue(_ key: String) -> Double {
        controlValues[key] ?? Self.knobByKey[key]?.neutral ?? 0
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
        controlValues[key] = v
        if let engine = currentEngine() {
            knob.push(engine, v, controlValue)
        }
        return true
    }

    /// Re-publish every non-neutral knob onto a freshly built engine.
    private func republishControls(to engine: BowEngine) {
        for knob in Self.controlKnobs where knob.reapply == .whenChanged {
            let v = controlValue(knob.key)
            if v != knob.neutral { knob.push(engine, v, controlValue) }
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
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        os_unfair_lock_unlock(&state.lock)
        engine?.jtInjectWrite(x, n)
    }

    // The four FX insert points' settings, cached like the runtime state
    // above (tails restart across a rebuild; settings never snap back).
    private var fxSettings = FXPoint.allCases.map { _ in FXSettings() }

    /// Apply one FX registry parameter and push the whole point: ONE
    /// prefix parse (`fx_<point>_` → `FXPoint`) plus one field write
    /// (`FXSettings.apply`). Every key the registry derives from its
    /// single insert definition lands here; false for an unrecognised
    /// key (`FXRackTests` pins the two sides in sync). Control-thread safe.
    @discardableResult
    public func setFXParam(_ key: String, _ value: Double) -> Bool {
        guard let (point, field) = FXPoint.parse(key: key),
              fxSettings[point.rawValue].apply(field: field, value: value)
        else { return false }
        currentEngine()?.setFX(point, fxSettings[point.rawValue])
        return true
    }

    public init(sr: Double = 48000) {
        modelSR = sr
        let st = state
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            os_unfair_lock_lock(&st.lock)
            let engine = st.engine
            let fading = st.fading
            os_unfair_lock_unlock(&st.lock)
            guard let engine, out.count > 0, let l0 = out[0].mData else {
                for ch in 0..<out.count {
                    if let d = out[ch].mData { memset(d, 0, Int(out[ch].mDataByteSize)) }
                }
                return noErr
            }
            let outL = l0.assumingMemoryBound(to: Float.self)
            let outR = (out.count > 1 ? out[1].mData! : l0)
                .assumingMemoryBound(to: Float.self)
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            st.renderMix(engine: engine, fading: fading, frames: n,
                         outL: outL, outR: outR)
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
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        let fading = state.fading
        os_unfair_lock_unlock(&state.lock)
        guard let engine else { return }
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                state.renderMix(engine: engine, fading: fading, frames: frames,
                                outL: lb.baseAddress!, outR: rb.baseAddress!)
            }
        }
    }

    /// Pull `frames` through the exact audio-callback path (tests / offline).
    func renderForTesting(frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        let fading = state.fading
        os_unfair_lock_unlock(&state.lock)
        guard let engine else { return (l, r) }
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                state.renderMix(engine: engine, fading: fading, frames: frames,
                                outL: lb.baseAddress!, outR: rb.baseAddress!)
            }
        }
        return (l, r)
    }

    /// Crossfade length when swapping engines (a fresh engine has no ringing
    /// state, so the outgoing one fades out instead of being cut).
    public static let engineCrossfadeMs = 300.0

    /// Publish a freshly built engine (brief lock; control thread). nil
    /// silences the node. Swapped-out engines are retained so an in-flight
    /// buffer never reads a freed one; the outgoing one crossfades out.
    public func setEngine(_ engine: BowEngine?, crossfadeMs: Double? = nil) {
        if let engine {
            // deep enough that a fading engine is never freed under the audio thread
            recentEngines.append(engine)
            if recentEngines.count > 8 { recentEngines.removeFirst() }
            // re-apply the runtime playing state (a rebuild must not snap to defaults)
            republishControls(to: engine)
            if busMeterOn { engine.setBusMeter(true) }
            if scopeOn { engine.setScopeArmed(true) }
            for point in FXPoint.allCases
                where fxSettings[point.rawValue] != FXSettings() {
                engine.setFX(point, fxSettings[point.rawValue])
            }
        }
        let ms = crossfadeMs ?? Self.engineCrossfadeMs
        os_unfair_lock_lock(&state.lock)
        let outgoing = state.engine
        // a swap mid-fade restarts the fade from the audible engine
        if engine != nil, let outgoing, ms > 0 {
            state.fading = outgoing
            state.fadeLen = max(1, Int(ms * 0.001 * modelSR))
            state.fadePos = 0
        } else {
            state.fading = nil
            state.fadeLen = 0
            state.fadePos = 0
        }
        state.engine = engine
        os_unfair_lock_unlock(&state.lock)
    }

    public var isArmed: Bool {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.engine != nil
    }

    /// The currently published engine (brief lock); nil unarmed.
    public func currentEngine() -> BowEngine? {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.engine
    }

    /// Async-jt overload telemetry (dropped drive blocks, flat-filled samples,
    /// FIFO fill, async flag); growing drops = the web misses realtime. Any thread.
    public func jtStats() -> (drops: Double, flat: Double,
                              fill: Double, on: Double)? {
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        os_unfair_lock_unlock(&state.lock)
        return engine?.jtAsyncStats()
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
        mapper.midi(0xB0, 123, 0)
    }

    /// Settle pre-roll blocks (4096 frames each) rendered and discarded before
    /// publish — the dominant rebuild cost; the minimum that keeps the publish
    /// peak under −80 dBFS (`RebuildCostTests`).
    static var settleBlocks = 5

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
            flags.append(false)
        }
        return (rows, flags)
    }

    public static func buildEngine(tonicHz: Double,
                                   strings: [ResolvedString],
                                   mapper: BowControlMapper,
                                   sr: Double = 48000,
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
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               // width-decorrelated wet pair (cancels in L+R)
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: bp.v("bow_rev_predelay", 15.0),
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: bp.v("bow_rev_width", 0.6),
                               maxPoly: Int(bp.v("bow_live_poly", 8.0).rounded()))
        // trim = the fitted calibration; `bow_gain` is re-applied by `setEngine`
        engine.outGain = bp.v("bow_live_trim", 0.05)
        engine.seedLiveGains()   // ramp starts from the built values
        // SETTLE PRE-ROLL: a fresh jt web relaxes off the builder's q0 with
        // an audible chime, so `settleBlocks` blocks are rendered and
        // discarded here (off-main; also primes the async-jt FIFO). NOT in
        // BowEngine.init — parity fixtures need renders from t = 0. The
        // taraf is choked through the pre-roll so the contact settles to its
        // discrete equilibrium; the ring is restored exactly (0 = byte-null).
        engine.setJtSettleDamp(t60: 0.05)
        var prL = [Double](repeating: 0, count: 4096)
        var prR = [Double](repeating: 0, count: 4096)
        for _ in 0..<settleBlocks {
            prL.withUnsafeMutableBufferPointer { lb in
                prR.withUnsafeMutableBufferPointer { rb in
                    engine.render(frames: 4096, outL: lb.baseAddress!,
                                  outR: rb.baseAddress!)
                }
            }
        }
        engine.setJtSettleDamp(t60: 0)   // natural ring back (byte-null)
        return engine
    }
}
