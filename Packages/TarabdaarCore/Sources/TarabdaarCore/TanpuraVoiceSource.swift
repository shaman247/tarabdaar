import Foundation
import AVFoundation
import os
import SarangiKit

/// The playable TANPURA: an `AVAudioSourceNode` over a `TanpuraEngine` that
/// mounts one settled slot per pitch of the scale's JI grid (×0.25 … ×4 around
/// the tonic), so drone buttons and frets pluck exact scale pitches. Second
/// source on the graph (`node → symGain → mainMixerNode`, 48 kHz). Tonic/scale
/// changes build a fresh engine OFF the render thread (`buildEngine`) and
/// publish it via `setEngine` with an equal-power crossfade.
public final class TanpuraVoiceSource {
    public let node: AVAudioSourceNode
    public let modelSR: Double

    private final class State: @unchecked Sendable {
        var lock = os_unfair_lock()
        var engine: TanpuraEngine?
        /// The engine being crossfaded out (a fresh engine starts silent;
        /// an abrupt swap would cut what is ringing).
        var fading: TanpuraEngine?
        var fadePos = 0
        var fadeLen = 0
        let maxFrames = 4096
        var bufL: [Double]
        var bufR: [Double]
        var fadeL: [Double]
        var fadeR: [Double]
        /// Voice→taraf tap: each finished block (mono mixdown,
        /// post-crossfade) goes to the sink — the String kernel's jt
        /// inject ring. Published under the state lock; the sink must be
        /// render-thread safe (`StringVoiceSource.jtInjectWrite` is).
        var injectSink: ((UnsafePointer<Double>, Int) -> Void)?
        /// Per-source taraf drive (`st_taraf` / `tp_taraf`), applied
        /// BEFORE the sink so sitar and tanpura share the ring at
        /// independent levels. 0 = the sink is skipped (byte-null).
        var injectGain = 0.0
        var monoBuf: [Double]
        /// Output level meter, integrate-and-dump: the callback
        /// accumulates the mono mixdown's sum of squares under the state
        /// lock; `outputLevel()` returns the exact RMS since its last call.
        var meterSum = 0.0
        var meterFrames = 0
        var meterLast = 0.0

        /// Fold one finished buffer into the interval accumulator.
        func meterOutput(outL: UnsafePointer<Float>,
                         outR: UnsafePointer<Float>, frames n: Int) {
            var s = 0.0
            for i in 0..<n {
                let m = 0.5 * (Double(outL[i]) + Double(outR[i]))
                s += m * m
            }
            os_unfair_lock_lock(&lock)
            meterSum += s
            meterFrames += n
            os_unfair_lock_unlock(&lock)
        }
        init() {
            bufL = [Double](repeating: 0, count: maxFrames)
            bufR = [Double](repeating: 0, count: maxFrames)
            fadeL = [Double](repeating: 0, count: maxFrames)
            fadeR = [Double](repeating: 0, count: maxFrames)
            monoBuf = [Double](repeating: 0, count: maxFrames)
        }

        /// Mono-mix `n` frames into the sink at the taraf drive, chunked
        /// to the preallocated scratch (no render-thread allocation).
        func feedSink(_ sink: (UnsafePointer<Double>, Int) -> Void,
                      gain: Double,
                      outL: UnsafePointer<Float>,
                      outR: UnsafePointer<Float>, frames n: Int) {
            var done = 0
            while done < n {
                let m = min(maxFrames, n - done)
                monoBuf.withUnsafeMutableBufferPointer { mb in
                    let p = mb.baseAddress!
                    for i in 0..<m {
                        p[i] = gain * (0.5 * (Double(outL[done + i])
                                              + Double(outR[done + i])))
                    }
                    sink(p, m)
                }
                done += m
            }
        }

