import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Regression guards for the 2026-07-24 parameter unification: one
/// registry, one knob per perceptual thing, and tilt bindings that can
/// target a composite OR any single parameter.
final class ParamUnificationTests: XCTestCase {

    // MARK: - Registry integrity

    func testKeysAreUnique() {
        var seen = Set<String>()
        for p in ParamRegistry.all {
            XCTAssertTrue(seen.insert(p.key).inserted,
                          "duplicate parameter key \(p.key)")
        }
    }

    func testGroupFieldMatchesTheGroupItIsListedUnder() {
        for (name, params) in ParamRegistry.groups {
            for p in params {
                XCTAssertEqual(p.group, name,
                               "\(p.key) is listed under \(name) but says \(p.group)")
            }
        }
    }

    /// The duplicate pairs the unification removed. `bow_jaw_gain` and
    /// `bow_vibrato` were the LIVE SCALERS of `bow_taraf_jawari` and
    /// `bow_vib_cents`; exposing them as parameters is what put the same
    /// knob in two tabs under two names. (`bow_taraf_jawari` itself is gone
    /// too since the linear sympathetic web was deleted — see
    /// `testTheLinearTarafWebIsGone`.)
    func testDeletedScalerKeysAreNotParameters() {
        for gone in ["bow_jaw_gain", "bow_vibrato"] {
            XCTAssertNil(ParamRegistry.spec(gone),
                         "\(gone) is a hybrid parameter's scaler, not a parameter")
        }
    }

    /// THE TARAF SIMPLIFICATION (2026-07-24): the linear comb web
    /// (`bow_taraf_*`) and the open gut pair (`bow_open_*`) were removed —
    /// the modal-jawari block (`bow_jt_*`) is the whole sympathetic
    /// response now. Nothing may reintroduce a knob for them: the builder
    /// no longer reads any of these keys, so a parameter row would be a
    /// slider that silently does nothing.
    func testTheLinearTarafWebIsGone() {
        for p in ParamRegistry.all {
            XCTAssertFalse(p.key.hasPrefix("bow_taraf_")
                           || p.key.hasPrefix("bow_open_"),
                           "\(p.key) belongs to the deleted sympathetic web")
        }
        XCTAssertFalse(ParamRegistry.groups.contains { $0.name == "Taraf (sympathetic)" })
        XCTAssertFalse(ParamRegistry.inPlaceKeys.contains {
            $0.hasPrefix("bow_taraf_") || $0.hasPrefix("bow_open_")
        })
        // the jawari block must still be there — it IS the taraf
        XCTAssertNotNil(ParamRegistry.spec("bow_jt_gain"))
    }

    /// THE TARAF IS ALWAYS ON (2026-08-02): `bow_jtaraf_on` was an arming
    /// switch on the block that IS the sympathetic response — a knob whose
    /// only other setting was "no taraf at all". It is gone from the
    /// registry AND from the builder's guard; the taraf now builds
    /// whenever there are enabled tarab rows. Nothing may reintroduce it:
    /// the builder no longer reads the key, so a row would be a slider
    /// that silently does nothing.
    func testTheJawariArmingSwitchIsGone() {
        XCTAssertNil(ParamRegistry.spec("bow_jtaraf_on"))
        XCTAssertFalse(ParamRegistry.inPlaceKeys.contains("bow_jtaraf_on"))
    }

    func testEveryHybridResolvesToAScalerAndARestFraction() {
        let hybrids = ParamRegistry.all.filter { $0.apply == .hybrid }
        XCTAssertFalse(hybrids.isEmpty)
        for p in hybrids {
            XCTAssertNotNil(ParamRegistry.hybridScaler(p.key),
                            "\(p.key) is .hybrid but has no live scaler")
            XCTAssertNotNil(p.restFraction,
                            "\(p.key) is .hybrid but has no resting fraction")
            if let f = p.restFraction {
                XCTAssertTrue(f >= 0 && f <= 1, "\(p.key) rest fraction \(f)")
            }
        }
    }

