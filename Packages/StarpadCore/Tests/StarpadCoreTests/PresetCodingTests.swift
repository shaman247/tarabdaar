import XCTest
import SarangiKit
@testable import StarpadCore

/// The preset document's CODABLE halves that live in StarpadCore —
/// composites and tilt bindings. `StarpadPreset` itself lives in the Mac
/// target (it also carries `InstrumentState`), so what is guarded here is
/// that the two pieces the preset adds over the legacy `.sarangi` format
/// survive a JSON round trip with their meaning intact.
///
/// This matters because a tilt binding encodes a `MapTarget` only through
/// its storage KEY: if that key stopped round-tripping, a loaded preset
/// would silently come back with no bindings.
final class PresetCodingTests: XCTestCase {

    func testCompositesRoundTrip() throws {
        let original = CompositeParam.defaults()
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode([CompositeParam].self, from: data)
        XCTAssertEqual(original, back)
    }

    func testTiltMappingRoundTripsIncludingDirectParameterTargets() throws {
        var m = DimensionMapping.makeDefault()
        // a composite target and a DIRECT parameter target
        let comp = MapTarget(compositeSlot: 1)
        let param = MapTarget(paramKey: "bow_body_q")
        m.mappings[param.storageKey] = ParameterMapping(bindings: [
            DimensionBinding(dimension: .tilt3, rangeMin: 8, rangeMax: 45),
        ])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(DimensionMapping.self, from: data)

        XCTAssertNotNil(back.mapping(for: comp).binding(for: .tilt2))
        guard let b = back.mapping(for: param).binding(for: .tilt3) else {
            return XCTFail("the direct parameter binding did not survive")
        }
        XCTAssertEqual(b.controlPoints.first?.y, 8)
        XCTAssertEqual(b.controlPoints.last?.y, 45)
        XCTAssertTrue(back.boundTargets.contains(param))
    }

