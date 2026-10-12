import XCTest
import SarangiKit
@testable import TarabdaarCore

final class PlayedVoiceLifecycleTests: XCTestCase {
    /// Re-selecting a voice preserves glide ownership; a real switch releases it without waiting for physical lifts.
    func testInstrumentSelectionPreservesOrReleasesGlideOwnership() {
        var now = 0.0
        let seq = GlideSequencer(drivesTimer: false, clock: { now })
        let audio = AudioEngine(glideQueue: seq)
        let source = StringVoiceSource()
        audio.stringVoiceSource = source
        source.mapper.setSlotLimit(2)
        seq.setControl("ctl_glide_on", 1)
        seq.setControl("ctl_glide_over", 0)
        seq.setControl("ctl_glide_grace", 0)
        func heldCount() -> Int {
            var snapshot = BowControlMapper.PolySnapshot(count: 2)
            source.mapper.snapshotPoly(into: &snapshot)
            return snapshot.slots.filter { $0.gate > 0 }.count
        }
        audio.touchOn(10, pitchSemis: 60)
        audio.touchOn(20, pitchSemis: 64)
        audio.touchOff(10)
        now = 1
        seq.tick(now: now)
        XCTAssertEqual(heldCount(), 1)
        audio.setMainInstrument(.string)
        audio.touchOff(20)
        XCTAssertEqual(heldCount(), 0, "The physical owner must still release the original voice id")

        audio.touchOn(30, pitchSemis: 60)
        audio.touchOn(40, pitchSemis: 67)
        audio.touchOff(30)
        audio.setMainInstrument(.tanpura)
        XCTAssertEqual(heldCount(), 0)
        XCTAssertTrue(audio.touchPitchSemis.isEmpty)
        now += 1
        seq.tick(now: now)
        audio.touchGlide(40, pitchSemis: 72)
        audio.touchOff(40)
        XCTAssertEqual(heldCount(), 0)
        XCTAssertTrue(audio.touchPitchSemis.isEmpty)
    }

    /// A replacement slot owner ignores older fingers, and switching voices releases only played slots with normal tails.
    func testPluckedOwnershipAndSwitchPreserveReleaseTailsAndDrones() throws {
        let params = try XCTUnwrap(Presets.tanpuraParams())
        let audio = AudioEngine(glideQueue: GlideSequencer(drivesTimer: false))
        let source = TanpuraVoiceSource()
        let actual = try XCTUnwrap(TanpuraEngine(params: params, frequencies: [220, 330], workers: 1))
        source.setEngine(actual, crossfadeMs: 0)
        audio.tanpuraVoice.source = source
        audio.setMainInstrument(.tanpura)
        let referenceSource = TanpuraVoiceSource()
        let reference = try XCTUnwrap(TanpuraEngine(params: params, frequencies: [220, 330], workers: 1))
        referenceSource.setEngine(reference, crossfadeMs: 0)
        let referenceVoice = PluckedVoice.tanpura()
        referenceVoice.source = referenceSource
        func render(_ engine: TanpuraEngine) -> [Double] {
            var left = [Double](repeating: 0, count: 1024), right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    engine.render(frames: l.count, outL: l.baseAddress!, outR: r.baseAddress!)
                }
            }
            return left
        }
        for id in UInt16(1)...UInt16(2) {
            audio.touchOn(id, pitchSemis: 57)
            referenceVoice.touchOn(id, pitchSemis: 57, exprScale: 1)
        }
        audio.touchGlide(1, pitchSemis: 58)
        audio.touchOff(1)
        XCTAssertEqual(actual.scopeSlots()[0].hz, 220)
        XCTAssertFalse(audio.tanpuraVoice.touchResume(1, exprScale: 1))
        XCTAssertEqual(render(actual), render(reference), "The displaced owner cannot bend or release the new pluck")
        audio.touchGlide(2, pitchSemis: 57.2)
        referenceVoice.touchGlide(2, pitchSemis: 57.2, exprScale: nil)
        XCTAssertGreaterThan(actual.scopeSlots()[0].hz, 220)

        audio.setDroneMappedFreqs([660, nil, nil])
        audio.setDronePressed(0, true, repeating: false)
        reference.pluck(slot: 1, scale: audio.tanpuraDroneLevel,
                        touch: audio.tanpuraVoice.pluckTouch, drive: audio.tanpuraVoice.pluckDrive)
        XCTAssertEqual(render(actual), render(reference))
        audio.setMainInstrument(.string)
        referenceVoice.touchAllOff()
        XCTAssertTrue(audio.droneHeld[0])
        XCTAssertTrue(audio.tanpuraVoice.touchBindings.held.isEmpty)
        audio.touchGlide(2, pitchSemis: 60)
        audio.touchOff(2)
        let tail = render(actual)
        XCTAssertEqual(tail, render(reference), "Switches use the normal release and leave the drone ringing")
        XCTAssertTrue(tail.contains { abs($0) > 1e-9 })
    }
}
