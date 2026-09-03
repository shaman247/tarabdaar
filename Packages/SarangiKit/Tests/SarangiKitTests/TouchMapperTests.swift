import XCTest
@testable import SarangiKit

/// The mapper's touch-id path allocates and releases exactly like the MIDI path — the parity substrate the render hash rests on.
final class TouchMapperTests: XCTestCase {

    /// One abstract step of a performance, playable through either path.
    private enum Step {
        case on(note: UInt8)     // touch id = note; MPE channel = note % 15 + 1
        case off(note: UInt8)
        case allOff
    }

    private func applyMIDI(_ m: BowControlMapper, _ s: Step) {
        switch s {
        case .on(let n): m.midi(0x90 | (n % 15 + 1), n, 100)
        case .off(let n): m.midi(0x80 | (n % 15 + 1), n, 0)
        case .allOff: m.midi(0xB0, 123, 0)
        }
    }

    private func applyTouch(_ m: BowControlMapper, _ s: Step) {
        switch s {
        case .on(let n): m.touchOn(UInt16(n), pitchSemis: Double(n), velocity: 0.8)
        case .off(let n): m.touchOff(UInt16(n))
        case .allOff: m.touchAllOff()
        }
    }

    private func snap(_ m: BowControlMapper, count: Int = 8) -> BowControlMapper.PolySnapshot {
        var s = BowControlMapper.PolySnapshot(count: count)
        m.snapshotPoly(into: &s)
        return s
    }

    private func assertIdentical(_ script: [Step], slotLimit: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let midi = BowControlMapper()
        let touch = BowControlMapper()
        midi.setSlotLimit(slotLimit)
        touch.setSlotLimit(slotLimit)
        for (stepIdx, step) in script.enumerated() {
            applyMIDI(midi, step)
            applyTouch(touch, step)
            let a = snap(midi), b = snap(touch)
            XCTAssertEqual(a.lead, b.lead, "lead @ step \(stepIdx)", file: file, line: line)
            for i in 0..<a.slots.count {
                XCTAssertEqual(a.slots[i].f0Target, b.slots[i].f0Target,
                               "f0 slot \(i) @ step \(stepIdx)", file: file, line: line)
                XCTAssertEqual(a.slots[i].gate, b.slots[i].gate,
                               "gate slot \(i) @ step \(stepIdx)", file: file, line: line)
                XCTAssertEqual(a.slots[i].serial, b.slots[i].serial,
                               "serial slot \(i) @ step \(stepIdx)", file: file, line: line)
            }
        }
    }

    func testSingleNoteAndRelease() {
        assertIdentical([.on(note: 60), .off(note: 60)], slotLimit: 4)
    }

    func testChordAllocationAndSteal() {
        assertIdentical([.on(note: 60), .on(note: 64), .on(note: 67),
                         .on(note: 71),                    // steals oldest
                         .off(note: 64), .on(note: 72)],   // longest-released reuse
                        slotLimit: 3)
    }

    // MARK: touch-only semantics

    func testMixedMidiAndTouchCoexist() {
        // In-process MIDI (Mac keyboard/auditions) and link touches share
        // the mapper today only in tests, but identity must never collide.
        let m = BowControlMapper()
        m.setSlotLimit(4)
        m.midi(0x91, 60, 100)
        m.touchOn(60, pitchSemis: 64.0, velocity: 1.0)   // same number, distinct identity
        let s = snap(m)
        XCTAssertEqual(s.slots[0].gate, 1.0)
        XCTAssertEqual(s.slots[1].gate, 1.0)
        XCTAssertEqual(s.slots[0].f0Target, 440.0 * pow(2.0, (60.0 - 69.0) / 12.0))
        XCTAssertEqual(s.slots[1].f0Target, 440.0 * pow(2.0, (64.0 - 69.0) / 12.0))
    }
}
