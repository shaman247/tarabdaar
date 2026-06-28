import Foundation

/// A single biquad section in Direct-Form II transposed form (matches scipy's
/// `sosfilt`/`lfilter` numerics closely). Coefficients are normalised so a0 == 1.
///
/// The RBJ peaking/low-shelf designs are ported 1:1 from `src/blocks.py`
/// (`_peaking`, `_shelf`) for bit-close parity on the deterministic body/EQ
/// blocks. The Butterworth high-/low-/band-pass helpers are standard RBJ
/// (Q = 1/√2) designs used by the jawari and reverb paths, which are causal
/// ports (close, not sample-identical to scipy's `butter`).
public struct Biquad: Sendable {
    public var b0: Double, b1: Double, b2: Double
    public var a1: Double, a2: Double
    // Transposed DF-II state.
    public var z1: Double = 0
    public var z2: Double = 0

    public init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() { z1 = 0; z2 = 0 }

    // MARK: - RBJ designs (ported from blocks.py)

    /// Peaking EQ — exact port of `blocks._peaking`.
    public static func peaking(f0: Double, gainDB: Double, q: Double, sr: Double) -> Biquad {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * f0 / sr
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        return Biquad(b0: 1 + alpha * A, b1: -2 * cosw, b2: 1 - alpha * A,
                      a0: 1 + alpha / A, a1: -2 * cosw, a2: 1 - alpha / A)
    }

