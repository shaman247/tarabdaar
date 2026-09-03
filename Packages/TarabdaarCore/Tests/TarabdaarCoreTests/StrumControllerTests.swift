import XCTest
@testable import TarabdaarCore

/// The controller strum: what a strum sounds, the hold/retrigger/release
/// laws for the L button and the accel trigger, and the in-place retune
/// when the chord-bar selection moves while the chord rings.
final class StrumControllerTests: XCTestCase {

    private enum Call: Equatable {
        case on(id: Int, ratio: Double, expr: Double)
        case off(id: Int)
        case glide(id: Int, ratio: Double)
        case expr(id: Int, value: Double)
    }

    /// A 3-degree scale is enough for the chord derivation; the strum-set
    /// fallback is the Strings tab's configured ratios.
    private let degrees: [(ratio: Double, label: String)] = [
        (1.0, "S"), (1.25, "G"), (1.5, "P"),
    ]
    private let fallback = [0.5, 0.75]

    private func makeController(
        selectionFallback: [Double]? = nil,
        now: @escaping () -> TimeInterval = { 0 }
    ) -> (StrumController, () -> [Call]) {
        var calls: [Call] = []
        let sink = StrumController.NoteSink(
            noteOn: { id, ratio, _, expr in
                calls.append(.on(id: id, ratio: ratio, expr: expr))
            },
            noteOff: { calls.append(.off(id: $0)) },
            glide: { calls.append(.glide(id: $0, ratio: $1)) },
            setExpr: { calls.append(.expr(id: $0, value: $1)) })
        let c = StrumController(
            sink: sink,
            degrees: { self.degrees },
            fallbackRatios: { selectionFallback ?? self.fallback },
            dispatchMain: { $0() },          // synchronous in tests
            now: now)
        return (c, { calls })
    }

    // MARK: - What a strum sounds

    /// No selection = the configured strum set at weight 1.
    func testNotesFallBackToTheConfiguredSet() {
        let n = StrumController.notes(selection: nil, degrees: degrees,
                                      fallback: fallback)
        XCTAssertEqual(n.map(\.ratio), fallback)
        XCTAssertEqual(n.map(\.weight), [1.0, 1.0])
    }

    /// A selection sounds the derived chord under the Shepard register
    /// law: every member sits in the two-octave window below the tonic,
    /// and each chord TONE's copies carry unit total weight.
    func testSelectionSoundsTheShepardChord() {
        let chord = scaleChords(degrees: degrees)[0]
        let n = StrumController.notes(
            selection: ChordSelection(degree: 0, octave: 0),
            degrees: degrees, fallback: fallback)
        XCTAssertFalse(n.isEmpty)
        XCTAssertEqual(n.map(\.weight).reduce(0, +),
                       Double(chord.intervals.count), accuracy: 0.1)
        for note in n {
            XCTAssertGreaterThan(note.ratio, 0.2)
            XCTAssertLessThan(note.ratio, 1.5)
        }
    }

    /// An out-of-range selection degree falls back rather than trapping.
    func testOutOfRangeSelectionFallsBack() {
        let n = StrumController.notes(
            selection: ChordSelection(degree: 99, octave: 0),
            degrees: degrees, fallback: fallback)
        XCTAssertEqual(n.map(\.ratio), fallback)
    }

    // MARK: - Holds

    /// L down strikes the whole set; L up releases exactly those ids.
    func testLButtonStrikesAndReleases() {
        let (c, calls) = makeController()
        c.strum(pressed: true)
        let held = c.heldTouchIds
        XCTAssertEqual(held.count, fallback.count)
        XCTAssertEqual(calls(), [
            .on(id: held[0], ratio: 0.5, expr: 1.0),
            .on(id: held[1], ratio: 0.75, expr: 1.0),
        ])
        c.strum(pressed: false)
        XCTAssertEqual(calls().suffix(2),
                       [.off(id: held[0]), .off(id: held[1])])
        XCTAssertTrue(c.heldTouchIds.isEmpty)
    }

