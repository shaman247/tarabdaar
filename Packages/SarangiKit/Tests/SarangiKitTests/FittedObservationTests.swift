import XCTest
import CBowKernel
@testable import SarangiKit

final class FittedObservationTests: XCTestCase {
    /// Changing radiation residues leaves bridge mobility and string physics intact.
    func testRadiationIsObservationOnly() throws {
        var bp = try XCTUnwrap(Presets.bowedStringParams())
        let a = BowTables.buildOpenString(sr: 96000, tonic: 328.9, bp: bp)
        bp.num["bow_fit_body"] = 1
        let b = BowTables.buildOpenString(sr: 96000, tonic: 328.9, bp: bp)
        XCTAssertEqual(a.ba1, b.ba1); XCTAssertEqual(a.ba2, b.ba2)
        XCTAssertEqual(a.bn0, b.bn0); XCTAssertEqual(a.bA, b.bA)
        XCTAssertTrue(a.scalars.equalsFieldwise(b.scalars))
        XCTAssertNotEqual(a.bC, b.bC)
    }

    /// The full fitted room preserves every impulse tap across arbitrary callback boundaries and reset.
    func testRoomConvolutionAndReset() {
        let asset = BowFitAsset.shared, state = asset.create()
        defer { bow_fit_destroy(state) }
        bow_fit_set(state, 4, 1)
        func render(_ input: [Double], chunk: Int) -> [Double] {
            var y = input, side = [Double](repeating: 0, count: chunk)
            let hz = [Double](repeating: 330, count: 2*chunk)
            let speed = [Double](repeating: 0.03, count: 2*chunk)
            let force = [Double](repeating: 0.1, count: 2*chunk)
            let beta = [Double](repeating: 0.15, count: 2*chunk)
            let gate = [Double](repeating: 0, count: 2*chunk)
            y.withUnsafeMutableBufferPointer { p in
                for i in stride(from: 0, to: input.count, by: chunk) {
                    bow_fit_process(state, p.baseAddress!+i, &side, nil,
                                    Int32(min(chunk, input.count-i)), hz, speed,
                                    force, beta, gate, Int32(2*chunk), 1)
                }
            }
            return y
        }
        _ = render([Double](repeating: 0, count: 48000), chunk: 127)
        var pulse = [Double](repeating: 0, count: asset.roomFrames+500)
        pulse[17] = 0.1
        let y = render(pulse, chunk: 127)
        var error = 0.0
        for k in 0..<asset.roomFrames {
            let h = (0..<3).reduce(0.0) { $0 + Double(BowFitAsset.room[$1*asset.roomFrames+k]) }
            error = max(error, abs(y[k+17]-pulse[k+17]-0.1*h))
        }
        XCTAssertLessThan(error, 1e-9)
        bow_fit_reset(state)
        let quiet = render([Double](repeating: 0, count: 5000), chunk: 256)
        XCTAssertTrue(quiet.allSatisfy { $0 == 0 })
    }
}
