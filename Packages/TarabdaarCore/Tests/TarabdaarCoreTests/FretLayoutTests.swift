import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret arrangements save, load and delete by name.
final class FretLayoutTests: XCTestCase {

    private let degrees = scaleDegrees(from: PitchScale.defaultJI)

    private func x(of label: String, in a: FretArrangement) -> Double {
        let i = degrees.firstIndex { $0.label == label }!
        return a.segments.first { $0.degreeIndex == i }!.x
    }

    private func segment(_ label: String, in a: FretArrangement) -> FretSegment {
        let i = degrees.firstIndex { $0.label == label }!
        return a.segments.first { $0.degreeIndex == i }!
    }

    /// The persisted fields of each segment — `FretSegment.id` is per-process
    /// (minted fresh on decode), so a round trip is compared on these.
    private func layout(_ a: FretArrangement) -> [[Double]] {
        a.segments.map { [Double($0.degreeIndex), $0.x, $0.topY, $0.bottomY,
                          $0.enabled ? 1 : 0] }
    }

    // MARK: - The built-ins

    // MARK: - Saving and loading

    /// A layout round-trips by name: positions, extents, ghost extent and
    /// drone ratios all survive, the saved name is listed (the live autosave
    /// never is), and deleting removes it.
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
