import XCTest
import CBowKernel
@testable import SarangiKit

/// THE BYTE-NULL CONTRACT: every optional path of the String voice, armed at
/// its resting value, renders bit-identically to an engine that never heard of
/// it. A failure names the "0 = off" knob that is no longer off.
final class ByteNullContractTests: XCTestCase {
    /// Zero release damping preserves a freely ringing kernel sample for sample.
    func testZeroStringDampingIsByteNull() throws {
        func render(setZero: Bool) throws -> [Double] {
            var t = BowTables.buildOpenString(sr: 96000, tonic: 261.63,
                                              bp: BowedStringEngineTests.stringBP())
            let state = try XCTUnwrap(bow_poly_init(1, 96000, 0, nil, nil,
                                                   nil, nil, nil, &t.scalars))
            defer { bow_poly_free(state) }
            let frames = 256
            let pitch = [Double](repeating: 261.63, count: frames)
            let speed = [Double](repeating: 0.1, count: frames)
            let force = [Double](repeating: 0.2, count: frames)
            let position = [Double](repeating: 0.1, count: frames)
            var gate = [Double](repeating: 1, count: frames)
            let zero = [Double](repeating: 0, count: frames)
            var output = zero, result: [Double] = []
            for block in 0..<160 {
                if block == 80 { gate = zero }
                if setZero { bow_poly_set_string_damping(state, 0, 0, pitch[0]) }
                bow_poly_process(state, Int32(frames), Int32(frames), pitch,
                                 speed, force, position, gate, zero, &output)
                result += output
            }
            return result
        }
        let reference = try render(setZero: false)
        XCTAssertTrue(reference.suffix(256).contains { abs($0) > 1e-8 })
        XCTAssertEqual(try render(setZero: true), reference)
    }

    private func makeEngine(_ overrides: [String: Double] = [:]) -> BowEngine {
        var bp = BowedStringEngineTests.stringBP()
        bp.num["bow_jt_gain"] = 1.0
        for (k, v) in overrides { bp.num[k] = v }
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
        e.mapper.touchOn(60, pitchSemis: 60)
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
            ("fitted observations at zero", { e in
                for i in [0, 1, 4, 8, 9] { e.setFittedControl(i, 0) }
                e.setFittedControl(2, 2); e.setFittedControl(3, 150)
                for i in 5...7 { e.setFittedControl(i, 12) }
            }),
            ("raga pluck loudness with backend off", { $0.setJtDualPluckLevel(1) }),
            ("raga bow bloom with backend off", { $0.setJtBowBloom(1) }),
            ("two-direction selectivity with backend off", { $0.setJtDualSelectivity(1) }),
            ("two-direction tone with backend off", { $0.setJtDualTone(hz: 2000) }),
            ("two-direction displacement with backend off", { $0.setJtDualDisplacement(mm: 1) }),
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
            ("evolution pulse disabled", {
                $0.setJtEvolutionPulse(amount: 0, attackMs: 1, decayMs: 2000) }),
            ("taraf drive at the build value", {
                $0.setJtDrive(BowedStringEngineTests.stringBP().v("bow_jt_drive", 1.0)) }),
            ("drive level norm 1", { $0.setJtDriveNorm(1) }),
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

    /// The regime grip never touches a note that captured its fundamental:
    /// the shipped grip and a fully disarmed one render the healthy phrase
    /// bit-identically.
    func testRegimeGripIsByteNullOnACapturedNote() {
        let armed = phrase(makeEngine())
        let disarmed = phrase(makeEngine(["bow_grip_beta": 0, "bow_grip_v_db": 0,
                                          "bow_grip_db": 0]))
        XCTAssertEqual(armed.count, disarmed.count)
        if let i = zip(armed, disarmed).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            XCTFail("the regime grip engaged on a captured note: first divergence at sample \(i)")
        }
    }
}
