import XCTest
@testable import TarabdaarCore

/// TarabLink: the hello handshake with its epoch reset, own-echo rejection,
/// event dedupe, and pad → host end to end.
final class TarabLinkTests: XCTestCase {

    private func envelope(_ frame: TLPFrame, from role: TLPRole = .pad) -> [UInt8] {
        TLPPack.envelope(frame.encode(), role: role)
    }

    /// A MIDI loop echoes a side's own frames back at it: a looped hello must
    /// never mark the link up, and looped events must not consume the
    /// sequence gate the real peer's low seqs then need.
    func testOwnEchoedTrafficIgnored() {
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

    /// A peer hello brings the link up and is greeted back with our own role;
    /// duplicate and stale event seqs are dropped, and a peer restart's hello
    /// re-anchors the epoch so its small seqs are accepted again.
    func testHelloHandshakeAndEventDedupe() {
        let host = TarabLink(role: .host)
        var sent: [[UInt8]] = []
        host.sendRaw = { bytes, _ in sent.append(bytes) }
        var events: [TLPEvent] = []
        host.onEvent = { events.append($0) }
        XCTAssertFalse(host._testStatus.isUp)
        host._testProcess(envelope(.event(seq: 10, .hello(minVer: TLP.versionMin, maxVer: TLP.versionMax,
                                                          role: .pad))))
        XCTAssertTrue(host._testStatus.isUp)
        // the greet-back went out as a TLP hello, stamped with OUR role
        XCTAssertTrue(sent.allSatisfy { TLPPack.unenvelope($0)?.role == .host })
        XCTAssertTrue(sent.compactMap { TLPPack.unenvelope($0)?.frame }
            .compactMap(TLPFrame.decode).contains {
                if case .event(_, .hello(_, _, .host)) = $0 { return true }
                return false
            })
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

    /// The whole tunnel minus CoreMIDI: a real `OutboundPlayState` through the
    /// pad's paced tick arrives at the host's ingest as one on and one off.
    func testPadToHostEndToEnd() {
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
