import XCTest
import SarangiKit
@testable import StarpadCore

/// TARAF RECRUITMENT (`bow_jt_sel`, 2026-07-26; BIPOLAR rework the same
/// day). The axis is centred on the fitted sound: 0.5 = every row hears
/// the fitted bridge force; below, rows lose drive by harmonic distance
/// from the played pitches (0 = kin-only — unison, faint octaves,
/// fainter fifth, the kin score squared at the endpoint); above, every
/// row is driven harder (1 = ×`bow_jt_sel_lush` [2] — the graze
/// nonlinearity turns extra drive into cascade, the lush full chorus).
/// Chords combine as a soft-OR on the selective half — gentler than a
/// max, still bounded.
///
/// The math half pins `BowEngine.recruitWeight` (the exact formula the
/// render thread pushes into the kernel); the render half proves BOTH
/// ends audibly move the taraf away from the fitted midpoint.
final class TarafRecruitTests: XCTestCase {

    // MARK: - Weight math

    func testNeutralMidpointIsIdentity() {
        for row in [100.0, 328.9, 700.0, 1234.5] {
            XCTAssertEqual(BowEngine.recruitWeight(rowHz: row,
                                                   playedHz: [261.6],
                                                   selectivity: 0.5),
                           1.0, accuracy: 1e-12)
        }
    }

    func testKinOrderingUnisonOctaveFifthUnrelated() {
        let p = 300.0
        func w(_ ratio: Double) -> Double {
            BowEngine.recruitWeight(rowHz: p * ratio, playedHz: [p],
                                    selectivity: 0.0)
        }
        let unison = w(1.0)
        let octave = w(2.0)
        let fifth = w(1.5)
        // 590 c — at least ~90 c from every kin interval (the fourth at
        // 498 c and the fifth at 702 c are the nearest)
        let unrelated = w(pow(2.0, 590.0 / 1200.0))
        XCTAssertEqual(unison, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(octave, fifth)
        XCTAssertGreaterThan(fifth, 0.02)
        XCTAssertLessThan(octave, 0.6,
                          "octaves should be clearly FAINTER than the unison")
        XCTAssertLessThan(fifth, 0.15, "the fifth family should be faint")
        XCTAssertLessThan(unrelated, 0.01, "a non-kin row must lose its drive")
    }

    func testNearMissWithinTheCentsCorridorStillRecruits() {
        // A 12-TET fifth against a JI row: 2 c off the 3/2 — the width
        // (default 30 c) must carry it at nearly full kin strength.
        let p = 300.0
        let exact = BowEngine.recruitWeight(rowHz: p * 1.5, playedHz: [p],
                                            selectivity: 0.0)
        let tempered = BowEngine.recruitWeight(
            rowHz: p * pow(2.0, 700.0 / 1200.0), playedHz: [p],
            selectivity: 0.0)
        XCTAssertEqual(tempered, exact, accuracy: 0.02)
    }

    /// Chords combine as a soft-OR on the kin score (misses multiply,
    /// then the endpoint squaring): more than either note alone, bounded
    /// at 1.
    func testChordRecruitsAdditivelyButBounded() {
        let row = 300.0
        // row is the lower octave of 600 and the lower twelfth of 900
        let a1 = BowEngine.recruitWeight(rowHz: row, playedHz: [600.0],
                                         selectivity: 0.0)
        let a2 = BowEngine.recruitWeight(rowHz: row, playedHz: [900.0],
                                         selectivity: 0.0)
        let both = BowEngine.recruitWeight(rowHz: row,
                                           playedHz: [600.0, 900.0],
                                           selectivity: 0.0)
        XCTAssertGreaterThan(both, max(a1, a2))
        XCTAssertLessThanOrEqual(both, 1.0)
        // exact soft-OR: singles are kin², so undo the square to compose
        let expected = pow(1.0 - (1.0 - a1.squareRoot())
                               * (1.0 - a2.squareRoot()), 2.0)
        XCTAssertEqual(both, expected, accuracy: 1e-9)
        // eight unison-kin notes still cannot push past the bound
        let pile = BowEngine.recruitWeight(
            rowHz: row, playedHz: [Double](repeating: 300.0, count: 8),
            selectivity: 0.0)
        XCTAssertLessThanOrEqual(pile, 1.0)
    }

    /// The selective half lerps the weight from the squared kin score
    /// (at 0) to 1 (at 0.5): quarter-throw = halfway.
    func testSelectiveHalfInterpolatesLinearly() {
        let row = 300.0 * pow(2.0, 590.0 / 1200.0)
        let full = BowEngine.recruitWeight(rowHz: row, playedHz: [300.0],
                                           selectivity: 0.0)
        let half = BowEngine.recruitWeight(rowHz: row, playedHz: [300.0],
                                           selectivity: 0.25)
        XCTAssertEqual(half, 0.5 * (1.0 + full), accuracy: 1e-9)
    }

    /// The lush half is a uniform pitch-independent boost: 1 → ×lush,
    /// 0.75 → halfway, for kin and non-kin rows alike.
    func testLushHalfBoostsEveryRowUniformly() {
        for row in [300.0, 450.0, 300.0 * pow(2.0, 590.0 / 1200.0)] {
            XCTAssertEqual(BowEngine.recruitWeight(rowHz: row,
                                                   playedHz: [300.0],
                                                   selectivity: 1.0),
                           2.0, accuracy: 1e-12)
            XCTAssertEqual(BowEngine.recruitWeight(rowHz: row,
                                                   playedHz: [300.0],
                                                   selectivity: 0.75),
                           1.5, accuracy: 1e-12)
            XCTAssertEqual(BowEngine.recruitWeight(rowHz: row,
                                                   playedHz: [],
                                                   selectivity: 1.0,
                                                   lush: 3.0),
                           3.0, accuracy: 1e-12)
        }
    }

    // MARK: - Render (both ends reach the sound)

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    private func rms(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                         / Double(x.count)).squareRoot()
    }