    /// A press while already ringing RETRIGGERS: the old chord is released
    /// first and the new one gets fresh (generation-scoped) ids.
    func testPressWhileRingingRetriggersWithNewIds() {
        let (c, _) = makeController()
        c.strum(pressed: true)
        let first = c.heldTouchIds
        c.strum(pressed: true)
        let second = c.heldTouchIds
        XCTAssertEqual(first.count, second.count)
        XCTAssertTrue(Set(first).isDisjoint(with: Set(second)))
    }

    /// `ctl_strum_expr` scales the ringing notes live (× each member's
    /// Shepard weight) and the next strike's onsets.
    func testExpressionPushesToHeldNotes() {
        let (c, calls) = makeController()
        c.strum(pressed: true)
        let held = c.heldTouchIds
        c.setExpression(0.4)
        XCTAssertEqual(calls().suffix(2), [
            .expr(id: held[0], value: 0.4),
            .expr(id: held[1], value: 0.4),
        ])
        c.strum(pressed: false)
        c.strum(pressed: true)
        if case let .on(_, _, expr) = calls().suffix(2).first {
            XCTAssertEqual(expr, 0.4, accuracy: 1e-9)
        } else {
            XCTFail("expected a fresh onset")
        }
    }

    // MARK: - The accel trigger

    /// Rising through `ctl_strum_thresh` strikes, falling releases, and the
    /// 100 ms cooldown blocks an immediate re-strike from a jittery
    /// envelope. 127 = off.
    func testAccelTriggerEdgesAndCooldown() {
        var clock: TimeInterval = 100
        let (c, calls) = makeController(now: { clock })
        c.setAccelThreshold(64)                       // ≈ 0.504
        c.accelSense(0.2)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
        c.accelSense(0.7)
        XCTAssertEqual(c.heldTouchIds.count, fallback.count)
        c.accelSense(0.1)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
        // Inside the cooldown a re-crossing is ignored…
        clock += 0.05
        c.accelSense(0.9)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
        // …and past it, it strikes again.
        clock += 0.1
        c.accelSense(0.0)                             // no edge (already low)
        c.accelSense(0.9)
        XCTAssertEqual(c.heldTouchIds.count, fallback.count)
        XCTAssertFalse(calls().isEmpty)
    }

    /// L still holding keeps the chord alive when the accel trigger drops.
    func testAccelReleaseDoesNotStealAHeldLButton() {
        let (c, _) = makeController()
        c.setAccelThreshold(64)
        c.strum(pressed: true)
        c.accelSense(0.9)                             // re-strikes, both held
        XCTAssertFalse(c.heldTouchIds.isEmpty)
        c.accelSense(0.1)
        XCTAssertFalse(c.heldTouchIds.isEmpty, "L still holds the chord")
        c.strum(pressed: false)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
    }

    /// A threshold of 127 disarms the trigger entirely.
    func testAccelThresholdOff() {
        let (c, _) = makeController()
        c.setAccelThreshold(127)
        c.accelSense(1.0)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
    }

    // MARK: - Selection edges

    /// A selection change while RINGING retunes in place — glides, never a
    /// fresh attack on the surviving members.
    func testSelectionChangeRetunesInPlace() {
        let (c, calls) = makeController(selectionFallback: [0.5, 0.75])
        c.strum(pressed: true)
        let held = c.heldTouchIds
        let before = calls().count
        c.setSelection(ChordSelection(degree: 0, octave: 0))
        let after = Array(calls().dropFirst(before))
        XCTAssertFalse(after.isEmpty)
        // The surviving members glide; only a GROWING chord adds onsets.
        for call in after {
            if case let .glide(id, _) = call {
                XCTAssertTrue(held.contains(id))
            }
        }
        XCTAssertEqual(c.selection, ChordSelection(degree: 0, octave: 0))
    }

    /// A selection change with nothing ringing sounds nothing.
    func testSelectionChangeSilentWhenNotRinging() {
        let (c, calls) = makeController()
        c.setSelection(ChordSelection(degree: 1, octave: 0))
        XCTAssertTrue(calls().isEmpty)
    }
}
