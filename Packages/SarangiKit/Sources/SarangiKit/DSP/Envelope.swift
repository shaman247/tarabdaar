import Foundation

/// One-pole smoother: `y = (1−a)·x + a·y_prev`. `a` from a time constant.
public struct OnePole: Sendable {
    public var a: Double
    public var y: Double = 0
    public init(tauMs: Double, sr: Double) { a = exp(-1.0 / (sr * tauMs / 1000.0)) }
    public init(a: Double) { self.a = a }
    public mutating func process(_ x: Double) -> Double { y = (1 - a) * x + a * y; return y }
    public mutating func reset(_ v: Double = 0) { y = v }
}

/// Causal running RMS (one-pole on x²). Replaces the offline whole-signal RMS
/// used by the jawari/drone level-matching.
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

/// Decaying peak-hold (instant attack, slow release). Causal stand-in for the
/// offline `env.max()` when no MIDI velocity is available (offline harness).
public struct RunningPeak: Sendable {
    public var aRel: Double
    public var peak: Double = 0
    public init(releaseS: Double, sr: Double) { aRel = exp(-1.0 / (sr * releaseS)) }
    public mutating func process(_ x: Double) -> Double {
        peak = Swift.max(x, aRel * peak)
        return peak
    }
    public mutating func reset() { peak = 0 }
}
