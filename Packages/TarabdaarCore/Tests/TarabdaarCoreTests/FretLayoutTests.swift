import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret arrangements save, load and delete by name.
final class FretLayoutTests: XCTestCase {

    private let degrees = scaleDegrees(from: PitchScale.defaultJI)

    /// The persisted fields of each segment — `FretSegment.id` is per-process
    /// (minted fresh on decode), so a round trip is compared on these.
    private func layout(_ a: FretArrangement) -> [[Int]] {
        a.segments.map { [$0.degreeIndex, $0.row.rawValue] }
    }

    /// Named layouts retain their pairs and display metadata without replacing the autosave.
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

    /// Pair geometry stays frequency-aligned and equal-height across tuning, rows and octave copies.
    func testFixedGeometryAndVerticalEditing() throws {
        for degrees in [self.degrees, [(ratio: 1.0, label: "S"),
                                      (ratio: 1.00001, label: "near"),
                                      (ratio: 1.37, label: "custom")]] {
            for preset in FretLayoutPreset.allCases {
                var a = preset.arrangement(degrees: degrees)
                a.segments[0].row = .top
                a.segments[a.segments.count - 1].row = .bottom
                let size = CGSize(width: 1200, height: 400)
                let frets = fretPlacements(arrangement: a, degrees: degrees, size: size)
                for fret in frets {
                    XCTAssertEqual(fret.bottomY - fret.topY, FretSegment.height * size.height,
                                   accuracy: 1e-10)
                    XCTAssertGreaterThanOrEqual(fret.topY, -1e-10)
                    XCTAssertLessThanOrEqual(fret.bottomY, size.height + 1e-10)
                    XCTAssertEqual(fretBandX(atPixelX: fret.x,
                                             ghostExtentOctaves: a.ghostExtentOctaves,
                                             width: size.width), log2(fret.ratio), accuracy: 1e-12)
                    let center = CGPoint(x: fret.x, y: (fret.topY + fret.bottomY) / 2)
                    XCTAssertEqual(try XCTUnwrap(fretFieldLog(at: center, placements: frets, warp: 1)),
                                   log2(fret.ratio), accuracy: 1e-12)
                }
                let base = try XCTUnwrap(frets.first { !$0.isGhost })
                for y in [base.topY, base.bottomY] {
                    XCTAssertEqual(fretAssignment(at: CGPoint(x: base.x, y: y), placements: [base],
                                                  hitRadius: 9)?.degreeIndex, base.degreeIndex)
                }
            }
        }
    }

