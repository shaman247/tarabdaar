import XCTest
@testable import SarangiKit

/// The two jt drive shapes and the law that relates them.
final class JtDriveShapeTests: XCTestCase {

    private func tables() throws -> JtTables {
        let bp = BowedStringEngineTests.stringBP()
        let jt = BowTables.buildJawariTables(rows: BowedStringEngineTests.testTaraf,
                                             srk: 96000.0, bp: bp)
        return try XCTUnwrap(jt)
    }

    /// NORMALISATION LAW: the termination shape is ENERGY-matched to the
    /// 0.90 L tap over each row's own built modes, so the morph
    /// (`bow_jt_drive_term`) redistributes a row's fitted drive energy up
    /// the mode stack instead of adding level. A mode-1 match (the first
    /// cut) multiplied every mode above the first by ≈ 1.4·k.
    func testTerminationDriveIsEnergyMatchedPerRow() throws {
        let jt = try tables()
        XCTAssertEqual(jt.phiDT.count, jt.phiD.count)
        var off = 0
        for (row, mc) in jt.M.enumerated() {
            let M = Int(mc)
            var eTap = 0.0, eTerm = 0.0
            for k in off..<(off + M) {
                eTap += jt.phiD[k] * jt.phiD[k]
                eTerm += jt.phiDT[k] * jt.phiDT[k]
            }
            XCTAssertGreaterThan(eTap, 0)
            XCTAssertEqual(eTerm, eTap, accuracy: eTap * 1e-9,
                           "row \(row): termination drive energy must equal the tap's")
            // and the shape itself: |phiDT_k| rises linearly in k with
            // alternating sign (no comb null anywhere)
            for k in 0..<M {
                let v = jt.phiDT[off + k]
                XCTAssertNotEqual(v, 0.0)
                let want = (k & 1) == 0 ? -1.0 : 1.0
                XCTAssertEqual((v < 0 ? -1.0 : 1.0), want,
                               "row \(row) mode \(k + 1): sign must follow (−1)^k")
                if k > 0 {
                    let ratio = abs(v) / abs(jt.phiDT[off + k - 1])
                    XCTAssertEqual(ratio, Double(k + 1) / Double(k), accuracy: 1e-9)
                }
            }
            // the tap DOES have nulls — the reason the shape exists
            off += M
        }
    }
}
