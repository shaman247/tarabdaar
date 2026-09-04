import XCTest
@testable import TarabdaarCore

/// The fingertip-flatten law: the onset baseline, the hysteresis band, and
/// the deliberate consequence that a touch which lands ALREADY flattened
/// reads un-flattened until it drops and rises again.
final class TouchFlattenTests: XCTestCase {

    private let step = Config.touchFlattenStepPt

    /// Feed a constant radius across the whole baseline window.
    private func settled(_ d: inout TouchFlattenDetector, id: Int,
                         radius: Double, from t0: TimeInterval = 0) -> TimeInterval {
        d.begin(id, radiusPt: radius, at: t0)
        var t = t0
        while t < t0 + TouchFlattenDetector.baselineWindowS + 0.01 {
            t += 0.03
            d.sample(id, radiusPt: radius, at: t)
        }
        return t
    }

    func testBaselineIsTheMedianOfTheOnsetWindow() {
        var d = TouchFlattenDetector()
        d.begin(0, radiusPt: 20, at: 0)
        // A landing finger ramps, with one wild outlier; the median must
        // sit in the body of the samples, not be dragged by the spike.
        for (i, r) in [21.0, 22.0, 900.0, 22.0].enumerated() {
            d.sample(0, radiusPt: r, at: 0.03 * Double(i + 1))
        }
        d.sample(0, radiusPt: 22, at: TouchFlattenDetector.baselineWindowS)
        XCTAssertEqual(d.baseline(0) ?? 0, 22.0, accuracy: 1e-9)
        XCTAssertFalse(d.isFlattened(0))
    }

    /// The window is open until `baselineWindowS`: nothing reads flattened
    /// while the reference is still being measured.
    func testNoFlattenBeforeTheBaselineCloses() {
        var d = TouchFlattenDetector()
        d.begin(0, radiusPt: 20, at: 0)
        XCTAssertFalse(d.sample(0, radiusPt: 20 + 4 * step, at: 0.05))
        XCTAssertNil(d.baseline(0))
    }

    /// A motionless touch still closes its window on a plain tick (UIKit
    /// only reports a finger that moves).
    func testTickClosesTheWindowWithoutNewSamples() {
        var d = TouchFlattenDetector()
        d.begin(0, radiusPt: 18, at: 0)
        d.tick(0, at: 0.05)
        XCTAssertNil(d.baseline(0))
        d.tick(0, at: TouchFlattenDetector.baselineWindowS + 0.01)
        XCTAssertEqual(d.baseline(0) ?? 0, 18.0, accuracy: 1e-9)
    }

    func testHysteresisBand() {
        var d = TouchFlattenDetector()
        var t = settled(&d, id: 0, radius: 20)
        XCTAssertEqual(d.baseline(0) ?? 0, 20.0, accuracy: 1e-9)

        // Just under a full step: still un-flattened.
        t += 0.03
        XCTAssertFalse(d.sample(0, radiusPt: 20 + step - 0.01, at: t))
        // A full step up: flattened.
        t += 0.03
        XCTAssertTrue(d.sample(0, radiusPt: 20 + step, at: t))
        // Falling back INTO the band holds the flattened state.
        t += 0.03
        XCTAssertTrue(d.sample(0, radiusPt: 20 + 0.6 * step, at: t))
        // Below half a step: released.
        t += 0.03
        XCTAssertFalse(d.sample(0, radiusPt: 20 + 0.5 * step, at: t))
        // And it re-arms.
        t += 0.03
        XCTAssertTrue(d.sample(0, radiusPt: 20 + step + 1, at: t))
    }

    /// DOCUMENTED CONSEQUENCE of the relative baseline: a finger that lands
    /// already flattened reads UN-flattened (its flattened size IS its
    /// baseline). It only triggers after relaxing and flattening again.
    func testATouchThatStartsFlattenedStaysUnflattenedUntilItDropsAndRises() {
        var d = TouchFlattenDetector()
        var t = settled(&d, id: 0, radius: 20 + step)   // born flat
        XCTAssertFalse(d.isFlattened(0))
        // Holding that size forever changes nothing.
        for _ in 0..<20 {
            t += 0.03
            XCTAssertFalse(d.sample(0, radiusPt: 20 + step, at: t))
        }
        // Relax to a normal fingertip…
        t += 0.03
        XCTAssertFalse(d.sample(0, radiusPt: 20, at: t))
        // …then flatten again: now it fires, one step above the BASELINE.
        t += 0.03
        XCTAssertTrue(d.sample(0, radiusPt: 20 + 2 * step, at: t))
    }