    /// Resting behavior must match what the deleted scaler defaulted to:
    /// no vibrato (aftertouch 0).
    func testHybridRestFractionsPreserveTheShippedSound() {
        XCTAssertEqual(ParamRegistry.spec("bow_vib_cents")?.restFraction, 0.0)
    }

    func testLiveKeysCoverLiveAndHybrid() {
        for p in ParamRegistry.all {
            XCTAssertEqual(ParamRegistry.liveKeys.contains(p.key),
                           p.apply != .rebuild, "\(p.key)")
        }
    }

    func testStoredKeysAreExactlyTheNonRebuildParameters() {
        XCTAssertEqual(Set(ParamRegistry.storedKeys.map(\.key)),
                       Set(ParamRegistry.all.filter { $0.apply != .rebuild }
                            .map(\.key)))
    }

    /// DEFAULT = ENGINE TRUTH (2026-08-19). A `.rebuild` parameter's
    /// authored default is what the Parameters tab DISPLAYS for an
    /// untouched row, but the engine runs artifact + overrides only — for
    /// a key the artifact does not carry, the value that actually plays is
    /// the ENGINE code fallback (`bp.v(key, fallback)` in
    /// `BowControlFilter` / the table builders). The two drifted apart
    /// once (bite showed 2.0 while the engine ran 0; sharp-draw showed the
    /// offline fit's 8 ms while the engine followed the 60 ms draw): the
    /// tab lied about the sound. This pins def == engine fallback for the
    /// artifact-absent articulation/liveness keys — change one side, keep
    /// the other in step (or ship the key in the artifact).
    func testAuthoredDefaultsMatchEngineFallbacks() throws {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // Mirrors the fallbacks in BowControls.swift (init/updateLiveParams).
        let engineFallback: [String: Double] = [
            "bow_draw_min_ms": bp.num["bow_draw_ms"] ?? 1.0, // follows the draw
            "bow_attack_bite": 0.0,
            "bow_attack_bite_ms": 60.0,
            "bow_attack_thresh": 0.5,
            "bow_attack_fms": 15.0,
            "bow_attack_vel": 0.0,
            "bow_settle_sharp": 0.0,
        ]
        for (key, expect) in engineFallback {
            let spec = try XCTUnwrap(ParamRegistry.spec(key), key)
            XCTAssertNil(bp.num[key],
                         "\(key) grew an artifact value — this pin covers "
                         + "artifact-absent keys only; re-derive the def")
            XCTAssertEqual(spec.def, expect, accuracy: 1e-12,
                           "\(key): authored default \(spec.def) is not what "
                           + "the engine plays (\(expect)) — the Parameters "
                           + "tab would lie about the sound")
        }
    }

    /// THE SCOPE AUDIT (2026-08-23): per-note = the parameter drives a
    /// mechanism with PER-NOTE control state (onset clocks, envelopes,
    /// phases, walks, blend windows) — exactly the note-scoped groups
    /// plus the plucked voices' per-note releases. Everything else is a
    /// shared mechanism = global. Pinned here so a new parameter must be
    /// classified deliberately (a mis-defaulted `.global` on a per-note
    /// group fails loudly).
    func testScopeClassificationMatchesTheMechanisms() {
        let perNoteGroups: Set<String> = [
            "Articulation", "Liveness", "Fret linger", "Strike blend",
        ]
        let perNoteExtras: Set<String> = ["tp_rel_t60", "st_rel_t60"]
        for (group, params) in ParamRegistry.groups {
            for p in params {
                let expected: ParamScope =
                    perNoteGroups.contains(group) || perNoteExtras.contains(p.key)
                    ? .perNote : .global
                XCTAssertEqual(p.scope, expected,
                               "\(p.key) in \(group): scope \(p.scope) — "
                               + "classify deliberately (see ParamScope)")
            }
        }
    }

