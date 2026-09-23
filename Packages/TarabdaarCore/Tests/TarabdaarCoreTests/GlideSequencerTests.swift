import XCTest
@testable import TarabdaarCore

/// Glide joining, release grace, ownership, parked fingers and pass-through contracts.
final class GlideSequencerTests: XCTestCase {

    enum Call: Equatable {
        case on(UInt16, Double)
        case glide(UInt16, Double)
        case off(UInt16)
        case resume(UInt16, Double)
    }

    var now = 0.0
    var seq: GlideSequencer!
    var calls: [Call] = []

    override func setUp() {
        super.setUp()
        now = 0
        calls = []
        seq = GlideSequencer(drivesTimer: false) { [weak self] in
            self?.now ?? 0
        }
        seq.onTouchOn = { [weak self] id, p in
            self?.calls.append(.on(id, p))
        }
        seq.onTouchGlide = { [weak self] id, p in
            self?.calls.append(.glide(id, p))
        }
        seq.onTouchResume = { [weak self] id, p in
            self?.calls.append(.resume(id, p))
        }
        seq.onTouchOff = { [weak self] id in
            self?.calls.append(.off(id))
        }
    }

    /// Advance time in small steps, ticking the sequencer.
    func advance(_ dt: Double, steps: Int = 50) {
        let step = dt / Double(steps)
        for _ in 0..<steps {
            now += step
            seq.tick(now: now)
        }
    }

    /// `over` defaults to 0 so the trajectory math stays exact.
    func enable(rate: Double = 40, held: Double = 0.3,
                catchup: Double = 4, over: Double = 0, grace: Double = 0) {
        seq.setControl("ctl_glide_on", 1)
        seq.setControl("ctl_glide_grace", grace)
        seq.setControl("ctl_glide_rate", rate)
        seq.setControl("ctl_glide_held", held)
        seq.setControl("ctl_glide_catchup", catchup)
        seq.setControl("ctl_glide_over", over)
    }

    /// Every pitch the voice `id` was commanded to, in order.
    func pitchTrace(_ id: UInt16) -> [Double] {
        calls.compactMap {
            if case .glide(let cid, let p) = $0, cid == id { return p }
            return nil
        }
    }

    /// The last commanded pitch of voice `id`.
    func lastPitch(_ id: UInt16) -> Double? {
        for c in calls.reversed() {
            if case .glide(let cid, let p) = c, cid == id { return p }
        }
        return nil
    }

    func onCount() -> Int {
        calls.filter { if case .on = $0 { return true }; return false }.count
    }

    /// The parity contract: with the toggle off (the default), every event
    /// passes through verbatim — overlapping fingers included.
    func testDisabledIsPurePassThrough() {
        seq.touchOn(1, pitchSemis: 60)
        now += 0.01                       // overlapping second finger
        seq.touchOn(2, pitchSemis: 64)
        seq.touchGlide(1, pitchSemis: 60.5)
        seq.touchOff(1)
        seq.touchOff(2)
        XCTAssertEqual(calls, [
            .on(1, 60), .on(2, 64), .glide(1, 60.5),
            .off(1), .off(2),
        ])
    }

    /// Zero grace preserves immediate staccato release.
    func testStaccatoReleaseIsImmediate() {
        enable()
        seq.touchOn(1, pitchSemis: 60)
        now += 0.03
        seq.touchOff(1)
        XCTAssertEqual(calls, [.on(1, 60), .off(1)],
                       "off in the release call itself, no tick needed")
    }

