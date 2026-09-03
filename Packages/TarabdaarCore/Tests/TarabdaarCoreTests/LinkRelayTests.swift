import XCTest
@testable import TarabdaarCore

/// The Mac-side relay glue extracted from `AppController`: the
/// JOYCON_STATE display mirror's frame assembly, the change-gated volume
/// readout, and the debounced rebuild funnel.
final class LinkRelayTests: XCTestCase {

    // MARK: - JOYCON_STATE mirror

    /// An axis that has never reported reads as absent (`bodyLive` /
    /// `armLive` false, values 0); a report both stores and pushes.
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
    }

    /// A stick inside the dead zone does not read as live.
    func testStickDeadZone() {
        let relay = JoyConDisplayRelay()
        relay.setStick(0.03, -0.03)
        XCTAssertFalse(relay.frame().stickLive)
        relay.setStick(0.03, -0.05)
        XCTAssertTrue(relay.frame().stickLive)
    }

    // MARK: - Volume readout

    /// The relay converts to the two TLP bytes and drops an unchanged
    /// pair — a silent instrument costs no wire traffic.
    func testVolumeRelayIsChangeGated() {
        var level = (voice: 0.5, taraf: 0.25)
        var sent: [(UInt8, UInt8)] = []
        let relay = VolumeMeterRelay(levels: { level },
                                     send: { sent.append(($0, $1)) })
        relay.tick()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0, TLPVolume.byte(fromLinear: 0.5))
        XCTAssertEqual(sent[0].1, TLPVolume.byte(fromLinear: 0.25))
        relay.tick()
        XCTAssertEqual(sent.count, 1, "unchanged bytes are dropped")
        level = (voice: 0.5, taraf: 0.9)
        relay.tick()
        XCTAssertEqual(sent.count, 2)
    }

    /// Silence maps to byte 0 on both buses and is sent at most once.
    func testVolumeRelaySilence() {
        var sent = 0
        let relay = VolumeMeterRelay(levels: { (voice: 0, taraf: 0) },
                                     send: { _, _ in sent += 1 })
        relay.tick()
        relay.tick()
        XCTAssertEqual(sent, 0, "the gate starts at (0, 0)")
    }

    // MARK: - The rebuild funnel

    /// A burst of rebuild-path values costs ONE flush, last value per key.
    func testDebouncedFlushMergesABurst() {
        var scheduled: [() -> Void] = []
        var flushes: [[String: Double]] = []
        let q = DebouncedParamFlush(
            delay: 0.25,
            schedule: { _, work in scheduled.append(work) },
            flush: { flushes.append($0) })
        q.queue(["a": 1])
        q.queue(["b": 2])
        q.queue(["a": 3])
        XCTAssertEqual(scheduled.count, 1, "one flush in flight")
        scheduled.removeFirst()()
        XCTAssertEqual(flushes, [["a": 3, "b": 2]])
        // The next burst schedules again.
        q.queue(["c": 4])
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(flushes.last, ["c": 4])
    }

    /// An empty batch never schedules anything (an unbound axis frame).
    func testDebouncedFlushIgnoresEmptyBatches() {
        var scheduled = 0
        let q = DebouncedParamFlush(schedule: { _, _ in scheduled += 1 },
                                    flush: { _ in })
        q.queue([:])
        XCTAssertEqual(scheduled, 0)
    }
}