        func renderMix(engine: TanpuraEngine, fading: TanpuraEngine?,
                       frames n: Int,
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
                os_unfair_lock_lock(&lock)
                if self.fading === fading { self.fading = nil }
                os_unfair_lock_unlock(&lock)
            }
        }
    }
    private let state = State()
    // strong refs keep swapped-out engines alive past any in-flight buffer
    private var recentEngines: [TanpuraEngine] = []

    /// Output trim override (`tp_gain`): playing state, re-applied after a
    /// structural rebuild. nil = artifact value.
    private var outGainOverride: Double?

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
            let sink = st.injectSink
            let injectGain = st.injectGain
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
            st.renderMix(engine: engine, fading: fading, frames: n,
                         outL: outL, outR: outR)
            if let sink, injectGain != 0.0 {
                st.feedSink(sink, gain: injectGain,
                            outL: outL, outR: outR, frames: n)
            }
            st.meterOutput(outL: outL, outR: outR, frames: n)
            return noErr
        }
    }

    /// Exact RMS of the node's output (mono mixdown) since the previous
    /// call; repeats the last reading when nothing rendered. Any thread.
    public func outputLevel() -> Double {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        if state.meterFrames > 0 {
            state.meterLast =
                (state.meterSum / Double(state.meterFrames)).squareRoot()
            state.meterSum = 0
            state.meterFrames = 0
        }
        return state.meterLast
    }

    /// Pull `frames` through the exact audio-callback path, for tests and
    /// offline analysis. Not for realtime use.
    func renderForTesting(frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        os_unfair_lock_lock(&state.lock)
        let engine = state.engine
        let fading = state.fading
        let sink = state.injectSink
        let injectGain = state.injectGain
        os_unfair_lock_unlock(&state.lock)
        guard let engine else { return (l, r) }
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                state.renderMix(engine: engine, fading: fading, frames: frames,
                                outL: lb.baseAddress!, outR: rb.baseAddress!)
                if let sink, injectGain != 0.0 {
                    state.feedSink(sink, gain: injectGain,
                                   outL: lb.baseAddress!,
                                   outR: rb.baseAddress!, frames: frames)
                }
            }
        }
        return (l, r)
    }

    /// Publish a freshly-built engine (control thread). nil silences the
    /// node. Swapped-out engines are retained past any in-flight buffer.
    public func setEngine(_ engine: TanpuraEngine?, crossfadeMs: Double? = nil) {
        if let engine {
            recentEngines.append(engine)
            if recentEngines.count > 4 { recentEngines.removeFirst() }
            if let g = outGainOverride { engine.outGain = g }
        }
        let ms = crossfadeMs ?? StringVoiceSource.engineCrossfadeMs
        os_unfair_lock_lock(&state.lock)
        let outgoing = state.engine
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

    /// Install/clear the voice→taraf render tap (control thread); wire it
    /// to `StringVoiceSource.jtInjectWrite`.
    public func setInjectSink(_ sink: ((UnsafePointer<Double>, Int) -> Void)?) {
        os_unfair_lock_lock(&state.lock)
        state.injectSink = sink
        os_unfair_lock_unlock(&state.lock)
    }

    /// This voice's taraf drive (control thread). 0 = byte-null; playing
    /// state, survives engine rebuilds.
    public func setInjectGain(_ g: Double) {
        os_unfair_lock_lock(&state.lock)
        state.injectGain = max(g, 0.0)
        os_unfair_lock_unlock(&state.lock)
    }

    /// The currently-published engine — the pluck target.
    public func currentEngine() -> TanpuraEngine? {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.engine
    }

    /// Output trim (`tp_gain`), live; cached across rebuilds.
    public func setOutGain(_ g: Double) {
        outGainOverride = g
        currentEngine()?.outGain = g
    }

    /// The mounted JI slot grid: every degree ratio in octaves ×1/4 … ×4 of
    /// the tonic, sorted ascending (~4·degrees + 1 slots).
    public static func slotFrequencies(tonicHz: Double,
                                       scaleRatios: [Double]) -> [Double] {
        guard tonicHz > 0 else { return [] }
        let ratios = scaleRatios.filter { $0 > 0 }
        guard !ratios.isEmpty else { return [] }
        var freqs: [Double] = []
        for o in -2...2 {
            let m = pow(2.0, Double(o))
            for r in ratios {
                let f = r * m * tonicHz
                if f >= tonicHz * 0.25 - 1e-9, f <= tonicHz * 4.0 + 1e-9 {
                    freqs.append(f)
                }
            }
        }
        freqs.sort()
        return freqs
    }

    /// Build the engine for a tonic + scale — seconds of CPU: call OFF the
    /// main/audio thread, publish via `setEngine`; nil if the artifact is
    /// missing. `registerComp` (`tp_jiva_comp`) / `cascade` (`tp_cascade`)
    /// = per-slot thread calibration; both 0 = the fitted instrument,
    /// byte-identical.
    /// `artifact` selects the tanpura or the SITAR (a second source).
    public enum Artifact { case tanpura, sitar }

    public static func buildEngine(tonicHz: Double,
                                   scaleRatios: [Double],
                                   artifact: Artifact = .tanpura,
                                   registerComp: Double = 0,
                                   cascade: Double = 0,
                                   workers: Int = 8,
                                   polyphony: Int = 6) -> TanpuraEngine? {
        let loaded = artifact == .sitar ? Presets.sitarParams()
                                        : Presets.tanpuraParams()
        guard let params = loaded else { return nil }
        var freqs = slotFrequencies(tonicHz: tonicHz, scaleRatios: scaleRatios)
        if artifact == .sitar {
            // the sitar ladder is simulable to ~1.5 kHz (above it the
            // contact is under-resolved and self-oscillates); higher
            // slots do not mount, so frets above the cap find no slot
            freqs = freqs.filter { $0 <= 1500.0 }
        }
        guard !freqs.isEmpty else { return nil }
        let comp = min(max(registerComp, 0.0), 1.0)
        let casc = min(max(cascade, 0.0), 1.0)
        let threadHMul: ((Double) -> Double)? = (comp > 0 || casc > 0)
            ? { f0 in
                min(1.0,
                    TanpuraTables.registerCompThreadMul(
                        f0: f0, comp: comp, p: params)
                    + TanpuraTables.cascadeThreadLift(
                        f0: f0, cascade: casc, p: params))
            } : nil
        let engine = TanpuraEngine(params: params, frequencies: freqs,
                                   workers: workers,
                                   threadHMul: threadHMul,
                                   hfT60Mul: casc > 0 ? { f0 in
                                       TanpuraTables.cascadeHFT60Mul(
                                           f0: f0, cascade: casc)
                                   } : nil)
        engine?.setPolyphony(polyphony)
        return engine
    }
}

