import XCTest
@testable import SarangiKit

final class BowAttackTests: XCTestCase {
    private func trace(sharpness: Double, overrides: [String: Double] = [:],
                       changedSharpness: Double? = nil) -> [[Double]] {
        var bp = BowedStringEngineTests.stringBP()
        for (k, v) in overrides { bp.num[k] = v }
        var filter = BowControlFilter(bp: bp, srk: 96000)
        let buffers = (0..<5).map { _ in UnsafeMutablePointer<Double>.allocate(capacity: 256) }
        defer { buffers.forEach { $0.deallocate() } }
        let mapper = BowControlMapper()
        mapper.setAttackSharpness(sharpness)
        mapper.touchOn(1, pitchSemis: Pitch.fractionalMidi(hz: 328.9))
        var result = [[Double]](repeating: [], count: 5)
        for block in 0..<400 {
            if block == 1, let changedSharpness { mapper.setAttackSharpness(changedSharpness) }
            if block == 350 { mapper.touchOff(1) }
            filter.fill(snapshot: mapper.snapshot(), n: 256, f0: buffers[0], vb: buffers[1],
                        fb: buffers[2], beta: buffers[3], gate: buffers[4])
            for k in buffers.indices { result[k].append(contentsOf: UnsafeBufferPointer(start: buffers[k], count: 256)) }
        }
        return result
    }

    /// One bounded bow engagement preserves force/speed ratio, captures sharpness once, and shares sustain and release.
    func testSingleEngagementAndCapturedSharpness() {
        let gentle = trace(sharpness: 0)
        let sharp = trace(sharpness: 1)
        XCTAssertEqual(gentle[1][0], 0)
        XCTAssertGreaterThan(gentle[1][64], 0, "the draw starts without a placement delay")
        XCTAssertGreaterThan(sharp[1][960], 10 * gentle[1][960])
        XCTAssertEqual(sharp, trace(sharpness: 1, changedSharpness: 0), "a held touch must not recapture sharpness")
        for path in [gentle, sharp] {
            let speed = path[1][90000], force = path[2][90000]
            for i in stride(from: 0, to: 90000, by: 31) {
                XCTAssertEqual(path[1][i] / speed, path[2][i] / force, accuracy: 1e-12,
                               "independent envelopes must not move the bow's force/speed ratio")
                XCTAssertGreaterThanOrEqual(path[1][i], 0)
                XCTAssertLessThanOrEqual(path[1][i], speed)
            }
        }
        for k in [1, 2, 3] {
            XCTAssertEqual(sharp[k].suffix(256), gentle[k].suffix(256), "both attacks return to the same sustained bow")
        }
        XCTAssertEqual(sharp[4].suffix(4096), gentle[4].suffix(4096), "release keeps the shared lift time")
    }

    /// Overlapping onsets capture independent sharpness before rendering and ignore subsequent pressure changes.
    func testIndependentOnsetCapture() {
        let mapper = BowControlMapper()
        mapper.setSlotLimit(3)
        mapper.setAttackSharpness(0.2)
        mapper.touchOn(1, pitchSemis: 60)
        mapper.setAttackSharpness(0.8)
        mapper.touchOn(2, pitchSemis: 64)
        mapper.setAttackSharpness(0)
        mapper.setAxis(press: 1)
        mapper.touchGlide(1, pitchSemis: 61)
        var snapshot = BowControlMapper.PolySnapshot(count: 3)
        mapper.snapshotPoly(into: &snapshot)
        XCTAssertEqual(snapshot.slots[0].attackSharpness, 0.2)
        XCTAssertEqual(snapshot.slots[1].attackSharpness, 0.8)
        mapper.touchOn(1, pitchSemis: 61)
        mapper.snapshotPoly(into: &snapshot)
        XCTAssertEqual(snapshot.slots[2].attackSharpness, 0)
    }

    /// Retired preset knobs cannot reintroduce placement, competing ramps, accents, or a post-onset dip.
    func testRetiredAttackOverridesAreInert() {
        let retired = ["bow_place_ms": 120.0, "bow_draw_ms": 200,
                       "bow_draw_min_ms": 60, "bow_attack_fms": 60,
                       "bow_attack_bite": 4, "bow_attack_bite_ms": 200,
                       "bow_attack_beta": 0.7, "bow_attack_speed_db": 12,
                       "bow_settle_db": 12, "bow_settle_ms": 500, "bow_settle_sharp": 1]
        for sharpness in [0.0, 0.5, 1.0] {
            XCTAssertEqual(trace(sharpness: sharpness), trace(sharpness: sharpness, overrides: retired))
        }
    }
}
