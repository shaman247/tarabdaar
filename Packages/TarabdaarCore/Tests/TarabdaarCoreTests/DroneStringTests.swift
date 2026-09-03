import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Drone buttons map to tarab rows: mapped frequencies resolve to jt rows, decode defaults and prunes stale mappings.
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

    /// The RAGA bridge's rows (the pre-split `jawariRows` input).
    private func taraf() -> [(f: Double, gain: Double, t60: Double)] {
        strings().filter { $0.enabled && !$0.chromatic }
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
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

    // MARK: - Controller strum set (2026-08-27)

}
