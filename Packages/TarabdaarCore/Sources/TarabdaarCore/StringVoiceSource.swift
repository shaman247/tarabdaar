import Foundation
import AVFoundation
import os
import SarangiKit

/// The playable STRING-PHYSICS sarangi: an `AVAudioSourceNode` pulling stereo
/// buffers from a `SarangiKit.BowEngine` — the generic pure-physics bowed gut
/// string (the C friction kernel at 96 kHz, formula body, modal-jawari taraf
/// fused in-kernel, analytic Schelleng press envelope, self-calibrated
/// intonation) that upstream Sarangi Live ships as its ONE live instrument
/// (the 2026-07-21 String-only simplification). Replaces the v57
/// `SarangiModelSource` + coupled-network pair as Tarabdaar's "Sarangi (model)"
/// voice: the kernel IS the whole instrument (played strings + taraf +
/// body + radiation + room), so it renders STRAIGHT to the mix (`node →
/// symGain → mainMixerNode`).
///
/// Controlled by the long-lived `BowControlMapper` (same CC map as the v57
/// voice: CC11 expr · CC1 press · CC74 pos · CC2/75 tilt · per-channel MPE
/// pitch bend — the Tarabdaar extension in `BowControls.swift`). Structural
/// changes (tonic/tarab strings/param overrides) build a fresh `BowEngine`
/// OFF the render thread (`buildEngine`) and publish it via `setEngine`; the
/// mapper keeps held notes/axes across the swap. Runs at the artifact's
/// native 48 kHz; the receiving mixer input converts to the engine rate.
public extension BowControlMapper {
    /// The idle operating point (pair-3 gated medians — the same values the
    /// mapper's init seeds): what the Setup-tab axis sliders initialize to.
    static let defaultExpr = 0.251
    static let defaultPress = 0.562
    static let defaultPos = 0.45
    static let defaultTilt = -tiltMinDb / (tiltMaxDb - tiltMinDb)
}

public final class StringVoiceSource {
    /// Tarabdaar live-default seeds for `bowed_string.json` keys the artifact
    /// does NOT carry (2026-07-23 stereo rev): the physically-derived
    /// stereo image (taraf/jt/played pans across the bridge — see
    /// `BowEngine`'s side path) and the width-decorrelated room. Applied in
    /// `buildEngine` under any user override; ALSO merged into
    /// `StringParamStore`'s baseline so the editor shows/resets to these
    /// and an override landing back on a seed value is dropped.
    public static let liveParamSeeds: [String: Double] = [
        // 2026-08-01 coherence rev: the 0.7 spread read as an
        // accompanying chorus around a centred soloist — a real sarangi
        // is ONE small radiator whose width comes from the room, so the
        // source halo narrows (0.7 → 0.2) and the room's decorrelated
        // width carries the image (0.6 → 0.8) instead.
        // 2026-08-01 WIDTH UNIFICATION: one law — the whole instrument
        // heard from two observation points (the kernel's diffuse-field
        // difference bank on voice + wash). The per-source pans
        // (`bow_st_spread` svara staging, `bow_st_played` noise
        // positions) are legacy staging, unseeded = disarmed, kept in
        // the registry for A/B; machinery removal pending the ears
        // check. Coherence falls with frequency like a real
        // instrument's; the image never leans.
        "bow_st_width": 0.2,      // instrument width (two-ear diffuse)
        "bow_rev_width": 0.8,     // room tail L/R decorrelation
    ]

    public let mapper = BowControlMapper()
    public let node: AVAudioSourceNode
    public let modelSR: Double

