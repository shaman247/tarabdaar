import XCTest
@testable import SarangiKit

final class BowBodyResponseTests: XCTestCase {
    private func engine(_ bp: BowParams) -> BowEngine {
        BowEngine(tables: BowTables.buildOpenString(sr: 96000, tonic: 261.63, bp: bp),
                  mapper: BowControlMapper(), bp: bp, rfir: [],
                  eLp: bp.v("bow_rad_lp", 8000), reverbRT60: 1,
                  reverbPredelayMs: 0, reverbMix: 0, reverbWidth: 0)
    }

    /// Diagnostics follow accepted live coefficients, including ramps, and ignore unapplied or rejected tables.
    func testBodyResponseTracksAdoptedCoefficients() throws {
        var bp = try XCTUnwrap(Presets.bowedStringParams())
        let running = engine(bp)
        let original = running.bodyResponse(points: 128)
        bp.num["bow_body_q"] = bp.v("bow_body_q", 25) * 1.5
        bp.num["bow_body_c0"] = bp.v("bow_body_c0", 0.4) * 0.5
        bp.num["bow_rad_lp"] = bp.v("bow_rad_lp", 8000) * 0.5
        let updated = BowTables.buildOpenString(sr: 96000, tonic: 261.63, bp: bp)
        running.setLiveParams(bp: bp, scalars: updated.scalars, tables: updated)
        XCTAssertEqual(running.bodyResponseRevision, original.revision)
        for _ in 0..<32 { running.applyPendingLive(n48: 4096) }
        let actual = running.bodyResponse(points: 128)
        let rebuilt = engine(bp).bodyResponse(points: 128)
        XCTAssertGreaterThan(actual.revision, original.revision)
        XCTAssertNotEqual(actual.radDb, original.radDb)
        for (lhs, rhs) in [(actual.radDb, rebuilt.radDb), (actual.chainDb, rebuilt.chainDb),
                           (actual.admDb, rebuilt.admDb)] {
            XCTAssertLessThan(zip(lhs, rhs).map { abs($0 - $1) }.max() ?? .infinity, 1e-8)
        }
        XCTAssertEqual(actual.modes.map(\.q), rebuilt.modes.map(\.q))

        running.setLiveParams(bp: bp, scalars: updated.scalars, tables: updated)
        running.applyPendingLive(n48: 4096)
        XCTAssertEqual(running.bodyResponseRevision, actual.revision)
        var rejected = updated
        rejected.ba1.removeLast(); rejected.ba2.removeLast(); rejected.bn0.removeLast()
        rejected.bA.removeLast(); rejected.bC.removeLast()
        running.setLiveParams(bp: bp, scalars: updated.scalars, tables: rejected)
        running.applyPendingLive(n48: 4096)
        XCTAssertEqual(running.bodyResponseRevision, actual.revision)
        XCTAssertEqual(running.bodyResponse(points: 128).radDb, actual.radDb)
    }
}
