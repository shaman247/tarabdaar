#if os(macOS)
import AVFoundation
import CoreAudio

extension AudioEngine: AudioOutputRecoveryDriver {
    /// Production and live integration probes share the same observer/recovery path.
    func startOutputRecovery(preferredDevice: AudioDeviceID = 0) {
        precondition(Thread.isMainThread)
        guard outputRecovery == nil else { return }
        let recovery = AudioOutputRecovery(driver: self)
        outputRecovery = recovery
        if preferredDevice != 0 { recovery.select(preferredDevice) }
        recovery.observe(engine: engine)
        recovery.start()
    }

    public func shutdownOutput() {
        precondition(Thread.isMainThread)
        outputRecovery?.shutdown()
        stopOutput()
        restoreOutputDeviceRate()
    }

    var defaultOutputDevice: AudioDeviceID { systemDefaultOutputDevice() }
    var activeOutputDevice: AudioDeviceID { currentOutputDevice }

    var availableOutputRoutes: [AudioOutputRoute] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            var alive: UInt32 = 0
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            bytes = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &alive) == noErr, alive != 0 else { return nil }
            var jack = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyJackIsConnected,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(id, &jack) {
                var connected: UInt32 = 1
                if AudioObjectGetPropertyData(id, &jack, 0, nil, &bytes, &connected) == noErr, connected == 0 { return nil }
            }
            property.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &uid) == noErr,
                  let value = uid?.takeRetainedValue() else { return nil }
            return AudioOutputRoute(id: id, uid: value as String)
        }
    }

    func stopOutput() {
        graphLock.lock()
        defer { graphLock.unlock() }
        engine.stop()
        if isRunning { isRunning = false }
    }

    func outputIsHealthy(on device: AudioDeviceID) -> Bool {
        guard engine.isRunning, currentOutputDevice == device else { return false }
        return (try? validateOutputFormats(on: device)) != nil
    }

    func startOutput(on device: AudioDeviceID, matchRate: Bool) throws {
        precondition(Thread.isMainThread)
        graphLock.lock()
        defer { graphLock.unlock() }
        guard availableOutputRoutes.contains(where: { $0.id == device }) else { throw AudioOutputError.unavailable }
        stopOutput()
        removeFinalOutputTap()
        guard let unit = engine.outputNode.audioUnit else { throw AudioOutputError.unavailable }
        if currentOutputDevice != device {
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioOutputError.coreAudio("Selecting output device \(device)", status) }
        }
        guard currentOutputDevice == device else { throw AudioOutputError.format("Output device selection did not take effect") }
        if matchRate { matchOutputDeviceToEngineRate(device) }
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw AudioOutputError.format("Output device has no active audio format")
        }
        // Remove the tap before reconnecting: its cached format can otherwise hide an old connection.
        engine.disconnectNodeOutput(engine.mainMixerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: Config.sampleRate, channels: 2)!
        installFinalOutputTap(format: format)
        try validateOutputFormats(on: device)
        let requested = preferredBufferFrames(for: device)
        let received = setOutputBufferFrames(requested)
        if received == 0 { NSLog("Tarabdaar: could not query output IO buffer after requesting \(requested) frames") }
        do {
            try engine.start()
            try validateOutputFormats(on: device)
            guard engine.isRunning else { throw AudioOutputError.format("Output stopped during startup") }
            isRunning = true
            logAudioLatencyReport("output recovered")
        } catch {
            stopOutput()
            throw error
        }
    }

    /// Internal processing stays stereo/48 kHz; the output unit may convert to another hardware rate.
    func validateOutputFormats(on device: AudioDeviceID) throws {
        graphLock.lock()
        defer { graphLock.unlock() }
        guard currentOutputDevice == device else { throw AudioOutputError.format("Active output device changed") }
        let formats: [(String, AVAudioFormat)] = [
            ("voice sum", symGain.outputFormat(forBus: 0)),
            ("final input", finalOutput.node.inputFormat(forBus: 0)),
            ("final output", finalOutput.node.outputFormat(forBus: 0)),
            ("mixer input", engine.mainMixerNode.inputFormat(forBus: 0)),
            ("mixer output", engine.mainMixerNode.outputFormat(forBus: 0)),
            ("device input", engine.outputNode.inputFormat(forBus: 0))
        ]
        for (name, format) in formats {
            guard format.sampleRate == Config.sampleRate, format.channelCount == 2 else {
                throw AudioOutputError.format("Invalid \(name) format: \(format.sampleRate) Hz / \(format.channelCount) channels")
            }
        }
        // Check active source connections too; their DSP clocks never follow device-rate changes.
        let sources = [stringVoiceSource?.node, tanpuraVoice.source?.node, sitarVoice.source?.node].compactMap { $0 }
        for source in sources where !engine.outputConnectionPoints(for: source, outputBus: 0).isEmpty {
            guard source.outputFormat(forBus: 0).sampleRate == Config.sampleRate else {
                throw AudioOutputError.format("Voice source sample rate changed")
            }
        }
        let output = engine.outputNode.outputFormat(forBus: 0)
        let nominal = deviceNominalSampleRate(device)
        guard nominal.isFinite, nominal > 0, output.channelCount > 0,
              abs(output.sampleRate - nominal) < 1 else {
            throw AudioOutputError.format("Hardware rate is unsettled: output \(output.sampleRate), device \(nominal)")
        }
    }

    func outputRecoveryChanged(selection: AudioDeviceID, error: String?) {
        if outputDeviceSelection != selection { outputDeviceSelection = selection }
        if outputDeviceError != error {
            outputDeviceError = error
            if let error { NSLog("Tarabdaar: \(error)") }
        }
        if isRunning != engine.isRunning { isRunning = engine.isRunning }
        let routes = availableOutputRoutes
        let defaultID = defaultOutputDevice
        if lastOutputRoutes != routes || lastDefaultOutput != defaultID {
            lastOutputRoutes = routes
            lastDefaultOutput = defaultID
            outputDeviceRevision += 1
        }
    }
}
#endif
