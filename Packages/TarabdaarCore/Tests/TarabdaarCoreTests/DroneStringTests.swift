import XCTest
import SarangiKit
@testable import TarabdaarCore

/// DRONE BUTTONS → MAPPED SYMPATHETIC STRINGS (2026-07-25). There are no
/// dedicated drone strings: the jawari web is built from the tarab rows
/// alone, and each of the 3 Fret Pad buttons plucks ONE mapped row
/// (`InstrumentState.droneStringIds` → `BowEngine.droneRow(forExactHz:)`,
/// an identity lookup on the row's nominal Hz). These tests pin the
/// auto-mapping, the mapped-freq → jt-row identity, the build/live row
/// unification, and the document migrations.
final class DroneStringTests: XCTestCase {

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    private func bp() throws -> BowParams {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        return bp
    }

    private func taraf() -> [(f: Double, gain: Double, t60: Double)] {
        strings().filter(\.enabled).map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
    }

    /// SarangiKit can't see `FretArrangement.droneCount` (dependency
    /// direction), so the two counts are mirrored by hand — pin them equal.
    func testDroneSlotCountsAgree() {
        XCTAssertEqual(InstrumentState.droneSlotCount, FretArrangement.droneCount)
        XCTAssertEqual(FretArrangement.defaultDroneRatios.count,
                       FretArrangement.droneCount)
    }

    /// The default (Pilu) document auto-maps all 3 buttons, each to an
    /// enabled string within ±100 ¢ of its target (low Sa · low Pa · Sa).
    func testAutoMappingFindsAllThreeTargets() {
        let state = Presets.state(.sarangiPilu)
        XCTAssertEqual(state.droneStringIds.count, 3)
        for (id, target) in zip(state.droneStringIds, [0.5, 0.75, 1.0]) {
            guard let id, let s = state.strings.first(where: { $0.id == id }) else {
                return XCTFail("slot for target \(target) unmapped in the default bank")
            }
            XCTAssertTrue(s.enabled)
            XCTAssertLessThanOrEqual(
                abs(1200.0 * log2(s.ratio(in: state.scaleRatios) / target)), 100.0)
        }
    }

    /// Every default-mapped string must be found in the BUILT engine's jt
    /// web by exact nominal Hz — the whole press path (`droneStringFreqs`
    /// → `droneRow(forExactHz:)`) is an identity chain, so any drift
    /// between resolve and table build breaks the buttons silently.
    func testMappedFreqsResolveToJtRows() throws {
        let state = Presets.state(.sarangiPilu)
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: state.tonicHz, strings: state.resolvedStrings,
            mapper: src.mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        for hz in state.droneStringFreqs {
            guard let hz else { return XCTFail("default slot unmapped") }
            XCTAssertNotNil(e.droneRow(forExactHz: hz),
                            "mapped string \(hz) Hz not found in the jt web")
        }
    }

    /// `droneStringFreqs` goes nil for unmapped slots, dangling ids and
    /// disabled strings — the button must be inert in all three cases.
    func testDroneStringFreqsNilCases() {
        var state = Presets.state(.sarangiPilu)
        state.droneStringIds[0] = nil                      // unmapped
        state.droneStringIds[1] = UUID()                   // dangling
        if let id = state.droneStringIds[2],
           let i = state.strings.firstIndex(where: { $0.id == id }) {
            state.strings[i].enabled = false               // disabled
        }
        XCTAssertEqual(state.droneStringFreqs, [nil, nil, nil])
    }

    /// Build and in-place jawari row selections must agree exactly (the
    /// 2026-07-25 unification): a shape mismatch makes the kernel silently
    /// refuse every live jt reload.
    func testBuildAndLivePathsSelectIdenticalRows() throws {
        let bp = try bp()
        let tonic = 328.9
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: tonic, strings: strings(), mapper: src.mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let selected = StringVoiceSource.jawariRows(bp: bp, tonicHz: tonic,
                                                    taraf: taraf())
        XCTAssertEqual(e.jtRowFreqs.count, selected.count,
                       "build/live jawari row shapes diverged")
        for (a, b) in zip(e.jtRowFreqs, selected.map(\.f)) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    /// Documents without `droneStringIds` (including the one-day
    /// `droneStrings` per-slot-spec era, whose key is ignored) decode to
    /// the auto-mapping; a mapped id pointing at a deleted string is
    /// pruned to nil rather than dangling.
    func testDecodeDefaultsAndPrunesMapping() throws {
        let state = Presets.state(.sarangiPilu)
        var obj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)) as! [String: Any]
        obj.removeValue(forKey: "droneStringIds")
        obj["droneStrings"] = [["enabled": true]]          // retired key: ignored
        let decoded = try JSONDecoder().decode(
            InstrumentState.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(decoded.droneStringIds,
                       InstrumentState.autoDroneMapping(strings: decoded.strings,
                                                        scaleRatios: decoded.scaleRatios))
        XCTAssertTrue(decoded.droneStringIds.allSatisfy { $0 != nil })

        var withDangling = state
        withDangling.droneStringIds[1] = UUID()
        let redecoded = try JSONDecoder().decode(
            InstrumentState.self, from: JSONEncoder().encode(withDangling))
        XCTAssertNil(redecoded.droneStringIds[1])
        XCTAssertEqual(redecoded.droneStringIds[0], state.droneStringIds[0])
    }
}
