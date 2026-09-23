import XCTest
@testable import TarabdaarCore

/// TLP wire format: frames round-trip byte-exactly, truncation never decodes,
/// the 7-in-8 SysEx envelope round-trips, sequence comparison is wrap-aware,
/// and the outbox never drops, reorders or stales an event.
final class TLPCodecTests: XCTestCase {

    private func samplePerf(touches: Int) -> TLPPerfState {
        var list: [TLPTouch] = []
        for i in 0..<touches {
            let pitch: Float = 60.0 + Float(i) * 1.01
            list.append(TLPTouch(id: UInt16(i * 7 + 1), onsetSeq: UInt8(i),
                                 radius: UInt8(i * 3),   // v13: fingertip size
                                 pitch: pitch, fretPosition: UInt16(i * 6500)))
        }
        return TLPPerfState(
            flags: TLPPerfState.flagBackgrounded,
            stateSeq: 0xBEEF, timestampUs: 0xDEAD_BEEF,
            tiltX: -32767, tiltY: 0, tiltZ: 32767,
            accelX: 1234, accelY: -32767, accelZ: 32767,
            droneMask: 0b101, strike: 0xA7, touches: list)
    }

    private var sampleFrames: [TLPFrame] {
        [
            .perfState(samplePerf(touches: 0)),
            .perfState(samplePerf(touches: 5)),
            .perfState(samplePerf(touches: 10)),
            .joyConState(TLPJoyConState(
                flags: TLPJoyConState.flagConnected, stateSeq: 1,
                timestampUs: 42, stickX: 0, stickY: 255, wrist1: 127, wrist2: 128)),
            .joyConState(TLPJoyConState(
                flags: TLPJoyConState.flagArmLive | TLPJoyConState.flagBodyLive,
                stateSeq: 2, timestampUs: 43, stickX: 128, stickY: 128,
                wrist1: 0, wrist2: 255, wrist3: 1, arm1: 254, arm2: 2,
                arm3: 200, strikeWin: 40,        // v7: 2 s in 50 ms units
                volVoice: 173, volTaraf: 91,     // v9: volume readout
                fieldWarp: 201,                  // v10: fret pitch warp
                octave: UInt8(bitPattern: -3),   // v11: octave shift (i8)
                wristRate1: 10, wristRate2: 128, wristRate3: 250,
                accel1: 3, accel2: 129, accel3: 255,
                accelLevel: 77,
                noteControls: TLPNoteControls(active: true, expression: 255,
                                              pressure: 127, position: 0))),
            .event(seq: 0, .hello(minVer: 1, maxVer: 1, role: .pad)),
            .event(seq: 1, .hello(minVer: 1, maxVer: 3, role: .host)),
            .event(seq: 999, .ping(id: 7, t1: 123_456)),
            .event(seq: 1000, .pong(id: 7, t1: 123_456, t2: 9_999_999)),
            .event(seq: 65535, .panic),
            .event(seq: 2, .resyncRequest),
            .event(seq: 6, .tarafBank(.init(revision: 0xFEDCBA98, tonic: 261.63,
                rows: [.init(id: 3, frequency: 561, flags: 1),
                       .init(id: 0, frequency: 130.815), .init(id: 4, frequency: 220, flags: 2)]))),
            .event(seq: 7, .tarafPluck(revision: 0xFEDCBA98, row: 3)),
            .event(seq: 3, .scaleState(blob: [])),
            .event(seq: 4, .scaleState(blob: Array(0...255))),
            .event(seq: 5, .fretArrangement(blob: [0xF0, 0x7F, 0x80, 0xFF, 0x00])),
        ]
    }

    /// Every frame type survives encode → decode unchanged and fits the cap.
    func testRoundTripAllFrameTypes() {
        for frame in sampleFrames {
            let bytes = frame.encode()
            XCTAssertLessThanOrEqual(bytes.count, TLP.maxFrameBytes)
            XCTAssertEqual(TLPFrame.decode(bytes), frame, "round-trip failed for \(frame)")
        }
    }

