import Foundation

/// Block F — room reverb + stereo width (real-time). The offline model convolves
/// a deterministic exponential-decay IR (~57k taps) — too costly per-sample — so
/// this uses a compact Freeverb-style tank with RT60-matched feedback, the same
/// 100–9000 Hz band-limit, running-RMS energy match, and a **decorrelated side**
/// so `L=mid+s, R=mid−s`: width changes the L/R correlation without touching the
/// mono sum (the `width_for_corr` relationship `F_width` encodes). `F_width` is
/// read directly from the preset (it's a baked scalar).
public struct Reverb: Sendable {
    private var predelay: DelayLine
    private var mid: ReverbTank
    private var side: ReverbTank
    private var hpM: Biquad, lpM: Biquad, hpS: Biquad, lpS: Biquad
    private var rmsDry: RunningRMS, rmsWet: RunningRMS, rmsSide: RunningRMS, rmsMid: RunningRMS

    public var mix: Double            // F_mix (live)
    public var width: Double          // F_width (live)

    public init(rt60: Double, predelayMs: Double, mix: Double, width: Double, sr: Double) {
        self.mix = mix; self.width = width
        predelay = DelayLine(samples: max(1, Int(predelayMs / 1000.0 * sr)))
        mid = ReverbTank(rt60: rt60, sr: sr, spread: 0)
        side = ReverbTank(rt60: rt60 * 0.9, sr: sr, spread: 23)
        hpM = Biquad.highpass(fc: 100, sr: sr); lpM = Biquad.lowpass(fc: min(9000, 0.45 * sr), sr: sr)
        hpS = Biquad.highpass(fc: 100, sr: sr); lpS = Biquad.lowpass(fc: min(9000, 0.45 * sr), sr: sr)
        rmsDry = RunningRMS(tauMs: 200, sr: sr); rmsWet = RunningRMS(tauMs: 200, sr: sr)
        rmsSide = RunningRMS(tauMs: 200, sr: sr); rmsMid = RunningRMS(tauMs: 200, sr: sr)
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
}

struct Comb: Sendable {
    var buf: [Double]; var idx = 0; var store = 0.0
    let feedback: Double; let damp: Double
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
