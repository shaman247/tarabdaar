import AVFoundation
import Foundation

/// Post-mix sample peaks; 1 is digital full scale, independent of device volume.
public struct OutputPeakSnapshot {
    public let left: Double
    public let right: Double
    public let maximumLeft: Double
    public let maximumRight: Double
    public let clipped: Bool
    public let gainReductionDB: Double
}

/// Smooth gain and linked stereo peak protection after every source.
final class FinalOutputStage {
    static let gainSpec = ParamRegistry.spec("output_gain_db")!
    private static let component: AudioComponentDescription = {
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: 0x744f7574, componentManufacturer: 0x54726264,
            componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(FinalGainAudioUnit.self, as: description,
                                     name: "Tarabdaar: Final Output", version: 1)
        return description
    }()
    let node: AVAudioUnitEffect
    let meter = OutputPeakMeter()
    private let processor: FinalGainProcessor

    init() {
        node = AVAudioUnitEffect(audioComponentDescription: Self.component)
        processor = (node.auAudioUnit as! FinalGainAudioUnit).processor
        processor.meter = meter
    }

    func setControl(_ control: FinalOutputControl, _ value: Double) {
        guard value.isFinite else { return }
        processor.setControl(control, value)
    }
}

/// Control writers share only a mailbox; the render thread never waits on it.
private final class FinalGainProcessor {
    private let lock = NSLock()
    private var requestedGain = 1.0
    private var requestedSettings = OutputLimiterSettings()
    private var renderingSettings = OutputLimiterSettings()
    private var sampleRate = 48_000.0
    private var targetGain = 1.0
    private var gain = 1.0
    private var step = 0.0
    private var remaining = 0
    var rampFrames = 960
    var buffer: AVAudioPCMBuffer?
    var limiter = OutputLimiterTransition(sampleRate: 48_000)
    var meter: OutputPeakMeter?
    private var pendingReductionDB = 0.0
    private var pendingInvalidAudio = false

    func setControl(_ control: FinalOutputControl, _ value: Double) {
        lock.lock()
        switch control {
        case .gain:
            requestedGain = pow(10, FinalOutputStage.gainSpec.clamp(value) / 20)
        case .limiterCeiling:
            requestedSettings.ceilingDB = OutputLimiterSettings.ceilingSpec.clamp(value)
        case .limiterLookahead:
            requestedSettings.lookaheadMS = OutputLimiterSettings.lookaheadSpec.clamp(value)
        case .limiterRelease:
            requestedSettings.releaseMS = OutputLimiterSettings.releaseSpec.clamp(value)
        }
        lock.unlock()
    }

    var latency: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(StereoOutputLimiter.delayFrames(sampleRate: sampleRate,
                        lookaheadMS: requestedSettings.lookaheadMS)) / sampleRate
    }

    /// Resource setup only; no running render callback shares this storage.
    func prepare(sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate
        renderingSettings = requestedSettings
        lock.unlock()
        rampFrames = max(1, Int(sampleRate * 0.02))
        limiter = OutputLimiterTransition(sampleRate: sampleRate, settings: renderingSettings)
    }

    func process(_ data: UnsafeMutableAudioBufferListPointer, frames: Int) {
        if lock.try() {
            let requested = requestedGain
            renderingSettings = requestedSettings
            lock.unlock()
            if requested != targetGain {
                targetGain = requested
                remaining = rampFrames
                step = (targetGain - gain) / Double(remaining)
            }
        }
        limiter.request(renderingSettings)
        let left = data[0].mData!.assumingMemoryBound(to: Float.self)
        let right = data[1].mData!.assumingMemoryBound(to: Float.self)
        var minimumGain = 1.0
        for i in 0..<frames {
            if remaining > 0 {
                gain += step
                remaining -= 1
                if remaining == 0 { gain = targetGain }
            }
            pendingInvalidAudio = pendingInvalidAudio || !left[i].isFinite || !right[i].isFinite
            let output = limiter.process(left: Double(left[i]) * gain, right: Double(right[i]) * gain)
            left[i] = output.left
            right[i] = output.right
            minimumGain = min(minimumGain, output.gain)
        }
        pendingReductionDB = max(pendingReductionDB, -20 * log10(max(1e-12, minimumGain)))
        if meter?.recordLimiting(reductionDB: pendingReductionDB, invalidAudio: pendingInvalidAudio,
                                 at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9) == true {
            pendingReductionDB = 0
            pendingInvalidAudio = false
        }
    }
}

