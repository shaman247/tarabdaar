import XCTest
@testable import TarabdaarCore

final class FretPositionTests: XCTestCase {
    /// Each row resolves its own endpoints and height, with continuous gap and column blends.
    func testFretRelativePositionField() {
        func fret(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> FretPlacement {
            FretPlacement(id: UUID().uuidString, segmentID: UUID(), isGhost: false,
                          ratio: 1, name: "", x: x, topY: top, bottomY: bottom)
        }
        let frets = [fret(10, 10, 40), fret(10, 60, 90), fret(30, 55, 75)]
        func position(_ x: CGFloat, _ y: CGFloat) -> Double {
            fretPosition(at: CGPoint(x: x, y: y), placements: frets, padHeight: 100)
        }
        for (y, expected): (CGFloat, Double) in [(-10, 1), (10, 1), (25, 0.5),
                (40, 0), (50, 0), (60, 0), (75, 0.5), (90, 1), (110, 1)] {
            XCTAssertEqual(position(10, y), expected, accuracy: 1e-12)
        }
        XCTAssertEqual(position(30, 55), 0)
        XCTAssertEqual(position(30, 65), 0.5)
        XCTAssertEqual(position(30, 75), 1)
        XCTAssertEqual(position(20, 75), 0.75)
        XCTAssertEqual(position(-100, 75), 0.5)
        XCTAssertEqual(position(100, 75), 1)
        XCTAssertEqual(position(20 - 1e-6, 75), position(20 + 1e-6, 75), accuracy: 1e-6)
        XCTAssertEqual(fretPosition(at: .zero, placements: [], padHeight: 100), 0)
        for (raw, word): (Double, UInt16) in [(-1, 0), (0, 0), (1, 65535), (2, 65535), (.nan, 0)] {
            XCTAssertEqual(TLPTouch.fretPositionWord(raw), word)
        }
    }
}
