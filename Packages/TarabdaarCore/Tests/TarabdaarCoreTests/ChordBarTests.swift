import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Chord bar: Shepard chord construction and the selection codec round-trip.
final class ChordBarTests: XCTestCase {

    private func degs(_ pairs: [(Int, Int, String)])
        -> [(ratio: Double, label: String)] {
        pairs.map { (Double($0.0) / Double($0.1), $0.2) }
    }

    // MARK: - Shepard register law (2026-08-30)

    /// The I chord's construction: every tone lands its main copy in the
    /// octave below the tonic, Sa itself splits evenly across tonic/2 and
    /// the tonic (the wrap point), each tone's copies sum to unit weight
    /// (cos² + sin² across the octave spacing), and a sub-threshold flank
    /// is dropped (the fifth's two-octaves-down copy).
    func testShepardChordConstruction() {
        let notes = shepardChordNotes(rootRatio: 1.0,
                                      intervals: [1.0, 5.0 / 4.0, 3.0 / 2.0])
        XCTAssertEqual(notes.map(\.ratio), [0.5, 0.625, 0.75, 1.0, 1.25])
        func weight(at r: Double) -> Double {
            notes.first { abs($0.ratio - r) < 1e-9 }?.weight ?? 0
        }
        // Sa: the wrap point — equal halves an octave apart.
        XCTAssertEqual(weight(at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(weight(at: 1.0), 0.5, accuracy: 1e-9)
        // Third and root classes: complementary pairs summing to 1.
        XCTAssertEqual(weight(at: 0.625) + weight(at: 1.25), 1.0,
                       accuracy: 1e-9)
        // The fifth keeps only its main copy (flank weight ~0.018 < 0.02).
        XCTAssertGreaterThan(weight(at: 0.75), 0.98)
        XCTAssertEqual(weight(at: 0.375), 0)
        // A class at exactly the tritone is a single full-weight copy at
        // the window's center.
        let tritone = shepardChordNotes(rootRatio: pow(2.0, 0.5),
                                        intervals: [1.0])
        XCTAssertEqual(tritone.count, 1)
        XCTAssertEqual(tritone[0].ratio, pow(2.0, -0.5), accuracy: 1e-9)
        XCTAssertEqual(tritone[0].weight, 1.0, accuracy: 1e-9)
    }

    /// The wire carries the selection (TLP v12): codec roundtrip of the
    /// chord bytes, including a negative octave, and the none default.
    func testChordSelectionCodecRoundtrip() throws {
        var s = TLPPerfState(stateSeq: 7, timestampUs: 1,
                             tiltX: 0, tiltY: 0, tiltZ: 0,
                             droneMask: 0, touches: [])
        XCTAssertNil(s.chordSelection)
        s.chordDegree = 4
        s.chordOctave = UInt8(bitPattern: Int8(-1))
        guard case .perfState(let back)? =
            TLPFrame.decode(TLPFrame.perfState(s).encode()) else {
            return XCTFail("perfState did not roundtrip")
        }
        XCTAssertEqual(back.chordSelection,
                       ChordSelection(degree: 4, octave: -1))
        s.chordDegree = TLPPerfState.chordNone
        guard case .perfState(let none)? =
            TLPFrame.decode(TLPFrame.perfState(s).encode()) else {
            return XCTFail("perfState did not roundtrip")
        }
        XCTAssertNil(none.chordSelection)
    }
}
