import XCTest
import simd
@testable import TarabdaarCore

/// The guided calibration's two solves: joint (arm) separates non-perpendicular sweeps; orthogonal (wrist) gives each sweep one attitude axis and ignores cross-axis leakage.
final class TiltCalibratorTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "TiltCalibratorTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func feed(_ cal: TiltCalibrator, _ f: SIMD3<Double>, n: Int, t: inout Double) {
        for _ in 0..<n { cal.tick(f, at: t); t += 1.0 / 60 }
    }

    /// Rest → +a → −a → rest along `dir`, with rest windows at both ends.
    private func sweep(_ cal: TiltCalibrator, rest: SIMD3<Double>, dir: SIMD3<Double>,
                       amp: Double, t: inout Double) {
        feed(cal, rest, n: 20, t: &t)
        for i in 0...60 {
            feed(cal, rest + dir * (amp * sin(Double(i) / 60 * 2 * .pi)), n: 1, t: &t)
        }
        feed(cal, rest, n: 20, t: &t)
    }

    private func capture(_ cal: TiltCalibrator, rest: SIMD3<Double>,
                         dirs: [SIMD3<Double>], amps: [Double], t: inout Double) {
        cal.begin()
        feed(cal, rest, n: 40, t: &t)
        cal.advance()
        for (d, a) in zip(dirs, amps) {
            sweep(cal, rest: rest, dir: d, amp: a, t: &t)
            cal.advance()
        }
    }

    func testJointSolveSeparatesNonPerpendicularSweeps() {
        let cal = TiltCalibrator(config: .arm, defaults: isolatedDefaults())
        var t = 0.0
        let rest = SIMD3<Double>(0.2, -0.1, 0.05)
        let d1 = simd_normalize(SIMD3<Double>(1, 0.3, 0))
        let d2 = simd_normalize(SIMD3<Double>(0.3, 1, 0.2))
        let d3 = simd_normalize(SIMD3<Double>(0, 0.2, 1))
        capture(cal, rest: rest, dirs: [d1, d2, d3], amps: [0.5, 0.4, 0.3], t: &t)
        XCTAssertTrue(cal.isCalibrated, cal.info)
        var last: (Double, Double, Double)?
        cal.onAxes = { last = ($0, $1, $2) }
        feed(cal, rest + d2 * 0.4, n: 40, t: &t)
        XCTAssertEqual(last!.1, 1, accuracy: 0.05)
        XCTAssertEqual(last!.0, 0, accuracy: 0.05)
        XCTAssertEqual(last!.2, 0, accuracy: 0.05)
        feed(cal, rest - d1 * 0.5, n: 40, t: &t)
        XCTAssertEqual(last!.0, -1, accuracy: 0.05)
    }

    func testOrthogonalSolveTakesSweepOneExactlyAndInfersTheThird() {
        let cal = TiltCalibrator(config: .wrist, defaults: isolatedDefaults())
        var t = 0.0
        let rest = SIMD3<Double>(0.1, -0.2, 0)
        let d1 = simd_normalize(SIMD3<Double>(1, 0.4, 0))
        // Sweep 2 leans 30° toward sweep 1: its shared part must drop.
        let d2raw = simd_normalize(SIMD3<Double>(0, 0, 1) + d1 * 0.58)
        capture(cal, rest: rest, dirs: [d1, d2raw], amps: [0.5, 0.4], t: &t)
        XCTAssertTrue(cal.isCalibrated, cal.info)
        let m = cal.currentModel!.m.map { SIMD3<Double>($0[0], $0[1], $0[2]) }
        XCTAssertEqual(simd_dot(m[0], d1), 1, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(m[1], m[0]), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_length(simd_cross(m[0], m[1]) - m[2]), 0, accuracy: 1e-9)
        var last: (Double, Double, Double)?
        cal.onAxes = { last = ($0, $1, $2) }
        feed(cal, rest + d1 * 0.5, n: 40, t: &t)
        XCTAssertEqual(last!.0, 1, accuracy: 0.03)
        XCTAssertEqual(last!.1, 0, accuracy: 1e-6)
        XCTAssertEqual(last!.2, 0, accuracy: 1e-6)
        feed(cal, rest + m[2] * 0.3, n: 40, t: &t)
        XCTAssertGreaterThan(last!.2, 0.5)
        XCTAssertEqual(last!.0, 0, accuracy: 1e-6)
        // A second sweep along sweep 1's axis repeats itself.
        let dup = TiltCalibrator(config: .wrist, defaults: isolatedDefaults())
        dup.begin()
        feed(dup, rest, n: 30, t: &t)
        dup.advance()
        sweep(dup, rest: rest, dir: d1, amp: 0.5, t: &t)
        dup.advance()
        sweep(dup, rest: rest, dir: d1, amp: 0.5, t: &t)
        dup.advance()
        XCTAssertEqual(dup.step, 2, dup.detail)
    }

    /// A reconnected stream emits an unchanged pose without altering either calibration.
    func testReconnectRearmsOutputWithoutChangingCalibration() {
        let defaults = isolatedDefaults()
        let wristModel = TiltCalibrator.Model(f0: [0.1, 0.2, 0.3],
            m: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
            lo: [-0.5, -0.5, -0.5], hi: [0.5, 0.5, 0.5])
        let armModel = TiltCalibrator.Model(f0: [-0.1, -0.2, -0.3],
            m: [[0, 1, 0], [1, 0, 0], [0, 0, 1]],
            lo: [-0.3, -0.4, -0.5], hi: [0.6, 0.7, 0.8])
        DefaultsStore.save(wristModel, key: TiltCalibrator.Config.wrist.key, to: defaults)
        DefaultsStore.save(armModel, key: TiltCalibrator.Config.arm.key, to: defaults)
        let cal = TiltCalibrator(config: .wrist, defaults: defaults)
        var outputs: [SIMD3<Double>] = []
        cal.onAxes = { outputs.append(SIMD3($0, $1, $2)) }
        let pose = SIMD3<Double>(0.2, 0.3, 0.4)
        cal.tick(pose, at: 1)
        cal.tick(pose, at: 2)
        XCTAssertEqual(outputs.count, 1)
        cal.resetInput()
        cal.tick(pose, at: 3)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs.first, outputs.last)
        XCTAssertEqual(cal.currentModel, wristModel)
        XCTAssertEqual(TiltCalibrator(config: .wrist, defaults: defaults).currentModel, wristModel)
        XCTAssertEqual(TiltCalibrator(config: .arm, defaults: defaults).currentModel, armModel)
    }

    /// Reversal negates only the selected output, including asymmetric ranges, and survives reload.
    func testReverseAxisPreservesCalibrationAndPersists() throws {
        let defaults = isolatedDefaults()
        var config = TiltCalibrator.Config.wrist
        config.smoothAlpha = 1
        let original = TiltCalibrator.Model(
            f0: [0.1, -0.2, 0.05],
            m: [[0.6, 0.8, 0], [-0.8, 0.6, 0], [0, 0, 1]],
            lo: [-0.2, -0.3, -0.4], hi: [0.5, 0.6, 0.7])
        DefaultsStore.save(original, key: config.key, to: defaults)
        let cal = TiltCalibrator(config: config, defaults: defaults)
        var t = 1.0
        var output = SIMD3<Double>(repeating: 0)
        cal.onAxes = { output = SIMD3($0, $1, $2) }
        for axis in 0..<3 {
            for amount in [-2.0, -0.5, 0, 0.5, 2.0] {
                let coordinates = SIMD3<Double>(0.2, -0.1, 0.3) * amount
                let pose = SIMD3<Double>(original.f0[0], original.f0[1], original.f0[2])
                    + SIMD3<Double>(0.6, 0.8, 0) * coordinates.x
                    + SIMD3<Double>(-0.8, 0.6, 0) * coordinates.y
                    + SIMD3<Double>(0, 0, 1) * coordinates.z
                feed(cal, pose, n: 1, t: &t)
                let before = output
                var expected = before
                expected[axis] = -expected[axis]
                cal.reverseAxis(axis)
                XCTAssertEqual(output, expected)
                XCTAssertEqual(cal.axes, [expected.x, expected.y, expected.z])
                XCTAssertEqual(cal.currentModel?.f0, original.f0)

                let reloaded = TiltCalibrator(config: config, defaults: defaults)
                reloaded.onAxes = { output = SIMD3($0, $1, $2) }
                feed(reloaded, pose, n: 1, t: &t)
                XCTAssertEqual(output, expected)
                reloaded.recenter()
                feed(reloaded, pose, n: 1, t: &t)
                XCTAssertEqual(output, .zero)

                cal.reverseAxis(axis)
                XCTAssertEqual(output, before)
                XCTAssertEqual(cal.currentModel, original)
                let restored = TiltCalibrator(config: config, defaults: defaults)
                XCTAssertEqual(restored.currentModel, original)
                let geometry = try XCTUnwrap(cal.viz)
                XCTAssertEqual(geometry.axes[axis].lo, original.lo[axis])
                XCTAssertEqual(geometry.axes[axis].hi, original.hi[axis])
            }
        }
        cal.begin()
        cal.reverseAxis(0)
        XCTAssertEqual(cal.currentModel, original)
        cal.cancel()
        cal.reverseAxis(-1)
        cal.reverseAxis(3)
        XCTAssertEqual(cal.currentModel, original)
    }
}
