import XCTest
@testable import SarangiKit

/// Stereo side path: L ≠ R, and the L+R fold-down equals the mono render.
final class BowStereoTests: XCTestCase {

    private func makeEngine(stereo: Bool) -> BowEngine {
        var bp = BowedStringEngineTests.stringBP()
        bp.num["bow_jt_gain"] = 1.0
        if stereo {
            // the width law is the WHOLE stereo law: every source stays
            // centred and the side stream carries only the second
            // observation point (voice bus + jt-wash bus instances)
            bp.num["bow_st_width"] = 0.6
        }
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tonic = 261.63
        let taraf = BowedStringEngineTests.testTaraf
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonic, bp: bp)
        tables.jt = BowTables.buildJawariTables(rows: taraf,
                                                srk: sr * Double(osf),
                                                bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: 1.0, reverbPredelayMs: 15.0,
                               reverbMix: 0.08,
                               reverbWidth: stereo ? 0.6 : 0.0,
                               maxPoly: 8)
        // headroom: the fold-down invariance below is a BELOW-CEILING
        // contract — the safety limiter is linked-stereo (one gain from
        // max(|L|, |R|)), so a render that clips would legitimately fold
        // down differently from the mono one. 0.07 keeps the armed peak
        // (~0.6) under the 0.8 ceiling with the pin force radiating.
        engine.outGain = 0.07
        return engine
    }

    private func renderSeconds(_ engine: BowEngine, seconds: Double)
        -> (l: [Double], r: [Double]) {
        engine.mapper.midi(0xB0, 11, 60)     // expression
        engine.mapper.midi(0xB0, 1, 80)      // press
        engine.mapper.midi(0x91, 62, 96)     // note on, MPE ch 1
        let sr = engine.sr
        let n = Int(seconds * sr)
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        var done = 0
        while done < n {
            let m = min(256, n - done)
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    engine.render(frames: m, outL: lb.baseAddress! + done,
                                  outR: rb.baseAddress! + done)
                }
            }
            done += m
        }
        return (l, r)
    }

    func testStereoSidePathAndMonoFoldDownInvariance() {
        let mono = renderSeconds(makeEngine(stereo: false), seconds: 2.0)
        let wide = renderSeconds(makeEngine(stereo: true), seconds: 2.0)

        func rms(_ x: [Double]) -> Double {
            (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
        }

        // 1. unarmed: exactly the legacy equal split
        let monoDiff = zip(mono.l, mono.r).map { abs($0 - $1) }.max() ?? 1
        XCTAssertEqual(monoDiff, 0.0, "legacy path must stay L == R")
        let monoRMS = rms(mono.l)
        XCTAssertGreaterThan(monoRMS, 1e-4, "silent render — bow not speaking")

        // 2. armed: a real side stream
        let side = zip(wide.l, wide.r).map { 0.5 * ($0 - $1) }
        let sideRMS = rms(side)
        let midRMS = rms(zip(wide.l, wide.r).map { 0.5 * ($0 + $1) })
        XCTAssertGreaterThan(sideRMS / midRMS, 0.02,
                             "armed stereo produced no side energy")

        // 3. fold-down invariance: mid of the armed render == the unarmed
        //    render (identical deterministic mid path; side cancels)
        var maxErr = 0.0
        for i in 0..<mono.l.count {
            let sum = 0.5 * (wide.l[i] + wide.r[i])
            maxErr = max(maxErr, abs(sum - mono.l[i]))
        }
        XCTAssertLessThan(maxErr, 1e-9,
                          "armed L+R fold-down diverged from the mono render")
        print("bow stereo: mid rms \(String(format: "%.5f", midRMS)), " +
              "side/mid \(String(format: "%.3f", sideRMS / midRMS)), " +
              "folddown err \(String(format: "%.2e", maxErr))")
    }

}
