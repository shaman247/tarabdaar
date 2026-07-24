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
    /// knob in two tabs under two names.
    func testDeletedScalerKeysAreNotParameters() {
        for gone in ["bow_jaw_gain", "bow_vibrato"] {
            XCTAssertNil(ParamRegistry.spec(gone),
                         "\(gone) is a hybrid parameter's scaler, not a parameter")
        }
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

    /// Resting behavior must match what the deleted scalers defaulted to:
    /// full fitted buzz (jaw gain 1.0) and no vibrato (aftertouch 0).
    func testHybridRestFractionsPreserveTheShippedSound() {
        XCTAssertEqual(ParamRegistry.spec("bow_taraf_jawari")?.restFraction, 1.0)
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

    /// Taraf Purity must sweep the buzz DEPTH itself now (down to clean),
    /// which is the live-scaler path — the composite has to stay instant.
    func testTarafPuritySweepsTheBuzzDepthLive() {
        guard let purity = CompositeParam.defaults()
            .first(where: { $0.name == "Taraf Purity" }),
              let buzz = purity.members.first(where: {
                  $0.key == "bow_taraf_jawari" })
        else { return XCTFail("Taraf Purity no longer sweeps bow_taraf_jawari") }
        XCTAssertGreaterThan(buzz.lo, buzz.hi, "purity should sweep DOWN to clean")
        XCTAssertEqual(buzz.hi, 0.0)
        XCTAssertTrue(ParamRegistry.liveKeys.contains(buzz.key))
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
