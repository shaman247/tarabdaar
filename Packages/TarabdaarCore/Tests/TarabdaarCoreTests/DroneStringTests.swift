import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Drone buttons map to tarab rows: every mapped frequency resolves to a jt
/// row, and the mapping defaults and prunes on decode.
final class DroneStringTests: XCTestCase {

    /// Rebuilding during a drone hold re-arms only the selected voice, and release reaches the replacement bank.
    func testRebuildKeepsDroneHoldsOnTheirSelectedVoice() throws {
        for mode in AudioEngine.DroneVoiceMode.allCases {
            let audio = AudioEngine(glideQueue: GlideSequencer(drivesTimer: false))
            let source = StringVoiceSource()
            audio.stringVoiceSource = source
            audio.useSarangiModelVoice = true
            audio.stringVoiceOverrides = ["bow_jt_threads": 0, "bow_jt_async": 0]
            audio.setDroneVoiceMode(mode)
            audio.setDroneMappedFreqs([293.67], chromatic: [true])
            audio.setDronePressed(0, true, repeating: false)

            for hz in [293.67, 329.63] {
                let previous = source.currentEngine()
                audio.rebuildSarangi(strings: [ResolvedString(freq: hz, gain: 0.95,
                    t60: 4, chromatic: true)], tonic: hz,
                    droneFreqs: [hz], droneChromatic: [true])
                let published = expectation(description: "Publish retuned \(mode) drone")
                audio.stringBuildQueue.async { DispatchQueue.main.async { published.fulfill() } }
                wait(for: [published], timeout: 15)
                let engine = try XCTUnwrap(source.currentEngine())
                XCTAssertFalse(engine === previous)
                XCTAssertNotNil(engine.droneRow(forExactHz: hz, chromatic: true))
                _ = source.renderForTesting(frames: 4096)
                XCTAssertEqual(engine.jtGateProbe().droneHot, mode == .sympathetic,
                    "A Tanpura hold must never start a sustained chromatic drone")
            }

            audio.setDronePressed(0, false, repeating: false)
            let engine = try XCTUnwrap(source.currentEngine())
            // Allow the normal drone release and onset boost to finish.
            for _ in 0..<120 { _ = source.renderForTesting(frames: 4096) }
            _ = engine.jtGateProbe()
            _ = source.renderForTesting(frames: 4096)
            XCTAssertFalse(engine.jtGateProbe().droneHot,
                "A released button must not leave sustained drive in the replacement bank")
        }
    }

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
