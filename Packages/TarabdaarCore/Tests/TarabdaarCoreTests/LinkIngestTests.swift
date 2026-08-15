import XCTest
@testable import TarabdaarCore

/// Guards for the Mac-side frame diff (LinkIngest) and the iPad-side
/// outbound snapshot (OutboundPlayState): the state-frame lifecycle model
/// — offs from absence, ons from presence, retriggers from onsetSeq — and
/// the end-to-end property the redesign exists for: a coalesced stream can
/// never lose a release, and onset+pitch arrive in ONE call (the tanpura
/// atomic-pluck contract).
final class LinkIngestTests: XCTestCase {

    private final class RecordingSink: LinkPerformanceSink {
        enum Call: Equatable, Hashable {
            case on(UInt16, Double, Double)
            case glide(UInt16, Double)
            case off(UInt16)
            case allOff
            case drone(Int, Bool)
        }
        var calls: [Call] = []
        func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double) {
            calls.append(.on(id, pitchSemis, velocity))
        }
        func touchGlide(_ id: UInt16, pitchSemis: Double) {
            calls.append(.glide(id, pitchSemis))
        }
        func touchOff(_ id: UInt16) { calls.append(.off(id)) }
        func touchesAllOff() { calls.append(.allOff) }
        func setDronePressed(_ index: Int, _ pressed: Bool) {
            calls.append(.drone(index, pressed))
        }
    }

    private func frame(seq: UInt16, touches: [TLPTouch], drones: UInt8 = 0,
                       tilt: (Int16, Int16, Int16) = (0, 0, 0)) -> TLPPerfState {
        TLPPerfState(stateSeq: seq, timestampUs: 0,
                     tiltX: tilt.0, tiltY: tilt.1, tiltZ: tilt.2,
                     droneMask: drones, touches: touches)
    }

    private func touch(_ id: UInt16, onset: UInt8 = 0, vel: UInt8 = 255,
                       pitch: Float) -> TLPTouch {
        TLPTouch(id: id, onsetSeq: onset, velocity: vel, pitch: pitch)
    }

    func testOnsetCarriesPitchAtomically() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [touch(1, pitch: 62.37)]))
        // ONE call, onset + exact pitch together — the property the MIDI
        // path's pending-pluck hack existed to fake.
        XCTAssertEqual(sink.calls, [.on(1, Double(Float(62.37)), 1.0)])
    }

    func testOffFromAbsenceThenGlideOrder() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [touch(1, pitch: 60), touch(2, pitch: 64)]))
        sink.calls.removeAll()
        // 1 lifts, 2 glides, 3 lands — offs must precede ons/glides.
        ingest.apply(frame(seq: 2, touches: [touch(2, pitch: 64.5), touch(3, pitch: 67)]))
        XCTAssertEqual(sink.calls, [.off(1), .glide(2, Double(Float(64.5))),
                                    .on(3, 67, 1.0)])
    }

    func testRetriggerViaOnsetSeqSurvivesCoalescing() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [touch(1, onset: 5, pitch: 60)]))
        sink.calls.removeAll()
        // Same id, new onsetSeq = an off+on collapsed into one frame.
        ingest.apply(frame(seq: 2, touches: [touch(1, onset: 6, pitch: 60)]))
        XCTAssertEqual(sink.calls, [.on(1, 60, 1.0)])
    }

    func testCoalescedReleaseNeverLost() {
        // Sender-side coalescing (LinkOutbox) + receiver diff: a frame
        // burst on→(off dropped by coalescing)→empty must still release.
        let box = LinkOutbox()
        box.enqueue(.perfState(frame(seq: 1, touches: [touch(1, pitch: 60)])))
        box.enqueue(.perfState(frame(seq: 2, touches: [])))   // replaces frame 1
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        while let item = box.dequeue() {
            if case .perfState(let s)? = TLPFrame.decode(item.bytes) {
                ingest.apply(s)
            }
        }
        // The on was coalesced away entirely — and correctly nothing fires:
        // the newest frame IS the truth (no stuck note, nothing to release).
        XCTAssertEqual(sink.calls, [])

        // And when the on DID make it out, the empty frame releases it.
        let sink2 = RecordingSink()
        let ingest2 = LinkIngest(sink: sink2)
        ingest2.apply(frame(seq: 1, touches: [touch(1, pitch: 60)]))
        ingest2.apply(frame(seq: 2, touches: []))
        XCTAssertEqual(sink2.calls, [.on(1, 60, 1.0), .off(1)])
    }

    func testDroneMaskEdges() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [], drones: 0b011))
        XCTAssertEqual(sink.calls, [.drone(0, true), .drone(1, true)])
        sink.calls.removeAll()
        ingest.apply(frame(seq: 2, touches: [], drones: 0b100))
        XCTAssertEqual(Set(sink.calls), Set([.drone(0, false), .drone(1, false),
                                             .drone(2, true)]))
        sink.calls.removeAll()
        ingest.apply(frame(seq: 3, touches: [], drones: 0b100))   // heartbeat
        XCTAssertEqual(sink.calls, [])
    }

    func testTiltChangeGatedAndHeartbeatDeduped() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        var tilts: [(Int, Double)] = []
        ingest.onTiltAxis = { tilts.append(($0, $1)) }
        ingest.apply(frame(seq: 1, touches: [], tilt: (0, -32767, 32767)))
        XCTAssertEqual(tilts.count, 3)
        XCTAssertEqual(tilts[0].1, 0.5, accuracy: 1e-4)
        XCTAssertEqual(tilts[1].1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(tilts[2].1, 1.0, accuracy: 1e-9)
        tilts.removeAll()
        ingest.apply(frame(seq: 2, touches: [], tilt: (0, -32767, 32767)))
        XCTAssertEqual(tilts.count, 0, "heartbeat repeat must not re-fire")
        ingest.apply(frame(seq: 3, touches: [], tilt: (100, -32767, 32767)))
        XCTAssertEqual(tilts.count, 1)
        XCTAssertEqual(tilts[0].0, 0)
    }

    func testLinkDropKillsOnlyItsOwnTouches() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [touch(1, pitch: 60), touch(2, pitch: 64)],
                           drones: 0b101))
        sink.calls.removeAll()
        ingest.linkDidDrop()
        // SURGICAL: exactly the wire's touches + held drones, never a
        // global all-off (which would kill the Mac's local-pad notes).
        XCTAssertFalse(sink.calls.contains(.allOff))
        XCTAssertEqual(Set(sink.calls), Set([.off(1), .off(2),
                                             .drone(0, false), .drone(2, false)]))
        // Reconnect: the first frame is a full resync by construction.
        sink.calls.removeAll()
        ingest.apply(frame(seq: 1, touches: [touch(9, pitch: 65)]))
        XCTAssertEqual(sink.calls.last, .on(9, 65, 1.0))
        // A second drop with nothing held is a no-op beyond the offs.
        ingest.linkDidDrop()
        ingest.linkDidDrop()
        XCTAssertEqual(sink.calls.filter { $0 == .off(9) }.count, 1)
    }

    // MARK: OutboundPlayState → frame → ingest, end to end

    func testOutboundLifecycleEndToEnd() {
        let out = OutboundPlayState()
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        func pump() {
            if let f = out.snapshotFrame(timestampUs: 0) { ingest.apply(f) }
        }
        out.touchOn("fingerA", pitchSemis: 60.25, velocity: 0.5)
        pump()
        out.touchGlide("fingerA", pitchSemis: 60.75)
        out.setDrone(2, true)
        pump()
        out.touchOff("fingerA")
        pump()
        pump()   // clean: no frame
        guard sink.calls.count == 4 else {
            return XCTFail("expected 4 calls, got \(sink.calls)")
        }
        guard case .on(let id, let p0, let v) = sink.calls[0] else {
            return XCTFail("first call not an onset: \(sink.calls)")
        }
        XCTAssertEqual(p0, Double(Float(60.25)))
        XCTAssertEqual(v, 128.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(sink.calls[1], .glide(id, Double(Float(60.75))))
        XCTAssertEqual(sink.calls[2], .drone(2, true))
        XCTAssertEqual(sink.calls[3], .off(id))
    }

    func testOutboundRapidRetapReadsAsRetrigger() {
        let out = OutboundPlayState()
        out.touchOn("a", pitchSemis: 60, velocity: 1)
        let f1 = out.snapshotFrame(timestampUs: 0)!
        // off + on between snapshots — collapses into one frame
        out.touchOff("a")
        out.touchOn("b", pitchSemis: 60, velocity: 1)
        let f2 = out.snapshotFrame(timestampUs: 0)!
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(f1)
        ingest.apply(f2)
        // New wire id ⇒ old off + new on, in that order.
        XCTAssertEqual(sink.calls.count, 3)
        guard case .on = sink.calls[0], case .off = sink.calls[1],
              case .on = sink.calls[2] else {
            return XCTFail("bad sequence: \(sink.calls)")
        }
    }

    func testOutboundHeartbeatForceEmitsWhenClean() {
        let out = OutboundPlayState()
        XCTAssertNil(out.snapshotFrame(timestampUs: 0))
        XCTAssertNotNil(out.snapshotFrame(timestampUs: 0, force: true))
    }

    func testOutboundStateSeqMonotonic() {
        let out = OutboundPlayState()
        out.touchOn("a", pitchSemis: 60, velocity: 1)
        let s1 = out.snapshotFrame(timestampUs: 0)!.stateSeq
        out.touchOff("a")
        let s2 = out.snapshotFrame(timestampUs: 0)!.stateSeq
        XCTAssertTrue(TLP.isNewer(s2, than: s1))
    }
}
