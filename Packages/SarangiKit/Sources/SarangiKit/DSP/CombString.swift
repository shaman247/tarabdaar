import Foundation

/// One sympathetic string as a **harmonic comb** (Karplus-Strong feedback comb),
/// the current offline model's `blocks.comb_string`. Unlike a 2-pole resonator
/// (a pure sine), a comb rings at its fundamental AND its whole harmonic series —
/// the rich shimmer of a real taraf bank.
///
///   y[n] = (1−g)·x[n] + g·y[n−L],   L = round(sr/f0),
///   g = min(0.99985, 10^(−3L/(t60·sr)))      (unity gain at each harmonic)
/// then a `bright` one-zero HF roll-off (gut-string damping):
///   out[n] = y[n] − (1−bright)·0.5·(y[n] − y[n−1]).
public struct CombString: Sendable {
    private var buf: [Double]
    private var idx: Int = 0
    private let g: Double
    private let oneMinusG: Double
    private let damp: Double            // (1−bright)·0.5
    private var prevY: Double = 0

    public init(f0: Double, t60: Double, sr: Double, bright: Double) {
        let L = max(2, Int((sr / f0).rounded()))
        buf = [Double](repeating: 0, count: L)
        g = min(0.99985, pow(10.0, -3.0 * Double(L) / (max(t60, 0.05) * sr)))
        oneMinusG = 1 - g
        damp = (1 - bright) * 0.5
    }

    public mutating func process(_ x: Double) -> Double {
        let yL = buf[idx]                       // y[n−L]
        let y = oneMinusG * x + g * yL          // comb output (feeds back)
        buf[idx] = y
        idx = (idx + 1) % buf.count
        let out = y - damp * (y - prevY)        // brightness one-zero
        prevY = y
        return out
    }

    public mutating func reset() { for i in buf.indices { buf[i] = 0 }; idx = 0; prevY = 0 }

    /// Delay length `L = round(sr/f0)` — exactly one period of the fundamental.
    public var period: Int { buf.count }

    /// A value copy of the one-period delay buffer. A DFT of this (at integer
    /// bins k=1…L/2) yields the per-harmonic amplitudes directly: bin k sits at
    /// k·sr/L ≈ k·f0. Magnitude is rotation-invariant, so the circular write
    /// index needn't be undone. Used by the Live-tab harmonic display.
    public func bufferCopy() -> [Double] { buf }
}
