import XCTest
@testable import SarangiKit

/// The mapper's slot allocation on the touch path — the ONE note path.
/// Every note-on mounts a FRESH string (unused slot, else longest-released,
/// else steal the oldest sounding note) and bumps `serial`.
final class TouchMapperTests: XCTestCase {

    private func snap(_ m: BowControlMapper, count: Int = 8) -> BowControlMapper.PolySnapshot {
        var s = BowControlMapper.PolySnapshot(count: count)
        m.snapshotPoly(into: &s)
        return s
    }

    private func f0(_ semis: Double) -> Double {
        440.0 * pow(2.0, (semis - 69.0) / 12.0)
    }

    /// Fresh slot, longest-released reuse, then steal the oldest sounding
    /// note; a released bow keeps its pitch and `touchAllOff` lifts every one.
    func testAllocationMountsFreshStringsAndSteals() {
        let m = BowControlMapper()
        m.setSlotLimit(3)
        for n in [60, 64, 67] as [UInt16] {
            m.touchOn(n, pitchSemis: Double(n), velocity: 0.8)
        }
        var s = snap(m)
        XCTAssertEqual(s.slots[0..<3].map(\.gate), [1.0, 1.0, 1.0])
        XCTAssertEqual(s.slots[0..<3].map(\.f0Target), [f0(60), f0(64), f0(67)])
        XCTAssertEqual(s.slots[0].serial, 1)

        // no free slot, none released: the OLDEST sounding note is stolen
        m.touchOn(71, pitchSemis: 71, velocity: 0.8)
        s = snap(m)
        XCTAssertEqual(s.slots[0].f0Target, f0(71))
        XCTAssertEqual(s.slots[0].serial, 2, "the stolen slot mounts a fresh string")
        XCTAssertEqual(s.lead, 0)

        // a released slot is the longest-released reuse before any steal
        m.touchOff(64)
        s = snap(m)
        XCTAssertEqual(s.slots[1].gate, 0.0)
        XCTAssertEqual(s.slots[1].f0Target, f0(64), "the bow lifts; the string rings on")
        m.touchOn(72, pitchSemis: 72, velocity: 0.8)
        s = snap(m)
        XCTAssertEqual(s.slots[1].f0Target, f0(72))
        XCTAssertEqual(s.slots[1].gate, 1.0)
        XCTAssertEqual(s.slots[2].f0Target, f0(67), "a sounding note was stolen early")

        m.touchAllOff()
        XCTAssertEqual(snap(m).slots[0..<3].map(\.gate), [0.0, 0.0, 0.0])
    }

    /// A retrigger on a live id releases the old string and mounts a new one.
    func testRetriggerOnALiveIdMountsAFreshString() {
        let m = BowControlMapper()
        m.setSlotLimit(4)
        m.touchOn(7, pitchSemis: 60, velocity: 0.8)
        m.touchOn(7, pitchSemis: 62, velocity: 0.8)     // same id, retrigger
        let s = snap(m)
        XCTAssertEqual(s.slots[0].gate, 0.0, "the first string was not released")
        XCTAssertEqual(s.slots[0].f0Target, f0(60), "the released string moved")
        XCTAssertEqual(s.slots[1].gate, 1.0)
        XCTAssertEqual(s.slots[1].f0Target, f0(62))
    }

    /// One touch = one identity: a glide moves only its own slot (a released
    /// string freezes), and two ids at the same pitch release independently.
    func testGlideAndReleaseFollowTheTouchIdentity() {
        let m = BowControlMapper()
        m.setSlotLimit(4)
        m.touchOn(1, pitchSemis: 60, velocity: 0.8)
        m.touchOn(2, pitchSemis: 64, velocity: 0.8)
        m.touchGlide(1, pitchSemis: 61.5)
        var s = snap(m)
        XCTAssertEqual(s.slots[0].f0Target, f0(61.5))
        XCTAssertEqual(s.slots[1].f0Target, f0(64))

        m.touchOff(1)
        m.touchGlide(1, pitchSemis: 55)
        s = snap(m)
        XCTAssertEqual(s.slots[0].f0Target, f0(61.5), "a released string froze")
        XCTAssertEqual(s.slots[1].gate, 1.0, "releasing one id released the other")

        // distinct ids at the SAME pitch keep distinct identities
        let n = BowControlMapper()
        n.setSlotLimit(4)
        n.touchOn(1, pitchSemis: 60, velocity: 1.0)
        n.touchOn(2, pitchSemis: 60, velocity: 1.0)
        n.touchOff(1)
        let t = snap(n)
        XCTAssertEqual(t.slots[0].gate, 0.0)
        XCTAssertEqual(t.slots[1].gate, 1.0)
    }
}
