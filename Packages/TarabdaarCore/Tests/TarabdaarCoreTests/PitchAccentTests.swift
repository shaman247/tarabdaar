import Combine
import XCTest
@testable import TarabdaarCore

/// The pitch accent follows the pad's frets, not the scale, and is null on every fret.
final class PitchAccentTests: XCTestCase {

    /// One edit immediately updates the accent grid, including the final fractional tonic.
    func testPublishedGridUsesIncomingArrangementAndTuning() throws {
        final class Layout: ObservableObject {
            @Published var arrangement = FretArrangement(segments: [
                FretSegment(degreeIndex: 0, row: .row5),
            ])
        }
        let tuning = Tuning()
        tuning.scale = .defaultJI
        let layout = Layout()
        var latest: FretPitchGrid?
        let subscription = FretPitchGrid.publisher(tuning: tuning, arrangement: layout.$arrangement)
            .sink { latest = $0 }
        defer { subscription.cancel() }

        layout.arrangement = FretArrangement(segments: [
            FretSegment(degreeIndex: 7, row: .row5),
        ])
        XCTAssertEqual(try XCTUnwrap(latest).degrees, [log2(1.5)])

        tuning.setTonic(fractionalMidi: 67.23)
        let moved = try XCTUnwrap(latest)
        XCTAssertEqual(moved.tonicSemis, 67.23, accuracy: 1e-12)
        let pitch = 67.23 + 12 * log2(1.5)
        XCTAssertEqual(moved.exprScale(atSemis: pitch, amount: 1), 1, accuracy: 1e-12)

        tuning.scale = PitchScale(points: [PitchPoint(num: 1, den: 1, y: 0.5)])
        XCTAssertTrue(try XCTUnwrap(latest).degrees.isEmpty,
                      "a removed degree cannot remain an accent target")
        XCTAssertEqual(try XCTUnwrap(latest).exprScale(atSemis: pitch + 3, amount: 1), 1)
    }

    /// Accent is null on frets, ignores missing degrees and dips across unfretted pitches.
    func testAccentIsNullOnFretsAndDipsAcrossUnfrettedDegrees() {
        let degrees = scaleDegrees(from: PitchScale.defaultJI)
        XCTAssertEqual(degrees.count, 12)
        let d = 2, e = 4, fs = 6, f = 5
        let arrangement = FretArrangement(segments: [
            FretSegment(degreeIndex: fs, row: .row5),
            FretSegment(degreeIndex: d, row: .row5),
            FretSegment(degreeIndex: e, row: .row5),
            FretSegment(degreeIndex: 40, row: .row5),
        ])
        let grid = FretPitchGrid(tonicHz: 261.63, arrangement: arrangement,
                                 degrees: degrees)
        XCTAssertEqual(grid.degrees.count, 3)
        let tonic = grid.tonicSemis
        func semis(_ degree: Int, octave: Double = 0) -> Double {
            tonic + 12.0 * (log2(degrees[degree].ratio) + octave)
        }
        for octave in [-2.0, 0.0, 1.0] {
            for fret in [d, e, fs] {
                XCTAssertEqual(grid.exprScale(atSemis: semis(fret, octave: octave),
                                              amount: 1.0),
                               1.0, accuracy: 1e-9, "on a fret is as played")
            }
        }
        // the unfretted degrees sit inside their gaps: D♯ and F dip
        let dSharp = (semis(d) + semis(e)) / 2.0
        XCTAssertEqual(grid.exprScale(atSemis: dSharp, amount: 0.4), 0.6,
                       accuracy: 1e-9)
        XCTAssertGreaterThan(grid.betweenness(atSemis: semis(f)), 0.9)
        XCTAssertEqual(grid.exprScale(atSemis: dSharp, amount: 0.0), 1.0)
        // the wrap gap F♯ → D′ is one gap too: its midpoint is the full dip
        let wrapMid = (semis(fs) + semis(d, octave: 1)) / 2.0
        XCTAssertEqual(grid.betweenness(atSemis: wrapMid), 1.0, accuracy: 1e-9)
    }
}
