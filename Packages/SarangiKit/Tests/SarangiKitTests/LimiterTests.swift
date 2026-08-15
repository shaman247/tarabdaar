import XCTest
@testable import SarangiKit

/// OUTPUT SAFETY LIMITER (2026-08-01). Three pins: it actually bounds a
/// hot render, it is BIT-EXACT below its ceiling (the parity guarantee),
/// and after a peak it releases back to exact unity so the passthrough
/// re-nulls.
final class LimiterTests: XCTestCase {

    private func makeEngine(bp: BowParams, outGain: Double) -> BowEngine {
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: 261.63, bp: bp)
        let engine = BowEngine(tables: tables, mapper: BowControlMapper(),
                               bp: bp, sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: 0.6, reverbPredelayMs: 10.0,
                               reverbMix: 0.0, reverbWidth: 0.0)
        engine.outGain = outGain
        return engine
    }

    private func render(_ engine: BowEngine, seconds: Double,
                        into out: inout [Double]) {
        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        var left = Int(seconds * 48000.0)
        while left > 0 {
            let m = min(1024, left)
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    engine.render(frames: m, outL: lb.baseAddress!,
                                  outR: rb.baseAddress!)
                }
            }
            for i in 0..<m {
                XCTAssertTrue(l[i].isFinite && r[i].isFinite)
                out.append(l[i])
            }
            left -= m
        }
    }

    func testLimiterBoundsHotOutput() {
        var bp = BowedStringEngineTests.stringBP()
        bp.num["bow_lim_thresh"] = 0.5
        // an outGain far past sane: without the limiter this clips hard
        let engine = makeEngine(bp: bp, outGain: 20.0)
        engine.mapper.midi(0x90, 60, 127)
        var y: [Double] = []
        render(engine, seconds: 2.0, into: &y)
        let peak = y.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.4, "the hot phrase never reached the "
                             + "ceiling — the bound was not exercised")
        // hard bound: ceiling × 1.25 attack clamp, capped at full scale
        XCTAssertLessThanOrEqual(peak, min(1.0, 0.5 * 1.25) + 1e-9)
        // the sustained region rides AT the ceiling, not above it
        let sustained = y.suffix(48000).map(abs).filter { $0 > 0.5 * 1.02 }
        XCTAssertLessThan(Double(sustained.count) / 48000.0, 0.01,
                          "more than 1% of the sustain exceeds the ceiling")
    }

    /// Below the ceiling the limiter multiplies nothing: two engines whose
    /// ONLY difference is the (never-reached) threshold render
    /// bit-identically.
    func testBitExactBelowCeiling() {
        var bpA = BowedStringEngineTests.stringBP()
        bpA.num["bow_lim_thresh"] = 0.8
        var bpB = bpA
        bpB.num["bow_lim_thresh"] = 0.999
        let a = makeEngine(bp: bpA, outGain: 0.05)
        let b = makeEngine(bp: bpB, outGain: 0.05)
        a.mapper.midi(0x90, 60, 100)
        b.mapper.midi(0x90, 60, 100)
        var ya: [Double] = [], yb: [Double] = []
        render(a, seconds: 1.5, into: &ya)
        render(b, seconds: 1.5, into: &yb)
        XCTAssertEqual(ya, yb, "an unengaged limiter perturbed the render")
    }

    /// After the hot passage ends, the gain releases back to EXACT unity —
    /// the tail of a limited render re-nulls against an unlimited one.
    func testReleaseReturnsToExactUnity() {
        var bpA = BowedStringEngineTests.stringBP()
        bpA.num["bow_lim_thresh"] = 0.2
        var bpB = bpA
        bpB.num["bow_lim_thresh"] = 0.999
        let a = makeEngine(bp: bpA, outGain: 8.0)
        let b = makeEngine(bp: bpB, outGain: 8.0)
        for e in [a, b] {
            e.mapper.midi(0x90, 60, 127)
        }
        var ya: [Double] = [], yb: [Double] = []
        render(a, seconds: 1.0, into: &ya)
        render(b, seconds: 1.0, into: &yb)
        XCTAssertNotEqual(ya, yb, "the hot phrase must engage A's limiter")
        for e in [a, b] { e.mapper.midi(0x80, 60, 0) }
        // long enough for the ring to fall below 0.2 and the gain to snap
        // back to exactly 1.0
        render(a, seconds: 4.0, into: &ya)
        render(b, seconds: 4.0, into: &yb)
        let na = ya.suffix(24000), nb = yb.suffix(24000)
        XCTAssertEqual(Array(na), Array(nb),
                       "the released limiter must re-null bit-exactly")
    }
}
