import XCTest
import SarangiKit
@testable import TarabdaarCore

/// SCALE-DEFINED TARAB (2026-07-25): `StringSpec` stores pitch as a scale
/// DEGREE + OCTAVE into `InstrumentState.scaleRatios` — the one centralized
/// scale — and absolute Hz is minted only at resolve time, on a millihertz
/// grid. These tests pin the resolution law, the transpose semantics, and
/// the out-of-range clamping. (The fitted-Hz Pilu table and the free-ratio
/// model it required were retired with this change — a degree cannot be a
/// few cents off itself, so there is no fitted-table bit-exactness to pin
/// any more; `TarafRemovalParityTests` hashes the generated default's
/// render instead.)
final class TarabRatioTests: XCTestCase {

    /// Resolution is tonic × degreeRatio × 2^octave on the millihertz grid
    /// — deterministic to the bit, which the drone press path (identity
    /// lookup on nominal Hz) depends on.
    func testResolutionLaw() {
        let scale = RagaTuning.ratios(forIntervals: RagaTuning.raga(id: 3).intervals)
        for tonic in [161.3, 328.9, 440.0] {
            for d in scale.indices {
                for oct in -2...2 {
                    let s = StringSpec(degree: d, octave: oct, gain: 1, t60: 5)
                    let want = (scale[d] * pow(2.0, Double(oct)) * tonic * 1000).rounded() / 1000
                    XCTAssertEqual(s.resolved(tonic: tonic, scaleRatios: scale).freq, want)
                }
            }
        }
    }

    /// Moving the tonic IS the transpose: degrees stand, every string
    /// scales. Resolved pitches land on the millihertz grid, so the
    /// transposed value is the scaled one to within a millihertz.
    func testTransposeKeepsDegrees() {
        var state = Presets.state(.sarangiPilu)
        let degrees = state.strings.map(\.degree)
        let before = state.resolvedStrings.map(\.freq)
        state.tonicHz *= 1.5
        XCTAssertEqual(state.strings.map(\.degree), degrees)
        for (a, b) in zip(state.resolvedStrings.map(\.freq), before) {
            XCTAssertEqual(a, b * 1.5, accuracy: 1e-3)
        }
    }

    /// Retuning a scale DEGREE retunes every string that references it —
    /// the centralization in one assertion.
    func testScaleEditRetunesReferencingStrings() {
        var state = Presets.state(.sarangiPilu)
        let d = 2
        let affected = state.strings.indices.filter { state.strings[$0].degree == d }
        XCTAssertFalse(affected.isEmpty)
        var ratios = state.scaleRatios
        ratios[d] *= 1.01
        state.updateScale(tonicHz: state.tonicHz, ratios: ratios)
        for i in affected {
            let s = state.strings[i]
            let want = (ratios[d] * pow(2.0, Double(s.octave)) * state.tonicHz * 1000)
                .rounded() / 1000
            XCTAssertEqual(state.resolvedStrings[i].freq, want)
        }
    }

    /// A degree past the end of a SHRUNK scale clamps to the top degree —
    /// the row keeps sounding rather than crashing or going silent; it
    /// resolves correctly again if the scale grows back.
    func testOutOfRangeDegreeClamps() {
        let scale = [1.0, 9.0 / 8, 3.0 / 2]
        let s = StringSpec(degree: 7, octave: 0, gain: 1, t60: 5)
        XCTAssertEqual(s.ratio(in: scale), 1.5)
        XCTAssertEqual(StringSpec(degree: -1, octave: 0, gain: 1, t60: 5).ratio(in: scale), 1.0)
        XCTAssertEqual(s.ratio(in: []), 1.0)      // empty scale: octave-only
    }