    /// Low shelf — exact port of `blocks._shelf(kind="low")`.
    public static func lowShelf(f0: Double, gainDB: Double, sr: Double, S: Double = 0.7) -> Biquad {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * f0 / sr
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * (((A + 1 / A) * (1 / S - 1) + 2)).squareRoot()
        let tsa = 2 * A.squareRoot() * alpha
        let b0 = A * ((A + 1) - (A - 1) * cosw + tsa)
        let b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
        let b2 = A * ((A + 1) - (A - 1) * cosw - tsa)
        let a0 = (A + 1) + (A - 1) * cosw + tsa
        let a1 = -2 * ((A - 1) + (A + 1) * cosw)
        let a2 = (A + 1) + (A - 1) * cosw - tsa
        return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// High shelf — RBJ (kind="high" in blocks._shelf).
    public static func highShelf(f0: Double, gainDB: Double, sr: Double, S: Double = 0.7) -> Biquad {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * f0 / sr
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * (((A + 1 / A) * (1 / S - 1) + 2)).squareRoot()
        let tsa = 2 * A.squareRoot() * alpha
        let b0 = A * ((A + 1) + (A - 1) * cosw + tsa)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
        let b2 = A * ((A + 1) + (A - 1) * cosw - tsa)
        let a0 = (A + 1) - (A - 1) * cosw + tsa
        let a1 = 2 * ((A - 1) - (A + 1) * cosw)
        let a2 = (A + 1) - (A - 1) * cosw - tsa
        return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// 2nd-order Butterworth high-pass (RBJ HPF, Q = 1/√2).
    public static func highpass(fc: Double, sr: Double, q: Double = 0.70710678) -> Biquad {
        let w0 = 2 * Double.pi * fc / sr
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// 2nd-order Butterworth low-pass (RBJ LPF, Q = 1/√2).
    public static func lowpass(fc: Double, sr: Double, q: Double = 0.70710678) -> Biquad {
        let w0 = 2 * Double.pi * fc / sr
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let b0 = (1 - cosw) / 2
        let b1 = 1 - cosw
        let b2 = (1 - cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// 4th-order **Butterworth** band-pass (`butter(2, [lo, hi], 'band')`) as a
    /// cascade of two biquads — verified equal to scipy to 0.0000 dB. The offline
    /// jawari morph-bandpass uses this maximally-flat response; the older RBJ
    /// `bandpass` cascade was over-narrow (each section −3 dB at the edges → the
    /// cascade −6 dB there), peaking the 2–4 kHz buzz. The scalar normalising the
    /// passband to unity at the geometric centre is folded into the first section.
    public static func butterBandpass(lo: Double, hi: Double, sr: Double) -> (Biquad, Biquad) {
        // analog prewarp (bilinear, fs = 2 convention as in scipy.signal.butter)
        let wl = 4.0 * tan(Double.pi * (lo / (sr / 2)) / 2.0)
        let wh = 4.0 * tan(Double.pi * (hi / (sr / 2)) / 2.0)
        let bw = wh - wl, wo2 = wl * wh
        let fs2 = 4.0
        // 2-pole Butterworth low-pass prototype poles: e^{j·3π/4}, e^{j·5π/4}
        let proto = [Cx(cos(3 * Double.pi / 4), sin(3 * Double.pi / 4)),
                     Cx(cos(5 * Double.pi / 4), sin(5 * Double.pi / 4))]
        // lp→bp: each prototype pole p solves s² − (p·bw)·s + wo² = 0; bilinear→z
        var zpoles: [Cx] = []
        for p in proto {
            let b = p * (-bw)                       // −p·bw
            let disc = (b * b - Cx(4 * wo2, 0)).sqrt()
            for s in [(b * -1 + disc) * 0.5, (b * -1 - disc) * 0.5] {
                zpoles.append((Cx(fs2, 0) + s) / (Cx(fs2, 0) - s))   // bilinear
            }
        }
        // one section per upper-half-plane pole (its conjugate completes it);
        // band-pass numerator z²−1 → (b0,b1,b2) = (1,0,−1)
        var secs: [Biquad] = []
        for zp in zpoles where zp.im > 1e-12 {
            secs.append(Biquad(b0: 1, b1: 0, b2: -1, a0: 1, a1: -2 * zp.re, a2: zp.re * zp.re + zp.im * zp.im))
        }
        // fall back to the (rare) degenerate case so we always return two sections
        while secs.count < 2 { secs.append(Biquad(b0: 1, b1: 0, b2: -1, a0: 1, a1: 0, a2: 0)) }
        var s0 = secs[0], s1 = secs[1]
        // normalise the cascade to unity at the geometric-mean centre
        let w0 = 2 * Double.pi * (lo * hi).squareRoot() / sr
        let g = 1.0 / cascadeMag(s0, s1, w0)
        s0.b0 *= g; s0.b1 *= g; s0.b2 *= g
        return (s0, s1)
    }

    private static func cascadeMag(_ a: Biquad, _ b: Biquad, _ w: Double) -> Double {
        let ej = Cx(cos(w), sin(w)), ej2 = ej * ej
        func h(_ s: Biquad) -> Cx {
            (Cx(s.b0, 0) * ej2 + Cx(s.b1, 0) * ej + Cx(s.b2, 0))
                / (ej2 + Cx(s.a1, 0) * ej + Cx(s.a2, 0))
        }
        let H = h(a) * h(b)
        return (H.re * H.re + H.im * H.im).squareRoot()
    }

    /// Constant-skirt band-pass (RBJ BPF, peak gain = Q). `lo`/`hi` set the
    /// centre (geomean) and bandwidth in octaves.
    public static func bandpass(lo: Double, hi: Double, sr: Double) -> Biquad {
        let f0 = (lo * hi).squareRoot()
        let w0 = 2 * Double.pi * f0 / sr
        let bw = max(0.001, log2(hi / lo))
        let sinw = sin(w0), cosw = cos(w0)
        let alpha = sinw * sinh(0.5 * log(2.0) * bw * w0 / sinw)
        let b0 = alpha
        let b1 = 0.0
        let b2 = -alpha
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }
}

/// Minimal complex number for the Butterworth band-pass pole math (no
/// `swift-numerics` dependency; only the handful of ops the design needs).
struct Cx {
    var re: Double, im: Double
    init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
    static func + (a: Cx, b: Cx) -> Cx { Cx(a.re + b.re, a.im + b.im) }
    static func - (a: Cx, b: Cx) -> Cx { Cx(a.re - b.re, a.im - b.im) }
    static func * (a: Cx, b: Cx) -> Cx { Cx(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Cx, s: Double) -> Cx { Cx(a.re * s, a.im * s) }
    static func / (a: Cx, b: Cx) -> Cx {
        let d = b.re * b.re + b.im * b.im
        return Cx((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
    /// Principal complex square root.
    func sqrt() -> Cx {
        let r = (re * re + im * im).squareRoot()
        let sr = ((r + re) / 2).squareRoot()
        let si = ((r - re) / 2).squareRoot()
        return Cx(sr, im < 0 ? -si : si)
    }
}

/// A short cascade of biquads applied in series (e.g. parametric EQ, body modes).
public struct BiquadChain: Sendable {
    public var sections: [Biquad]
    public init(_ sections: [Biquad] = []) { self.sections = sections }

    public mutating func process(_ x: Double) -> Double {
        var y = x
        for i in sections.indices { y = sections[i].process(y) }
        return y
    }

    public mutating func reset() { for i in sections.indices { sections[i].reset() } }
    public var isEmpty: Bool { sections.isEmpty }
}
