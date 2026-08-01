import XCTest
@testable import StarpadCore

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
        XCTAssertNotNil(ParamRegistry.spec("bow_jtaraf_on"))
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
    /// recruitment amount sweeps DOWN its bipolar range (1 = lush
    /// chorus → 0 = kin-only). Every member must stay on a LIVE path —
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
        // The recruitment member rests on the FITTED taraf (0.5) and
        // sweeps down to the kin-only strip (2026-08-01 coherence rev:
        // the old lo of 1.0 parked the resting instrument at the ×2
        // lush chorus, which read as a backing ensemble).
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
        d.removeObject(forKey: "starpad_dimensionMapping_v6")
        defer {
            d.removeObject(forKey: "starpad_dimensionMapping_v5")
            d.removeObject(forKey: "starpad_dimensionMapping_v6")
        }
        let legacy = DimensionMapping(mappings: [
            "midiCC71": ParameterMapping(bindings: [
                DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 127),
            ], defaultValue: 63.5),
        ])
        d.set(try JSONEncoder().encode(legacy),
              forKey: "starpad_dimensionMapping_v5")

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
