import XCTest
@testable import TarabdaarCore

final class AccelerationSmoothingTests: XCTestCase {
    /// Held inputs evolve independently of report cadence, bypass exactly, and reset without a tail.
    func testHeldInputAndBypass() {
        var sparse = AccelerationSmoother()
        sparse.setTime(0.2, at: 0)
        sparse.setInput(1, at: 0)
        var dense = sparse
        for i in 1...19 { _ = dense.value(at: Double(i) * 0.01) }
        XCTAssertEqual(sparse.value(at: 0.2), 1 - exp(-1), accuracy: 1e-12)
        XCTAssertEqual(dense.value(at: 0.2), sparse.value(at: 0.2), accuracy: 1e-12)
        sparse.setInput(0, at: 0.2)
        XCTAssertEqual(sparse.value(at: 0.4), (1 - exp(-1)) * exp(-1), accuracy: 1e-12)
        sparse.setTime(0, at: 0.4)
        for value in [0.0, 0.17, 1.0, 0.4, 0.0] {
            sparse.setInput(value, at: 0.4)
            XCTAssertEqual(sparse.value(at: 0.4), value)
        }
        dense.reset()
        XCTAssertEqual(dense.value(at: 10), 0)
    }

    /// Source filters are independent, leave Strike responsive, and clear on disconnect.
    func testEvaluatorRouting() {
        // The clock stays fixed once binding the sources arms the live timer.
        var time = 0.0
        let evaluator = ControlAxisEvaluator(now: { time })
        evaluator.setAccelerationSmoothing(.acceleration, milliseconds: 200)
        evaluator.setAccelerationSmoothing(.jcAccel, milliseconds: 400)
        evaluator.setStrikeMeasure(1)
        evaluator.applyAxis(ControlAxisEvaluator.jcAccelAxisIndex, 1)
        time = 0.2
        let targets = (0..<3).map { MapTarget(compositeSlot: $0) }
        let dimensions: [InputDimension] = [.acceleration, .jcAccel, .strike]
        let mapping = DimensionMapping(mappings: Dictionary(uniqueKeysWithValues:
            zip(targets, dimensions).map { target, dimension in
                (target.storageKey, ParameterMapping(bindings: [
                    DimensionBinding(dimension: dimension, rangeMin: 0, rangeMax: 1)
                ], defaultValue: 0))
            }))
        let lock = NSLock()
        var values: [MapTarget: Double] = [:]
        evaluator.onApply = { batch in
            lock.lock(); defer { lock.unlock() }
            for application in batch { values[application.target] = application.value }
        }
        func value(_ index: Int) -> Double {
            lock.lock(); defer { lock.unlock() }
            return values[targets[index]] ?? -1
        }
        evaluator.setMapping(mapping)
        evaluator.reapply()
        XCTAssertEqual(value(0), 1 - exp(-1), accuracy: 1e-12)
        XCTAssertEqual(value(1), 1 - exp(-0.5), accuracy: 1e-12)
        evaluator.setAccelerationSmoothing(.acceleration, milliseconds: 0)
        evaluator.setAccelerationSmoothing(.jcAccel, milliseconds: 0)
        evaluator.reapply()
        XCTAssertEqual(value(0), 1)
        XCTAssertEqual(value(1), 1)
        evaluator.touchGate(lane: .wire, id: 1, on: true)
        evaluator.reapply()
        XCTAssertEqual(value(2), 1)
        evaluator.resetAcceleration(.acceleration)
        evaluator.resetAcceleration(.jcAccel)
        XCTAssertEqual(value(0), 0)
        XCTAssertEqual(value(1), 0)
        XCTAssertEqual(value(2), 0)
        evaluator.setMapping(DimensionMapping(mappings: [:]))
    }
}
