import XCTest
@testable import TarabdaarCore

/// The control-axis evaluator: the swing law (rest + Σ swings), the
/// strike/acceleration blend's gating, and the two-lane finger registry.
final class ControlAxisEvaluatorTests: XCTestCase {

    /// Offset edits preserve endpoints, zero at rest, persistence, and a movable base.
    func testOffsetEditingAndBaseMovement() throws {
        let original = DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 1)
        let edited = original.withOffsets(lo: -0.2, hi: 0.5)
        let decoded = try JSONDecoder().decode(DimensionBinding.self,
            from: JSONEncoder().encode(edited))
        XCTAssertEqual(decoded.swing(atX: 0), -0.2, accuracy: 1e-12)
        XCTAssertEqual(decoded.swing(atX: 0.5), 0)
        XCTAssertEqual(decoded.swing(atX: 1), 0.5, accuracy: 1e-12)
        let sameSign = original.withOffsets(lo: 0.2, hi: 0.5)
        XCTAssertEqual(sameSign.swing(atX: 0.5), 0)
        XCTAssertEqual(sameSign.swing(atX: 0), 0.2, accuracy: 1e-12)
        let strike = DimensionBinding(dimension: .strike, rangeMin: 0, rangeMax: 1)
            .withOffsets(lo: 0, hi: 0.3)
        XCTAssertEqual(strike.swing(atX: 0), 0)
        XCTAssertEqual(strike.swing(atX: 1), 0.3, accuracy: 1e-12)
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        var m = mapping([(slot0, decoded)], rest: 0.5)
        e.setMapping(m)
        e.applyAxis(0, -1)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.3, accuracy: 1e-12)
        m.setRest(for: slot0, 0.6)
        e.setMapping(m)
        e.reapply()
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertEqual(m.mapping(for: slot0).binding(for: .tilt1), decoded)
        let parameter = MapTarget(paramKey: "bow_expr")
        e.paramRest = { _ in 0.8 }
        e.setMapping(mapping([(parameter, decoded)]))
        e.applyAxis(0, 1)
        let count = rec.appliedCount
        e.setParamRest("bow_expr", 0.9)
        XCTAssertEqual(rec.appliedCount, count + 1,
                       "A base write must restore the combined output even when it stays saturated")
        XCTAssertEqual(rec.last(parameter) ?? -1, 1, accuracy: 1e-12)
    }

    private let slot0 = MapTarget(compositeSlot: 0)

    /// One-way offsets interpolate independently across edits and persistence without moving the base.
    func testOneWayEndpointOffsets() throws {
        for dimension in ControlAxes.bindableDims where dimension.restX == 0 {
            let legacy = DimensionBinding(dimension: dimension, rangeMin: 0.3, rangeMax: 0.9)
            let oldRoundTrip = try JSONDecoder().decode(DimensionBinding.self,
                from: JSONEncoder().encode(legacy))
            XCTAssertEqual(oldRoundTrip.swing(atX: 0), 0)
            XCTAssertEqual(oldRoundTrip.swing(atX: 1), 0.6, accuracy: 1e-12)

            let firstEdit = oldRoundTrip.withOffsets(lo: -0.2, hi: oldRoundTrip.swing(atX: 1))
            let edited = firstEdit.withOffsets(lo: firstEdit.swing(atX: 0), hi: 0.4)
            let decoded = try JSONDecoder().decode(DimensionBinding.self,
                from: JSONEncoder().encode(edited))
            for (input, output) in [(0.0, 0.2), (0.5, 0.5), (1.0, 0.8)] {
                XCTAssertEqual(0.4 + decoded.swing(atX: input), output, accuracy: 1e-12)
            }
            let inverted = decoded.withOffsets(lo: 0.4, hi: -0.2)
            XCTAssertEqual(inverted.swing(atX: 0), 0.4, accuracy: 1e-12)
            XCTAssertEqual(inverted.swing(atX: 1), -0.2, accuracy: 1e-12)
        }

        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.paramRest = { _ in 0.4 }
        let expression = MapTarget(paramKey: "bow_expr")
        let accel = DimensionBinding(dimension: .jcAccel, rangeMin: 0, rangeMax: 1)
            .withOffsets(lo: -0.2, hi: 0.4)
        let m = mapping([(slot0, accel), (expression, accel)], rest: 0.4)
        e.setMapping(m)
        for (input, output) in [(0.0, 0.2), (0.5, 0.5), (1.0, 0.8)] {
            e.applyAxis(ControlAxisEvaluator.jcAccelAxisIndex, 2 * input - 1)
            XCTAssertEqual(rec.last(slot0) ?? -1, output, accuracy: 1e-12)
            XCTAssertEqual(rec.last(expression) ?? -1, output, accuracy: 1e-12)
        }
        XCTAssertEqual(m.mapping(for: slot0).defaultValue, 0.4)
    }

    /// Connection changes select one cached three-axis pose without summing both devices.
    func testMotionSourceSelection() throws {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        let bindings = [InputDimension.tilt1, .tilt2, .tilt3].map {
            DimensionBinding(dimension: $0, rangeMin: 0.4, rangeMax: 0.6)
        }
        e.setMapping(DimensionMapping(mappings: [slot0.storageKey:
            ParameterMapping(bindings: bindings, defaultValue: 0.5)]))
        e.applyTilt(.iPad, SIMD3(-0.8, -0.4, -0.2))
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.36, accuracy: 1e-12)
        e.setControllerConnected(true)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.5, accuracy: 1e-12,
                       "A connected controller without calibrated samples owns the neutral tilts")
        e.applyTilt(.controller, SIMD3(0.4, 0.2, 0.1))
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.57, accuracy: 1e-12)
        let count = rec.appliedCount
        e.applyRawArmAxis(0, -1)
        e.applyTilt(.iPad, SIMD3(-1, -0.5, -0.3))
        XCTAssertEqual(rec.appliedCount, count)
        e.setControllerConnected(false)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.32, accuracy: 1e-12)
        e.applyRawArmAxis(0, -1)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.32, accuracy: 1e-12)
        e.setControllerConnected(true)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.5, accuracy: 1e-12,
                       "Reconnect cannot replay the previous controller pose")
        e.applyTilt(.controller, SIMD3(0.8, 0.4, 0.2))
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.64, accuracy: 1e-12)
        for batch in rec.all {
            XCTAssertEqual(batch.filter { $0.target == slot0 }.count, 1)
        }
    }

    /// Legacy wrist curves win overlapping arm bindings, preserving offsets and preset rests.
    func testSharedTiltMigration() throws {
        let wrist = DimensionBinding(dimension: .tilt4, rangeMin: 0, rangeMax: 1)
            .withOffsets(lo: -0.2, hi: 0.4)
        let arm = DimensionBinding(dimension: .tilt1, rangeMin: 0.9, rangeMax: 0.1)
        let armOnly = DimensionBinding(dimension: .tilt2, rangeMin: 0.2, rangeMax: 0.8)
        let wristOnly = DimensionBinding(dimension: .wrist3, rangeMin: 1, rangeMax: 0)
        let legacy = [slot0.storageKey: ParameterMapping(
            bindings: [arm, wrist, armOnly, wristOnly], defaultValue: 0.37)]
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
        let data = try JSONSerialization.data(withJSONObject: ["mappings": object, "restLaw": 1])
        let migrated = try JSONDecoder().decode(DimensionMapping.self, from: data)
        let roundTrip = try JSONDecoder().decode(DimensionMapping.self,
            from: JSONEncoder().encode(migrated))
        XCTAssertEqual(migrated, roundTrip)
        let pm = roundTrip.mapping(for: slot0)
        XCTAssertEqual(pm.defaultValue, 0.37)
        XCTAssertEqual(Set(pm.bindings.map(\.dimension)), [.tilt1, .tilt2, .tilt3])
        XCTAssertEqual(pm.bindings.count, 3)
        for (old, shared) in [(wrist, InputDimension.tilt1), (armOnly, .tilt2), (wristOnly, .tilt3)] {
            let binding = try XCTUnwrap(pm.binding(for: shared))
            for i in 0...100 {
                let x = Double(i) / 100
                XCTAssertEqual(binding.swing(atX: x), old.swing(atX: x), accuracy: 1e-12)
            }
        }
        XCTAssertTrue(Set([InputDimension.tilt4, .wrist2, .wrist3])
            .isDisjoint(with: ControlAxes.bindableDims))
        let defaults = DimensionMapping.makeDefault()
        for slot in 0..<4 {
            XCTAssertEqual(defaults.mapping(for: MapTarget(compositeSlot: slot)).bindings.count, 1)
        }
    }

    /// Stick migration preserves both halves of nonlinear curves across preset round trips.
    func testStickDirectionMigration() throws {
        let x = DimensionBinding(dimension: .stickX, controlPoints: [
            ControlPoint(x: 0, y: 0.1), ControlPoint(x: 0.3, y: 0.25),
            ControlPoint(x: 0.7, y: 0.6), ControlPoint(x: 1, y: 0.8),
        ])
        let y = DimensionBinding(dimension: .stickY, rangeMin: 0.8, rangeMax: 0.2)
        let legacy = [slot0.storageKey: ParameterMapping(bindings: [x, y], defaultValue: 0.4)]
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
        let data = try JSONSerialization.data(withJSONObject: ["mappings": object, "restLaw": 1])
        let migrated = try JSONDecoder().decode(DimensionMapping.self, from: data)
        let roundTrip = try JSONDecoder().decode(DimensionMapping.self,
            from: JSONEncoder().encode(migrated))
        XCTAssertEqual(migrated, roundTrip)
        let pm = roundTrip.mapping(for: slot0)
        XCTAssertEqual(pm.defaultValue, 0.4)
        XCTAssertEqual(pm.bindings.count, 4)
        XCTAssertFalse(pm.hasBinding(for: .stickX))
        XCTAssertFalse(pm.hasBinding(for: .stickY))
        for i in 0...100 {
            let level = Double(i) / 100
            for (old, negative, positive) in [(x, InputDimension.stickLeft, InputDimension.stickRight),
                                               (y, InputDimension.stickDown, InputDimension.stickUp)] {
                XCTAssertEqual(try XCTUnwrap(pm.binding(for: negative)).swing(atX: level),
                               old.swing(atX: 0.5 - level * 0.5), accuracy: 1e-12)
                XCTAssertEqual(try XCTUnwrap(pm.binding(for: positive)).swing(atX: level),
                               old.swing(atX: 0.5 + level * 0.5), accuracy: 1e-12)
            }
        }
        XCTAssertEqual(Set(ControlAxes.bindableDims.filter { ControlAxes.stickDimensions.contains($0) }),
                       Set(ControlAxes.stickDimensions))
        XCTAssertFalse(ControlAxes.bindableDims.contains(.stickX))
        XCTAssertFalse(ControlAxes.bindableDims.contains(.stickY))
    }

    /// Direction changes, diagonals, and centring emit one combined value without stale opposites.
    func testIndependentStickDirections() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        let amounts = [0.2, 0.3, 0.1, -0.1]
        var pairs: [(MapTarget, DimensionBinding)] = []
        for (i, direction) in ControlAxes.stickDimensions.enumerated() {
            let b = DimensionBinding(dimension: direction, rangeMin: 0, rangeMax: amounts[i])
            pairs.append((slot0, b))
            pairs.append((MapTarget(compositeSlot: i + 1), b))
        }
        e.setMapping(mapping(pairs, rest: 0.5))
        e.applyStick(x: -1, y: 0)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.7, accuracy: 1e-12)
        e.applyStick(x: 1, y: 1)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.9, accuracy: 1e-12)
        XCTAssertEqual(rec.last(MapTarget(compositeSlot: 1)) ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(rec.last(MapTarget(compositeSlot: 2)) ?? -1, 0.8, accuracy: 1e-12)
        XCTAssertEqual(rec.last(MapTarget(compositeSlot: 3)) ?? -1, 0.6, accuracy: 1e-12)
        XCTAssertEqual(rec.last(MapTarget(compositeSlot: 4)) ?? -1, 0.5, accuracy: 1e-12)
        e.applyStick(x: 0, y: -1)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.4, accuracy: 1e-12)
        e.applyStick(x: 0, y: 0)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.5, accuracy: 1e-12)
        for batch in rec.all {
            XCTAssertEqual(batch.filter { $0.target == slot0 }.count, 1)
        }
    }

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

    /// A mapping over the given (target, curve) pairs; every composite
    /// target rests at `rest`.
    private func mapping(_ pairs: [(MapTarget, DimensionBinding)],
                         rest: Double = 0) -> DimensionMapping {
        var m: [String: ParameterMapping] = [:]
        for (t, b) in pairs {
            var pm = m[t.storageKey]
                ?? ParameterMapping(bindings: [], defaultValue: rest)
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
        ], rest: 4))
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
    /// unbound side swings nothing, so the target reads its rest), and is
    /// never driven at all while nothing is bound to it — it must never go
    /// through `applyAxis`.
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
                       "no note has played: weight 1 = the unbound accel side = rest")
        e.touchGate(lane: .wire, id: 7, on: true)
        e.setStrikeMeasure(0.75)
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.75, accuracy: 1e-3,
                       "fresh onset: weight ≈ 0 = the strike binding")
    }

    /// Several axes on one target ADD their swings about its rest instead of
    /// overwriting each other: an axis back at rest contributes exactly 0, a
    /// parameter target rests at its store value and follows it.
    func testSwingsAddAboutTheRest() {
        let e = ControlAxisEvaluator()
        let rec = Recorder()
        e.onApply = { rec.record($0) }
        e.setStrikeWindow(1000)                  // weight ≈ 0 after an onset
        var store = 0.5
        e.paramRest = { _ in store }
        let mu = MapTarget(paramKey: "bow_mu_s")
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 1)),
            (slot0, DimensionBinding(dimension: .strike, rangeMin: 0, rangeMax: 0.3)),
            (mu, DimensionBinding(dimension: .tilt2, rangeMin: 0, rangeMax: 0.4)),
        ], rest: 0.5))
        e.touchGate(lane: .wire, id: 1, on: true)
        e.applyAxis(0, -0.5)                                   // swing −0.25
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.25, accuracy: 1e-12)
        e.setStrikeMeasure(1.0)                                // swing +0.3
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.55, accuracy: 1e-3)
        e.applyAxis(0, 0.0)                                    // tilt at rest
        XCTAssertEqual(rec.last(slot0) ?? -1, 0.8, accuracy: 1e-3,
                       "the resting axis must not overwrite the strike's swing")
        e.applyAxis(0, 1.0)                                    // 0.5+0.5+0.3
        XCTAssertEqual(rec.last(slot0) ?? -1, 1.0, accuracy: 1e-12,
                       "the sum clamps once, to the target's range")

        e.applyAxis(1, 1.0)                                    // swing +0.2
        XCTAssertEqual(rec.last(mu) ?? -1, 0.7, accuracy: 1e-12,
                       "a parameter target swings about its store value")
        store = 0.6
        e.setParamRest("bow_mu_s", store)
        XCTAssertEqual(rec.last(mu) ?? -1, 0.8, accuracy: 1e-12,
                       "the knob moved: the swing rides the new rest")
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
