import XCTest
@testable import TarabdaarCore

/// TarabLink: hello brings the link up, echoed own traffic is ignored, dedupe with hello-epoch reset, pad → host end to end.
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
