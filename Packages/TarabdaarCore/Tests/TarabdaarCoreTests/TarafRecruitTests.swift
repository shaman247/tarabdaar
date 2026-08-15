import XCTest
import SarangiKit
@testable import TarabdaarCore

/// TARAF RECRUITMENT PROFILE (`bow_jt_sel`, 2026-07-26; PROFILE rework
/// 2026-08-01 — the first bipolar axis' top half was a pure uniform
/// boost, so the knob read as a taraf VOLUME; an interim monotone
/// "breadth" cut topped out at the fitted response, which is still
/// note-dependent). The axis now sweeps each row's CONTRIBUTION to the
/// taraf at held loudness: 0 = kin-only (unison, faint octaves, fainter
/// fifth — the kin score squared at the endpoint), 0.5 = the fitted
/// natural resonance profile (bit-exact), 1 = every row contributing
/// EQUALLY — resonant rows cut to the common haze level and the whole
/// response (contributions AND level) independent of the played note.
/// The radiated jt gain holds the loudness throughout: below 0.5 at the
/// note's own fitted power, above 0.5 blending to the fixed common
/// level (rows·haze + `recruitKinNominal`), cap ×`bow_jt_sel_comp`.
/// Chords combine as a soft-OR — gentler than a max, still bounded.
///
/// The math half pins `BowEngine.recruitWeight` / `recruitGainMul` (the
/// exact formulas the render thread pushes into the kernel); the render
/// half proves the profile audibly moves both ways off the fitted
/// midpoint while the loudness holds where physics allows it.
final class TarafRecruitTests: XCTestCase {

    // MARK: - Weight math

    func testFittedMidpointIsIdentity() {
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

    /// The flat half INVERTS the ordering: at 1 a unison row is cut to
    /// √(haze/(haze+1)) ≈ 0.22 while a non-kin row keeps its full drive
    /// — every row levels at the common haze contribution.
    func testFlatEndCutsResonantRowsToTheCommonLevel() {
        let p = 300.0
        let unison = BowEngine.recruitWeight(rowHz: p, playedHz: [p],
                                             selectivity: 1.0)
        let octave = BowEngine.recruitWeight(rowHz: 2.0 * p, playedHz: [p],
                                             selectivity: 1.0)
        let unrelated = BowEngine.recruitWeight(
            rowHz: p * pow(2.0, 590.0 / 1200.0), playedHz: [p],
            selectivity: 1.0)
        XCTAssertEqual(unison, (0.05 / 1.05).squareRoot(), accuracy: 1e-9)
        // (1e-3 slack: the 590 c row keeps a ~1e-5 kin from the
        // corridor's Gaussian tail off the fourth)
        XCTAssertEqual(unrelated, 1.0, accuracy: 1e-3)
        XCTAssertGreaterThan(octave, unison)
        XCTAssertLessThan(octave, unrelated)
        // the modeled CONTRIBUTIONS w²·(haze+kin²) are equal
        func contrib(_ w: Double, _ kin2: Double) -> Double {
            w * w * (0.05 + kin2)
        }
        XCTAssertEqual(contrib(unison, 1.0), contrib(unrelated, 0.0),
                       accuracy: 1e-4)
        // half-throw = halfway to the flat cut
        let mid = BowEngine.recruitWeight(rowHz: p, playedHz: [p],
                                          selectivity: 0.75)
        XCTAssertEqual(mid, 0.5 * (1.0 + unison), accuracy: 1e-9)
    }

    // MARK: - Loudness-compensation math

    /// A JI-ish bank against its tonic — kin and non-kin rows mixed.
    private let bank = [300.0, 320.0, 337.5, 360.0, 400.0, 450.0,
                        480.0, 506.25, 540.0, 600.0, 675.0, 900.0]

    func testCompensationIsIdentityAtTheFittedMidpoint() {
        XCTAssertEqual(BowEngine.recruitGainMul(rowsHz: bank,
                                                playedHz: [300.0],
                                                selectivity: 0.5),
                       1.0, accuracy: 1e-12)
    }

    /// Away from the midpoint the gain only ever rises (never ducks),
    /// grows monotonically toward both ends, and stays under the cap.
    func testCompensationRisesMonotonicallyTowardBothEnds() {
        for dir in [-1.0, 1.0] {
            var last = 1.0
            for step in 1...5 {
                let s = 0.5 + dir * 0.1 * Double(step)
                let g = BowEngine.recruitGainMul(rowsHz: bank,
                                                 playedHz: [300.0],
                                                 selectivity: s)
                XCTAssertGreaterThanOrEqual(g, last - 1e-9,
                    "gain fell moving away from fitted (s=\(s))")
                XCTAssertLessThanOrEqual(g, 4.0)
                last = g
            }
            XCTAssertGreaterThan(last, 1.1,
                "both extremes should need a real lift to hold the level")
        }
    }

    /// When the gain is under the cap the selective half restores the
    /// model's fitted power exactly: Σ (g·w·a)² == Σ a², a² = haze+kin².
    func testSelectiveCompensationRestoresTheModelPower() {
        let played = [300.0]
        let s = 0.3
        let g = BowEngine.recruitGainMul(rowsHz: bank, playedHz: played,
                                         selectivity: s)
        XCTAssertLessThan(g, 4.0, "capped — pick a kin-heavier scenario")
        var pFit = 0.0, pNow = 0.0
        for r in bank {
            let w = BowEngine.recruitWeight(rowHz: r, playedHz: played,
                                            selectivity: s)
            let kin2 = (w - s * 2.0) / (1.0 - s * 2.0)
            pFit += 0.05 + kin2
            pNow += w * w * (0.05 + kin2)
        }
        XCTAssertEqual(g * g * pNow, pFit, accuracy: 1e-6 * pFit)
    }

    /// The flat end is NOTE-INDEPENDENT by construction: the same bank
    /// gets the same gain (and the same modeled power) whether the
    /// played note is its tonic or kin to nothing in it.
    func testFlatEndGainIsTheSameForKinAndNonKinNotes() {
        let nonKin = [300.0 * pow(2.0, 590.0 / 1200.0)]
        let gKin = BowEngine.recruitGainMul(rowsHz: bank, playedHz: [300.0],
                                            selectivity: 1.0)
        let gNon = BowEngine.recruitGainMul(rowsHz: bank, playedHz: nonKin,
                                            selectivity: 1.0)
        XCTAssertEqual(gKin, gNon, accuracy: 1e-6)
        // and it equals the fixed common-level lift √(ref/rows·haze)
        let n = Double(bank.count)
        let expected = ((n * 0.05 + 1.75) / (n * 0.05)).squareRoot()
        XCTAssertEqual(gKin, min(expected, 4.0), accuracy: 1e-6)
    }

    /// A note kin to NOTHING in the bank: kin-only leaves almost
    /// nothing, so the selective end rides the cap — but engages
    /// SMOOTHLY (the haze floor keeps the gain near 1 just off fitted).
    func testCompensationCapsOnANonKinNoteButEngagesSmoothly() {
        let nonKin = [300.0 * pow(2.0, 590.0 / 1200.0)]
        let g = BowEngine.recruitGainMul(rowsHz: bank, playedHz: nonKin,
                                         selectivity: 0.0)
        XCTAssertEqual(g, 4.0, accuracy: 1e-9)
        let gNear = BowEngine.recruitGainMul(rowsHz: bank, playedHz: nonKin,
                                             selectivity: 0.45)
        XCTAssertLessThan(gNear, 1.2,
            "just off fitted the lift must be gentle (measured ~1.11),"
            + " not the cap jump the floor-less model produced")
    }

    // MARK: - Render (profile moves, loudness holds)

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

    /// Post-release taraf tail RMS for one played note at one profile.
    private func tarafTail(sel: Double, midi: UInt8) throws -> Double {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper)
        else { throw XCTSkip("bowed_string.json not available") }
        src.setEngine(e, crossfadeMs: 0)
        src.setTarafSelectivity(sel)
        src.mapper.midi(0xB0, 11, 64)
        src.mapper.midi(0x90, midi, 100)
        _ = pull(src, 12)                    // bow ~1 s, charge the taraf
        src.mapper.midi(0x80, midi, 0)
        _ = pull(src, 8)                     // played-string ring dies
        return rms(pull(src, 2))             // taraf-dominated tail
    }

