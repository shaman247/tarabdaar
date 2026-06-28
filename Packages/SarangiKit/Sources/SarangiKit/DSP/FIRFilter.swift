import Foundation

/// Block E body transfer: a fixed FIR (the min-phase, 1/3-octave-smoothed
/// `|LTAS_target|/|LTAS_input|` curve from `blocks.design_transfer_fir`, baked
/// per pair). Applied to the dry violin branch exactly as `chain.process` does
/// (`apply_fir` = straight convolution). Direct-form, ring-buffered, RT-safe.
public struct FIRFilter: Sendable {
    public let taps: [Double]
    private var ring: [Double]
    private var pos: Int = 0

    public init(taps: [Double]) {
        self.taps = taps
        self.ring = [Double](repeating: 0, count: max(1, taps.count))
    }

    public mutating func process(_ x: Double) -> Double {
        let n = ring.count
        ring[pos] = x
        var acc = 0.0
        var idx = pos
        for k in 0..<n {
            acc += taps[k] * ring[idx]
            idx = (idx == 0) ? n - 1 : idx - 1
        }
        pos = (pos + 1) % n
        return acc
    }

    public mutating func reset() { for i in ring.indices { ring[i] = 0 }; pos = 0 }
}
