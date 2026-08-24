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
/// (from the Strings tab, pushed via `rebuildSarangi`) tunes the kernel's taraf;
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
    /// Test hook (@testable) — the render path's source, for asserting the
    /// touch layer drives the same mapper the render thread reads.
    var stringVoiceSourceForTesting: StringVoiceSource? { stringVoiceSource }
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
    private let stringBuildQueue = DispatchQueue(label: "tarabdaar.string.build",
                                                 qos: .userInitiated)
    private var stringBuildGen = 0

    // MARK: - Tanpura voice (r7 modal-contact plucked drone, 2026-08-04)

    /// Which voice the Fret Pad drone buttons drive. Default `.tanpura` —
    /// the ported tanpura plucks the mapped pitch (press = pluck, hold =
    /// periodic re-pluck, release = ring out); `.sympathetic` restores the
    /// legacy jt-row drive (swell while held).
    public enum DroneVoiceMode: String, CaseIterable, Sendable {
        case tanpura, sympathetic
    }
    /// Which voice the played (fret) notes drive. The String bowed voice is
    /// the default; `.tanpura` routes note-ons to tanpura plucks at the
    /// exact bent pitch (nearest mounted scale slot); `.sitar` (2026-08-19)
    /// does the same on the SITAR engine — the r7 modal-contact model
    /// retuned to sitar1.wav (`sitar_live.json`), whose rendered output
    /// also drives the sarangi jt taraf sympathetically (`st_taraf` →
    /// `bow_poly_jt_inject_*`): the sitar's taraf halo IS the String
    /// voice's tarab bank, tuned from the Strings tab.
    public enum MainInstrument: String, CaseIterable, Sendable {
        case string, tanpura, sitar
    }

    /// Second source on the graph (`node → symGain`), beside the String
    /// voice. Kept attached; engine (re)built off-main per tonic + scale.
    private var tanpuraSource: TanpuraVoiceSource?
    private var tanpuraAttached = false
    private var tanpuraConnected = false
    /// Guarded by `lock`.
    private var droneVoiceModeStorage: DroneVoiceMode = .tanpura
    private var mainInstrumentStorage: MainInstrument = .string
    /// Last structural scale push, retained for (re)builds. Guarded by `lock`.
    private var lastTanpuraTonic: Double = 261.63
    private var lastTanpuraRatios: [Double] = []
    /// Main-instrument plucks wait for the pitch bend that immediately
    /// follows the pad's note-on (the bend carries the exact fret pitch;
    /// the note number alone is only the nearest semitone). Guarded by
    /// `lock`; keyed by MPE channel.
    private var tanpuraPendingPluck: [UInt8: (note: UInt8, vel: UInt8)] = [:]
    /// The slot each ringing main-instrument note plucked (2026-08-05):
    /// while the channel's note holds, its MPE pitch bends live-retune
    /// this slot (the fret glide); note-off fast-releases it. Cleared on
    /// instrument switch and engine rebuild (slots change).
    private var tanpuraChannelSlot: [UInt8: Int] = [:]
    /// Touch-id twin of `tanpuraChannelSlot` for the TarabLink path (the
    /// wire carries touches, not MPE channels).
    private var tanpuraTouchSlot: [UInt16: Int] = [:]
    /// Per-button cancellation token for the hold re-pluck cycle. Guarded
    /// by `lock`; bumping a slot's generation orphans its timer chain.
    private var droneCycleGen = [Int](repeating: 0,
                                      count: FretArrangement.droneCount)
    /// Live tanpura trims (`tp_*` registry params). Guarded by `lock`
    /// except `tanpuraGainOverride` (main-thread config, applied at source
    /// creation; live path goes through `TanpuraVoiceSource.setOutGain`).
    private var tanpuraDroneLevel = 1.0
    private var tanpuraDroneCycleSec = 2.5
    private var tanpuraPluckLevel = 1.0
    private var tanpuraReleaseT60 = 0.4
    /// Pluck consistency + character (2026-08-15): `tp_pluck_touch`
    /// blends the string's pre-pluck state toward its settled wrap at each
    /// pluck (0 = legacy ride-the-ring, 1 = identical plucks);
    /// `tp_pluck_drive` drives the string that many times harder into the
    /// jawari at the calibrated radiated level (mellow↔buzzy). Read at
    /// pluck time and passed per pluck, so they need no re-apply after an
    /// engine rebuild. Guarded by `lock`.
    private var tanpuraPluckTouch = 0.0
    private var tanpuraPluckDrive = 1.0
    /// Tanpura→taraf drive (2026-08-21, `tp_taraf`): how strongly the
    /// tanpura's rendered output charges the sarangi jt web — the drone
    /// buttons ring the Strings-tab taraf as though the tanpura were
    /// part of the bowed instrument. Same inject ring as the sitar's
    /// halo, at its own per-source gain (`TanpuraVoiceSource
    /// .setInjectGain`); the kernel-side gain is just the shared arm
    /// (`updateJtInjectArm`). Guarded by `lock`; the 4.0 default must
    /// match the registry (`TanpuraVoiceTests`).
    private var tanpuraTarafDrive = 4.0
    /// String bank (2026-08-15, `tp_poly`): how many history strings —
    /// previous plucks, each a full jawari simulation at its own frozen
    /// pitch — stay alive before the oldest is evicted to the linear
    /// ghost tier. Applied live to the running engine AND passed to
    /// fresh builds. Guarded by `lock`; the 6 default must match the
    /// registry (`TanpuraVoiceTests`).
    private var tanpuraPoly = 6.0
    private var tanpuraGainOverride: Double?
    /// Scale-shaped overtones (2026-08-05, `tp_shape_*`). Registry-live
    /// like the trims above, but they parameterize the TABLE BUILD — an
    /// edit schedules a debounced full tanpura rebuild (seconds of CPU;
    /// the Parameters-tab drag must settle first, same reasoning as the
    /// scale pipeline's 750 ms). Guarded by `lock`.
    private var tanpuraShapeAlign = 0.0
    private var tanpuraShapeFocus = 0.0
    private var tanpuraShapeSpread = 0.0
    private var tanpuraShapeQuiet = 0.0
    /// Register calibration (2026-08-15, `tp_jiva_comp`): 1 = every slot's
    /// jiva thread height retargeted so the whole register keeps the
    /// low-Sa graze regime (level buzziness, laddered cascade); 0 = the
    /// fitted geometry. Table-build param like the shapes — edits ride the
    /// same debounced rebuild. Guarded by `lock`. The 1.0 default must
    /// match the registry (`TanpuraVoiceTests`).
    private var tanpuraJivaComp = 1.0
    /// Cascade slowing (2026-08-15, `tp_cascade`): pitch-graded thread
    /// lift + HF-sustain stretch that slows the higher slots' harmonic
    /// cascade toward low Sa's pace. Same rebuild discipline; the 1.0
    /// default must match the registry.
    private var tanpuraCascade = 1.0
    /// Pending debounced shape rebuild (main-thread mutate only).
    private var tanpuraShapeRebuildWork: DispatchWorkItem?

    // MARK: - Sitar voice (2026-08-19)

    /// Third source on the graph (`node → symGain`) — a second
    /// `TanpuraVoiceSource` mounted from the SITAR artifact. Armed
    /// lazily on the first switch to `.sitar` and kept armed (idle
    /// strings cost ~nothing; switch-back is instant). Its render tap
    /// feeds the String kernel's jt inject ring — the sympathetic halo.
    private var sitarSource: TanpuraVoiceSource?
    private var sitarAttached = false
    private var sitarConnected = false
    private var sitarBuildGen = 0
    /// Live sitar trims (`st_*` registry params). Guarded by `lock`
    /// except `sitarGainOverride` (same contract as the tanpura's).
    /// Defaults must match the registry (`SitarVoiceTests`).
    private var sitarPluckLevel = 1.0
    private var sitarReleaseT60 = 0.15
    private var sitarPluckTouch = 1.0
    private var sitarPluckDrive = 1.0
    private var sitarPoly = 4.0
    /// Sitar→taraf drive (`st_taraf`) — since 2026-08-21 a per-source
    /// gain on the sitar's inject tap (see `tanpuraTarafDrive`), so the
    /// tanpura's `tp_taraf` rides the same kernel ring independently.
    /// Guarded by `lock`; the 4.0 default must match the registry
    /// (`SitarVoiceTests`).
    private var sitarTarafDrive = 4.0
    private var sitarGainOverride: Double?

    /// The plucked-voice source a main instrument routes to (nil = the
    /// String voice — not a plucked engine). Callers hold `lock`.
    private func pluckSourceLocked(_ inst: MainInstrument) -> TanpuraVoiceSource? {
        switch inst {
        case .string: return nil
        case .tanpura: return tanpuraSource
        case .sitar: return sitarSource
        }
    }

    /// The per-instrument pluck trims (level / isolation / drive /
    /// release t60). Callers hold `lock`.
    private func pluckTrimsLocked(_ inst: MainInstrument)
        -> (level: Double, touch: Double, drive: Double, relT60: Double) {
        inst == .sitar
            ? (sitarPluckLevel, sitarPluckTouch, sitarPluckDrive, sitarReleaseT60)
            : (tanpuraPluckLevel, tanpuraPluckTouch, tanpuraPluckDrive, tanpuraReleaseT60)
    }
    /// The tanpura build is SECONDS of CPU (mount + settle every slot), so
    /// it gets its own serial queue below the String voice's priority.
    private let tanpuraBuildQueue = DispatchQueue(label: "tarabdaar.tanpura.build",
                                                  qos: .utility)
    private var tanpuraBuildGen = 0

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

    // Touch-keyed twins for the TarabLink path (full-resolution pitch, no
    // note+bend split). Wire play and in-process MIDI play never co-occur;
    // when any touch is held the readout prefers it. Guarded by `lock`.
    /// Fractional-MIDI pitch per live touch id.
    private var touchPitchSemis: [UInt16: Double] = [:]
    /// Still-held touches in play order, most-recent last.
    private var heldTouchOrder: [UInt16] = []

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
        // Request the IO buffer for play latency — transport-aware: the low
        // buffer on solid transports, the safe buffer on jitter-prone ones
        // (DisplayPort/HDMI/Bluetooth/AirPlay). macOS has no per-app IO
        // buffer (no AVAudioSession) — this is the output device's HAL buffer,
        // clamped to its allowed range. Tunable live via `setOutputBufferFrames`.
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
        // The IO buffer is a per-device property — re-apply to the new device
        // (transport-aware: jitter-prone transports take the safe buffer).
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

    /// The IO buffer this output device should run. Solid transports
    /// (built-in, USB, Thunderbolt, …) take the low play-latency buffer;
    /// jitter-prone ones — monitor audio over the video link
    /// (DisplayPort/HDMI: packetized, clock recovered monitor-side),
    /// Bluetooth, AirPlay — cannot sustain its ~3 ms callback cadence and
    /// crackle on EVERY voice (the misses are in the shared device
    /// callback, not any one DSP path), so they take the safe buffer.
    /// Measured 2026-08-17: AORUS FO32U2P over DisplayPort crackled at
    /// 128 frames; the headphone DAC was clean with the identical render.
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
            NSLog("Tarabdaar: output device lacks \(Int(target)) Hz — leaving at \(Int(current)) Hz (resampler stays)")
            return
        }
        if changedDeviceRate == nil { changedDeviceRate = (dev, current) }
        let ok = setDeviceNominalSampleRate(dev, target)
        NSLog("Tarabdaar: output device rate \(Int(current)) → \(Int(target)) Hz: \(ok ? "OK (no resampler)" : "FAILED")")
    }

    /// Restore any output device whose rate we changed back to its original.
    /// Wire to a clean-quit hook (`NSApplication.willTerminateNotification`) so
    /// the user's device is not left at 44.1 kHz after Tarabdaar exits.
    public func restoreOutputDeviceRate() {
        guard let prev = changedDeviceRate else { return }
        setDeviceNominalSampleRate(prev.device, prev.originalRate)
        NSLog("Tarabdaar: restored output device rate → \(Int(prev.originalRate)) Hz")
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
        NSLog("Tarabdaar: \(msg)")
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
        // TarabLink touches first: exact pitch, no bend math. (Expression
        // reads 0 here, matching the old iPad wire — the iPad never sent
        // CC11; the axis idles at the fitted median inside the mapper.)
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

    // MARK: - TarabLink touch ingestion (the wire path)
    //
    // The protocol twins of `sendHostedMIDI` — full-resolution fractional-
    // MIDI pitch keyed by iPad touch id, no MIDI vocabulary. `sendHostedMIDI`
    // stays for the in-process paths (Mac keyboard, auditions, external
    // hardware). All entry points are thread-safe (called on the link
    // receive queue, which plays the CoreMIDI thread's old role).

    /// Touch onset. In tanpura main-instrument mode the pluck fires HERE,
    /// immediately, at the exact bent pitch — onset and pitch arrive in one
    /// frame, so the MIDI path's pending-pluck-on-next-bend contraption has
    /// no wire-path equivalent. `posY` (fret-band y, 0…1) feeds the String
    /// voice's fret-linger / auto-vibrato; the tanpura pluck ignores it
    /// (a pluck decays on its own), and nil keeps the legacy behavior.
    public func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double,
                        posY: Double? = nil, fretY: Double? = nil) {
        lock.lock()
        touchPitchSemis[id] = pitchSemis
        heldTouchOrder.removeAll { $0 == id }
        heldTouchOrder.append(id)
        let inst = mainInstrumentStorage
        let src = stringVoiceSource
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if inst != .string {
            let hz = 440.0 * pow(2.0, (pitchSemis - 69.0) / 12.0)
            pluckMainTouch(inst, hz: hz, velocity: velocity, touch: id)
            return
        }
        src?.mapper.touchOn(id, pitchSemis: pitchSemis, velocity: velocity,
                            posY: posY, fretY: fretY)
    }

    /// Pitch/position update for a live touch (post-onset glide, or a
    /// vertical move along a fret). String voice: the mapper's 9 Hz meend
    /// smoother carries the pitch motion, the y travel recharges the linger
    /// envelopes. Tanpura: live-retune the ringing string kernel-side,
    /// exactly as the MIDI bend path did (y is ignored).
    public func touchGlide(_ id: UInt16, pitchSemis: Double,
                           posY: Double? = nil, fretY: Double? = nil) {
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
        src?.mapper.touchGlide(id, pitchSemis: pitchSemis, posY: posY,
                               fretY: fretY)
    }

    /// Touch release. String voice: bow lift (the string rings). Tanpura:
    /// fast-release the slot (`tp_rel_t60`). A stale tanpura slot is
    /// released even after a mode switch back to the String voice.
    public func touchOff(_ id: UInt16) {
        lock.lock()
        touchPitchSemis.removeValue(forKey: id)
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

    /// The link-drop kill path: every bow off, every tanpura touch slot
    /// released, every drone button up. Called on disconnect or staleness —
    /// the wire's stuck-note safety net.
    public func touchesAllOff() {
        lock.lock()
        touchPitchSemis.removeAll(keepingCapacity: true)
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

    /// The performance-expression axis (the old flat CC11): the Mac pads
    /// hold the fitted median here since they have no tilt source. Sets
    /// the long-lived mapper axis directly (survives engine rebuilds).
    public func setPerformanceExpression(_ v01: Double) {
        stringVoiceSource?.mapper.setAxis(expr: v01)
    }

    /// The String voice's per-touch linger envelope state (expression
    /// charge, auto-vib depth + ceiling), keyed by wire touch id — the
    /// display feed AppController paces onto the LINGER_STATE frame so
    /// the iPad's overlay shows what is actually being evaluated. Empty
    /// while the tanpura is the main instrument (its plucks don't linger).
    public func lingerDisplay() -> [BowEngine.LingerTouchState] {
        lock.lock()
        let src = stringVoiceSource
        lock.unlock()
        return src?.currentEngine()?.lingerDisplay() ?? []
    }

    /// Touch-keyed twin of `pluckMain` — the plucked main instruments'
    /// (tanpura / sitar) wire-path onset.
    private func pluckMainTouch(_ inst: MainInstrument, hz: Double,
                                velocity: Double, touch id: UInt16) {
        lock.lock()
        let (level, fingerTouch, drive, _) = pluckTrimsLocked(inst)
        let src = pluckSourceLocked(inst)
        lock.unlock()
        guard let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 60)
        else { return }
        let vel = Int((velocity * 127.0).rounded())
        engine.pluck(slot: slot, velocity: min(max(vel, 0), 127), scale: level,
                     bendRatio: hz / engine.slotFrequencies[slot],
                     touch: fingerTouch, drive: drive)
        lock.lock()
        tanpuraTouchSlot[id] = slot
        lock.unlock()
    }

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
        // MAIN-INSTRUMENT gate (2026-08-04): when the tanpura is the played
        // voice, a note-on becomes a pluck at the note's EXACT sounding
        // pitch — which arrives one message later, on the pitch bend the
        // pad always sends right after the note-on (the note number alone
        // is only the nearest semitone). The pending pluck fires on that
        // bend, or on CC11 as the fallback for senders that skip the bend.
        // 2026-08-05: the note then PLAYS like the String voice — glides
        // after the pluck live-retune the ringing string (per-channel MPE
        // bend -> `TanpuraEngine.bend`), and note-off fast-releases it
        // (`tp_rel_t60` — held strings decay at their natural rate, a
        // released string much faster). The String mapper sees no note
        // messages in this mode.
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
        // RAW TILT REPORT (2026-07-24): the controller streams its three
        // raw tilt values on the fixed axis messages (`TiltAxisWire`) —
        // it knows nothing about parameters or mappings. Forwarded to
        // the host (AppController), which evaluates its own tilt
        // bindings. Called on the MIDI thread; handler thread-safe.
        // 14-BIT (2026-08-14): MSB/LSB CC pairs, sent MSB-then-LSB.
        // Emit on the LSB (combining with the stored MSB) so the pair
        // lands atomically — emitting on the MSB too would interleave
        // coarse values between fine ones and reintroduce the very
        // quantization steps the pair removes. A stream that has never
        // carried an LSB is a legacy 7-bit iPad build: emit on MSB.
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
        // COMPOSITE PARAMETER slots (2026-07-24): direct slot-CC drives
        // (audition scores / external hardware; the iPad no longer sends
        // these). The mapper ignores these CCs.
        if statusHi == 0xB0, CompositeParam.slotCCs.contains(data1) {
            onCompositeCC?(data1, Double(data2) / 127.0)
        }
        // Note messages reach the String mapper only when the String voice
        // is the played instrument; axes/CCs flow either way (they drive
        // nothing without notes, and keep the mapper's state current for a
        // switch back).
        if inst != .string, statusHi == 0x90 || statusHi == 0x80 { return }
        mapper?.midi(statusHi | channel, data1, data2)
    }

    /// Raw-tilt delivery (2026-07-24): fired with (axis 0…2, value
    /// −1…+1, rest 0 — the CC transport's 0…16383 is unsigned, the
    /// software value is not) for each incoming tilt-axis message — on
    /// the MIDI thread; the handler must be thread-safe.
    public var onTiltAxis: ((Int, Double) -> Void)?
    /// 14-bit tilt-pair assembly (2026-08-14): latest MSB per axis, and
    /// whether the stream has EVER carried an LSB (false = legacy 7-bit
    /// iPad build, decode MSB-only). MIDI-thread only.
    private var tiltMSB = [UInt8](repeating: 0, count: 3)
    private var tiltLSBSeen = false

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
                NSLog("Tarabdaar: bowed_string.json missing from the SarangiKit bundle")
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

    // MARK: - Tanpura voice bridge

    /// Enable the tanpura source. On first enable the node is created and
    /// connected to `symGain` (beside the String node — the mixer sums), and
    /// the engine is built off-main from the current tonic + scale. Returns
    /// false when `tanpura_live.json` is missing. Armed once at startup and
    /// stays on — it is the default drone voice.
    @discardableResult
    public func setTanpuraVoiceEnabled(_ on: Bool) -> Bool {
        if on && tanpuraSource == nil {
            guard Presets.tanpuraParams() != nil else {
                NSLog("Tarabdaar: tanpura_live.json missing from the SarangiKit bundle")
                return false
            }
            let src = TanpuraVoiceSource()
            if let g = tanpuraGainOverride { src.setOutGain(g) }
            // tanpura→taraf tap (2026-08-21): the drone plucks charge
            // the sarangi jt web sympathetically, `tp_taraf`-scaled —
            // the String voice exists by now (enabled first at startup)
            if let strSrc = stringVoiceSource {
                src.setInjectSink { strSrc.jtInjectWrite($0, $1) }
            }
            lock.lock()
            let drive = tanpuraTarafDrive
            lock.unlock()
            src.setInjectGain(drive)
            tanpuraSource = src
            updateJtInjectArm()
        }
        if let src = tanpuraSource, on != tanpuraConnected {
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            if on {
                if !tanpuraAttached {
                    engine.attach(src.node)
                    tanpuraAttached = true
                }
                let fmt = AVAudioFormat(standardFormatWithSampleRate: src.modelSR, channels: 2)!
                engine.connect(src.node, to: symGain, format: fmt)
            } else {
                engine.disconnectNodeOutput(src.node)
            }
            tanpuraConnected = on
            if wasRunning {
                do { try engine.start() } catch {
                    print("AudioEngine restart after tanpura switch failed: \(error)")
                    isRunning = false
                }
            }
        }
        lock.lock()
        let tonic = lastTanpuraTonic
        let ratios = lastTanpuraRatios
        lock.unlock()
        if on, !ratios.isEmpty { rebuildTanpura(tonic: tonic, scaleRatios: ratios) }
        return true
    }

    /// True once a tanpura engine is mounted and renderable.
    public var isTanpuraArmed: Bool { tanpuraSource?.isArmed ?? false }

    /// Tanpura async-pool telemetry (underruns / divergence resets / ringing
    /// strings). nil while unarmed.
    public func tanpuraStats() -> (underruns: Int, resets: Int, active: Int)? {
        guard let e = tanpuraSource?.currentEngine() else { return nil }
        return (e.underruns, e.resetCount, e.activeStrings)
    }

    /// (Re)build the tanpura's JI slot grid for a tonic + scale, off-main
    /// (the mount+settle pass is ~seconds of CPU — far heavier than a
    /// String rebuild, hence the utility-QoS queue and the caller-side
    /// debounce). A newer build supersedes any in-flight older one; held
    /// drone buttons re-pluck onto the fresh engine across the crossfade.
    public func rebuildTanpura(tonic: Double, scaleRatios: [Double]) {
        lock.lock()
        lastTanpuraTonic = tonic
        lastTanpuraRatios = scaleRatios
        let src = tanpuraSource
        let shapeAlign = tanpuraShapeAlign
        let shapeFocus = tanpuraShapeFocus
        let shapeSpread = tanpuraShapeSpread
        let shapeQuiet = tanpuraShapeQuiet
        let jivaComp = tanpuraJivaComp
        let cascade = tanpuraCascade
        let poly = Int(tanpuraPoly.rounded())
        lock.unlock()
        guard src != nil else { return }
        tanpuraBuildGen += 1
        let gen = tanpuraBuildGen
        tanpuraBuildQueue.async { [weak self] in
            let engine = TanpuraVoiceSource.buildEngine(tonicHz: tonic,
                                                       scaleRatios: scaleRatios,
                                                       shapeAlign: shapeAlign,
                                                       shapeFocus: shapeFocus,
                                                       shapeSpread: shapeSpread,
                                                       shapeQuiet: shapeQuiet,
                                                       registerComp: jivaComp,
                                                       cascade: cascade,
                                                       polyphony: poly)
            DispatchQueue.main.async {
                guard let self, gen == self.tanpuraBuildGen else { return }
                if engine == nil {
                    NSLog("Tarabdaar: tanpura engine build failed (tanpura_live.json missing?)")
                }
                self.tanpuraSource?.setEngine(engine)
                // held main-instrument notes lose their slot binding — the
                // fresh engine's slots differ; the next note-on rebinds
                self.lock.lock()
                self.tanpuraChannelSlot.removeAll(keepingCapacity: true)
                self.tanpuraTouchSlot.removeAll(keepingCapacity: true)
                self.lock.unlock()
                self.reapplyHeldTanpuraDrones()
            }
        }
    }

    /// Enable the SITAR voice (2026-08-19). Mirrors the tanpura path: a
    /// third source node connected to `symGain`, engine built off-main on
    /// the same utility queue from the current tonic + scale, but from the
    /// SITAR artifact — and its render tap is wired into the String
    /// kernel's jt inject ring, so whatever the sitar radiates charges
    /// the sarangi taraf sympathetically (`st_taraf` scales it; the
    /// String voice stays armed and silent under sitar play, exactly as
    /// under tanpura play, so the web is always there to ring).
    /// Returns false when `sitar_live.json` is missing.
    @discardableResult
    public func setSitarVoiceEnabled(_ on: Bool) -> Bool {
        if on && sitarSource == nil {
            guard Presets.sitarParams() != nil else {
                NSLog("Tarabdaar: sitar_live.json missing from the SarangiKit bundle")
                return false
            }
            let src = TanpuraVoiceSource()
            if let g = sitarGainOverride { src.setOutGain(g) }
            if let strSrc = stringVoiceSource {
                src.setInjectSink { strSrc.jtInjectWrite($0, $1) }
            }
            lock.lock()
            let drive = sitarTarafDrive
            lock.unlock()
            src.setInjectGain(drive)
            sitarSource = src
            updateJtInjectArm()
        }
        if let src = sitarSource, on != sitarConnected {
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            if on {
                if !sitarAttached {
                    engine.attach(src.node)
                    sitarAttached = true
                }
                let fmt = AVAudioFormat(standardFormatWithSampleRate: src.modelSR, channels: 2)!
                engine.connect(src.node, to: symGain, format: fmt)
            } else {
                engine.disconnectNodeOutput(src.node)
            }
            sitarConnected = on
            if wasRunning {
                do { try engine.start() } catch {
                    print("AudioEngine restart after sitar switch failed: \(error)")
                    isRunning = false
                }
            }
        }
        lock.lock()
        let tonic = lastTanpuraTonic
        let ratios = lastTanpuraRatios
        lock.unlock()
        if on, !ratios.isEmpty { rebuildSitar(tonic: tonic, scaleRatios: ratios) }
        return true
    }

    /// True once a sitar engine is mounted and renderable.
    public var isSitarArmed: Bool { sitarSource?.isArmed ?? false }

    /// (Re)build the sitar's JI slot grid — same discipline as
    /// `rebuildTanpura` (off-main on the shared utility queue, newer build
    /// supersedes, held notes lose their slot binding). No shaping /
    /// register-comp layers: the sitar artifact is its own fit.
    public func rebuildSitar(tonic: Double, scaleRatios: [Double]) {
        lock.lock()
        let src = sitarSource
        let poly = Int(sitarPoly.rounded())
        lock.unlock()
        guard src != nil else { return }
        sitarBuildGen += 1
        let gen = sitarBuildGen
        tanpuraBuildQueue.async { [weak self] in
            let engine = TanpuraVoiceSource.buildEngine(tonicHz: tonic,
                                                        scaleRatios: scaleRatios,
                                                        artifact: .sitar,
                                                        polyphony: poly)
            DispatchQueue.main.async {
                guard let self, gen == self.sitarBuildGen else { return }
                if engine == nil {
                    NSLog("Tarabdaar: sitar engine build failed (sitar_live.json missing?)")
                }
                self.sitarSource?.setEngine(engine)
                self.lock.lock()
                if self.mainInstrumentStorage == .sitar {
                    self.tanpuraChannelSlot.removeAll(keepingCapacity: true)
                    self.tanpuraTouchSlot.removeAll(keepingCapacity: true)
                }
                self.lock.unlock()
            }
        }
    }

    /// Apply one `st_*` live registry parameter. Same contract as
    /// `setTanpuraParam`.
    @discardableResult
    public func setSitarParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        case "st_gain":
            sitarGainOverride = value
            sitarSource?.setOutGain(value)
        case "st_pluck_level":
            lock.lock(); sitarPluckLevel = value; lock.unlock()
        case "st_rel_t60":
            lock.lock(); sitarReleaseT60 = value; lock.unlock()
        case "st_pluck_touch":
            lock.lock(); sitarPluckTouch = value; lock.unlock()
        case "st_pluck_drive":
            lock.lock(); sitarPluckDrive = value; lock.unlock()
        case "st_poly":
            lock.lock()
            sitarPoly = value
            let src = sitarSource
            lock.unlock()
            src?.currentEngine()?.setPolyphony(Int(value.rounded()))
        case "st_taraf":
            // sympathetic-coupling drive, scaled per-source at the
            // sitar's inject tap (2026-08-21 — the tanpura's `tp_taraf`
            // shares the kernel ring); the String-side kernel gain is
            // the shared arm, republished across bow rebuilds
            lock.lock()
            sitarTarafDrive = value
            let src = sitarSource
            lock.unlock()
            src?.setInjectGain(value)
            updateJtInjectArm()
        default:
            return false
        }
        return true
    }

    /// (Re)publish the String kernel's inject-ring arm: 1.0 while ANY
    /// foreign voice drives the taraf (`st_taraf` / `tp_taraf` above 0),
    /// else 0. The per-source drives scale at the taps, so the kernel
    /// gain carries no level of its own; `StringVoiceSource` caches the
    /// arm across bow rebuilds. Both-zero keeps the ring unwritten —
    /// the byte-null String parity path.
    private func updateJtInjectArm() {
        lock.lock()
        let armed = sitarTarafDrive > 0 || tanpuraTarafDrive > 0
        lock.unlock()
        stringVoiceSource?.setJtInjectGain(armed ? 1.0 : 0.0)
    }

    /// Which voice the drone buttons drive. Switching releases everything:
    /// held jt rows get their release envelope, ringing tanpura strings are
    /// damped, hold-cycles cancel — the buttons start clean in the new mode.
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
        let tpSrc = tanpuraSource
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

    /// Which voice the played notes drive. Switching away from the String
    /// voice releases its held notes; switching away from the tanpura just
    /// drops pending plucks (its strings ring out — their nature).
    public func setMainInstrument(_ inst: MainInstrument) {
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
        // the sitar arms lazily on first use and stays armed (idle
        // strings are ~free; switching back is instant)
        if inst == .sitar { setSitarVoiceEnabled(true) }
    }

    public var mainInstrument: MainInstrument {
        lock.lock(); defer { lock.unlock() }
        return mainInstrumentStorage
    }

    /// Apply one `tp_*` live registry parameter. Same contract as
    /// `setStringControlParam` — thread-safe, persists across rebuilds.
    @discardableResult
    public func setTanpuraParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        case "tp_gain":
            tanpuraGainOverride = value
            tanpuraSource?.setOutGain(value)
        case "tp_drone_level":
            lock.lock(); tanpuraDroneLevel = value; lock.unlock()
        case "tp_drone_cycle":
            lock.lock(); tanpuraDroneCycleSec = value; lock.unlock()
        case "tp_pluck_level":
            lock.lock(); tanpuraPluckLevel = value; lock.unlock()
        case "tp_rel_t60":
            lock.lock(); tanpuraReleaseT60 = value; lock.unlock()
        case "tp_pluck_touch":
            lock.lock(); tanpuraPluckTouch = value; lock.unlock()
        case "tp_pluck_drive":
            lock.lock(); tanpuraPluckDrive = value; lock.unlock()
        case "tp_taraf":
            lock.lock()
            tanpuraTarafDrive = value
            let src = tanpuraSource
            lock.unlock()
            src?.setInjectGain(value)
            updateJtInjectArm()
        case "tp_poly":
            lock.lock()
            tanpuraPoly = value
            let src = tanpuraSource
            lock.unlock()
            src?.currentEngine()?.setPolyphony(Int(value.rounded()))
        case "tp_jiva_comp":
            lock.lock()
            let old = tanpuraJivaComp
            tanpuraJivaComp = value
            lock.unlock()
            // same discipline as the shapes: only a real change burns a
            // seconds-long rebuild (the startup default push is a no-op)
            if value != old { scheduleTanpuraShapeRebuild() }
        case "tp_cascade":
            lock.lock()
            let oldC = tanpuraCascade
            tanpuraCascade = value
            lock.unlock()
            if value != oldC { scheduleTanpuraShapeRebuild() }
        case "tp_shape_align", "tp_shape_focus", "tp_shape_spread",
             "tp_shape_quiet":
            lock.lock()
            let wasActive = tanpuraShapeAlign > 0 || tanpuraShapeFocus > 0
                || tanpuraShapeQuiet > 0
            let old: Double
            switch key {
            case "tp_shape_align":
                old = tanpuraShapeAlign; tanpuraShapeAlign = value
            case "tp_shape_focus":
                old = tanpuraShapeFocus; tanpuraShapeFocus = value
            case "tp_shape_quiet":
                old = tanpuraShapeQuiet; tanpuraShapeQuiet = value
            default:
                old = tanpuraShapeSpread; tanpuraShapeSpread = value
            }
            let isActive = tanpuraShapeAlign > 0 || tanpuraShapeFocus > 0
                || tanpuraShapeQuiet > 0
            lock.unlock()
            // the engine only changes when a value moved AND shaping is
            // (or was) actually in effect — spread alone is inert, and
            // the startup default push must not burn a seconds-long build
            if value != old, wasActive || isActive {
                scheduleTanpuraShapeRebuild()
            }
        default:
            return false
        }
        return true
    }

    /// Debounced rebuild for a `tp_shape_*` edit: the tanpura build is
    /// seconds of CPU, so a Parameters-tab slider drag must settle
    /// (750 ms, the scale pipeline's constant) before one build runs.
    /// The build-generation guard then supersedes any in-flight older
    /// build as usual.
    private func scheduleTanpuraShapeRebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tanpuraShapeRebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let tonic = self.lastTanpuraTonic
                let ratios = self.lastTanpuraRatios
                self.lock.unlock()
                guard !ratios.isEmpty else { return }
                self.rebuildTanpura(tonic: tonic, scaleRatios: ratios)
            }
            self.tanpuraShapeRebuildWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75,
                                          execute: work)
        }
    }

    /// One drone-button tanpura pluck: the mapped pitch's nearest mounted
    /// slot (the grid carries every scale pitch, so this is exact up to the
    /// mHz quantization; 50 ¢ tolerance guards a mid-rebuild mismatch).
    private func tanpuraPluckDrone(_ index: Int) {
        lock.lock()
        let hz = droneFreqs.indices.contains(index) ? droneFreqs[index] : nil
        let level = tanpuraDroneLevel
        let touch = tanpuraPluckTouch
        let drive = tanpuraPluckDrive
        let src = tanpuraSource
        lock.unlock()
        guard let hz, let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 50)
        else { return }
        engine.pluck(slot: slot, velocity: 100, scale: level,
                     touch: touch, drive: drive)
    }

    /// Hold re-pluck cycle (the strumming hand): while button `index` stays
    /// held in tanpura mode, re-pluck every `tp_drone_cycle` seconds. The
    /// period is re-read each hop so a live edit applies mid-hold; a bumped
    /// generation (release / remap / mode switch) orphans the chain.
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

    /// Re-strike held drone buttons on a freshly-built tanpura (a rebuild
    /// crossfades the old ring out; the fresh engine starts silent).
    private func reapplyHeldTanpuraDrones() {
        lock.lock()
        let held = droneHeld.indices.filter {
            droneHeld[$0] && droneVoiceModeStorage == .tanpura
        }
        lock.unlock()
        for i in held { tanpuraPluckDrone(i) }
    }

    /// A main-instrument tanpura pluck at an exact sounding pitch: the
    /// nearest mounted slot (60 ¢ tolerance — a fret pitch always has a
    /// slot) BENT to the exact Hz (2026-08-05 — the pluck itself is now
    /// pitch-exact, not slot-quantized). The slot is recorded per channel
    /// so later MPE bends retune it and note-off fast-releases it.
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
    public func setStringJtGov(_ amt01: Double) {
        stringVoiceSource?.setJtGov(amt01)
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
    public func setStringTwang(_ amt01: Double) {
        stringVoiceSource?.setTwang(amt01)
    }

    /// String-voice jawari-web overload telemetry (see
    /// `StringVoiceSource.jtStats`). nil when the voice isn't created.
    public func stringVoiceJtStats() -> (drops: Double, flat: Double,
                                         fill: Double, on: Double)? {
        stringVoiceSource?.jtStats()
    }

    /// String-voice quiescence-gate probe (see
    /// `StringVoiceSource.jtGateProbe`). nil when the voice isn't created.
    public func stringVoiceJtGateProbe() -> (asleep: Int, total: Int,
                                             ringR: Double, driveR: Double,
                                             droneHot: Bool)? {
        stringVoiceSource?.jtGateProbe()
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
        case "bow_jt_gov":    setStringJtGov(value)
        case "bow_jt_damp":   setStringTarafDamp(value)
        case "bow_gain":      stringVoiceSource?.setMasterGain(value)
        case "bow_jt_sel":    setStringTarafSelectivity(value)
        case "bow_jt_evolve": setStringJtEvolve(value)
        case "bow_twang":     setStringTwang(value)
        case "bow_tone_tilt": setStringToneTilt(value)
        default:
            // FX rack (2026-08-01): every `fx_<point>_<field>` key routes
            // to the source's cached settings (re-applied across rebuilds).
            if key.hasPrefix("fx_") {
                return stringVoiceSource?.setFXParam(key, value) ?? false
            }
            // Tanpura voice (2026-08-04): the `tp_*` group.
            if key.hasPrefix("tp_") {
                return setTanpuraParam(key, value)
            }
            // Sitar voice (2026-08-19): the `st_*` group.
            if key.hasPrefix("st_") {
                return setSitarParam(key, value)
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

    /// Press/release drone button `index` (0–2). In the default tanpura
    /// mode a press PLUCKS the mapped pitch (and starts the hold re-pluck
    /// cycle); release stops the cycle and lets the string ring out. In
    /// `.sympathetic` mode: pluck-and-hold / release the mapped string's jt
    /// row (identity lookup on its nominal Hz; string not in the web =
    /// inert). Unmapped slot = inert either way. Safe from the MIDI thread.
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
        // Frequencies of the OTHER still-held buttons — a release must not
        // silence a row another button also maps to.
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
                    NSLog("Tarabdaar: String engine build failed (bowed_string.json missing?)")
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

    // MARK: - Tarab tuning (Strings tab) → String voice

    /// Push the current tarab tuning (tonic + resolved sympathetic strings)
    /// to the String voice's in-kernel taraf. Called by `SarangiStore` on
    /// every structural change (raga/tonic/string edits, Strings-tab sync). The
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
