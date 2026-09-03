import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret warp 0 is the identity and stays out of the arrangement blob.
final class FretWarpTests: XCTestCase {

    // MARK: - The warp law

    func testWarpZeroIsIdentity() {
        for t in stride(from: -0.5, through: 1.5, by: 0.1) {
            XCTAssertEqual(fretWarp(t, amount: 0), t, accuracy: 1e-12)
        }
    }

    // MARK: - The field

    /// Two plain columns an octave apart, full-height, 100 px apart.
    private func twoColumns() -> [FretPlacement] {
        [placement("S", ratio: 1.0, x: 100),
         placement("S'", ratio: 2.0, x: 200)]
    }

    private func placement(_ name: String, ratio: Double, x: CGFloat,
                           topY: CGFloat = 0, bottomY: CGFloat = 100)
        -> FretPlacement {
        FretPlacement(id: name, segmentID: UUID(), isGhost: false,
                      ratio: ratio, name: name, x: x, topY: topY,
                      bottomY: bottomY)
    }

    // MARK: - Contours

    // MARK: - The parameter + the wire relay

    /// The arrangement blob deliberately does NOT carry the warp any more
    /// (it is a live param, not layout state) — the codec is back to the
    /// v6 shape: segments + extent + drones round-trip, nothing else.
    func testArrangementBlobIsWarpFree() {
        let a = FretArrangement(
            segments: [FretSegment(degreeIndex: 2, x: 0.3, topY: 0.1,
                                   bottomY: 0.6)],
            ghostExtentOctaves: 0.75)
        let blob = FretArrangementSysEx.encodeBlob(a)
        XCTAssertEqual(blob[0], 6, "blob version is v6 again")
        XCTAssertEqual(blob.count,
                       4 + 6 * a.segments.count
                         + 2 * FretArrangement.droneCount,
                       "no trailing warp byte")
        let decoded = FretArrangementSysEx.decodeBlob(blob)!
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.ghostExtentOctaves, 0.75)
    }
}