    /// Legacy layouts migrate to the nearest row and omit disabled frets when rewritten as pairs.
    func testLegacyPairMigration() throws {
        let json = #"{"version":4,"segments":[{"degreeIndex":2,"x":0.83,"topY":0.2,"bottomY":0.6},{"degreeIndex":4,"x":0.1,"topY":0,"bottomY":1,"enabled":false}]}"#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(FretArrangementDocument.self, from: json)
        XCTAssertEqual(doc.segments.count, 1)
        XCTAssertEqual(doc.segments[0].degreeIndex, 2)
        XCTAssertEqual(doc.segments[0].row, .middle)
        let v5 = #"{"version":5,"segments":[{"degreeIndex":2,"y":0.9},{"degreeIndex":4,"y":0.1}]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FretArrangementDocument.self, from: v5).segments.map(\.row), [.bottom, .top])
        let data = try JSONEncoder().encode(doc.segments)
        let pairs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(pairs[0].keys), ["degreeIndex", "row"])
        var surface = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PresetPlayingSurface(scale: .defaultJI, arrangement: FretArrangement(segments: []),
                                 snapPixels: 24, primeLimit: 7))) as? [String: Any])
        surface["fretSegments"] = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])["segments"]
        let migrated = try JSONDecoder().decode(PresetPlayingSurface.self,
                                                from: JSONSerialization.data(withJSONObject: surface))
        XCTAssertEqual(migrated.fretSegments.map(\.degreeIndex), [2])
        XCTAssertEqual(migrated.fretSegments[0].row, .middle)
    }

    /// Five-row geometry, assignment toggles and overlap unions agree on every octave copy.
    func testPiluAssignmentsAndOverlapUnions() throws {
        var arrangement = FretArrangement.defaultArrangement(degrees: degrees)
        let expected: [FretRow: [Int]] = [.bottom: [0, 2, 4, 5, 7, 9, 11], .lower: [],
                                         .middle: [0, 3, 7, 10], .upper: [], .top: [1, 6, 8]]
        for row in FretRow.allCases {
            XCTAssertEqual(arrangement.segments.filter { $0.row == row }.map(\.degreeIndex), expected[row])
        }
        for (lower, upper) in zip(FretRow.allCases, FretRow.allCases.dropFirst()) {
            XCTAssertEqual(upper.bottomY - lower.topY, FretRow.height * FretRow.overlap, accuracy: 1e-12)
        }
        let size = CGSize(width: 1200, height: 600)
        var grid = fretPlacements(arrangement: arrangement, degrees: degrees, size: size, includeUnassigned: true)
        XCTAssertEqual(grid.filter { !$0.isGhost }.count, degrees.count * 5)
        let disabled = try XCTUnwrap(grid.first { $0.isGhost && $0.row == .lower && $0.degreeIndex == 3 })
        XCTAssertFalse(disabled.isEnabled)
        let hit = try XCTUnwrap(fretAssignment(at: CGPoint(x: disabled.x, y: FretRow.lower.y * size.height),
                                               placements: grid, hitRadius: 9))
        arrangement.toggle(degreeIndex: hit.degreeIndex, row: hit.row)
        grid = fretPlacements(arrangement: arrangement, degrees: degrees, size: size, includeUnassigned: true)
        XCTAssertTrue(grid.filter { $0.degreeIndex == 3 && $0.row == .lower }.allSatisfy(\.isEnabled))
        XCTAssertEqual(arrangement.segments.filter { $0.degreeIndex == 3 && $0.row == .lower }.count, 1)
        let fields = fretRegionFields(atX: 421, placements: grid, warp: 1)
        let enabled = grid.filter(\.isEnabled)
        XCTAssertEqual(fields, fretRegionFields(atX: 421, placements: enabled, warp: 1),
                       "gray assignment candidates must never attract pitch")
        for region in FretRegion.allCases {
            let y = (region.topY + region.bottomY) / 2 * size.height
            XCTAssertEqual(fretRegion(atY: y, placements: enabled), region)
            for fret in region.frets(in: enabled) {
                XCTAssertEqual(fretFieldLog(at: CGPoint(x: fret.x, y: y), placements: enabled, warp: 1)!,
                               log2(fret.ratio), accuracy: 1e-12)
                XCTAssertEqual(fretOnset(at: CGPoint(x: fret.x + 1, y: y), placements: enabled,
                                         snapDistance: 2, warp: 1)!.pitch, log2(fret.ratio), accuracy: 1e-12)
            }
        }
        let overlapY = (FretRegion.bottomLower.topY + FretRegion.bottomLower.bottomY) / 2 * size.height
        let g = try XCTUnwrap(enabled.first { !$0.isGhost && $0.row == .lower && $0.degreeIndex == 3 })
        XCTAssertNotEqual(fretRegionFields(atX: g.x, placements: enabled, warp: 1)[.bottom], log2(g.ratio))
        XCTAssertEqual(fretFieldLog(at: CGPoint(x: g.x, y: overlapY), placements: enabled, warp: 1)!, log2(g.ratio), accuracy: 1e-12)
        // An empty row is an unwarped ribbon, even with warp and snap at full strength.
        let y = FretRow.upper.y * size.height
        let raw = fretBandX(atPixelX: 421, ghostExtentOctaves: arrangement.ghostExtentOctaves, width: size.width)
        XCTAssertEqual(fretOnset(at: CGPoint(x: 421, y: y), placements: enabled,
                                 snapDistance: 100, warp: 1)!.pitch, raw, accuracy: 1e-12)
        arrangement.toggle(degreeIndex: 3, row: .lower)
        XCTAssertFalse(arrangement.segments.contains { $0.degreeIndex == 3 && $0.row == .lower })
        let duplicates = FretArrangement(segments: arrangement.segments + arrangement.segments)
        XCTAssertEqual(duplicates.segments.count, arrangement.segments.count)
        XCTAssertNil(fretFieldLog(at: .zero, placements: []))
    }

    /// Three-row files and embedded surfaces migrate once; new rows survive another save/load.
    func testFiveRowMigration() throws {
        let old = #"{"version":6,"segments":[{"degreeIndex":0,"row":1},{"degreeIndex":1,"row":2},{"degreeIndex":2,"row":3}]}"#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(FretArrangementDocument.self, from: old)
        XCTAssertEqual(doc.segments.map(\.row), [.bottom, .middle, .top])
        let new = #"{"version":7,"segments":[{"degreeIndex":0,"row":2},{"degreeIndex":1,"row":4}]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FretArrangementDocument.self, from: new).segments.map(\.row), [.lower, .upper])
        let surface = PresetPlayingSurface(scale: .defaultJI,
            arrangement: FretArrangement(segments: [FretSegment(degreeIndex: 0, row: .lower)]), snapPixels: 24, primeLimit: 7)
        let data = try JSONEncoder().encode(surface)
        XCTAssertEqual(try JSONDecoder().decode(PresetPlayingSurface.self, from: data).fretSegments[0].row, .lower)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "fretRowCount")
        XCTAssertEqual(try JSONDecoder().decode(PresetPlayingSurface.self,
            from: JSONSerialization.data(withJSONObject: legacy)).fretSegments[0].row, .middle)
    }
}