    /// Baselines are per touch, and `end` forgets one.
    func testPerTouchIndependenceAndEnd() {
        var d = TouchFlattenDetector()
        var t = settled(&d, id: 1, radius: 12)
        _ = settled(&d, id: 2, radius: 30, from: t)
        t += TouchFlattenDetector.baselineWindowS + 0.05
        XCTAssertTrue(d.sample(1, radiusPt: 12 + step, at: t))
        XCTAssertFalse(d.sample(2, radiusPt: 12 + step, at: t))  // way below 30
        d.end(1)
        XCTAssertNil(d.baseline(1))
        XCTAssertFalse(d.isFlattened(1))
        XCTAssertNotNil(d.baseline(2))
    }

    /// A producer with no touchscreen (radius 0 everywhere) never flattens.
    func testUnknownRadiusNeverFlattens() {
        var d = TouchFlattenDetector()
        let t = settled(&d, id: 0, radius: 0)
        XCTAssertEqual(d.baseline(0) ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertFalse(d.sample(0, radiusPt: 0, at: t + 0.03))
    }

    // MARK: - The vibrato ease

    /// Depth eases 0 → 1 over `flattenVibratoEaseInS` while flattened and
    /// back over `flattenVibratoEaseOutS`, per touch, and a touch this
    /// controller never drove is never pushed.
    func testFlattenVibratoEase() {
        let fv = FlattenVibrato(tickHz: 30, autoTick: false)
        var pushes: [(UInt16, Double)] = []
        fv.onDepth = { pushes.append(($0, $1)) }

        var t = 100.0
        fv.touchGate(7, true)
        fv.touchRadius(7, radiusPt: 20, at: t)
        // Untouched second note: nothing must ever be pushed for it.
        fv.touchGate(9, true)

        // Baseline window (no flatten yet) — and no pushes at all.
        for _ in 0..<6 { t += 1.0 / 30.0; fv.tick(dt: 1.0 / 30.0, now: t) }
        XCTAssertTrue(pushes.isEmpty)
        XCTAssertEqual(fv.depth(for: 7), 0, accuracy: 1e-9)

        // Flatten: the depth eases in over ~2 s.
        fv.touchRadius(7, radiusPt: 20 + Config.touchFlattenStepPt, at: t)
        for _ in 0..<30 { t += 1.0 / 30.0; fv.tick(dt: 1.0 / 30.0, now: t) }
        XCTAssertEqual(fv.depth(for: 7),
                       1.0 / Config.flattenVibratoEaseInS, accuracy: 0.05)
        for _ in 0..<60 { t += 1.0 / 30.0; fv.tick(dt: 1.0 / 30.0, now: t) }
        XCTAssertEqual(fv.depth(for: 7), 1.0, accuracy: 1e-9)
        XCTAssertTrue(pushes.allSatisfy { $0.0 == 7 })

        // Un-flatten: back to 0 over ~0.5 s, and it stops there.
        fv.touchRadius(7, radiusPt: 20, at: t)
        for _ in 0..<20 { t += 1.0 / 30.0; fv.tick(dt: 1.0 / 30.0, now: t) }
        XCTAssertEqual(fv.depth(for: 7), 0.0, accuracy: 1e-9)
        XCTAssertEqual(pushes.last?.1 ?? -1, 0.0, accuracy: 1e-9)

        // A released touch is eased out and dropped, never left ringing
        // with depth.
        fv.touchGate(7, false)
        for _ in 0..<20 { t += 1.0 / 30.0; fv.tick(dt: 1.0 / 30.0, now: t) }
        XCTAssertEqual(fv.depth(for: 7), 0.0, accuracy: 1e-9)
        XCTAssertFalse(pushes.contains { $0.0 == 9 })
    }
}
