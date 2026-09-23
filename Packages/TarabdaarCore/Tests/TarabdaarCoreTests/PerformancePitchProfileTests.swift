import XCTest
@testable import TarabdaarCore

final class PerformancePitchProfileTests: XCTestCase {
    /// Timing is independent of UI polls, polyphony shares time, and silence ages only the windows.
    func testOccupancyWindowsAndOctaveFolding() {
        var p = PerformancePitchProfile()
        p.configure(tonicSemis: 62, ratios: [1, 1.5], at: 0)
        p.setPitch(62, for: 1, at: 0)
        p.setPitch(74, for: 2, at: 0)
        p.setPitch(nil, for: 1, at: 2)
        p.setPitch(nil, for: 2, at: 2)
        p.setPitch(62 + 12 * log2(1.5), for: 3, at: 5)
        p.setPitch(nil, for: 3, at: 5.02)
        let snap = p.snapshot(at: 6)
        XCTAssertEqual(snap.performance[0], 2, accuracy: 1e-9)
        XCTAssertEqual(snap.performance.reduce(0, +), 2.02, accuracy: 1e-9)
        XCTAssertEqual(snap.short.reduce(0, +), 2.02, accuracy: 1e-9)
        XCTAssertEqual(p.snapshot(at: 20).short.reduce(0, +), 0)
        let later = p.snapshot(at: 70)
        XCTAssertEqual(later.medium.reduce(0, +), 0)
        XCTAssertEqual(later.performance, snap.performance)
        p.reset(at: 70)
        XCTAssertEqual(p.snapshot(at: 71).activeSeconds, 0)
    }

    /// Seed dwell rejects passing pitches and becomes an equal prior; tuning edits invalidate the profile.
    func testSeedAndTuningReset() {
        var p = PerformancePitchProfile()
        let ratios = [1.0, 1.125, 1.5]
        p.configure(tonicSemis: 62, ratios: ratios, at: 0)
        p.reset(at: 0, seed: true)
        p.setPitch(62, for: 1, at: 0)
        p.setPitch(62 + 12 * log2(1.125), for: 1, at: 0.5)
        p.setPitch(62 + 12 * log2(1.5), for: 1, at: 0.55)
        p.setPitch(nil, for: 1, at: 1)
        p.finishSeed(at: 1)
        let seed = p.snapshot(at: 1)
        XCTAssertEqual(seed.seededDegrees, [0, 2])
        let evidence = PerformancePitchProfile.degreeWeights(seed.performance, scale: ratios)
        XCTAssertGreaterThan(evidence[0], 0)
        XCTAssertEqual(evidence[0], evidence[2])
        XCTAssertEqual(evidence[1], 0)
        let gains = PerformancePitchProfile.gains(snapshot: seed, scale: ratios)
        XCTAssertEqual(gains[0], gains[2])
        XCTAssertLessThan(gains[1], gains[0])
        XCTAssertTrue(gains.allSatisfy { $0 >= 0 && $0 <= 1 })
        p.configure(tonicSemis: 64, ratios: ratios, at: 2)
        let reset = p.snapshot(at: 2)
        XCTAssertEqual(reset.activeSeconds, 0)
        XCTAssertTrue(reset.seededDegrees.isEmpty)
        XCTAssertEqual(PerformancePitchProfile.gains(snapshot: reset, scale: ratios), [1, 1, 1])
    }
}
