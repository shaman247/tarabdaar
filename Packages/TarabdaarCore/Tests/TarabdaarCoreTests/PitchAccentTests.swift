import XCTest
@testable import TarabdaarCore

/// The pitch accent follows the pad's frets, not the scale, and is null on every fret.
final class PitchAccentTests: XCTestCase {

    /// Frets on D, E, F♯ of a 12-tone scale: null on each fret in any octave,
    /// `1 − amount` midway (on the D♯ the scale holds but the pad does not),
    /// a disabled fret and an out-of-range degree count for nothing, amount 0
    /// is the identity.
    func testAccentIsNullOnFretsAndDipsAcrossUnfrettedDegrees() {
        let degrees = scaleDegrees(from: PitchScale.defaultJI)
        XCTAssertEqual(degrees.count, 12)
        let d = 2, e = 4, fs = 6, f = 5
        let arrangement = FretArrangement(segments: [
            FretSegment(degreeIndex: fs, x: 0.6, topY: 0.1, bottomY: 0.9),
            FretSegment(degreeIndex: d, x: 0.2, topY: 0.1, bottomY: 0.9),
            FretSegment(degreeIndex: e, x: 0.4, topY: 0.1, bottomY: 0.9),
            FretSegment(degreeIndex: f, x: 0.5, topY: 0.1, bottomY: 0.9,
                        enabled: false),
            FretSegment(degreeIndex: 40, x: 0.9, topY: 0.1, bottomY: 0.9),
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
