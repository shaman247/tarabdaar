import XCTest
@testable import TarabdaarCore

final class MIDISysExScheduleTests: XCTestCase {
    /// Sync bursts stay separated and ordered; ordinary paced frames incur no delay.
    func testBurstSpacingAndReturnToImmediateDelivery() {
        var schedule = MIDISysExSchedule()
        let gap = MIDISysExSchedule.spacingTicks
        XCTAssertGreaterThan(gap, 0)
        let now = gap * 100
        // Scale, arrangement, taraf bank and the forced display resend.
        let burst = (0..<4).map { _ in schedule.reserve(now: now) }
        XCTAssertEqual(burst, (0..<4).map { now + UInt64($0) * gap })
        // A further message cannot overtake the already scheduled burst.
        XCTAssertEqual(schedule.reserve(now: now + gap), now + 4 * gap)
        // At the usual 120 Hz cadence the transport adds no latency.
        let nextTick = now + 9 * gap
        XCTAssertEqual(schedule.reserve(now: nextTick), nextTick)
        XCTAssertEqual(schedule.reserve(now: nextTick + 4 * gap), nextTick + 4 * gap)
    }
}
