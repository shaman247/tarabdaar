import XCTest
@testable import TarabdaarCore

/// ONE NAMING (2026-07-25): every pitch the app shows is named by the CURRENT
/// SCALE's own labels — the fixed 12-tone sargam table that used to name the
/// frets and the drone buttons is gone, so a pitch can never be called two
/// things at once. (The default scale then took sargam names of its own, so
/// the pad still reads `S r R g …` — but now because the SCALE says so, and
/// renaming a degree in the editor renames it everywhere.) These tests pin
/// that the labels come from the scale, that octave repeats get `'`/`,`
/// marks, and that a ratio just under the octave names itself from the tonic
/// above rather than from the topmost degree.
final class ScaleLabelTests: XCTestCase {

    private let defaultDegrees = scaleDegrees(from: PitchScale.defaultJI)

    /// The default scale is sargam, low→high, and matches the bundled
    /// `Default.json` that actually loads.
    func testDefaultScaleIsSargam() {
        XCTAssertEqual(defaultDegrees.map(\.label),
                       ["S", "r", "R", "g", "G", "m", "M", "P", "d", "D", "n", "N"])
    }

    /// The fret labels ARE the scale's labels, in scale order.
    func testFretNamesComeFromTheScale() {
        let arrangement = FretArrangement.defaultArrangement(degrees: defaultDegrees)
        let placements = fretPlacements(arrangement: arrangement,
                                        degrees: defaultDegrees,
                                        size: CGSize(width: 1000, height: 400))
        let base = placements.filter { !$0.isGhost }
            .sorted { $0.ratio < $1.ratio }.map(\.name)
        XCTAssertEqual(base, defaultDegrees.map(\.label))
    }

    /// Octave-repeat frets keep the degree's label and add the octave mark.
    func testGhostFretsCarryOctaveMarks() {
        let degrees = defaultDegrees
        let arrangement = FretArrangement(
            segments: [FretSegment(degreeIndex: 0, x: 0.5, topY: 0.4, bottomY: 0.6)],
            ghostExtentOctaves: 1.0)
        let placements = fretPlacements(arrangement: arrangement, degrees: degrees,
                                        size: CGSize(width: 1000, height: 400))
        XCTAssertEqual(Set(placements.map(\.name)), ["S,", "S", "S'"])
    }

    /// A ratio-only pitch (the drone buttons) resolves to the nearest degree
    /// in ANY octave — `,Sa` and `,Pa` under the default scale.
    func testRatioLabelsUseTheScaleAndTheNearestOctave() {
        XCTAssertEqual(scaleLabel(forRatio: 1.0, degrees: defaultDegrees), "S")
        XCTAssertEqual(scaleLabel(forRatio: 0.5, degrees: defaultDegrees), "S,")
        XCTAssertEqual(scaleLabel(forRatio: 0.75, degrees: defaultDegrees), "P,")
        XCTAssertEqual(scaleLabel(forRatio: 2.5, degrees: defaultDegrees), "G'")
        // 1.99 is 9 ¢ under the octave and 63 ¢ over N — the octave wins.
        XCTAssertEqual(scaleLabel(forRatio: 1.99, degrees: defaultDegrees), "S'")
    }

    /// A custom scale renames everything, frets and drones alike — nothing
    /// falls back to a fixed vocabulary.
    func testCustomLabelsWinEverywhere() {
        let scale = PitchScale(points: [
            PitchPoint(num: 1, den: 1, y: 0.5, label: "do"),
            PitchPoint(num: 3, den: 2, y: 0.5, label: "sol"),
            PitchPoint(num: 5, den: 4, y: 0.5, label: ""),   // blank → ratio
        ])
        let degrees = scaleDegrees(from: scale)
        XCTAssertEqual(degrees.map(\.label), ["do", "5/4", "sol"])
        XCTAssertEqual(scaleLabel(degree: 2, octave: -1, degrees: degrees), "sol,")
        XCTAssertEqual(scaleLabel(forRatio: 1.25, degrees: degrees), "5/4")
        // A degree index the scale no longer has is skipped, never renamed.
        XCTAssertEqual(scaleLabel(degree: 7, degrees: degrees), "—")
    }

    // MARK: - The tonic (concert note names — a different axis)

    /// The tonic setters agree, and picking a NOTE keeps the cents offset (so
    /// a fine tuning survives a change of note) while an off-note frequency
    /// splits into anchor + remainder, staying inside the ±50¢ the sync blob
    /// encodes.
    func testTonicSettersKeepTheirHalves() {
        let e = PitchPadEngine(state: OutboundPlayState())

        // A fresh engine ALWAYS opens on G#3 — the tonic is not persisted.
        XCTAssertEqual(e.tonicMidi, PitchPadEngine.defaultTonicMidi)
        XCTAssertEqual(Scale.noteName(for: e.tonicMidi), "G#3")
        XCTAssertEqual(e.tonicCents, 0, accuracy: 1e-9)
        XCTAssertEqual(e.tonicHz, 207.6523, accuracy: 1e-3)

        e.setTonic(hz: 440.0)
        XCTAssertEqual(e.tonicMidi, 69)
        XCTAssertEqual(e.tonicCents, 0, accuracy: 1e-9)

        // A typed frequency 14¢ under A4 splits into the anchor + remainder.
        e.setTonic(hz: 440.0 * pow(2.0, -0.14 / 12.0))
        XCTAssertEqual(e.tonicMidi, 69)
        XCTAssertEqual(e.tonicCents, -14, accuracy: 1e-9)

        // Pick the next note up from the menu: same offset, a semitone up.
        e.setTonic(midi: e.tonicMidi + 1)
        XCTAssertEqual(e.tonicMidi, 70)
        XCTAssertEqual(e.tonicCents, -14, accuracy: 1e-9)
        XCTAssertEqual(e.tonicHz, 440.0 * pow(2.0, (1 - 0.14) / 12.0), accuracy: 1e-6)

        // Past the half-semitone the ANCHOR rolls, so the remainder always
        // stays inside ±50¢: A#4 −14¢ + 70¢ = B4 −44¢.
        e.setTonic(fractionalMidi: e.tonicFractionalMidi + 0.70)
        XCTAssertEqual(e.tonicMidi, 71)
        XCTAssertEqual(e.tonicCents, -44, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(abs(e.tonicCents), 50)

        // Both ends clamp to the range.
        e.setTonic(midi: 999)
        XCTAssertEqual(e.tonicMidi, PitchPadEngine.tonicNoteRange.upperBound)
        e.setTonic(midi: -5)
        XCTAssertEqual(e.tonicMidi, PitchPadEngine.tonicNoteRange.lowerBound)
    }
}
