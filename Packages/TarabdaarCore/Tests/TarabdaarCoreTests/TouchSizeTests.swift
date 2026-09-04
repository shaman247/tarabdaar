import XCTest
@testable import TarabdaarCore

/// The `.touchSize` law: the measured points → 0…1 window and its clamps,
/// the finger-motion estimator that reads the quantised radius staircase
/// as position fixes, and the newest-sounding-touch rule the
/// `ControlAxisEvaluator` drives it under.
final class TouchSizeTests: XCTestCase {

    private let lo = Config.touchSizeLoPt      // 31.3 — normal fingertip
    private let hi = Config.touchSizeHiPt      // 73.0 — deliberately flattened
    private let trueVel = Config.touchSizeDefaultVelPtS   // 83.4 pt/s

    /// The reported levels: multiples of the ≈10.42 pt quantum.
    private let steps = [31.3, 41.7, 52.1, 62.5, 73.0]

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

    // MARK: - The estimator

    /// Run a quantised staircase at 120 Hz: `levels[i]` from `i · stepS`.
    private func staircase(_ levels: [Double], stepS: Double,
                           forS: Double) -> [(t: Double, v: Double)] {
        var tr = TouchSizeTracker()
        var out: [(t: Double, v: Double)] = []
        let n = Int(forS * 120)
        for i in 0...n {
            let t = Double(i) / 120.0
            let k = min(Int(t / stepS + 1e-9), levels.count - 1)
            out.append((t, tr.sample(radiusPt: levels[k], at: t)))
        }
        return out
    }

    /// Axis velocity over `[a, b]`, back in points per second.
    private func velocityPtS(_ o: [(t: Double, v: Double)],
                             _ a: Double, _ b: Double) -> Double {
        func at(_ t: Double) -> Double {
            o.min { abs($0.t - t) < abs($1.t - t) }!.v
        }
        return (at(b) - at(a)) / (b - a) * (hi - lo)
    }

    /// A flatten at the measured speed: the estimator reads the staircase
    /// as a continuous 83 pt/s finger, monotone, with no plateau between
    /// crossings — a rate limiter stalls at each level until the next lands.
    func testStaircaseTracksTheFingerWithoutPlateaus() {
        let o = staircase(steps, stepS: 0.125, forS: 1.0)

        for i in 1..<o.count {
            XCTAssertGreaterThanOrEqual(o[i].v, o[i - 1].v - 1e-9,
                                        "output must not reverse")
        }
        let v = velocityPtS(o, 0.25, 0.45)
        XCTAssertEqual(v, trueVel, accuracy: 0.3 * trueVel,
                       "mid-gesture speed within ±30 % of the real finger")

        // Longest run of a standing output while crossings keep arriving.
        var run = 0, worst = 0
        var prev: Double?
        for s in o where s.t >= 0.13 && s.t <= 0.5 {
            if let p = prev {
                if abs(s.v - p) < 1e-4 { run += 1; worst = max(worst, run) }
                else { run = 0 }
            }
            prev = s.v
        }
        XCTAssertLessThan(Double(worst) / 120.0, 0.040,
                          "no plateau longer than 40 ms mid-gesture")
        XCTAssertEqual(o.last!.v, 1.0, accuracy: 1e-9)
    }

    /// The SAME staircase walked half as fast tracks at half the speed:
    /// two consecutive crossings measure the finger, they do not assume it.
    func testHalfSpeedStaircaseTracksAtHalfTheVelocity() {
        let o = staircase(steps, stepS: 0.25, forS: 1.6)
        let v = velocityPtS(o, 0.55, 0.95)
        XCTAssertEqual(v, trueVel / 2, accuracy: 0.3 * trueVel / 2)
    }

    /// One step and then silence: the estimate coasts to the bin edge, the
    /// finger is judged stopped, and it settles on the level's centre.
    func testASingleStepSettlesOnTheLevel() {
        var tr = TouchSizeTracker()
        for i in 0...15 { tr.sample(radiusPt: 31.3, at: Double(i) / 120.0) }
        let target = TouchSizeTracker.mapped(radiusPt: 41.7)
        var at06 = 0.0
        for i in 16...240 {
            let t = Double(i) / 120.0
            let v = tr.sample(radiusPt: 41.7, at: t)
            if abs(t - (0.125 + 0.6)) < 1.0 / 240.0 { at06 = v }
        }
        XCTAssertEqual(at06, target, accuracy: 0.03)      // ~0.6 s
        XCTAssertEqual(tr.value, target, accuracy: 0.01)  // ~1.9 s, settled
    }

    /// A fresh finger reads its OWN size at once — the level is the whole
    /// estimate — instead of sweeping there from whatever the last one left.
    func testAFreshTouchReadsItsLevelImmediately() {
        var curled = TouchSizeTracker()
        XCTAssertEqual(curled.sample(radiusPt: lo, at: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(curled.sample(radiusPt: lo, at: 1 / 120.0), 0,
                       accuracy: 1e-12)

        var flat = TouchSizeTracker()
        XCTAssertEqual(flat.sample(radiusPt: hi, at: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(flat.sample(radiusPt: hi, at: 1 / 120.0), 1,
                       accuracy: 1e-12)

        // And a lift relaxes to EXACT rest, not to a creep at the clamp.
        var t = 1 / 120.0
        for _ in 0..<120 { t += 1 / 120.0; flat.sample(radiusPt: nil, at: t) }
        XCTAssertEqual(flat.value, 0, accuracy: 1e-12)
    }

    /// Un-flattening walks the staircase back down and tracks downward.
    func testReverseStaircaseTracksDownward() {
        let o = staircase(steps.reversed(), stepS: 0.125, forS: 1.0)
        for i in 1..<o.count {
            XCTAssertLessThanOrEqual(o[i].v, o[i - 1].v + 1e-9)
        }
        XCTAssertEqual(velocityPtS(o, 0.25, 0.45), -trueVel,
                       accuracy: 0.3 * trueVel)
        XCTAssertEqual(o.last!.v, 0, accuracy: 1e-9)
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
            // The 30 Hz tick advances the estimator; a whole-window
            // traverse plus the settle is well under a second.
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
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

        // Everything lifts: the axis relaxes to rest.
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
