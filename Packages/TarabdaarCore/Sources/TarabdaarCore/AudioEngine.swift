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
/// Touches arrive on the TLP path (via the glide queue) — there is no MIDI
/// note vocabulary. Public methods take `lock` for state and release it
/// before calling into an engine.
public class AudioEngine: ObservableObject {
    let engine = AVAudioEngine()
    /// Summing stage for the three source nodes, pinned at unity.
    let symGain = AVAudioMixerNode()
    let lock = NSLock()

    // MARK: - String voice source

    /// The String voice (native 48 kHz; the mixer input converts). Kept
    /// attached; connected on enable.
    var stringVoiceSource: StringVoiceSource?
    /// Test hook: the render path's source.
    var stringVoiceSourceForTesting: StringVoiceSource? { stringVoiceSource }
    var stringVoiceAttached = false
    var stringVoiceConnected = false
    /// Guarded by `lock`. Armed once at startup and stays on.
    var useSarangiModelVoice = false
    /// Last structural tarab push, retained for (re)builds.
    var lastSarangiStrings: [ResolvedString] = []
    var lastSarangiTonic: Double = 261.63
    /// The melody-follower string: (gain, t60) when enabled, nil when off.
    var lastSarangiFollower: (gain: Double, t60: Double)?
    /// Scalar overrides applied over `bowed_string.json` at every build.
    public var stringVoiceOverrides: [String: Double] = [:]
    /// Drone buttons: each plucks ONE mapped sympathetic string, found by
    /// identity on its nominal Hz (`droneFreqs`; nil = unmapped → inert).
    /// Guarded by `lock` with `droneHeld` (presses arrive on the MIDI thread).
    var droneChromatic = [Bool?](repeating: nil, count: InstrumentState.droneSlotCount)
    var droneFreqs = [Double?](repeating: nil,
                               count: FretArrangement.droneCount)
    var droneHeld = [Bool](repeating: false,
                           count: FretArrangement.droneCount)
    /// Serial off-main build queue for the String engine; `stringBuildGen`
    /// discards builds superseded while in flight.
    let stringBuildQueue = DispatchQueue(label: "tarabdaar.string.build",
                                         qos: .userInitiated)
    var stringBuildGen = 0
    @Published public internal(set) var tarafBank = TarafBank.empty

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
    let tanpuraVoice = PluckedVoice.tanpura()
    let sitarVoice = PluckedVoice.sitar()

    /// Guarded by `lock`.
    var droneVoiceModeStorage: DroneVoiceMode = .tanpura
    var mainInstrumentStorage: MainInstrument = .string
    /// Last structural scale push, retained for BOTH plucked (re)builds. Guarded by `lock`.
    var lastTanpuraTonic: Double = 261.63
    var lastTanpuraRatios: [Double] = []
    /// Per-button generation token for the hold re-pluck cycle. Guarded by `lock`.
    var droneCycleGen = [Int](repeating: 0,
                              count: FretArrangement.droneCount)
    /// The drone-button trims (`tp_drone_*`) — tanpura-only, so they stay
    /// here rather than on `PluckedVoice`. Guarded by `lock`.
    var tanpuraDroneLevel = 1.0
    var tanpuraDroneCycleSec = 2.5
    /// Session register: drones start an octave below their mapped strings.
    /// Guarded by `lock`; the controller's Up button restores the mapped octave.
    var tanpuraDroneOctaveRaised = false
    /// Pending debounced table rebuild (main-thread mutate only).
    let tanpuraTableRebuild = Debouncer(delay: 0.75)

    /// A plucked build is seconds of CPU — one shared utility-QoS serial queue.
    let tanpuraBuildQueue = DispatchQueue(label: "tarabdaar.tanpura.build",
                                          qos: .utility)

    @Published public var isRunning = false

    // MARK: - Live-tab readout bookkeeping