    /// On a KIN note (E5 — the tonic's octave, dead-center of the
    /// bank's strongest rows) the tail must stay within a workable band
    /// across the whole throw: kin-only narrows and the flat end
    /// re-profiles, but the compensation keeps the level near fitted.
    func testLoudnessHoldsAcrossTheThrowOnAKinNote() throws {
        let narrow = try tarafTail(sel: 0.0, midi: 76)
        let fitted = try tarafTail(sel: 0.5, midi: 76)
        let flat = try tarafTail(sel: 1.0, midi: 76)
        print("  kin-note taraf tail RMS: narrow \(narrow)"
              + "  fitted \(fitted)  flat \(flat)")
        XCTAssertGreaterThan(fitted, 0, "no taraf ring at all — bad rig")
        for (name, v) in [("narrow", narrow), ("flat", flat)] {
            XCTAssertGreaterThan(v, 0.4 * fitted,
                "\(name) profile lost the taraf's loudness (>8 dB down)")
            XCTAssertLessThan(v, 2.5 * fitted,
                "\(name) profile pumped the taraf (>8 dB up)")
        }
    }

    /// On a NON-kin note (A#4, ~604 c above the E tonic — ~100 c from
    /// the nearest kin interval of most rows): the selective end still
    /// audibly thins the chorus (physics leaves only haze to boost —
    /// the ×4 cap keeps it honest, but well above the ~×4-lower
    /// uncompensated strip), and the flat end must NOT collapse — for a
    /// non-kin note the fitted profile is already nearly flat, so the
    /// tail holds (the fixed common level lifts it if anything).
    func testNonKinNoteNarrowsSelectivelyButHoldsFlat() throws {
        let narrow = try tarafTail(sel: 0.0, midi: 70)
        let fitted = try tarafTail(sel: 0.5, midi: 70)
        let flat = try tarafTail(sel: 1.0, midi: 70)
        print("  non-kin taraf tail RMS: narrow \(narrow)"
              + "  fitted \(fitted)  flat \(flat)")
        XCTAssertGreaterThan(fitted, 0, "no taraf ring at all — bad rig")
        XCTAssertLessThan(narrow, 0.5 * fitted,
            "kin-only should still thin a non-kin note's chorus")
        XCTAssertGreaterThan(narrow, 0.1 * fitted,
            "compensation should lift the kin strip well above the"
            + " uncompensated level")
        XCTAssertGreaterThan(flat, 0.7 * fitted,
            "the flat end must keep a non-kin note's chorus ringing")
    }
}
