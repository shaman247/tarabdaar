import AVFoundation
import Foundation

// Output-device plumbing: device selection, the transport-aware IO buffer,
// matching the device's nominal rate to the engine rate (and restoring it),
// and the latency report.
extension AudioEngine {
    /// Effective hardware sample rate of the current output device.
    public var outputSampleRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    #if os(macOS)
    /// Route AVAudioEngine output to a specific CoreAudio device.
    public func setOutputDevice(_ deviceID: AudioDeviceID) {
        let wasRunning = isRunning
        if wasRunning {
            engine.pause()
        }
        if let au = engine.outputNode.audioUnit {
            var dev = deviceID
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dev,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        // Match the NEW device to the engine rate (restoring the old one).
        matchOutputDeviceToEngineRate(deviceID)
        if wasRunning {
            do {
                try engine.start()
                isRunning = true
            } catch {
                print("AudioEngine restart after device change failed: \(error)")
                isRunning = false
            }
        }
        // The IO buffer is per-device — re-apply to the new device.
        setOutputBufferFrames(preferredBufferFrames(for: deviceID))
    }

    /// Current output device ID (or 0 if querying failed).
    public var currentOutputDevice: AudioDeviceID {
        guard let au = engine.outputNode.audioUnit else { return 0 }
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            &size
        )
        return dev
    }

    // MARK: - Output device sample-rate matching

    /// CoreAudio system default output device.
    func systemDefaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
        return id
    }

    /// `kAudioDevicePropertyTransportType` of `dev` (0 if the query fails).
    private func deviceTransportType(_ dev: AudioDeviceID) -> UInt32 {
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v)
        return v
    }

    /// Solid transports take the low play-latency buffer; jitter-prone ones
    /// (DisplayPort/HDMI monitor audio, Bluetooth, AirPlay) cannot sustain its
    /// callback cadence and crackle on EVERY voice, so they take the safe buffer.
    func preferredBufferFrames(for dev: AudioDeviceID) -> UInt32 {
        let t = deviceTransportType(dev)
        let jittery: Set<UInt32> = [kAudioDeviceTransportTypeDisplayPort,
                                    kAudioDeviceTransportTypeHDMI,
                                    kAudioDeviceTransportTypeBluetooth,
                                    kAudioDeviceTransportTypeBluetoothLE,
                                    kAudioDeviceTransportTypeAirPlay]
        guard jittery.contains(t) else {
            return Config.preferredOutputBufferFrames
        }
        let fourcc = String(bytes: [UInt8(t >> 24 & 0xFF), UInt8(t >> 16 & 0xFF),
                                    UInt8(t >> 8 & 0xFF), UInt8(t & 0xFF)],
                            encoding: .ascii) ?? "????"
        NSLog("Tarabdaar: output transport '\(fourcc)' is jitter-prone — using the \(Config.jitterProneOutputBufferFrames)-frame IO buffer")
        return Config.jitterProneOutputBufferFrames
    }

    private func deviceNominalSampleRate(_ dev: AudioDeviceID) -> Double {
        var v: Double = 0
        var sz = UInt32(MemoryLayout<Double>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v)
        return v
    }

    private func deviceSupportsSampleRate(_ dev: AudioDeviceID, _ sr: Double) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 else { return false }
        let n = Int(sz) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: n)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &ranges) == noErr else { return false }
        return ranges.contains { sr >= $0.mMinimum - 1 && sr <= $0.mMaximum + 1 }
    }

    /// Set a device's nominal rate and poll until it settles (asynchronous in CoreAudio).
    @discardableResult
    private func setDeviceNominalSampleRate(_ dev: AudioDeviceID, _ sr: Double) -> Bool {
        var v = sr
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectSetPropertyData(dev, &a, 0, nil,
                                         UInt32(MemoryLayout<Double>.size), &v) == noErr else {
            return false
        }
        for _ in 0..<60 {                       // up to ~300 ms for the rate to settle
            if abs(deviceNominalSampleRate(dev) - sr) < 1 { return true }
            usleep(5000)
        }
        return abs(deviceNominalSampleRate(dev) - sr) < 1
    }

    /// Match `dev`'s nominal rate to `Config.sampleRate` (no resampler).
    /// Best-effort; remembers the prior rate for `restoreOutputDeviceRate`.
    func matchOutputDeviceToEngineRate(_ dev: AudioDeviceID) {
        guard dev != 0 else { return }
        let target = Config.sampleRate
        // If we previously changed a DIFFERENT device, restore it first.
        if let prev = changedDeviceRate, prev.device != dev {
            setDeviceNominalSampleRate(prev.device, prev.originalRate)
            changedDeviceRate = nil
        }
        let current = deviceNominalSampleRate(dev)
        guard abs(current - target) >= 1 else { return }   // already at target
        guard deviceSupportsSampleRate(dev, target) else {
            NSLog("Tarabdaar: output device lacks \(Int(target)) Hz — leaving at \(Int(current)) Hz (resampler stays)")
            return
        }
        if changedDeviceRate == nil { changedDeviceRate = (dev, current) }
        let ok = setDeviceNominalSampleRate(dev, target)
        NSLog("Tarabdaar: output device rate \(Int(current)) → \(Int(target)) Hz: \(ok ? "OK (no resampler)" : "FAILED")")
    }

    /// Restore any output device whose rate we changed (wired to the clean-quit hook).
    public func restoreOutputDeviceRate() {
        guard let prev = changedDeviceRate else { return }
        setDeviceNominalSampleRate(prev.device, prev.originalRate)
        NSLog("Tarabdaar: restored output device rate → \(Int(prev.originalRate)) Hz")
        changedDeviceRate = nil
    }

    /// The output device's IO buffer in frames (0 if unknown) — the HAL buffer.
    public var outputBufferFrames: UInt32 {
        guard let au = engine.outputNode.audioUnit else { return 0 }
        var n: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(au, kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0, &n, &size)
        return n
    }

    /// Request an IO buffer size on the output device (a system-wide HAL
    /// property, clamped to its range). Returns the value in effect.
    @discardableResult
    public func setOutputBufferFrames(_ frames: UInt32) -> UInt32 {
        guard let au = engine.outputNode.audioUnit else { return 0 }
        var n = frames
        AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0, &n,
                             UInt32(MemoryLayout<UInt32>.size))
        return outputBufferFrames
    }

    /// Log the latency budget: engine vs device rate, IO buffer, presentation latency.
    public func logAudioLatencyReport(_ context: String) {
        let engineSR = Config.sampleRate
        let deviceSR = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let buf = outputBufferFrames
        let bufMs = deviceSR > 0 ? Double(buf) / deviceSR * 1000 : 0
        let outLatMs = engine.outputNode.presentationLatency * 1000
        let outSrcNote = (deviceSR != engineSR) ? " [output RESAMPLE]" : ""
        let msg = """
        AUDIO LATENCY [\(context)]: engineSR=\(engineSR) deviceSR=\(deviceSR)\(outSrcNote) \
        ioBuffer=\(buf)f (\(String(format: "%.1f", bufMs))ms) \
        outputPresentationLatency=\(String(format: "%.1f", outLatMs))ms
        """
        NSLog("Tarabdaar: \(msg)")
    }
    #endif
}
