import Foundation

/// Block F — room reverb + stereo width (real-time). The offline model convolves
/// a deterministic exponential-decay IR (~57k taps) — too costly per-sample — so
/// this uses a compact Freeverb-style tank with RT60-matched feedback, the same
/// 100–9000 Hz band-limit, running-RMS energy match, and a **decorrelated side**
/// so `L=mid+s, R=mid−s`: width changes the L/R correlation without touching the
/// mono sum (`w = sqrt((1−corr)/(1+corr))`, the relationship `F_width` encodes).
/// `F_width` is read directly from the preset (it's a baked scalar).
public struct Reverb: Sendable {
    private var predelay: DelayLine
    private var mid: ReverbTank
    private var side: ReverbTank
    private var hpM: Biquad, lpM: Biquad, hpS: Biquad, lpS: Biquad
    private var rmsDry: RunningRMS, rmsWet: RunningRMS, rmsSide: RunningRMS, rmsMid: RunningRMS

    public var mix: Double            // F_mix (live)
    public var width: Double          // F_width (live)
    private let sr: Double

    public init(rt60: Double, predelayMs: Double, mix: Double, width: Double, sr: Double) {
        self.mix = mix; self.width = width; self.sr = sr
        predelay = DelayLine(samples: max(1, Int(predelayMs / 1000.0 * sr)))
        mid = ReverbTank(rt60: rt60, sr: sr, spread: 0)
        side = ReverbTank(rt60: rt60 * 0.9, sr: sr, spread: 23)
        hpM = Biquad.highpass(fc: 100, sr: sr); lpM = Biquad.lowpass(fc: min(9000, 0.45 * sr), sr: sr)
        hpS = Biquad.highpass(fc: 100, sr: sr); lpS = Biquad.lowpass(fc: min(9000, 0.45 * sr), sr: sr)
        rmsDry = RunningRMS(tauMs: 200, sr: sr); rmsWet = RunningRMS(tauMs: 200, sr: sr)
        rmsSide = RunningRMS(tauMs: 200, sr: sr); rmsMid = RunningRMS(tauMs: 200, sr: sr)
    }

    /// Mono `x` → ADDITIVE mono wet (scaled by `mix`, energy-matched to the
    /// dry level). Stereo image now comes from the bank's per-string pans; the
    /// room is mono and the caller splits it equally across channels.
    public mutating func processMono(_ x: Double) -> Double {
        let dRMS = rmsDry.process(x)
        if mix <= 0 { return 0 }
        let pre = predelay.process(x)
        var wet = lpM.process(hpM.process(mid.process(pre)))
        let wRMS = rmsWet.process(wet)
        wet *= (dRMS + 1e-12) / (wRMS + 1e-12)
        return mix * wet
    }

    /// Mono `x` → ADDITIVE stereo wet pair (Tarabdaar stereo, 2026-07-23):
    /// the `processMono` wet plus the decorrelated side tank scaled by
    /// `width` — a real room's reverberant field differs at the two ears.
    /// The side term cancels in L+R, so the mono fold-down is exactly
    /// `processMono`'s output; `width` 0 returns an identical pair.
    public mutating func processMonoStereo(_ x: Double) -> (Double, Double) {
        let dRMS = rmsDry.process(x)
        if mix <= 0 { return (0, 0) }
        let pre = predelay.process(x)
        var wet = lpM.process(hpM.process(mid.process(pre)))
        let wRMS = rmsWet.process(wet)
        wet *= (dRMS + 1e-12) / (wRMS + 1e-12)
        if width <= 0 { let w = mix * wet; return (w, w) }
        var s = lpS.process(hpS.process(side.process(pre)))
        let sRMS = rmsSide.process(s)
        // side scaled to width × the (dry-matched) wet level
        s = s / (sRMS + 1e-12) * width * (dRMS + 1e-12)
        return (mix * (wet + s), mix * (wet - s))
    }

    /// Mono `x` → stereo (L, R).
    public mutating func process(_ x: Double) -> (Double, Double) {
        let dRMS = rmsDry.process(x)
        let pre = predelay.process(x)

        var midOut = x
        if mix > 0 {
            var wet = lpM.process(hpM.process(mid.process(pre)))
            let wRMS = rmsWet.process(wet)
            wet *= (dRMS + 1e-12) / (wRMS + 1e-12)         // energy-match wet to dry
            midOut = (1 - mix) * x + mix * wet
        }
        if width <= 0 { return (midOut, midOut) }

        var s = lpS.process(hpS.process(side.process(pre)))
        let sRMS = rmsSide.process(s)
        let mRMS = rmsMid.process(midOut)
        s = s / (sRMS + 1e-12) * width * mRMS              // side scaled to width × mid level
        return (midOut + s, midOut - s)
    }

    public mutating func reset() {
        predelay.reset(); mid.reset(); side.reset()
        hpM.reset(); lpM.reset(); hpS.reset(); lpS.reset()
        rmsDry.reset(); rmsWet.reset(); rmsSide.reset(); rmsMid.reset()
    }

