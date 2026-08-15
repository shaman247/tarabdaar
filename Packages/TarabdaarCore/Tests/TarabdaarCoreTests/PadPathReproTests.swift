import XCTest
@testable import TarabdaarCore
@testable import SarangiKit

/// Reproduction: the exact pad → state → pump → ingest chain the Mac local
/// pads (and, minus the link hop, the iPad) use. Guards the full stack
/// including PitchPadEngine, which LinkIngestTests bypassed.
final class PadPathReproTests: XCTestCase {

    private final class RecordingSink: LinkPerformanceSink {
        enum Call: Equatable {
            case on(UInt16), glide(UInt16, Double), off(UInt16), allOff, drone(Int, Bool)
        }
        var calls: [Call] = []
        func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double) { calls.append(.on(id)) }
        func touchGlide(_ id: UInt16, pitchSemis: Double) { calls.append(.glide(id, pitchSemis)) }
        func touchOff(_ id: UInt16) { calls.append(.off(id)) }
        func touchesAllOff() { calls.append(.allOff) }
        func setDronePressed(_ index: Int, _ pressed: Bool) { calls.append(.drone(index, pressed)) }
    }

    func testPadDragThroughLocalPump() {
        let state = OutboundPlayState()
        let sink = RecordingSink()
        let ingest = LinkIngest(sink: sink)
        let pump = LocalLinkPump(state: state, ingest: ingest)
        _ = pump
        let e = PitchPadEngine(state: state)

        e.noteOn(touchId: 7, ratio: 1.5)
        e.glide(touchId: 7, ratio: 1.51)
        e.glide(touchId: 7, ratio: 1.52)
        e.noteOff(touchId: 7)

        // Expect exactly: on, glide, glide, off — same id throughout.
        XCTAssertEqual(sink.calls.count, 4, "calls: \(sink.calls)")
        guard case .on(let id) = sink.calls.first else {
            return XCTFail("first call not an onset: \(sink.calls)")
        }
        guard case .glide(id, _) = sink.calls[1],
              case .glide(id, _) = sink.calls[2],
              case .off(id) = sink.calls[3] else {
            return XCTFail("bad sequence: \(sink.calls)")
        }
    }

    func testPadDragThroughRealMapper() {
        // Same chain, but the sink is a real mapper adapter — checks the
        // gate stays up across glides and pitch actually moves.
        final class MapperSink: LinkPerformanceSink {
            let mapper = BowControlMapper()
            init() { mapper.setSlotLimit(4) }
            func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double) {
                mapper.touchOn(id, pitchSemis: pitchSemis, velocity: velocity)
            }
            func touchGlide(_ id: UInt16, pitchSemis: Double) {
                mapper.touchGlide(id, pitchSemis: pitchSemis)
            }
            func touchOff(_ id: UInt16) { mapper.touchOff(id) }
            func touchesAllOff() { mapper.touchAllOff() }
            func setDronePressed(_ index: Int, _ pressed: Bool) {}
        }
        let state = OutboundPlayState()
        let sink = MapperSink()
        let ingest = LinkIngest(sink: sink)
        let pump = LocalLinkPump(state: state, ingest: ingest)
        _ = pump
        let e = PitchPadEngine(state: state)

        func poly() -> BowControlMapper.PolySnapshot {
            var s = BowControlMapper.PolySnapshot(count: 4)
            sink.mapper.snapshotPoly(into: &s)
            return s
        }

        e.noteOn(touchId: 3, ratio: 1.0)
        XCTAssertEqual(poly().slots[0].gate, 1.0, "gate down right after onset")
        let f0 = poly().slots[0].f0Target

        e.glide(touchId: 3, ratio: 1.1)
        XCTAssertEqual(poly().slots[0].gate, 1.0, "glide dropped the gate")
        XCTAssertNotEqual(poly().slots[0].f0Target, f0, "glide didn't move pitch")

        e.glide(touchId: 3, ratio: 1.2)
        XCTAssertEqual(poly().slots[0].gate, 1.0)

        e.noteOff(touchId: 3)
        XCTAssertEqual(poly().slots[0].gate, 0.0)
    }
}

extension PadPathReproTests {
    func testAudioEngineTouchLayerHoldsGate() throws {
        let audio = AudioEngine()
        guard audio.setSarangiModelVoiceEnabled(true) else {
            throw XCTSkip("bowed_string.json unavailable")
        }
        // The engine builds off-main; the mapper exists immediately.
        let e = PitchPadEngine(audio: audio)
        e.start()
        e.noteOn(touchId: 1, ratio: 1.25)
        guard let src = audio.stringVoiceSourceForTesting else {
            throw XCTSkip("no source")
        }
        func poly() -> BowControlMapper.PolySnapshot {
            var s = BowControlMapper.PolySnapshot(count: 4)
            src.mapper.snapshotPoly(into: &s)
            return s
        }
        XCTAssertEqual(poly().slots[0].gate, 1.0, "gate down after onset")
        let f0 = poly().slots[0].f0Target
        e.glide(touchId: 1, ratio: 1.30)
        XCTAssertEqual(poly().slots[0].gate, 1.0, "glide dropped the gate")
        XCTAssertNotEqual(poly().slots[0].f0Target, f0, "glide didn't move pitch")
        e.noteOff(touchId: 1)
        XCTAssertEqual(poly().slots[0].gate, 0.0)
    }
}

extension PadPathReproTests {
    /// Render-level A/B: a held note through the touch path must sustain
    /// like the MIDI path, and a touch glide must move the rendered pitch.
    func testTouchPathRendersSustainedTone() throws {
        func makeSource() -> StringVoiceSource? {
            let src = StringVoiceSource()
            let strings = Presets.state(.sarangiPilu).resolvedStrings
            guard let e = StringVoiceSource.buildEngine(
                tonicHz: 328.9, strings: strings, mapper: src.mapper) else {
                return nil
            }
            src.setEngine(e, crossfadeMs: 0)
            return src
        }
        func rms(_ x: ArraySlice<Double>) -> Double {
            x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
        }
        func pull(_ src: StringVoiceSource, _ blocks: Int) -> [Double] {
            var out: [Double] = []
            for _ in 0..<blocks {
                let (l, r) = src.renderForTesting(frames: 4096)
                out.append(contentsOf: (0..<4096).map { Double(l[$0]) + Double(r[$0]) })
            }
            return out
        }

        guard let midiSrc = makeSource(), let touchSrc = makeSource() else {
            throw XCTSkip("bowed_string.json not available")
        }
        midiSrc.mapper.midi(0xB0, 11, 64)
        midiSrc.mapper.midi(0x90, 60, 100)
        touchSrc.mapper.setAxis(expr: Double(64) / 127.0)
        touchSrc.mapper.touchOn(1, pitchSemis: 60.0, velocity: 100.0 / 127.0)

        let a = pull(midiSrc, 10)
        let b = pull(touchSrc, 10)
        let aTail = rms(a[(a.count - 8192)...])
        let bTail = rms(b[(b.count - 8192)...])
        print("midi tail RMS \(aTail)  touch tail RMS \(bTail)")
        XCTAssertGreaterThan(bTail, 1e-4, "touch-held note did not sustain")
        XCTAssertGreaterThan(bTail, aTail * 0.25, "touch path much quieter than midi path")

        // Glide: pitch must actually move the rendered waveform.
        touchSrc.mapper.touchGlide(1, pitchSemis: 63.0)
        let after = pull(touchSrc, 6)
        XCTAssertGreaterThan(rms(after[(after.count - 8192)...]), 1e-4,
                             "tone died after glide")
    }
}
