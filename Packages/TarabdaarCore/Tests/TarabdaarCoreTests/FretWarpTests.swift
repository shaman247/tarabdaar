import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Selective fret warp preserves pitch continuity, snapping and one-way membership.
final class FretWarpTests: XCTestCase {

    /// The byte-null end of the knob: amount 0 leaves every position alone.
    func testWarpZeroIsIdentity() {
        for t in stride(from: -0.5, through: 1.5, by: 0.1) {
            XCTAssertEqual(fretWarp(t, amount: 0), t, accuracy: 1e-12)
        }
    }

    /// The arrangement carries raga membership, while the live warp amount stays out of the blob.
    func testArrangementBlobIsWarpFree() {
        let a = FretArrangement(
            segments: [FretSegment(degreeIndex: 2, x: 0.3, topY: 0.1,
                                   bottomY: 0.6)],
            ghostExtentOctaves: 0.75)
        let blob = FretArrangementSysEx.encodeBlob(a)
        XCTAssertEqual(blob[0], 3, "the first byte is the ghost extent in quarter octaves")
        XCTAssertEqual(blob.count,
                       3 + 7 * a.segments.count
                         + 2 * FretArrangement.droneCount,
                       "no version byte, no trailing warp byte")
        let decoded = FretArrangementSysEx.decodeBlob(blob)!
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.ghostExtentOctaves, 0.75)
    }
    /// One raga octave enables all fret copies through sync, leaving other pitches gray and snappable.
    func testRagaMembershipSyncAndLayoutIsolation() throws {
        let degrees = [(ratio: 1.0, label: "S"), (ratio: 1.5, label: "P")]
        let arrangement = FretArrangement(segments: [
            FretSegment(degreeIndex: 0, x: 0.2, topY: 0, bottomY: 1),
            FretSegment(degreeIndex: 1, x: 0.8, topY: 0, bottomY: 1)], ghostExtentOctaves: 2)
        let snapshot = arrangement.withRagaStrings(ratios: [0.5], degrees: degrees)
        let blob = FretArrangementSysEx.encodeBlob(snapshot)
        let decoded = try XCTUnwrap(FretArrangementSysEx.decodeBlob(blob))
        XCTAssertEqual(decoded.segments.map(\.ragaOctaves), [0x1F, 0])
        let placements = fretPlacements(arrangement: decoded, degrees: degrees,
                                        size: CGSize(width: 1000, height: 100))
        XCTAssertEqual(placements.filter(\.hasRagaString).map(\.ratio).sorted(), [0.25, 0.5, 1, 2, 4])
        let gray = try XCTUnwrap(placements.first { $0.ratio == 1.5 })
        XCTAssertEqual(fretSnap(at: CGPoint(x: gray.x + 2, y: 50), placements: placements,
                                snapDistance: 10)?.id, gray.id)
        let local = try JSONDecoder().decode(FretSegment.self,
            from: JSONEncoder().encode(snapshot.segments[0]))
        XCTAssertEqual(local.ragaOctaves, 0x1F, "layout files cannot overwrite instrument membership")
        var legacy = blob
        legacy.remove(at: 3 + 7 + 6)
        legacy.remove(at: 3 + 6)
        legacy[1] = 0
        XCTAssertEqual(FretArrangementSysEx.decodeBlob(legacy)?.segments.map(\.ragaOctaves),
                       [0x1F, 0x1F])
    }

    /// Gray frets stay linear and snappable while mixed horizontal and stacked fields stay continuous.
    func testSelectiveWarpAndContours() throws {
        func fret(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat,
                  _ ratio: Double, _ raga: Bool) -> FretPlacement {
            FretPlacement(id: UUID().uuidString, segmentID: UUID(), isGhost: false,
                          ratio: ratio, name: "", x: x, topY: top, bottomY: bottom,
                          hasRagaString: raga)
        }
        for (left, right) in [(true, true), (true, false), (false, true), (false, false)] {
            let horizontal = [fret(0, 0, 100, 1, left), fret(100, 0, 100, 2, right)]
            let stacked = [fret(0, 0, 10, 1, left), fret(0, 90, 100, 2, right)]
            var previous = -Double.infinity
            for n in 0...100 {
                let t = Double(n) / 100
                let x = try XCTUnwrap(fretFieldLog(at: CGPoint(x: t * 100, y: 50),
                                                  placements: horizontal, warp: 1))
                let y = try XCTUnwrap(fretFieldLog(at: CGPoint(x: 0, y: 10 + 80 * t),
                                                  placements: stacked, warp: 1))
                XCTAssertEqual(y, x, accuracy: 1e-12, "stacked and horizontal gaps obey the same law")
                if t == 0 || t == 0.5 || t == 1 || !(t < 0.5 ? left : right) {
                    XCTAssertEqual(x, t, accuracy: 1e-12, "gray regions and pitch anchors stay fixed")
                } else if t < 0.5 {
                    XCTAssertLessThan(x, t, "warp attracts the colored left fret")
                } else {
                    XCTAssertGreaterThan(x, t, "warp attracts the colored right fret")
                }
                XCTAssertGreaterThanOrEqual(x, previous)
                previous = x
                XCTAssertEqual(fretFieldLog(at: CGPoint(x: t * 100, y: 50),
                                            placements: horizontal, warp: 0)!, t, accuracy: 1e-12)
            }
        }
        let frets = [fret(0, 0, 20, 1, true), fret(0, 80, 100, 1.25, false),
                     fret(100, 0, 100, 2, true)]
        for y: CGFloat in [20, 50, 80] {
            for x: CGFloat in [0, 25, 50, 75, 100] {
                let before = fretFieldLog(at: CGPoint(x: x, y: y - 1e-7), placements: frets, warp: 1)!
                let after = fretFieldLog(at: CGPoint(x: x, y: y + 1e-7), placements: frets, warp: 1)!
                XCTAssertEqual(before, after, accuracy: 1e-7)
            }
        }
        let contours = fretFieldContours(placements: frets, size: CGSize(width: 100, height: 100), warp: 1)
        XCTAssertFalse(contours.isEmpty)
        for contour in contours {
            for point in contour.points {
                XCTAssertEqual(fretFieldLog(at: point, placements: frets, warp: 1)!,
                               contour.level, accuracy: 1e-9)
            }
        }
    }

}
