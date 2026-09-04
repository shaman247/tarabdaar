import XCTest
@testable import TarabdaarCore

/// The controller strum: what a strum sounds, the hold/retrigger/release laws
/// for the L button and the accel trigger, and the in-place retune when the
/// chord-bar selection moves while the chord rings.
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

    /// No selection (and an out-of-range degree) sounds the configured strum
    /// set; a valid selection sounds the derived chord under the Shepard law.
    func testWhatAStrumSounds() {
        let plain = StrumController.notes(selection: nil, degrees: degrees,
                                          fallback: fallback)
        XCTAssertEqual(plain.map(\.ratio), fallback)
        XCTAssertEqual(plain.map(\.weight), [1.0, 1.0])
        XCTAssertEqual(StrumController.notes(
            selection: ChordSelection(degree: 99, octave: 0),
            degrees: degrees, fallback: fallback).map(\.ratio), fallback)

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

    /// L down strikes the whole set, L up releases exactly those ids, and a
    /// press while ringing retriggers with fresh (generation-scoped) ids.
    func testLButtonHoldAndRetrigger() {
        let (c, calls) = makeController()
        c.strum(pressed: true)
        let held = c.heldTouchIds
        XCTAssertEqual(held.count, fallback.count)
        XCTAssertEqual(calls(), [
            .on(id: held[0], ratio: 0.5, expr: 1.0),
            .on(id: held[1], ratio: 0.75, expr: 1.0),
        ])
        c.strum(pressed: true)
        let second = c.heldTouchIds
        XCTAssertEqual(second.count, held.count)
        XCTAssertTrue(Set(held).isDisjoint(with: Set(second)),
                      "a retrigger reused its ids")
        c.strum(pressed: false)
        XCTAssertEqual(calls().suffix(2),
                       [.off(id: second[0]), .off(id: second[1])])
        XCTAssertTrue(c.heldTouchIds.isEmpty)
    }

    /// Rising through `ctl_strum_thresh` strikes and falling releases, with a
    /// cooldown against a jittery envelope; 127 disarms; a held L is not stolen.
    func testAccelTrigger() {
        var clock: TimeInterval = 100
        let (c, _) = makeController(now: { clock })
        c.setAccelThreshold(0.504)
        c.accelSense(0.2)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
        c.accelSense(0.7)
        XCTAssertEqual(c.heldTouchIds.count, fallback.count)
        c.accelSense(0.1)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
        clock += 0.05                                 // inside the cooldown
        c.accelSense(0.9)
        XCTAssertTrue(c.heldTouchIds.isEmpty)
        clock += 0.1                                  // and past it
        c.accelSense(0.0)
        c.accelSense(0.9)
        XCTAssertEqual(c.heldTouchIds.count, fallback.count)

        // L still holding keeps the chord alive when the trigger drops
        let (held, _) = makeController()
        held.setAccelThreshold(0.504)
        held.strum(pressed: true)
        held.accelSense(0.9)
        held.accelSense(0.1)
        XCTAssertFalse(held.heldTouchIds.isEmpty, "L still holds the chord")
        held.strum(pressed: false)
        XCTAssertTrue(held.heldTouchIds.isEmpty)

        let (off, _) = makeController()
        off.setAccelThreshold(1)
        off.accelSense(1.0)
        XCTAssertTrue(off.heldTouchIds.isEmpty, "127 must disarm the trigger")
    }

    /// A selection change while ringing retunes in place — the surviving
    /// members glide, never re-attack; with nothing ringing it is silent.
    func testSelectionChangeRetunesInPlace() {
        let (c, calls) = makeController(selectionFallback: [0.5, 0.75])
        c.setSelection(ChordSelection(degree: 1, octave: 0))
        XCTAssertTrue(calls().isEmpty, "a selection change sounded a chord")

        c.strum(pressed: true)
        let held = c.heldTouchIds
        let before = calls().count
        c.setSelection(ChordSelection(degree: 0, octave: 0))
        let after = Array(calls().dropFirst(before))
        XCTAssertFalse(after.isEmpty)
        for call in after {
            if case let .glide(id, _) = call {
                XCTAssertTrue(held.contains(id))
            }
        }
        XCTAssertEqual(c.selection, ChordSelection(degree: 0, octave: 0))
    }
}
