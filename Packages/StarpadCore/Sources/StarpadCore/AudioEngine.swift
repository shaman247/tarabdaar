import AVFoundation
import Foundation
import QuartzCore
import SarangiKit

/// macOS audio plumbing for the sarangi **String voice** — the only voice.
///
/// The played voice is the pure-physics bowed gut string (`StringVoiceSource`
/// wrapping `SarangiKit.BowEngine`, the C friction kernel with the modal-jawari
/// taraf fused in-kernel). The kernel is the WHOLE instrument (played strings +
/// taraf + body + radiation + room), so its source node connects DIRECTLY to
/// `symGain`, which feeds the engine's main mixer:
///
///   `stringVoiceSource.node → symGain → mainMixerNode → output`
///
/// MPE MIDI arrives at `sendHostedMIDI` and is routed to the String voice's
/// `BowControlMapper` (`routeSarangiModelMIDI`); the Fret Pad drone buttons
/// (CC 102–104) drive the kernel's jawari-taraf drone rows. The tarab tuning
/// (from the Tarab tab, pushed via `rebuildSarangi`) tunes the kernel's taraf;
/// the String physics scalars ride `stringVoiceOverrides`.
///
/// Sym public methods acquire `lock` and swap/configure the String engine.
public class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    /// Output-gain stage for the String voice source node. Pinned at unity —
    /// the kernel is the complete played voice and feeds `mainMixerNode` directly.
    private let symGain = AVAudioMixerNode()
    private let lock = NSLock()

    // MARK: - Sarangi model source (the String pure-physics bowed gut string)

    /// The String-physics source (`StringVoiceSource` wrapping
    /// `SarangiKit.BowEngine` — the C friction kernel with the modal-jawari
    /// taraf fused in-kernel). The kernel is the WHOLE instrument (played
    /// strings + taraf + body + radiation + room), so its node connects
    /// DIRECTLY to `symGain`. Runs at the artifact's native 48 kHz; the mixer
    /// input converts to the engine rate. Kept attached; connected on enable.
    private var stringVoiceSource: StringVoiceSource?
    private var stringVoiceAttached = false
    private var stringVoiceConnected = false
    /// Guarded by `lock`. The String voice is the only voice, so this is armed
    /// once at startup and stays on.
    private var useSarangiModelVoice = false
    /// Last structural tarab push, retained so the String engine can be
    /// (re)built from the current tuning when the voice is enabled later.
    private var lastSarangiStrings: [ResolvedString] = []
    private var lastSarangiTonic: Double = 261.63
    /// The melody-follower string (2026-07-25): (gain, t60) when enabled,
    /// nil when off — pushed with every `rebuildSarangi` like the rows.
    private var lastSarangiFollower: (gain: Double, t60: Double)?
    /// String-editor / audition scalar overrides applied OVER the
    /// `bowed_string.json` artifact at every String engine build.
    public var stringVoiceOverrides: [String: Double] = [:]
    /// Drone buttons (Fret Pad, 2026-07-23; string-mapped 2026-07-25):
    /// each of the 3 buttons plucks ONE mapped sympathetic string —
    /// `droneFreqs` holds the mapped rows' nominal Hz
    /// (`InstrumentState.droneStringFreqs`, pushed with every
    /// `rebuildSarangi`; nil = unmapped/disabled → button inert). A press
    /// finds the jt row by identity (`BowEngine.droneRow(forExactHz:)`) —
    /// no dedicated rows, no nearest-pitch matching. Guarded by `lock`
    /// with `droneHeld` (presses arrive on the MIDI thread, config on
    /// main).
    private var droneFreqs = [Double?](repeating: nil,
                                       count: FretArrangement.droneCount)
    private var droneHeld = [Bool](repeating: false,
                                   count: FretArrangement.droneCount)
    /// Serial build queue for the String engine (tables + kernel init + jt
    /// worker-pool spawn are too heavy for the main thread); `stringBuildGen`
    /// discards builds that were superseded while in flight.
    private let stringBuildQueue = DispatchQueue(label: "starpad.string.build",
                                                 qos: .userInitiated)
    private var stringBuildGen = 0

    @Published public var isRunning = false

    // MARK: - MPE bookkeeping (Live-tab readout)

    /// Currently-sounding note number per MPE channel (one note per channel
    /// in MPE). Tracked MPE bookkeeping; guarded by `lock`.
    private var hostedChannelNote: [UInt8: UInt8] = [:]
    /// Current 14-bit pitch-bend value per MPE channel (8192 = centre). Tracked
    /// MPE bookkeeping; guarded by `lock`.
    private var hostedChannelBend: [UInt8: Int] = [:]
    /// Most recent CC11 (Expression) value per MPE channel, 0…127. Mirrored
    /// here only to surface the live "volume" readout in the Mac Live tab.
    /// Guarded by `lock`.
    private var hostedChannelExpr: [UInt8: UInt8] = [:]
    /// Still-held note channels in play order, most-recent **last**. The
    /// Live tab's pitch/volume graphs track the last entry — the voice
    /// struck most recently — and on its release fall back deterministically
    /// to the next-most-recent. Guarded by `lock`.
    private var heldChannelOrder: [UInt8] = []

    /// Lightweight lock guarding the performance-readout scalars below.
    /// Separate from `lock` so the Live tab's poll never contends with the
    /// audio render thread. Never held while `lock` is held.
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

    public init() {
        setupAudio()
    }

    private func setupAudio() {
        #if os(macOS)
        // Match the output device to the engine/model rate (44.1 kHz) BEFORE the
        // graph is built + started, so the engine adopts a 44.1 kHz output and
        // there is no resampler between mainMixerNode and the device. Restored on
        // quit (AppController wires `restoreOutputDeviceRate` to willTerminate).
        matchOutputDeviceToEngineRate(systemDefaultOutputDevice())
        #endif
        let sampleRate = Config.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: 2)!

        // Graph — the String voice is the COMPLETE played voice. Its source node
        // is attached + connected to `symGain` when the voice is enabled
        // (`setSarangiModelVoiceEnabled`); `symGain` feeds the main mixer:
        //   stringVoiceSource.node → symGain → mainMixerNode → output
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
        // Request a low IO buffer for play latency. macOS has no per-app IO
        // buffer (no AVAudioSession) — this is the output device's HAL buffer,
        // clamped to its allowed range. Tunable live via `setOutputBufferFrames`.
        let beforeBuf = outputBufferFrames
        let gotBuf = setOutputBufferFrames(Config.preferredOutputBufferFrames)
        NSLog("Starpad: output IO buffer \(beforeBuf)f → requested \(Config.preferredOutputBufferFrames)f → got \(gotBuf)f")
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
        // Match the NEW device to the engine rate (and restore the old one)
        // before restarting, so the engine adopts a 44.1 kHz output.
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
        // The IO buffer is a per-device property — re-apply the low buffer to
        // the new device.
        setOutputBufferFrames(Config.preferredOutputBufferFrames)
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

    /// The device whose nominal sample rate we changed to match the engine, plus
    /// its original rate — so we can restore it on quit / device switch. nil when
    /// no device has been changed.
    private var changedDeviceRate: (device: AudioDeviceID, originalRate: Double)?

    /// CoreAudio system default output device (the one AVAudioEngine uses until
    /// `setOutputDevice` overrides it).
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

    /// Set a device's nominal sample rate and poll until it settles (the change
    /// is asynchronous in CoreAudio). Returns true once it reaches `sr`.
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

    /// Match `dev`'s sample rate to the engine/model rate (`Config.sampleRate`,
    /// 44.1 kHz) so the engine → device path has no resampler. Best-effort:
    /// skipped if the device does not support the rate (then AVAudioEngine's
    /// converter bridges as before). Remembers the device's prior rate; restore
    /// with `restoreOutputDeviceRate`.
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
            NSLog("Starpad: output device lacks \(Int(target)) Hz — leaving at \(Int(current)) Hz (resampler stays)")
            return
        }
        if changedDeviceRate == nil { changedDeviceRate = (dev, current) }
        let ok = setDeviceNominalSampleRate(dev, target)
        NSLog("Starpad: output device rate \(Int(current)) → \(Int(target)) Hz: \(ok ? "OK (no resampler)" : "FAILED")")
    }

    /// Restore any output device whose rate we changed back to its original.
    /// Wire to a clean-quit hook (`NSApplication.willTerminateNotification`) so
    /// the user's device is not left at 44.1 kHz after Starpad exits.
    public func restoreOutputDeviceRate() {
        guard let prev = changedDeviceRate else { return }
        setDeviceNominalSampleRate(prev.device, prev.originalRate)
        NSLog("Starpad: restored output device rate → \(Int(prev.originalRate)) Hz")
        changedDeviceRate = nil
    }

    /// The output device's current IO buffer size in frames (0 if unknown). On
    /// macOS this is the CoreAudio HAL buffer — the floor under round-trip
    /// latency. Settable via `setOutputBufferFrames`.
    public var outputBufferFrames: UInt32 {
        guard let au = engine.outputNode.audioUnit else { return 0 }
        var n: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(au, kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0, &n, &size)
        return n
    }

    /// Request a smaller IO buffer on the output device (lower latency). macOS
    /// has no per-app IO buffer (no AVAudioSession); the buffer is a device HAL
    /// property, so this is clamped to the device's allowed range and affects
    /// that device system-wide. Returns the value actually in effect afterward.
    @discardableResult
    public func setOutputBufferFrames(_ frames: UInt32) -> UInt32 {
        guard let au = engine.outputNode.audioUnit else { return 0 }
        var n = frames
        AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0, &n,
                             UInt32(MemoryLayout<UInt32>.size))
        return outputBufferFrames
    }

    /// One-shot diagnostic: log the played-voice latency budget — engine vs
    /// device sample rate (a mismatch means an output resampler), the IO buffer
    /// size, and the output presentation latency.
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
        NSLog("Starpad: \(msg)")
    }
    #endif

    // MARK: - Recording (post-FX tap on the main mixer)

    private let recordingLock = NSLock()
    // Recording is accumulated into a pre-allocated interleaved Int16 buffer
    // by the tap (no audio-thread allocation), then written as one complete
    // WAV at stop. We do NOT use AVAudioFile: its incremental write buffers
    // internally and DROPS the unflushed tail on dispose for long recordings
    // (the frames are "written" but lost before flush — verified: framesWritten
    // full, file ~260 KB), which produced intermittent 0-frame WAVs. Owning the
    // buffer + header makes the file deterministic and complete.
    private var recBuf: [Int16] = []      // interleaved L,R; reused across runs
    private var recCount: Int = 0         // valid interleaved Int16 count
    private var recURL: URL?
    private var recSampleRate: Double = 48000
    private var recActive = false
    private var recOverflow = false       // ran out of pre-allocated capacity

    /// Frames written + first error of the last recording — surfaced in the
    /// audition `.done` marker so any silent failure is visible.
    public var lastRecordingStats: (frames: Int64, error: String?) {
        recordingLock.lock(); defer { recordingLock.unlock() }
        return (Int64(recCountFinal / 2), recOverflow ? "buffer overflow (recording exceeded capacity)" : nil)
    }
    private var recCountFinal: Int = 0    // recCount snapshot at last stop

    /// True when a recording is in progress. Updated on the main thread.
    @Published public var isRecording: Bool = false
    /// File URL of the most recently completed (or in-progress) recording.
    @Published public var lastRecordingURL: URL?

    /// Begin capturing post-FX audio (after reverb, at the main mixer) into a
    /// 16-bit stereo WAV at `url`, written in full at `stopRecording`.
    /// Idempotent — always stops any prior recording first.
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

    /// Live performance readout for the Mac "Live" tab: the currently
    /// played pitch (Hz, from the tracked Note + pitch-bend) and the
    /// commanded loudness (`expression`, 0…1, from CC11). `active` is false
    /// when nothing is held. Derived at the single MIDI choke point below,
    /// so it reflects every input path: the USB iPad, the Mac pads, and the
    /// simulator.
    public struct PerformanceReadout {
        public let pitchHz: Double
        public let expression: Double
        public let active: Bool
    }

    /// Thread-safe snapshot of the current played pitch + loudness. Cheap —
    /// poll it at UI rate.
    public func performanceReadout() -> PerformanceReadout {
        meterLock.lock()
        defer { meterLock.unlock() }
        return PerformanceReadout(pitchHz: meterPitchHz,
                                  expression: meterExpr,
                                  active: meterActive)
    }

    /// Recompute `(pitchHz, expression, active)` for the primary held voice
    /// from the tracked MPE maps. `lock` must be held; pure read → locals.
    private func meterSnapshotLocked() -> (Double, Double, Bool) {
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

    /// Publish a snapshot into the readout scalars. Call with **no other
    /// lock held** (it takes `meterLock`, which must never nest with `lock`).
    private func storeMeter(_ snap: (Double, Double, Bool)) {
        meterLock.lock()
        meterPitchHz = snap.0
        meterExpr = snap.1
        meterActive = snap.2
        meterLock.unlock()
    }

    // MARK: - MIDI in

    /// Push a 3-byte MIDI message into the String voice. Drone buttons
    /// (Fret Pad, CC 102–104) are consumed here; everything else is routed
    /// to the String voice's `BowControlMapper`.
    public func sendHostedMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let channel = UInt8(status & 0x0F)
        let statusHi = status & 0xF0

        // Drone buttons (Fret Pad): CC 102+i press/release (value ≥ 64 =
        // pressed). Consumed here — never forwarded to the mapper. CC 105
        // (the retired 4th slot) is still swallowed so an old iPad build
        // can't leak it into the mapper; `setDronePressed` bounds-checks it
        // into a no-op.
        if statusHi == 0xB0, (102...105).contains(data1) {
            setDronePressed(Int(data1) - 102, data2 >= 64)
            return
        }

        routeSarangiModelMIDI(channel: channel, statusHi: statusHi,
                              data1: data1, data2: data2)
    }

    /// Two-byte variant for Channel Pressure (0xDx) and Program Change (0xCx).
    /// The String voice ignores both (aftertouch vibrato arrives as polyphonic
    /// aftertouch 0xAx, a 3-byte message on the path above).
    public func sendHostedMIDI2(status: UInt8, data1: UInt8) {}

    // MARK: - Sarangi-model voice bridge (the String physics instrument)

    /// Route one MPE message to the String source. The `BowControlMapper`
    /// allocates gut-string slots physically (poly chords, mono meend on a
    /// single line) with per-channel MPE pitch bend; CCs 11/1/74/2/75 drive the
    /// expr/press/pos/tilt axes; aftertouch is player vibrato. Also updates the
    /// `hostedChannel*` bookkeeping so the Live readout tracks pitch/expression.
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
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        // RAW TILT REPORT (2026-07-24): the controller streams only its
        // three calibrated tilt values on the fixed axis messages
        // (`TiltAxisWire`) — it knows nothing about parameters or
        // mappings. Forwarded to the host (AppController), which
        // evaluates its own tilt bindings (composites + performance
        // parameters). Called on the MIDI thread; handler thread-safe.
        if statusHi == 0xB0, let axis = TiltAxisWire.ccs.firstIndex(of: data1) {
            onTiltAxis?(axis, Double(data2) / 127.0)
        }
        // COMPOSITE PARAMETER slots (2026-07-24): direct slot-CC drives
        // (audition scores / external hardware; the iPad no longer sends
        // these). The mapper ignores these CCs.
        if statusHi == 0xB0, CompositeParam.slotCCs.contains(data1) {
            onCompositeCC?(data1, Double(data2) / 127.0)
        }
        mapper?.midi(statusHi | channel, data1, data2)
    }

    /// Raw-tilt delivery (2026-07-24): fired with (axis 0…2, value 0…1)
    /// for each incoming tilt-axis message — on the MIDI thread; the
    /// handler must be thread-safe.
    public var onTiltAxis: ((Int, Double) -> Void)?

    /// Composite-parameter delivery (2026-07-24): fired with
    /// (slot CC, value 0…1) for every incoming slot-CC message — on the
    /// MIDI thread; the handler must be thread-safe. Set by the host
    /// (AppController wires it to its composite apply path).
    public var onCompositeCC: ((UInt8, Double) -> Void)?

    /// Enable/disable the String physics instrument. On first enable the
    /// source node is created and connected DIRECTLY to `symGain`, and the
    /// `BowEngine` is built off-main from the current tonic + tarab strings.
    /// Returns false when `bowed_string.json` is missing.
    @discardableResult
    public func setSarangiModelVoiceEnabled(_ on: Bool) -> Bool {
        if on && stringVoiceSource == nil {
            guard Presets.bowedStringParams() != nil else {
                NSLog("Starpad: bowed_string.json missing from the SarangiKit bundle")
                return false
            }
            let src = StringVoiceSource()
            src.mapper.bendRange = Config.midiPitchBendRange
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

    /// Runtime BASE PARAMETERS of the String voice (2026-07-24 composite
    /// rework) — the live-appliable base params composite parameters
    /// sweep (no engine rebuild; chunk-rate smoothed in `BowEngine`).
    /// Values persist across engine rebuilds. Thread-safe.
    public func setStringJtToneLp(hz: Double) {
        stringVoiceSource?.setJtToneLp(hz: hz)
    }
    public func setStringJtToneHp(hz: Double) {
        stringVoiceSource?.setJtToneHp(hz: hz)
    }
    public func setStringJtBody(_ mix01: Double) {
        stringVoiceSource?.setJtBody(mix01)
    }
    public func setStringTarafDamp(_ amt01: Double) {
        stringVoiceSource?.setTarafDamp(amt01)
    }
    public func setStringToneTilt(_ t: Double) {
        stringVoiceSource?.setToneTilt(t)
    }
    public func setStringTarafSelectivity(_ s01: Double) {
        stringVoiceSource?.setTarafSelectivity(s01)
    }
    public func setStringJtEvolve(_ e01: Double) {
        stringVoiceSource?.setJtEvolve(e01)
    }

    /// String-voice jawari-web overload telemetry (see
    /// `StringVoiceSource.jtStats`). nil when the voice isn't created.
    public func stringVoiceJtStats() -> (drops: Double, flat: Double,
                                         fill: Double, on: Double)? {
        stringVoiceSource?.jtStats()
    }

    /// String-voice render-deadline telemetry (see
    /// `StringVoiceSource.renderStats`). nil when the voice isn't created.
    public func stringVoiceRenderStats() -> (maxMs: Double, overruns: UInt64,
                                             callbacks: UInt64)? {
        stringVoiceSource?.renderStats()
    }

    /// Drive one of the String voice's control axes from the UI (0..1),
    /// through the same axes the CCs drive (CC11 expr · CC1 press · CC74
    /// pos · CC2/75 tilt). No-op when the source isn't created yet.
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

    /// Player vibrato depth 0..1 (the aftertouch axis) — delivered as a
    /// channel-pressure message so the mapper's vibrato path picks it up.
    public func setStringVibrato(_ v01: Double) {
        let byte = UInt8(max(0, min(127, Int((v01 * 127.0).rounded()))))
        stringVoiceSource?.mapper.midi(0xD0, byte, 0)
    }

    /// Apply one `.live` registry parameter to the String voice — the
    /// unified instant-apply path for the Parameters tab, composite
    /// members and direct tilt bindings. Returns false when the key has no
    /// live setter (the caller routes it through the rebuild path). All
    /// setters are thread-safe and persist across engine rebuilds.
    @discardableResult
    public func setStringControlParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        case "bow_expr":      setSarangiModelVoiceAxis(cc: 11, value01: value)
        case "bow_press":     setSarangiModelVoiceAxis(cc: 1, value01: value)
        case "bow_pos":       setSarangiModelVoiceAxis(cc: 74, value01: value)
        case "bow_tilt":      setSarangiModelVoiceAxis(cc: 75, value01: value)
        // The registry's top of range means "bypass" — hand the engine 0
        // so it restores the EXACT build-time coefficient (bit-exact
        // legacy) instead of engaging the runtime filter at its ceiling.
        // Matters at rest: the unified apply pushes every live parameter
        // at startup, and this one rests at 20 kHz.
        case "bow_jt_lp":     setStringJtToneLp(hz: value >= 20000 ? 0 : value)
        case "bow_jt_hp":     setStringJtToneHp(hz: value)
        case "bow_jt_body":   setStringJtBody(value)
        case "bow_jt_damp":   setStringTarafDamp(value)
        case "bow_jt_sel":    setStringTarafSelectivity(value)
        case "bow_jt_evolve": setStringJtEvolve(value)
        case "bow_tone_tilt": setStringToneTilt(value)
        default:
            // FX rack (2026-08-01): every `fx_<point>_<field>` key routes
            // to the source's cached settings (re-applied across rebuilds).
            if key.hasPrefix("fx_") {
                return stringVoiceSource?.setFXParam(key, value) ?? false
            }
            return false
        }
        return true
    }

    /// Drive the kernel's live 0…1 scaler behind a `.hybrid` parameter.
    /// The scaler is an implementation detail — it exists so a build-time
    /// depth (vibrato cents) can be turned DOWN from its built value
    /// without an engine rebuild. `ParamRegistry` owns the native-units ↔
    /// scaler conversion; no UI shows these directly.
    public func setStringHybridScaler(_ scaler: ParamRegistry.HybridScaler,
                                      _ amount01: Double) {
        let a = max(0.0, min(1.0, amount01))
        switch scaler {
        case .vibratoAmount:  setStringVibrato(a)
        }
    }

    // MARK: - Drone buttons (Fret Pad)

    /// Update which sympathetic strings the drone buttons pluck. A
    /// mapping-only change — the jawari web is untouched, so no rebuild.
    /// Any held button is released first (its OLD row must not drone on
    /// with no release path to it).
    public func setDroneMappedFreqs(_ freqs: [Double?]) {
        lock.lock()
        let heldOld = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        for i in droneFreqs.indices {
            droneFreqs[i] = freqs.indices.contains(i) ? freqs[i] : nil
            droneHeld[i] = false
        }
        let src = stringVoiceSource
        lock.unlock()
        guard let engine = src?.currentEngine() else { return }
        for hz in heldOld {
            if let row = engine.droneRow(forExactHz: hz) {
                engine.droneRelease(row: row)
            }
        }
    }

    /// Press/release drone button `index` (0–2): pluck-and-hold / release
    /// the mapped sympathetic string's jt row (identity lookup on its
    /// nominal Hz). Unmapped slot / string not in the web = inert. Safe
    /// from the MIDI thread.
    public func setDronePressed(_ index: Int, _ pressed: Bool) {
        lock.lock()
        guard droneHeld.indices.contains(index),
              let hz = droneFreqs[index] else { lock.unlock(); return }
        let was = droneHeld[index]
        droneHeld[index] = pressed
        // Frequencies of the OTHER still-held buttons — a release must not
        // silence a row another button also maps to.
        let othersHeld = droneHeld.indices
            .filter { $0 != index && droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        let src = stringVoiceSource
        lock.unlock()
        guard pressed != was, let engine = src?.currentEngine(),
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

    /// Re-arm held drones on a freshly-built engine (a structural rebuild
    /// starts from silent drone state).
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

    /// Build a fresh String `BowEngine` for the tuning (tonic + tarab rows)
    /// off the main thread and publish it lock-free. The long-lived mapper
    /// keeps held notes/axes across the swap; a newer build supersedes any
    /// in-flight older one. Called on voice enable and on every structural
    /// tarab/tonic change.
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
                    NSLog("Starpad: String engine build failed (bowed_string.json missing?)")
                }
                self.stringVoiceSource?.setEngine(engine)
                if let engine { self.reapplyHeldDrones(to: engine) }
            }
        }
    }

    /// Push overrides onto the RUNNING String engine when every changed
    /// key can be applied in place (`ParamRegistry.inPlaceKeys`), so a
    /// physics edit costs nothing and interrupts nothing. Returns false if
    /// anything needs a real rebuild — the caller then goes the slow way.
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
        // Rebuilding the jawari tables is the costly half (~3.4 ms); only
        // do it when a jawari key actually moved.
        let jtTouched = changed.contains { $0.hasPrefix("bow_jt") }
        return src.applyLiveParams(tonicHz: tonic, strings: strings,
                                   overrides: overrides,
                                   follower: follower,
                                   needsJawariTables: jtTouched)
    }

    /// Re-apply the String-editor / audition overrides with a rebuild (the
    /// artifact scalars are baked into the tables/kernel at build time).
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

    // MARK: - Tarab tuning → String voice

    /// Push the current tarab tuning (tonic + resolved sympathetic strings)
    /// to the String voice's in-kernel taraf. Called by `SarangiStore` on
    /// every structural change (raga/tonic/string edits, Tarab-tab sync). The
    /// String kernel's taraf tracks the same tuning as the tarab table; the
    /// build runs off-main (the mapper keeps held notes across the swap).
    ///
    /// The String voice reads only the tuning — its physics come from
    /// `bowed_string.json` + `stringVoiceOverrides`. This used to also take
    /// `params`/`fx`/`eqBands`/`groups`/`coupled` and ignore all five; they
    /// were dropped with the rest of the coupled-network remnants
    /// (2026-07-24), along with the `applySarangiScalars` /
    /// `applySarangiFXScalars` / `applySarangiFXFilters` no-op hooks.
    /// `droneFreqs` (2026-07-25) = per drone button, the mapped sympathetic
    /// string's nominal Hz (`InstrumentState.droneStringFreqs`; nil =
    /// unmapped/disabled → button inert).
    /// `follower` (2026-07-25) = the melody-follower string's (gain, t60)
    /// when enabled (`InstrumentState.resolvedFollower`; nil = off).
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
        // A slot unmapped while held must not stay latched: the fresh
        // engine starts silent and `reapplyHeldDrones` skips nil slots,
        // so drop the flag too (a later press starts clean).
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
