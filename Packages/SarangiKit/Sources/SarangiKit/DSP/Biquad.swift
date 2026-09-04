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

    /// TARABDAAR : adopt another section's COEFFICIENTS while
    /// keeping this one's delay state — the click-free way to retune a
    /// filter that is already running (a live parameter edit).
    public mutating func copyCoefficients(from o: Biquad) {
        b0 = o.b0; b1 = o.b1; b2 = o.b2; a1 = o.a1; a2 = o.a2
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() { z1 = 0; z2 = 0 }

    /// |H(e^{jω})| at `hz` for a section run at `sr` — display only.
    public func magnitude(at hz: Double, sr: Double) -> Double {
        let w = 2.0 * Double.pi * hz / sr
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1.0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return ((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30)).squareRoot()
    }

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

    /// First-order one-pole low-pass (`y += (1−a)·(x − y)`, a = e^(−2πfc/sr))
    /// expressed as a biquad — the generic bowed string's formula HF rolloff
    /// (gentler than butter-2; matches gutstring.post's lfilter([1−a],[1,−a])).
    public static func onePoleLowpass(fc: Double, sr: Double) -> Biquad {
        let a = OnePole.pole(hz: fc, sr: sr)
        return Biquad(b0: 1.0 - a, b1: 0, b2: 0, a0: 1.0, a1: -a, a2: 0)
    }

    /// |H(e^{jω})| of this (a0-normalised) biquad at `f` Hz — the linear magnitude
    /// response, exact for any design. Used to draw the EQ curve and to derive the
    /// post-EQ spectrum overlay analytically (post-dB = pre-dB + 20·log10(mag)).
    public func magnitude(atHz f: Double, sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr
        let cw = cos(w), sw = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numRe = b0 + b1 * cw + b2 * c2, numIm = -(b1 * sw + b2 * s2)
        let denRe = 1 + a1 * cw + a2 * c2, denIm = -(a1 * sw + a2 * s2)
        let num = (numRe * numRe + numIm * numIm).squareRoot()
        let den = (denRe * denRe + denIm * denIm).squareRoot()
        return num / max(den, 1e-12)
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
    static let zero = Cx(0, 0)
    /// e^{-jθ} (unit phasor) — used by the coupled stability transfer sweeps.
    var magnitude: Double { (re * re + im * im).squareRoot() }
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
