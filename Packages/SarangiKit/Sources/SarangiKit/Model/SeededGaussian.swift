import Foundation

/// Deterministic RNG (SplitMix64) + Box–Muller normal. Used for the per-string
/// detune in `buildStrings`. Note: this is **musically equivalent** to the
/// Python model's NumPy PCG64 chorus, not bit-identical (and need not be — the
/// detune is a few cents of beating). Same seed ⇒ same bank every launch.
public struct SeededGaussian: Sendable {
    private var state: UInt64
    private var spare: Double?

    public init(seed: UInt64) { self.state = seed }

    private mutating func nextU64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(nextU64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Standard normal × `sigma`.
    public mutating func normal(sigma: Double) -> Double {
        if let s = spare { spare = nil; return s * sigma }
        var u1 = uniform(), u2 = uniform()
        if u1 < 1e-12 { u1 = 1e-12 }
        if u2 < 1e-12 { u2 = 1e-12 }
        let mag = (-2.0 * log(u1)).squareRoot()
        let z0 = mag * cos(2 * Double.pi * u2)
        let z1 = mag * sin(2 * Double.pi * u2)
        spare = z1
        return z0 * sigma
    }
}
