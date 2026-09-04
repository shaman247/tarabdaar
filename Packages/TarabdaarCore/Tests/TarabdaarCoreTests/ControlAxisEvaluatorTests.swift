import XCTest
@testable import TarabdaarCore

/// The control-axis evaluator: axis → native-unit application, the
/// strike/acceleration blend's gating, and the two-lane finger registry.
final class ControlAxisEvaluatorTests: XCTestCase {

    private let slot0 = MapTarget(compositeSlot: 0)

    /// Thread-safe capture of what the evaluator emitted (a bound strike pair
    /// arms a 30 Hz blend timer that also applies).
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

    /// An axis drives every bound target in native units (−1…+1 onto the
    /// curve's 0…1 input); an unbound or out-of-range axis applies nothing.
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

        e.applyAxis(1, 1.0)
        e.applyAxis(99, 1.0)
        e.applyAxis(-1, 1.0)
        XCTAssertEqual(rec.appliedCount, 3, "an unbound axis applied something")
    }

    /// The strike pair rests on the Acceleration side until a note starts (an
    /// unbound side reads its target's default), and is never driven at all
    /// while nothing is bound to it — it must never go through `applyAxis`.
    func testStrikeBlendGating() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setStrikeWindow(1000)                  // pin the weight at ~0/1
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .tilt1,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        e.setStrikeMeasure(1.0)
        XCTAssertEqual(rec.appliedCount, 0, "nothing bound, yet the pair drove")

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

    /// The finger registry keeps sounding touches oldest→newest, the two lanes
    /// have DISTINCT id spaces, and a retrigger re-orders without duplicating.
    func testTouchRegistryOrdersLanesSeparately() {
        let e = ControlAxisEvaluator()
        e.touchGate(lane: .wire, id: 1, on: true)
        e.touchPitch(lane: .wire, id: 1, pitch: 60)
        e.touchGate(lane: .local, id: 1, on: true)
        e.touchPitch(lane: .local, id: 1, pitch: 64)
        var touches = e.currentTouches()
        XCTAssertEqual(touches.count, 2)
        XCTAssertEqual(touches.map(\.pitchSemis), [60, 64])
        XCTAssertNotEqual(touches[0].id, touches[1].id)

        e.touchGate(lane: .wire, id: 2, on: true)
        e.touchPitch(lane: .wire, id: 2, pitch: 62)
        e.touchGate(lane: .wire, id: 1, on: true)          // retrigger
        touches = e.currentTouches()
        XCTAssertEqual(touches.map(\.pitchSemis), [64, 62, 60])

        e.touchGate(lane: .wire, id: 1, on: false)
        XCTAssertEqual(e.currentTouches().map(\.pitchSemis), [64, 62])
    }
}
