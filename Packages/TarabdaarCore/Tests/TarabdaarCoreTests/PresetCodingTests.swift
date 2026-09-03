import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The preset document round-trips, partial files apply only what they carry, garbage is rejected.
final class PresetCodingTests: XCTestCase {

    // MARK: - The document itself

    private func fullPreset() -> TarabdaarPreset {
        var p = TarabdaarPreset()
        p.name = "Test rig"
        p.savedAt = "2026-07-24T12:00:00Z"
        p.instrument = Presets.state(.sarangiPilu)
        p.stringOverrides = ["bow_body_q": 33.0, "bow_jt_apex": 1.4e-5]
        p.paramValues = ["bow_expr": 0.4, "bow_vib_cents": 12.0]
        p.composites = CompositeParam.defaults()
        var m = DimensionMapping.makeDefault()
        m.mappings[MapTarget(paramKey: "bow_mu_s").storageKey] =
            ParameterMapping(bindings: [
                DimensionBinding(dimension: .tilt2, rangeMin: 0.5, rangeMax: 1.1),
            ])
        p.tiltMapping = m
        return p
    }

    func testWholeDocumentRoundTrips() throws {
        let a = fullPreset()
        let b = try TarabdaarPreset.decode(a.encoded())

        XCTAssertEqual(b.name, a.name)
        XCTAssertEqual(b.savedAt, a.savedAt)
        XCTAssertEqual(b.stringOverrides, a.stringOverrides)
        XCTAssertEqual(b.paramValues, a.paramValues)
        XCTAssertEqual(b.composites, a.composites)
        // the instrument section: spot-check the parts a player would notice
        XCTAssertEqual(b.instrument?.strings.count, a.instrument?.strings.count)
        XCTAssertEqual(b.instrument?.tonicHz, a.instrument?.tonicHz)
        XCTAssertEqual(b.instrument?.scaleRatios, a.instrument?.scaleRatios)
        // and the binding that only survives via its storage key
        let t = MapTarget(paramKey: "bow_mu_s")
        XCTAssertEqual(b.tiltMapping?.mapping(for: t).binding(for: .tilt2)?
                        .controlPoints.last?.y, 1.1)
    }

    /// A partial preset — say tilt bindings only — must load without
    /// disturbing anything else. `applyPreset` skips nil sections.
    func testPartialPresetCarriesOnlyWhatItHas() throws {
        var p = TarabdaarPreset()
        p.name = "Just my tilts"
        p.tiltMapping = DimensionMapping.makeDefault()
        let back = try TarabdaarPreset.decode(p.encoded())
        XCTAssertNil(back.instrument)
        XCTAssertNil(back.stringOverrides)
        XCTAssertNil(back.paramValues)
        XCTAssertNotNil(back.tiltMapping)
        // 5 since 2026-08-28: makeDefault seeds the strum-expression
        // binding (ctl_strum_expr on Stick Y) beside the four classics.
        XCTAssertEqual(back.sections(), ["5 tilt bindings"])
    }

    func testGarbageIsRejectedRatherThanSilentlyEmpty() {
        XCTAssertThrowsError(try TarabdaarPreset.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try TarabdaarPreset.decode(Data("not json".utf8)))
    }

    // MARK: - Split-era files (2026-07-24 → 2026-07-30)

}
