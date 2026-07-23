import XCTest
@testable import SarangiKit

/// GATE A of the live bow port: the Swift table builder
/// (`BowTables.build`) must reproduce `bowstring._kernel_setup` — every
/// per-voice column, body array and the 52-scalar list — to 1e-12 for the
/// default fitted config. The golden carries BOTH the exact inputs
/// (tuning strings/classes/tonic + merged q + bp) and the expected outputs.
/// Regenerate with:  python3 scripts/export_bow_tables.py
final class BowTableParityTests: XCTestCase {

    private func loadGolden() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "bow_tables_default",
                                          withExtension: "json",
                                          subdirectory: "Goldens") else {
            throw XCTSkip("bow_tables_default golden not found — run scripts/export_bow_tables.py")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dict = obj as? [String: Any] else {
            XCTFail("golden is not a JSON object")
            return [:]
        }
        return dict
    }

    func testKernelTablesMatchPython() throws {
        let golden = try loadGolden()
        guard let tj = golden["tuning"] as? [String: Any],
              let qj = golden["q"] as? [String: Any],
              let bpj = golden["bp"] as? [String: Any],
              let expect = golden["expect"] as? [String: Any],
              let sr = (golden["sr"] as? NSNumber)?.doubleValue,
              let nBow = (golden["n_bow"] as? NSNumber)?.doubleValue
        else { return XCTFail("golden missing sections") }

        // inputs — the same parse path the live loader uses
        guard let tonic = (tj["tonic"] as? NSNumber)?.doubleValue,
              let rows = tj["strings"] as? [[Any]]
        else { return XCTFail("golden tuning malformed") }
        let strings = rows.compactMap {
            row -> (f: Double, gain: Double, t60: Double, bright: Bool)? in
            guard row.count >= 4,
                  let f = (row[0] as? NSNumber)?.doubleValue,
                  let g = (row[1] as? NSNumber)?.doubleValue,
                  let t = (row[2] as? NSNumber)?.doubleValue,
                  let b = row[3] as? NSNumber
            else { return nil }
            return (f, g, t, b.boolValue)
        }
        XCTAssertEqual(strings.count, rows.count)
        let cls = (tj["string_class"] as? [Any])?.compactMap { $0 as? String }
        let absIdx = Set(((tj["t60_abs_idx"] as? [Any]) ?? [])
            .compactMap { ($0 as? NSNumber)?.intValue })
        let tuning = BowTuning(tonic: tonic, strings: strings, stringClass: cls,
                               t60AbsIdx: absIdx)
        var q = BowNetParams()
        q.merge(json: qj)
        guard let bp = BowParams(json: bpj) else {
            return XCTFail("golden bp malformed")
        }

        let t = BowTables.build(sr: sr, tuning: tuning, q: q, bp: bp, nBow: nBow)

        func expArr(_ name: String) -> [Double]? {
            (expect[name] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        func check(_ name: String, _ got: [Double], tol: Double = 1e-12) {
            guard let want = expArr(name) else {
                return XCTFail("golden missing expected array \(name)")
            }
            // LOUD count fail: a voice-count mismatch means the choir
            // expansion diverged — value diffs would only obscure it.
            guard got.count == want.count else {
                return XCTFail("\(name): COUNT MISMATCH swift=\(got.count) " +
                               "python=\(want.count)")
            }
            var worst = 0.0
            var worstIdx = -1
            for i in got.indices {
                let e = abs(got[i] - want[i])
                if e > worst { worst = e; worstIdx = i }
            }
            XCTAssertLessThanOrEqual(
                worst, tol,
                "\(name)[\(worstIdx)] err \(worst) (swift \(got[worstIdx]) " +
                "vs python \(want[worstIdx]))")
        }

        // integer delays must be EXACT (an off-by-one L is a retuned string)
        guard let wantL = expArr("L") else { return XCTFail("golden missing L") }
        XCTAssertEqual(t.L.count, wantL.count,
                       "L: COUNT MISMATCH swift=\(t.L.count) python=\(wantL.count)")
        if t.L.count == wantL.count {
            for i in t.L.indices {
                XCTAssertEqual(Double(t.L[i]), wantL[i], "L[\(i)]")
            }
        }
        check("cs", t.cs); check("cp", t.cp)
        check("w0", t.w0); check("w1", t.w1); check("w2", t.w2)
        check("w3", t.w3); check("w4", t.w4)
        check("g", t.g); check("lpA", t.lpA); check("wout", t.wout)
        check("kap", t.kap); check("alphaw", t.alphaw)
        check("jw", t.jw); check("jl", t.jl); check("jn", t.jn)
        check("chg", t.chg)
        check("zdrv", t.zdrv); check("zi", t.zi); check("twt", t.twt)
        check("ba1", t.ba1); check("ba2", t.ba2); check("bn0", t.bn0)
        check("bA", t.bA); check("bC", t.bC)
        // the 52 scalars include the kret passivity projection through the
        // _y_max admittance sweep — the strongest float-parity probe here
        check("scalars", t.scalars)
        XCTAssertEqual(t.scalars.count, 61)
    }

    /// MEASURED-ABSOLUTE t60 (python 07-15 law, Swift port 2026-07-16i): a
    /// row named in `t60AbsIdx` carries the pencil t60 of the real line, so
    /// BOTH `B_t60_scale` and the `N_t60_cap` ring cap must be bypassed for
    /// it — an identical row that is NOT named takes min(t60·scale, cap).
    /// The golden's fitted tuning exercises this only incidentally; this
    /// pins the branch itself.
    func testMeasuredAbsoluteT60BypassesScaleAndCap() {
        let sr = 96000.0
        let f = 293.66, t60 = 6.0
        let scale = 3.0, cap = 1.5
        func tuning(abs isAbs: Bool) -> BowTuning {
            BowTuning(tonic: 261.63, strings: [(f, 0.5, t60, false)],
                      stringClass: ["raga"], t60AbsIdx: isAbs ? [0] : [])
        }
        let bp = BowedStringEngineTests.stringBP()
        var q = BowNetParams(num: ["B_gain": 0.4, "B_bright": 0.0,
                                   "B_t60_scale": scale, "N_t60_cap": cap])

        let tAbs = BowTables.build(sr: sr, tuning: tuning(abs: true), q: q,
                                   bp: bp, nBow: 1.0)
        let tRel = BowTables.build(sr: sr, tuning: tuning(abs: false), q: q,
                                   bp: bp, nBow: 1.0)
        // one taraf voice (no polarization split, bright choir off) then the
        // 3 open played strings — voice 0 is the row under test
        XCTAssertEqual(tAbs.L.count, 4)

        func loopGain(_ t60: Double) -> Double {
            BowTables.webLoopCoeffs(f0: f, t60: t60, sr: sr,
                                    inharm: 0.0, damp: 0.0).g
        }
        XCTAssertEqual(tAbs.g[0], loopGain(t60), accuracy: 1e-15,
                       "measured-absolute t60 was scaled or capped")
        XCTAssertEqual(tRel.g[0], loopGain(min(t60 * scale, cap)),
                       accuracy: 1e-15, "relative t60 lost its scale/cap")
        XCTAssertGreaterThan(tAbs.g[0], tRel.g[0],
                             "the capped voice must decay faster")

        // and the bypass is total: moving the scale cannot move an
        // absolute-t60 voice at all
        q.num["B_t60_scale"] = 1.0
        let tAbs1 = BowTables.build(sr: sr, tuning: tuning(abs: true), q: q,
                                    bp: bp, nBow: 1.0)
        XCTAssertEqual(tAbs1.g[0], tAbs.g[0],
                       "B_t60_scale reached the measured-decay voice")
    }
}