    /// TARABDAAR FX (2026-08-01): retune the running room in place — comb
    /// feedbacks re-derived for the new RT60 (buffers and state kept, so
    /// the tail glides instead of clicking) and the band-limit low-passes
    /// take new coefficients state-kept (`copyCoefficients`). The FX
    /// rack's "Room" reverb drives this from its live size/cutoff knobs;
    /// the fitted calibration room never calls it.
    public mutating func setTone(rt60: Double, cutoffHz: Double) {
        mid.setRT60(rt60, sr: sr)
        side.setRT60(rt60 * 0.9, sr: sr)
        let lp = Biquad.lowpass(fc: min(max(cutoffHz, 100), 0.45 * sr), sr: sr)
        lpM.copyCoefficients(from: lp)
        lpS.copyCoefficients(from: lp)
    }
}

/// A simple fixed-delay line (predelay).
struct DelayLine: Sendable {
    var buf: [Double]; var idx = 0
    init(samples: Int) { buf = [Double](repeating: 0, count: max(1, samples)) }
    mutating func process(_ x: Double) -> Double {
        let y = buf[idx]; buf[idx] = x; idx = (idx + 1) % buf.count; return y
    }
    mutating func reset() { for i in buf.indices { buf[i] = 0 } }
}

/// Freeverb-style tank: 8 damped combs in parallel → 4 allpasses in series.
struct ReverbTank: Sendable {
    var combs: [Comb]; var allpasses: [Allpass]
    let norm: Double

    init(rt60: Double, sr: Double, spread: Int, damp: Double = 0.2) {
        let scale = sr / 44100.0
        let combSizes = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let apSizes = [556, 441, 341, 225]
        combs = combSizes.map { base -> Comb in
            let size = max(2, Int(Double(base + spread) * scale))
            let g = pow(10.0, -3.0 * Double(size) / (rt60 * sr))   // −60 dB over rt60
            return Comb(size: size, feedback: min(0.98, g), damp: damp)
        }
        allpasses = apSizes.map { Allpass(size: max(2, Int(Double($0 + spread) * scale)), feedback: 0.5) }
        norm = 1.0 / Double(combSizes.count).squareRoot()
    }

    mutating func process(_ x: Double) -> Double {
        var y = 0.0
        for i in combs.indices { y += combs[i].process(x) }
        y *= norm
        for i in allpasses.indices { y = allpasses[i].process(y) }
        return y
    }

    mutating func reset() { for i in combs.indices { combs[i].reset() }; for i in allpasses.indices { allpasses[i].reset() } }

    /// Re-derive each comb's feedback for a new RT60 (same −60 dB law as
    /// init), keeping every buffer and state — a live, click-free move.
    mutating func setRT60(_ rt60: Double, sr: Double) {
        for i in combs.indices {
            let size = combs[i].buf.count
            let g = pow(10.0, -3.0 * Double(size) / (max(rt60, 0.05) * sr))
            combs[i].feedback = min(0.98, g)
        }
    }
}

struct Comb: Sendable {
    var buf: [Double]; var idx = 0; var store = 0.0
    var feedback: Double; let damp: Double
    init(size: Int, feedback: Double, damp: Double) { buf = [Double](repeating: 0, count: size); self.feedback = feedback; self.damp = damp }
    mutating func process(_ x: Double) -> Double {
        let y = buf[idx]
        store = y * (1 - damp) + store * damp
        buf[idx] = x + store * feedback
        idx = (idx + 1) % buf.count
        return y
    }
    mutating func reset() { for i in buf.indices { buf[i] = 0 }; store = 0 }
}

struct Allpass: Sendable {
    var buf: [Double]; var idx = 0; let feedback: Double
    init(size: Int, feedback: Double) { buf = [Double](repeating: 0, count: size); self.feedback = feedback }
    mutating func process(_ x: Double) -> Double {
        let bufout = buf[idx]
        let out = -x + bufout
        buf[idx] = x + bufout * feedback
        idx = (idx + 1) % buf.count
        return out
    }
    mutating func reset() { for i in buf.indices { buf[i] = 0 } }
}

/// Causal running RMS (one-pole on x²) — the wet/dry level tracker above is
/// its only consumer, so it lives here since `DSP/Envelope.swift` (a grab-bag
/// of offline-harness helpers) was deleted with the vendored machinery.
/// Verbatim: the reverb's balance depends on these exact coefficients.
public struct RunningRMS: Sendable {
    public var a: Double
    public var meanSq: Double = 0
    public init(tauMs: Double, sr: Double) { a = exp(-1.0 / (sr * tauMs / 1000.0)) }
    public mutating func process(_ x: Double) -> Double {
        meanSq = (1 - a) * (x * x) + a * meanSq
        return meanSq.squareRoot()
    }
    public mutating func reset() { meanSq = 0 }
}
