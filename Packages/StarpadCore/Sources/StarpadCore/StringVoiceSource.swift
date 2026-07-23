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
/// base voice: the kernel IS the whole instrument (played strings + taraf +
/// body + radiation + room), so it renders STRAIGHT to the mix — it must NOT
/// pass through `SarangiProcessorAU`'s coupled network (that would double the
/// taraf).
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
    public let mapper = BowControlMapper()
    public let node: AVAudioSourceNode
    public let modelSR: Double

    private final class State: @unchecked Sendable {
        var lock = os_unfair_lock()
        var engine: BowEngine?
        let maxFrames = 4096
        var bufL: [Double]
        var bufR: [Double]
        // render-deadline telemetry: the audition tap records what the
        // engine renders, so a LATE callback glitches at the device while
        // the WAV stays clean — this is the only way to see it
        var maxRenderNs: UInt64 = 0
        var overruns: UInt64 = 0
        var callbacks: UInt64 = 0
        init() {
            bufL = [Double](repeating: 0, count: maxFrames)
            bufR = [Double](repeating: 0, count: maxFrames)
        }
    }
    private let state = State()
    // strong refs keep swapped-out engines alive past any in-flight buffer
    private var recentEngines: [BowEngine] = []

    public init(sr: Double = 48000) {
        modelSR = sr
        let st = state
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            os_unfair_lock_lock(&st.lock)
            let engine = st.engine
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
            var done = 0
            while done < n {
                let m = min(st.maxFrames, n - done)
                st.bufL.withUnsafeMutableBufferPointer { lb in
                    st.bufR.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                for i in 0..<m {
                    outL[done + i] = Float(st.bufL[i])
                    outR[done + i] = Float(st.bufR[i])
                }
                done += m
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

    /// Publish a freshly-built engine (brief lock; call on main/control
    /// thread). Passing nil silences the node. Swapped-out engines are kept
    /// briefly so an in-flight buffer never reads a freed one.
    public func setEngine(_ engine: BowEngine?) {
        if let engine {
            recentEngines.append(engine)
            if recentEngines.count > 4 { recentEngines.removeFirst() }
        }
        os_unfair_lock_lock(&state.lock)
        state.engine = engine
        os_unfair_lock_unlock(&state.lock)
    }

    public var isArmed: Bool {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.engine != nil
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
    public static func buildEngine(tonicHz: Double,
                                   strings: [ResolvedString],
                                   mapper: BowControlMapper,
                                   sr: Double = 48000,
                                   overrides: [String: Double] = [:]) -> BowEngine? {
        guard var bp = Presets.bowedStringParams() else { return nil }
        for (k, v) in overrides { bp.num[k] = v }
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
        tables.jt = BowTables.buildJawariTables(
            rows: jtRows, srk: sr * Double(osf), bp: bp)
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               // slight mono room; width 0 = equal L/R
                               // (pan-invariant), NO stereo widening
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: bp.v("bow_rev_predelay", 15.0),
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: 0.0,
                               fpMask: nil,
                               maxPoly: Int(bp.v("bow_live_poly", 8.0).rounded()))
        engine.outGain = bp.v("bow_live_trim", 0.05)
        return engine
    }
}
