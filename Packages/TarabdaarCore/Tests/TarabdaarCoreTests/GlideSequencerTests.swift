import XCTest
@testable import TarabdaarCore

/// The glide queue's rules: off = pass-through, staccato releases immediately, overlap queues and glides, ownership transfer, parked fingers, glide-back cascade, strum exemption.
final class GlideSequencerTests: XCTestCase {

    enum Call: Equatable {
        case on(UInt16, Double, Double)
        case glide(UInt16, Double)
        case off(UInt16)
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
        seq.onTouchOn = { [weak self] id, p, v in
            self?.calls.append(.on(id, p, v))
        }
        seq.onTouchGlide = { [weak self] id, p in
            self?.calls.append(.glide(id, p))
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

    /// `over` defaults to 0 here so the trajectory-math tests stay
    /// exact; the overshoot tests opt in explicitly (the shipped
    /// registry default is 0.08).
    func enable(rate: Double = 40, held: Double = 0.3,
                catchup: Double = 4, over: Double = 0) {
        seq.setControl("ctl_glide_on", 1)
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

    // MARK: Pass-through

    /// The parity contract: with the toggle off (the default), every
    /// event passes through verbatim — overlapping fingers included.
    func testDisabledIsPurePassThrough() {
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.01                       // overlapping second finger
        seq.touchOn(2, pitchSemis: 64, velocity: 0.6)
        seq.touchGlide(1, pitchSemis: 60.5)
        seq.touchOff(1)
        seq.touchOff(2)
        XCTAssertEqual(calls, [
            .on(1, 60, 0.5), .on(2, 64, 0.6), .glide(1, 60.5),
            .off(1), .off(2),
        ])
    }

    /// THE STACCATO CONTRACT: a lone tap's release lands immediately —
    /// no deferral, no sustain (the first cut's regression).
    func testStaccatoReleaseIsImmediate() {
        enable()
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.03
        seq.touchOff(1)
        XCTAssertEqual(calls, [.on(1, 60, 0.5), .off(1)],
                       "off in the release call itself, no tick needed")
    }

    // MARK: Chaining

    /// A second onset while the first is HELD mounts NO note — the
    /// first voice glides to its pitch and arrives exactly.
    func testOverlappingOnsetQueuesAndGlides() {
        enable(rate: 40, held: 1.0)                // held = full rate
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.1
        seq.touchOn(2, pitchSemis: 64, velocity: 0.5)
        XCTAssertEqual(calls, [.on(1, 60, 0.5)], "no second note-on")

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
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64, velocity: 0.5)   // overlap → queue
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

    // MARK: Overshoot & correction

    // MARK: Parked fingers & glide-back

    /// THE TWO-FINGER OSCILLATION BUG (2026-08-31): after ownership
    /// transfers to the second finger, the still-held FIRST finger's
    /// wiggles must be ignored — its wire id is the voice's downstream
    /// id, so letting it fall through to pass-through yanked the pitch
    /// back on every wiggle. The voice sticks with the owner.
    func testParkedFingerWiggleIsIgnored() {
        enable(rate: 400, held: 1.0)
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64, velocity: 0.5)   // both held
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

    /// Releasing the second finger while the first still holds GLIDES
    /// BACK to the first note; the first finger then owns the voice.
    func testReleasingOwnerGlidesBackToHeldFirst() {
        enable(rate: 40, held: 1.0)
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64, velocity: 0.5)
        advance(0.3)                                    // arrive at 64
        calls = []
        seq.touchOff(2)                                 // owner lifts
        XCTAssertEqual(calls, [], "no bow-up — finger 1 still holds")
        advance(0.05)
        guard let mid = lastPitch(1) else { return XCTFail("no glide back") }
        XCTAssertLessThan(mid, 64)
        XCTAssertGreaterThan(mid, 60)
        advance(0.2)
        XCTAssertEqual(lastPitch(1), 60, "back on the first note")
        XCTAssertFalse(calls.contains(.off(1)))

        calls = []
        seq.touchGlide(1, pitchSemis: 60.5)             // 1 owns again
        XCTAssertEqual(calls, [.glide(1, 60.5)])
        seq.touchOff(1)
        XCTAssertEqual(calls.last, .off(1), "last member up = bow up")
    }

    /// Three held fingers cascade back in most-recent-first order, and
    /// only the last release lifts the bow.
    func testThreeFingerCascadeGlidesBackInOrder() {
        enable(rate: 400, held: 1.0)
        seq.touchOn(1, pitchSemis: 60, velocity: 0.5)
        now += 0.05
        seq.touchOn(2, pitchSemis: 64, velocity: 0.5)
        advance(0.1)
        seq.touchOn(3, pitchSemis: 67, velocity: 0.5)
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
        seq.touchOff(1)
        XCTAssertEqual(calls.last, .off(1))
        XCTAssertEqual(onCount(), 1, "one voice for the whole episode")
    }

    // MARK: Exemption

    /// Exempt touches (the strum chord) pass through even while
    /// overlapping, and never capture following notes.
    func testExemptTouchesBypassTheQueue() {
        enable()
        seq.markExempt(10)
        seq.markExempt(11)
        seq.touchOn(10, pitchSemis: 48, velocity: 0.9)
        now += 0.01
        seq.touchOn(11, pitchSemis: 55, velocity: 0.9)   // chord mate
        seq.touchOff(10)
        seq.touchOff(11)
        XCTAssertEqual(calls, [.on(10, 48, 0.9), .on(11, 55, 0.9),
                               .off(10), .off(11)])
    }

    // MARK: Wire plumbing

}
