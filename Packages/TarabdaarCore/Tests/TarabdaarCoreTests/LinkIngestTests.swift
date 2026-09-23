import XCTest
import SarangiKit
@testable import TarabdaarCore

/// LinkIngest / OutboundPlayState touch lifecycle: onsets carry their pitch,
/// retriggers and releases survive coalescing, and a drop is surgical.
final class LinkIngestTests: XCTestCase {

    private final class RecordingSink: LinkPerformanceSink {
        enum Call: Equatable, Hashable {
            case on(UInt16, Double)
            case glide(UInt16, Double)
            case off(UInt16)
            case allOff
            case drone(Int, Bool)
            case expr(UInt16, Double)
        }
        var calls: [Call] = []
        var onMount: ((UInt16, Double) -> Void)?
        func touchOn(_ id: UInt16, pitchSemis: Double) {
            calls.append(.on(id, pitchSemis))
            onMount?(id, pitchSemis)
        }
        func touchExpr(_ id: UInt16, exprScale: Double) {
            calls.append(.expr(id, exprScale))
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

    /// Fret position survives the wire, precedes mounting, and follows the newest held finger.
    func testFretPositionMappingLifecycle() throws {
        let state = OutboundPlayState()
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        let evaluator = ControlAxisEvaluator()
        let target = MapTarget(paramKey: "bow_expr")
        var value = -1.0
        var applications = 0
        var mounts: [Double] = []
        evaluator.onApply = { apps in
            for app in apps where app.target == target {
                value = app.value
                applications += 1
            }
        }
        let binding = DimensionBinding(dimension: .fretPosition, rangeMin: 0, rangeMax: 1)
        let decoded = try JSONDecoder().decode(DimensionBinding.self,
            from: JSONEncoder().encode(binding))
        XCTAssertEqual(decoded.dimension.rawValue, 21)
        evaluator.setMapping(DimensionMapping(mappings: [target.storageKey:
            ParameterMapping(bindings: [decoded], defaultValue: 0)]))
        ingest.onTouchGate = { evaluator.touchGate(lane: .wire, id: $0, on: $1) }
        ingest.onTouchFretPosition = {
            evaluator.touchFretPosition(lane: .wire, id: $0, value: $1)
        }
        sink.onMount = { _, _ in mounts.append(value) }
        func send() throws -> TLPPerfState {
            let frame = try XCTUnwrap(state.snapshotFrame(timestampUs: 0))
            guard case .perfState(let decoded)? = TLPFrame.decode(TLPFrame.perfState(frame).encode())
            else { throw NSError(domain: "codec", code: 1) }
            ingest.apply(decoded)
            return decoded
        }
        state.touchOn(1, pitchSemis: 60, fretPosition: 0.2)
        let first = try send()
        XCTAssertEqual(mounts.last ?? -1, 0.2, accuracy: 1 / 65535.0)
        state.touchGlide(1, pitchSemis: 60, fretPosition: 0.8)
        let moved = try send()
        XCTAssertEqual(value, 0.8, accuracy: 1 / 65535.0)
        XCTAssertFalse(sink.calls.contains { if case .glide = $0 { return true }; return false })
        let count = applications
        ingest.apply(moved)
        XCTAssertEqual(applications, count)
        state.touchGlide(1, pitchSemis: 61) // assist ticks retain position
        let retained = try send()
        XCTAssertEqual(retained.touches[0].fretPosition01, 0.8, accuracy: 1 / 65535.0)
        state.touchGlide(1, pitchSemis: 61, fretPosition: 0.8)
        XCTAssertNil(state.snapshotFrame(timestampUs: 0))
        state.touchOn(2, pitchSemis: 64, fretPosition: 1)
        _ = try send()
        XCTAssertEqual(mounts.last, 1)
        state.touchGlide(1, pitchSemis: 61, fretPosition: 0.4)
        _ = try send()
        XCTAssertEqual(value, 1)
        state.touchOff(2)
        _ = try send()
        XCTAssertEqual(value, 0.4, accuracy: 1 / 65535.0)
        // Same numeric id on the other lane is an independent newest finger.
        let id = first.touches[0].id
        evaluator.touchGate(lane: .local, id: id, on: true)
        evaluator.touchFretPosition(lane: .local, id: id, value: 0.7)
        ingest.linkDidDrop()
        XCTAssertEqual(value, 0.7, accuracy: 1e-12)
        evaluator.touchGate(lane: .local, id: id, on: false)
        XCTAssertEqual(value, 0)
    }

    private func frame(seq: UInt16, touches: [TLPTouch], drones: UInt8 = 0,
                       tilt: (Int16, Int16, Int16) = (0, 0, 0)) -> TLPPerfState {
        TLPPerfState(stateSeq: seq, timestampUs: 0,
                     tiltX: tilt.0, tiltY: tilt.1, tiltZ: tilt.2,
                     droneMask: drones, touches: touches)
    }

    private func touch(_ id: UInt16, onset: UInt8 = 0,
                       pitch: Float) -> TLPTouch {
        TLPTouch(id: id, onsetSeq: onset, pitch: pitch)
    }

    /// An onset arrives as ONE call carrying its exact pitch, and a new
    /// `onsetSeq` on a live id retriggers even when the off+on collapsed into
    /// a single coalesced frame.
    func testOnsetCarriesPitchAndRetriggersViaOnsetSeq() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [touch(1, onset: 5, pitch: 62.37)]))
        XCTAssertEqual(sink.calls, [.on(1, Double(Float(62.37)))])
        sink.calls.removeAll()
        ingest.apply(frame(seq: 2, touches: [touch(1, onset: 6, pitch: 62.37)]))
        XCTAssertEqual(sink.calls, [.on(1, Double(Float(62.37)))])
    }

    /// A new note uses its frame's Strike binding even when the envelope byte repeats, and Joy-Con bindings use the same target.
    func testBoundSharpnessPrecedesOnset() {
        let mapper = BowControlMapper()
        mapper.setSlotLimit(3)
        let sink = RecordingSink()
        sink.onMount = { mapper.touchOn($0, pitchSemis: $1) }
        let ingest = LinkIngest(sink: sink)
        let evaluator = ControlAxisEvaluator(now: { 10 })
        let target = MapTarget(paramKey: "bow_attack_sharpness")
        evaluator.onApply = { apps in
            for app in apps where app.target == target { mapper.setAttackSharpness(app.value) }
        }
        func bind(_ dimension: InputDimension) {
            evaluator.setMapping(DimensionMapping(mappings: [target.storageKey:
                ParameterMapping(bindings: [DimensionBinding(dimension: dimension,
                    rangeMin: 0, rangeMax: 1)], defaultValue: 0)]))
        }
        defer { evaluator.setMapping(DimensionMapping(mappings: [:])) }
        bind(.strike)
        ingest.onStrike = { evaluator.setStrikeMeasure($0) }
        ingest.onTouchGate = { evaluator.touchGate(lane: .wire, id: $0, on: $1) }
        ingest.apply(TLPPerfState(stateSeq: 1, timestampUs: 0, tiltX: 0, tiltY: 0, tiltZ: 0, droneMask: 0, strike: 255,
            touches: [touch(1, pitch: 60)]))
        ingest.apply(TLPPerfState(stateSeq: 2, timestampUs: 0, tiltX: 0, tiltY: 0, tiltZ: 0, droneMask: 0, strike: 255, touches: []))
        // No note remains: the next onset must re-anchor the blend despite the repeated byte.
        ingest.apply(TLPPerfState(stateSeq: 3, timestampUs: 0, tiltX: 0, tiltY: 0, tiltZ: 0, droneMask: 0, strike: 255,
            touches: [touch(2, pitch: 64)]))
        bind(.jcAccel)
        evaluator.applyAxis(ControlAxisEvaluator.jcAccelAxisIndex, -0.4)
        ingest.apply(TLPPerfState(stateSeq: 4, timestampUs: 0, tiltX: 0, tiltY: 0, tiltZ: 0, droneMask: 0, strike: 255,
            touches: [touch(2, pitch: 64), touch(3, pitch: 67)]))
        var snapshot = BowControlMapper.PolySnapshot(count: 3)
        mapper.snapshotPoly(into: &snapshot)
        XCTAssertEqual(snapshot.slots[0].attackSharpness, 1.0, accuracy: 1e-12)
        XCTAssertEqual(snapshot.slots[1].attackSharpness, 1.0, accuracy: 1e-12)
        XCTAssertEqual(snapshot.slots[2].attackSharpness, 0.3, accuracy: 1e-12)
    }

    /// Sender-side coalescing plus the receiver diff can never lose a release.
    func testCoalescedReleaseNeverLost() {
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
        XCTAssertEqual(sink2.calls, [.on(1, 60), .off(1)])
    }

    /// A drop is SURGICAL: exactly the wire's touches and held drones, never
    /// a global all-off (which would kill the Mac's own pad notes).
    func testLinkDropKillsOnlyItsOwnTouches() {
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        ingest.apply(frame(seq: 1, touches: [touch(1, pitch: 60), touch(2, pitch: 64)],
                           drones: 0b101))
        sink.calls.removeAll()
        ingest.linkDidDrop()
        XCTAssertFalse(sink.calls.contains(.allOff))
        XCTAssertEqual(Set(sink.calls), Set([.off(1), .off(2),
                                             .drone(0, false), .drone(2, false)]))
        // Reconnect: the first frame is a full resync by construction.
        sink.calls.removeAll()
        ingest.apply(frame(seq: 1, touches: [touch(9, pitch: 65)]))
        XCTAssertEqual(sink.calls.last, .on(9, 65))
        // A second drop with nothing held is a no-op beyond the offs.
        ingest.linkDidDrop()
        ingest.linkDidDrop()
        XCTAssertEqual(sink.calls.filter { $0 == .off(9) }.count, 1)
    }

    /// `OutboundPlayState` → frame → ingest, end to end: on, glide, drone,
    /// off, and a clean state emits no frame at all.
    func testOutboundLifecycleEndToEnd() {
        let out = OutboundPlayState()
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        func pump() {
            if let f = out.snapshotFrame(timestampUs: 0) { ingest.apply(f) }
        }
        out.touchOn("fingerA", pitchSemis: 60.25)
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
        guard case .on(let id, let p0) = sink.calls[0] else {
            return XCTFail("first call not an onset: \(sink.calls)")
        }
        XCTAssertEqual(p0, Double(Float(60.25)))
        XCTAssertEqual(sink.calls[1], .glide(id, Double(Float(60.75))))
        XCTAssertEqual(sink.calls[2], .drone(2, true))
        XCTAssertEqual(sink.calls[3], .off(id))
    }

}
