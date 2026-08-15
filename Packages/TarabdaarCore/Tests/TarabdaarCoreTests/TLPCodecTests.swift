import XCTest
@testable import TarabdaarCore

/// TLP wire-format guards: every frame round-trips byte-exactly, every
/// truncated prefix decodes to nil without trapping, and the 7-in-8 SysEx
/// envelope survives arbitrary payloads.
final class TLPCodecTests: XCTestCase {

    private func samplePerf(touches: Int) -> TLPPerfState {
        var list: [TLPTouch] = []
        for i in 0..<touches {
            let pitch: Float = 60.0 + Float(i) * 1.01
            list.append(TLPTouch(id: UInt16(i * 7 + 1), onsetSeq: UInt8(i),
                                 velocity: UInt8(200 - i), pressure: UInt8(i * 3),
                                 pitch: pitch))
        }
        return TLPPerfState(
            flags: TLPPerfState.flagBackgrounded,
            stateSeq: 0xBEEF, timestampUs: 0xDEAD_BEEF,
            tiltX: -32767, tiltY: 0, tiltZ: 32767,
            accelX: 1234, accelY: -32767, accelZ: 32767,
            droneMask: 0b101, touches: list)
    }

    private var sampleFrames: [TLPFrame] {
        [
            .perfState(samplePerf(touches: 0)),
            .perfState(samplePerf(touches: 5)),
            .perfState(samplePerf(touches: 10)),
            .joyConState(TLPJoyConState(
                flags: TLPJoyConState.flagConnected, stateSeq: 1,
                timestampUs: 42, stickX: 0, stickY: 255, wrist1: 127, wrist2: 128)),
            .event(seq: 0, .hello(minVer: 1, maxVer: 1, role: .pad)),
            .event(seq: 1, .hello(minVer: 1, maxVer: 3, role: .host)),
            .event(seq: 999, .ping(id: 7, t1: 123_456)),
            .event(seq: 1000, .pong(id: 7, t1: 123_456, t2: 9_999_999)),
            .event(seq: 65535, .panic),
            .event(seq: 2, .resyncRequest),
            .event(seq: 3, .scaleState(blob: [])),
            .event(seq: 4, .scaleState(blob: Array(0...255))),
            .event(seq: 5, .fretArrangement(blob: [0xF0, 0x7F, 0x80, 0xFF, 0x00])),
        ]
    }

    func testRoundTripAllFrameTypes() {
        for frame in sampleFrames {
            let bytes = frame.encode()
            XCTAssertLessThanOrEqual(bytes.count, TLP.maxFrameBytes)
            XCTAssertEqual(TLPFrame.decode(bytes), frame, "round-trip failed for \(frame)")
        }
    }

    func testPerfStateWireSize() {
        // Header 22 B (16 + the v2 accel fields) + 10 B per touch.
        XCTAssertEqual(TLPFrame.perfState(samplePerf(touches: 0)).encode().count, 22)
        XCTAssertEqual(TLPFrame.perfState(samplePerf(touches: 5)).encode().count, 72)
    }

    func testTruncationNeverDecodes() {
        for frame in sampleFrames {
            let bytes = frame.encode()
            for cut in 0..<bytes.count {
                XCTAssertNil(TLPFrame.decode(Array(bytes.prefix(cut))),
                             "prefix \(cut) of \(frame) decoded")
            }
        }
    }

    func testTrailingGarbageRejected() {
        for frame in sampleFrames {
            var bytes = frame.encode()
            bytes.append(0x00)
            XCTAssertNil(TLPFrame.decode(bytes))
        }
    }

    func testUnknownTypesRejected() {
        XCTAssertNil(TLPFrame.decode([0x00]))
        XCTAssertNil(TLPFrame.decode([0x2A, 0x00, 0x00]))       // unknown event
        XCTAssertNil(TLPFrame.decode([0x42, 0x00, 0x00, 0x00])) // unknown state
        XCTAssertNil(TLPFrame.decode([0x60, 0x00]))
    }

    func testHelloBadMagicRejected() {
        var bytes = TLPFrame.event(seq: 0, .hello(minVer: 1, maxVer: 1, role: .pad)).encode()
        bytes[3] ^= 0xFF   // corrupt first magic byte (type + seq16 precede it)
        XCTAssertNil(TLPFrame.decode(bytes))
    }

    func testOversizeFrameRejected() {
        let big = [UInt8](repeating: 0, count: TLP.maxFrameBytes + 1)
        XCTAssertNil(TLPFrame.decode(big))
    }

    func testSeqIsNewerWrapAware() {
        XCTAssertTrue(TLP.isNewer(1, than: 0))
        XCTAssertFalse(TLP.isNewer(0, than: 0))
        XCTAssertFalse(TLP.isNewer(0, than: 1))
        XCTAssertTrue(TLP.isNewer(0, than: 65535))      // wrap
        XCTAssertTrue(TLP.isNewer(100, than: 65500))    // wrap window
        XCTAssertFalse(TLP.isNewer(65500, than: 100))
    }

    // MARK: 7-in-8 + envelope

    func testPackRoundTripAllLengths() {
        for len in 0...64 {
            let payload = (0..<len).map { i in
                UInt8(truncatingIfNeeded: i &* 37 &+ 129)
            }
            let packed = TLPPack.pack(payload)
            XCTAssertTrue(packed.allSatisfy { $0 & 0x80 == 0 }, "len \(len) not 7-bit clean")
            XCTAssertEqual(TLPPack.unpack(packed[...]), payload, "len \(len)")
        }
    }

