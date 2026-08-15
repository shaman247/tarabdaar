import XCTest
@testable import TarabdaarCore

/// TarabLink logic guards: HELLO as a sequence epoch, event/state dedupe
/// across lane overlap, ping→pong→RTT, and the pad→host path end to end
/// through real envelopes (encode → 7-in-8 SysEx → decode → ingest).
final class TarabLinkTests: XCTestCase {

    private func envelope(_ frame: TLPFrame, from role: TLPRole = .pad) -> [UInt8] {
        TLPPack.envelope(frame.encode(), role: role)
    }

    func testHelloBringsLinkUpAndGreetsBack() {
        let host = TarabLink(role: .host)
        var sent: [[UInt8]] = []
        host.sendRaw = { bytes, _ in sent.append(bytes) }
        XCTAssertFalse(host._testStatus.isUp)
        host._testProcess(envelope(.event(seq: 1, .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax,
                                                         role: .pad))))
        XCTAssertTrue(host._testStatus.isUp)
        // The greet-back went out as a TLP hello, stamped with OUR role.
        XCTAssertTrue(sent.allSatisfy { TLPPack.unenvelope($0)?.role == .host })
        let decoded = sent.compactMap { TLPPack.unenvelope($0)?.frame }
            .compactMap(TLPFrame.decode)
        XCTAssertTrue(decoded.contains {
            if case .event(_, .hello(_, _, .host)) = $0 { return true }
            return false
        })
    }

    func testOwnEchoedTrafficIgnored() {
        // A MIDI loop (IAC bus, patchbay, USB+BLE double delivery) can
        // echo a side's own frames back at it. They must be dropped: a
        // looped hello must never mark the link up (it would arm the
        // staleness kill path with no peer), and looped events must not
        // consume the shared sequence gate.
        let host = TarabLink(role: .host)
        host.sendRaw = { _, _ in }
        var events: [TLPEvent] = []
        host.onEvent = { events.append($0) }
        host._testProcess(envelope(.event(seq: 500, .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax,
                                                           role: .host)),
                                   from: .host))
        XCTAssertFalse(host._testStatus.isUp, "own looped hello marked link up")
        host._testProcess(envelope(.event(seq: 501, .scaleState(blob: [1, 2])),
                                   from: .host))
        XCTAssertTrue(events.isEmpty)
        // The real pad's low seqs must still be accepted afterwards.
        host._testProcess(envelope(.event(seq: 1, .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax,
                                                         role: .pad))))
        host._testProcess(envelope(.event(seq: 2, .resyncRequest)))
        XCTAssertTrue(host._testStatus.isUp)
        XCTAssertEqual(events, [.resyncRequest])
    }

    func testVersionMismatchStaysDown() {
        let host = TarabLink(role: .host)
        host.sendRaw = { _, _ in }
        host._testProcess(envelope(.event(seq: 1, .hello(minVer: 99, maxVer: 99,
                                                         role: .pad))))
        XCTAssertFalse(host._testStatus.isUp)
    }

    func testEventDedupeAndHelloEpochReset() {
        let host = TarabLink(role: .host)
        host.sendRaw = { _, _ in }
        var events: [TLPEvent] = []
        host.onEvent = { events.append($0) }
        host._testProcess(envelope(.event(seq: 10, .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax,
                                                          role: .pad))))
        host._testProcess(envelope(.event(seq: 11, .resyncRequest)))
        host._testProcess(envelope(.event(seq: 11, .resyncRequest)))   // dup (lane overlap)
        host._testProcess(envelope(.event(seq: 5, .panic)))            // stale
        XCTAssertEqual(events.count, 1)
        // Peer restarts: small seqs again — hello re-anchors the epoch.
        host._testProcess(envelope(.event(seq: 1, .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax,
                                                         role: .pad))))
        host._testProcess(envelope(.event(seq: 2, .resyncRequest)))
        XCTAssertEqual(events.count, 2)
    }

    func testStateDedupePerType() {
        let host = TarabLink(role: .host)
        host.sendRaw = { _, _ in }
        var frames: [TLPPerfState] = []
        host.onPerfState = { frames.append($0) }
        func perf(_ seq: UInt16) -> TLPFrame {
            .perfState(TLPPerfState(stateSeq: seq, timestampUs: 0, tiltX: 0,
                                    tiltY: 0, tiltZ: 0, droneMask: 0, touches: []))
        }
        host._testProcess(envelope(perf(7)))
        host._testProcess(envelope(perf(7)))   // duplicate
        host._testProcess(envelope(perf(6)))   // stale
        host._testProcess(envelope(perf(8)))
        XCTAssertEqual(frames.map(\.stateSeq), [7, 8])
    }

    func testPingGetsPongAndPongFeedsRTT() {
        let pad = TarabLink(role: .pad)
        var padOut: [[UInt8]] = []
        pad.sendRaw = { bytes, _ in padOut.append(bytes) }
        pad._testProcess(envelope(.event(seq: 1, .ping(id: 3, t1: 12345)), from: .host))
        let pongs = padOut.compactMap { TLPPack.unenvelope($0)?.frame }
            .compactMap(TLPFrame.decode)
            .filter { if case .event(_, .pong(3, 12345, _)) = $0 { return true }
                      return false }
        XCTAssertEqual(pongs.count, 1)

        let host = TarabLink(role: .host)
        host.sendRaw = { _, _ in }
        let now = LinkClock.nowUs()
        host._testProcess(envelope(.event(seq: 1,
                                          .pong(id: 1, t1: now &- 8_000,
                                                t2: now &- 4_000))))
        XCTAssertNotNil(host._testStatus.rttMs)
        XCTAssertLessThan(host._testStatus.rttMs!, 100.0)
    }

    func testPadToHostEndToEnd() {
        // Pad side: real OutboundPlayState through the paced tick.
        let pad = TarabLink(role: .pad)
        let state = OutboundPlayState()
        pad.attach(playState: state)
        // Host side: real ingest into a recording sink.
        final class Sink: LinkPerformanceSink {
            var ons: [(UInt16, Double)] = []
            var offs: [UInt16] = []
            func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double) {
                ons.append((id, pitchSemis))
            }
            func touchGlide(_ id: UInt16, pitchSemis: Double) {}
            func touchOff(_ id: UInt16) { offs.append(id) }
            func touchesAllOff() {}
            func setDronePressed(_ index: Int, _ pressed: Bool) {}
        }
        let sink = Sink()
        let ingest = LinkIngest(sink: sink)
        let host = TarabLink(role: .host)
        host.sendRaw = { _, _ in }
        host.onPerfState = { ingest.apply($0) }
        // Wire pad's sends into host's receive (the tunnel, minus CoreMIDI).
        pad.sendRaw = { bytes, _ in host.receivedSysEx(bytes) }

        state.touchOn("finger", pitchSemis: 61.25, velocity: 0.9)
        pad._testTick()
        state.touchOff("finger")
        pad._testTick()

        // host.receivedSysEx is async on the host queue — flush it.
        host._testTick()
        let deadline = Date().addingTimeInterval(2)
        while sink.offs.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(sink.ons.count, 1)
        XCTAssertEqual(sink.ons.first?.1 ?? 0, Double(Float(61.25)))
        XCTAssertEqual(sink.offs.count, 1)
        XCTAssertEqual(sink.ons.first?.0, sink.offs.first)
    }
}
