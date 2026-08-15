import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The app-managed preset library (2026-07-30): saving asks for a NAME,
/// never a location, and every saved preset appears in the Load-preset
/// menu. What is guarded here is the name↔file contract — a saved name
/// must come back in `names()` and load the same document.
final class PresetLibraryTests: XCTestCase {

    private var lib: PresetLibrary!

    override func setUpWithError() throws {
        lib = PresetLibrary(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetLibraryTests-\(UUID().uuidString)",
                                    isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: lib.directory)
    }

    private func rig(name: String = "") -> TarabdaarPreset {
        var p = TarabdaarPreset()
        p.name = name
        p.instrument = Presets.state(.sarangiPilu)
        p.paramValues = ["bow_expr": 0.4]
        p.composites = CompositeParam.defaults()
        p.tiltMapping = DimensionMapping.makeDefault()
        return p
    }

    func testMissingFolderIsAnEmptyLibrary() {
        XCTAssertEqual(lib.names(), [])
    }

    func testSaveListLoadRoundTrip() throws {
        let saved = rig()
        try lib.save(saved, name: "Evening Pilu")
        XCTAssertEqual(lib.names(), ["Evening Pilu"])

        let back = try lib.load(name: "Evening Pilu")
        XCTAssertEqual(back.name, "Evening Pilu")
        XCTAssertNotNil(back.instrument)
        XCTAssertEqual(back.paramValues, ["bow_expr": 0.4])
        // defaults() mints fresh IDs per call, so compare to what was saved
        XCTAssertEqual(back.composites, saved.composites)
        XCTAssertNotNil(back.tiltMapping)
    }

    func testNamesSortCaseInsensitively() throws {
        for n in ["zeta", "Alpha", "beta"] { try lib.save(rig(), name: n) }
        XCTAssertEqual(lib.names(), ["Alpha", "beta", "zeta"])
    }

    func testSameNameOverwrites() throws {
        try lib.save(rig(), name: "Rig")
        var changed = rig()
        changed.paramValues = ["bow_expr": 0.9]
        try lib.save(changed, name: "Rig")
        XCTAssertEqual(lib.names(), ["Rig"])
        XCTAssertEqual(try lib.load(name: "Rig").paramValues, ["bow_expr": 0.9])
    }

    func testDeleteRemovesFromTheList() throws {
        try lib.save(rig(), name: "Rig")
        try lib.delete(name: "Rig")
        XCTAssertEqual(lib.names(), [])
        XCTAssertThrowsError(try lib.load(name: "Rig"))
    }

    /// The name doubles as the filename, so separators sanitize and an
    /// empty name refuses rather than writing `.tarabdaar`.
    func testNameSanitization() throws {
        XCTAssertEqual(try PresetLibrary.sanitized("  a/b:c  "), "a-b-c")
        XCTAssertThrowsError(try PresetLibrary.sanitized("   "))
        try lib.save(rig(), name: " a/b ")
        XCTAssertEqual(lib.names(), ["a-b"])
        XCTAssertEqual(try lib.load(name: "a-b").name, "a-b")
    }

    /// A file dropped into the folder by hand (or synced from another
    /// machine) is a legitimate library entry — including split-era and
    /// legacy `.sarangi`-content files, which apply only what they carry.
    func testForeignFileInTheFolderIsListedAndLoads() throws {
        try FileManager.default.createDirectory(at: lib.directory,
                                                withIntermediateDirectories: true)
        let legacy = try JSONEncoder().encode(Presets.state(.sarangiPilu))
        try legacy.write(to: lib.url(for: "Dropped"))
        XCTAssertEqual(lib.names(), ["Dropped"])
        let p = try lib.load(name: "Dropped")
        XCTAssertNotNil(p.instrument)
        XCTAssertNil(p.tiltMapping)
    }
}
