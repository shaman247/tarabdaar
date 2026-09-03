import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Two bridges: the chromatic knobs (level / level norm / evolution) bake
/// only chromatic rows, and the chromatic registry defaults are the engine
/// truth. The contact GEOMETRY is shared — derived from `bow_jt_*`.
final class TarabSetTests: XCTestCase {

    private func bp() throws -> BowParams {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        return bp
    }

    // MARK: - Model

    // MARK: - Row plan + tables

    /// A chromatic-bridge knob moves ONLY the chromatic rows' tables (the
    /// raga rows are byte-identical), and at rest the two bridges bake the
    /// same jawari: a chromatic row at the raga bridge's values is
    /// identical to the same row built as a raga row. Since the geometry
    /// folded into `bow_jt_*`, the level and the level norm are the only
    /// per-bank bakes (evolution is a live kernel push).
    func testChromaticKnobsBakeOnlyChromaticRows() throws {
        var bp = try bp()
        let srk = 96000.0
        let rows: [(f: Double, gain: Double, t60: Double)] = [
            (f: 220.0, gain: 0.9, t60: 4.0), (f: 330.0, gain: 0.6, t60: 3.0),
            (f: 440.0, gain: 0.6, t60: 3.0),
        ]
        let flags = [false, true, true]
        let base = try XCTUnwrap(BowTables.buildJawariTables(
            rows: rows, srk: srk, bp: bp, chromatic: flags))
        XCTAssertTrue(base.hasChromatic)
        XCTAssertEqual(base.rowChromatic, flags)
        // resting chromatic bridge == the raga bridge's shipped values
        let allRaga = try XCTUnwrap(BowTables.buildJawariTables(
            rows: rows, srk: srk, bp: bp))
        XCTAssertFalse(allRaga.hasChromatic)
        XCTAssertEqual(base.b, allRaga.b)
        // the per-row level law rides the force-radiation scale
        XCTAssertEqual(base.rowForceScale, allRaga.rowForceScale)
        XCTAssertEqual(base.phiD, allRaga.phiD)
        XCTAssertEqual(base.ca, allRaga.ca)
        XCTAssertEqual(base.rowApex, [Double](repeating: bp.v("bow_jt_apex", 1e-5), count: 3))

        bp.num["bow_jtc_gain"] = 0.6
        bp.num["bow_jtc_norm"] = 0.8
        let moved = try XCTUnwrap(BowTables.buildJawariTables(
            rows: rows, srk: srk, bp: bp, chromatic: flags))
        let J = Int(base.J)
        // the bone geometry is SHARED now — every row's bone is untouched
        XCTAssertEqual(moved.b, base.b)
        // raga row 0: untouched
        XCTAssertEqual(moved.rowForceScale[0], base.rowForceScale[0])
        // chromatic rows: level + level norm moved
        for r in 1...2 {
            XCTAssertNotEqual(moved.rowForceScale[r], base.rowForceScale[r])
        }
        XCTAssertEqual(moved.rowApex,
                       [Double](repeating: bp.v("bow_jt_apex", 1e-5), count: 3))
        XCTAssertEqual(moved.rowAlpha,
                       [Double](repeating: bp.v("bow_jt_alpha", 1.3), count: 3))
        // the global phys vector is the RAGA bridge's — never the chromatic's
        XCTAssertEqual(moved.phys, base.phys)
    }

    // MARK: - Registry

    /// DEFAULT = ENGINE TRUTH: the artifact never carries `bow_jtc_*`, so
    /// the registry default is exactly what the builder plays — and it is
    /// the raga bridge's shipped value (the split alone adds no new
    /// sound). The three surviving chromatic keys — level, level norm,
    /// evolution — are twins of raga keys, land in place (or live for
    /// evolve), and are prefixed so the in-place path's `bow_jt` prefix
    /// test catches them.
    func testChromaticBridgeDefaultsAreTheEngineTruth() throws {
        let bp = try bp()
        let specs = ParamRegistry.all.filter { $0.key.hasPrefix("bow_jtc_") }
        XCTAssertEqual(Set(specs.map(\.key)),
                       Set(BowTables.chromaticBridgeDefaults.keys))
        for s in specs {
            XCTAssertNil(bp.num[s.key], "\(s.key) grew an artifact value — re-derive the contract")
            XCTAssertEqual(s.def, BowTables.chromaticBridgeDefaults[s.key]!, accuracy: 1e-15,
                           "\(s.key): registry default is not what the builder plays")
            let twin = "bow_jt_" + s.key.dropFirst("bow_jtc_".count)
            let twinSpec = try XCTUnwrap(ParamRegistry.spec(twin), "\(s.key) has no raga twin")
            XCTAssertEqual(s.lo, twinSpec.lo); XCTAssertEqual(s.hi, twinSpec.hi)
            XCTAssertEqual(s.apply, twinSpec.apply)
            XCTAssertEqual(s.group, "Chromatic bridge (jawari taraf)")
            if s.apply != .live {
                XCTAssertTrue(ParamRegistry.inPlaceKeys.contains(s.key), "\(s.key) must land in place")
            }
            // the raga bridge's shipped value: artifact, else the builder fallback
            let shipped = bp.num[twin] ?? BowTables.chromaticBridgeDefaults[s.key]!
            XCTAssertEqual(s.def, shipped, accuracy: 1e-15,
                           "\(s.key) does not rest at the raga bridge's shipped \(twin)")
        }
        XCTAssertEqual(ParamRegistry.spec("bow_jtc_evolve")?.apply, .live)
    }
}
