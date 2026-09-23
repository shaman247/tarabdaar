import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Drone buttons map to tarab rows: every mapped frequency resolves to a jt
/// row, and the mapping defaults and prunes on decode.
final class DroneStringTests: XCTestCase {

    /// The press path is an identity chain on exact nominal Hz, so any drift
    /// between resolve and table build breaks the buttons silently.
    func testMappedFreqsResolveToJtRows() throws {
        let state = Presets.state(.sarangiPilu)
        let tanpuraSlots = TanpuraVoiceSource.slotFrequencies(
            tonicHz: state.tonicHz, scaleRatios: state.scaleRatios)
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
            for droneHz in [hz * 0.5, hz] {
                XCTAssertTrue(tanpuraSlots.contains { abs(1200 * log2($0 / droneHz)) < 0.01 },
                              "Tanpura drone \(droneHz) Hz has no slot in its selected register")
            }
        }
    }

    /// A document without `droneStringIds` decodes to the auto-mapping, and a
    /// mapped id pointing at a deleted string is pruned rather than dangling.
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
