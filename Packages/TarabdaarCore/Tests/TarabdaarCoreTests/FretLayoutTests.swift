import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// FRET LAYOUTS (2026-08-02): the fret positions are their own state, saved
/// and loaded by name (`FretArrangementStore`) beside two built-ins
/// (`FretLayoutPreset`) that are generated from whatever scale is loaded —
/// **C Equal Freq** (the default: x = log2(ratio), position IS pitch) and
/// **C Keyboard** (the pre-2026-08-02 default: 7 evenly-spaced svara columns
/// with the komal/tivra frets stacked above their shuddha partners).
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

    /// C Equal Freq: every fret sits at its own frequency, so x is exactly
    /// log2 of the degree's ratio — one fret per pitch, no two sharing a
    /// column, and the octave ghosts at x ± 1 continue the same ruler.
    func testEqualFreqPutsEveryFretAtItsPitch() {
        let a = FretLayoutPreset.equalFreq.arrangement(degrees: degrees)
        XCTAssertEqual(a.segments.count, degrees.count)
        for (i, deg) in degrees.enumerated() {
            let s = a.segments.first { $0.degreeIndex == i }!
            XCTAssertEqual(s.x, log2(deg.ratio), accuracy: 1e-12)
        }
        XCTAssertEqual(Set(a.segments.map { ($0.x * 1e6).rounded() }).count,
                       degrees.count, "no two frets share a column")
    }

    /// Its tiers: komal/tivra above, everything else below, S and P the long
    /// keys — and the tiers share NO endpoint (no y belongs to both).
    func testEqualFreqTiersAreSeparatedAndSPAreLongest() {
        let a = FretLayoutPreset.equalFreq.arrangement(degrees: degrees)
        let upper = ["r", "g", "M", "d", "n"].map { segment($0, in: a) }
        let lower = ["R", "G", "m", "D", "N"].map { segment($0, in: a) }
        let s = segment("S", in: a)
        let p = segment("P", in: a)

        // One height for the ordinary frets.
        for f in upper + lower { XCTAssertEqual(f.height, 0.352, accuracy: 1e-9) }
        // Separated tiers: the upper ends strictly above the lower's start,
        // and S's tip pokes into the gap without reaching the tier above.
        let upperBottom = upper.map(\.bottomY).max()!
        let lowerTop = lower.map(\.topY).min()!
        XCTAssertLessThan(upperBottom, lowerTop)
        XCTAssertLessThan(upperBottom, s.topY)
        XCTAssertLessThan(s.topY, p.topY)
        XCTAssertLessThan(p.topY, lowerTop)
        // S and P hang lower than the naturals, and S is the longest fret.
        XCTAssertGreaterThan(s.bottomY, lower.map(\.bottomY).max()!)
        XCTAssertEqual(s.bottomY, p.bottomY, accuracy: 1e-9)
        XCTAssertEqual(s.height, a.segments.map(\.height).max()!, accuracy: 1e-9)
    }

    /// C Keyboard: 7 evenly-spaced columns, one per svara — the komal/tivra
    /// fret shares its shuddha partner's column (stacked above it), which is
    /// what makes it a keyboard rather than a frequency ruler.
    func testKeyboardStacksSvaraPairsInSevenColumns() {
        let a = FretLayoutPreset.keyboard.arrangement(degrees: degrees)
        let columns = Set(a.segments.map { ($0.x * 1e6).rounded() })
        XCTAssertEqual(columns.count, 7)
        for (komal, shuddha) in [("r", "R"), ("g", "G"), ("M", "m"),
                                 ("d", "D"), ("n", "N")] {
            XCTAssertEqual(x(of: komal, in: a), x(of: shuddha, in: a), accuracy: 1e-12,
                           "\(komal) stacks on \(shuddha)")
            XCTAssertLessThan(segment(komal, in: a).bottomY,
                              segment(shuddha, in: a).topY,
                              "\(komal) sits above \(shuddha), with a gap to bend across")
        }
        // Evenly spaced: S in the first column's centre, N/n in the last.
        XCTAssertEqual(x(of: "S", in: a), 0.5 / 7.0, accuracy: 1e-12)
        XCTAssertEqual(x(of: "N", in: a), 6.5 / 7.0, accuracy: 1e-12)
    }

    /// Both built-ins follow the scale: a 7-degree scale gets 7 frets, still
    /// at their own pitches / in their own svara columns.
    func testBuiltInsFollowTheLoadedScale() {
        let major = scaleDegrees(from: ScalePreset.major.pitchScale)
        for preset in FretLayoutPreset.allCases {
            let a = preset.arrangement(degrees: major)
            XCTAssertEqual(a.segments.count, major.count, preset.label)
            XCTAssertEqual(Set(a.segments.map(\.degreeIndex)).count, major.count)
        }
        XCTAssertEqual(FretLayoutPreset.equalFreq.arrangement(degrees: major)
            .segments.map(\.x),
                       major.map { log2($0.ratio) })
    }

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

    /// Names double as filenames: separators fold, and the reserved autosave
    /// name is refused so a layout can never shadow the working arrangement.
    func testNameSanitizing() throws {
        XCTAssertEqual(try FretArrangementStore.sanitized("  Pilu/Live "),
                       "Pilu-Live")
        XCTAssertThrowsError(try FretArrangementStore.sanitized("   "))
        XCTAssertThrowsError(try FretArrangementStore.sanitized("_Current"))
    }
}
