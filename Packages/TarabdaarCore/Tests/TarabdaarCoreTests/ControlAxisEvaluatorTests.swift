import XCTest
@testable import TarabdaarCore

/// The control-axis evaluator: the binding snapshot, the axis→native
/// evaluation, the strike→acceleration blend's gating, and the two-lane
/// finger registry. (The timing laws themselves live in
/// `StrikeBlendWindow` / `FingerAccelTracker` and are not re-tested here.)
///
/// The evaluator arms a 30 Hz blend timer whenever the strike pair is
/// bound, so every recording here is lock-guarded and the blend tests use
/// a very long window (weight pinned at ~0) to stay tick-independent.
final class ControlAxisEvaluatorTests: XCTestCase {

    private let slot0 = MapTarget(compositeSlot: 0)

    /// Thread-safe capture of what the evaluator emitted.
    private final class Recorder {
        private let lock = NSLock()
        private var batches: [[ControlAxisEvaluator.Application]] = []
        func record(_ b: [ControlAxisEvaluator.Application]) {
            lock.lock(); batches.append(b); lock.unlock()
        }
        var all: [[ControlAxisEvaluator.Application]] {
            lock.lock(); defer { lock.unlock() }; return batches
        }
        var appliedCount: Int { all.reduce(0) { $0 + $1.count } }
        func last(_ t: MapTarget) -> Double? {
            all.flatMap { $0 }.last { $0.target == t }?.value
        }
    }

    private func mapping(_ pairs: [(MapTarget, DimensionBinding)])
        -> DimensionMapping {
        var m: [String: ParameterMapping] = [:]
        for (t, b) in pairs {
            var pm = m[t.storageKey] ?? ParameterMapping(bindings: [])
            pm.bindings.append(b)
            m[t.storageKey] = pm
        }
        return DimensionMapping(mappings: m)
    }

    /// An axis drives every bound target in native units; the axis value
    /// −1…+1 maps onto the curve's 0…1 input.
    func testAxisDrivesBoundTargetsInNativeUnits() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .tilt1,
                                     rangeMin: 2, rangeMax: 6)),
        ]))
        e.applyAxis(0, 1.0)                     // curve x = 1
        e.applyAxis(0, -1.0)                    // curve x = 0
        e.applyAxis(0, 0.0)                     // curve x = 0.5
        let batches = rec.all
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].first?.value ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(batches[1].first?.value ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(batches[2].first?.value ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(batches[0].first?.target, slot0)
    }

    /// An unbound axis (and an out-of-range index) applies nothing.
    func testUnboundAxisAppliesNothing() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .tilt1,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        e.applyAxis(1, 1.0)
        e.applyAxis(99, 1.0)
        e.applyAxis(-1, 1.0)
        XCTAssertEqual(rec.appliedCount, 0)
    }

    /// The raw iPad arm axes are duplicate-dropped (the uncalibrated
    /// passthrough repeats the same value every frame).
    func testRawArmAxisDropsDuplicates() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .tilt1,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        e.applyRawArmAxis(0, 0.5)
        e.applyRawArmAxis(0, 0.5)
        e.applyRawArmAxis(0, 0.25)
        XCTAssertEqual(rec.appliedCount, 2)
    }

    /// With nothing ever played the blend rests fully on the Acceleration
    /// side, so a Strike-only binding reads its target's DEFAULT (0 for a
    /// composite); the first note-on swings it to the strike measurement.
    func testStrikeBlendRestsOnAccelerationUntilANoteStarts() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setStrikeWindow(1000)                  // pin the weight at ~0/1
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .strike,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        e.setStrikeMeasure(1.0)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.0, accuracy: 1e-9,
                       "no note has played: weight 1 = the accel side's default")
        e.touchGate(lane: .wire, id: 7, on: true)
        e.setStrikeMeasure(0.75)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.75, accuracy: 1e-3,
                       "fresh onset: weight ≈ 0 = the strike binding")
    }

    /// The blend is change-gated per target: re-feeding the same
    /// measurement emits nothing.
    func testStrikeBlendIsChangeGated() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .acceleration,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        e.setStrikeMeasure(0.5)
        let after = rec.appliedCount
        e.setStrikeMeasure(0.5)
        XCTAssertEqual(rec.appliedCount, after)
        e.setStrikeMeasure(0.6)
        XCTAssertEqual(rec.appliedCount, after + 1)
    }

    /// Nothing bound on either strike dimension = no blend evaluation at
    /// all (the pair must never be driven through `applyAxis`).
    func testStrikeBlendSilentWithoutBindings() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .tilt1,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        e.setStrikeMeasure(1.0)
        XCTAssertEqual(rec.appliedCount, 0)
    }

    /// The window is clamped to a sane floor (a 0 s window would divide by
    /// zero in the weight ramp).
    func testStrikeWindowIsClamped() {
        let e = ControlAxisEvaluator()
        e.setStrikeWindow(0)
        XCTAssertEqual(e.strikeWindowS, 0.05, accuracy: 1e-12)
        e.setStrikeWindow(3.5)
        XCTAssertEqual(e.strikeWindowS, 3.5, accuracy: 1e-12)
    }

    /// The finger registry keeps sounding touches oldest→newest, and the
    /// two lanes have DISTINCT id spaces (the wire's u16 ids and the local
    /// pump's would otherwise collide).
    func testTouchRegistryOrdersLanesSeparately() {
        let e = ControlAxisEvaluator()
        e.touchGate(lane: .wire, id: 1, on: true)
        e.touchPitch(lane: .wire, id: 1, pitch: 60)
        e.touchGate(lane: .local, id: 1, on: true)
        e.touchPitch(lane: .local, id: 1, pitch: 64)
        let touches = e.currentTouches()
        XCTAssertEqual(touches.count, 2)
        XCTAssertEqual(touches.map(\.pitchSemis), [60, 64])
        XCTAssertNotEqual(touches[0].id, touches[1].id)
        // A release drops just that lane's touch.
        e.touchGate(lane: .wire, id: 1, on: false)
        XCTAssertEqual(e.currentTouches().map(\.pitchSemis), [64])
    }

    /// A retrigger re-orders the touch to newest without duplicating it.
    func testRetriggerMovesTouchToNewest() {
        let e = ControlAxisEvaluator()
        e.touchGate(lane: .wire, id: 1, on: true)
        e.touchPitch(lane: .wire, id: 1, pitch: 60)
        e.touchGate(lane: .wire, id: 2, on: true)
        e.touchPitch(lane: .wire, id: 2, pitch: 62)
        e.touchGate(lane: .wire, id: 1, on: true)
        XCTAssertEqual(e.currentTouches().map(\.pitchSemis), [62, 60])
    }
}
