import XCTest
import SarangiKit
@testable import TarabdaarCore

final class StringsPresetTests: XCTestCase {
    private func setup() -> StringsPreset {
        let raga = StringSpec(degree: 0, octave: -1, gain: 0.7, t60: 3)
        let chromatic = StringSpec(degree: 0, octave: -1, gain: 0.9, t60: 5,
                                   enabled: false, set: .chromatic)
        let scaleRow = StringSpec(degree: 2, gain: 0.4, t60: 6,
                                 set: .chromatic, followsScale: true)
        let state = InstrumentState(tonicHz: 300, scaleRatios: [1, 1.25, 1.5],
            strings: [raga, chromatic, scaleRow],
            droneStringIds: [chromatic.id, nil, raga.id],
            strumStringIds: [scaleRow.id, raga.id])
        return StringsPreset(state: state, droneVoice: "sympathetic",
                             droneSequence: [2, 0, 2, 1])
    }

    /// Named setups retain both bridges, identities and controls while adopting the current tuning.
    func testRoundTripAndLoadOntoDifferentScale() throws {
        let original = setup()
        let data = try original.encoded()
        let back = try StringsPreset.decode(data)
        XCTAssertEqual(back.strings, original.strings)
        XCTAssertEqual(back.droneStringIds, original.droneStringIds)
        XCTAssertEqual(back.strumStringIds, original.strumStringIds)
        XCTAssertEqual(back.droneVoice, original.droneVoice)
        XCTAssertEqual(back.droneSequence, original.droneSequence)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version", "strings", "droneStringIds",
            "strumStringIds", "droneVoice", "droneSequence"])
        var legacy = fields
        legacy["adaptation"] = 0.8
        let migrated = try StringsPreset.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(try migrated.encoded(), data)

        let scale = [1.0, 1.2, 1.4, 1.6]
        let state = back.state(tonicHz: 240, scaleRatios: scale)
        XCTAssertEqual(state.tonicHz, 240)
        XCTAssertEqual(state.scaleRatios, scale)
        XCTAssertEqual(state.strings, original.strings)
        XCTAssertEqual(state.droneStringIds, original.droneStringIds)
        XCTAssertEqual(state.strumStringIds, original.strumStringIds)
        XCTAssertEqual(state.droneStringChromatic, [nil, nil, false])
        XCTAssertEqual(state.strumStringRatios, [0.5, 1.4])
    }

    /// Scale collisions fold rows and redirect mappings to the surviving identity on each bridge.
    func testMappingsFollowNormalizationOnLoad() throws {
        var preset = setup()
        let twin = StringSpec(degree: 3, gain: 0.8, t60: 8, set: .chromatic, followsScale: true)
        let oldID = preset.strings.last!.id
        preset.strings.append(twin)
        preset.droneStringIds[1] = oldID
        let state = try StringsPreset.decode(preset.encoded()).state(
            tonicHz: 240, scaleRatios: [1, 1.5])
        XCTAssertEqual(state.strings.count, 3)
        XCTAssertEqual(state.droneStringIds[1], twin.id)
        XCTAssertEqual(state.strumStringIds.first, twin.id)
    }

    /// Default overrides survive reopening, and failed replacement leaves the last good snapshot intact.
    func testLibraryDefaultAndAtomicReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = StringsPresetLibrary(directory: dir)
        XCTAssertEqual(library.names(), [StringsPresetLibrary.defaultName])
        XCTAssertEqual(try library.load(name: "Default").encoded(), try StringsPreset.bundledDefault.encoded())
        let preset = setup()
        XCTAssertEqual(try library.save(preset, name: " My / Strings "), "My - Strings")
        try library.save(preset, name: "Default")
        let reopened = StringsPresetLibrary(directory: dir)
        XCTAssertEqual(try reopened.load(name: "Default").encoded(), try preset.encoded())
        XCTAssertEqual(reopened.names(), ["Default", "My - Strings"])

        var bad = preset
        bad.droneStringIds[0] = UUID()
        XCTAssertThrowsError(try library.save(bad, name: "Default"))
        XCTAssertEqual(try reopened.load(name: "Default").encoded(), try preset.encoded())
        bad = preset
        bad.version = 2
        XCTAssertThrowsError(try StringsPreset.decode(JSONEncoder().encode(bad)))
        bad = preset
        bad.droneSequence = [3]
        XCTAssertThrowsError(try library.save(bad, name: "Default"))
        XCTAssertThrowsError(try library.save(preset, name: " \n "))
        try library.delete(name: "My - Strings")
        XCTAssertEqual(library.names(), ["Default"])
        try library.delete(name: "Default")
        XCTAssertEqual(try library.load(name: "Default").encoded(), try StringsPreset.bundledDefault.encoded())
    }
}