    private func pull(_ src: StringVoiceSource, _ blocks: Int) -> [Double] {
        var out: [Double] = []
        for _ in 0..<blocks {
            let (l, r) = src.renderForTesting(frames: 4096)
            out.append(contentsOf: (0..<4096).map {
                Double(l[$0]) + Double(r[$0])
            })
        }
        return out
    }

    private func tarafTail(sel: Double) throws -> Double {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper)
        else { throw XCTSkip("bowed_string.json not available") }
        src.setEngine(e, crossfadeMs: 0)
        src.setTarafSelectivity(sel)
        src.mapper.midi(0xB0, 11, 64)
        // A#4 — ~604 c above the E tonic, ~100 c from the nearest kin
        // interval of most rows, so the selective end recruits little
        src.mapper.midi(0x90, 70, 100)
        _ = pull(src, 12)                    // bow ~1 s, charge the taraf
        src.mapper.midi(0x80, 70, 0)
        _ = pull(src, 8)                     // played-string ring dies
        return rms(pull(src, 2))             // taraf-dominated tail
    }

    /// The kin-only end must strip the chorus, the lush end must swell
    /// it — both relative to the fitted midpoint.
    func testRecruitmentMovesTheTarafRingBothWays() throws {
        let fitted = try tarafTail(sel: 0.5)
        let selective = try tarafTail(sel: 0.0)
        let lush = try tarafTail(sel: 1.0)
        print("  taraf tail RMS: selective \(selective)  fitted \(fitted)"
              + "  lush \(lush)")
        XCTAssertGreaterThan(fitted, 0, "no taraf ring at all — bad rig")
        XCTAssertLessThan(selective, 0.5 * fitted,
                          "sel 0 should strip most of the taraf chorus")
        XCTAssertGreaterThan(lush, 1.3 * fitted,
                             "sel 1 should swell the chorus well past fitted")
    }
}