    // Touch-keyed, full-resolution pitch (the TLP path). Guarded by `lock`.
    /// Fractional-MIDI pitch per live touch id.
    var touchPitchSemis: [UInt16: Double] = [:]
    /// Still-held touches in play order, most-recent last.
    var heldTouchOrder: [UInt16] = []
    var performanceProfile = PerformancePitchProfile()
    private var profileExcludedTouches = Set<UInt16>()
    /// Per-touch expression scale (the strum chord; absent = 1). Delivered
    /// by `touchExpr` ahead of the onset; String: the mapper's per-slot
    /// scale, live while held; plucked mains: the pluck level at onset.
    private var touchExprScale: [UInt16: Double] = [:]
    /// The pitch accent (`ctl_fret_accent`): the fret grid it reads and
    /// its amount. The per-touch expression scale handed to the voice is
    /// the strum scale × the accent at the touch's pitch. Guarded by `lock`.
    var fretPitchGrid = FretPitchGrid(tonicHz: 261.63, ratios: [])
    var pitchAccentAmount: Double = 0

    /// Guards the readout scalars below; separate from `lock` so the Live
    /// tab's poll never contends with it. Never held while `lock` is held.
    let meterLock = NSLock()
    var meterPitchHz: Double = 0
    var meterExpr: Double = 0
    var meterActive: Bool = false

    // MARK: - Profiling

    public private(set) var lastRenderTime: Double = 0
    public private(set) var maxRenderTime: Double = 0
    public private(set) var lastRenderFrames: Int = 0

    // MARK: - Setup

    /// The glide queue the public touch API funnels through: with
    /// `ctl_glide_on` armed, an overlapping onset is queued as a glissando
    /// waypoint instead of mounting a note. Pass-through at the default 0.
    public let glideQueue = GlideSequencer()

