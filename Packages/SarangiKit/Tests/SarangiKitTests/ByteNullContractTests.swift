import XCTest
@testable import SarangiKit

/// THE BYTE-NULL CONTRACT: every optional path of the String voice, armed
/// at its resting value, renders bit-identically to an engine that never
/// heard of it. One phrase, one reference render, one assertion per path.
/// A failure here means a "0 = off" knob is no longer off — the parity
/// hash (`TarafRemovalParityTests`) would move too, but this names the
/// culprit.
final class ByteNullContractTests: XCTestCase {
    private func makeEngine() -> BowEngine {
        var bp = BowedStringEngineTests.stringBP()
        bp.num["bow_jt_gain"] = 1.0
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: 261.63, bp: bp)
        tables.jt = BowTables.buildJawariTables(
            rows: BowedStringEngineTests.testTaraf,
            srk: sr * Double(osf), bp: bp)
        let e = BowEngine(tables: tables, mapper: BowControlMapper(), bp: bp,
                          sr: sr, rfir: [], eLp: bp.v("bow_rad_lp", 8000.0),
                          reverbRT60: 1.0, reverbPredelayMs: 15.0,
                          reverbMix: 0.0, reverbWidth: 0.0, maxPoly: 4)
        e.outGain = 0.1
        return e
    }

    /// Bow Sa 0.4 s, lift, ring 0.3 s; both channels concatenated.
    private func phrase(_ e: BowEngine) -> [Double] {
        e.mapper.setAxis(expr: 60.0 / 127.0)
        e.mapper.setAxis(press: 80.0 / 127.0)
        e.mapper.touchOn(60, pitchSemis: 60, velocity: 100.0 / 127.0)
        let nBow = Int(0.4 * e.sr), nRing = Int(0.3 * e.sr)
        var l = [Double](repeating: 0, count: nBow + nRing)
        var r = [Double](repeating: 0, count: nBow + nRing)
        func render(_ from: Int, _ count: Int) {
            var done = 0
            while done < count {
                let k = min(256, count - done)
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in
                        e.render(frames: k, outL: lp.baseAddress! + from + done,
                                 outR: rp.baseAddress! + from + done)
                    }
                }
                done += k
            }
        }
        render(0, nBow)
        e.mapper.touchOff(60)
        render(nBow, nRing)
        return l + r
    }

    func testRestingValuesAreByteNull() {
        let reference = phrase(makeEngine())
        XCTAssertTrue(reference.contains { $0 != 0 }, "the phrase must make sound")
        let cases: [(String, (BowEngine) -> Void)] = [
            ("scope meters armed", { $0.setScopeArmed(true) }),
            ("bus meter armed", { $0.setBusMeter(true) }),
            ("fx rack at rest", { e in FXPoint.allCases.forEach { e.setFX($0, FXSettings()) } }),
            ("taraf cap 0", { $0.setJtCap(hard: 0, ratio: 1) }),
            ("bus balance 0", { $0.setBusBalance(0) }),
            ("inject gain 0", { $0.setJtInjectGain(0) }),
            ("taraf damp 0", { $0.setTarafDamp(0) }),
            ("tone tilt 0", { $0.setToneTilt(0) }),
            ("jt body 0", { $0.setJtBody(0) }),
            ("bridge coupling 0", { $0.setJtCouple(0) }),
            ("evolve register 0", { $0.setJtEvolveRegister(0) }),
            ("master gain 1", { $0.setMasterGain(1) }),
            ("jt tone LP bypass", { $0.setJtToneLp(hz: 20000) }),
        ]
        for (name, arm) in cases {
            let e = makeEngine()
            arm(e)
            let out = phrase(e)
            XCTAssertEqual(out.count, reference.count, name)
            if let i = zip(out, reference).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                XCTFail("\(name) is not byte-null: first divergence at sample \(i) (\(out[i]) vs \(reference[i]))")
            }
        }
    }
}
