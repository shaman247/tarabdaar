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

    /// FX KEYS ARE PRESET KEYS. The rack is now ONE insert definition
    /// instantiated at four points, but the keys it derives
    /// (`fx_<point>_<knob>`) are the same strings older `.tarabdaar` files
    /// already carry — a preset written before the refactor must load
    /// byte-for-byte, and every key must still resolve in the registry
    /// (an unknown key would be dropped at apply time and the insert
    /// would silently rest at its default).
    func testFXRackValuesRoundTripAndStillResolve() throws {
        let fx: [String: Double] = [
            "fx_voice_eq_on": 1, "fx_voice_eq_b3": -4.5,
            "fx_drive_rev_on": 1, "fx_drive_rev_type": 1,
            "fx_taraf_rev_mix": 0.42, "fx_global_rev_cut": 6000,
        ]
        var p = TarabdaarPreset()
        p.name = "FX rig"
        p.paramValues = fx
        let back = try TarabdaarPreset.decode(p.encoded())
        XCTAssertEqual(back.paramValues, fx)
        for (key, value) in fx {
            let spec = try XCTUnwrap(ParamRegistry.spec(key),
                                     "\(key) no longer exists in the registry")
            XCTAssertNotNil(spec.insert, key)
            XCTAssertTrue(value >= spec.lo && value <= spec.hi, key)
        }
        XCTAssertEqual(back.sections(), ["6 parameters"])
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
        // 5  makeDefault seeds the strum-expression
        // binding (ctl_strum_expr on Stick Y) beside the four classics.
        XCTAssertEqual(back.sections(), ["5 tilt bindings"])
    }

    func testGarbageIsRejectedRatherThanSilentlyEmpty() {
        XCTAssertThrowsError(try TarabdaarPreset.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try TarabdaarPreset.decode(Data("not json".utf8)))
    }

    // MARK: - Partial and older files

}
