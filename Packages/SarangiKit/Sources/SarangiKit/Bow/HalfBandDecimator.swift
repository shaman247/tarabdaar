import Foundation

/// Streaming 2:1 decimator (96 kHz kernel rate → 48 kHz engine rate).
///
/// DESIGN — 65-tap linear-phase half-band FIR, Kaiser-windowed sinc:
///   h[n] = ½·sinc((n−32)/2)·kaiser(β = 8)[n],  n = 0…64.
/// Half-band ⇒ every even offset from centre is an exact zero (33 nonzero
/// taps), passband/stopband symmetric about fs/4 = 24 kHz; with the 65-tap
/// Kaiser the transition spans ≈20→28 kHz at ~80 dB stopband — the aliased
/// image of the kernel's 24–48 kHz residue lands ≥80 dB under the audio band.
/// 65 taps (centre M = 32, even) rather than 63 so the group delay is an
/// INTEGER number of OUTPUT samples (32 @96k = 16 @48k ≈ 0.33 ms — inaudible
/// live, and the end-to-end confirm compensates it exactly). The offline
/// render uses scipy `resample_poly` (different kaiser design, zero-phase
/// trim); the representable difference between the two is the −60 dB class
/// the live-parity confirm budgets for.
///
/// RT-safe: taps + history are fixed at init; `process` allocates nothing.
public struct HalfBandDecimator: Sendable {
    public static let taps: [Double] = design()
    static let order = 65
    static let centre = 32
    /// Group delay in OUTPUT (decimated-rate) samples.
    public static let outputDelay = centre / 2

    // history holds the last `order−1` input samples (previous chunks)
    private var hist: [Double]

    public init() {
        hist = [Double](repeating: 0, count: HalfBandDecimator.order - 1)
    }

    static func design() -> [Double] {
        let n = order
        let m = Double(centre)
        let beta = 8.0
        // zeroth-order modified Bessel I0 (power series; converges fast)
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            var k = 1.0
            while true {
                term *= (x / (2.0 * k)) * (x / (2.0 * k))
                sum += term
                if term < 1e-18 * sum { break }
                k += 1
            }
            return sum
        }
        let i0b = i0(beta)
        var h = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = (Double(i) - m) / 2.0            // half-band sinc argument
            let s = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let r = (Double(i) - m) / m
            let w = i0(beta * (1.0 - r * r).squareRoot()) / i0b
            h[i] = 0.5 * s * w
        }
        return h
    }

    /// Decimate `n96` input samples (n96 even) into `n96/2` outputs.
    /// Output m is Σ_k h[k]·x[2m − k] on the concatenated (history + chunk)
    /// stream — exactly one linear convolution split across calls.
    public mutating func process(_ input: UnsafePointer<Double>, count n96: Int,
                                 into out: UnsafeMutablePointer<Double>) {
        let h = HalfBandDecimator.taps
        let hn = HalfBandDecimator.order
        let histN = hn - 1                        // 64
        let nOut = n96 / 2
        hist.withUnsafeBufferPointer { hb in
            for m in 0..<nOut {
                // newest input index for this output: y[m] ≈ x_lp(2m − 32),
                // an integer 16-sample delay at the output rate
                let base = 2 * m
                var acc = 0.0
                // taps k = 0…hn−1 read x[base − k]; x[j] with j < 0 comes
                // from the history tail (hist[histN + j]).
                var k = 0
                while k < hn {
                    let j = base - k
                    if j >= 0 {
                        acc += h[k] * input[j]
                    } else {
                        acc += h[k] * hb[histN + j]
                    }
                    k += 1
                }
                out[m] = acc
            }
        }
        // roll the history: keep the last histN input samples
        if n96 >= histN {
            for i in 0..<histN { hist[i] = input[n96 - histN + i] }
        } else {
            let keep = histN - n96
            for i in 0..<keep { hist[i] = hist[i + n96] }
            for i in 0..<n96 { hist[keep + i] = input[i] }
        }
    }

    public mutating func reset() {
        for i in hist.indices { hist[i] = 0 }
    }
}