    private final class State: @unchecked Sendable {
        var lock = os_unfair_lock()
        var engine: BowEngine?
        /// The engine being CROSSFADED OUT (2026-07-24). A fresh engine
        /// starts with empty string/taraf/room state, so an abrupt swap
        /// silences whatever was ringing (measured: 4.9% of a taraf +
        /// room tail survives). Keeping the outgoing engine rendering for
        /// the fade window lets its tail decay instead of vanishing.
        var fading: BowEngine?
        var fadePos = 0
        var fadeLen = 0
        let maxFrames = 4096
        var bufL: [Double]
        var bufR: [Double]
        /// Second buffer pair, used only while a crossfade is running.
        var fadeL: [Double]
        var fadeR: [Double]
        // render-deadline telemetry: the audition tap records what the
        // engine renders, so a LATE callback glitches at the device while
        // the WAV stays clean — this is the only way to see it
        var maxRenderNs: UInt64 = 0
        var overruns: UInt64 = 0
        var callbacks: UInt64 = 0
        init() {
            bufL = [Double](repeating: 0, count: maxFrames)
            bufR = [Double](repeating: 0, count: maxFrames)
            fadeL = [Double](repeating: 0, count: maxFrames)
            fadeR = [Double](repeating: 0, count: maxFrames)
        }