    /// `inPlaceKeys` covers build scalars that can land on the running
    /// kernel — `.rebuild` keys, plus `.hybrid` ones whose above-headroom
    /// push is still an in-place constant (`bow_vib_cents`). A `.live`
    /// key in the list would be meaningless (live already applies
    /// instantly) and would garble the timing story the docs tell.
    func testInPlaceKeysCarryNoLiveStrategy() {
        for key in ParamRegistry.inPlaceKeys {
            XCTAssertNotEqual(ParamRegistry.spec(key)?.apply, .live,
                              "\(key) is .live — it does not belong in "
                              + "inPlaceKeys")
        }
    }

    func testRangesContainTheAuthoredDefault() {
        for p in ParamRegistry.all {
            XCTAssertTrue(p.def >= p.lo && p.def <= p.hi,
                          "\(p.key) default \(p.def) outside \(p.lo)…\(p.hi)")
        }
    }

    // MARK: - Composites

    func testShippedCompositeMembersExistInTheRegistry() {
        for c in CompositeParam.defaults() {
            XCTAssertFalse(c.members.isEmpty, "\(c.name) has no members")
            for m in c.members {
                XCTAssertNotNil(ParamRegistry.spec(m.key),
                                "\(c.name) references unknown key \(m.key)")
            }
        }
    }

    /// Taraf Purity's two members both move toward "clean" as the
    /// composite rises: the tone LP sweeps DOWN (darker buzz) and the
    /// recruitment profile sweeps DOWN (0.5 = fitted → 0 = kin-only,
    /// loudness compensated). Every member must stay on a LIVE path —
    /// the whole point of a composite is that a tilt can sweep it.
    func testTarafPuritySweepsTowardCleanAndStaysLive() {
        guard let purity = CompositeParam.defaults()
            .first(where: { $0.name == "Taraf Purity" })
        else { return XCTFail("Taraf Purity composite is gone") }
        let expected: Set<String> = ["bow_jt_lp", "bow_jt_sel"]
        XCTAssertEqual(Set(purity.members.map(\.key)), expected,
                       "Taraf Purity's member set changed — update this test")
        for m in purity.members {
            XCTAssertGreaterThan(m.lo, m.hi, "\(m.key) should sweep DOWN to clean")
            XCTAssertTrue(ParamRegistry.liveKeys.contains(m.key),
                          "\(m.key) is not on a live path")
        }
        // The recruitment member rests on the FITTED taraf (0.5, the
        // profile axis' midpoint) and sweeps down to the kin-only
        // strip. It must NOT rest at 1.0: since the 2026-08-01 profile
        // rework the upper half is the note-independent FLAT profile,
        // and resting there decouples the wash from the playing (the
        // coherence rev's "backing ensemble" failure mode).
        let sel = purity.members.first { $0.key == "bow_jt_sel" }!
        XCTAssertEqual(sel.lo, 0.5)
        XCTAssertEqual(sel.hi, 0.0)
    }

    func testCompositeSlotsAreUniqueAndInRange() {
        let slots = CompositeParam.defaults().map(\.slot)
        XCTAssertEqual(Set(slots).count, slots.count)
        for s in slots {
            XCTAssertTrue(s >= 0 && s < CompositeParam.maxSlots)
        }
    }

    // MARK: - Tilt targets

    func testCompositeStorageKeysRoundTripToTheirSlots() {
        for slot in 0..<CompositeParam.maxSlots {
            let t = MapTarget(compositeSlot: slot)
            XCTAssertEqual(MapTarget.from(storageKey: t.storageKey)?.compositeSlot,
                           slot)
        }
        // The legacy (pre-unification) spellings must still resolve, or
        // saved tilt bindings silently vanish.
        XCTAssertEqual(MapTarget.from(storageKey: "midiCC71")?.compositeSlot, 0)
        XCTAssertEqual(MapTarget.from(storageKey: "midiCC73")?.compositeSlot, 1)
        XCTAssertEqual(MapTarget.from(storageKey: "midiCC72")?.compositeSlot, 2)
    }

