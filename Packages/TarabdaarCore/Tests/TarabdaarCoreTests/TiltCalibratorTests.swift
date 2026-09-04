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

    func testOrthogonalSolveClaimsOneAxisPerSweepAndIgnoresLeakage() {
        let cal = TiltCalibrator(config: .wrist, defaults: isolatedDefaults())
        var t = 0.0
        let rest = SIMD3<Double>(0.1, -0.2, 0)
        capture(cal, rest: rest,
                dirs: [SIMD3(1, 0.4, 0), SIMD3(0.3, 0, 1), SIMD3(0, 1, 0.2)],
                amps: [0.5, 0.3, 0.4], t: &t)
        XCTAssertTrue(cal.isCalibrated, cal.info)
        XCTAssertEqual(cal.currentModel!.m, [[1, 0, 0], [0, 0, 1], [0, 1, 0]])
        var last: (Double, Double, Double)?
        cal.onAxes = { last = ($0, $1, $2) }
        feed(cal, rest + SIMD3(0, 0.4, 0), n: 40, t: &t)
        XCTAssertEqual(last!.2, 1, accuracy: 0.03)
        XCTAssertEqual(last!.0, 0)
        XCTAssertEqual(last!.1, 0)
        // A second sweep on an already-claimed axis repeats itself.
        let dup = TiltCalibrator(config: .wrist, defaults: isolatedDefaults())
        dup.begin()
        feed(dup, rest, n: 30, t: &t)
        dup.advance()
        sweep(dup, rest: rest, dir: SIMD3(1, 0, 0), amp: 0.5, t: &t)
        dup.advance()
        sweep(dup, rest: rest, dir: SIMD3(1, 0.5, 0), amp: 0.5, t: &t)
        dup.advance()
        XCTAssertEqual(dup.step, 2, dup.detail)
    }
}
