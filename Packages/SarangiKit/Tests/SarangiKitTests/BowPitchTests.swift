import XCTest
@testable import SarangiKit

final class BowPitchTests: XCTestCase {
    /// Rendered fundamentals follow concert pitch across register damping, tonics and live loss edits.
    func testRenderedPitchTracksLoopFilters() throws {
        for tonic in [220.0, 440.0] {
            for hz in [110.0, Pitch.hz(fractionalMidi: 64), 440.0, 880.0] {
                var bp = try XCTUnwrap(Presets.bowedStringParams())
                bp.num["bow_drift_cents"] = 0
                let mapper = BowControlMapper()
                mapper.setAxis(expr: 0.6, press: 0.01, pos: 0.93)
                let tables = BowTables.buildOpenString(sr: 96000, tonic: tonic, bp: bp)
                let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                    rfir: [], eLp: 8000, reverbRT60: 1,
                    reverbPredelayMs: 0, reverbMix: 0, reverbWidth: 0)
                engine.outGain = 0.05
                mapper.touchOn(1, pitchSemis: Pitch.fractionalMidi(hz: hz))
                for edited in [false, true] {
                    if edited {
                        bp.num["bow_nut_fc"] = 7000
                        bp.num["bow_br_fc"] = 8000
                        engine.setLiveParams(bp: bp, scalars: BowTables.buildOpenString(
                            sr: 96000, tonic: tonic, bp: bp).scalars)
                    }
                    var l = [Double](repeating: 0, count: 1024), r = l
                    var signal = [Double]()
                    for block in 0..<80 {
                        l.withUnsafeMutableBufferPointer { lp in
                            r.withUnsafeMutableBufferPointer { rp in
                                engine.render(frames: 1024, outL: lp.baseAddress!, outR: rp.baseAddress!)
                            }
                        }
                        if block >= 48 { signal.append(contentsOf: zip(l, r).map { ($0 + $1) * 0.5 }) }
                    }
                    XCTAssertGreaterThan(signal.reduce(0) { $0 + $1 * $1 }, 1e-8)
                    let measured = fundamental(signal, near: hz)
                    let cents = 1200 * log2(measured / hz)
                    XCTAssertLessThan(abs(cents), 3,
                        "\(hz) Hz at tonic \(tonic), edited losses \(edited): \(measured) Hz (\(cents) cents)")
                }
            }
        }
    }

    private func fundamental(_ signal: [Double], near hz: Double) -> Double {
        let windowed = signal.enumerated().map { i, x in
            x * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(signal.count - 1)))
        }
        func power(_ frequency: Double) -> Double {
            let angle = 2 * Double.pi * frequency / 48000
            let c = cos(angle), s = sin(angle)
            var re = 0.0, im = 0.0, cr = 1.0, ci = 0.0
            for x in windowed {
                re += x * cr; im += x * ci
                let next = cr * c - ci * s
                ci = ci * c + cr * s; cr = next
            }
            return re * re + im * im
        }
        // Locate the fundamental's local peak, then refine below FFT-bin spacing.
        let step = hz * 0.001
        let peak = (-30...30).max { power(hz + Double($0) * step) < power(hz + Double($1) * step) }!
        var lo = hz + Double(peak - 1) * step, hi = hz + Double(peak + 1) * step
        for _ in 0..<24 {
            let a = lo + (hi - lo) / 3, b = hi - (hi - lo) / 3
            if power(a) < power(b) { lo = a } else { hi = b }
        }
        return (lo + hi) * 0.5
    }
}