    /// Ten-byte touch records preserve radius and its quarter-point encoding.
    func testTouchRadiusRoundTrip() {
        let frame = TLPFrame.perfState(samplePerf(touches: 4))
        guard case .perfState(let back)? = TLPFrame.decode(frame.encode()) else {
            return XCTFail("perf state did not decode")
        }
        XCTAssertEqual(back.touches.map(\.radius), [0, 3, 6, 9])
        // header (1+1+2+4 + 6·2 + 1+1+1+1 + 1 = 25) + 10 per touch
        XCTAssertEqual(frame.encode().count, 25 + 4 * 10)

        XCTAssertEqual(TLPTouch.radiusByte(points: 0), 0)
        XCTAssertEqual(TLPTouch.radiusByte(points: -3), 0)
        XCTAssertEqual(TLPTouch.radiusByte(points: 5.25), 21)
        XCTAssertEqual(TLPTouch.radiusByte(points: 1000), 255)
        XCTAssertEqual(TLPTouch.radiusPoints(21), 5.25, accuracy: 1e-12)
        XCTAssertEqual(TLPTouch(id: 1, onsetSeq: 0,
                                radius: 92, pitch: 60).radiusPoints,
                       23.0, accuracy: 1e-12)
    }

    /// A truncated frame decodes to nothing, never to a plausible one.
    func testTruncationNeverDecodes() {
        for frame in sampleFrames {
            let bytes = frame.encode()
            for cut in 0..<bytes.count {
                XCTAssertNil(TLPFrame.decode(Array(bytes.prefix(cut))),
                             "prefix \(cut) of \(frame) decoded")
            }
        }
    }

    /// Sequence comparison is wrap-aware over the 16-bit space.
    func testSeqIsNewerWrapAware() {
        XCTAssertTrue(TLP.isNewer(1, than: 0))
        XCTAssertFalse(TLP.isNewer(0, than: 0))
        XCTAssertFalse(TLP.isNewer(0, than: 1))
        XCTAssertTrue(TLP.isNewer(0, than: 65535))      // wrap
        XCTAssertTrue(TLP.isNewer(100, than: 65500))    // wrap window
        XCTAssertFalse(TLP.isNewer(65500, than: 100))
    }

    /// The 7-in-8 packing round-trips at every length and the SysEx envelope
    /// stamps its sender role, keeping every interior byte 7-bit clean.
    func testEnvelopeAndPackRoundTrip() {
        for len in 0...64 {
            let payload = (0..<len).map { i in
                UInt8(truncatingIfNeeded: i &* 37 &+ 129)
            }
            let packed = TLPPack.pack(payload)
            XCTAssertTrue(packed.allSatisfy { $0 & 0x80 == 0 }, "len \(len) not 7-bit clean")
            XCTAssertEqual(TLPPack.unpack(packed[...]), payload, "len \(len)")
        }
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

    /// OUTBOX DISCIPLINE: events are never dropped or reordered behind a state
    /// frame, while state frames coalesce per type, latest wins — so a
    /// coalesced queue can never lose the release-carrying frame.
    func testOutboxDiscipline() {
        let box = LinkOutbox()
        box.enqueue(.event(seq: 0, .panic))
        box.enqueue(.perfState(samplePerf(touches: 1)))
        box.enqueue(.event(seq: 1, .resyncRequest))
        box.enqueue(.event(seq: 2, .ping(id: 1, t1: 0)))
        var seen: [UInt8] = []
        while let item = box.dequeue() { seen.append(item.bytes[0]) }
        XCTAssertEqual(seen, [TLP.typePanic, TLP.typePerfState,
                              TLP.typeResyncRequest, TLP.typePing])

        let box2 = LinkOutbox()
        let old = samplePerf(touches: 2)
        var newer = samplePerf(touches: 0)   // the release-carrying frame
        newer.stateSeq = old.stateSeq &+ 1
        box2.enqueue(.perfState(old))
        box2.enqueue(.joyConState(TLPJoyConState(flags: 0, stateSeq: 0, timestampUs: 0,
                                                 stickX: 0, stickY: 0, wrist1: 0, wrist2: 0)))
        box2.enqueue(.perfState(newer))
        XCTAssertEqual(box2.count, 2)
        let frames = [box2.dequeue()!, box2.dequeue()!]
        let perf = frames.first { $0.stateType == TLP.typePerfState }!
        XCTAssertEqual(TLPFrame.decode(perf.bytes), .perfState(newer))
    }
}
