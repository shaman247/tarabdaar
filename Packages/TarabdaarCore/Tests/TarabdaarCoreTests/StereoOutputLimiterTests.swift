import XCTest
@testable import TarabdaarCore

final class StereoOutputLimiterTests: XCTestCase {
    /// Quiet audio is sample-identical after the declared delay, including after a reset.
    func testTransparentDelayAndReset() {
        for rate in [44_100.0, 48_000, 96_000] {
            for lookahead in [1.0, 5, 20] {
                let limiter = StereoOutputLimiter(sampleRate: rate,
                    settings: OutputLimiterSettings(lookaheadMS: lookahead))
                let input = (0..<2_000).map { Float(0.5 * sin(Double($0) * 0.137)) }
                for pass in 0..<2 {
                    if pass > 0 { limiter.reset() }
                    for index in 0..<(input.count + limiter.delayFrames) {
                        let sample = index < input.count ? input[index] : 0
                        let output = limiter.process(left: Double(sample), right: Double(-sample))
                        let expected = index >= limiter.delayFrames ? input[index - limiter.delayFrames] : 0
                        XCTAssertEqual(output.left, expected)
                        XCTAssertEqual(output.right, -expected)
                        XCTAssertEqual(output.gain, 1)
                    }
                }
            }
        }
    }

