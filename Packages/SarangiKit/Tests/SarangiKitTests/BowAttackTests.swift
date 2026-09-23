import XCTest
@testable import SarangiKit

final class BowAttackTests: XCTestCase {
    private func trace(sharpness: Double, overrides: [String: Double] = [:],
                       changedSharpness: Double? = nil) -> [[Double]] {
        var bp = BowedStringEngineTests.stringBP()
        for (k, v) in ["bow_place_ms": 0.0, "bow_draw_ms": 180,
                       "bow_draw_min_ms": 5, "bow_attack_fms": 3,
                       "bow_attack_bite_ms": 60] { bp.num[k] = v }
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

    /// Zero placement starts a finite draw, sharp draw time remains effective, and sharpness stays onset-captured.
    func testFiniteDrawAndCapturedSharpness() {
        let gentle = trace(sharpness: 0)
        let sharp = trace(sharpness: 1)
        let slowSharp = trace(sharpness: 1, overrides: ["bow_draw_min_ms": 40])
        XCTAssertEqual(gentle[1][0], 0)
        XCTAssertGreaterThan(gentle[1][64], 0, "zero placement must not hold or bypass the draw")
        XCTAssertGreaterThan(sharp[1][960], 5 * slowSharp[1][960])
        XCTAssertGreaterThan(sharp[1][960], 10 * gentle[1][960])
        XCTAssertEqual(sharp, trace(sharpness: 1, changedSharpness: 0), "a held touch must not recapture sharpness")
        for k in [1, 2, 3] {
            XCTAssertEqual(sharp[k].suffix(256), gentle[k].suffix(256), "both attacks return to the same sustained bow")
        }
        XCTAssertEqual(sharp[4].last!, gentle[4].last!, accuracy: 1e-10, "release keeps the shared lift time")
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

    /// Attack color is null for a gentle onset and returns exactly to the unmodified sustained controls.
    func testAttackColorIsTransientAndZeroIsNull() {
        let color = ["bow_attack_beta": 0.6, "bow_attack_speed_db": 8.0]
        XCTAssertEqual(trace(sharpness: 0), trace(sharpness: 0, overrides: color))
        XCTAssertEqual(trace(sharpness: 1), trace(sharpness: 1,
            overrides: ["bow_attack_beta": 0, "bow_attack_speed_db": 0]))
        let plain = trace(sharpness: 1), colored = trace(sharpness: 1, overrides: color)
        XCTAssertLessThan(colored[3][960], plain[3][960])
        XCTAssertGreaterThan(colored[1][960], plain[1][960])
        for k in plain.indices {
            XCTAssertTrue(colored[k].allSatisfy(\.isFinite))
            XCTAssertEqual(plain[k].suffix(4096), colored[k].suffix(4096))
        }
    }
}