    public init() {
        setupAudio()
        glideQueue.onTouchOn = { [weak self] id, pitch in
            self?.touchOnDirect(id, pitchSemis: pitch)
        }
        glideQueue.onTouchGlide = { [weak self] id, pitch in
            self?.touchGlideDirect(id, pitchSemis: pitch)
        }
        glideQueue.onTouchResume = { [weak self] id, pitch in
            self?.touchResumeDirect(id, pitchSemis: pitch)
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


    #if os(macOS)
    /// The device whose nominal rate we changed, plus its original rate (nil = none).
    var changedDeviceRate: (device: AudioDeviceID, originalRate: Double)?
    #endif

    // MARK: - Recording (post-FX tap on the main mixer)

    let recordingLock = NSLock()
    // The tap fills a pre-allocated interleaved Int16 buffer (no audio-thread
    // allocation); one complete WAV with our own header is written at stop.
    // Never AVAudioFile here: its incremental write drops the unflushed tail.
    var recBuf: [Int16] = []      // interleaved L,R; reused across runs
    var recCount: Int = 0         // valid interleaved Int16 count
    var recURL: URL?
    var recActive = false
    var recOverflow = false       // ran out of pre-allocated capacity

    var recCountFinal: Int = 0    // recCount snapshot at last stop

    /// True when a recording is in progress. Updated on the main thread.
    @Published public var isRecording: Bool = false
    /// File URL of the most recently completed (or in-progress) recording.
    @Published public var lastRecordingURL: URL?

    // MARK: - TarabLink touch ingestion (the wire path)
    //
    // Fractional-MIDI pitch keyed by touch id. Thread-safe (link receive queue).

    /// Touch onset, through the glide queue: a fresh note via
    /// `touchOnDirect`, or a queued glissando waypoint.
    public func touchOn(_ id: UInt16, pitchSemis: Double) {
        glideQueue.touchOn(id, pitchSemis: pitchSemis)
    }

    /// The glide queue's exemption mark (the strum chord), delivered before `touchOn`.
    public func touchGlideExempt(_ id: UInt16) {
        lock.lock()
        profileExcludedTouches.insert(id)
        lock.unlock()
        glideQueue.markExempt(id)
    }

    /// Pitch update, through the glide queue: a drag on a queued waypoint
    /// retargets it; the owning touch's drag meends the voice directly.
    public func touchGlide(_ id: UInt16, pitchSemis: Double) {
        glideQueue.touchGlide(id, pitchSemis: pitchSemis)
    }

    /// Touch release, immediately through the glide queue: a chain
    /// member's release is resolved by the sequencer, others forward directly.
    public func touchOff(_ id: UInt16) {
        glideQueue.touchOff(id)
    }

    /// Touch onset, the DIRECT path. A plucked main instrument plucks HERE
    /// at the exact pitch (onset and pitch arrive together).
    private func touchOnDirect(_ id: UInt16, pitchSemis: Double) {
        lock.lock()
        if !profileExcludedTouches.contains(id) {
            performanceProfile.setPitch(pitchSemis, for: id, at: ProcessInfo.processInfo.systemUptime)
        }
        touchPitchSemis[id] = pitchSemis
        heldTouchOrder.removeAll { $0 == id }
        heldTouchOrder.append(id)
        let voice = playedVoiceLocked(mainInstrumentStorage)
        let exprScale = effectiveExprScaleLocked(id)
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        voice?.touchOn(id, pitchSemis: pitchSemis,
                       exprScale: exprScale)
    }

    /// Restore tracking and reopen the released voice without a new attack.
    private func touchResumeDirect(_ id: UInt16, pitchSemis: Double) {
        lock.lock()
        performanceProfile.setPitch(pitchSemis, for: id, at: ProcessInfo.processInfo.systemUptime)
        touchPitchSemis[id] = pitchSemis
        heldTouchOrder.removeAll { $0 == id }
        heldTouchOrder.append(id)
        let voice = playedVoiceLocked(mainInstrumentStorage)
        let exprScale = effectiveExprScaleLocked(id)
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        if voice?.touchResume(id, exprScale: exprScale) != true {
            // A stolen slot or rebuilt instrument has no prior string to resume.
            voice?.touchOn(id, pitchSemis: pitchSemis, exprScale: exprScale)
        }
    }

    /// The expression scale a touch carries into the voice: the strum
    /// chord's scale × the pitch accent at the touch's current pitch.
    /// Exactly 1.0 with neither in play. Callers hold `lock`.
    func effectiveExprScaleLocked(_ id: UInt16) -> Double {
        let strum = touchExprScale[id] ?? 1.0
        guard pitchAccentAmount > 0, let semis = touchPitchSemis[id] else { return strum }
        return strum * fretPitchGrid.exprScale(atSemis: semis, amount: pitchAccentAmount)
    }

    /// Re-deliver every held touch's expression scale (the accent amount
    /// or the fret grid moved under sounding notes). Callers hold `lock`;
    /// the returned closure runs after it is released.
    private func repushHeldExprLocked() -> () -> Void {
        let voice = playedVoiceLocked(mainInstrumentStorage)
        let pushes = heldTouchOrder.map { ($0, effectiveExprScaleLocked($0)) }
        return { for (id, s) in pushes { voice?.touchExpr(id, exprScale: s) } }
    }

    /// The pitch accent amount (`ctl_fret_accent`, 0…1). Thread-safe;
    /// held notes take the new amount at once.
    public func setPitchAccent(_ amount: Double) {
        let a = min(max(amount, 0), 1)
        lock.lock()
        guard a != pitchAccentAmount else { lock.unlock(); return }
        pitchAccentAmount = a
        let push = repushHeldExprLocked()
        lock.unlock()
        push()
    }

    /// The fret pitches the accent reads (the pad's arrangement against
    /// the ONE scale, pushed on every change of either). Thread-safe; held
    /// notes follow at once.
    public func setFretPitchGrid(_ grid: FretPitchGrid) {
        lock.lock()
        guard grid != fretPitchGrid else { lock.unlock(); return }
        fretPitchGrid = grid
        let push = pitchAccentAmount > 0 ? repushHeldExprLocked() : {}
        lock.unlock()
        push()
    }

    /// The voice the fret notes drive right now. Callers hold `lock`.
    func playedVoiceLocked(_ inst: MainInstrument) -> PlayedVoice? {
        inst == .string ? stringVoiceSource : pluckVoiceLocked(inst)
    }

    /// Every voice that can hold a touch — a release reaches all of them,
    /// so a note begun before an instrument switch still lets go.
    /// Callers hold `lock`.
    func allVoicesLocked() -> [PlayedVoice] {
        var v: [PlayedVoice] = [tanpuraVoice, sitarVoice]
        if let s = stringVoiceSource { v.insert(s, at: 0) }
        return v
    }

    /// Per-touch expression scale (the strum chord). String touches update
    /// the mapper's per-slot scale live; plucked mains consume it at onset.
    public func touchExpr(_ id: UInt16, exprScale: Double) {
        lock.lock()
        touchExprScale[id] = exprScale
        let voice = playedVoiceLocked(mainInstrumentStorage)
        let effective = effectiveExprScaleLocked(id)
        lock.unlock()
        voice?.touchExpr(id, exprScale: effective)
    }

    /// Pitch update, the DIRECT path. String: the mapper tracks the finger
    /// directly, with the pitch accent's expression scale landing in the
    /// same update. Plucked mains: live-retune the ringing slot kernel-side.
    private func touchGlideDirect(_ id: UInt16, pitchSemis: Double) {
        lock.lock()
        guard touchPitchSemis[id] != nil else { lock.unlock(); return }
        if !profileExcludedTouches.contains(id) {
            performanceProfile.setPitch(pitchSemis, for: id, at: ProcessInfo.processInfo.systemUptime)
        }
        touchPitchSemis[id] = pitchSemis
        let voice = playedVoiceLocked(mainInstrumentStorage)
        let exprScale = pitchAccentAmount > 0 ? effectiveExprScaleLocked(id) : nil
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        voice?.touchGlide(id, pitchSemis: pitchSemis, exprScale: exprScale)
    }

    /// Touch release, the DIRECT path. String: bow lift. Plucked mains:
    /// fast-release the slot (`tp_rel_t60`), even after a switch back to String.
    private func touchOffDirect(_ id: UInt16) {
        lock.lock()
        performanceProfile.setPitch(nil, for: id, at: ProcessInfo.processInfo.systemUptime)
        profileExcludedTouches.remove(id)
        touchPitchSemis.removeValue(forKey: id)
        touchExprScale.removeValue(forKey: id)
        heldTouchOrder.removeAll { $0 == id }
        let voices = allVoicesLocked()
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        for v in voices { v.touchOff(id) }
    }

    /// The link-drop kill path: every bow off, slot released, drone up,
    /// glide queue cleared — the wire's stuck-note safety net.
    public func touchesAllOff() {
        glideQueue.reset()
        lock.lock()
        performanceProfile.releaseAll(at: ProcessInfo.processInfo.systemUptime)
        profileExcludedTouches.removeAll()
        touchPitchSemis.removeAll(keepingCapacity: true)
        touchExprScale.removeAll(keepingCapacity: true)
        heldTouchOrder.removeAll(keepingCapacity: true)
        let voices = allVoicesLocked()
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        for v in voices { v.touchAllOff() }
        for i in 0..<FretArrangement.droneCount { setDronePressed(i, false) }
    }

    /// The expression axis (CC11); the Mac pads hold the fitted median here.
    public func setPerformanceExpression(_ v01: Double) {
        stringVoiceSource?.mapper.setAxis(expr: v01)
    }

    deinit {
        #if os(macOS)
        restoreOutputDeviceRate()
        #endif
        engine.stop()
    }
}