    /// Isolated and dense overloads stay below the ceiling without clipping samples or shifting pan.
    func testCeilingAndStereoLinkForBurstsAtDeviceRates() {
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for settings in [OutputLimiterSettings(),
                             .init(ceilingDB: -24, lookaheadMS: 1, releaseMS: 20),
                             .init(ceilingDB: 0, lookaheadMS: 20, releaseMS: 1000)] {
                let limiter = StereoOutputLimiter(sampleRate: rate, settings: settings)
                let ceiling = pow(10, settings.ceilingDB / 20)
                var seed: UInt64 = 0x8a41
                let count = Int(rate / 2)
                let input: [Double] = (0..<count).map { i in
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    let noise = Double(seed >> 32) / Double(UInt32.max) * 2 - 1
                    // Include sparse single-sample peaks, rapid reversals and a sustained overload.
                    let scale = i % 977 == 0 ? 64.0 : i % 8_000 < 3_000 ? 16.0 : 0.3
                    return noise * scale
                }
                for dominantRight in [false, true] {
                    limiter.reset()
                    for i in 0..<(count + limiter.delayFrames) {
                        let value = i < count ? input[i] : 0
                        let output = limiter.process(left: dominantRight ? value * -0.3 : value,
                                                     right: dominantRight ? value : value * -0.3)
                        let dominant = dominantRight ? output.right : output.left
                        let companion = dominantRight ? output.left : output.right
                        XCTAssertLessThanOrEqual(abs(Double(dominant)), ceiling + 1e-7)
                        XCTAssertEqual(Double(companion), Double(dominant) * -0.3, accuracy: 1e-7)
                        let delayed = i >= limiter.delayFrames ? input[i - limiter.delayFrames] : 0
                        // The envelope itself controls peaks; the numerical fallback does no work.
                        XCTAssertEqual(Double(dominant), delayed * output.gain, accuracy: 1e-7)
                    }
                }
            }
        }
    }

    /// A transient in one channel cannot step a steady signal in the other during attack or release.
    func testSmoothAttackAndRelease() {
        let limiter = StereoOutputLimiter(sampleRate: 48_000)
        var previous = 0.25
        var previousDelta = 0.0
        var maximumStep = 0.0
        var maximumCurvature = 0.0
        var minimumGain = 1.0
        var recovered: Float = 0
        for i in 0..<200_000 {
            let output = limiter.process(left: 0.25, right: (5_000..<5_200).contains(i) ? 4 : 0)
            if i > limiter.delayFrames {
                let delta = Double(output.left) - previous
                maximumStep = max(maximumStep, abs(delta))
                maximumCurvature = max(maximumCurvature, abs(delta - previousDelta))
                previousDelta = delta
            }
            if i == 5_000 + limiter.delayFrames {
                XCTAssertLessThanOrEqual(Double(output.right), StereoOutputLimiter.ceiling + 1e-7)
            }
            previous = Double(output.left)
            minimumGain = min(minimumGain, output.gain)
            recovered = output.left
        }
        XCTAssertLessThan(minimumGain, 0.23)
        XCTAssertLessThan(maximumStep, 0.002)
        XCTAssertLessThan(maximumCurvature, 0.00002)
        XCTAssertEqual(recovered, 0.25)
    }

    /// Sustained overload is attenuated as a waveform, without the harmonics of a waveshaping clipper.
    func testSustainedToneRemainsSinusoidal() {
        let limiter = StereoOutputLimiter(sampleRate: 48_000)
        var errorEnergy = 0.0
        var signalEnergy = 0.0
        for i in 0..<48_000 {
            let input = 2 * sin(2 * .pi * Double(i % 48) / 48)
            let output = limiter.process(left: input, right: input * 0.5)
            if i > 24_000 {
                let expected = StereoOutputLimiter.ceiling * sin(2 * .pi * Double((i - limiter.delayFrames) % 48) / 48)
                errorEnergy += pow(Double(output.left) - expected, 2)
                signalEnergy += expected * expected
            }
        }
        XCTAssertLessThan(sqrt(errorEnergy / signalEnergy), 1e-6)
    }

    /// Release controls recovery after an identical overload rather than changing the held ceiling.
    func testReleaseControlsRecovery() {
        let fast = StereoOutputLimiter(sampleRate: 48_000,
                                       settings: .init(releaseMS: 20))
        let slow = StereoOutputLimiter(sampleRate: 48_000,
                                       settings: .init(releaseMS: 1000))
        var fastOutput: Float = 0
        var slowOutput: Float = 0
        for i in 0..<12_000 {
            let peak = i < 1_000 ? 4.0 : 0.0
            fastOutput = fast.process(left: 0.25, right: peak).left
            slowOutput = slow.process(left: 0.25, right: peak).left
            if i == 999 { XCTAssertEqual(fastOutput, slowOutput) }
        }
        XCTAssertGreaterThan(fastOutput, 0.249)
        XCTAssertLessThan(slowOutput, 0.10)
    }

    /// Repeated live edits preserve a steady signal's continuity and eventually adopt the latest ceiling.
    func testLiveEditsCoalesceWithoutGainSteps() {
        let limiter = OutputLimiterTransition(sampleRate: 48_000)
        var settings = OutputLimiterSettings()
        var previous: Float = 0
        var maximumStep: Float = 0
        for i in 0..<24_000 {
            if i >= 3_000, i < 9_000, i % 128 == 0 {
                settings = .init(ceilingDB: i % 256 == 0 ? -12 : -3,
                                 lookaheadMS: i % 256 == 0 ? 20 : 1,
                                 releaseMS: i % 256 == 0 ? 1000 : 20)
            }
            if i == 9_000 { settings = .init(ceilingDB: -6, lookaheadMS: 12, releaseMS: 200) }
            if i % 128 == 0 { limiter.request(settings) }
            let output = limiter.process(left: 4, right: -2)
            if i > 1_000 { maximumStep = max(maximumStep, abs(output.left - previous)) }
            XCTAssertLessThanOrEqual(abs(output.left), Float(StereoOutputLimiter.ceiling))
            XCTAssertEqual(output.right, output.left * -0.5)
            previous = output.left
        }
        XCTAssertLessThan(maximumStep, 0.003)
        XCTAssertEqual(Double(previous), pow(10, -6.0 / 20), accuracy: 1e-6)
    }

    /// Changing lookahead replaces the delay smoothly and ends at the newly selected sample offset.
    func testLookaheadEditCrossfadesToNewDelay() {
        let limiter = OutputLimiterTransition(sampleRate: 48_000)
        let settings = OutputLimiterSettings(lookaheadMS: 20)
        var previous: Float = 0
        var maximumStep: Float = 0
        for i in 0..<10_000 {
            if i >= 3_000, i % 64 == 0 { limiter.request(settings) }
            let input = Float(0.2 * sin(Double(i) * 0.01))
            let output = limiter.process(left: Double(input), right: Double(-input))
            if i > 1_000 { maximumStep = max(maximumStep, abs(output.left - previous)) }
            if i > 6_000 {
                XCTAssertEqual(output.left, Float(0.2 * sin(Double(i - 960) * 0.01)))
            }
            previous = output.left
        }
        XCTAssertLessThan(maximumStep, 0.003)
    }
}