/// Stereo float gain and limiting; all storage is allocated before rendering.
private final class FinalGainAudioUnit: AUAudioUnit {
    let processor = FinalGainProcessor()
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var latency: TimeInterval { processor.latency }
    override var tailTime: TimeInterval { OutputLimiterSettings.lookaheadSpec.hi / 1000 }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                    busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                     busses: [try AUAudioUnitBus(format: format)])
    }

    override func allocateRenderResources() throws {
        let format = outputBusses[0].format
        guard format == inputBusses[0].format, format.channelCount == 2,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))
        }
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameCapacity))
        }
        processor.buffer = buffer
        processor.prepare(sampleRate: format.sampleRate)
        try super.allocateRenderResources()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        processor.buffer = nil
    }

    override func reset() {
        super.reset()
        processor.limiter.reset()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let processor = processor
        return { flags, timestamp, frames, bus, output, _, pullInput in
            guard bus == 0, let pullInput else { return kAudioUnitErr_NoConnection }
            guard let storage = processor.buffer,
                  frames <= storage.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 2 else { return kAudioUnitErr_FormatNotSupported }
            for channel in 0..<buffers.count where buffers[channel].mData == nil {
                buffers[channel].mData = UnsafeMutableRawPointer(storage.floatChannelData![channel])
                buffers[channel].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
            }
            let status = pullInput(flags, timestamp, frames, 0, output)
            guard status == noErr else { return status }
            processor.process(buffers, frames: Int(frames))
            // Silent input can still leave audible samples in the lookahead delay.
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            return noErr
        }
    }
}

/// The tap scans samples outside the lock; UI reads never consume or lose peaks.
final class OutputPeakMeter {
    private let lock = NSLock()
    private var left = Channel()
    private var right = Channel()
    private var clipped = false
    private var reductionDB = 0.0
    private var reductionTime = 0.0

    private func displayedReduction(at time: Double) -> Double {
        let value = reductionDB - 24 * max(0, time - reductionTime - 0.6)
        return value > 0 ? value : 0
    }

    /// The render callback never waits for the tap or UI; missed updates remain pending.
    func recordLimiting(reductionDB value: Double, invalidAudio: Bool, at time: Double) -> Bool {
        guard lock.try() else { return false }
        if value >= displayedReduction(at: time) {
            reductionDB = value
            reductionTime = time
        }
        clipped = clipped || invalidAudio
        lock.unlock()
        return true
    }

    private struct Channel {
        var peak = 0.0
        var peakTime = 0.0
        var maximum = 0.0

        func displayed(at time: Double) -> Double {
            // Hold for 600 ms, then fall at 24 dB/s even if rendering stops.
            guard peak.isFinite else { return peak }
            return peak * pow(10, -24 * max(0, time - peakTime - 0.6) / 20)
        }

        mutating func record(_ value: Double, at time: Double) {
            maximum = max(maximum, value)
            if value >= displayed(at: time) {
                peak = value
                peakTime = time
            }
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer,
                 at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let channels = buffer.floatChannelData, buffer.format.channelCount == 2,
              !buffer.format.isInterleaved, buffer.frameLength > 0 else { return }
        var l = 0.0, r = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            let a = Double(abs(channels[0][frame]))
            let b = Double(abs(channels[1][frame]))
            // Invalid audio also latches the warning; it is never hidden as silence.
            l = a.isFinite ? max(l, a) : .infinity
            r = b.isFinite ? max(r, b) : .infinity
        }
        lock.lock()
        left.record(l, at: time)
        right.record(r, at: time)
        clipped = clipped || l >= 1 || r >= 1
        lock.unlock()
    }

    func snapshot(at time: Double = ProcessInfo.processInfo.systemUptime) -> OutputPeakSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return OutputPeakSnapshot(left: left.displayed(at: time), right: right.displayed(at: time),
                                  maximumLeft: left.maximum, maximumRight: right.maximum,
                                  clipped: clipped, gainReductionDB: displayedReduction(at: time))
    }

    func reset() {
        lock.lock()
        left = Channel()
        right = Channel()
        clipped = false
        reductionDB = 0
        reductionTime = 0
        lock.unlock()
    }
}

extension AudioEngine {
    /// Shared by production and offline graph tests; no device access or engine start.
    func connectFinalOutput(format: AVAudioFormat) {
        engine.attach(symGain)
        engine.attach(finalOutput.node)
        engine.connect(symGain, to: finalOutput.node, format: format)
        engine.connect(finalOutput.node, to: engine.mainMixerNode, format: format)
        symGain.outputVolume = 1
        engine.mainMixerNode.outputVolume = 1
    }

    func installFinalOutputTap(format: AVAudioFormat) {
        removeFinalOutputTap()
        // Connect before installing the fixed-rate tap. A tap can change the mixer's
        // reported format without updating its implicit 44.1 kHz output connection,
        // slowing every 48 kHz source by 44.1/48 despite a 48 kHz hardware readout.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        let meter = finalOutput.meter
        let capture = pluckCapture
        // One tap owns this bus; optional diagnostics receive the same post-gain samples.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, time in
            meter.consume(buffer)
            capture?.append(buffer, at: time)
        }
        finalOutputTapInstalled = true
    }

    func removeFinalOutputTap() {
        guard finalOutputTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        finalOutputTapInstalled = false
    }

    public func setOutputGainDB(_ value: Double) { setFinalOutputControl(.gain, value) }
    public func setFinalOutputControl(_ control: FinalOutputControl, _ value: Double) {
        finalOutput.setControl(control, value)
    }
    public func outputPeaks() -> OutputPeakSnapshot { finalOutput.meter.snapshot() }
    /// Clear output peak history and bus RMS maxima without consuming the current bus intervals.
    public func resetOutputPeaks() {
        finalOutput.meter.reset()
        performanceMeter.resetMaxima()
    }
}