    func testPackOverheadIs8Over7() {
        XCTAssertEqual(TLPPack.pack([UInt8](repeating: 0xFF, count: 70)).count, 80)
    }

    func testUnpackRejectsHighBitsAndLoneMSB() {
        XCTAssertNil(TLPPack.unpack([0x80, 0x01][...]))
        XCTAssertNil(TLPPack.unpack([0x00, 0x81][...]))
        XCTAssertNil(TLPPack.unpack([0x00][...]))                    // lone MSB septet
        XCTAssertNil(TLPPack.unpack([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x00][...]))
    }

    func testEnvelopeRoundTrip() {
        for frame in sampleFrames {
            for role in [TLPRole.pad, .host] {
                let bytes = frame.encode()
                let sysex = TLPPack.envelope(bytes, role: role)
                XCTAssertEqual(sysex.first, 0xF0)
                XCTAssertEqual(sysex[1], 0x7D)
                XCTAssertEqual(sysex[2], 0x10)
                XCTAssertEqual(sysex[3], role.rawValue)
                XCTAssertEqual(sysex.last, 0xF7)
                // Every interior byte must be 7-bit clean (SysEx data rule).
                XCTAssertTrue(sysex.dropFirst().dropLast().allSatisfy { $0 & 0x80 == 0 })
                let out = TLPPack.unenvelope(sysex)
                XCTAssertEqual(out?.role, role)
                XCTAssertEqual(out?.frame, bytes)
            }
        }
    }

    func testUnenvelopeRejectsForeignSysEx() {
        XCTAssertNil(TLPPack.unenvelope([0xF0, 0x7D, 0x01, 0x41, 0xF7]))  // legacy scale msg
        XCTAssertNil(TLPPack.unenvelope([0xF0, 0x7E, 0x10, 0x00, 0x00, 0xF7]))
        XCTAssertNil(TLPPack.unenvelope([0xF0, 0x7D, 0x10, 0x00]))        // no terminator
        XCTAssertNil(TLPPack.unenvelope([0xF0, 0x7D, 0x10, 0x07, 0xF7])) // bad role
        XCTAssertNil(TLPPack.unenvelope([]))
    }

    // MARK: outbox discipline

    func testOutboxEventsNeverDropOrReorder() {
        let box = LinkOutbox()
        box.enqueue(.event(seq: 0, .panic))
        box.enqueue(.perfState(samplePerf(touches: 1)))
        box.enqueue(.event(seq: 1, .resyncRequest))
        box.enqueue(.event(seq: 2, .ping(id: 1, t1: 0)))
        var seen: [UInt8] = []
        while let item = box.dequeue() { seen.append(item.bytes[0]) }
        XCTAssertEqual(seen, [TLP.typePanic, TLP.typePerfState,
                              TLP.typeResyncRequest, TLP.typePing])
    }

    func testOutboxStateCoalescesPerTypeLatestWins() {
        let box = LinkOutbox()
        let old = samplePerf(touches: 2)
        var newer = samplePerf(touches: 0)   // the release-carrying frame
        newer.stateSeq = old.stateSeq &+ 1
        box.enqueue(.perfState(old))
        box.enqueue(.joyConState(TLPJoyConState(flags: 0, stateSeq: 0, timestampUs: 0,
                                                stickX: 0, stickY: 0, wrist1: 0, wrist2: 0)))
        box.enqueue(.perfState(newer))
        XCTAssertEqual(box.count, 2)
        // The surviving perf frame must be the NEWER one — a coalesced
        // queue can never lose a release.
        let frames = [box.dequeue()!, box.dequeue()!]
        let perf = frames.first { $0.stateType == TLP.typePerfState }!
        XCTAssertEqual(TLPFrame.decode(perf.bytes), .perfState(newer))
    }

    func testOutboxLaneSwitchKeepsEventsDropsState() {
        let box = LinkOutbox()
        box.enqueue(.event(seq: 9, .panic))
        box.enqueue(.perfState(samplePerf(touches: 3)))
        box.removeAllState()
        XCTAssertEqual(box.pendingEvents.count, 1)
        XCTAssertEqual(box.count, 1)
        XCTAssertEqual(box.dequeue()?.bytes.first, TLP.typePanic)
    }

    // MARK: clock

    func testClockSyncOffsetAndRTT() {
        var sync = LinkClockSync(windowSize: 1)
        // Remote clock runs 500 µs ahead; RTT 10 ms symmetric.
        sync.addPong(t1: 1_000, t2: 6_500, t3: 11_000)
        XCTAssertEqual(sync.rttUs, 10_000)
        XCTAssertEqual(sync.offsetUs, 500)
        let age = sync.frameAgeUs(timestampUs: 20_500, nowUs: 25_000)
        XCTAssertEqual(age, 5_000)   // sent at local 20_000, now 25_000
    }

    func testClockSyncSurvivesWrap() {
        var sync = LinkClockSync(windowSize: 1)
        let t1 = UInt32.max - 2_000
        sync.addPong(t1: t1, t2: 3_000, t3: t1 &+ 8_000)
        XCTAssertEqual(sync.rttUs, 8_000)
        // Local mid = t1 &+ 4000, which wraps to 1999; offset = 3000 − 1999.
        XCTAssertEqual(sync.offsetUs, 1_001)
        // Frame stamped remote 4000 = local 2999; now = local 6999 → age 4000.
        let age = sync.frameAgeUs(timestampUs: 3_000 &+ 1_000,
                                  nowUs: (t1 &+ 8_000) &+ 1_000)
        XCTAssertEqual(age, 4_000)
    }
}
