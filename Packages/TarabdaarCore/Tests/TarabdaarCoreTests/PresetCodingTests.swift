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
        p.paramValues = ["output_gain_db": 6, "bow_expr": 0.4, "bow_vib_cents": 12.0, "bow_jt_sav": 1,
                         "output_limiter_ceiling_db": -3, "output_limiter_lookahead_ms": 8,
                         "output_limiter_release_ms": 240,
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
        XCTAssertEqual(b.tiltMapping, a.tiltMapping)
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

    /// Legacy split sections preserve precedence and units without filling absent partial sections.
    func testLegacyParameterResolution() throws {
        var preset = TarabdaarPreset()
        XCTAssertNil(preset.resolvedParamValues())
        preset.stringOverrides = ["bow_body_q": 33, "bow_expr": 0.2]
        preset.paramValues = ["bow_expr": 0.7, "ctl_strum_thresh": 63.5]
        let back = try TarabdaarPreset.decode(preset.encoded())
        XCTAssertEqual(back.resolvedParamValues(),
                       ["bow_body_q": 33, "bow_expr": 0.7, "ctl_strum_thresh": 0.5])
        preset.paramValues = ["ctl_strum_thresh": 0.25]
        XCTAssertEqual(preset.resolvedParamValues()?["ctl_strum_thresh"], 0.25)
        preset.stringOverrides = nil
        preset.paramValues = [:]
        XCTAssertEqual(preset.resolvedParamValues(), [:])
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
    private func completeSnapshot() -> TarabdaarPreset {
        var p = fullPreset()
        p.version = TarabdaarPreset.currentVersion
        p.savedBy = "Preset regression fixture"
        p.stringOverrides = nil
        p.paramValues = ["bow_expr": 0.4, "bow_vib_cents": 0, "bow_jtc_norm": 0.53]
        p.fxCurves = [:]
        p.bowAxisCurves = TarabdaarPreset.factoryBowAxisCurves()
        p.mainInstrument = "sitar"
        p.droneVoice = "sympathetic"
        let scale = PitchScale(points: p.instrument!.scaleRatios.enumerated().map { index, ratio in
            let f = bestFraction(ratio)
            return PitchPoint(num: f.num, den: f.den, y: 0.3, label: "degree \(index)")
        })
        p.playingSurface = PresetPlayingSurface(scale: scale,
            arrangement: FretArrangement(segments: [
                FretSegment(degreeIndex: 1, row: .row5)
            ], ghostExtentOctaves: 1.25), snapPixels: 19)
        return p
    }

    /// Complete snapshots retain every section and cannot partially load through the old flat reader.
    func testCompleteSnapshotPreservesBanksCurvesRoutingAndSurface() throws {
        let a = completeSnapshot()
        let data = try a.encoded()
        let b = try TarabdaarPreset.decode(data)
        XCTAssertEqual(try b.encoded(), data)
        XCTAssertEqual(b.instrument?.strings, a.instrument?.strings)
        XCTAssertEqual(b.instrument?.droneStringIds, a.instrument?.droneStringIds)
        XCTAssertEqual(b.instrument?.strumStringIds, a.instrument?.strumStringIds)
        XCTAssertEqual(b.fxCurves, [:]) // Explicit flat rack, not an omitted section.
        XCTAssertEqual(b.playingSurface?.scalePoints, a.playingSurface?.scalePoints)
        XCTAssertEqual(b.playingSurface?.fretSegments.first?.row, .row5)
        XCTAssertEqual(b.resolvedScale(current: .defaultJI)?.points, a.playingSurface?.scalePoints)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var snapshot = try XCTUnwrap(legacy["snapshot"] as? [String: Any])
        var surface = try XCTUnwrap(snapshot["playingSurface"] as? [String: Any])
        XCTAssertNil(surface["primeLimit"])
        surface["primeLimit"] = 7
        snapshot["playingSurface"] = surface
        legacy["snapshot"] = snapshot
        let migrated = try TarabdaarPreset.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(try migrated.encoded(), data, "legacy prime limits are ignored and omitted on save")
        struct OldReader: Decodable {
            let version: Int
            let name: String
            let instrument: InstrumentState?
            let paramValues: [String: Double]?
            let tiltMapping: DimensionMapping?
        }
        let old = try JSONDecoder().decode(OldReader.self, from: data)
        XCTAssertNil(old.instrument)
        XCTAssertNil(old.paramValues)
        XCTAssertNil(old.tiltMapping)
    }

    /// Legacy and complete presets discard retired values and bindings while preserving the rig.
    func testRetiredSettingsMigrate() throws {
        for version in [1, 2] {
            var expected = completeSnapshot()
            expected.version = version
            expected.stringOverrides = ["bow_body_q": 33]
            var old = expected
            old.version = 1 // Encode the old payload without current snapshot validation.
            for (key, value) in [("bow_lim_thresh", 0.8), ("bow_lim_rel_ms", 150.0), ("ctl_taraf_adapt", 0.8)] {
                old.paramValues?[key] = value
                old.stringOverrides?[key] = value
                old.tiltMapping?.mappings[MapTarget(paramKey: key).storageKey] = ParameterMapping(
                    bindings: [DimensionBinding(dimension: .tilt2, rangeMin: 0.1, rangeMax: 1)])
                old.composites?[0].members.append(CompositeMember(key: key, lo: 0.1, hi: 1))
            }
            let payload = try JSONSerialization.jsonObject(with: old.encoded())
            let raw: Any = version == 1 ? payload : ["version": 2, "name": old.name, "snapshot": payload]
            let migrated = try TarabdaarPreset.decode(JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(try migrated.encoded(), try expected.encoded())
        }
        for key in ["bow_lim_thresh", "bow_lim_rel_ms", "ctl_taraf_adapt"] {
            XCTAssertNil(ParamRegistry.spec(key))
            XCTAssertFalse(ParamRegistry.appliesInPlace(key))
            XCTAssertNil(MapTarget.from(storageKey: MapTarget(paramKey: key).storageKey))
        }
    }

    /// Corrupt, downgraded and unsupported snapshots fail before any live state can be applied.
    func testIncompleteAndUnsupportedSnapshotsAreRejected() throws {
        let data = try completeSnapshot().encoded()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var raw = original
        raw["version"] = TarabdaarPreset.currentVersion + 1
        XCTAssertThrowsError(try TarabdaarPreset.decode(JSONSerialization.data(withJSONObject: raw)))
        for section in ["instrument", "paramValues", "fxCurves", "bowAxisCurves", "tiltMapping", "playingSurface"] {
            raw = original
            var body = raw["snapshot"] as! [String: Any]
            body.removeValue(forKey: section)
            raw["snapshot"] = body
            XCTAssertThrowsError(try TarabdaarPreset.decode(JSONSerialization.data(withJSONObject: raw)), section)
        }
        var body = original["snapshot"] as! [String: Any]
        var instrument = body["instrument"] as! [String: Any]
        var strings = instrument["strings"] as! [[String: Any]]
        strings[0].removeValue(forKey: "set")
        instrument["strings"] = strings
        body["instrument"] = instrument
        // This is exactly the old-app failure: a modern schema with the bank tags stripped.
        XCTAssertThrowsError(try TarabdaarPreset.decode(JSONSerialization.data(withJSONObject: body)))
        var unsupported = completeSnapshot()
        unsupported.paramValues?["future_dsp_knob"] = 1
        XCTAssertThrowsError(try unsupported.encoded())
        unsupported = completeSnapshot()
        unsupported.tiltMapping?.mappings["param:future_controller_target"] = ParameterMapping(
            bindings: [DimensionBinding(dimension: .tilt2, rangeMin: 0, rangeMax: 1)])
        XCTAssertThrowsError(try unsupported.encoded())
    }

    /// Overwrites retain the previous bytes and a failed validation leaves the saved rig intact.
    func testLibraryOverwriteBackupAndFailedSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PresetLibrary(directory: directory)
        var a = completeSnapshot()
        let url = try library.save(a, name: "Working rig")
        let first = try Data(contentsOf: url)
        a.paramValues?["bow_expr"] = 0.7
        try library.save(a, name: "Working rig")
        XCTAssertEqual(library.names(), ["Working rig"])
        XCTAssertEqual(try library.load(name: "Working rig").paramValues?["bow_expr"], 0.7)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), first)
        let good = try Data(contentsOf: url)
        a.fxCurves = nil
        XCTAssertThrowsError(try library.save(a, name: "Working rig"))
        XCTAssertEqual(try Data(contentsOf: url), good)
    }

    /// A pending gesture from the replaced rig cannot overwrite a new preset's settings.
    func testPresetSwitchDiscardsPendingGestureRebuilds() {
        var scheduled: [() -> Void] = []
        var applied: [[String: Double]] = []
        let flush = DebouncedParamFlush(schedule: { _, work in scheduled.append(work) },
                                       flush: { applied.append($0) })
        flush.queue(["bow_body_q": 40])
        flush.cancel()
        flush.queue(["bow_body_q": 12])
        scheduled[0]()
        XCTAssertTrue(applied.isEmpty)
        scheduled[1]()
        XCTAssertEqual(applied, [["bow_body_q": 12]])
    }

}