/// ONE plucked-voice mount. The tanpura and the sitar are the same machinery
/// on different fitted artifacts — a `TanpuraVoiceSource` on the graph plus
/// its `<prefix>_*` live trims — so `AudioEngine` holds two of these and
/// drives them through one parameterized enable / rebuild / parameter path.
/// The genuinely asymmetric parts stay in `AudioEngine` as explicit hooks:
/// the tanpura's drone buttons and its debounced table-shaping rebuild, and
/// the sitar's "clear the slot map only while it is the main instrument".
///
/// Threading follows the fields it replaced: the trims are guarded by
/// `AudioEngine.lock`; `gainOverride`, `attached`, `connected` and
/// `buildGen` are main-thread config.
final class PluckedVoice {
    /// Registry key prefix — `tp_` / `st_`.
    let prefix: String
    /// Which fitted artifact the engine mounts.
    let artifact: TanpuraVoiceSource.Artifact
    /// Log noun and the artifact's file name (the missing-file diagnostic).
    let name: String
    let artifactFile: String

    var source: TanpuraVoiceSource?
    var attached = false
    var connected = false
    var buildGen = 0

    // `<prefix>_*` live trims; the initial values ARE the registry defaults.
    var gainOverride: Double?
    var pluckLevel = 1.0
    var releaseT60: Double
    /// `<prefix>_pluck_touch`: pre-pluck state blended toward the settled
    /// wrap (1 = identical plucks).
    var pluckTouch: Double
    /// `<prefix>_pluck_drive`: drive into the jawari at the calibrated level.
    var pluckDrive = 1.0
    /// `<prefix>_taraf`: per-source gain at this voice's jt inject tap (the
    /// kernel-side gain is the shared arm).
    var tarafDrive = 4.0
    /// `<prefix>_poly`: previous plucks kept as full jawari simulations
    /// before dropping to the ghost tier.
    var poly: Double
    /// Table-build shaping (`tp_jiva_comp` / `tp_cascade`); the sitar has no
    /// such keys and holds both at 0 = the fitted instrument, byte-identical.
    var registerComp: Double
    var cascade: Double

    private init(prefix: String, artifact: TanpuraVoiceSource.Artifact,
                 name: String, artifactFile: String,
                 releaseT60: Double, pluckTouch: Double, poly: Double,
                 registerComp: Double, cascade: Double) {
        self.prefix = prefix
        self.artifact = artifact
        self.name = name
        self.artifactFile = artifactFile
        self.releaseT60 = releaseT60
        self.pluckTouch = pluckTouch
        self.poly = poly
        self.registerComp = registerComp
        self.cascade = cascade
    }

    static func tanpura() -> PluckedVoice {
        PluckedVoice(prefix: "tp_", artifact: .tanpura, name: "tanpura",
                     artifactFile: "tanpura_live.json",
                     releaseT60: 0.4, pluckTouch: 0.0, poly: 6.0,
                     registerComp: 1.0, cascade: 1.0)
    }

    static func sitar() -> PluckedVoice {
        PluckedVoice(prefix: "st_", artifact: .sitar, name: "sitar",
                     artifactFile: "sitar_live.json",
                     releaseT60: 0.15, pluckTouch: 1.0, poly: 4.0,
                     registerComp: 0, cascade: 0)
    }

    /// Is the fitted artifact present in the SarangiKit bundle?
    var artifactLoads: Bool {
        artifact == .sitar ? Presets.sitarParams() != nil
                           : Presets.tanpuraParams() != nil
    }

    /// The pluck trims one `pluckMain` needs. Caller holds `AudioEngine.lock`.
    var pluckTrims: (level: Double, touch: Double, drive: Double, relT60: Double) {
        (pluckLevel, pluckTouch, pluckDrive, releaseT60)
    }
}
