import AVFoundation
import Foundation
import QuartzCore
import SarangiKit

/// macOS audio plumbing for the three voices — the String voice
/// (`StringVoiceSource`; the kernel is the whole instrument: strings +
/// taraf + body + room) and the plucked tanpura / sitar
/// (`TanpuraVoiceSource`) — summed through `symGain`:
///
///   `{string, tanpura, sitar}.node → symGain → mainMixerNode → output`
///
/// Touches arrive on the TLP path (via the glide queue); in-process MIDI at
/// `sendHostedMIDI`. Public methods take `lock` for state and release it
/// before calling into an engine.
public class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    /// Summing stage for the three source nodes, pinned at unity.
    private let symGain = AVAudioMixerNode()
    private let lock = NSLock()

    // MARK: - String voice source

    /// The String voice (native 48 kHz; the mixer input converts). Kept
    /// attached; connected on enable.
    private var stringVoiceSource: StringVoiceSource?
    /// Test hook: the render path's source.
    var stringVoiceSourceForTesting: StringVoiceSource? { stringVoiceSource }
    private var stringVoiceAttached = false
    private var stringVoiceConnected = false
    /// Guarded by `lock`. Armed once at startup and stays on.
    private var useSarangiModelVoice = false
    /// Last structural tarab push, retained for (re)builds.
    private var lastSarangiStrings: [ResolvedString] = []
    private var lastSarangiTonic: Double = 261.63
    /// The melody-follower string: (gain, t60) when enabled, nil when off.
    private var lastSarangiFollower: (gain: Double, t60: Double)?
    /// Scalar overrides applied over `bowed_string.json` at every build.
    public var stringVoiceOverrides: [String: Double] = [:]
    /// Drone buttons: each plucks ONE mapped sympathetic string, found by
    /// identity on its nominal Hz (`droneFreqs`; nil = unmapped → inert).
    /// Guarded by `lock` with `droneHeld` (presses arrive on the MIDI thread).
    private var droneFreqs = [Double?](repeating: nil,
                                       count: FretArrangement.droneCount)
    private var droneHeld = [Bool](repeating: false,
                                   count: FretArrangement.droneCount)
    /// Serial off-main build queue for the String engine; `stringBuildGen`
    /// discards builds superseded while in flight.
    private let stringBuildQueue = DispatchQueue(label: "tarabdaar.string.build",
                                                 qos: .userInitiated)
    private var stringBuildGen = 0

    // MARK: - Tanpura voice

    /// Which voice the drone buttons drive: `.tanpura` (default; press =
    /// pluck, hold = re-pluck cycle) or `.sympathetic` (jt-row swell while held).
    public enum DroneVoiceMode: String, CaseIterable, Sendable {
        case tanpura, sympathetic
    }
    /// Which voice the fret notes drive: `.string` (default) bows; `.tanpura`
    /// / `.sitar` pluck the nearest slot bent to the exact pitch.
    public enum MainInstrument: String, CaseIterable, Sendable {
        case string, tanpura, sitar
    }

    /// The two plucked voices — the SAME mount driven twice (`PluckedVoice`):
    /// the tanpura (second source on the graph, armed at startup as the
    /// default drone voice) and the sitar (third source, armed lazily on the
    /// first `.sitar` switch and kept armed; its tap feeds the jt inject ring).
    private let tanpuraVoice = PluckedVoice.tanpura()
    private let sitarVoice = PluckedVoice.sitar()

    /// Guarded by `lock`.
    private var droneVoiceModeStorage: DroneVoiceMode = .tanpura
    private var mainInstrumentStorage: MainInstrument = .string
    /// Last structural scale push, retained for BOTH plucked (re)builds. Guarded by `lock`.
    private var lastTanpuraTonic: Double = 261.63
    private var lastTanpuraRatios: [Double] = []
    /// MIDI path: a main-instrument pluck waits for the pitch bend that
    /// follows the note-on (it carries the exact pitch). Guarded by `lock`.
    private var tanpuraPendingPluck: [UInt8: (note: UInt8, vel: UInt8)] = [:]
    /// The slot each ringing main-instrument note plucked (bends retune it,
    /// note-off releases it). Cleared on instrument switch and rebuild.
    private var tanpuraChannelSlot: [UInt8: Int] = [:]
    /// Touch-id twin of `tanpuraChannelSlot` for the TLP path.
    private var tanpuraTouchSlot: [UInt16: Int] = [:]
    /// Per-button generation token for the hold re-pluck cycle. Guarded by `lock`.
    private var droneCycleGen = [Int](repeating: 0,
                                      count: FretArrangement.droneCount)
    /// The drone-button trims (`tp_drone_*`) — tanpura-only, so they stay
    /// here rather than on `PluckedVoice`. Guarded by `lock`.
    private var tanpuraDroneLevel = 1.0
    private var tanpuraDroneCycleSec = 2.5
    /// Pending debounced table rebuild (main-thread mutate only).
    private var tanpuraTableRebuildWork: DispatchWorkItem?

    /// The plucked voice a main instrument routes to (nil = String). Callers hold `lock`.
    private func pluckVoiceLocked(_ inst: MainInstrument) -> PluckedVoice? {
        switch inst {
        case .string: return nil
        case .tanpura: return tanpuraVoice
        case .sitar: return sitarVoice
        }
    }

    /// The plucked source a main instrument routes to (nil = String). Callers hold `lock`.
    private func pluckSourceLocked(_ inst: MainInstrument) -> TanpuraVoiceSource? {
        pluckVoiceLocked(inst)?.source
    }

    /// Per-instrument pluck trims. Callers hold `lock`.
    private func pluckTrimsLocked(_ inst: MainInstrument)
        -> (level: Double, touch: Double, drive: Double, relT60: Double) {
        (pluckVoiceLocked(inst) ?? tanpuraVoice).pluckTrims
    }

    /// A plucked build is seconds of CPU — one shared utility-QoS serial queue.
    private let tanpuraBuildQueue = DispatchQueue(label: "tarabdaar.tanpura.build",
                                                  qos: .utility)

    @Published public var isRunning = false

    // MARK: - In-process MIDI bookkeeping (Live-tab readout)

    /// Currently-sounding note per MIDI channel. Guarded by `lock`.
    private var hostedChannelNote: [UInt8: UInt8] = [:]
    /// 14-bit pitch bend per channel (8192 = centre). Guarded by `lock`.
    private var hostedChannelBend: [UInt8: Int] = [:]
    /// Latest CC11 per channel, 0…127 — the Live tab's volume readout.
    /// Guarded by `lock`.
    private var hostedChannelExpr: [UInt8: UInt8] = [:]
    /// Still-held channels in play order, most-recent last; the readout
    /// tracks the last entry. Guarded by `lock`.
    private var heldChannelOrder: [UInt8] = []

    // Touch-keyed twins for the TLP path (full-resolution pitch). When any
    // touch is held the readout prefers it. Guarded by `lock`.
    /// Fractional-MIDI pitch per live touch id.
    private var touchPitchSemis: [UInt16: Double] = [:]
    /// Still-held touches in play order, most-recent last.
    private var heldTouchOrder: [UInt16] = []
    /// Per-touch expression scale (the strum chord; absent = 1). Delivered
    /// by `touchExpr` ahead of the onset; String: the mapper's per-slot
    /// scale, live while held; plucked mains: the pluck level at onset.
    private var touchExprScale: [UInt16: Double] = [:]

    /// Guards the readout scalars below; separate from `lock` so the Live
    /// tab's poll never contends with it. Never held while `lock` is held.
    private let meterLock = NSLock()
    private var meterPitchHz: Double = 0
    private var meterExpr: Double = 0
    private var meterActive: Bool = false

    // MARK: - Profiling

    public private(set) var lastRenderTime: Double = 0
    public private(set) var maxRenderTime: Double = 0
    public private(set) var lastRenderFrames: Int = 0
    public private(set) var lockWaitNanos: UInt64 = 0
    public private(set) var lockAcquisitions: UInt64 = 0

    public func lockAndMeasure() {
        let t0 = CACurrentMediaTime()
        lock.lock()
        let waitNanos = UInt64(max(0, (CACurrentMediaTime() - t0) * 1e9))
        lockWaitNanos &+= waitNanos
        lockAcquisitions &+= 1
    }

    public func snapshotLockStats() -> (avgWaitMicros: Double, count: UInt64) {
        let count = lockAcquisitions
        let total = lockWaitNanos
        lockAcquisitions = 0
        lockWaitNanos = 0
        guard count > 0 else { return (0, 0) }
        return (Double(total) / Double(count) / 1000.0, count)
    }

    // MARK: - Setup

    /// The glide queue the public touch API funnels through: with
    /// `ctl_glide_on` armed, an overlapping onset is queued as a glissando
    /// waypoint instead of mounting a note. Pass-through at the default 0.
    public let glideQueue = GlideSequencer()

    public init() {
        setupAudio()
        glideQueue.onTouchOn = { [weak self] id, pitch, vel in
            self?.touchOnDirect(id, pitchSemis: pitch, velocity: vel)
        }
        glideQueue.onTouchGlide = { [weak self] id, pitch in
            self?.touchGlideDirect(id, pitchSemis: pitch)
        }
        glideQueue.onTouchOff = { [weak self] id in
            self?.touchOffDirect(id)
        }
    }

    private func setupAudio() {
        #if os(macOS)
        // Match the output device to the engine rate BEFORE the graph starts
        // (no resampler to the device). Restored on quit.
        matchOutputDeviceToEngineRate(systemDefaultOutputDevice())
        #endif
        let sampleRate = Config.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: 2)!

        // source nodes attach + connect to symGain on enable
        engine.attach(symGain)
        engine.connect(symGain, to: engine.mainMixerNode, format: format)
        symGain.outputVolume = 1

        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try engine.start()
            isRunning = true
        } catch {
            print("AudioEngine failed to start: \(error)")
        }
        #if os(macOS)
        // transport-aware IO buffer (the device's HAL buffer)
        let beforeBuf = outputBufferFrames
        let wantBuf = preferredBufferFrames(for: currentOutputDevice)
        let gotBuf = setOutputBufferFrames(wantBuf)
        NSLog("Tarabdaar: output IO buffer \(beforeBuf)f → requested \(wantBuf)f → got \(gotBuf)f")
        logAudioLatencyReport("engine started")
        #endif
    }

    /// Stop the AVAudioEngine and tear down the iOS audio session.
    public func suspend() {
        guard isRunning else { return }
        engine.pause()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRunning = false
    }

    public func resume() {
        guard !isRunning else { return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try engine.start()
            isRunning = true
        } catch {
            print("AudioEngine resume failed: \(error)")
        }
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

    /// The device whose nominal rate we changed, plus its original rate (nil = none).
    private var changedDeviceRate: (device: AudioDeviceID, originalRate: Double)?

    /// CoreAudio system default output device.
    private func systemDefaultOutputDevice() -> AudioDeviceID {
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
    private func preferredBufferFrames(for dev: AudioDeviceID) -> UInt32 {
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
    private func matchOutputDeviceToEngineRate(_ dev: AudioDeviceID) {
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

    // MARK: - Recording (post-FX tap on the main mixer)

    private let recordingLock = NSLock()
    // The tap fills a pre-allocated interleaved Int16 buffer (no audio-thread
    // allocation); one complete WAV with our own header is written at stop.
    // Never AVAudioFile here: its incremental write drops the unflushed tail.
    private var recBuf: [Int16] = []      // interleaved L,R; reused across runs
    private var recCount: Int = 0         // valid interleaved Int16 count
    private var recURL: URL?
    private var recSampleRate: Double = 48000
    private var recActive = false
    private var recOverflow = false       // ran out of pre-allocated capacity

    /// Frames written + first error of the last recording (the audition `.done` marker).
    public var lastRecordingStats: (frames: Int64, error: String?) {
        recordingLock.lock(); defer { recordingLock.unlock() }
        return (Int64(recCountFinal / 2), recOverflow ? "buffer overflow (recording exceeded capacity)" : nil)
    }
    private var recCountFinal: Int = 0    // recCount snapshot at last stop

    /// True when a recording is in progress. Updated on the main thread.
    @Published public var isRecording: Bool = false
    /// File URL of the most recently completed (or in-progress) recording.
    @Published public var lastRecordingURL: URL?

    /// Capture post-FX audio at the main mixer into a 16-bit stereo WAV at
    /// `url`, written in full at `stopRecording`. Stops any prior recording.
    public func startRecording(to url: URL) throws {
        stopRecording()
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let sr = outputFormat.sampleRate
        // Pre-allocate ~120 s of stereo so the tap never allocates.
        let cap = Int(sr) * 2 * 120
        recordingLock.lock()
        if recBuf.count < cap { recBuf = [Int16](repeating: 0, count: cap) }
        recCount = 0
        recURL = url
        recSampleRate = sr
        recActive = true
        recOverflow = false
        recordingLock.unlock()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let nch = Int(buffer.format.channelCount)
            let l = ch[0]
            let r = nch > 1 ? ch[1] : ch[0]
            self.recordingLock.lock()
            if self.recActive {
                var idx = self.recCount
                let capCount = self.recBuf.count
                var f = 0
                while f < frames && idx + 1 < capCount {
                    self.recBuf[idx] = Int16(max(-1.0, min(1.0, l[f])) * 32767.0); idx += 1
                    self.recBuf[idx] = Int16(max(-1.0, min(1.0, r[f])) * 32767.0); idx += 1
                    f += 1
                }
                if f < frames { self.recOverflow = true }
                self.recCount = idx
            }
            self.recordingLock.unlock()
        }
        DispatchQueue.main.async {
            self.isRecording = true
            self.lastRecordingURL = url
        }
    }

    /// Stop recording and write the complete WAV synchronously (no-op if none).
    public func stopRecording() {
        recordingLock.lock()
        let active = recActive
        recActive = false
        recordingLock.unlock()
        // removeTap first so no further samples land while we snapshot.
        if active { engine.mainMixerNode.removeTap(onBus: 0) }
        recordingLock.lock()
        let url = recURL
        let n = recCount
        let sr = recSampleRate
        let samples = active ? Array(recBuf[0..<n]) : []
        recCountFinal = n
        recURL = nil
        recCount = 0
        recordingLock.unlock()
        if active, let url {
            Self.writeWavInt16(url: url, interleaved: samples, sampleRate: sr)
        }
        if active {
            DispatchQueue.main.async { self.isRecording = false }
        }
    }

    /// Write a complete 16-bit stereo PCM WAV (own header — no AVAudioFile).
    private static func writeWavInt16(url: URL, interleaved: [Int16], sampleRate: Double) {
        let dataBytes = interleaved.count * 2
        let byteRate = Int(sampleRate) * 2 * 2     // SR * channels * bytesPerSample
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)      // PCM, 2 ch
        u32(Int(sampleRate)); u32(byteRate); u16(4); u16(16)                   // blockAlign 4, 16-bit
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        interleaved.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: url)
    }

    // MARK: - Live performance readout (Live tab)

    /// Live-tab readout: played pitch (Hz), commanded loudness (`expression`
    /// 0…1 from CC11; 0 on the touch path), and whether anything is held.
    public struct PerformanceReadout {
        public let pitchHz: Double
        public let expression: Double
        public let active: Bool
    }

    /// Thread-safe snapshot; poll at UI rate.
    public func performanceReadout() -> PerformanceReadout {
        meterLock.lock()
        defer { meterLock.unlock() }
        return PerformanceReadout(pitchHz: meterPitchHz,
                                  expression: meterExpr,
                                  active: meterActive)
    }

    /// Radiated level of the main voice and of the taraf (the jt bus) for
    /// the iPad's volume scope. Voice = the String voice bus plus the main
    /// instrument's node when plucked (energy sum; the drone never counts).
    /// Interval RMS since the previous poll, linear, 1.0 ≈ 0 dBFS. ONE poller.
    public func volumeLevels() -> (voice: Double, taraf: Double) {
        let bus = stringVoiceSource?.busLevels() ?? (voice: 0, taraf: 0)
        lock.lock()
        let inst = mainInstrumentStorage
        let tp = tanpuraVoice.source
        let st = sitarVoice.source
        lock.unlock()
        var voiceSq = bus.voice * bus.voice
        switch inst {
        case .string: break
        case .tanpura:
            let l = tp?.outputLevel() ?? 0
            voiceSq += l * l
        case .sitar:
            let l = st?.outputLevel() ?? 0
            voiceSq += l * l
        }
        return (voiceSq.squareRoot(), bus.taraf)
    }

    /// `(pitchHz, expression, active)` for the primary held voice. `lock` held.
    private func meterSnapshotLocked() -> (Double, Double, Bool) {
        // touches first: exact pitch; expression reads 0 (the axis idles in the mapper)
        if let id = heldTouchOrder.last, let semis = touchPitchSemis[id] {
            let hz = 440.0 * pow(2.0, (semis - 69.0) / 12.0)
            return (hz, 0, true)
        }
        guard let ch = heldChannelOrder.last, let note = hostedChannelNote[ch] else {
            return (0, 0, false)
        }
        let bend = hostedChannelBend[ch] ?? 8192
        let semis = Double(note)
            + (Double(bend - 8192) / 8192.0) * Config.midiPitchBendRange
        let hz = 440.0 * pow(2.0, (semis - 69.0) / 12.0)
        let expr = Double(hostedChannelExpr[ch] ?? 0) / 127.0
        return (hz, expr, true)
    }

    /// Publish a snapshot. Takes `meterLock`, which must never nest with `lock`.
    private func storeMeter(_ snap: (Double, Double, Bool)) {
        meterLock.lock()
        meterPitchHz = snap.0
        meterExpr = snap.1
        meterActive = snap.2
        meterLock.unlock()
    }

    // MARK: - MIDI in

    /// Push a 3-byte in-process MIDI message. Drone buttons (CC 102–104) are
    /// consumed here; everything else routes through `routeSarangiModelMIDI`.
    public func sendHostedMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let channel = UInt8(status & 0x0F)
        let statusHi = status & 0xF0

        // drone buttons: CC 102+i, value ≥ 64 = pressed; never forwarded.
        // CC 105 is swallowed too (`setDronePressed` bounds-checks it away).
        if statusHi == 0xB0, (102...105).contains(data1) {
            setDronePressed(Int(data1) - 102, data2 >= 64)
            return
        }

        routeSarangiModelMIDI(channel: channel, statusHi: statusHi,
                              data1: data1, data2: data2)
    }

    /// Two-byte variant (Channel Pressure / Program Change) — ignored.
    public func sendHostedMIDI2(status: UInt8, data1: UInt8) {}

    // MARK: - TarabLink touch ingestion (the wire path)
    //
    // Fractional-MIDI pitch keyed by touch id. Thread-safe (link receive queue).

    /// Touch onset, through the glide queue: a fresh note via
    /// `touchOnDirect`, or a queued glissando waypoint.
    public func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double) {
        glideQueue.touchOn(id, pitchSemis: pitchSemis, velocity: velocity)
    }

    /// The glide queue's exemption mark (the strum chord), delivered before `touchOn`.
    public func touchGlideExempt(_ id: UInt16) {
        glideQueue.markExempt(id)
    }

    /// Pitch update, through the glide queue: a drag on a queued waypoint
    /// retargets it; the owning touch's drag meends the voice directly.
    public func touchGlide(_ id: UInt16, pitchSemis: Double) {
        glideQueue.touchGlide(id, pitchSemis: pitchSemis)
    }

    /// Touch release, through the glide queue (never deferred): a chain
    /// member's release is resolved by the sequencer, others forward directly.
    public func touchOff(_ id: UInt16) {
        glideQueue.touchOff(id)
    }

    /// Touch onset, the DIRECT path. A plucked main instrument plucks HERE
    /// at the exact pitch (onset and pitch arrive together).
    private func touchOnDirect(_ id: UInt16, pitchSemis: Double,
                               velocity: Double) {
        lock.lock()
        touchPitchSemis[id] = pitchSemis
        heldTouchOrder.removeAll { $0 == id }
        heldTouchOrder.append(id)
        let inst = mainInstrumentStorage
        let src = stringVoiceSource
        let exprScale = touchExprScale[id] ?? 1.0
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if inst != .string {
            let hz = 440.0 * pow(2.0, (pitchSemis - 69.0) / 12.0)
            pluckMainTouch(inst, hz: hz, velocity: velocity, touch: id,
                           exprScale: exprScale)
            return
        }
        src?.mapper.touchOn(id, pitchSemis: pitchSemis, velocity: velocity,
                            exprScale: exprScale)
    }

    /// Per-touch expression scale (the strum chord). String touches update
    /// the mapper's per-slot scale live; plucked mains consume it at onset.
    public func touchExpr(_ id: UInt16, exprScale: Double) {
        lock.lock()
        touchExprScale[id] = exprScale
        let inst = mainInstrumentStorage
        let src = stringVoiceSource
        lock.unlock()
        if inst == .string {
            src?.mapper.setExprScale(exprScale, forTouch: id)
        }
    }

    /// Pitch update, the DIRECT path. String: the mapper tracks the finger
    /// directly. Plucked mains: live-retune the ringing slot kernel-side.
    private func touchGlideDirect(_ id: UInt16, pitchSemis: Double) {
        lock.lock()
        guard touchPitchSemis[id] != nil else { lock.unlock(); return }
        touchPitchSemis[id] = pitchSemis
        let inst = mainInstrumentStorage
        let tpSlot = tanpuraTouchSlot[id]
        let tpSrc = pluckSourceLocked(inst)
        let src = stringVoiceSource
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if inst != .string {
            if let slot = tpSlot, let engine = tpSrc?.currentEngine(),
               slot < engine.slotFrequencies.count {
                let hz = 440.0 * pow(2.0, (pitchSemis - 69.0) / 12.0)
                engine.bend(slot: slot, ratio: hz / engine.slotFrequencies[slot])
            }
            return
        }
        src?.mapper.touchGlide(id, pitchSemis: pitchSemis)
    }

    /// Touch release, the DIRECT path. String: bow lift. Plucked mains:
    /// fast-release the slot (`tp_rel_t60`), even after a switch back to String.
    private func touchOffDirect(_ id: UInt16) {
        lock.lock()
        touchPitchSemis.removeValue(forKey: id)
        touchExprScale.removeValue(forKey: id)
        heldTouchOrder.removeAll { $0 == id }
        let inst = mainInstrumentStorage
        let tpSlot = tanpuraTouchSlot.removeValue(forKey: id)
        let tpSrc = pluckSourceLocked(inst)
        let relT60 = pluckTrimsLocked(inst).relT60
        let src = stringVoiceSource
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if let slot = tpSlot, let engine = tpSrc?.currentEngine() {
            engine.release(slot: slot, rate: log(1000.0) / max(0.05, relT60))
        }
        if inst == .string {
            src?.mapper.touchOff(id)
        }
    }

    /// The link-drop kill path: every bow off, slot released, drone up,
    /// glide queue cleared — the wire's stuck-note safety net.
    public func touchesAllOff() {
        glideQueue.reset()
        lock.lock()
        touchPitchSemis.removeAll(keepingCapacity: true)
        touchExprScale.removeAll(keepingCapacity: true)
        heldTouchOrder.removeAll(keepingCapacity: true)
        let tpSlots = Array(tanpuraTouchSlot.values)
        tanpuraTouchSlot.removeAll(keepingCapacity: true)
        let tpSrc = pluckSourceLocked(mainInstrumentStorage)
        let relT60 = pluckTrimsLocked(mainInstrumentStorage).relT60
        let src = stringVoiceSource
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if let engine = tpSrc?.currentEngine() {
            let rate = log(1000.0) / max(0.05, relT60)
            for s in tpSlots { engine.release(slot: s, rate: rate) }
        }
        src?.mapper.touchAllOff()
        for i in 0..<FretArrangement.droneCount { setDronePressed(i, false) }
    }

    /// The expression axis (CC11); the Mac pads hold the fitted median here.
    public func setPerformanceExpression(_ v01: Double) {
        stringVoiceSource?.mapper.setAxis(expr: v01)
    }

    /// Touch-keyed twin of `pluckMain`; `exprScale` scales the pluck level
    /// (the strum chord, onset-only).
    private func pluckMainTouch(_ inst: MainInstrument, hz: Double,
                                velocity: Double, touch id: UInt16,
                                exprScale: Double = 1.0) {
        lock.lock()
        let (level, fingerTouch, drive, _) = pluckTrimsLocked(inst)
        let src = pluckSourceLocked(inst)
        lock.unlock()
        guard let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 60)
        else { return }
        let vel = Int((velocity * 127.0).rounded())
        engine.pluck(slot: slot, velocity: min(max(vel, 0), 127),
                     scale: level * exprScale,
                     bendRatio: hz / engine.slotFrequencies[slot],
                     touch: fingerTouch, drive: drive)
        lock.lock()
        tanpuraTouchSlot[id] = slot
        lock.unlock()
    }

    // MARK: - In-process MIDI routing

    /// Route one in-process MIDI message: the `BowControlMapper` mounts a
    /// fresh gut string per note-on with per-channel bend; CCs 11/1/74/2/75
    /// drive the axes. Also keeps the `hostedChannel*` readout bookkeeping.
    private func routeSarangiModelMIDI(channel: UInt8, statusHi: UInt8,
                                       data1: UInt8, data2: UInt8) {
        lock.lock()
        let src = stringVoiceSource
        let mapper = src?.mapper
        if statusHi == 0x90 && data2 > 0 {
            hostedChannelNote[channel] = data1
            hostedChannelBend[channel] = 8192
            heldChannelOrder.removeAll { $0 == channel }
            heldChannelOrder.append(channel)
        } else if statusHi == 0x80 || (statusHi == 0x90 && data2 == 0) {
            hostedChannelNote.removeValue(forKey: channel)
            hostedChannelBend.removeValue(forKey: channel)
            hostedChannelExpr.removeValue(forKey: channel)
            heldChannelOrder.removeAll { $0 == channel }
        } else if statusHi == 0xE0 {
            let bend = (Int(data2) << 7) | Int(data1)
            if hostedChannelNote[channel] != nil { hostedChannelBend[channel] = bend }
        } else if statusHi == 0xB0 {
            if data1 == 11 { hostedChannelExpr[channel] = data2 }
            else if data1 == 123 {
                hostedChannelNote.removeAll(keepingCapacity: true)
                hostedChannelBend.removeAll(keepingCapacity: true)
                hostedChannelExpr.removeAll(keepingCapacity: true)
                heldChannelOrder.removeAll(keepingCapacity: true)
            }
        }
        // Plucked main instrument: the note-on plucks at the EXACT pitch,
        // which arrives on the following pitch bend (CC11 = fallback); later
        // bends retune the slot, note-off releases it. The mapper sees no notes.
        let inst = mainInstrumentStorage
        let tpSrc = pluckSourceLocked(inst)
        var pendingHz: Double?
        var pendingVel: UInt8 = 0
        var pendingChannel: UInt8 = 0
        var bendSlot: (slot: Int, hz: Double)?
        var releaseSlots: [Int] = []
        if inst != .string {
            func soundingHz(note: UInt8) -> Double {
                let bend = hostedChannelBend[channel] ?? 8192
                let semis = Double(note)
                    + (Double(bend - 8192) / 8192.0) * Config.midiPitchBendRange
                return 440.0 * pow(2.0, (semis - 69.0) / 12.0)
            }
            if statusHi == 0x90 && data2 > 0 {
                tanpuraPendingPluck[channel] = (note: data1, vel: data2)
            } else if statusHi == 0x80 || (statusHi == 0x90 && data2 == 0) {
                tanpuraPendingPluck.removeValue(forKey: channel)
                if let s = tanpuraChannelSlot.removeValue(forKey: channel) {
                    releaseSlots.append(s)
                }
            } else if statusHi == 0xB0 && data1 == 123 {
                tanpuraPendingPluck.removeAll(keepingCapacity: true)
                releaseSlots.append(contentsOf: tanpuraChannelSlot.values)
                tanpuraChannelSlot.removeAll(keepingCapacity: true)
            } else if statusHi == 0xE0 || (statusHi == 0xB0 && data1 == 11) {
                if let p = tanpuraPendingPluck.removeValue(forKey: channel) {
                    pendingHz = soundingHz(note: p.note)
                    pendingVel = p.vel
                    pendingChannel = channel
                } else if statusHi == 0xE0,
                          let slot = tanpuraChannelSlot[channel],
                          let note = hostedChannelNote[channel] {
                    bendSlot = (slot, soundingHz(note: note))
                }
            }
        }
        let relT60 = pluckTrimsLocked(inst).relT60
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if let pendingHz {
            pluckMain(inst, hz: pendingHz, velocity: pendingVel,
                      channel: pendingChannel)
        }
        if let engine = tpSrc?.currentEngine() {
            if let b = bendSlot, b.slot < engine.slotFrequencies.count {
                engine.bend(slot: b.slot,
                            ratio: b.hz / engine.slotFrequencies[b.slot])
            }
            let rate = log(1000.0) / max(0.05, relT60)
            for s in releaseSlots { engine.release(slot: s, rate: rate) }
        }
        // Raw tilt axes (`TiltAxisWire`, in-process): 14-bit MSB/LSB pairs,
        // MSB first. Emit on the LSB so the pair lands atomically; a stream
        // that has never carried an LSB is 7-bit — emit on the MSB.
        if statusHi == 0xB0, let axis = TiltAxisWire.ccs.firstIndex(of: data1) {
            tiltMSB[axis] = data2
            if !tiltLSBSeen {
                onTiltAxis?(axis, Double(data2) / 127.0 * 2.0 - 1.0)
            }
        }
        if statusHi == 0xB0, let axis = TiltAxisWire.lsbCCs.firstIndex(of: data1) {
            tiltLSBSeen = true
            let v14 = Int(tiltMSB[axis]) << 7 | Int(data2)
            onTiltAxis?(axis, Double(v14) / 16383.0 * 2.0 - 1.0)
        }
        // composite-parameter slot CCs (audition scores / hardware); the mapper ignores them
        if statusHi == 0xB0, CompositeParam.slotCCs.contains(data1) {
            onCompositeCC?(data1, Double(data2) / 127.0)
        }
        // Notes reach the String mapper only while it is the played
        // instrument; axes/CCs flow either way (kept current for a switch back).
        if inst != .string, statusHi == 0x90 || statusHi == 0x80 { return }
        mapper?.midi(statusHi | channel, data1, data2)
    }

    /// Raw-tilt delivery: (axis 0…2, value −1…+1), MIDI thread; handler must be thread-safe.
    public var onTiltAxis: ((Int, Double) -> Void)?
    /// 14-bit tilt-pair assembly: latest MSB per axis; LSB ever seen (false = 7-bit). MIDI thread.
    private var tiltMSB = [UInt8](repeating: 0, count: 3)
    private var tiltLSBSeen = false

    /// Composite-parameter delivery: (slot CC, value 0…1), MIDI thread;
    /// the handler must be thread-safe.
    public var onCompositeCC: ((UInt8, Double) -> Void)?

    /// Enable/disable the String voice: creates + connects the node on first
    /// enable and builds the engine off-main. False if `bowed_string.json` is missing.
    @discardableResult
    public func setSarangiModelVoiceEnabled(_ on: Bool) -> Bool {
        if on && stringVoiceSource == nil {
            guard Presets.bowedStringParams() != nil else {
                NSLog("Tarabdaar: bowed_string.json missing from the SarangiKit bundle")
                return false
            }
            let src = StringVoiceSource()
            src.mapper.bendRange = Config.midiPitchBendRange
            // always armed — the metered render is bit-exact (`BusMeterTests`)
            src.setBusMeter(true)
            stringVoiceSource = src
        }
        if let src = stringVoiceSource, on != stringVoiceConnected {
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            if on {
                if !stringVoiceAttached {
                    engine.attach(src.node)
                    stringVoiceAttached = true
                }
                let fmt = AVAudioFormat(standardFormatWithSampleRate: src.modelSR, channels: 2)!
                engine.connect(src.node, to: symGain, format: fmt)
            } else {
                engine.disconnectNodeOutput(src.node)
            }
            stringVoiceConnected = on
            if wasRunning {
                do { try engine.start() } catch {
                    print("AudioEngine restart after model-voice switch failed: \(error)")
                    isRunning = false
                }
            }
        }
        stringVoiceSource?.reset()
        lockAndMeasure()
        useSarangiModelVoice = on
        let strings = lastSarangiStrings
        let tonic = lastSarangiTonic
        let follower = lastSarangiFollower
        hostedChannelNote.removeAll(keepingCapacity: true)
        hostedChannelBend.removeAll(keepingCapacity: true)
        hostedChannelExpr.removeAll(keepingCapacity: true)
        heldChannelOrder.removeAll(keepingCapacity: true)
        lock.unlock()
        if on { rebuildStringVoice(tonic: tonic, strings: strings,
                                   follower: follower) }
        storeMeter((0, 0, false))
        return true
    }

    /// Whether the String physics instrument is currently the base voice.
    public var isSarangiModelVoice: Bool {
        lock.lock(); defer { lock.unlock() }
        return useSarangiModelVoice
    }

    // MARK: - Plucked voice bridge (tanpura + sitar, one path)

    /// Enable one plucked voice: mount the source on first enable (artifact
    /// check, out-gain override, the voice→taraf tap at its own drive),
    /// attach/connect the node, then (re)build it on the retained scale.
    /// False only when the fitted artifact is missing.
    @discardableResult
    private func setPluckedVoiceEnabled(_ v: PluckedVoice, _ on: Bool) -> Bool {
        if on && v.source == nil {
            guard v.artifactLoads else {
                NSLog("Tarabdaar: \(v.artifactFile) missing from the SarangiKit bundle")
                return false
            }
            let src = TanpuraVoiceSource()
            if let g = v.gainOverride { src.setOutGain(g) }
            // voice→taraf tap; the String voice exists by now (enabled first)
            if let strSrc = stringVoiceSource {
                src.setInjectSink { strSrc.jtInjectWrite($0, $1) }
            }
            lock.lock()
            let drive = v.tarafDrive
            lock.unlock()
            src.setInjectGain(drive)
            v.source = src
            updateJtInjectArm()
        }
        if let src = v.source, on != v.connected {
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            if on {
                if !v.attached {
                    engine.attach(src.node)
                    v.attached = true
                }
                let fmt = AVAudioFormat(standardFormatWithSampleRate: src.modelSR, channels: 2)!
                engine.connect(src.node, to: symGain, format: fmt)
            } else {
                engine.disconnectNodeOutput(src.node)
            }
            v.connected = on
            if wasRunning {
                do { try engine.start() } catch {
                    print("AudioEngine restart after \(v.name) switch failed: \(error)")
                    isRunning = false
                }
            }
        }
        lock.lock()
        let tonic = lastTanpuraTonic
        let ratios = lastTanpuraRatios
        lock.unlock()
        if on, !ratios.isEmpty {
            rebuildPlucked(v, tonic: tonic, scaleRatios: ratios)
        }
        return true
    }

    /// (Re)build one plucked voice's JI slot grid off-main (seconds of CPU).
    /// A newer build supersedes; `published` runs on main right after the
    /// swap (the per-voice hooks: the slot map and the tanpura's drones).
    private func rebuildPlucked(_ v: PluckedVoice, tonic: Double,
                                scaleRatios: [Double]) {
        lock.lock()
        let armed = v.source != nil
        let artifact = v.artifact
        let registerComp = v.registerComp
        let cascade = v.cascade
        let poly = Int(v.poly.rounded())
        lock.unlock()
        guard armed else { return }
        v.buildGen += 1
        let gen = v.buildGen
        tanpuraBuildQueue.async { [weak self] in
            let engine = TanpuraVoiceSource.buildEngine(tonicHz: tonic,
                                                        scaleRatios: scaleRatios,
                                                        artifact: artifact,
                                                        registerComp: registerComp,
                                                        cascade: cascade,
                                                        polyphony: poly)
            DispatchQueue.main.async {
                guard let self, gen == v.buildGen else { return }
                if engine == nil {
                    NSLog("Tarabdaar: \(v.name) engine build failed (\(v.artifactFile) missing?)")
                }
                v.source?.setEngine(engine)
                self.pluckedEnginePublished(v)
            }
        }
    }

    /// The per-voice hook after a fresh engine is published (main thread):
    /// the fresh slots differ, so held notes lose their binding — the sitar
    /// only owns that map while it IS the main instrument, and the tanpura
    /// re-strikes its held drone buttons onto the silent new engine.
    private func pluckedEnginePublished(_ v: PluckedVoice) {
        lock.lock()
        if v !== sitarVoice || mainInstrumentStorage == .sitar {
            tanpuraChannelSlot.removeAll(keepingCapacity: true)
            tanpuraTouchSlot.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if v === tanpuraVoice { reapplyHeldTanpuraDrones() }
    }

    /// The `<prefix>_*` trims BOTH plucked voices carry. False for a key
    /// outside the shared set (the caller handles its own extras).
    @discardableResult
    private func setPluckedParam(_ v: PluckedVoice, _ key: String,
                                 _ value: Double) -> Bool {
        switch key.hasPrefix(v.prefix) ? String(key.dropFirst(v.prefix.count)) : "" {
        case "gain":
            v.gainOverride = value
            v.source?.setOutGain(value)
        case "pluck_level":
            lock.lock(); v.pluckLevel = value; lock.unlock()
        case "rel_t60":
            lock.lock(); v.releaseT60 = value; lock.unlock()
        case "pluck_touch":
            lock.lock(); v.pluckTouch = value; lock.unlock()
        case "pluck_drive":
            lock.lock(); v.pluckDrive = value; lock.unlock()
        case "poly":
            lock.lock()
            v.poly = value
            let src = v.source
            lock.unlock()
            src?.currentEngine()?.setPolyphony(Int(value.rounded()))
        case "taraf":
            // per-source tap gain; the kernel-side gain is the shared arm
            lock.lock()
            v.tarafDrive = value
            let src = v.source
            lock.unlock()
            src?.setInjectGain(value)
            updateJtInjectArm()
        default:
            return false
        }
        return true
    }

    /// Enable the tanpura source (node + off-main engine build on first
    /// enable). Armed once at startup — the default drone voice.
    @discardableResult
    public func setTanpuraVoiceEnabled(_ on: Bool) -> Bool {
        setPluckedVoiceEnabled(tanpuraVoice, on)
    }

    /// True once a tanpura engine is mounted and renderable.
    public var isTanpuraArmed: Bool { tanpuraVoice.source?.isArmed ?? false }

    /// Tanpura async-pool telemetry (underruns / resets / ringing strings); nil unarmed.
    public func tanpuraStats() -> (underruns: Int, resets: Int, active: Int)? {
        guard let e = tanpuraVoice.source?.currentEngine() else { return nil }
        return (e.underruns, e.resetCount, e.activeStrings)
    }

    /// (Re)build the tanpura's JI slot grid. The tonic + scale are RETAINED
    /// here for both plucked voices (the sitar rebuilds off the same push).
    public func rebuildTanpura(tonic: Double, scaleRatios: [Double]) {
        lock.lock()
        lastTanpuraTonic = tonic
        lastTanpuraRatios = scaleRatios
        lock.unlock()
        rebuildPlucked(tanpuraVoice, tonic: tonic, scaleRatios: scaleRatios)
    }

    /// Enable the sitar voice (the same mount as the tanpura). Its render
    /// tap feeds the jt inject ring (`st_taraf`); the String voice stays
    /// armed and silent so the web can ring. False if `sitar_live.json` is missing.
    @discardableResult
    public func setSitarVoiceEnabled(_ on: Bool) -> Bool {
        setPluckedVoiceEnabled(sitarVoice, on)
    }

    /// True once a sitar engine is mounted and renderable.
    public var isSitarArmed: Bool { sitarVoice.source?.isArmed ?? false }

    /// (Re)build the sitar's JI slot grid — same discipline as `rebuildTanpura`,
    /// no shaping layers.
    public func rebuildSitar(tonic: Double, scaleRatios: [Double]) {
        rebuildPlucked(sitarVoice, tonic: tonic, scaleRatios: scaleRatios)
    }

    /// Apply one `st_*` live registry parameter (same contract as `setTanpuraParam`).
    @discardableResult
    public func setSitarParam(_ key: String, _ value: Double) -> Bool {
        setPluckedParam(sitarVoice, key, value)
    }

    /// (Re)publish the String kernel's inject-ring arm: 1 while any foreign
    /// voice drives the taraf (`st_taraf` / `tp_taraf` > 0), else 0. Levels
    /// live at the taps; both zero keeps the ring unwritten (byte-null).
    private func updateJtInjectArm() {
        lock.lock()
        let armed = sitarVoice.tarafDrive > 0 || tanpuraVoice.tarafDrive > 0
        lock.unlock()
        stringVoiceSource?.setJtInjectGain(armed ? 1.0 : 0.0)
    }

    /// Which voice the drone buttons drive. Switching releases everything
    /// held so the buttons start clean in the new mode.
    public func setDroneVoiceMode(_ mode: DroneVoiceMode) {
        lock.lock()
        guard mode != droneVoiceModeStorage else { lock.unlock(); return }
        let oldMode = droneVoiceModeStorage
        droneVoiceModeStorage = mode
        let heldOld = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        for i in droneHeld.indices { droneHeld[i] = false }
        for i in droneCycleGen.indices { droneCycleGen[i] += 1 }
        let strSrc = stringVoiceSource
        let tpSrc = tanpuraVoice.source
        lock.unlock()
        if oldMode == .sympathetic, let engine = strSrc?.currentEngine() {
            for hz in heldOld {
                if let row = engine.droneRow(forExactHz: hz) {
                    engine.droneRelease(row: row)
                }
            }
        }
        if oldMode == .tanpura { tpSrc?.currentEngine()?.allNotesOff() }
    }

    public var droneVoiceMode: DroneVoiceMode {
        lock.lock(); defer { lock.unlock() }
        return droneVoiceModeStorage
    }

    /// Which voice the played notes drive. Leaving the String voice
    /// releases its notes; leaving a plucked voice drops pending plucks.
    public func setMainInstrument(_ inst: MainInstrument) {
        // an in-flight glissando references the outgoing voice's notes
        glideQueue.reset()
        lock.lock()
        guard inst != mainInstrumentStorage else { lock.unlock(); return }
        let old = mainInstrumentStorage
        mainInstrumentStorage = inst
        tanpuraPendingPluck.removeAll(keepingCapacity: true)
        tanpuraChannelSlot.removeAll(keepingCapacity: true)
        tanpuraTouchSlot.removeAll(keepingCapacity: true)
        let strSrc = stringVoiceSource
        lock.unlock()
        if old == .string { strSrc?.reset() }
        // the sitar arms lazily and stays armed (idle strings are ~free)
        if inst == .sitar { setSitarVoiceEnabled(true) }
    }

    public var mainInstrument: MainInstrument {
        lock.lock(); defer { lock.unlock() }
        return mainInstrumentStorage
    }

    /// Apply one `tp_*` live registry parameter (thread-safe, persists across
    /// rebuilds): the shared plucked trims plus the tanpura's own extras —
    /// the drone-button trims and the two table-build shaping knobs.
    @discardableResult
    public func setTanpuraParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        case "tp_drone_level":
            lock.lock(); tanpuraDroneLevel = value; lock.unlock()
        case "tp_drone_cycle":
            lock.lock(); tanpuraDroneCycleSec = value; lock.unlock()
        case "tp_jiva_comp":
            lock.lock()
            let old = tanpuraVoice.registerComp
            tanpuraVoice.registerComp = value
            lock.unlock()
            // only a real change burns a seconds-long rebuild
            if value != old { scheduleTanpuraTableRebuild() }
        case "tp_cascade":
            lock.lock()
            let oldC = tanpuraVoice.cascade
            tanpuraVoice.cascade = value
            lock.unlock()
            if value != oldC { scheduleTanpuraTableRebuild() }
        default:
            return setPluckedParam(tanpuraVoice, key, value)
        }
        return true
    }

    /// Debounced table-build rebuild: a slider drag settles (750 ms) before
    /// one seconds-long build runs; the generation guard supersedes in-flight ones.
    private func scheduleTanpuraTableRebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tanpuraTableRebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let tonic = self.lastTanpuraTonic
                let ratios = self.lastTanpuraRatios
                self.lock.unlock()
                guard !ratios.isEmpty else { return }
                self.rebuildTanpura(tonic: tonic, scaleRatios: ratios)
            }
            self.tanpuraTableRebuildWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75,
                                          execute: work)
        }
    }

    /// One drone-button pluck at the mapped pitch's slot (50 ¢ tolerance
    /// guards a mid-rebuild mismatch).
    private func tanpuraPluckDrone(_ index: Int) {
        lock.lock()
        let hz = droneFreqs.indices.contains(index) ? droneFreqs[index] : nil
        let level = tanpuraDroneLevel
        let touch = tanpuraVoice.pluckTouch
        let drive = tanpuraVoice.pluckDrive
        let src = tanpuraVoice.source
        lock.unlock()
        guard let hz, let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 50)
        else { return }
        engine.pluck(slot: slot, velocity: 100, scale: level,
                     touch: touch, drive: drive)
    }

    /// Hold re-pluck cycle: re-pluck every `tp_drone_cycle` s while held
    /// (period re-read each hop); a bumped generation orphans the chain.
    private func scheduleDroneCycle(_ index: Int, gen: Int) {
        lock.lock()
        let period = tanpuraDroneCycleSec
        lock.unlock()
        guard period >= 0.1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + period) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.droneCycleGen.indices.contains(index)
                && self.droneCycleGen[index] == gen
                && self.droneHeld.indices.contains(index)
                && self.droneHeld[index]
                && self.droneVoiceModeStorage == .tanpura
            self.lock.unlock()
            guard live else { return }
            self.tanpuraPluckDrone(index)
            self.scheduleDroneCycle(index, gen: gen)
        }
    }

    /// Re-strike held drone buttons on a freshly built tanpura (it starts silent).
    private func reapplyHeldTanpuraDrones() {
        lock.lock()
        let held = droneHeld.indices.filter {
            droneHeld[$0] && droneVoiceModeStorage == .tanpura
        }
        lock.unlock()
        for i in held { tanpuraPluckDrone(i) }
    }

    /// A main-instrument pluck (MIDI path): the nearest slot (60 ¢) bent to
    /// the exact Hz, recorded per channel for later bends / release.
    private func pluckMain(_ inst: MainInstrument, hz: Double,
                           velocity: UInt8, channel: UInt8) {
        lock.lock()
        let (level, touch, drive, _) = pluckTrimsLocked(inst)
        let src = pluckSourceLocked(inst)
        lock.unlock()
        guard let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 60)
        else { return }
        engine.pluck(slot: slot, velocity: Int(velocity), scale: level,
                     bendRatio: hz / engine.slotFrequencies[slot],
                     touch: touch, drive: drive)
        lock.lock()
        tanpuraChannelSlot[channel] = slot
        lock.unlock()
    }

    /// Jawari-web overload telemetry (see `StringVoiceSource.jtStats`); nil without a voice.
    public func stringVoiceJtStats() -> (drops: Double, flat: Double,
                                         fill: Double, on: Double)? {
        stringVoiceSource?.jtStats()
    }

    /// Quiescence-gate probe (see `StringVoiceSource.jtGateProbe`); nil without a voice.
    public func stringVoiceJtGateProbe() -> (asleep: Int, total: Int,
                                             ringR: Double, driveR: Double,
                                             droneHot: Bool)? {
        stringVoiceSource?.jtGateProbe()
    }

    // MARK: - Scope telemetry

    /// The Scope tab's one poll: the main voice's strings (pitch + level) and
    /// every taraf row's pitch, level and character. Display only.
    public struct ScopeSnapshot {
        public struct Voice {
            /// Stable identity across polls (slot + string generation).
            public let id: Int
            public let pitchHz: Double
            /// Held (bow down / touch down); a released string rings on.
            public let held: Bool
            /// 0…1 display level (log-mapped, relative).
            public let level: Double
        }
        public var voices: [Voice] = []
        public var taraf: [BowEngine.ScopeRow] = []
        public var instrument: MainInstrument = .string
    }

    /// Arm/disarm the kernel's display meters (unarmed = byte-null).
    public func setScopeArmed(_ on: Bool) {
        stringVoiceSource?.setScopeArmed(on)
    }

    /// Bowed-string ring envelope → 0…1 display level (60 dB range).
    static func bowScopeLevel01(_ senv: Double) -> Double {
        guard senv > 0 else { return 0 }
        return min(1, max(0, 1 + 20 * log10(senv / 0.5) / 60))
    }

    /// Plucked-string output envelope (1.0 at the pluck) → 0…1 over the same 60 dB.
    static func pluckScopeLevel01(_ env: Double) -> Double {
        TLPVolume.level01(linear: env)
    }

    /// Thread-safe; allocates — poll at UI rate only.
    public func scopeSnapshot() -> ScopeSnapshot {
        lock.lock()
        let inst = mainInstrumentStorage
        let src = stringVoiceSource
        let pluck = pluckSourceLocked(inst)
        let heldSlots = Set(tanpuraTouchSlot.values)
        lock.unlock()
        var snap = ScopeSnapshot()
        snap.instrument = inst
        snap.taraf = src?.scopeRows() ?? []
        switch inst {
        case .string:
            for (i, s) in (src?.scopeSlots() ?? []).enumerated()
                where s.level > 0 || s.gated {
                snap.voices.append(.init(
                    id: i << 32 | Int(s.serial), pitchHz: s.f0Hz,
                    held: s.gated, level: Self.bowScopeLevel01(s.level)))
            }
        case .tanpura, .sitar:
            guard let engine = pluck?.currentEngine() else { break }
            for (i, s) in engine.scopeSlots().enumerated()
                where s.level > 0 {
                snap.voices.append(.init(
                    id: i, pitchHz: s.hz, held: heldSlots.contains(i),
                    level: Self.pluckScopeLevel01(s.level)))
            }
        }
        return snap
    }

    /// Render-deadline telemetry (see `StringVoiceSource.renderStats`); nil without a voice.
    public func stringVoiceRenderStats() -> (maxMs: Double, overruns: UInt64,
                                             callbacks: UInt64)? {
        stringVoiceSource?.renderStats()
    }

    /// Drive one control axis from the UI (0..1): CC11 expr · CC1 press · CC74 pos · CC2/75 tilt.
    public func setSarangiModelVoiceAxis(cc: UInt8, value01: Double) {
        guard let m = stringVoiceSource?.mapper else { return }
        switch cc {
        case 11: m.setAxis(expr: value01)
        case 1: m.setAxis(press: value01)
        case 74: m.setAxis(pos: value01)
        case 2, 75: m.setAxis(tilt: value01)
        default: break
        }
    }

    /// Player vibrato depth 0..1 (the aftertouch axis), as a channel-pressure message.
    public func setStringVibrato(_ v01: Double) {
        let byte = UInt8(max(0, min(127, Int((v01 * 127.0).rounded()))))
        stringVoiceSource?.mapper.midi(0xD0, byte, 0)
    }

    /// Apply one `.live` registry parameter to the String voice — the ONE
    /// instant-apply path. Returns false when the key has no live setter (the
    /// caller rebuilds). Setters are thread-safe and persist across rebuilds.
    @discardableResult
    public func setStringControlParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        // the bow-control axes: the mapper, not the engine
        case "bow_expr":      setSarangiModelVoiceAxis(cc: 11, value01: value)
        case "bow_press":     setSarangiModelVoiceAxis(cc: 1, value01: value)
        case "bow_pos":       setSarangiModelVoiceAxis(cc: 74, value01: value)
        case "bow_tilt":      setSarangiModelVoiceAxis(cc: 75, value01: value)
        default:
            // the knob plumbing table (clamp + cache + push, and re-applied
            // across a rebuild); it owns the key even with no voice armed yet
            if StringVoiceSource.handlesControl(key) {
                stringVoiceSource?.setControl(key, value)
                return true
            }
            // FX rack: `fx_<point>_<field>` keys route to the source's cached settings
            if key.hasPrefix("fx_") {
                return stringVoiceSource?.setFXParam(key, value) ?? false
            }
            // the tanpura's `tp_*` group
            if key.hasPrefix("tp_") {
                return setTanpuraParam(key, value)
            }
            // the sitar's `st_*` group
            if key.hasPrefix("st_") {
                return setSitarParam(key, value)
            }
            return false
        }
        return true
    }

    /// Drive the kernel's live 0…1 scaler behind a `.hybrid` parameter (a
    /// build-time depth turned DOWN without a rebuild; `ParamRegistry` converts).
    public func setStringHybridScaler(_ scaler: ParamRegistry.HybridScaler,
                                      _ amount01: Double) {
        let a = max(0.0, min(1.0, amount01))
        switch scaler {
        case .vibratoAmount:  setStringVibrato(a)
        }
    }

    // MARK: - Drone buttons (Fret Pad)

    /// Update which strings the drone buttons pluck (mapping only — no
    /// rebuild). Any held button is released first.
    public func setDroneMappedFreqs(_ freqs: [Double?]) {
        lock.lock()
        let heldOld = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        for i in droneFreqs.indices {
            droneFreqs[i] = freqs.indices.contains(i) ? freqs[i] : nil
            droneHeld[i] = false
        }
        for i in droneCycleGen.indices { droneCycleGen[i] += 1 }
        let mode = droneVoiceModeStorage
        let src = stringVoiceSource
        lock.unlock()
        guard mode == .sympathetic, let engine = src?.currentEngine() else { return }
        for hz in heldOld {
            if let row = engine.droneRow(forExactHz: hz) {
                engine.droneRelease(row: row)
            }
        }
    }

    /// Press/release drone button `index` (0–2). Tanpura mode: press plucks
    /// + starts the re-pluck cycle, release rings out. Sympathetic mode:
    /// hold/release the mapped jt row. Unmapped = inert. MIDI-thread safe.
    public func setDronePressed(_ index: Int, _ pressed: Bool) {
        lock.lock()
        guard droneHeld.indices.contains(index),
              let hz = droneFreqs[index] else { lock.unlock(); return }
        let was = droneHeld[index]
        droneHeld[index] = pressed
        let mode = droneVoiceModeStorage
        if mode == .tanpura, pressed != was {
            droneCycleGen[index] += 1
        }
        let cycleGen = droneCycleGen[index]
        // a release must not silence a row another held button maps to
        let othersHeld = droneHeld.indices
            .filter { $0 != index && droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        let src = stringVoiceSource
        lock.unlock()
        guard pressed != was else { return }
        if mode == .tanpura {
            guard pressed else { return }   // release = ring out
            tanpuraPluckDrone(index)
            scheduleDroneCycle(index, gen: cycleGen)
            return
        }
        guard let engine = src?.currentEngine(),
              let row = engine.droneRow(forExactHz: hz)
        else { return }
        if pressed {
            engine.dronePress(row: row)
        } else if !othersHeld.contains(where: {
            engine.droneRow(forExactHz: $0) == row
        }) {
            engine.droneRelease(row: row)
        }
    }

    /// Re-arm held drones on a freshly built engine (it starts silent).
    private func reapplyHeldDrones(to engine: BowEngine) {
        lock.lock()
        let held = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        lock.unlock()
        for hz in held {
            if let row = engine.droneRow(forExactHz: hz) {
                engine.dronePress(row: row)
            }
        }
    }

    /// Build a fresh String `BowEngine` off-main and publish it; the mapper
    /// keeps held notes/axes across the swap, a newer build supersedes.
    private func rebuildStringVoice(tonic: Double, strings: [ResolvedString],
                                    follower: (gain: Double, t60: Double)? = nil) {
        guard let src = stringVoiceSource else { return }
        stringBuildGen += 1
        let gen = stringBuildGen
        let overrides = stringVoiceOverrides
        let mapper = src.mapper
        stringBuildQueue.async { [weak self] in
            let engine = StringVoiceSource.buildEngine(tonicHz: tonic,
                                                      strings: strings,
                                                      mapper: mapper,
                                                      overrides: overrides,
                                                      follower: follower)
            DispatchQueue.main.async {
                guard let self, gen == self.stringBuildGen else { return }
                if engine == nil {
                    NSLog("Tarabdaar: String engine build failed (bowed_string.json missing?)")
                }
                self.stringVoiceSource?.setEngine(engine)
                if let engine { self.reapplyHeldDrones(to: engine) }
            }
        }
    }

    /// Push overrides onto the RUNNING engine when every changed key is in
    /// `ParamRegistry.inPlaceKeys`. False = the caller must rebuild.
    @discardableResult
    public func applyStringVoiceOverridesInPlace(
        _ overrides: [String: Double], changed: Set<String>) -> Bool {
        guard !changed.isEmpty,
              changed.allSatisfy({ ParamRegistry.appliesInPlace($0) })
        else { return false }
        lock.lock()
        let on = useSarangiModelVoice
        let tonic = lastSarangiTonic
        let strings = lastSarangiStrings
        let follower = lastSarangiFollower
        lock.unlock()
        guard on, let src = stringVoiceSource else { return false }
        stringVoiceOverrides = overrides
        // the jawari tables are the costly half — only when a jt key moved
        let jtTouched = changed.contains { $0.hasPrefix("bow_jt") }
        return src.applyLiveParams(tonicHz: tonic, strings: strings,
                                   overrides: overrides,
                                   follower: follower,
                                   needsJawariTables: jtTouched)
    }

    /// Re-apply the overrides with a rebuild (artifact scalars bake into the tables).
    public func setStringVoiceOverrides(_ overrides: [String: Double]) {
        stringVoiceOverrides = overrides
        lock.lock()
        let on = useSarangiModelVoice
        let tonic = lastSarangiTonic
        let strings = lastSarangiStrings
        let follower = lastSarangiFollower
        lock.unlock()
        if on { rebuildStringVoice(tonic: tonic, strings: strings,
                                   follower: follower) }
    }

    /// Effective hardware sample rate of the current output device.
    public var outputSampleRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    // MARK: - Tarab tuning (Strings tab) → String voice

    /// Push the tarab tuning (tonic + resolved strings) to the String
    /// voice's in-kernel taraf; the build runs off-main. `droneFreqs` = per
    /// drone button, the mapped string's nominal Hz (nil = inert);
    /// `follower` = the melody-follower's (gain, t60) when enabled.
    public func rebuildSarangi(strings: [ResolvedString], tonic: Double,
                               droneFreqs: [Double?] = [],
                               follower: (gain: Double, t60: Double)? = nil) {
        lockAndMeasure()
        lastSarangiStrings = strings
        lastSarangiTonic = tonic
        lastSarangiFollower = follower
        for i in self.droneFreqs.indices {
            self.droneFreqs[i] = droneFreqs.indices.contains(i) ? droneFreqs[i] : nil
        }
        // a slot unmapped while held must not stay latched
        for i in droneHeld.indices where self.droneFreqs[i] == nil {
            droneHeld[i] = false
        }
        let armModel = useSarangiModelVoice
        lock.unlock()
        if armModel { rebuildStringVoice(tonic: tonic, strings: strings,
                                         follower: follower) }
    }

    deinit {
        #if os(macOS)
        restoreOutputDeviceRate()
        #endif
        engine.stop()
    }
}
