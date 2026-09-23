import XCTest
import CBowKernel

final class RadiationTests: XCTestCase {
    /// Partition boundaries, ring wrap and silent tails preserve the full causal FIR.
    func testMatchesDirectConvolutionWithoutLatency() throws {
        for count in [1, 63, 64, 65, 128, 129, 2049] {
            let taps = (0..<count).map { cos(Double($0)*0.37)*exp(-Double($0)/700) }
            let filter = try XCTUnwrap(bow_radiation_create(taps, Int32(count)))
            defer { bow_radiation_destroy(filter) }
            var input = [Double](repeating: 0, count: 10000)
            input[0] = 1; input[63] = -0.4; input[64] = 0.7; input[2049] = 0.3
            for i in 2100..<4300 { input[i] = sin(Double(i)*1.31) + 0.2*cos(Double(i)*0.13) }
            input[8001] = -1
            for i in input.indices {
                var expected = 0.0
                for k in 0..<min(count, i+1) { expected += taps[k]*input[i-k] }
                let actual = bow_radiation_tick(filter, input[i])
                XCTAssertEqual(actual, expected, accuracy: 1e-11)
                if i > 6500 && i < 8001 { XCTAssertEqual(actual, 0) }
            }
        }
    }
}
