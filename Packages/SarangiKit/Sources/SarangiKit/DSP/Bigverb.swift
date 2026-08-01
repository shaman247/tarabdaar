import Foundation

/// Bigverb — a direct port of sndkit's `sk_bigverb`
/// (https://paulbatchelor.github.io/sndkit/bigverb/), itself derived from
/// Sean Costello's csound `reverbsc`: 8 parallel feedback delay lines whose
/// read taps jitter along random line segments (cubic-interpolated), coupled
/// through a shared junction pressure. Even lines take/return the LEFT
/// channel, odd lines the RIGHT; the jitter decorrelates the tail, so a mono
/// send still blooms into wide stereo.
///
/// The port keeps the reference's exact constants (the 8-line parameter
/// table, the 15625 LCG, the 28-bit fractional read, the 0.25 junction and
/// 0.35 output scalars) but runs in Double like the rest of the DSP here —
/// it is a faithful algorithm port, not a bit-parity one.
///
/// `size` (0…1, default 0.93) is the feedback level — the decay. `cutoff`
/// (Hz, default 10 kHz) is a 1-pole lowpass inside every feedback loop —
/// the tail darkens as it recirculates. Both are plain stored properties,
/// safe to move every block; the coefficient refresh is cached on change.
public struct Bigverb: Sendable {

    /// The reference's fixed per-line parameter set
    /// (delay in samples @44.1 kHz, drift in 0.1 ms, randfreq in mHz, RNG seed).
    private struct ParamSet {
        let delay: Int, drift: Int, randfreq: Int, seed: Int
    }
    private static let params: [ParamSet] = [
        ParamSet(delay: 0x09a9, drift: 0x0a, randfreq: 0xc1c, seed: 0x07ae),
        ParamSet(delay: 0x0acf, drift: 0x0b, randfreq: 0xdac, seed: 0x7333),
        ParamSet(delay: 0x0c91, drift: 0x11, randfreq: 0x456, seed: 0x5999),
        ParamSet(delay: 0x0de5, drift: 0x06, randfreq: 0xf85, seed: 0x2666),
        ParamSet(delay: 0x0f43, drift: 0x0a, randfreq: 0x925, seed: 0x50a3),
        ParamSet(delay: 0x101f, drift: 0x0b, randfreq: 0x769, seed: 0x5999),
        ParamSet(delay: 0x085f, drift: 0x11, randfreq: 0x37b, seed: 0x7333),
        ParamSet(delay: 0x078d, drift: 0x06, randfreq: 0xc95, seed: 0x3851),
    ]

    private static let fracScale = 0x10000000
    private static let fracMask = 0xFFFFFFF
    private static let fracNBits = 28

    private struct DelayLine: Sendable {
        var buf: [Double]
        var wpos = 0
        var irpos: Int
        var frpos: Int
        var rng: Int
        var inc = 0
        var counter = 0
        let maxcount: Int
        let dels: Double     // base delay, seconds
        let drift: Double    // drift table value (still in 0.1 ms units)
        var y = 0.0          // feedback-filter state (also the junction tap)

        init(_ p: ParamSet, sr: Int) {
            let sz = DelayLine.size(p, sr: sr)
            buf = [Double](repeating: 0, count: sz)
            rng = p.seed
            dels = Double(p.delay) / 44100.0
            drift = Double(p.drift)
            maxcount = Int(floor(Double(sr) / (Double(p.randfreq) * 0.001)))
            var readpos = dels
            readpos += Double(rng) * (drift * 0.0001) / 32768.0
            readpos = Double(sz) - readpos * Double(sr)
            irpos = Int(floor(readpos))
            frpos = Int(floor((readpos - Double(irpos)) * Double(Bigverb.fracScale)))
            generateNextLine(sr: sr)
        }

        static func size(_ p: ParamSet, sr: Int) -> Int {
            let sz = Double(p.delay) / 44100.0 + (Double(p.drift) * 0.0001) * 1.125
            return Int(floor(16.0 + sz * Double(sr)))
        }