        /// Render `frames` of the current engine, equal-power crossfaded
        /// with the outgoing one while a fade is running. The audio
        /// callback's whole body — factored out so tests exercise the
        /// identical path.
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
                    // Render the outgoing engine too and equal-power mix,
                    // so its ring decays across the window instead of
                    // being cut off. Costs 2x voice CPU for the fade only.
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
                // Fade finished — drop the reference. The engine object
                // stays alive in `recentEngines` (control-thread owned),
                // so this never deallocates on the audio thread.
                os_unfair_lock_lock(&lock)
                if self.fading === fading { self.fading = nil }
                os_unfair_lock_unlock(&lock)
            }
        }
    }
    private let state = State()
    // strong refs keep swapped-out engines alive past any in-flight buffer
    private var recentEngines: [BowEngine] = []

    // Runtime base parameters (2026-07-24 composite rework): the last
    // values pushed by composite parameters, kept here — the long-lived
    // side — so a structural rebuild (tonic/scale/drone change)
    // republishes them onto the fresh engine. Defaults = the fitted
    // sound: build-time jt tone LP, no extra damping, flat tone tilt.
    private var jtLpHz = 0.0
    private var jtHpHz = 0.0
    private var jtBody = 0.0
    private var jtGov = 0.0
    private var tarafDamp = 0.0
    private var toneTilt = 0.0
    private var masterGain = 1.0  // bow_gain neutral = the calibrated level
    private var tarafSel = 0.5    // bow_jt_sel neutral = the fitted profile
    private var jtEvolve = 0.5    // bow_jt_evolve neutral = fitted bone
    private var twang = 0.0       // bow_twang 0 = plain bridge (byte-null)
    private var jtInjectGain = 0.0  // inject-ring arm: 0 = no foreign drive (byte-null)

    /// Radiated-jt tone LP corner (`bow_jt_lp`, runtime path; Hz,
    /// <= 0 = the build-time state). Control-thread safe.
    public func setJtToneLp(hz: Double) {
        jtLpHz = max(hz, 0.0)
        currentEngine()?.setJtToneLp(hz: jtLpHz)
    }

    /// Radiated-jt tone HP corner (`bow_jt_hp`; Hz, <= 0 = bypass) —
    /// the jawari-formant voicing. Control-thread safe.
    public func setJtToneHp(hz: Double) {
        jtHpHz = max(hz, 0.0)
        currentEngine()?.setJtToneHp(hz: jtHpHz)
    }

    /// Radiated-jt body-radiation mix (`bow_jt_body`; 0 = bypass) — the
    /// taraf through the voice's own body bank. Control-thread safe.
    public func setJtBody(_ mix01: Double) {
        jtBody = min(max(mix01, 0.0), 1.0)
        currentEngine()?.setJtBody(jtBody)
    }

    /// Taraf charge governor 0..1 (`bow_jt_gov`): 0 = raw physics, 1 =
    /// each row's ring saturates at its single-strike level (the phrase
    /// pile-up in the long-t60 anchors is shed at the bridge drive).
    /// Control-thread safe.
    public func setJtGov(_ amt01: Double) {
        jtGov = min(max(amt01, 0.0), 1.0)
        currentEngine()?.setJtGov(jtGov)
    }

    /// Rows currently asleep under the quiescence gate (always on at
    /// build via the `bow_jt_gate` bp scalar; 0 with the voice unarmed
    /// or the gate override-disabled) — telemetry/tests. Safe from any
    /// thread.
    public func jtGateAsleep() -> Int {
        currentEngine()?.jtGateAsleep() ?? 0
    }

    /// Gate probe telemetry (see `BowEngine.jtGateProbe`). Safe from any
    /// thread; nil with the voice unarmed.
    public func jtGateProbe() -> (asleep: Int, total: Int, ringR: Double,
                                  driveR: Double, droneHot: Bool)? {
        currentEngine()?.jtGateProbe()
    }

    /// Master gain (`bow_gain`, .live 2026-08-23): the performance volume
    /// of the whole radiated instrument, multiplying the fitted trim at
    /// the engine's ramped output gain — instant (~25 ms glide), no
    /// rebuild, no debounce, so tilt/strike bindings sweep it in real
    /// time. Runtime playing state: cached here and re-applied across
    /// rebuilds. Control-thread safe.
    public func setMasterGain(_ g: Double) {
        masterGain = max(g, 0.0)
        currentEngine()?.setMasterGain(masterGain)
    }

    /// Taraf damping 0..1 (`bow_jt_damp`): 0 = natural ring, 1 = choked
    /// well under a second. Control-thread safe.
    public func setTarafDamp(_ amt01: Double) {
        tarafDamp = min(max(amt01, 0.0), 1.0)
        currentEngine()?.setTarafDamp(tarafDamp)
    }

    /// Tone tilt -1..1 (`bow_tone_tilt`): -1 = bass bias, 0 = flat,
    /// +1 = treble bias. Control-thread safe.
    public func setToneTilt(_ t: Double) {
        toneTilt = min(max(t, -1.0), 1.0)
        currentEngine()?.setToneTilt(toneTilt)
    }

    /// Taraf recruitment profile 0..1 (`bow_jt_sel`): 0.5 = the fitted
    /// natural resonance profile; below, rows lose bridge drive by
    /// harmonic distance from the played notes (0 = kin-only); above,
    /// the profile flattens (1 = every row contributes equally,
    /// note-independent) — the radiated jt gain compensates throughout
    /// so the taraf's loudness holds. Control-thread safe.
    public func setTarafSelectivity(_ s01: Double) {
        tarafSel = min(max(s01, 0.0), 1.0)
        currentEngine()?.setTarafSelectivity(tarafSel)
    }

    /// Harmonic evolution 0…1 (`bow_jt_evolve`): the twang axis — a
    /// kernel-slewed signed bone offset (BowEngine owns the map).
    /// Control-thread safe.
    public func setJtEvolve(_ e01: Double) {
        jtEvolve = min(max(e01, 0.0), 1.0)
        currentEngine()?.setJtEvolve(jtEvolve)
    }

    /// Sitar twang 0…1 (`bow_twang`): the played strings' grazing bridge
    /// fold — 0 = plain bridge (byte-exact). Control-thread safe.
    public func setTwang(_ amt01: Double) {
        twang = min(max(amt01, 0.0), 1.0)
        currentEngine()?.setTwang(twang)
    }

    /// Voice→taraf inject-ring gain (2026-08-19): mixes foreign voices'
    /// rendered output into the jt web's bridge drive — their
    /// sympathetic halo IS the sarangi taraf. Since 2026-08-21 the
    /// per-voice levels (`st_taraf` / `tp_taraf`) scale at each
    /// source's tap, so this is just the shared arm (1 while any
    /// source drives, else 0). Control-thread safe (the kernel ring
    /// allocates on the first non-zero push); 0, or armed with nothing
    /// written, stays byte-null.
    public func setJtInjectGain(_ g: Double) {
        jtInjectGain = max(g, 0.0)
        currentEngine()?.setJtInjectGain(jtInjectGain)
    }

    /// Voice→taraf inject write — the ONE render-thread entry point:
    /// a foreign voice's node callback appends its mono block to the
    /// current engine's kernel ring (brief state lock, same as the
    /// render callback's engine fetch). A mid-rebuild write lands on
    /// the incoming engine only; the fading one's wash just decays.
    public func jtInjectWrite(_ x: UnsafePointer<Double>, _ n: Int) {
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        os_unfair_lock_unlock(&state.lock)
        engine?.jtInjectWrite(x, n)
    }

    // FX rack (2026-08-01): the four insert points' settings, kept here —
    // the long-lived side — like the runtime base parameters above, so a
    // structural rebuild republishes them onto the fresh engine (the FX
    // DSP state itself is per-engine; tails restart across a rebuild's
    // crossfade, settings never snap back).
    private var fxSettings = FXPoint.allCases.map { _ in FXSettings() }

    /// Apply one FX registry parameter (`fx_<point>_<field>`) — parses the
    /// key, updates the cached point settings, and pushes the whole point
    /// to the running engine. Control-thread safe. Returns false for an
    /// unrecognised key.
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

    /// Zero-allocation variant for the realtime harness: renders into
    /// caller-owned buffers, so per-buffer malloc cannot show up as
    /// render-deadline jitter.
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

    /// Pull `frames` through the EXACT audio-callback path (crossfade
    /// included), for tests and offline analysis. Not for realtime use.
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

    /// Crossfade length when swapping engines (2026-07-24). A fresh engine
    /// has no string/taraf/room state, so an abrupt swap cuts whatever is
    /// ringing; fading the outgoing engine out over this window turns that
    /// into a natural decay. Long enough to cover a taraf tail's audible
    /// onset, short enough that the 2x-CPU window stays small.
    public static let engineCrossfadeMs = 300.0

    /// Publish a freshly-built engine (brief lock; call on main/control
    /// thread). Passing nil silences the node. Swapped-out engines are kept
    /// briefly so an in-flight buffer never reads a freed one, and the
    /// outgoing engine keeps rendering through a crossfade so its ring
    /// decays instead of being cut.
    public func setEngine(_ engine: BowEngine?, crossfadeMs: Double? = nil) {
        if let engine {
            // Deep enough that an engine still being faded out cannot be
            // evicted (and thus deallocated) while the audio thread reads
            // it — builds take tens of ms, the fade is ~180 ms.
            recentEngines.append(engine)
            if recentEngines.count > 8 { recentEngines.removeFirst() }
            // re-apply the runtime base parameters: they are playing
            // state, not build state — a rebuild must not snap the
            // sound back to defaults mid-performance
            if jtLpHz > 0 { engine.setJtToneLp(hz: jtLpHz) }
            if jtHpHz > 0 { engine.setJtToneHp(hz: jtHpHz) }
            if jtBody > 0 { engine.setJtBody(jtBody) }
            if jtGov > 0 { engine.setJtGov(jtGov) }
            if tarafDamp != 0 { engine.setTarafDamp(tarafDamp) }
            if toneTilt != 0 { engine.setToneTilt(toneTilt) }
            if masterGain != 1.0 { engine.setMasterGain(masterGain) }
            if tarafSel != 0.5 { engine.setTarafSelectivity(tarafSel) }
            if jtEvolve != 0.5 { engine.setJtEvolve(jtEvolve) }
            if twang > 0 { engine.setTwang(twang) }
            if jtInjectGain > 0 { engine.setJtInjectGain(jtInjectGain) }
            for point in FXPoint.allCases
                where fxSettings[point.rawValue] != FXSettings() {
                engine.setFX(point, fxSettings[point.rawValue])
            }
        }
        let ms = crossfadeMs ?? Self.engineCrossfadeMs
        os_unfair_lock_lock(&state.lock)
        let outgoing = state.engine
        // A swap during a running fade collapses it: the older engine is
        // dropped and the fade restarts from the one that was audible.
        // (Nothing is louder for it — both were mid-fade.)
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

    /// The currently-published engine (brief lock) — used by the drone
    /// buttons to reach the jt rows. nil while the voice is unarmed.
    public func currentEngine() -> BowEngine? {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.engine
    }

    /// Async-jt overload telemetry of the current engine — (dropped drive
    /// blocks, flat-filled samples, web-FIFO fill, async flag). Drops/flats
    /// growing while playing = the jawari web is missing its realtime
    /// budget (audible clicking). Safe from any thread.
    public func jtStats() -> (drops: Double, flat: Double,
                              fill: Double, on: Double)? {
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        os_unfair_lock_unlock(&state.lock)
        return engine?.jtAsyncStats()
    }

    /// Render-deadline telemetry: (worst callback ms since last call,
    /// callbacks that exceeded 90% of their buffer duration, total
    /// callbacks). Overruns growing = device-level glitching the
    /// audition WAV can NEVER show. Resets the max on read.
    public func renderStats() -> (maxMs: Double, overruns: UInt64,
                                  callbacks: UInt64) {
        os_unfair_lock_lock(&state.lock)
        let r = (Double(state.maxRenderNs) / 1e6, state.overruns,
                 state.callbacks)
        state.maxRenderNs = 0
        os_unfair_lock_unlock(&state.lock)
        return r
    }

    /// Reset the playing state (base-voice switch / panic): all notes off;
    /// the string charge itself rings out (physical state).
    public func reset() {
        mapper.midi(0xB0, 123, 0)
    }

    /// Build the pure-physics bowed string for a tonic + tarab bank — the
    /// port of upstream `BowSource.buildStringEngine` (2026-07-21c), loading
    /// `bowed_string.json` from the SarangiKit bundle instead of the repo.
    /// The app tonic is the open string (nail termination + register-force
    /// reference); the tarab rows are the taraf TUNING (the taraf PHYSICS —
    /// coupling/pol/damping/tap/jawari — is `bow_*` artifact keys). The
    /// jawari-class (steel lattice) subset re-runs the python `_jt_load`
    /// mirror: playing-register rows first, one 60-cent pitch class each
    /// (row nearest the class MEDIAN — the fitted tables carry deliberate
    /// near-unison shimmer detunes), remaining cap slots by gain.
    /// `overrides` = String-editor / audition scalar overrides, applied OVER
    /// the artifact (pitch knots/cents arrays ride the artifact untouched).
    /// EXPENSIVE (~tables + kernel init + jt pool spawn) — call off main.
    /// Discarded blocks of settle pre-roll before a freshly built engine
    /// is published (4096 frames each, ~85 ms of audio). See the note at
    /// the pre-roll itself — this is the dominant cost of a rebuild, so it
    /// is kept to the minimum the choke needs.
    /// 4 → 5 (2026-07-25): the scale-defined bank rings the doubling
    /// strings in EXACT unison with their mid-choir twins (no detune any
    /// more), so the publish chime stacks coherently and decays slower —
    /// four blocks left it ~2.8 dB above the old 6-block floor.
    /// 5 → 3 (2026-08-18, the DAMPED SETTLE): with the taraf choked
    /// through the pre-roll the chime dies inside the discarded blocks
    /// instead of asymptoting at ~-50 dBFS — measured publish peak
    /// (stock rig, through the crossfade): 1 block -80 dBFS, 2 -88,
    /// 3 -93, 5 -102. Three keeps ~13 dB under the -80 bar
    /// (`testShortPreRollIsNoLouderOnPublishThanTheOldLongOne`) for
    /// hotter-than-stock rigs, at ~60% of the old rebuild latency.
    static var settleBlocks = 3

    /// IN-PLACE PARAMETER PUSH (2026-07-24): apply an edit to the RUNNING
    /// engine instead of building a new one. Recomputes the kernel's
    /// 61-scalar vector (cheap — the table build is < 1 ms and we keep
    /// only the scalars) and hands it, plus the merged params, to
    /// `BowEngine.setLiveParams`. Nothing is reset: the string histories,
    /// taraf ring, jawari web, room tail and note articulation all carry
    /// straight through, so there is no rebuild, no settle pre-roll and no
    /// crossfade.
    ///
    /// Returns false when the voice has no engine yet (the caller falls
    /// back to a build). Only valid for `ParamRegistry.inPlaceKeys` — the
    /// caller owns that check.
    ///
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
        // Same builder the engine was made with, so the tables are exactly
        // what a rebuild would have produced. `taraf` MUST be passed here
        // too (2026-08-01): the bridge-coupling web derives the passive
        // scalar (scalars[40]) from its voice count — building without the
        // rows would push a mismatched scalar vector onto an armed kernel.
        var tables = BowTables.buildOpenString(sr: modelSR * Double(osf),
                                               tonic: tonicHz, bp: bp,
                                               taraf: taraf)
        // STAGE 3: the body modal bank and the jawari tables are reloaded
        // in place too, so body/jt parameters are live as well. The jt
        // build is the expensive part (~3.4 ms) — skip it unless a jt key
        // is actually involved.
        if needsJawariTables {
            let rows = Self.jawariRows(bp: bp, tonicHz: tonicHz,
                                       taraf: taraf, follower: follower)
            tables.jt = BowTables.buildJawariTables(
                rows: rows, srk: modelSR * Double(osf), bp: bp,
                trackRowIndex: follower != nil ? rows.count - 1 : nil)
        }
        engine.setLiveParams(bp: bp, scalars: tables.scalars, tables: tables)
        return true
    }

    /// The modal-jawari ROW SELECTION (the python `_jt_load` mirror,
    /// upstream 2026-07-21c). The ONE implementation — `buildEngine` and
    /// the in-place path both call it, so a live jt edit always installs
    /// tables for exactly the string set the kernel is running. (Until
    /// 2026-07-25 `buildEngine` kept its own inline copy — the shapes could
    /// differ and the kernel silently refused every live jt reload.)
    ///
    /// The tarab rows are the ONLY input: the drone buttons pluck existing
    /// rows (mapped per-slot in the Strings tab) and add nothing here — the
    /// dedicated-drone-row append (2026-07-23 … 2026-07-25, with its
    /// ±6 ¢ reuse check and `bow_drone_comp_cents` target shift) is gone.
    ///
    /// `follower` (2026-07-25): the melody-follower string, appended LAST
    /// when enabled — outside the class-coverage selection, the `gmin`
    /// gate and the `bow_jt_max` cap (its pitch is dynamic, so coverage
    /// logic doesn't apply). Built at tonic/2 so the fixed mode
    /// allocation covers the low register (the kernel only TRIMS modes
    /// as the pitch rises). Appended last so `droneRow(forExactHz:)`
    /// identity lookups hit the real tarab rows first.
    static func jawariRows(bp: BowParams, tonicHz: Double,
                           taraf: [(f: Double, gain: Double, t60: Double)],
                           follower: (gain: Double, t60: Double)? = nil)
        -> [(f: Double, gain: Double, t60: Double)] {
        // (the python _jt_load mirror, upstream 2026-07-21c)
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

    public static func buildEngine(tonicHz: Double,
                                   strings: [ResolvedString],
                                   mapper: BowControlMapper,
                                   sr: Double = 48000,
                                   overrides: [String: Double] = [:],
                                   follower: (gain: Double, t60: Double)? = nil)
        -> BowEngine? {
        guard var bp = Presets.bowedStringParams() else { return nil }
        for (k, v) in overrides { bp.num[k] = v }
        // TARABDAAR LIVE SEEDS (2026-07-23): keys the artifact doesn't
        // carry (absent = the bit-exact mono path every parity test
        // runs) get their live defaults here — the physically-derived
        // stereo side image (per-source pans across the bridge,
        // kernel-side) + the width-decorrelated room. Overrides (String
        // editor / audition `string.<key>`) win; 0 = mono. Defined ONCE
        // in `liveParamSeeds` — `StringParamStore` merges the same dict
        // into its baseline so the editor's default/reset semantics
        // agree with the engine.
        for (k, v) in liveParamSeeds where bp.num[k] == nil {
            bp.num[k] = v
        }
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        // taraf TUNING rows from the tarab table (Strings tab / scale sync).
        // They feed the modal-jawari block (the whole RADIATED sympathetic
        // response) and — when `bow_cpl_z` > 0 (2026-08-01) — the
        // bridge-coupling web, one silent comb per row on the passive
        // junction, so the played strings feel the taraf as a load.
        let taraf = strings.filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonicHz, bp: bp,
                                               taraf: taraf)
        // MODAL-JAWARI taraf: the shared selection (also the in-place
        // path's), so live jt edits see exactly these rows. The melody
        // follower (when enabled) is the LAST row, marked for the
        // kernel's live retune.
        let rows = jawariRows(bp: bp, tonicHz: tonicHz, taraf: taraf,
                              follower: follower)
        tables.jt = BowTables.buildJawariTables(
            rows: rows, srk: sr * Double(osf), bp: bp,
            trackRowIndex: follower != nil ? rows.count - 1 : nil)
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               // the room's wet pair is width-decorrelated
                               // (a real room differs at the two ears);
                               // the side tank cancels in L+R, so the
                               // mono fold-down stays pan-invariant
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: bp.v("bow_rev_predelay", 15.0),
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: bp.v("bow_rev_width", 0.6),
                               fpMask: nil,
                               maxPoly: Int(bp.v("bow_live_poly", 8.0).rounded()))
        // Trim = the fitted calibration only. The performance master
        // volume (`bow_gain`, .live) is runtime state — `setEngine`
        // re-applies the cached value once the engine mounts.
        engine.outGain = bp.v("bow_live_trim", 0.05)
        engine.seedLiveGains()   // ramp starts from the built values
        // (Drone-button excitation scalars — bow_drone_level/_onset/
        // _attack_ms/_release_ms/_onset_decay_ms — are read from bp
        // inside BowEngine.init, same override path as everything else.)
        // SETTLE PRE-ROLL (2026-07-23 night): a fresh kernel's jt web
        // relaxes off the builder's q0 with an audible jawari chime —
        // every UI-edit rebuild "strummed" on publish. Render and
        // discard HERE (already off-main) so the engine is quiet when
        // swapped in; also primes the async-jt FIFO. Deliberately NOT
        // in BowEngine.init — the parity fixtures need renders from
        // t = 0.
        //
        // LENGTH (2026-07-24): this pre-roll IS the cost of a rebuild —
        // ~318 ms of a 320 ms build, against ~4 ms for the tables and
        // the kernel/pool init put together. Measured chime decay on a
        // fresh engine, per 85 ms block:
        //     block 0  -33 dBFS   block 1  -45   block 2  -48
        //     block 3  -49        block 5  -50   block 7  -52
        // It asymptotes near -50 dBFS, so blocks 5-6 bought ~1 dB for
        // ~110 ms of build latency. Four blocks reaches -50 dBFS: the
        // publish is within 1 dB of the old 6-block behavior at 2/3 the
        // latency (324 ms -> 216 ms), guarded by an A/B test.
        //
        // Lengthening `engineCrossfadeMs` does NOT substitute for this:
        // measured, going 180 -> 450 ms of fade bought only 1 dB, because
        // what is left after a few blocks is the jt web's steady idle
        // floor, not a decaying transient. The real fix would be upstream
        // (a q0 that does not leave the web charged at t = 0).
        // DAMPED SETTLE (2026-08-18): the upstream fix the LENGTH note
        // wished for. The chime is the q0 relax — the analytic static
        // wrap is not an exact equilibrium of the discrete contact, so
        // the web rings when ticking starts, and the anchors' 7–9 s
        // natural tails meant no affordable pre-roll could absorb it
        // (it asymptoted at ~-50 dBFS and rode out audibly for ~10 s
        // after publish). Choking the taraf HARD while the discarded
        // blocks render lets the contact settle the wrap to its true
        // discrete equilibrium with the oscillation killed, then the
        // natural ring is restored EXACTLY (a pure momentum scalar,
        // 0 = byte-null) before the engine is published: silent
        // publish, and the quiescence gate closes on the web within
        // ~30 ms instead of ~10 s. Measured (RebuildCostTests):
        // publish peak -50 dBFS (undamped asymptote) → -93 dBFS at the
        // shipped 3 settle blocks.
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
