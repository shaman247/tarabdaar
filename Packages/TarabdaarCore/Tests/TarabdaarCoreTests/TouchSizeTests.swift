import XCTest
@testable import TarabdaarCore

/// The `.touchSize` law: the measured points → 0…1 window, its clamps, the
/// LINEAR rate limit in both directions, and the newest-sounding-touch rule
/// the `ControlAxisEvaluator` drives it under.
final class TouchSizeTests: XCTestCase {

    private let lo = Config.touchSizeLoPt      // 31.3 — normal fingertip
    private let hi = Config.touchSizeHiPt      // 73.0 — deliberately flattened
    private let rampS = Config.touchSizeRampS  // 0.5 s for the full range

    // MARK: - The mapping

    func testMappingEndpointsAndClamp() {
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: lo), 0, accuracy: 1e-12)
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: hi), 1, accuracy: 1e-12)
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: 0.5 * (lo + hi)),
                       0.5, accuracy: 1e-12)
        // The measured "normal playing" readings sit at rest.
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: 20.8), 0,
                       accuracy: 1e-12)
        // Below the window, above it, and the unknown-radius 0 all clamp.
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: -5), 0, accuracy: 1e-12)
        XCTAssertEqual(TouchSizeTracker.mapped(radiusPt: 200), 1,
                       accuracy: 1e-12)
    }

    // MARK: - The rate limiter

    /// A step to fully flattened ramps LINEARLY (not exponentially) and
    /// takes exactly `touchSizeRampS`, then stops dead on the target.
    func testRampUpIsLinearAndTakesTheRampTime() {
        var tr = TouchSizeTracker()
        var t = 10.0
        tr.sample(radiusPt: lo, at: t)                 // seeds the clock at 0
        XCTAssertEqual(tr.value, 0, accuracy: 1e-12)

        let dt = rampS / 20.0                          // 20 ticks = one ramp
        // A quarter of the ramp: a one-pole would be at ~0.39 here.
        for _ in 0..<5 { t += dt; tr.sample(radiusPt: hi, at: t) }
        XCTAssertEqual(tr.value, 0.25, accuracy: 1e-12)
        // Half: still exactly on the straight line.
        for _ in 0..<5 { t += dt; tr.sample(radiusPt: hi, at: t) }
        XCTAssertEqual(tr.value, 0.5, accuracy: 1e-12)
        // The whole ramp time lands on 1 and stays there (no overshoot).
        for _ in 0..<20 { t += dt; tr.sample(radiusPt: hi, at: t) }
        XCTAssertEqual(tr.value, 1.0, accuracy: 1e-12)
        t += dt
        XCTAssertEqual(tr.sample(radiusPt: hi, at: t), 1.0, accuracy: 1e-12)
    }

    /// The same rate applies DOWNWARD, and "no touch" (nil) targets 0.
    func testRampDownAtTheSameRateAndNoTouchRestsAtZero() {
        var tr = TouchSizeTracker()
        var t = 0.0
        tr.sample(radiusPt: hi, at: t)
        let dt = rampS / 20.0                          // 20 ticks = one ramp
        for _ in 0..<22 { t += dt; tr.sample(radiusPt: hi, at: t) }
        XCTAssertEqual(tr.value, 1.0, accuracy: 1e-12)

        // Finger relaxes to a normal size: down the same straight line.
        for _ in 0..<10 { t += dt; tr.sample(radiusPt: lo, at: t) }
        XCTAssertEqual(tr.value, 0.5, accuracy: 1e-12)
        // Finger lifts: nil targets rest, at the same rate, and stops at 0.
        for _ in 0..<22 { t += dt; tr.sample(radiusPt: nil, at: t) }
        XCTAssertEqual(tr.value, 0.0, accuracy: 1e-12)
    }

    /// A step SMALLER than one tick's allowance arrives exactly, in one
    /// step — the limiter caps the rate, it does not filter the value.
    func testASmallStepArrivesExactly() {
        var tr = TouchSizeTracker()
        tr.sample(radiusPt: lo, at: 0)
        let target = lo + 0.02 * (hi - lo)          // 2 % of the range
        // One rampS/20 tick allows 5 % of the range, so 2 % arrives whole.
        let v = tr.sample(radiusPt: target, at: rampS / 20.0)
        XCTAssertEqual(v, 0.02, accuracy: 1e-12)
    }

    // MARK: - The newest-touch rule

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

    /// The axis follows the NEWEST sounding touch, and a release falls back
    /// to the surviving one. The axis is UNIPOLAR: rest reads the curve's
    /// LEFT end, a fully flattened finger its right.
    func testAxisFollowsTheNewestSoundingTouch() {
        let e = ControlAxisEvaluator()
        let slot0 = MapTarget(compositeSlot: 0)
        let lock = NSLock()
        var last: Double?
        e.onApply = { apps in
            lock.lock()
            if let v = apps.first(where: { $0.target == slot0 })?.value {
                last = v
            }
            lock.unlock()
        }
        e.setMapping(mapping([
            (slot0, DimensionBinding(dimension: .touchSize,
                                     rangeMin: 0, rangeMax: 1)),
        ]))
        func read() -> Double {
            lock.lock(); defer { lock.unlock() }; return last ?? 0
        }
        func settle() {
            // The 30 Hz tick advances the limiter; the full ramp is 0.5 s.
            let deadline = Date().addingTimeInterval(rampS + 0.2)
            RunLoop.current.run(until: deadline)
        }

        // One flattened finger drives the axis to the top.
        e.touchGate(lane: .wire, id: 1, on: true)
        e.touchRadius(lane: .wire, id: 1, radiusPt: hi)
        settle()
        XCTAssertEqual(read(), 1.0, accuracy: 0.02)

        // A second, NORMAL finger lands: it is newest, so the axis follows
        // it back to rest even though finger 1 is still flattened.
        e.touchGate(lane: .wire, id: 2, on: true)
        e.touchRadius(lane: .wire, id: 2, radiusPt: lo)
        settle()
        XCTAssertEqual(read(), 0.0, accuracy: 0.02)

        // Releasing the newest falls back to the survivor — still flattened.
        e.touchGate(lane: .wire, id: 2, on: false)
        settle()
        XCTAssertEqual(read(), 1.0, accuracy: 0.02)

        // Everything lifts: the axis ramps to rest.
        e.touchGate(lane: .wire, id: 1, on: false)
        settle()
        XCTAssertEqual(read(), 0.0, accuracy: 0.02)
    }

    /// Nothing bound to `.touchSize` = nothing driven (the tick is not even
    /// armed), so an idle rig pays no cost.
    func testUnboundAxisNeverApplies() {
        let e = ControlAxisEvaluator()
        let lock = NSLock()
        var count = 0
        e.onApply = { lock.lock(); count += $0.count; lock.unlock() }
        e.setMapping(mapping([
            (MapTarget(compositeSlot: 0),
             DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 1)),
        ]))
        e.touchGate(lane: .wire, id: 1, on: true)
        e.touchRadius(lane: .wire, id: 1, radiusPt: hi)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        lock.lock(); let n = count; lock.unlock()
        XCTAssertEqual(n, 0)
    }
}
