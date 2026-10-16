#if os(macOS)
import AppKit
import AVFoundation
import CoreAudio
import SarangiKit
import XCTest
@testable import TarabdaarCore

/// Opt-in hardware integration: temporarily routes test audio through BlackHole and a disposable aggregate.
final class AudioOutputRecoveryLiveTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, timeout: Double = 8) throws {
        let end = Date().addingTimeInterval(timeout)
        var stable = 0
        while Date() < end {
            stable = predicate() ? stable + 1 : 0
            if stable >= 5 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AudioOutputError.format("Recovery timed out")
    }

    private func setDefault(_ id: AudioDeviceID) throws {
        var value = id
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("Test default device", status) }
    }

    private func setRate(_ id: AudioDeviceID, _ rate: Double) throws {
        var value = rate
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(id, &a, 0, nil, 8, &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("Test device rate", status) }
    }

    private func aggregate(uid: String, subdevice: String) throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "Tarabdaar Recovery Probe",
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subdevice]],
            kAudioAggregateDeviceMainSubDeviceKey: subdevice,
            kAudioAggregateDeviceIsPrivateKey: false
        ]
        var device: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr else { throw AudioOutputError.coreAudio("Create test aggregate", status) }
        return device
    }

    private func measure(device: AudioDeviceID, nominalRate: Double, label: String,
                         directory: URL, bow: Bool = false) throws -> [String: Any] {
        let capacity = 384_000
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        defer { storage.deinitialize(count: capacity); storage.deallocate() }
        var count = 0, callbacks = 0
        var first = AudioTimeStamp(), last = AudioTimeStamp()
        var io: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, input, time, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = list.first, let data = buffer.mData, buffer.mNumberChannels > 0 else { return }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            if callbacks == 0 { first = time.pointee }
            last = time.pointee
            callbacks += 1
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames where count < capacity {
                storage[count] = samples[i * channels]
                count += 1
            }
        }
        guard created == noErr, let io else { throw AudioOutputError.coreAudio("Create loopback recorder", created) }
        defer { AudioDeviceDestroyIOProcID(device, io) }
        let started = AudioDeviceStart(device, io)
        guard started == noErr else { throw AudioOutputError.coreAudio("Start loopback recorder", started) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        AudioDeviceStop(device, io)
        guard callbacks > 2, count > Int(nominalRate) else { throw AudioOutputError.format("No loopback audio") }
        let seconds = Double(last.mHostTime - first.mHostTime) / AudioGetHostClockFrequency()
        let actualRate = (last.mSampleTime - first.mSampleTime) / seconds
        let signal = Array(UnsafeBufferPointer(start: storage, count: count))
        try signal.withUnsafeBufferPointer { try Data(buffer: $0).write(to: directory.appendingPathComponent(label + ".f32")) }
        let samples = Array(signal.dropFirst(Int(nominalRate * 0.3)))
        let hz: Double
        if bow {
            hz = fundamental(samples, sampleRate: actualRate, near: 261.63)
        } else {
            var crossings: [Double] = []
            for i in 1..<samples.count where samples[i-1] <= 0 && samples[i] > 0 {
                crossings.append(Double(i-1) + Double(-samples[i-1] / (samples[i] - samples[i-1])))
            }
            guard crossings.count > 100 else { throw AudioOutputError.format("Missing loopback tone") }
            hz = Double(crossings.count - 1) * actualRate / (crossings.last! - crossings.first!)
        }
        let cents = 1200 * log2(hz / 261.63)
        print("RECOVERY PITCH \(label): \(hz) Hz (\(cents) cents), device clock \(actualRate) Hz")
        XCTAssertLessThan(abs(cents), bow ? 3 : 1, label)
        return ["scenario": label, "requestedHz": 261.63, "measuredHz": hz,
                "errorCents": cents, "nominalRate": nominalRate, "measuredDeviceRate": actualRate]
    }

    private func fundamental(_ samples: [Float], sampleRate: Double, near hz: Double) -> Double {
        let windowed = samples.enumerated().map { i, x in
            Double(x) * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(samples.count - 1)))
        }
        func power(_ f: Double) -> Double {
            let c = cos(2 * .pi * f / sampleRate), s = sin(2 * .pi * f / sampleRate)
            var cr = 1.0, ci = 0.0, re = 0.0, im = 0.0
            for x in windowed {
                re += x * cr; im += x * ci
                let next = cr * c - ci * s
                ci = ci * c + cr * s; cr = next
            }
            return re * re + im * im
        }
        let step = hz * 0.001
        let peak = (-20...20).max { power(hz + Double($0) * step) < power(hz + Double($1) * step) }!
        var lo = hz + Double(peak-1) * step, hi = hz + Double(peak+1) * step
        for _ in 0..<20 {
            let a = lo + (hi-lo)/3, b = hi - (hi-lo)/3
            if power(a) < power(b) { lo = a } else { hi = b }
        }
        return (lo + hi)/2
    }

    /// Real HAL changes recover without manual starts and retain measured pitch at the hardware loopback.
    func testLiveRecoveryAndPitch() throws {
        guard let path = ProcessInfo.processInfo.environment["TARABDAAR_RECOVERY_CAPTURE_DIR"] else {
            throw XCTSkip("Opt-in BlackHole output recovery probe")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = AudioEngine(glideQueue: GlideSequencer())
        let blackhole = try XCTUnwrap(audio.availableOutputRoutes.first { $0.uid.lowercased().contains("blackhole") })
        let originalDefault = audio.defaultOutputDevice
        let originalRate = audio.deviceNominalSampleRate(blackhole.id)
        let uid = "com.tarabdaar.recovery-test." + UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["originalDefault": originalDefault,
            "originalRate": originalRate, "blackhole": blackhole.id, "aggregateUID": uid], options: .prettyPrinted)
            .write(to: directory.appendingPathComponent("session.json"))
        var aggregateID: AudioDeviceID = 0
        defer {
            audio.shutdownOutput()
            try? setDefault(originalDefault)
            if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
            try? setRate(blackhole.id, originalRate)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        audio.connectFinalOutput(format: format)
        var phase = 0.0
        let source = AVAudioSourceNode(format: format) { _, _, frames, data in
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            for i in 0..<Int(frames) {
                let value = Float(0.01 * sin(phase))
                phase += 2 * .pi * 261.63 / 48_000
                for channel in 0..<buffers.count { buffers[channel].mData!.assumingMemoryBound(to: Float.self)[i] = value }
            }
            return noErr
        }
        audio.engine.attach(source)
        audio.engine.connect(source, to: audio.symGain, format: format)
        audio.startOutputRecovery(preferredDevice: blackhole.id)
        var report: [[String: Any]] = []
        func checkpoint(_ name: String, device: AudioDeviceID, bow: Bool = false) throws {
            try waitUntil { audio.outputIsHealthy(on: device) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            report.append(try measure(device: blackhole.id, nominalRate: audio.deviceNominalSampleRate(blackhole.id),
                                      label: name, directory: directory, bow: bow))
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("measurements.json"))
        }
        try checkpoint("startup", device: blackhole.id)
        for rate in [44_100.0, 96_000.0, 48_000.0] {
            try setRate(blackhole.id, rate)
            try waitUntil { abs(audio.outputSampleRate - rate) < 1 && audio.outputIsHealthy(on: blackhole.id) }
            try checkpoint("rate-\(Int(rate))", device: blackhole.id)
        }
        XCTAssertFalse(audio.setOutputDevice(UInt32.max))
        try checkpoint("rejected-device", device: blackhole.id)
        aggregateID = try aggregate(uid: uid, subdevice: blackhole.uid)
        try waitUntil { audio.availableOutputRoutes.contains { $0.id == aggregateID } }
        XCTAssertTrue(audio.setOutputDevice(aggregateID))
        try checkpoint("device-switch", device: aggregateID)
        try setDefault(blackhole.id)
        let removed = aggregateID
        XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregateID), noErr)
        aggregateID = 0
        try checkpoint("device-removed-fallback", device: blackhole.id)
        XCTAssertEqual(audio.outputRecovery?.preferredUID, uid)
        aggregateID = try aggregate(uid: uid, subdevice: blackhole.uid)
        try checkpoint("device-recreated", device: aggregateID)
        print("RECOVERY DEVICE identity \(removed) -> \(aggregateID)")
        XCTAssertTrue(audio.setOutputDevice(0))
        try checkpoint("system-default", device: blackhole.id)
        try setDefault(aggregateID)
        try checkpoint("system-default-changed", device: aggregateID)
        try setDefault(blackhole.id)
        try waitUntil { audio.outputIsHealthy(on: blackhole.id) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try waitUntil { audio.outputRecovery?.sleeping == true && !audio.engine.isRunning }
        try setRate(blackhole.id, 44_100)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try checkpoint("sleep-wake-notifications", device: blackhole.id)
        // Deliberately reproduce the original stale tap/connection format after a stop.
        audio.engine.stop()
        audio.removeFinalOutputTap()
        audio.engine.connect(audio.engine.mainMixerNode, to: audio.engine.outputNode,
                             format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        audio.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4800, format: format) { _, _ in }
        audio.finalOutputTapInstalled = true
        XCTAssertThrowsError(try audio.validateOutputFormats(on: blackhole.id))
        try checkpoint("invalid-connection-repaired", device: blackhole.id)
        // Hold a real String voice through the same sleep/wake recovery path.
        let bow = StringVoiceSource()
        let controls = ["bow_expr": 0.589723, "bow_press": 0.0, "bow_pos": 0.890566, "bow_drift_cents": 0.0]
        for (key, value) in controls { bow.setControl(key, value) }
        let model = try XCTUnwrap(bow.buildEngine(tonicHz: 261.63, strings: [], overrides: controls))
        bow.setEngine(model, crossfadeMs: 0)
        bow.mapper.setAxis(expr: 0.589723, press: 0, pos: 0.890566)
        audio.engine.stop()
        audio.engine.disconnectNodeOutput(source)
        audio.engine.attach(bow.node)
        audio.engine.connect(bow.node, to: audio.symGain, format: format)
        audio.stringVoiceSource = bow
        bow.mapper.touchOn(1, pitchSemis: 69 + 12 * log2(261.63/440))
        try checkpoint("bow-before-recovery", device: blackhole.id, bow: true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try waitUntil { audio.outputRecovery?.sleeping == true && !audio.engine.isRunning }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try checkpoint("bow-after-recovery", device: blackhole.id, bow: true)
    }
    /// An operator unplug/replug and real sleep cycle preserve the source clock against hardware time.
    func testPhysicalRecoveryAndClock() throws {
        guard let path = ProcessInfo.processInfo.environment["TARABDAAR_RECOVERY_PHYSICAL_DIR"] else {
            throw XCTSkip("Operator-assisted physical output and sleep/wake probe")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = AudioEngine(glideQueue: GlideSequencer())
        let route = try XCTUnwrap(audio.availableOutputRoutes.first { $0.id == audio.defaultOutputDevice })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        audio.connectFinalOutput(format: format)
        let clock = ToneClock()
        audio.engine.attach(clock.node)
        audio.engine.connect(clock.node, to: audio.symGain, format: format)
        audio.startOutputRecovery(preferredDevice: route.id)
        defer { audio.shutdownOutput() }
        var report: [[String: Any]] = []
        func progress(_ text: String) throws {
            try text.write(to: directory.appendingPathComponent("phase.txt"), atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(("PHYSICAL " + text + "\n").utf8))
        }
        func checkpoint(_ label: String) throws {
            try waitUntil { audio.outputIsHealthy(on: audio.currentOutputDevice) }
            clock.reset()
            var first = AudioTimeStamp(), last = AudioTimeStamp(), count = 0
            var io: AudioDeviceIOProcID?
            let device = audio.currentOutputDevice
            let status = AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, _, _, _, time in
                if count == 0 { first = time.pointee }
                last = time.pointee; count += 1
            }
            guard status == noErr, let io else { throw AudioOutputError.coreAudio("Physical clock recorder", status) }
            defer { AudioDeviceDestroyIOProcID(device, io) }
            let started = AudioDeviceStart(device, io)
            guard started == noErr else { throw AudioOutputError.coreAudio("Physical clock start", started) }
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            AudioDeviceStop(device, io)
            let renderedRate = clock.rate()
            let measuredHz = 261.63 * renderedRate / 48_000
            let elapsed = Double(last.mHostTime - first.mHostTime) / AudioGetHostClockFrequency()
            let hardwareRate = (last.mSampleTime - first.mSampleTime) / elapsed
            let cents = 1200 * log2(measuredHz / 261.63)
            XCTAssertLessThan(abs(cents), 3)
            XCTAssertEqual(hardwareRate, audio.outputSampleRate, accuracy: audio.outputSampleRate * 0.001)
            report.append(["scenario": label, "requestedHz": 261.63, "renderClockPitchHz": measuredHz,
                "errorCents": cents, "sourceSamplesPerSecond": renderedRate, "measuredHardwareRate": hardwareRate])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("measurements.json"))
            try progress("\(label): render-clock pitch \(measuredHz) Hz; hardware clock \(hardwareRate) Hz")
        }
        try checkpoint("baseline")
        try progress("READY: unplug the headphones, leave them out for three seconds, then reconnect them")
        try waitUntil({ !audio.availableOutputRoutes.contains { $0.uid == route.uid } }, timeout: 240)
        try progress("Removal detected; waiting for reconnection")
        try waitUntil({ audio.availableOutputRoutes.contains { $0.uid == route.uid } &&
            audio.outputIsHealthy(on: audio.currentOutputDevice) &&
            audio.availableOutputRoutes.first(where: { $0.id == audio.currentOutputDevice })?.uid == route.uid }, timeout: 240)
        try checkpoint("physical-replug")
        if ProcessInfo.processInfo.environment["TARABDAAR_RECOVERY_PHYSICAL_MODE"] != "unplug" {
            var wakes = 0
            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in wakes += 1 }
            defer { center.removeObserver(observer) }
            try progress("READY: put the Mac to sleep, wait five seconds, then wake and unlock it")
            try waitUntil({ wakes > 0 }, timeout: 300)
            try checkpoint("physical-sleep-wake")
        }
        try progress("COMPLETE: physical recovery checks passed")
    }

    private final class ToneClock {
        private final class State {
            let lock = NSLock()
            var frames: Int64 = 0, firstFrames: Int64 = 0
            var first: UInt64 = 0, last: UInt64 = 0
        }
        private let state: State
        let node: AVAudioSourceNode
        init() {
            let state = State()
            self.state = state
            var phase = 0.0
            node = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!) { _, _, n, data in
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                for i in 0..<Int(n) {
                    let value = Float(0.003 * sin(phase))
                    phase += 2 * .pi * 261.63 / 48_000
                    for c in 0..<buffers.count { buffers[c].mData!.assumingMemoryBound(to: Float.self)[i] = value }
                }
                state.lock.lock()
                state.frames += Int64(n)
                state.last = DispatchTime.now().uptimeNanoseconds
                if state.first == 0 { state.first = state.last; state.firstFrames = state.frames }
                state.lock.unlock()
                return noErr
            }
        }
        func reset() {
            state.lock.lock(); defer { state.lock.unlock() }
            state.frames = 0; state.first = 0; state.last = 0
        }
        func rate() -> Double {
            state.lock.lock(); defer { state.lock.unlock() }
            guard state.last > state.first else { return 0 }
            return Double(state.frames - state.firstFrames) / (Double(state.last - state.first) / 1e9)
        }
    }

}
#endif
