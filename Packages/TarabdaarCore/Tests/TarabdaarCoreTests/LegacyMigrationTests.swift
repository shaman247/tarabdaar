import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Starpad / TarabPad → Tarabdaar one-time migration of presets and defaults.
final class LegacyMigrationTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLegacyPresetExtensionsRename() throws {
        let fm = FileManager.default
        try Data("a".utf8).write(to: tmp.appendingPathComponent("Evening.starpad"))
        try Data("b".utf8).write(to: tmp.appendingPathComponent("Rig.starpadmap"))
        try Data("c".utf8).write(to: tmp.appendingPathComponent("Interim.tarabpad"))
        // A clobber candidate: the new name already exists — the legacy
        // file must survive untouched rather than overwrite it.
        try Data("old".utf8).write(to: tmp.appendingPathComponent("Kept.starpad"))
        try Data("new".utf8).write(to: tmp.appendingPathComponent("Kept.tarabdaar"))

        LegacyMigration.renameLegacyPresets(in: tmp)

        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Evening.tarabdaar").path))
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Rig.tarabdaarmap").path))
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Interim.tarabdaar").path))
        XCTAssertFalse(fm.fileExists(atPath: tmp.appendingPathComponent("Evening.starpad").path))
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("Kept.tarabdaar")),
                       Data("new".utf8))
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Kept.starpad").path))
    }

    func testDefaultsImportMapsPrefixSkipsRetiredAndRunsOnce() throws {
        let suite = "LegacyMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let plistURL = tmp.appendingPathComponent("legacy.plist")
        let legacy: [String: Any] = [
            "starpad.sarangiState.v8": Data([1, 2, 3]),
            "starpad.tonicHz": 293.66,          // retired — must not import
            "synthEnabled": true,               // unprefixed — imports as-is
            "starpad.ipadLayout": 4,
            "tarabpad.droneVoice.v1": "tanpura",     // interim-identity prefix
            "tarabpad.migratedFromStarpad.v1": true, // interim marker — retired
        ]
        try PropertyListSerialization.data(fromPropertyList: legacy,
                                           format: .binary, options: 0)
            .write(to: plistURL)

        // A value the user already wrote under the new identity wins.
        defaults.set(7, forKey: "tarabdaar.ipadLayout")

        LegacyMigration.migrateUserDefaults(into: defaults, legacyPlist: plistURL)

        XCTAssertEqual(defaults.data(forKey: "tarabdaar.sarangiState.v8"),
                       Data([1, 2, 3]))
        XCTAssertNil(defaults.object(forKey: "tarabdaar.tonicHz"))
        XCTAssertEqual(defaults.bool(forKey: "synthEnabled"), true)
        XCTAssertEqual(defaults.integer(forKey: "tarabdaar.ipadLayout"), 7)
        XCTAssertEqual(defaults.string(forKey: "tarabdaar.droneVoice.v1"), "tanpura")
        XCTAssertNil(defaults.object(forKey: "tarabdaar.migratedFromStarpad.v1"))

        // Second run is a no-op even against a changed plist.
        try PropertyListSerialization.data(
            fromPropertyList: ["starpad.sarangiState.v8": Data([9])],
            format: .binary, options: 0).write(to: plistURL)
        LegacyMigration.migrateUserDefaults(into: defaults, legacyPlist: plistURL)
        XCTAssertEqual(defaults.data(forKey: "tarabdaar.sarangiState.v8"),
                       Data([1, 2, 3]))
    }

    func testPresetLibraryListsAndLoadsLegacyExtension() throws {
        let lib = PresetLibrary(directory: tmp)
        var preset = TarabdaarPreset()
        preset.name = "Old"
        preset.instrument = Presets.state(.sarangiPilu)
        try preset.encoded().write(to: tmp.appendingPathComponent("Old.starpad"))
        XCTAssertEqual(lib.names(), ["Old"])
        XCTAssertEqual(try lib.load(name: "Old").name, "Old")
        try lib.delete(name: "Old")
        XCTAssertEqual(lib.names(), [])
    }
}
