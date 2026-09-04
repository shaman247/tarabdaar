import XCTest
@testable import TarabdaarCore

/// The Mac-side relay glue: the JOYCON_STATE display mirror's frame assembly
/// and the debounced rebuild funnel.
final class LinkRelayTests: XCTestCase {

    /// An axis that has never reported reads as absent; a report both stores
    /// and pushes; the fields the iPad ACTS on ride every frame.
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
        XCTAssertFalse(idle.stickLive)
        XCTAssertTrue(idle.connected)
        XCTAssertEqual(idle.strikeWindowS, 1.25, accuracy: 1e-12)
        XCTAssertEqual(idle.fieldWarp, 0.5, accuracy: 1e-12)
        XCTAssertEqual(idle.octaveShift, -2)

        relay.setWrist((0.1, 0.2, 0.3))
        relay.setArm(0.4, 0.5, 0.6)
        relay.setStick(0.5, 0)
        let f = relay.frame()
        XCTAssertTrue(f.bodyLive)
        XCTAssertTrue(f.armLive)
        XCTAssertTrue(f.stickLive)
        XCTAssertEqual(f.wrist3, 0.3, accuracy: 1e-12)
        XCTAssertEqual(f.arm2, 0.5, accuracy: 1e-12)
        XCTAssertEqual(sent.count, 3, "each setter pushes")
        XCTAssertFalse(sent.allSatisfy { $0.1 }, "axis pushes are link-paced")
        relay.push(force: true)
        XCTAssertTrue(sent.last?.1 ?? false)

        // a stick inside the dead zone does not read as live
        let rest = JoyConDisplayRelay()
        rest.setStick(0.03, -0.03)
        XCTAssertFalse(rest.frame().stickLive)
        rest.setStick(0.03, -0.05)
        XCTAssertTrue(rest.frame().stickLive)
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
