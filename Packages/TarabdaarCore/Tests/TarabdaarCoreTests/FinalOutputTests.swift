import AVFoundation
import XCTest
@testable import TarabdaarCore

final class FinalOutputTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// Metering must preserve the sample-rate agreement at the device input before startup.
    func testMeterTapPreservesOutputConnectionRate() {
        let audio = AudioEngine(glideQueue: GlideSequencer())
        audio.connectFinalOutput(format: format)
        // Reproduce the implicit connection's default rate, independent of the user's device.
        let initial = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        audio.engine.connect(audio.engine.mainMixerNode, to: audio.engine.outputNode, format: initial)
        audio.installFinalOutputTap(format: format)
        XCTAssertEqual(audio.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
                       format.sampleRate)
        XCTAssertEqual(audio.engine.outputNode.inputFormat(forBus: 0).sampleRate,
                       audio.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
                       "A fixed-rate tap must not relabel samples on a differently clocked connection")
    }

    private func graph(finalStage: Bool = true) throws -> AudioEngine {
        let audio = AudioEngine(glideQueue: GlideSequencer())
        if finalStage {
            audio.connectFinalOutput(format: format)
        } else {
            audio.engine.attach(audio.symGain)
            audio.engine.connect(audio.symGain, to: audio.engine.mainMixerNode, format: format)
        }
        // Three independent, unequal stereo sources exercise the production summing path.
        for (index, levels) in [(Float(0.25), Float(-0.125)),
                                (Float(0.125), Float(0.0625)),
                                (Float(-0.0625), Float(-0.03125))].enumerated() {
            let source = AVAudioSourceNode(format: format) { _, _, count, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                for channel in 0..<2 {
                    let samples = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    samples.update(repeating: channel == 0 ? levels.0 : levels.1, count: Int(count))
                }
                return noErr
            }
            audio.engine.attach(source)
            audio.engine.connect(source, to: audio.symGain, fromBus: 0,
                                 toBus: AVAudioNodeBus(index), format: format)
        }
        try audio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try audio.engine.start()
        return audio
    }

    private func render(_ audio: AudioEngine, blocks: Int = 32) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        for _ in 0..<blocks {
            XCTAssertEqual(try audio.engine.renderOffline(512, to: buffer), .success)
        }
        return buffer
    }

    /// Below the knee, the delayed stage preserves samples and scales the complete stereo sum.
    func testGainAfterAllThreeSourcesAndUnityParity() throws {
        let reference = try graph(finalStage: false)
        let expected = try render(reference)
        let audio = try graph()
        let unity = try render(audio)
        for channel in 0..<2 {
            XCTAssertEqual(Array(UnsafeBufferPointer(start: unity.floatChannelData![channel], count: 512)),
                           Array(UnsafeBufferPointer(start: expected.floatChannelData![channel], count: 512)))
        }
        for db in [-12.0, 6.0, 0.0] {
            audio.setOutputGainDB(db)
            let boosted = try render(audio)
            for channel in 0..<2 {
                XCTAssertEqual(Double(boosted.floatChannelData![channel][511]),
                               Double(expected.floatChannelData![channel][511]) * pow(10, db / 20),
                               accuracy: 0.00001)
            }
        }
    }

    /// Live gain changes ramp instead of stepping a sustained signal.
    func testLiveGainTransition() throws {
        let audio = try graph()
        let beforeBuffer = try render(audio)
        let before = beforeBuffer.floatChannelData![0][511]
        audio.setOutputGainDB(12)
        let transition = try render(audio, blocks: 1)
        var previous = before
        var maximumStep: Float = 0
        for sample in UnsafeBufferPointer(start: transition.floatChannelData![0], count: 512) {
            maximumStep = max(maximumStep, abs(sample - previous))
            previous = sample
        }
        XCTAssertLessThan(maximumStep, 0.01, "A gain edit must not step the waveform")
        audio.setOutputGainDB(-6)
        let reversed = try render(audio, blocks: 1)
        for sample in UnsafeBufferPointer(start: reversed.floatChannelData![0], count: 512) {
            XCTAssertLessThan(abs(sample - previous), 0.01)
            previous = sample
        }
        let settled = try render(audio, blocks: 180)
        XCTAssertEqual(Double(settled.floatChannelData![0][511]),
                       Double(before) * pow(10, -6.0 / 20), accuracy: 0.00001)
    }

    /// A single over-range sample survives silence and repeated reads until explicitly cleared.
    func testStereoPeaksLatchAndDecayWithoutChangingAudio() {
        let meter = OutputPeakMeter()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 512) }
        buffer.floatChannelData![0][17] = -1.25
        buffer.floatChannelData![1][231] = 0.375
        meter.consume(buffer, at: 10)
        XCTAssertEqual(buffer.floatChannelData![0][17], -1.25)
        XCTAssertEqual(buffer.floatChannelData![1][231], 0.375)
        for _ in 0..<3 {
            let snap = meter.snapshot(at: 10.5)
            XCTAssertEqual(snap.left, 1.25)
            XCTAssertEqual(snap.right, 0.375)
            XCTAssertTrue(snap.clipped)
        }
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 512) }
        meter.consume(buffer, at: 11)
        let silent = meter.snapshot(at: 12)
        XCTAssertLessThan(silent.left, 0.1)
        XCTAssertEqual(silent.maximumLeft, 1.25)
        XCTAssertEqual(silent.maximumRight, 0.375)
        XCTAssertTrue(silent.clipped)
        meter.reset()
        XCTAssertFalse(meter.snapshot(at: 12).clipped)
        XCTAssertEqual(meter.snapshot(at: 12).maximumLeft, 0)
        buffer.floatChannelData![1][99] = -1
        meter.consume(buffer, at: 13)
        XCTAssertTrue(meter.snapshot(at: 13).clipped)
    }

    /// All three voices share protection, while the output tap measures the protected stereo mix.
    func testOutputTapMeasuresFinalMix() throws {
        let audio = try graph()
        audio.installFinalOutputTap(format: format)
        audio.setOutputGainDB(12)
        _ = try render(audio, blocks: 100)
        let deadline = Date().addingTimeInterval(2)
        while audio.outputPeaks().maximumLeft < 0.89, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let snapshot = audio.outputPeaks()
        XCTAssertEqual(snapshot.maximumLeft, StereoOutputLimiter.ceiling, accuracy: 0.00001)
        XCTAssertEqual(snapshot.maximumRight, StereoOutputLimiter.ceiling * 0.3, accuracy: 0.00001)
        XCTAssertFalse(snapshot.clipped)
        XCTAssertGreaterThan(snapshot.gainReductionDB, 2.8)
        XCTAssertEqual(audio.finalOutput.node.auAudioUnit.latency, 0.005, accuracy: 0.000001)
    }

    /// Configured protection reaches the production sum and reports its selected latency.
    func testConfiguredProtectionAndLatency() throws {
        let audio = try graph()
        audio.setOutputGainDB(12)
        _ = try render(audio)
        audio.setFinalOutputControl(.limiterCeiling, -6)
        audio.setFinalOutputControl(.limiterLookahead, 15)
        audio.setFinalOutputControl(.limiterRelease, 400)
        let buffer = try render(audio, blocks: 100)
        XCTAssertEqual(Double(buffer.floatChannelData![0][511]), pow(10, -6.0 / 20), accuracy: 1e-6)
        XCTAssertEqual(Double(buffer.floatChannelData![1][511]), -0.3 * pow(10, -6.0 / 20), accuracy: 1e-6)
        XCTAssertEqual(audio.finalOutput.node.auAudioUnit.latency, 0.015, accuracy: 1e-6)
        // Out-of-range requests and invalid controller values cannot overrun delay storage.
        audio.setFinalOutputControl(.limiterLookahead, 1_000)
        audio.setFinalOutputControl(.limiterCeiling, 20)
        audio.setFinalOutputControl(.limiterRelease, -.infinity)
        let clamped = try render(audio, blocks: 100)
        XCTAssertLessThanOrEqual(abs(clamped.floatChannelData![0][511]), 1)
        XCTAssertEqual(audio.finalOutput.node.auAudioUnit.latency, 0.020, accuracy: 1e-6)
    }

    /// Lookahead audio survives silent input flags and render-block boundaries.
    func testDelayedTailAcrossSilentBlocks() throws {
        let audio = AudioEngine(glideQueue: GlideSequencer())
        audio.connectFinalOutput(format: format)
        var sent = false
        let source = AVAudioSourceNode(format: format) { silence, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for channel in 0..<2 {
                let samples = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                samples.update(repeating: 0, count: Int(count))
                if !sent { samples[0] = channel == 0 ? 0.5 : -0.25 }
            }
            silence.pointee = ObjCBool(sent)
            sent = true
            return noErr
        }
        audio.engine.attach(source)
        audio.engine.connect(source, to: audio.symGain, format: format)
        try audio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try audio.engine.start()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var index = 0
        for frames: AVAudioFrameCount in [17, 31, 64, 128, 3, 256, 512] {
            XCTAssertEqual(try audio.engine.renderOffline(frames, to: buffer), .success)
            for i in 0..<Int(frames) {
                XCTAssertEqual(buffer.floatChannelData![0][i], index == 240 ? 0.5 : 0)
                XCTAssertEqual(buffer.floatChannelData![1][i], index == 240 ? -0.25 : 0)
                index += 1
            }
        }
    }
}