    /// `updateScale` retunes WITHOUT touching the row layout;
    /// `regenerateFromScale` rebuilds the rows too (fresh ids, remapped
    /// drones). The auto-sync toggle is exactly this distinction.
    func testUpdateVersusRegenerate() {
        var a = Presets.state(.sarangiPilu)
        let ids = a.strings.map(\.id)
        // Same degree COUNT as Pilu (9) — the app only calls updateScale
        // when the count matches (a count change regenerates instead), and
        // clamped duplicate pitches would otherwise fold.
        let retuned = a.scaleRatios.map { $0 * 1.003 }
        a.updateScale(tonicHz: 300, ratios: retuned)
        XCTAssertEqual(a.strings.map(\.id), ids, "updateScale must not touch rows")
        XCTAssertEqual(a.scaleRatios, retuned)
        XCTAssertEqual(a.tonicHz, 300)

        var b = Presets.state(.sarangiPilu)
        let newScale = [1.0, 9.0 / 8, 5.0 / 4, 4.0 / 3, 3.0 / 2, 5.0 / 3, 15.0 / 8]
        b.regenerateFromScale(tonicHz: 300, ratios: newScale)
        XCTAssertEqual(b.strings.count,
                       RagaTuning.buildSpecs(scaleRatios: newScale).count)
        XCTAssertTrue(Set(b.strings.map(\.id)).isDisjoint(with: Set(ids)))
        XCTAssertEqual(b.droneStringIds,
                       InstrumentState.autoDroneMapping(strings: b.strings,
                                                        scaleRatios: newScale))
    }

    // MARK: - The pool invariant (2026-07-26): sorted by pitch, no
    // duplicate pitches, ever.

    /// The generated default bank is pitch-sorted and one-string-per-pitch
    /// (the historic Sa/Pa doubling rows fold into their strongest twin).
    func testDefaultBankIsSortedAndDuplicateFree() {
        let state = Presets.state(.sarangiPilu)
        let ratios = state.strings.map { $0.ratio(in: state.scaleRatios) }
        XCTAssertEqual(ratios, ratios.sorted(), "bank not sorted by pitch")
        XCTAssertEqual(Set(ratios).count, ratios.count, "duplicate pitches")
        // The fold kept the doubling rows' emphasis: Sa carries the
        // doubling's 0.95/7.0, not the plain mid row's 0.85/5.0.
        let sa = state.strings.first { $0.degree == 0 && $0.octave == 0 }!
        XCTAssertEqual(sa.gain, 0.95)
        XCTAssertEqual(sa.t60, 7.0)
    }

    /// A doubling-era document (duplicate rows) folds on decode: the
    /// strongest twin survives, the pool comes out sorted, and a drone
    /// button mapped to a DROPPED twin is re-pointed at the survivor.
    func testDecodeFoldsDuplicatesAndRemapsDrones() throws {
        var state = Presets.state(.sarangiPilu)
        // re-create the doubling era: a weak twin of low Sa, mapped by
        // drone slot 0, inserted out of order
        let weakTwin = StringSpec(degree: 0, octave: -1, gain: 0.80, t60: 7.0)
        let survivor = state.strings.first { $0.degree == 0 && $0.octave == -1 }!
        state.strings.insert(weakTwin, at: 0)
        state.droneStringIds[0] = weakTwin.id
        let decoded = try JSONDecoder().decode(
            InstrumentState.self, from: JSONEncoder().encode(state))
        let ratios = decoded.strings.map { $0.ratio(in: decoded.scaleRatios) }
        XCTAssertEqual(ratios, ratios.sorted())
        XCTAssertEqual(Set(ratios).count, ratios.count)
        XCTAssertFalse(decoded.strings.contains { $0.id == weakTwin.id },
                       "the weaker twin must fold away")
        XCTAssertEqual(decoded.droneStringIds[0], survivor.id,
                       "a drone mapped to the dropped twin must follow the survivor")
    }

    /// `normalizeStrings(preferring:)` lets the EDITED row win a fold even
    /// against a stronger twin (the store's edit semantics).
    func testNormalizePreferredRowWins() {
        var state = Presets.state(.sarangiPilu)
        let weak = StringSpec(degree: 0, octave: -1, gain: 0.1, t60: 1.0)
        state.strings.append(weak)
        state.normalizeStrings(preferring: weak.id)
        let atPitch = state.strings.filter { $0.degree == 0 && $0.octave == -1 }
        XCTAssertEqual(atPitch.map(\.id), [weak.id])
    }
}
