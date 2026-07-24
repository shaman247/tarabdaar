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
/// `SarangiModelSource` + coupled-network pair as Starpad's "Sarangi (model)"
/// voice: the kernel IS the whole instrument (played strings + taraf +
/// body + radiation + room), so it renders STRAIGHT to the mix (`node →
/// symGain → mainMixerNode`).
///
/// Controlled by the long-lived `BowControlMapper` (same CC map as the v57
/// voice: CC11 expr · CC1 press · CC74 pos · CC2/75 tilt · per-channel MPE
/// pitch bend — the Starpad extension in `BowControls.swift`). Structural
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
    /// Starpad live-default seeds for `bowed_string.json` keys the artifact
    /// does NOT carry (2026-07-23 stereo rev): the physically-derived
    /// stereo image (taraf/jt/played pans across the bridge — see
    /// `BowEngine`'s side path) and the width-decorrelated room. Applied in
    /// `buildEngine` under any user override; ALSO merged into
    /// `StringParamStore`'s baseline so the editor shows/resets to these
    /// and an override landing back on a seed value is dropped.
    public static let liveParamSeeds: [String: Double] = [
        "bow_st_spread": 0.7,     // taraf web + jawari-row spread
        "bow_st_played": 0.15,    // played-string (+ bow noise) spread
        "bow_rev_width": 0.6,     // room tail L/R decorrelation
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
    // sound: full web buzz, build-time jt tone LP, no extra damping,
    // flat tone tilt.
    private var jawGain = 1.0
    private var jtLpHz = 0.0
    private var tarafDamp = 0.0
    private var toneTilt = 0.0

    /// Web buzz SCALER 0..1 — the live half of the `bow_taraf_jawari`
    /// hybrid parameter: 1 = the built (fitted) buzz depth, 0 = none.
    /// Upstream SarangiKit calls this scalar `bow_jaw_gain`; in Starpad it
    /// is not a parameter of its own (see `ParamRegistry`).
    /// Control-thread safe.
    public func setJawGain(_ g01: Double) {
        jawGain = min(max(g01, 0.0), 1.0)
        currentEngine()?.setJawGain(jawGain)
    }

    /// Radiated-jt tone LP corner (`bow_jt_lp`, runtime path; Hz,
    /// <= 0 = the build-time state). Control-thread safe.
    public func setJtToneLp(hz: Double) {
        jtLpHz = max(hz, 0.0)
        currentEngine()?.setJtToneLp(hz: jtLpHz)
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
            if jawGain != 1 { engine.setJawGain(jawGain) }
            if jtLpHz > 0 { engine.setJtToneLp(hz: jtLpHz) }
            if tarafDamp != 0 { engine.setTarafDamp(tarafDamp) }
            if toneTilt != 0 { engine.setToneTilt(toneTilt) }
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
    /// `droneHz` = the drone buttons' ABSOLUTE SOUNDING pitches (played
    /// tonic × configured ratio). A jt row rings ~`bow_drone_comp_cents`
    /// (15.5 c) SHARP of its nominal frequency — the jawari bone stiffens
    /// the termination — so each drone's target nominal is the request
    /// compensated down by that shift; an existing row within ±6 c of the
    /// target is reused (true unison), otherwise a dedicated jawari string
    /// is appended at the target (gain/t60 = the jt table's median). Either
    /// way the drone SOUNDS at the requested pitch.
    /// Discarded blocks of settle pre-roll before a freshly built engine
    /// is published (4096 frames each, ~85 ms of audio). See the note at
    /// the pre-roll itself — this is the dominant cost of a rebuild, so it
    /// is kept to the minimum the crossfade can finish off.
    static var settleBlocks = 4

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
    /// `droneHz` MUST be the same drone pitches the engine was built with:
    /// they add rows to the jawari web, so a different list changes the
    /// row COUNT, the kernel refuses the reload (shape moved), and the
    /// edit would silently do nothing.
    @discardableResult
    public func applyLiveParams(tonicHz: Double,
                                strings: [ResolvedString],
                                overrides: [String: Double],
                                droneHz: [Double] = [],
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
        // what a rebuild would have produced.
        var tables = BowTables.buildOpenString(sr: modelSR * Double(osf),
                                               tonic: tonicHz, bp: bp,
                                               taraf: taraf)
        // STAGE 3: the body modal bank and the jawari tables are reloaded
        // in place too, so body/jt parameters are live as well. The jt
        // build is the expensive part (~3.4 ms) — skip it unless a jt key
        // is actually involved.
        if needsJawariTables {
            tables.jt = BowTables.buildJawariTables(
                rows: Self.jawariRows(bp: bp, tonicHz: tonicHz,
                                      taraf: taraf, droneHz: droneHz),
                srk: modelSR * Double(osf), bp: bp)
        }
        engine.setLiveParams(bp: bp, scalars: tables.scalars, tables: tables)
        return true
    }

    /// The modal-jawari ROW SELECTION (the python `_jt_load` mirror,
    /// upstream 2026-07-21c) + the drone rows. Factored out of
    /// `buildEngine` (2026-07-24) so the in-place path builds the SAME
    /// rows — if these two ever diverge, a live jt edit would install
    /// tables for a different string set than the kernel is running.
    static func jawariRows(bp: BowParams, tonicHz: Double,
                           taraf: [(f: Double, gain: Double, t60: Double)],
                           droneHz: [Double])
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
        return jtRows
    }

    public static func buildEngine(tonicHz: Double,
                                   strings: [ResolvedString],
                                   mapper: BowControlMapper,
                                   sr: Double = 48000,
                                   overrides: [String: Double] = [:],
                                   droneHz: [Double] = []) -> BowEngine? {
        guard var bp = Presets.bowedStringParams() else { return nil }
        for (k, v) in overrides { bp.num[k] = v }
        // STARPAD LIVE SEEDS (2026-07-23): keys the artifact doesn't
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
        // taraf TUNING rows from the tarab table (Tarab tab / scale sync)
        let taraf = strings.filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonicHz, bp: bp,
                                               taraf: taraf)
        // MODAL-JAWARI taraf: consensus-pitch-class coverage selection
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
        // DRONE rows (2026-07-23): guarantee every configured drone pitch
        // exists in the web. An existing row within ±40 c keeps priority
        // (the fitted table's deliberate detunes are the instrument's
        // character); otherwise a dedicated string is appended at the
        // exact pitch with the table's median gain/t60.
        func median(_ v: [Double], fallback: Double) -> Double {
            guard !v.isEmpty else { return fallback }
            let sorted = v.sorted()
            return sorted[sorted.count / 2]
        }
        let dnGain = median(jtRows.map(\.gain), fallback: 0.85)
        let dnT60 = median(jtRows.map(\.t60), fallback: 5.0)
        let dnComp = pow(2.0, -bp.v("bow_drone_comp_cents", 15.5) / 1200.0)
        for hz in droneHz where hz > 20.0 {
            let target = hz * dnComp
            if !jtRows.contains(where: { abs(1200.0 * log2($0.f / target)) <= 6.0 }) {
                jtRows.append((f: target, gain: dnGain, t60: dnT60))
            }
        }
        tables.jt = BowTables.buildJawariTables(
            rows: jtRows, srk: sr * Double(osf), bp: bp)
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
        return engine
    }
}
