import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret arrangements save, load and delete by name.
final class FretLayoutTests: XCTestCase {

    private let degrees = scaleDegrees(from: PitchScale.defaultJI)

    /// The persisted fields of each segment — `FretSegment.id` is per-process
    /// (minted fresh on decode), so a round trip is compared on these.
    private func layout(_ a: FretArrangement) -> [[Double]] {
        a.segments.map { [Double($0.degreeIndex), $0.x, $0.topY, $0.bottomY,
                          $0.enabled ? 1 : 0] }
    }

    /// A layout round-trips by name — positions, extents and drone ratios all
    /// survive, the live autosave is never listed, and deleting removes it.
    func testSaveLoadDeleteRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FretLayoutTests-\(UUID().uuidString)")
        FretArrangementStore.dirOverride = tmp
        defer {
            FretArrangementStore.dirOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        var a = FretLayoutPreset.keyboard.arrangement(degrees: degrees)
        a.ghostExtentOctaves = 1.25
        FretArrangementStore.saveCurrent(
            FretLayoutPreset.equalFreq.arrangement(degrees: degrees))
        try FretArrangementStore.save(a, name: "C Keyboard")

        XCTAssertEqual(FretArrangementStore.savedNames(), ["C Keyboard"],
                       "the live autosave is not a listed layout")
        let loaded = try FretArrangementStore.load(name: "C Keyboard")
        XCTAssertEqual(layout(loaded), layout(a))
        XCTAssertNotEqual(loaded.segments.map(\.id), a.segments.map(\.id),
                          "ids are per-process, minted fresh on decode")
        XCTAssertEqual(loaded.ghostExtentOctaves, 1.25)
        XCTAssertEqual(loaded.droneRatios, a.droneRatios)
        // The autosave is untouched by the named save.
        XCTAssertEqual(FretArrangementStore.loadCurrent().map(layout),
                       layout(FretLayoutPreset.equalFreq.arrangement(degrees: degrees)))

        try FretArrangementStore.delete(name: "C Keyboard")
        XCTAssertEqual(FretArrangementStore.savedNames(), [])
    }

}