        mutating func generateNextLine(sr: Int) {
            if rng < 0 { rng += 0x10000 }
            rng = (1 + rng * 0x3d09) & 0xFFFF
            if rng >= 0x8000 { rng -= 0x10000 }
            counter = maxcount
            var curdel = Double(wpos) - (Double(irpos) + Double(frpos) / Double(Bigverb.fracScale))
            while curdel < 0 { curdel += Double(buf.count) }
            curdel /= Double(sr)
            let nxtdel = Double(rng) * (drift * 0.0001) / 32768.0 + dels
            var inc = ((curdel - nxtdel) / Double(counter)) * Double(sr)
            inc += 1
            self.inc = Int(floor(inc * Double(Bigverb.fracScale)))
        }

        mutating func compute(_ x: Double, fdbk: Double, filt: Double, sr: Int) -> Double {
            let sz = buf.count
            buf[wpos] = x - y
            wpos += 1
            if wpos >= sz { wpos -= sz }
            if frpos >= Bigverb.fracScale {
                irpos += frpos >> Bigverb.fracNBits
                frpos &= Bigverb.fracMask
            }
            if irpos >= sz { irpos -= sz }
            let frac = Double(frpos) / Double(Bigverb.fracScale)
            // 3rd-order Lagrangian interpolation coefficients
            let d = ((frac * frac) - 1) / 6.0
            let tmp0 = (frac + 1.0) * 0.5
            let tmp1 = 3.0 * d
            let a = tmp0 - 1.0 - d
            let c = tmp0 - tmp1
            let b = tmp1 - frac
            var s0: Double, s1: Double, s2: Double, s3: Double
            let n = irpos
            if n > 0 && n < sz - 2 {
                s0 = buf[n - 1]; s1 = buf[n]; s2 = buf[n + 1]; s3 = buf[n + 2]
            } else {
                var k = n - 1
                if k < 0 { k += sz }
                s0 = buf[k]
                k += 1; if k >= sz { k -= sz }; s1 = buf[k]
                k += 1; if k >= sz { k -= sz }; s2 = buf[k]
                k += 1; if k >= sz { k -= sz }; s3 = buf[k]
            }
            var out = (a * s0 + b * s1 + c * s2 + d * s3) * frac + s1
            frpos += inc
            out *= fdbk
            out += (y - out) * filt
            y = out
            counter -= 1
            if counter <= 0 { generateNextLine(sr: sr) }
            return out
        }

        mutating func reset() {
            for i in buf.indices { buf[i] = 0 }
            y = 0
        }
    }

    private var delays: [DelayLine]
    private let sr: Int
    private var filt = 1.0
    private var pcutoff = -1.0

    /// Feedback level 0…1 — the decay ("size" of the room). Reference default 0.93.
    public var size = 0.93
    /// Feedback-loop lowpass in Hz. Reference default 10 kHz.
    public var cutoff = 10_000.0

    public init(sr: Double) {
        let isr = max(8000, Int(sr.rounded()))
        self.sr = isr
        delays = Bigverb.params.map { DelayLine($0, sr: isr) }
    }

    /// One stereo sample in → the WET stereo pair (no dry mixed in).
    public mutating func process(_ inL: Double, _ inR: Double) -> (Double, Double) {
        if pcutoff != cutoff {
            pcutoff = cutoff
            var f = 2.0 - cos(pcutoff * 2.0 * .pi / Double(sr))
            filt = f - (f * f - 1.0).squareRoot()
            f = filt
        }
        // junction pressure: the coupled sum of every line's last output
        var jp = 0.0
        for i in 0..<8 { jp += delays[i].y }
        jp *= 0.25
        let ainL = jp + inL
        let ainR = jp + inR
        let fdbk = min(max(size, 0.0), 0.999)
        var lsum = 0.0, rsum = 0.0
        for i in 0..<8 {
            if i & 1 == 1 {
                rsum += delays[i].compute(ainR, fdbk: fdbk, filt: filt, sr: sr)
            } else {
                lsum += delays[i].compute(ainL, fdbk: fdbk, filt: filt, sr: sr)
            }
        }
        return (lsum * 0.35, rsum * 0.35)
    }

    public mutating func reset() {
        for i in delays.indices { delays[i].reset() }
    }
}
