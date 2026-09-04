import Foundation

/// The one-pole coefficient forms, spelled once. `pole` is the feedback
/// pole a (y += (1 − a)·x + a·y); `coefficient` is the increment c = 1 − a.
/// Each is a fixed expression, so a site that spelled the same law gets
/// the same bits (the render hashes hold); the C kernels' twin is
/// `kernel_common.h`.
public enum OnePole {
    public static func pole(hz: Double, sr: Double) -> Double {
        exp(-2.0 * Double.pi * hz / sr)
    }

    public static func pole(tau: Double, sr: Double) -> Double {
        exp(-1.0 / (tau * sr))
    }

    public static func coefficient(hz: Double, sr: Double) -> Double {
        1.0 - exp(-2.0 * Double.pi * hz / sr)
    }

    public static func coefficient(tau: Double, sr: Double) -> Double {
        1.0 - exp(-1.0 / (tau * sr))
    }

    public static func coefficient(dt: Double, tau: Double) -> Double {
        1.0 - exp(-dt / tau)
    }

    /// The increment over a block of `frames` samples.
    public static func coefficient(frames: Int, tau: Double, sr: Double) -> Double {
        1.0 - exp(-Double(frames) / (tau * sr))
    }
}

/// xorshift64 — the step only; each site keeps its state and its own
/// word→float normalisation (they differ on purpose and are hash-pinned).
public enum XorShift64 {
    @inline(__always)
    public static func step(_ x: UInt64) -> UInt64 {
        var x = x
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        return x
    }
}