    /// Short gaps reuse the sounding voice and renew grace after each final lift.
    func testReleaseGraceConnectsSuccessiveGaps() {
        seq.setControl("ctl_glide_on", 1) // exercise the default grace
        seq.setControl("ctl_glide_over", 0)
        seq.touchOn(1, pitchSemis: 60)
        seq.touchOff(1)
        advance(0.10)
        XCTAssertEqual(calls, [.on(1, 60), .off(1)])
        seq.touchOn(2, pitchSemis: 64)
        advance(0.11)
        XCTAssertEqual(lastPitch(1), 64)
        seq.touchOff(2)
        advance(0.10)
        seq.touchOn(3, pitchSemis: 67)
        advance(0.10)
        XCTAssertEqual(lastPitch(1), 67)
        XCTAssertEqual(onCount(), 1)
        XCTAssertEqual(calls.filter { if case .resume = $0 { return true }; return false },
                       [.resume(1, 60), .resume(1, 64)])
        seq.touchOff(3)
        XCTAssertEqual(calls.last, .off(1), "the last release is immediate")
        let atRelease = calls
        advance(0.16)
        XCTAssertEqual(calls, atRelease, "expiry emits no sound or duplicate release")
    }

    /// A late onset expires grace even before the next timer tick.
    func testExpiredGraceStartsFreshWithoutTimerTick() {
        enable(grace: 150)
        seq.touchOn(1, pitchSemis: 60)
        seq.touchOff(1)
        now = 0.151
        seq.touchOn(2, pitchSemis: 64)
        XCTAssertEqual(calls, [.on(1, 60), .off(1), .on(2, 64)])
    }

    /// Repeated pitches re-attack during grace, including reused touch identities.
    func testRepeatTapDuringGraceReattacks() {
        enable(grace: 150)
        seq.touchOn(1, pitchSemis: 60)
        seq.touchOff(1)
        now = 0.05
        seq.touchOn(2, pitchSemis: 60)
        XCTAssertEqual(calls, [.on(1, 60), .off(1), .on(2, 60)])
        seq.touchOff(2)
        now += 0.05
        seq.touchOn(2, pitchSemis: 60)
        XCTAssertEqual(Array(calls.suffix(2)), [.off(2), .on(2, 60)])
    }

    /// The last physical lift releases even mid-glide; expiry never plays abandoned waypoints.
    func testQueuedReleaseGraceRunsFromLastPhysicalLift() {
        enable(rate: 40, held: 1, grace: 150)
        seq.touchOn(1, pitchSemis: 60)
        seq.touchOn(2, pitchSemis: 72)
        seq.touchOff(1)
        seq.touchOff(2)
        advance(0.20)
        seq.touchOn(3, pitchSemis: 76)
        XCTAssertEqual(onCount(), 2, "an expired in-flight chain cannot capture")
        advance(0.11)
        XCTAssertNil(lastPitch(1))
        XCTAssertTrue(calls.contains(.off(1)))
    }

    /// Disabling grace flushes a waiting release; reset cancels it without later events.
    func testGraceControlsAndResetDoNotLeavePendingReleases() {
        enable(grace: 150)
        seq.touchOn(1, pitchSemis: 60)
        seq.touchOff(1)
        seq.setControl("ctl_glide_on", 0)
        XCTAssertEqual(calls.last, .off(1))
        enable(grace: 150)
        seq.touchOn(2, pitchSemis: 64)
        seq.touchOff(2)
        seq.setControl("ctl_glide_grace", 0)
        XCTAssertEqual(calls.last, .off(2))
        enable(grace: 150)
        seq.touchOn(3, pitchSemis: 67)
        seq.touchOff(3)
        seq.reset()
        calls = []
        advance(1)
        XCTAssertEqual(calls, [])
    }

    /// A second onset while the first is HELD mounts NO note — the first
    /// voice glides to its pitch and arrives exactly.
    func testOverlappingOnsetQueuesAndGlides() {
        enable(rate: 40, held: 1.0)                // held = full rate
        seq.touchOn(1, pitchSemis: 60)
        now += 0.1
        seq.touchOn(2, pitchSemis: 64)
        XCTAssertEqual(calls, [.on(1, 60)], "no second note-on")

        advance(0.05)                              // mid-glide
        guard let mid = lastPitch(1) else { return XCTFail("no glide") }
        XCTAssertGreaterThan(mid, 60.01)
        XCTAssertLessThan(mid, 64)

        advance(0.2)                               // 4 st / 40 st/s = 0.1 s
        XCTAssertEqual(lastPitch(1), 64, "arrives exactly on the target")
        XCTAssertEqual(onCount(), 1)
    }

