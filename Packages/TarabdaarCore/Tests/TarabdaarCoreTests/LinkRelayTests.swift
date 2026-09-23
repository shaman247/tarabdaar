import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The Mac-side relay glue: the JOYCON_STATE display mirror's frame assembly
/// and the debounced rebuild funnel.
final class LinkRelayTests: XCTestCase {

    /// The note readout follows pitch, includes per-note expression, and clears despite silent volume.
    func testHighestNoteControlReadout() {
        let mapper = BowControlMapper()
        mapper.setSlotLimit(4)
        mapper.setAxis(expr: 0.8, press: 0.6, pos: 0.3)
        var sent: [TLPNoteControls] = []
        let relay = VolumeMeterRelay(levels: { (0, 0) }, send: { _, _ in },
            noteControls: { AudioEngine.noteControls(mapper: mapper) },
            sendNoteControls: { sent.append($0) })
        func poll() { for _ in 0..<4 { relay.tick() } }
        poll()
        XCTAssertTrue(sent.isEmpty)
        mapper.touchOn(1, pitchSemis: 72, exprScale: 0.5)
        mapper.touchOn(2, pitchSemis: 60, exprScale: 1)
        poll()
        XCTAssertEqual(sent.last, TLPNoteControls(expression: 0.4, pressure: 0.6, position: 0.3))
        let count = sent.count
        poll()
        XCTAssertEqual(sent.count, count)
        mapper.touchGlide(2, pitchSemis: 76)
        poll()
        XCTAssertEqual(sent.last, TLPNoteControls(expression: 0.8, pressure: 0.6, position: 0.3))
        mapper.touchOff(2)
        poll()
        XCTAssertEqual(sent.last, TLPNoteControls(expression: 0.4, pressure: 0.6, position: 0.3))
        mapper.touchOff(1)
        poll()
        XCTAssertEqual(sent.last, .idle)
    }

    /// The connected stick stays live at centre; motion is paced and acted-on edges send immediately.
    func testDisplayFrameReportsLivenessPerAxisGroup() {
        let relay = JoyConDisplayRelay()
        var sent: [(JoyConTiltDisplay, Bool)] = []
        relay.send = { sent.append(($0, $1)) }
        relay.connected = { true }
        relay.strikeWindowS = { 1.25 }
        relay.fieldWarp = { 0.5 }
        relay.octaveShift = { -2 }

        let idle = relay.frame()
        XCTAssertFalse(idle.bodyLive)
        XCTAssertFalse(idle.armLive)
        XCTAssertTrue(idle.stickLive)
        XCTAssertTrue(idle.connected)
        XCTAssertEqual(idle.strikeWindowS, 1.25, accuracy: 1e-12)
        XCTAssertEqual(idle.fieldWarp, 0.5, accuracy: 1e-12)
        XCTAssertEqual(idle.octaveShift, -2)

        relay.setWrist(JoyConWristMotion(tilt: SIMD3(0.1, 0.2, 0.3),
                                         rate: SIMD3(-0.5, 0, 0.5),
                                         accel: SIMD3(0.7, -0.8, 0.9),
                                         accelLevel: 0.75))
        relay.setArm(0.4, 0.5, 0.6)
        relay.setStick(0.5, 0)
        let f = relay.frame()
        XCTAssertTrue(f.bodyLive)
        XCTAssertTrue(f.armLive)
        XCTAssertTrue(f.stickLive)
        XCTAssertEqual(f.wrist3, 0.3, accuracy: 1e-12)
        XCTAssertEqual(f.wristRate1, -0.5, accuracy: 1e-12)
        XCTAssertEqual(f.accel2, -0.8, accuracy: 1e-12)
        XCTAssertEqual(f.accelLevel, 0.75, accuracy: 1e-12)
        XCTAssertEqual(f.arm2, 0.5, accuracy: 1e-12)
        XCTAssertTrue(sent.first?.1 ?? false, "the first frame is immediate")
        XCTAssertFalse(sent.dropFirst().contains { $0.1 }, "axis pushes are link-paced")
        relay.octaveShift = { -1 }
        relay.setStick(0.6, 0)
        XCTAssertTrue(sent.last?.1 ?? false, "an acted-on edge is immediate")
        relay.setStick(0.7, 0)
        XCTAssertFalse(sent.last?.1 ?? true, "and the next axis push is paced again")

        let rest = JoyConDisplayRelay()
        XCTAssertFalse(rest.frame().stickLive)
        rest.connected = { true }
        XCTAssertTrue(rest.frame().stickLive)
        rest.setStick(0.03, -0.03)
        XCTAssertTrue(rest.frame().stickLive)
        rest.connected = { false }
        XCTAssertFalse(rest.frame().stickLive)
    }

    /// A burst of rebuild-path values costs ONE flush, last value per key; an
    /// empty batch never schedules anything.
    func testDebouncedFlushMergesABurst() {
        var scheduled: [() -> Void] = []
        var flushes: [[String: Double]] = []
        let q = DebouncedParamFlush(
            delay: 0.25,
            schedule: { _, work in scheduled.append(work) },
            flush: { flushes.append($0) })
        q.queue([:])
        XCTAssertEqual(scheduled.count, 0, "an empty batch scheduled a flush")
        q.queue(["a": 1])
        q.queue(["b": 2])
        q.queue(["a": 3])
        XCTAssertEqual(scheduled.count, 1, "one flush in flight")
        scheduled.removeFirst()()
        XCTAssertEqual(flushes, [["a": 3, "b": 2]])
        // the next burst schedules again
        q.queue(["c": 4])
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(flushes.last, ["c": 4])
    }
}