    /// A preset written by a build that knew a parameter this build does
    /// not must not resurrect it as a binding.
    func testUnknownParameterTargetsDropOnLoad() throws {
        var m = DimensionMapping.makeDefault()
        m.mappings["param:bow_from_the_future"] = ParameterMapping(bindings: [
            DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 1),
        ])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(DimensionMapping.self, from: data)
        XCTAssertNil(MapTarget.from(storageKey: "param:bow_from_the_future"))
        XCTAssertFalse(back.boundTargets.contains {
            $0.paramKey == "bow_from_the_future"
        })
    }

    /// Every shipped composite member and every default binding target
    /// must resolve — a preset saved from a fresh install has to reload.
    func testFreshInstallStateIsFullyResolvable() throws {
        for c in CompositeParam.defaults() {
            for m in c.members {
                XCTAssertNotNil(ParamRegistry.spec(m.key),
                                "composite \(c.name) references \(m.key)")
            }
        }
        for t in DimensionMapping.makeDefault().boundTargets {
            XCTAssertNotNil(MapTarget.from(storageKey: t.storageKey))
        }
    }

    // MARK: - The document itself

    private func fullPreset() -> StarpadPreset {
        var p = StarpadPreset()
        p.name = "Test rig"
        p.savedAt = "2026-07-24T12:00:00Z"
        p.instrument = Presets.state(.sarangiPilu)
        p.stringOverrides = ["bow_body_q": 33.0, "bow_taraf_bright": 0.7]
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
        let b = try StarpadPreset.decode(a.encoded())

        XCTAssertEqual(b.name, a.name)
        XCTAssertEqual(b.savedAt, a.savedAt)
        XCTAssertEqual(b.stringOverrides, a.stringOverrides)
        XCTAssertEqual(b.paramValues, a.paramValues)
        XCTAssertEqual(b.composites, a.composites)
        // the instrument section: spot-check the parts a player would notice
        XCTAssertEqual(b.instrument?.strings.count, a.instrument?.strings.count)
        XCTAssertEqual(b.instrument?.tonicHz, a.instrument?.tonicHz)
        XCTAssertEqual(b.instrument?.autoSyncToScale, a.instrument?.autoSyncToScale)
        // and the binding that only survives via its storage key
        let t = MapTarget(paramKey: "bow_mu_s")
        XCTAssertEqual(b.tiltMapping?.mapping(for: t).binding(for: .tilt2)?
                        .controlPoints.last?.y, 1.1)
    }

    func testSectionsSummaryDescribesWhatIsInTheFile() throws {
        let p = try StarpadPreset.decode(fullPreset().encoded())
        let s = p.sections().joined(separator: ", ")
        XCTAssertTrue(s.contains("instrument"), s)
        XCTAssertTrue(s.contains("physics"), s)
        XCTAssertTrue(s.contains("parameters"), s)
        XCTAssertTrue(s.contains("composites"), s)
        XCTAssertTrue(s.contains("tilt bindings"), s)
    }

    /// A partial preset — say tilt bindings only — must load without
    /// disturbing anything else. `applyPreset` skips nil sections.
    func testPartialPresetCarriesOnlyWhatItHas() throws {
        var p = StarpadPreset()
        p.name = "Just my tilts"
        p.tiltMapping = DimensionMapping.makeDefault()
        let back = try StarpadPreset.decode(p.encoded())
        XCTAssertNil(back.instrument)
        XCTAssertNil(back.stringOverrides)
        XCTAssertNil(back.paramValues)
        XCTAssertNotNil(back.tiltMapping)
        XCTAssertEqual(back.sections(), ["4 tilt bindings"])
    }

    /// LEGACY: a file saved before presets existed is a bare
    /// `InstrumentState`. It must still open, as an instrument-only preset.
    func testLegacySarangiFileStillOpens() throws {
        let legacy = Presets.state(.sarangiPilu)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(legacy)

        let p = try StarpadPreset.decode(data)
        XCTAssertNotNil(p.instrument, "legacy .sarangi file failed to load")
        XCTAssertEqual(p.instrument?.strings.count, legacy.strings.count)
        XCTAssertEqual(p.instrument?.tonicHz, legacy.tonicHz)
        XCTAssertNil(p.composites)
        XCTAssertNil(p.tiltMapping)
        XCTAssertEqual(p.sections(), ["instrument"])
    }

    func testGarbageIsRejectedRatherThanSilentlyEmpty() {
        XCTAssertThrowsError(try StarpadPreset.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try StarpadPreset.decode(Data("not json".utf8)))
    }

    // MARK: - The instrument / controls split

    /// The two scopes must partition the document: everything the
    /// instrument scope reports, the controls scope must not, and between
    /// them they cover the whole file.
    func testScopesPartitionTheDocument() throws {
        let p = try StarpadPreset.decode(fullPreset().encoded())
        let inst = Set(p.sections(in: .instrument))
        let ctrl = Set(p.sections(in: .controls))
        let all = Set(p.sections(in: .all))
        XCTAssertTrue(inst.isDisjoint(with: ctrl), "scopes overlap")
        XCTAssertEqual(inst.union(ctrl), all, "a section belongs to neither scope")
        XCTAssertTrue(inst.contains("instrument"))
        XCTAssertTrue(ctrl.contains { $0.contains("tilt bindings") })
        XCTAssertTrue(ctrl.contains { $0.contains("composites") })
    }

    /// A controls preset must carry NO instrument sections, so loading one
    /// can never disturb the sound (and vice versa).
    func testEachScopeCarriesOnlyItsOwnHalf() {
        var ctrl = StarpadPreset()
        ctrl.kind = .controls
        ctrl.composites = CompositeParam.defaults()
        ctrl.tiltMapping = DimensionMapping.makeDefault()
        XCTAssertTrue(ctrl.isEmpty(in: .instrument),
                      "a controls preset would touch the instrument")
        XCTAssertFalse(ctrl.isEmpty(in: .controls))

        var inst = StarpadPreset()
        inst.kind = .instrument
        inst.instrument = Presets.state(.sarangiPilu)
        inst.paramValues = ["bow_expr": 0.4]
        XCTAssertTrue(inst.isEmpty(in: .controls),
                      "an instrument preset would touch the mapping")
        XCTAssertFalse(inst.isEmpty(in: .instrument))
    }

    /// An older COMBINED `.starpad` (written before the split, so it has
    /// both halves and no `kind`) must still be loadable as either half.
    func testCombinedPresetLoadsAsEitherHalf() throws {
        var combined = fullPreset()
        combined.kind = nil                       // pre-split file
        let p = try StarpadPreset.decode(combined.encoded())
        XCTAssertNil(p.kind)
        XCTAssertFalse(p.isEmpty(in: .instrument))
        XCTAssertFalse(p.isEmpty(in: .controls))
    }

    /// Opening a controls preset where an instrument is expected must be
    /// detectable, so the UI can say so rather than silently doing nothing.
    func testWrongKindIsDetectable() throws {
        var ctrl = StarpadPreset()
        ctrl.kind = .controls
        ctrl.tiltMapping = DimensionMapping.makeDefault()
        let p = try StarpadPreset.decode(ctrl.encoded())
        XCTAssertTrue(p.isEmpty(in: .instrument))
        XCTAssertEqual(p.kind, .controls)
    }

    func testScopeFileExtensionsAreDistinct() {
        XCTAssertEqual(PresetScope.instrument.fileExtension, "starpad")
        XCTAssertEqual(PresetScope.controls.fileExtension, "starpadmap")
        XCTAssertNotEqual(PresetScope.instrument.fileExtension,
                          PresetScope.controls.fileExtension)
    }
}
