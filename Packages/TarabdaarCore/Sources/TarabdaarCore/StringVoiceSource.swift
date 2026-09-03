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

    // Runtime playing state (`.live` params), cached here so a rebuild
    // republishes it onto the fresh engine. Defaults = the fitted sound.
    private var jtLpHz = 0.0
    private var jtHpHz = 0.0
    private var jtBody = 0.0
    private var jtGov = 0.0
    private var tarafDamp = 0.0
    private var toneTilt = 0.0
    private var masterGain = 1.0  // bow_gain neutral = the calibrated level
    private var tarafSel = 0.5    // bow_jt_sel neutral = the fitted profile
    private var jtEvolve = 0.5    // bow_jt_evolve neutral = fitted bone
    private var jtEvolveReg = 0.0 // bow_jt_ev_reg neutral = uniform bone
    private var jtEvolveChrom = 0.5 // bow_jtc_evolve neutral = the chromatic bridge's fitted bone
    private var twang = 0.0       // bow_twang 0 = plain bridge (byte-null)
    private var jtInjectGain = 0.0  // inject-ring arm: 0 = no foreign drive (byte-null)
    private var busMeterOn = false  // bus volume meter (voice/taraf readout)
    private var scopeOn = false     // Scope tab telemetry (display only)
    private var busBalance = 0.0    // bow_bal: 0 = neutral (byte-null)
    // bow_jt_comp_*: taraf-bus compressor (thresh 0 = off, byte-null)
    private var jtComp = (thresh: 0.0, ratio: 4.0, atkMs: 5.0, relMs: 150.0)
    // bow_jt_cap*: voice-relative taraf cap (hard 0 = off, byte-null);
    // bus 0 = per string … 1 = per taraf
    private var jtCap = (hard: 0.0, ratio: 1.0, bus: 0.0)

    /// Radiated-jt tone LP corner (`bow_jt_lp`; Hz, <= 0 = build-time state). Control-thread safe.
    public func setJtToneLp(hz: Double) {
        jtLpHz = max(hz, 0.0)
        currentEngine()?.setJtToneLp(hz: jtLpHz)
    }

    /// Radiated-jt tone HP corner (`bow_jt_hp`; Hz, <= 0 = bypass). Control-thread safe.
    public func setJtToneHp(hz: Double) {
        jtHpHz = max(hz, 0.0)
        currentEngine()?.setJtToneHp(hz: jtHpHz)
    }

    /// Taraf through the voice's body bank (`bow_jt_body`; 0 = bypass). Control-thread safe.
    public func setJtBody(_ mix01: Double) {
        jtBody = min(max(mix01, 0.0), 1.0)
        currentEngine()?.setJtBody(jtBody)
    }

    /// Taraf charge governor 0..1 (`bow_jt_gov`): 0 = raw physics, 1 = each
    /// row's ring saturates at its single-strike level. Control-thread safe.
    public func setJtGov(_ amt01: Double) {
        jtGov = min(max(amt01, 0.0), 1.0)
        currentEngine()?.setJtGov(jtGov)
    }

    /// Rows asleep under the quiescence gate (0 unarmed). Any thread.
    public func jtGateAsleep() -> Int {
        currentEngine()?.jtGateAsleep() ?? 0
    }

    /// Gate probe telemetry (see `BowEngine.jtGateProbe`); nil unarmed. Any thread.
    public func jtGateProbe() -> (asleep: Int, total: Int, ringR: Double,
                                  driveR: Double, droneHot: Bool)? {
        currentEngine()?.jtGateProbe()
    }

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

    /// Master gain (`bow_gain`): the performance volume of the whole radiated
    /// instrument, ramped (~25 ms) over the fitted trim; 1 = calibrated. Control-thread safe.
    public func setMasterGain(_ g: Double) {
        masterGain = max(g, 0.0)
        currentEngine()?.setMasterGain(masterGain)
    }

    /// Taraf damping 0..1 (`bow_jt_damp`): 0 = natural ring, 1 = choked. Control-thread safe.
    public func setTarafDamp(_ amt01: Double) {
        tarafDamp = min(max(amt01, 0.0), 1.0)
        currentEngine()?.setTarafDamp(tarafDamp)
    }

    /// Tone tilt -1..1 (`bow_tone_tilt`): bass … flat … treble. Control-thread safe.
    public func setToneTilt(_ t: Double) {
        toneTilt = min(max(t, -1.0), 1.0)
        currentEngine()?.setToneTilt(toneTilt)
    }

    /// Taraf recruitment 0..1 (`bow_jt_sel`): 0 = kin-only, 0.5 = fitted,
    /// 1 = every row equal; loudness is compensated. Control-thread safe.
    public func setTarafSelectivity(_ s01: Double) {
        tarafSel = min(max(s01, 0.0), 1.0)
        currentEngine()?.setTarafSelectivity(tarafSel)
    }

    /// Harmonic evolution 0…1 (`bow_jt_evolve`): a kernel-slewed bone offset. Control-thread safe.
    public func setJtEvolve(_ e01: Double) {
        jtEvolve = min(max(e01, 0.0), 1.0)
        currentEngine()?.setJtEvolve(jtEvolve)
    }

    /// Evolution register tilt (`bow_jt_ev_reg`): per-row bone offsets by
    /// octave from the tonic (+ blooms the low rows). Control-thread safe.
    public func setJtEvolveReg(_ reg: Double) {
        jtEvolveReg = min(max(reg, -1.0), 1.0)
        currentEngine()?.setJtEvolveRegister(jtEvolveReg)
    }

    /// The chromatic bridge's harmonic evolution 0…1 (`bow_jtc_evolve`). Control-thread safe.
    public func setJtEvolveChromatic(_ e01: Double) {
        jtEvolveChrom = min(max(e01, 0.0), 1.0)
        currentEngine()?.setJtEvolveChromatic(jtEvolveChrom)
    }

    /// Sitar twang 0…1 (`bow_twang`): the played strings' grazing bridge fold; 0 = byte-null.
    public func setTwang(_ amt01: Double) {
        twang = min(max(amt01, 0.0), 1.0)
        currentEngine()?.setTwang(twang)
    }

    /// Voice→taraf inject-ring arm: 1 while any foreign voice drives the jt
    /// web (levels scale at the taps), else 0. The ring allocates on the first
    /// non-zero push; 0, or armed with nothing written, is byte-null.
    public func setJtInjectGain(_ g: Double) {
        jtInjectGain = max(g, 0.0)
        currentEngine()?.setJtInjectGain(jtInjectGain)
    }

    /// Voice↔taraf balance (`bow_bal`): −1 voice only … 0 neutral (byte-null)
    /// … +1 taraf only; an attenuator pair, never a boost.
    public func setBusBalance(_ b: Double) {
        busBalance = min(max(b, -1.0), 1.0)
        currentEngine()?.setBusBalance(busBalance)
    }

    /// One field of the taraf-bus compressor (`bow_jt_comp_*`); the set is
    /// pushed whole on every edit. Threshold 0 = off, byte-null.
    public enum JtCompField { case thresh, ratio, atkMs, relMs }
    public func setJtCompParam(_ field: JtCompField, _ value: Double) {
        switch field {
        case .thresh: jtComp.thresh = max(value, 0.0)
        case .ratio:  jtComp.ratio = max(value, 1.0)
        case .atkMs:  jtComp.atkMs = max(value, 0.0)
        case .relMs:  jtComp.relMs = max(value, 1.0)
        }
        pushJtComp(to: currentEngine())
    }

    private func pushJtComp(to engine: BowEngine?) {
        engine?.setJtComp(thresh: jtComp.thresh, ratio: jtComp.ratio,
                          atkMs: jtComp.atkMs, relMs: jtComp.relMs)
    }

    /// One field of the voice-relative taraf cap (`bow_jt_cap*`): each row
    /// held at or below `ratio` × the voice bus's decaying peak, per string
    /// (`bus` 0) … per taraf (1). Pushed whole. Hard 0 = off, byte-null.
    public enum JtCapField { case hard, ratio, bus }
    public func setJtCapParam(_ field: JtCapField, _ value: Double) {
        switch field {
        case .hard:  jtCap.hard = min(max(value, 0.0), 1.0)
        case .ratio: jtCap.ratio = max(value, 0.01)
        case .bus:   jtCap.bus = min(max(value, 0.0), 1.0)
        }
        pushJtCap(to: currentEngine())
    }

    private func pushJtCap(to engine: BowEngine?) {
        engine?.setJtCap(hard: jtCap.hard, ratio: jtCap.ratio,
                         bus: jtCap.bus)
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

    /// Apply one FX registry parameter (`fx_<point>_<field>`) and push the
    /// whole point. False for an unrecognised key. Control-thread safe.
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
            if jtLpHz > 0 { engine.setJtToneLp(hz: jtLpHz) }
            if jtHpHz > 0 { engine.setJtToneHp(hz: jtHpHz) }
            if jtBody > 0 { engine.setJtBody(jtBody) }
            if jtGov > 0 { engine.setJtGov(jtGov) }
            if tarafDamp != 0 { engine.setTarafDamp(tarafDamp) }
            if toneTilt != 0 { engine.setToneTilt(toneTilt) }
            if masterGain != 1.0 { engine.setMasterGain(masterGain) }
            if tarafSel != 0.5 { engine.setTarafSelectivity(tarafSel) }
            if jtEvolve != 0.5 { engine.setJtEvolve(jtEvolve) }
            if jtEvolveReg != 0 { engine.setJtEvolveRegister(jtEvolveReg) }
            if jtEvolveChrom != 0.5 { engine.setJtEvolveChromatic(jtEvolveChrom) }
            if twang > 0 { engine.setTwang(twang) }
            if jtInjectGain > 0 { engine.setJtInjectGain(jtInjectGain) }
            if busMeterOn { engine.setBusMeter(true) }
            if scopeOn { engine.setScopeArmed(true) }
            if busBalance != 0 { engine.setBusBalance(busBalance) }
            if jtComp.thresh > 0 { pushJtComp(to: engine) }
            if jtCap.hard > 0 { pushJtCap(to: engine) }
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
        let taraf = strings.filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        // the same builder as the engine's. `taraf` MUST be passed: the
        // coupling web derives a passive scalar from its row count, and a
        // mismatched scalar vector must never reach the armed kernel
        var tables = BowTables.buildOpenString(sr: modelSR * Double(osf),
                                               tonic: tonicHz, bp: bp,
                                               taraf: taraf)
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
        // taraf tuning rows: the modal-jawari block radiates them; with
        // `bow_cpl_z` > 0 they also load the passive junction
        let taraf = strings.filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonicHz, bp: bp,
                                               taraf: taraf)
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