    func testParameterTargetsRoundTripAndRejectUnknownKeys() {
        let t = MapTarget(paramKey: "bow_vib_cents")
        XCTAssertEqual(MapTarget.from(storageKey: t.storageKey)?.paramKey,
                       "bow_vib_cents")
        XCTAssertNil(MapTarget.from(storageKey: "param:bow_jaw_gain"))
        XCTAssertNil(MapTarget.from(storageKey: "nonsense"))
    }

    func testParameterTargetRangeIsTheParameterRange() {
        let r = MapTarget(paramKey: "bow_vib_cents").defaultRange
        XCTAssertEqual(r.0, 0)
        XCTAssertEqual(r.1, 60)
        // A composite is always 0…1 (the old 0…127 transport units are gone).
        let c = MapTarget(compositeSlot: 0).defaultRange
        XCTAssertEqual(c.0, 0)
        XCTAssertEqual(c.1, 1)
    }

    func testAllTargetsCoversEverySlotAndEveryParameter() {
        let all = MapTarget.allTargets()
        XCTAssertEqual(all.compactMap(\.compositeSlot).count,
                       CompositeParam.maxSlots)
        XCTAssertEqual(Set(all.compactMap(\.paramKey)),
                       Set(ParamRegistry.all.map(\.key)))
    }

    // MARK: - Binding defaults + migration

    func testDefaultBindingsUseCompositeNativeUnits() {
        let m = DimensionMapping.makeDefault()
        let purity = m.mapping(for: MapTarget(compositeSlot: 0))
        guard let b = purity.binding(for: .tilt1) else {
            return XCTFail("Taraf Purity lost its default tilt-1 binding")
        }
        XCTAssertEqual(b.controlPoints.first?.y, 0)
        XCTAssertEqual(b.controlPoints.last?.y, 1)   // not 127
        XCTAssertEqual(b.evaluate(0.5), 0, accuracy: 1e-9)  // rest-zero shape
        XCTAssertEqual(b.evaluate(1.0), 1, accuracy: 1e-9)
    }

    /// A v5 document stored composite endpoints in 0…127 transport units.
    /// Loading it must rescale them, or every tilt would slam its
    /// composite to the top of the range.
    func testLegacyV5DocumentMigratesEndpointsTo01() throws {
        let d = UserDefaults.standard
        d.removeObject(forKey: "tarabdaar_dimensionMapping_v6")
        defer {
            d.removeObject(forKey: "tarabdaar_dimensionMapping_v5")
            d.removeObject(forKey: "tarabdaar_dimensionMapping_v6")
        }
        let legacy = DimensionMapping(mappings: [
            "midiCC71": ParameterMapping(bindings: [
                DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 127),
            ], defaultValue: 63.5),
        ])
        d.set(try JSONEncoder().encode(legacy),
              forKey: "tarabdaar_dimensionMapping_v5")

        let loaded = DimensionMapping.load()
        let b = loaded.mapping(for: MapTarget(compositeSlot: 0))
            .binding(for: .tilt1)
        XCTAssertEqual(b?.controlPoints.last?.y, 1.0)
        // Every slot is present after a migration, even ones the old
        // document never carried.
        for slot in 0..<CompositeParam.maxSlots {
            XCTAssertNotNil(
                loaded.mappings[MapTarget(compositeSlot: slot).storageKey])
        }
    }

    func testBoundTargetsListsOnlyTargetsWithBindings() {
        var m = DimensionMapping.makeDefault()
        let vib = MapTarget(paramKey: "bow_vib_cents")
        XCTAssertFalse(m.boundTargets.contains(vib))
        m.mappings[vib.storageKey] = ParameterMapping(bindings: [
            DimensionBinding(dimension: .tilt2, rangeMin: 0, rangeMax: 25),
        ])
        XCTAssertTrue(m.boundTargets.contains(vib))
        XCTAssertTrue(m.targets(for: .tilt2).contains(vib))
        XCTAssertFalse(m.targets(for: .tilt3).contains(vib))
    }
}
