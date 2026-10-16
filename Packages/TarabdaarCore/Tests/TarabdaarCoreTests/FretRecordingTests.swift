import XCTest
@testable import TarabdaarCore

final class FretRecordingTests: XCTestCase {
    private func context() -> FretGestureCapture.Context {
        .init(frets: [.init(id: "ipad-fret", log2Ratio: 0, x: 128, topY: 0,
                           bottomY: 64, ghost: false, row: 9)],
              snapDistance: 24, ghostExtentOctaves: 0.9, width: 1024, height: 576,
              assistParams: ["amount": 1, "fieldWarp": 0.5])
    }

    private func drain(_ outbox: FretRecordingOutbox) throws -> [TLPEvent] {
        var events: [TLPEvent] = []
        while let event = outbox.next() {
            let frame = TLPFrame.event(seq: UInt16(events.count), event)
            guard case .event(_, let decoded) = try XCTUnwrap(TLPFrame.decode(frame.encode())) else {
                XCTFail("expected event"); return []
            }
            events.append(decoded)
        }
        return events
    }

    /// iPad strokes keep the fitting format and finish saving on the Mac after Rec stops.
    func testRemoteStrokePreservesGeometryAndFlushesBeforeClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FretGestureRecorder(directory: directory)
        let pad = FretRecordingPad()
        let outbox = FretRecordingOutbox()
        let receiver = FretRecordingReceiver()
        pad.onStroke = { outbox.append(session: $0, data: $1) }
        pad.onSessionChange = { previous, current in
            if current == 0 { outbox.finish(session: previous) }
            else { outbox.reset() }
        }
        recorder.setRecording(true)
        receiver.reset(session: 42)
        pad.setSession(42)
        pad.capture.begin(touchId: 5, context: context(), offset: 0.02,
                          x: 127, y: 12, u: 0.01, o: 0.02, time: 10)
        pad.setSession(42) // Resync must not erase an in-flight stroke.
        pad.capture.sample(touchId: 5, x: 140, y: 15, u: 0.03, o: 0.04, time: 10.1)
        pad.capture.sampleTick(touchId: 5, u: 0.03, o: 0.05, time: 10.2)
        pad.capture.end(touchId: 5, time: 10.3)
        recorder.stop(waitForRemote: true)
        pad.stopSession(42)
        var finished = false
        for event in try drain(outbox) {
            switch event {
            case .fretRecordingChunk(let chunk):
                XCTAssertFalse(finished)
                if let data = receiver.receive(chunk) { recorder.appendRemote(data) }
            case .fretRecording(let session, let active):
                XCTAssertFalse(active)
                XCTAssertEqual(session, 42)
                XCTAssertEqual(recorder.strokeCount, 1)
                recorder.finish()
                finished = true
            default: XCTFail("unexpected event")
            }
        }
        XCTAssertTrue(finished)
        pad.stopSession(42)
        XCTAssertEqual(try drain(outbox), [.fretRecording(session: 42, recording: false)],
                       "a retried stop must recover a lost completion fence")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let data = try Data(contentsOf: XCTUnwrap(files.first))
        let record = try JSONDecoder().decode(FretGestureCapture.StrokeRecord.self, from: data)
        XCTAssertEqual(record.v, 7)
        XCTAssertEqual(record.ctx.width, 1024)
        XCTAssertEqual(record.ctx.frets.first?.id, "ipad-fret")
        XCTAssertEqual(record.ctx.assistParams["fieldWarp"], 0.5)
        XCTAssertEqual(record.offset, 0.02)
        XCTAssertEqual(record.events.map { $0.count }, [21, 21, 21])
        XCTAssertEqual(record.events.map { $0[0] }, [0, 0.1, 0.2])
        XCTAssertEqual(record.events.map { $0[1] }, [127, 140, 140])
        XCTAssertEqual(record.events.map { $0[5] }, [0, 0, 1])
        XCTAssertEqual(record.endT, 0.3, accuracy: 1e-9)
        recorder.appendRemote(data)
        XCTAssertEqual(recorder.strokeCount, 1, "closed sessions must reject late records")
    }

    /// Stop still acknowledges its token when the arm command was lost.
    func testStopWithoutAnArmCommandStillCompletes() {
        let pad = FretRecordingPad()
        var stopped: [UInt32] = []
        pad.onSessionChange = { token, next in if next == 0 { stopped.append(token) } }
        pad.stopSession(73)
        XCTAssertEqual(stopped, [73])
        XCTAssertFalse(pad.capture.isRecording)
    }

    /// The live tunnel sends performance before recording chunks and closes only after the data.
    func testLinkPrioritizesPerformanceBeforeRecordingAndCompletion() {
        let link = TarabLink(role: .pad)
        let state = OutboundPlayState()
        link.attach(playState: state)
        var sent: [TLPFrame] = []
        link.sendRaw = { bytes, _ in
            if let raw = TLPPack.unenvelope(bytes)?.frame,
               let frame = TLPFrame.decode(raw) { sent.append(frame) }
        }
        let hello = TLPFrame.event(seq: 1,
            .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax, role: .host))
        link._testProcess(TLPPack.envelope(hello.encode(), role: .host))
        let bytes = Data((0..<128).map(UInt8.init))
        let receiver = FretRecordingReceiver()
        receiver.reset(session: 6)
        link.sendRecording(session: 6, data: bytes)
        link.finishRecordings(session: 6)
        state.touchOn("finger", pitchSemis: 60)
        var received: [Data] = []
        var finished = false
        for tick in 0..<16 {
            sent.removeAll()
            state.touchGlide("finger", pitchSemis: 60 + Double(tick) / 10)
            link._testTick()
            guard case .perfState = sent.first else {
                XCTFail("recording must never preempt the latest performance frame")
                return
            }
            for frame in sent {
                if case .event(_, .fretRecordingChunk(let chunk)) = frame {
                    XCTAssertFalse(finished)
                    if let data = receiver.receive(chunk) { received.append(data) }
                } else if case .event(_, .fretRecording(let session, let active)) = frame {
                    XCTAssertEqual(session, 6)
                    XCTAssertFalse(active)
                    XCTAssertEqual(received, [bytes])
                    finished = true
                }
            }
        }
        XCTAssertTrue(finished)
    }

    /// Missing chunks and old sessions never become partial or duplicate fitting records.
    func testReassemblyRejectsGapsDuplicatesAndOldSessions() throws {
        var seed: UInt32 = 1
        let bytes = Data((0..<8192).map { _ -> UInt8 in
            seed = seed &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: seed >> 24)
        })
        let outbox = FretRecordingOutbox()
        outbox.append(session: 7, data: bytes)
        let chunks = try drain(outbox).compactMap { event -> FretRecordingChunk? in
            if case .fretRecordingChunk(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertGreaterThan(chunks.count, 3)
        let receiver = FretRecordingReceiver()
        receiver.reset(session: 7)
        for (index, chunk) in chunks.enumerated() where index != 1 {
            XCTAssertNil(receiver.receive(chunk))
        }
        var completed: [Data] = []
        for chunk in chunks { if let data = receiver.receive(chunk) { completed.append(data) } }
        XCTAssertEqual(completed, [bytes])
        for chunk in chunks { XCTAssertNil(receiver.receive(chunk)) }
        receiver.reset(session: 8)
        for chunk in chunks { XCTAssertNil(receiver.receive(chunk)) }
    }

    /// A dropped link discards partial capture and a new session starts at the next onset.
    func testDisconnectDoesNotCarryAnOldStrokeIntoANewSession() {
        let pad = FretRecordingPad()
        var records: [Data] = []
        pad.onStroke = { _, data in records.append(data) }
        pad.setSession(1)
        pad.capture.begin(touchId: 9, context: context(), offset: 0,
                          x: 128, y: 12, u: 0, o: 0, time: 0)
        pad.linkDropped()
        pad.setSession(2)
        pad.capture.sample(touchId: 9, x: 130, y: 12, u: 0.1, o: 0.1, time: 1)
        pad.capture.end(touchId: 9, time: 2)
        XCTAssertTrue(records.isEmpty)
    }

    /// Cached sync never hides a lost link or a connection awaiting either sync payload.
    func testStatusRequiresBothPayloadsOnTheCurrentConnection() {
        var status = PadConnectionState()
        status.appliedScale()
        status.appliedArrangement()
        XCTAssertFalse(status.isSynced)
        status.setConnected(true)
        status.appliedScale()
        XCTAssertFalse(status.isSynced)
        status.appliedArrangement()
        XCTAssertTrue(status.isSynced)
        status.setConnected(false)
        XCTAssertFalse(status.isSynced)
        status.setConnected(true)
        status.appliedArrangement()
        XCTAssertFalse(status.isSynced)
        status.appliedScale()
        XCTAssertTrue(status.isSynced)
    }
}
