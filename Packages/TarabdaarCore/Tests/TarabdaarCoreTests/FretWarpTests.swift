import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret warp: 0 is the identity, and the warp stays out of the arrangement
/// blob (it is a live param, not layout state).
final class FretWarpTests: XCTestCase {

    /// The byte-null end of the knob: amount 0 leaves every position alone.
    func testWarpZeroIsIdentity() {
        for t in stride(from: -0.5, through: 1.5, by: 0.1) {
            XCTAssertEqual(fretWarp(t, amount: 0), t, accuracy: 1e-12)
        }
    }

    /// The blob is extent + flags + segments + drones and nothing else — no
    /// version byte of its own (TLP's is the version) and no trailing warp
    /// byte, which would break iPad compatibility.
    func testArrangementBlobIsWarpFree() {
        let a = FretArrangement(
            segments: [FretSegment(degreeIndex: 2, x: 0.3, topY: 0.1,
                                   bottomY: 0.6)],
            ghostExtentOctaves: 0.75)
        let blob = FretArrangementSysEx.encodeBlob(a)
        XCTAssertEqual(blob[0], 3, "the first byte is the ghost extent in quarter octaves")
        XCTAssertEqual(blob.count,
                       3 + 6 * a.segments.count
                         + 2 * FretArrangement.droneCount,
                       "no version byte, no trailing warp byte")
        let decoded = FretArrangementSysEx.decodeBlob(blob)!
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.ghostExtentOctaves, 0.75)
    }
}
