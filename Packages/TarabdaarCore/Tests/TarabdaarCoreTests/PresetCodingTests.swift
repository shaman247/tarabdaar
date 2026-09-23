import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The preset document round-trips, partial files apply only what they carry, garbage is rejected.
final class PresetCodingTests: XCTestCase {

    private func fullPreset() -> TarabdaarPreset {
        var p = TarabdaarPreset()
        p.name = "Test rig"
        p.savedAt = "2026-07-24T12:00:00Z"
        p.instrument = Presets.state(.sarangiPilu)
        p.stringOverrides = ["bow_body_q": 33.0, "bow_jt_apex": 1.4e-5, "bow_jt_sav": 1]
        p.paramValues = ["bow_expr": 0.4, "bow_vib_cents": 12.0, "bow_jt_sav": 1,
                         "bow_expr_map_5": 0.17, "bow_press_map_10": 0.1,
                         "bow_pos_map_0": 0.4]
        p.composites = CompositeParam.defaults()
        var m = DimensionMapping.makeDefault()
        m.mappings[MapTarget(paramKey: "bow_mu_s").storageKey] =
            ParameterMapping(bindings: [
                DimensionBinding(dimension: .tilt2, rangeMin: 0.5, rangeMax: 1.1),
            ])
        p.tiltMapping = m
        p.droneSequence = [2, 0, 1, 1, 2]
        return p
    }

    /// The whole rig round-trips: name, overrides, param values, composites,
    /// the instrument section and a binding that survives only via its key.
    func testWholeDocumentRoundTrips() throws {
        let a = fullPreset()
        let b = try TarabdaarPreset.decode(a.encoded())

        XCTAssertEqual(b.name, a.name)
        XCTAssertEqual(b.savedAt, a.savedAt)
        XCTAssertEqual(b.stringOverrides, a.stringOverrides)
        XCTAssertEqual(b.paramValues, a.paramValues)
        XCTAssertEqual(b.composites, a.composites)
        XCTAssertEqual(b.droneSequence, a.droneSequence)
        XCTAssertTrue(b.sections().contains("drone sequence"))
        // the instrument section: spot-check the parts a player would notice
        XCTAssertEqual(b.instrument?.strings.count, a.instrument?.strings.count)
        XCTAssertEqual(b.instrument?.tonicHz, a.instrument?.tonicHz)
        XCTAssertEqual(b.instrument?.scaleRatios, a.instrument?.scaleRatios)
        // and the binding that only survives via its storage key
        let t = MapTarget(paramKey: "bow_mu_s")
        XCTAssertEqual(b.tiltMapping?.mapping(for: t).binding(for: .tilt2)?
                        .controlPoints.last?.y, 1.1)
    }

    /// Curve sections round-trip, override legacy bands, and leave mapping-only presets partial.
    func testBowAxisCurveMigration() throws {
        var preset = TarabdaarPreset()
        preset.paramValues = ["bow_expr_map_5": 0.17, "bow_press_map_10": 0.1]
        let migrated = try XCTUnwrap(preset.resolvedBowAxisCurves())
        XCTAssertEqual(migrated["expr"]?[5], BowAxisPoint(x: 0.5, y: 0.17))
        XCTAssertEqual(migrated["press"]?.last, BowAxisPoint(x: 1, y: 0.1))
        let factory = TarabdaarPreset.factoryBowAxisCurves()
        XCTAssertEqual(migrated["expr"]?[4], factory["expr"]?[4])
        preset.bowAxisCurves = ["expr": [BowAxisPoint(x: 0, y: 0),
                                       BowAxisPoint(x: 0.37, y: 0.2), BowAxisPoint(x: 1, y: 1)]]
        let back = try TarabdaarPreset.decode(preset.encoded())
        XCTAssertEqual(back.bowAxisCurves, preset.bowAxisCurves)
        XCTAssertEqual(back.resolvedBowAxisCurves()?["expr"], preset.bowAxisCurves?["expr"])
        XCTAssertEqual(back.resolvedBowAxisCurves()?["press"], factory["press"])
        preset = TarabdaarPreset()
        XCTAssertNil(preset.resolvedBowAxisCurves())
        preset.bowAxisCurves = [:]
        XCTAssertFalse(preset.isEmpty)
        XCTAssertEqual(preset.resolvedBowAxisCurves(), factory)
        XCTAssertNil(ParamRegistry.spec("bow_expr_map_5"))
    }

    /// FX KEYS ARE PRESET KEYS: the derived `fx_<point>_<knob>` keys are the
    /// strings existing `.tarabdaar` files carry, and every one must still
    /// resolve — an unknown key is dropped at apply time and rests silently.
    /// The EQ curves are a section of their own, and the graphic-EQ bands
    /// of older files convert to a curve through the band centres.
    func testFXRackValuesAndCurvesRoundTripAndStillResolve() throws {
        let fx: [String: Double] = [
            "fx_voice_eq_on": 1, "fx_voice_eq_amount": 0.5,
            "fx_drive_rev_on": 1, "fx_drive_rev_type": 1,
            "fx_taraf_rev_mix": 0.42, "fx_global_rev_cut": 6000,
        ]
        let curve = [EQPoint(hz: 120, db: -3), EQPoint(hz: 2500, db: 4.5)]
        var p = TarabdaarPreset()
        p.name = "FX rig"
        p.paramValues = fx
        p.fxCurves = ["fx_voice_": curve]
        let back = try TarabdaarPreset.decode(p.encoded())
        XCTAssertEqual(back.paramValues, fx)
        XCTAssertEqual(back.fxCurves, ["fx_voice_": curve])
        for (key, value) in fx {
            let spec = try XCTUnwrap(ParamRegistry.spec(key),
                                     "\(key) no longer exists in the registry")
            XCTAssertNotNil(spec.insert, key)
            XCTAssertTrue(value >= spec.lo && value <= spec.hi, key)
        }
        XCTAssertEqual(back.sections(), ["6 parameters", "1 EQ curves"])
        // an older file's bands: a point per band centre, only where touched
        let legacy = TarabdaarPreset.legacyEQCurves(
            in: ["fx_voice_eq_b3": -4.5, "fx_voice_eq_b8": 2, "fx_taraf_eq_b1": 0])
        XCTAssertEqual(Array(legacy.keys), ["fx_voice_"])
        XCTAssertEqual(legacy["fx_voice_"]?.count, 10)
        XCTAssertEqual(legacy["fx_voice_"]?[2], EQPoint(hz: 125, db: -4.5))
        XCTAssertEqual(legacy["fx_voice_"]?[7], EQPoint(hz: 4000, db: 2))
        XCTAssertTrue(TarabdaarPreset.legacyEQCurves(in: fx).isEmpty)
    }

    /// A partial preset — tilt bindings only — loads without disturbing
    /// anything else (`applyPreset` skips nil sections), and garbage is
    /// rejected rather than decoding to a silently empty document.
    func testPartialPresetCarriesOnlyWhatItHas() throws {
        var p = TarabdaarPreset()
        p.name = "Just my tilts"
        p.tiltMapping = DimensionMapping.makeDefault()
        let back = try TarabdaarPreset.decode(p.encoded())
        XCTAssertNil(back.instrument)
        XCTAssertNil(back.stringOverrides)
        XCTAssertNil(back.paramValues)
        XCTAssertNil(back.droneSequence)
        XCTAssertNotNil(back.tiltMapping)
        XCTAssertEqual(back.sections(), ["5 tilt bindings"])
        XCTAssertThrowsError(try TarabdaarPreset.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try TarabdaarPreset.decode(Data("not json".utf8)))
    }
}
