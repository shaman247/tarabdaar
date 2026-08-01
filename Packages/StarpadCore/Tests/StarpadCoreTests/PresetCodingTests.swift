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
        let b = try StarpadPreset.decode(a.encoded())

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

    /// RETIRED FIELDS (2026-07-24). `StringSpec.bright`/`.raga` and
    /// `InstrumentState`'s `fir`/`fx`/`params`/`eqBands` were deleted (the
    /// last two with the coupled network itself), but every saved state
    /// (`starpad.sarangiState.v8`) and every `.starpad`/`.sarangi` file on
    /// disk still carries them. The persist key was deliberately NOT bumped —
    /// a bump would throw the user's tarab edits away — so decoding MUST
    /// ignore the dead keys rather than fail and silently reset the
    /// instrument to the fresh-install default.
    func testDocumentsWrittenBeforeTheFieldRemovalStillLoad() throws {
        let live = Presets.state(.sarangiPilu)
        var doc = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(live))
                as? [String: Any])
        // put the retired keys back exactly as an older build wrote them
        doc["fir"] = [0.0, 1.0, 0.0]
        doc["fx"] = ["violinPre": ["enabled": true, "reverbMix": 0.2]]
        doc["params"] = ["gin": 2.6, "gout": 0.45, "N_taraf_dir": 0.02]
        doc["eqBands"] = [["freq": 500.0, "gainDB": -3.0, "q": 1.0]]
        var rows = try XCTUnwrap(doc["strings"] as? [[String: Any]])
        for i in rows.indices {
            rows[i]["bright"] = (i % 3 == 0)
            rows[i]["raga"] = (i >= 15)
        }
        doc["strings"] = rows
        let data = try JSONSerialization.data(withJSONObject: doc)

        let decoded = try JSONDecoder().decode(InstrumentState.self, from: data)
        XCTAssertEqual(decoded.strings.count, live.strings.count,
                       "an old document lost strings")
        XCTAssertEqual(decoded.tonicHz, live.tonicHz)
        // the tuning itself
        XCTAssertEqual(decoded.scaleRatios, live.scaleRatios)
        for (a, b) in zip(decoded.strings, live.strings) {
            XCTAssertEqual(a.degree, b.degree)
            XCTAssertEqual(a.octave, b.octave)
            XCTAssertEqual(a.gain, b.gain, accuracy: 1e-9)
            XCTAssertEqual(a.t60, b.t60, accuracy: 1e-9)
        }
        // and it must arrive through the preset reader too
        let p = try StarpadPreset.decode(data)
        XCTAssertEqual(p.instrument?.strings.count, live.strings.count)
    }

    /// `resolved(tonic:scaleRatios:)` carries only what the taraf builder
    /// reads. The retired `bright` / `raga` class flags went with the comb
    /// bank that read them.
    func testResolvedCarriesOnlyTheTuning() {
        let s = StringSpec(degree: 1, octave: 0, gain: 0.5, t60: 2)
        let r = s.resolved(tonic: 200, scaleRatios: [1.0, 1.5])
        XCTAssertEqual(r.freq, 300)
        XCTAssertEqual(r.gain, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.t60, 2)
        XCTAssertTrue(r.enabled)
    }

    /// Retired per-string keys (`weight`, `ratio`, `freq`, `group`) are
    /// ignored on decode — gain stands as written — and re-encoding never
    /// writes them back.
    func testRetiredStringKeysAreIgnored() throws {
        let json = """
        {"degree": 1, "gain": 0.5, "weight": 0.5, "ratio": 1.5, "group": "chromatic", "t60": 2.0}
        """
        let s = try JSONDecoder().decode(StringSpec.self, from: Data(json.utf8))
        XCTAssertEqual(s.gain, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.degree, 1)
        XCTAssertEqual(s.octave, 0)      // tolerant default
        let redone = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        for retired in ["weight", "ratio", "freq", "group"] {
            XCTAssertNil(redone?[retired])
        }
    }

    func testGarbageIsRejectedRatherThanSilentlyEmpty() {
        XCTAssertThrowsError(try StarpadPreset.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try StarpadPreset.decode(Data("not json".utf8)))
    }

    // MARK: - Split-era files (2026-07-24 → 2026-07-30)

    /// While the instrument/controls split existed, saves carried a `kind`
    /// tag and a `.starpadmap` file held only composites + tilt bindings.
    /// Both must still open under the unified reader: the `kind` key
    /// decodes away ignored, and the file simply carries only the
    /// sections it has — so applying it never disturbs the instrument.
    func testSplitEraControlsFileStillOpens() throws {
        var ctrl = StarpadPreset()
        ctrl.name = "My tilts"
        ctrl.composites = CompositeParam.defaults()
        ctrl.tiltMapping = DimensionMapping.makeDefault()
        var doc = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ctrl.encoded())
                as? [String: Any])
        doc["kind"] = "controls"     // exactly as a split-era build wrote it
        let data = try JSONSerialization.data(withJSONObject: doc)

        let p = try StarpadPreset.decode(data)
        XCTAssertNil(p.instrument)
        XCTAssertNil(p.stringOverrides)
        XCTAssertNil(p.paramValues)
        XCTAssertEqual(p.composites, ctrl.composites)
        XCTAssertNotNil(p.tiltMapping)
        XCTAssertFalse(p.isEmpty)
        XCTAssertFalse(p.sections().contains("instrument"))
    }

    func testSplitEraInstrumentFileStillOpens() throws {
        var inst = StarpadPreset()
        inst.name = "My sound"
        inst.instrument = Presets.state(.sarangiPilu)
        inst.paramValues = ["bow_expr": 0.4]
        var doc = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: inst.encoded())
                as? [String: Any])
        doc["kind"] = "instrument"
        let data = try JSONSerialization.data(withJSONObject: doc)

        let p = try StarpadPreset.decode(data)
        XCTAssertNotNil(p.instrument)
        XCTAssertEqual(p.paramValues, inst.paramValues)
        XCTAssertNil(p.composites)
        XCTAssertNil(p.tiltMapping)
    }
}