    /// After arrival the queued touch OWNS the voice: its drags meend it
    /// (as the original voice id) and its release ends it immediately.
    func testOwnershipTransfersOnArrival() {
        enable(rate: 400, held: 1.0)
        seq.touchOn(1, pitchSemis: 60)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64)   // overlap → queue
        seq.touchOff(1)                            // source lifts mid-glide
        advance(0.1)                               // arrive well within
        XCTAssertEqual(lastPitch(1), 64)

        calls = []
        seq.touchGlide(2, pitchSemis: 64.5)        // finger 2 meends
        XCTAssertEqual(calls, [.glide(1, 64.5)], "mapped onto voice 1")
        seq.touchOff(2)
        XCTAssertEqual(calls.last, .off(1), "release maps to voice 1")
        XCTAssertFalse(calls.contains { if case .off(2) = $0 { return true }
                                        return false })
    }

    /// THE TWO-FINGER OSCILLATION BUG: after ownership transfers, the
    /// still-held first finger's wiggles must be ignored — its wire id is the
    /// voice's downstream id, so passing them through yanked the pitch back.
    func testParkedFingerWiggleIsIgnored() {
        enable(rate: 400, held: 1.0)
        seq.touchOn(1, pitchSemis: 60)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64)   // both held
        advance(0.1)                                    // arrive; 1 parks
        XCTAssertEqual(lastPitch(1), 64)

        calls = []
        seq.touchGlide(1, pitchSemis: 60.2)             // finger 1 wiggles
        seq.touchGlide(1, pitchSemis: 59.8)
        seq.tick(now: now)
        XCTAssertEqual(calls, [], "parked wiggles are silent")

        seq.touchGlide(2, pitchSemis: 64.3)             // owner meends
        XCTAssertEqual(calls, [.glide(1, 64.3)], "the owner drives")
    }

    /// Releasing the owner glides BACK to the most recent still-held finger
    /// and hands it the voice; three fingers cascade in most-recent-first
    /// order, and only the last release lifts the bow.
    func testCascadeGlidesBackInOrderAndHandsOverOwnership() {
        enable(rate: 400, held: 1.0)
        seq.touchOn(1, pitchSemis: 60)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64)
        advance(0.1)
        seq.touchOn(3, pitchSemis: 67)
        advance(0.1)
        XCTAssertEqual(lastPitch(1), 67)

        seq.touchOff(3)
        advance(0.1)
        XCTAssertEqual(lastPitch(1), 64, "back to the second finger")
        XCTAssertFalse(calls.contains(.off(1)))
        seq.touchOff(2)
        advance(0.1)
        XCTAssertEqual(lastPitch(1), 60, "back to the first finger")
        XCTAssertFalse(calls.contains(.off(1)))
        XCTAssertEqual(onCount(), 1, "one voice for the whole episode")

        calls = []
        seq.touchGlide(1, pitchSemis: 60.5)          // finger 1 owns again
        XCTAssertEqual(calls, [.glide(1, 60.5)])
        seq.touchOff(1)
        XCTAssertEqual(calls.last, .off(1), "last member up = bow up")
    }

    /// Exempt touches (the strum chord) pass through even while overlapping,
    /// and never capture following notes.
    func testExemptTouchesBypassTheQueue() {
        enable()
        seq.markExempt(10)
        seq.markExempt(11)
        seq.touchOn(10, pitchSemis: 48)
        now += 0.01
        seq.touchOn(11, pitchSemis: 55)   // chord mate
        seq.touchOff(10)
        seq.touchOff(11)
        XCTAssertEqual(calls, [.on(10, 48), .on(11, 55),
                               .off(10), .off(11)])
    }
}
