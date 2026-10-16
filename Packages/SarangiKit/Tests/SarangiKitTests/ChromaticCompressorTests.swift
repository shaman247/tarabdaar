import XCTest
import CBowKernel

final class ChromaticCompressorTests: XCTestCase {
    private func settledGain(mid: Double, side: Double = 0, voice: Double,
                             floor: Double = -40, rate: Double = 96000) -> Double {
        var state = bow_chromatic_compressor_t()
        bow_chromatic_compressor_init(&state, rate)
        bow_chromatic_compressor_set(&state, 4, 0.5, floor)
        var gain = 1.0
        for _ in 0..<Int(rate) {
            gain = bow_chromatic_compressor_gain(&state, mid, side, voice)
        }
        return gain
    }

    /// Sustained blooms obey the compression ratio and follow the voice above the floor.
    func testRelativeThresholdAndStereoLink() {
        let gain = settledGain(mid: 0.2, voice: 0.1)
        XCTAssertEqual(20 * log10(0.2 * gain / 0.05), 20 * log10(4.0) / 4, accuracy: 0.001)
        XCTAssertEqual(gain, settledGain(mid: 0.4, voice: 0.2), accuracy: 1e-12)
        XCTAssertEqual(gain, settledGain(mid: 0.1, side: 0.1, voice: 0.1), accuracy: 1e-12)
        XCTAssertEqual(gain, settledGain(mid: 0, side: -0.2, voice: 0.1), accuracy: 1e-12)
        XCTAssertEqual(gain, settledGain(mid: 0.2, voice: 0.1, rate: 48000), accuracy: 1e-8)
    }

    /// A silent voice leaves independent plucks below the floor untouched and louder ones audible.
    func testSilentVoiceFloorAndTail() {
        XCTAssertEqual(settledGain(mid: 0.005, voice: 0), 1)
        let gain = settledGain(mid: 0.1, voice: 0)
        XCTAssertGreaterThan(gain, 0.1)
        XCTAssertLessThan(gain, 1)
        XCTAssertGreaterThan(settledGain(mid: 0.1, voice: 0, floor: -20), gain)
        var state = bow_chromatic_compressor_t()
        bow_chromatic_compressor_init(&state, 96000)
        bow_chromatic_compressor_set(&state, 4, 0.5, -40)
        var previous = 1.0
        for sample in 0..<192000 {
            let pluck = 0.1 * exp(-Double(sample) / 16000)
            let g = bow_chromatic_compressor_gain(&state, pluck, 0, 0)
            XCTAssertTrue(g.isFinite && g > 0 && g <= 1)
            XCTAssertLessThan(abs(g - previous), 0.005)
            previous = g
        }
        XCTAssertGreaterThan(previous, 0.99)
    }

    /// Bypass recovers smoothly and returns to exact unity without stale attenuation on re-arm.
    func testLiveBypassAndRearm() {
        var state = bow_chromatic_compressor_t()
        bow_chromatic_compressor_init(&state, 96000)
        XCTAssertEqual(bow_chromatic_compressor_gain(&state, 10, 5, 0), 1)
        bow_chromatic_compressor_set(&state, 4, 0.5, -40)
        var gain = 1.0
        for _ in 0..<24000 { gain = bow_chromatic_compressor_gain(&state, 1, 0, 0) }
        XCTAssertLessThan(gain, 0.1)
        bow_chromatic_compressor_set(&state, 1, 0.5, -40)
        let first = bow_chromatic_compressor_gain(&state, 1, 0, 0)
        XCTAssertGreaterThan(first, gain)
        XCTAssertLessThan(first - gain, 0.001)
        for _ in 0..<576000 { gain = bow_chromatic_compressor_gain(&state, 0, 0, 0) }
        XCTAssertEqual(gain, 1)
        bow_chromatic_compressor_set(&state, 4, 0.5, -40)
        XCTAssertEqual(bow_chromatic_compressor_gain(&state, 0.005, 0, 0), 1)
    }
}
