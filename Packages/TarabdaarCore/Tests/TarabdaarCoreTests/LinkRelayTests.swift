import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The Mac-side relay glue: the JOYCON_STATE display mirror's frame assembly
/// and the debounced rebuild funnel.
final class LinkRelayTests: XCTestCase {

    /// UI reads preserve intervals, released tails and maxima from every relay poll until reset.
    func testLiveVolumeSnapshotsShareTheRelayPoll() {
        let meter = AudioEngine.PerformanceMeter()
        var interval = (voice: 0.2, chromatic: 0.03, raga: 0.04)
        var samples = 0
        var sent: [[UInt8]] = []
        let relay = VolumeMeterRelay(levels: {
            meter.captureVolume {
                samples += 1
                let captured = interval
                interval = (0, 0, 0)
                return captured
            }
        }, send: { sent.append([$0, $1, $2]) })
        meter.storeTouch((440, true))
        relay.tick()
        XCTAssertEqual(sent.last, [0.2, 0.03, 0.04].map(TLPVolume.byte(fromLinear:)))
        meter.storeTouch((0, false))
        for _ in 0..<20 {
            let reading = meter.readout()
            XCTAssertFalse(reading.active)
            XCTAssertEqual(reading.voiceRMS, 0.2)
            XCTAssertEqual(reading.chromaticRMS, 0.03)
            XCTAssertEqual(reading.ragaRMS, 0.04)
            XCTAssertEqual(reading.maximumVoiceRMS, 0.2)
            XCTAssertEqual(reading.maximumChromaticRMS, 0.03)
            XCTAssertEqual(reading.maximumRagaRMS, 0.04)
        }
        XCTAssertEqual(samples, 1, "UI reads must not steal the next audio interval")
        interval.voice = 0.1
        interval.chromatic = 0.4
        relay.tick()
        XCTAssertEqual(meter.readout().voiceRMS, 0.1)
        // A bloom between UI reads must survive the next silent interval.
        relay.tick()
        XCTAssertEqual(meter.readout().voiceRMS, 0)
        XCTAssertEqual(meter.readout().chromaticRMS, 0)
        XCTAssertEqual(meter.readout().ragaRMS, 0)
        XCTAssertEqual(sent.last, [0, 0, 0])
        XCTAssertEqual(samples, 3)
        XCTAssertEqual(meter.readout().maximumVoiceRMS, 0.2)
        XCTAssertEqual(meter.readout().maximumChromaticRMS, 0.4)
        XCTAssertEqual(meter.readout().maximumRagaRMS, 0.04)
        interval = (0.05, 0.1, 0.02)
        relay.tick()
        meter.resetMaxima()
        XCTAssertEqual(meter.readout().maximumVoiceRMS, 0)
        XCTAssertEqual(meter.readout().maximumChromaticRMS, 0)
        XCTAssertEqual(meter.readout().maximumRagaRMS, 0)
        XCTAssertEqual(meter.readout().chromaticRMS, 0.1, "Reset must not consume the current reading")
        interval = (0.01, 0.02, 0.03)
        relay.tick()
        XCTAssertEqual(meter.readout().maximumVoiceRMS, 0.01)
        XCTAssertEqual(meter.readout().maximumChromaticRMS, 0.02)
        XCTAssertEqual(meter.readout().maximumRagaRMS, 0.03)
    }

    /// Each bank independently triggers the relay and silence clears all three readings.
    func testVolumeBanksRelayIndependently() {
        var levels = (voice: 0.1, chromatic: 0.01, raga: 0.001)
        var sent: [[UInt8]] = []
        let relay = VolumeMeterRelay(levels: { levels }, send: { sent.append([$0, $1, $2]) })
        relay.tick()
        XCTAssertEqual(sent.last, [levels.voice, levels.chromatic, levels.raga].map(TLPVolume.byte(fromLinear:)))
        relay.tick()
        XCTAssertEqual(sent.count, 1)
        levels.chromatic = 0.02
        relay.tick()
        XCTAssertEqual(sent.count, 2)
        levels.raga = 0.03
        relay.tick()
        XCTAssertEqual(sent.count, 3)
        levels = (0, 0, 0)
        relay.tick()
        XCTAssertEqual(sent.last, [0, 0, 0])
    }

    /// The note readout follows pitch, includes per-note expression, and clears despite silent volume.
    func testHighestNoteControlReadout() {
        let mapper = BowControlMapper()
        mapper.setSlotLimit(4)
        mapper.setAxis(expr: 0.8, press: 0.6, pos: 0.3)
        var sent: [TLPNoteControls] = []
        let relay = VolumeMeterRelay(levels: { (0, 0, 0) }, send: { _, _, _ in },
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

        var assist = FretAssistSettings()
        assist[.amount] = 0.25
        assist[.dwell] = 321
        relay.fretAssist = { assist }
        relay.push()
        XCTAssertFalse(sent.last?.1 ?? true, "continuous assist mappings use the paced state lane")
        let wire = relay.frame().frame(stateSeq: 1, timestampUs: 0,
                                      volVoice: 0, volChromatic: 0, volRaga: 0)
        XCTAssertEqual(JoyConTiltDisplay(frame: wire).fretAssist, assist)
        relay.resend()
        XCTAssertEqual(sent.last?.0.fretAssist, assist)
        XCTAssertTrue(sent.last?.1 ?? false, "resync sends the current resolved controls")

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
