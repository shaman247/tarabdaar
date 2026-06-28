import Foundation

/// 4× polyphase oversampler wrapping a per-sample nonlinearity, used by the
/// jawari shaper. `tanh(drive·x)` at drive≈20 generates harmonics far above
/// Nyquist and the downstream morph-bandpass deliberately passes high bands, so
/// oversampling (not the band-pass) is what controls aliasing (see plan/critique).
///
/// `process(_:shape:)` upsamples one input sample to 4, applies `shape` to each
/// at the oversampled rate, then band-limits and decimates back to 1 output.
/// The lowpass is a windowed-sinc with cutoff at the base Nyquist (¼ of the 4×
/// Nyquist), shared by the up and down stages.
public struct Oversampler4x: Sendable {
    public static let L = 4

    private let branches: [[Double]]   // polyphase up: branches[p] applied to input history
    private let downKernel: [Double]   // decimation FIR over the 4×-rate stream
    private let inTaps: Int

    private var inHist: [Double]       // input ring (newest at inPos-1)
    private var inPos: Int = 0
    private var upHist: [Double]       // recent 4×-rate shaped samples (ring)
    private var upPos: Int = 0

    public init(halfTaps: Int = 8) {
        let L = Oversampler4x.L
        let m = halfTaps * L                      // one-sided length ⇒ kernel length 2m+1
        let n = 2 * m + 1
        let fc = 0.25                             // cutoff as fraction of 4×-Nyquist (= base Nyquist)
        var k = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let t = Double(i - m)
            let sinc = (t == 0) ? 1.0 : sin(Double.pi * fc * t) / (Double.pi * fc * t)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))   // Blackman
                    + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            let h = fc * sinc * w
            k[i] = h; sum += h
        }
        for i in 0..<n { k[i] /= sum }            // unity DC gain (downsampler)
        downKernel = k

        // Polyphase branches for upsampling (gain ×L to preserve amplitude).
        inTaps = (n + L - 1) / L
        var br = [[Double]](repeating: [Double](repeating: 0, count: inTaps), count: L)
        for p in 0..<L {
            for j in 0..<inTaps {
                let idx = p + L * j
                br[p][j] = idx < n ? k[idx] * Double(L) : 0
            }
        }
        branches = br
        inHist = [Double](repeating: 0, count: inTaps)
        upHist = [Double](repeating: 0, count: n)
    }

    public mutating func reset() {
        for i in inHist.indices { inHist[i] = 0 }
        for i in upHist.indices { upHist[i] = 0 }
        inPos = 0; upPos = 0
    }

    /// One input sample → one output sample, with `shape` applied at 4× rate.
    /// Allocation-free (ring buffers): safe on the render thread.
    public mutating func process(_ x: Double, shape: (Double) -> Double) -> Double {
        inHist[inPos] = x
        inPos = (inPos + 1) % inTaps
        let n = downKernel.count
        var out = 0.0
        for p in 0..<Oversampler4x.L {
            // upsample (polyphase): branch tap j reads input n-j (newest at inPos-1)
            var u = 0.0
            let b = branches[p]
            var ii = (inPos - 1 + inTaps) % inTaps
            for j in 0..<inTaps { u += b[j] * inHist[ii]; ii = (ii - 1 + inTaps) % inTaps }
            let s = shape(u)
            upHist[upPos] = s
            upPos = (upPos + 1) % n
            if p == Oversampler4x.L - 1 {
                var acc = 0.0
                var idx = (upPos - 1 + n) % n
                for tap in 0..<n { acc += downKernel[tap] * upHist[idx]; idx = (idx - 1 + n) % n }
                // The decimation FIR has unity DC gain and the polyphase
                // upsampler is already unity, so the down stage needs NO gain
                // (the previous ×L made the whole shaper output 4× too hot — the
                // jawari buzz read ~3.6× loud, unbalancing it against the dry).
                out = acc
            }
        }
        return out
    }
}
