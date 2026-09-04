import Foundation

/// THE MODAL STRING both table builders share: a stiff string's mode
/// frequencies, its HF-rolled damping (σ = 6.91/t60 — the 60 dB decay),
/// the per-step rotation coefficients the kernels integrate with, and the
/// mode shapes at a point. Every expression is fixed so the two builders
/// produce the same bits they always did (the render hashes hold).
public enum ModalString {
    /// Angular mode frequencies for a stiff string: ω_k = 2π f0 k √(1 + B k²).
    public static func modeFrequencies(f0: Double, count M: Int,
                                       inharmonicity B: Double) -> [Double] {
        var w0 = [Double](repeating: 0, count: M)
        for k in 0..<M {
            let kk = Double(k + 1)
            w0[k] = 2.0 * Double.pi * f0 * kk * (1.0 + B * kk * kk).squareRoot()
        }
        return w0
    }

    /// Per-mode damping σ from the HF-rolled t60 law: 1/t60_k = 1/t60 +
    /// (f_k/fHf)²/t60hf.
    public static func damping(w0: [Double], t60: Double, fHf: Double,
                               t60hf: Double) -> [Double] {
        w0.map { w in
            let fk = w / (2.0 * Double.pi)
            let t60k = 1.0 / (1.0 / t60 + (fk / fHf) * (fk / fHf) * (1.0 / t60hf))
            return 6.91 / t60k
        }
    }

    /// The damped frequency and the rotation coefficients for one step `dt`:
    /// ca = e^{−σdt} cos(ω_d dt), cb = e^{−σdt} sin(ω_d dt), ω_d = √(ω₀² − σ²).
    /// `damp` overrides the decay in the coefficients (not in ω_d).
    public static func rotation(w0: [Double], sigma: [Double], dt: Double,
                                damp: Double? = nil)
        -> (ca: [Double], cb: [Double], wd: [Double]) {
        let M = w0.count
        var ca = [Double](repeating: 0, count: M)
        var cb = [Double](repeating: 0, count: M)
        var wd = [Double](repeating: 0, count: M)
        for k in 0..<M {
            let sg = damp ?? sigma[k]
            let wdk = max(w0[k] * w0[k] - sigma[k] * sigma[k], 1e-6).squareRoot()
            wd[k] = wdk
            ca[k] = exp(-sg * dt) * cos(wdk * dt)
            cb[k] = exp(-sg * dt) * sin(wdk * dt)
        }
        return (ca, cb, wd)
    }

    /// Mode k's (0-based) unit-normalised shape at `x` on a string of length L.
    @inline(__always)
    public static func shape(mode k: Int, at x: Double, length L: Double) -> Double {
        (2.0 / L).squareRoot() * sin(Double(k + 1) * Double.pi * x / L)
    }
}
