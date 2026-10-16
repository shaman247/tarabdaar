import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret arrangements save, load and delete by name.
final class FretLayoutTests: XCTestCase {

    private let degrees = scaleDegrees(from: PitchScale.defaultJI)

    /// Scale and layout replacements preserve the last good document when encoding fails.
    func testAtomicStoreReplacement() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedDocumentTests-\(UUID().uuidString)")
        ScaleStore.dirOverride = tmp.appendingPathComponent("Scales")
        FretArrangementStore.dirOverride = tmp.appendingPathComponent("Layouts")
        defer {
            ScaleStore.dirOverride = nil
            FretArrangementStore.dirOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        let scaleURL = ScaleStore.url(forName: "Custom")
        try ScaleStore.save(.defaultJI, name: "Custom")
        // An abandoned old staging path must not block future saves.
        try FileManager.default.createDirectory(at: scaleURL.appendingPathExtension("tmp"),
                                               withIntermediateDirectories: true)
        let scale = ScalePreset.pythagorean.pitchScale
        try ScaleStore.save(scale, name: "Custom")
        XCTAssertEqual(try ScaleStore.load(name: "Custom"), scale)
        let scaleBytes = try Data(contentsOf: scaleURL)
        var invalidScale = scale
        invalidScale.points[0].y = .nan
        XCTAssertThrowsError(try ScaleStore.save(invalidScale, name: "Custom"))
        XCTAssertEqual(try Data(contentsOf: scaleURL), scaleBytes)

        let layoutURL = FretArrangementStore.url(forName: "Custom")
        var arrangement = FretLayoutPreset.keyboard.arrangement(degrees: degrees)
        try FretArrangementStore.save(arrangement, name: "Custom")
        try FileManager.default.createDirectory(at: layoutURL.appendingPathExtension("tmp"),
                                               withIntermediateDirectories: true)
        arrangement.ghostExtentOctaves = 1.5
        try FretArrangementStore.save(arrangement, name: "Custom")
        XCTAssertEqual(try FretArrangementStore.load(name: "Custom").ghostExtentOctaves, 1.5)
        let layoutBytes = try Data(contentsOf: layoutURL)
        arrangement.droneRatios[0] = .nan
        XCTAssertThrowsError(try FretArrangementStore.save(arrangement, name: "Custom"))
        XCTAssertEqual(try Data(contentsOf: layoutURL), layoutBytes)
    }

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
                a.segments[0].row = .row15
                a.segments[a.segments.count - 1].row = .row1
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
        XCTAssertEqual(doc.segments.count, 3)
        XCTAssertEqual(doc.segments[0].degreeIndex, 2)
        XCTAssertEqual(doc.segments[0].row, .row5)
        let v5 = #"{"version":5,"segments":[{"degreeIndex":2,"y":0.9},{"degreeIndex":4,"y":0.1}]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FretArrangementDocument.self, from: v5).segments.map(\.row), [.row1, .row9, .row2, .row8])
        let data = try JSONEncoder().encode(doc.segments)
        let pairs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(pairs[0].keys), ["degreeIndex", "row"])
        var surface = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PresetPlayingSurface(scale: .defaultJI, arrangement: FretArrangement(segments: []),
                                 snapPixels: 24))) as? [String: Any])
        surface.removeValue(forKey: "fretRowCount")
        surface["fretSegments"] = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])["segments"]
        let migrated = try JSONDecoder().decode(PresetPlayingSurface.self,
                                                from: JSONSerialization.data(withJSONObject: surface))
        XCTAssertEqual(migrated.fretSegments.map(\.degreeIndex), [2, 2, 2])
        XCTAssertEqual(migrated.fretSegments[0].row, .row5)
    }

    /// Fifteen equal rows preserve the lower layout and keep assignments independent across octave copies.
    func testPiluAssignmentsAndIndependentRows() throws {
        var arrangement = FretArrangement.piluArrangement(degrees: degrees)
        let expected: [FretRow: [Int]] = [.row2: [0, 2, 4, 5, 7, 9, 11],
                                         .row4: [0, 3, 7, 10], .row6: [0, 3, 7, 10],
                                         .row8: [1, 6, 8], .row1: [0, 2, 4, 5, 7, 9, 11], .row3: [],
                                         .row5: [0, 3, 7, 10], .row7: [], .row9: [1, 6, 8]]
        for row in FretRow.allCases {
            XCTAssertEqual(arrangement.segments.filter { $0.row == row }.map(\.degreeIndex), expected[row] ?? [])
        }
        let currentDefault = FretArrangement.defaultArrangement(degrees: degrees)
        let capturedRows = [[4, 5, 9, 11], [2, 4, 5, 9, 11], [0, 2, 5, 7],
                            [0, 2, 5, 7, 10], [0, 3, 7, 10], [0, 1, 3, 7, 8, 10],
                            [1, 3, 8, 10], [1, 6, 8, 10], [6, 8, 10]]
        for row in FretRow.allCases {
            XCTAssertEqual(currentDefault.segments.filter { $0.row == row }.map(\.degreeIndex),
                           row.rawValue <= 9 ? capturedRows[row.rawValue - 1] : [])
        }
        for (lower, upper) in zip(FretRow.allCases, FretRow.allCases.dropFirst()) {
            XCTAssertEqual(upper.bottomY, lower.topY, accuracy: 1e-12)
        }
        let size = CGSize(width: 1200, height: 600)
        var grid = fretPlacements(arrangement: arrangement, degrees: degrees, size: size, includeUnassigned: true)
        XCTAssertEqual(grid.filter { !$0.isGhost }.count, degrees.count * 15)
        let disabled = try XCTUnwrap(grid.first { $0.isGhost && $0.row == .row3 && $0.degreeIndex == 3 })
        XCTAssertFalse(disabled.isEnabled)
        let hit = try XCTUnwrap(fretAssignment(at: CGPoint(x: disabled.x, y: FretRow.row3.y * size.height),
                                               placements: grid, hitRadius: 9))
        arrangement.toggle(degreeIndex: hit.degreeIndex, row: hit.row)
        grid = fretPlacements(arrangement: arrangement, degrees: degrees, size: size, includeUnassigned: true)
        XCTAssertTrue(grid.filter { $0.degreeIndex == 3 && $0.row == .row3 }.allSatisfy(\.isEnabled))
        XCTAssertEqual(arrangement.segments.filter { $0.degreeIndex == 3 && $0.row == .row3 }.count, 1)
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
        let adjacentY = (FretRegion.row2.topY + FretRegion.row2.bottomY) / 2 * size.height
        let g = try XCTUnwrap(enabled.first { !$0.isGhost && $0.row == .row3 && $0.degreeIndex == 3 })
        XCTAssertNotEqual(fretRegionFields(atX: g.x, placements: enabled, warp: 1)[.row1], log2(g.ratio))
        XCTAssertNotEqual(fretFieldLog(at: CGPoint(x: g.x, y: adjacentY), placements: enabled, warp: 1)!, log2(g.ratio), "editing one row must not alter its neighbor")
        // An empty row is an unwarped ribbon, even with warp and snap at full strength.
        let y = FretRow.row7.y * size.height
        let raw = fretBandX(atPixelX: 421, ghostExtentOctaves: arrangement.ghostExtentOctaves, width: size.width)
        XCTAssertEqual(fretOnset(at: CGPoint(x: 421, y: y), placements: enabled,
                                 snapDistance: 100, warp: 1)!.pitch, raw, accuracy: 1e-12)
        arrangement.toggle(degreeIndex: 3, row: .row3)
        XCTAssertFalse(arrangement.segments.contains { $0.degreeIndex == 3 && $0.row == .row3 })
        let duplicates = FretArrangement(segments: arrangement.segments + arrangement.segments)
        XCTAssertEqual(duplicates.segments.count, arrangement.segments.count)
        XCTAssertNil(fretFieldLog(at: .zero, placements: []))
    }

    /// Legacy rows expand their unions once, and every new row survives document and preset round trips.
    func testLegacyRowMigration() throws {
        let old = #"{"version":6,"segments":[{"degreeIndex":0,"row":1},{"degreeIndex":1,"row":2},{"degreeIndex":2,"row":3}]}"#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(FretArrangementDocument.self, from: old)
        XCTAssertEqual(doc.segments.map(\.row), [.row1, .row5, .row9, .row2, .row4, .row6, .row8])
        let five = #"{"version":7,"segments":[{"degreeIndex":0,"row":1},{"degreeIndex":0,"row":2},{"degreeIndex":1,"row":2},{"degreeIndex":2,"row":3},{"degreeIndex":3,"row":4},{"degreeIndex":4,"row":5}]}"#.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(FretArrangementDocument.self, from: five)
        let expected = [[0], [0, 1], [0, 1], [0, 1, 2], [2], [2, 3], [3], [3, 4], [4]]
        for row in FretRow.allCases {
            XCTAssertEqual(migrated.segments.filter { $0.row == row }.map(\.degreeIndex),
                           row.rawValue <= 9 ? expected[row.rawValue - 1] : [])
        }
        let reloaded = try JSONDecoder().decode(FretArrangementDocument.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(reloaded.version, 9)
        XCTAssertEqual(layout(FretArrangement(segments: reloaded.segments)), layout(FretArrangement(segments: migrated.segments)))
        let surface = PresetPlayingSurface(scale: .defaultJI,
            arrangement: FretArrangement(segments: migrated.segments), snapPixels: 24)
        let data = try JSONEncoder().encode(surface)
        XCTAssertEqual(layout(try JSONDecoder().decode(PresetPlayingSurface.self, from: data).arrangement), layout(surface.arrangement))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["fretRowCount"] = 5
        legacy["fretSegments"] = try XCTUnwrap(JSONSerialization.jsonObject(with: five) as? [String: Any])["segments"]
        XCTAssertEqual(layout(try JSONDecoder().decode(PresetPlayingSurface.self,
            from: JSONSerialization.data(withJSONObject: legacy)).arrangement), layout(surface.arrangement))
        legacy.removeValue(forKey: "fretRowCount")
        legacy["fretSegments"] = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])["segments"]
        XCTAssertEqual(try JSONDecoder().decode(PresetPlayingSurface.self,
            from: JSONSerialization.data(withJSONObject: legacy)).fretSegments.map(\.row), doc.segments.map(\.row))
        legacy["fretRowCount"] = 9
        legacy["fretSegments"] = [["degreeIndex": 2, "row": 9]]
        let nine = try JSONDecoder().decode(PresetPlayingSurface.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(nine.fretRowCount, 15)
        XCTAssertEqual(layout(nine.arrangement), [[2, 9]])
        let nineDocument = #"{"version":8,"segments":[{"degreeIndex":2,"row":9}]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FretArrangementDocument.self,
            from: nineDocument).segments.map(\.row), [.row9])
    }

    /// The upper rows are editable, playable and persistent without changing the lower nine assignments.
    func testAddedRowsRoundTripAndRemainPlayable() throws {
        var arrangement = FretArrangement.defaultArrangement(degrees: degrees)
        let original = layout(arrangement)
        let size = CGSize(width: 1200, height: 750)
        for row in FretRow.allCases.suffix(6) {
            let candidates = fretPlacements(arrangement: arrangement, degrees: degrees,
                                            size: size, includeUnassigned: true)
            let fret = try XCTUnwrap(candidates.first { $0.row == row && $0.degreeIndex == 0 && !$0.isGhost })
            let point = CGPoint(x: fret.x, y: row.y * size.height)
            let hit = try XCTUnwrap(fretAssignment(at: point, placements: candidates, hitRadius: 9))
            XCTAssertEqual(hit.row, row)
            arrangement.toggle(degreeIndex: hit.degreeIndex, row: hit.row)
            let playing = fretPlacements(arrangement: arrangement, degrees: degrees, size: size)
            XCTAssertEqual(try XCTUnwrap(fretOnset(at: point, placements: playing,
                                                  snapDistance: 24, warp: 1)).pitch, 0, accuracy: 1e-12)
        }
        XCTAssertEqual(Array(layout(arrangement).prefix(original.count)), original)
        let document = FretArrangementDocument(segments: arrangement.segments,
            ghostExtentOctaves: arrangement.ghostExtentOctaves, droneRatios: arrangement.droneRatios)
        let reloaded = try JSONDecoder().decode(FretArrangementDocument.self,
            from: JSONEncoder().encode(document))
        XCTAssertEqual(layout(FretArrangement(segments: reloaded.segments)), layout(arrangement))
        let surface = PresetPlayingSurface(scale: .defaultJI, arrangement: arrangement, snapPixels: 24)
        XCTAssertEqual(layout(try JSONDecoder().decode(PresetPlayingSurface.self,
            from: JSONEncoder().encode(surface)).arrangement), layout(arrangement))
    }

    /// Upward expansion keeps the bottom anchor and reserves the Mac strip on both surface sizes.
    func testExpandedBandFitsSurface() {
        for height: CGFloat in [300, 600, 1000] {
            let band = fretPadBandRect(in: CGSize(width: 1200, height: height))
            XCTAssertGreaterThanOrEqual(band.minY, TarafPluckStrip.height)
            XCTAssertLessThan(band.minY, height * 0.3)
            XCTAssertEqual(band.maxY, height * 0.8, accuracy: 1e-10)
            XCTAssertGreaterThan(band.height, height * 0.5)
            XCTAssertEqual(FretRow.row15.topY, 0)
            XCTAssertEqual(FretRow.row1.bottomY, 1)
        }
    }
}
