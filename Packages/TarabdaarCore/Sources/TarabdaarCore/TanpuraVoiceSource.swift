import Foundation
import AVFoundation
import os
import SarangiKit

/// The playable TANPURA: an `AVAudioSourceNode` pulling stereo buffers from a
/// `SarangiKit.TanpuraEngine` — the r7 modal-contact plucked drone ported from
/// Sarangi Live (2026-08-04). The engine mounts one permanently-settled kernel
/// slot per pitch of the centralized scale's JI degree grid (octaves ×0.25 …
/// ×4 around the tonic — the same ratio range the drone buttons and the sync
/// blob speak), so the drone buttons and the main-instrument frets both pluck
/// exact scale pitches; there is no note-off (tanpura strings ring).
///
/// Second source on the graph (`node → symGain → mainMixerNode`, beside the
/// String voice's node) at the artifact's native 48 kHz. Structural changes
/// (tonic/scale) build a fresh engine OFF the render thread (`buildEngine` —
/// the mount+settle pass is ~seconds of CPU) and publish it via `setEngine`
/// with the same equal-power crossfade law as `StringVoiceSource`, so ringing
/// strings decay across a swap instead of being cut.
public final class TanpuraVoiceSource {
    public let node: AVAudioSourceNode
    public let modelSR: Double

    private final class State: @unchecked Sendable {
        var lock = os_unfair_lock()
        var engine: TanpuraEngine?
        /// The engine being CROSSFADED OUT — same law as the String voice:
        /// a fresh engine starts silent, so an abrupt swap would cut
        /// whatever is ringing (and a tanpura is ALWAYS ringing).
        var fading: TanpuraEngine?
        var fadePos = 0
        var fadeLen = 0
        let maxFrames = 4096
        var bufL: [Double]
        var bufR: [Double]
        var fadeL: [Double]
        var fadeR: [Double]
        init() {
            bufL = [Double](repeating: 0, count: maxFrames)
            bufR = [Double](repeating: 0, count: maxFrames)
            fadeL = [Double](repeating: 0, count: maxFrames)
            fadeR = [Double](repeating: 0, count: maxFrames)
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

    /// Output trim override (`tp_gain`) — playing state, kept here on the
    /// long-lived side so a structural rebuild re-applies it instead of
    /// snapping back to the artifact's fitted trim. nil = artifact value.
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
            return noErr
        }
    }

    /// Pull `frames` through the exact audio-callback path, for tests and
    /// offline analysis. Not for realtime use.
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

    /// Publish a freshly-built engine (brief lock; call on main/control
    /// thread). Passing nil silences the node. Swapped-out engines are kept
    /// briefly so an in-flight buffer never reads a freed one.
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

    /// The currently-published engine (brief lock) — pluck target for the
    /// drone buttons and the main-instrument note routing.
    public func currentEngine() -> TanpuraEngine? {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.engine
    }

    /// Output trim (`tp_gain`), live — plain scalar store on the running
    /// engine (the drone-setter contract), cached across rebuilds.
    public func setOutGain(_ g: Double) {
        outGainOverride = g
        currentEngine()?.outGain = g
    }

    /// The mounted JI slot grid for a tonic + scale: every degree ratio in
    /// octaves ×1/4 … ×4 of the tonic — the ratio range the drone buttons
    /// (0.25 … 4.0 on the sync blob) and the fret field live in. Sorted
    /// ascending; ~4·degrees + 1 slots (a 12-degree scale ≈ the Sarangi
    /// Live keyboard's 49).
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

    /// Build the tanpura for a tonic + scale — mounts and settles one slot
    /// per grid pitch. ~seconds of CPU: call OFF the main/audio thread and
    /// publish via `setEngine`. nil when `tanpura_live.json` is missing.
    /// `shapeAlign`/`shapeFocus`/`shapeSpread`/`shapeQuiet` (2026-08-05)
    /// build the scale-shaped-overtones transform from the SAME scale
    /// the grid mounts — all 0 (the defaults) is the physical tanpura,
    /// and the engine build is unchanged.
    public static func buildEngine(tonicHz: Double,
                                   scaleRatios: [Double],
                                   shapeAlign: Double = 0,
                                   shapeFocus: Double = 0,
                                   shapeSpread: Double = 0,
                                   shapeQuiet: Double = 0) -> TanpuraEngine? {
        guard let params = Presets.tanpuraParams() else { return nil }
        let freqs = slotFrequencies(tonicHz: tonicHz, scaleRatios: scaleRatios)
        guard !freqs.isEmpty else { return nil }
        let shaping: TanpuraShaping? =
            (shapeAlign > 0 || shapeFocus > 0 || shapeQuiet > 0)
            ? TanpuraShaping(tonicHz: tonicHz, scaleRatios: scaleRatios,
                             align: shapeAlign, focus: shapeFocus,
                             spread: shapeSpread, quiet: shapeQuiet)
            : nil
        return TanpuraEngine(params: params, frequencies: freqs,
                             shaping: shaping)
    }
}
