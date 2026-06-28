import Foundation

/// One sympathetic (taraf) string: a 2-pole modal resonator with **unity gain
/// at resonance**. Exact port of `blocks.resonator` / `_r_from_t60`.
///
/// Difference equation (b1=b2=0): `y = b0·x − a1·z1 − a2·z2`, with
/// `a1 = −2R cosθ`, `a2 = R²`, and `b0 = |1 − 2R cosθ·e^{−jθ} + R²e^{−2jθ}|`.
/// The `|denominator(e^{jθ})|` form is essential — the simpler `(1−R²)` form
/// collapses to ~0 for high-Q strings and the bank goes silent (see blocks.py).
public struct Resonator: Sendable {
    public var b0: Double
    public var a1: Double
    public var a2: Double
    public var z1: Double = 0
    public var z2: Double = 0

    public static let ln1000x3 = 6.90775527898  // 3·ln(10)

    public init(f0: Double, t60: Double, sr: Double) {
        let R = exp(-Resonator.ln1000x3 / (t60 * sr))
        let theta = 2 * Double.pi * f0 / sr
        let c = cos(theta), s = sin(theta)
        // |1 - 2R c·z + R² z²| with z = e^{-jθ}:
        let real = 1 - 2 * R * c * c + R * R * cos(2 * theta)
        let imag = 2 * R * c * s - R * R * sin(2 * theta)
        self.b0 = (real * real + imag * imag).squareRoot()
        self.a1 = -2 * R * c
        self.a2 = R * R
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x - a1 * z1 - a2 * z2
        z2 = z1
        z1 = y
        return y
    }

    public mutating func reset() { z1 = 0; z2 = 0 }
}
