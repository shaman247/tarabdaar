import XCTest
import CBowKernel
@testable import SarangiKit

/// Poly kernel: an eight-note max-force chord stays bounded and releases.
final class BowPolyTests: XCTestCase {

    /// Driven from the shipping artifact and tarab: eight notes at maximum
    /// force stay finite and bounded, stop growing, and release.
    func testPolyEightNoteChordStaysBoundedAndReleases() throws {
        guard var bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // Stability must not depend on asynchronous drive blocks dropped under test load.
        bp.num["bow_jt_async"] = 0
        bp.num["bow_jt_threads"] = 0
        let sr = 48000.0
        let tonic = 328.9
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonic, bp: bp)
        let taraf = Presets.state(.sarangiPilu).resolvedStrings
            .filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        tables.jt = BowTables.buildJawariTables(
            rows: taraf.filter { BowTables.jtSteelRow($0.f, tonic: tonic) },
            srk: sr * Double(osf), bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp, sr: sr,
                               rfir: [], eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: 15.0,
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: 0.0, maxPoly: 8)
        engine.outGain = bp.v("bow_live_trim", 0.175)

        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        var peak = 0.0
        func run(seconds: Double) -> Double {
            var acc = 0.0
            var n = 0
            var left = Int(seconds * sr)
            while left > 0 {
                let m = min(1024, left)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                for i in 0..<m {
                    XCTAssertTrue(l[i].isFinite && r[i].isFinite,
                                  "poly chord render went non-finite")
                    let s = l[i] + r[i]
                    acc += s * s
                    peak = max(peak, abs(s))
                }
                n += m
                left -= m
            }
            return (acc / Double(n)).squareRoot()
        }

        mapper.setAxis(expr: 1.0, press: 1.0, pos: 0.5)
        for note in [57, 60, 62, 64, 67, 69, 72, 76] {
            mapper.touchOn(UInt16(note), pitchSemis: Double(note))
        }
        _ = run(seconds: 0.5)                       // speak/settle
        let sustain = run(seconds: 2.5)
        XCTAssertGreaterThan(sustain, 1e-3, "chord made no sound")
        XCTAssertLessThan(peak, 5.0,
                          "8-note max-force chord unbounded (peak \(peak))")
        // energy must not still be GROWING at the end of the sustain
        let s2 = run(seconds: 1.0)
        XCTAssertLessThan(s2, sustain * 3.0, "chord energy still growing")

        mapper.touchAllOff()                   // all off
        // the taraf rings on by design — settle well clear of the release
        _ = run(seconds: 7.5)
        let tail = run(seconds: 0.5)
        XCTAssertLessThan(tail, sustain * 0.5, "chord did not release")
    }

}
