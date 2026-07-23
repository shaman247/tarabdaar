import AVFoundation
import Foundation
import QuartzCore
import StarpadDSP
import SarangiKit

/// macOS audio plumbing wrapper around the ported `SarangiKit.SarangiEngine`.
///
/// The played voice is supplied by a hosted Audio Unit (SWAM Violin), run DRY.
/// `SarangiEngine` is the full sarangi model (the v57 PASSIVE coupled
/// bridge–body network): it takes the played-voice audio as input and produces
/// the COMPLETE stereo sarangi. It therefore REPLACES the dry voice — the dry
/// source is not summed separately.
///
/// Render flow each block (INLINE — no tap/ring; see `setupSarangiEffect`):
///   1. The base voice renders into `hostedDriveTap` (which sums the poly
///      instances) as part of the normal graph pull.
///   2. The inline `sarangiEffect` AUv3 node (spliced `hostedDriveTap →
///      sarangiEffect → symGain`) pulls that summed audio synchronously in the
///      SAME pull, calls `sarangiEngine.beginBuffer()` once, then
///      `renderSample(x)` per sample. Because the model runs in the source's
///      own render pull, there is no transport latency (the old
///      `installTap(4096) → SPSCAudioRing → separate source node` added ~140 ms).
///   3. The sarangi (model incl. its Starpad FX rack) goes `symGain →
///      mainMixerNode` DIRECTLY, bypassing the master filter/reverb, which is the
///      shared room for the tanpura + sitar only. The model owns its body
///      (modal admittance + radiation FIR from `sarangi_coupled.json`).
///
/// Sym public methods acquire `lock` and swap/configure `sarangiEngine`. The
/// inline effect's render closure (`makeSarangiProcessBlock`) also takes the lock
/// to read `sarangiEngine` and run `renderSample`.
public class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    /// Sums sym-pool output and the hosted AU's dry signal before the
    /// master-FX chain.
    private let preReverbMixer = AVAudioMixerNode()
    /// Single-input gain stage between the hosted AU and the pre-reverb
    /// mixer. AVAudioMixerNode doesn't expose per-input-bus volume, so
    /// to control the hosted-AU level independently of the source node
    /// (which carries sym output) we route the AU through its own
    /// mixer and set THAT mixer's `outputVolume`.
    private let hostedInstrumentGain = AVAudioMixerNode()
    /// Makeup-gain stage for the hosted AU, sitting between
    /// `hostedInstrumentGain` and the pre-reverb mixer. `AVAudioMixerNode`
    /// `outputVolume` clamps to [0, 1] and can only attenuate, so when a
    /// hosted AU (e.g. SWAM Viola) renders at a low level there is no way
    /// to bring it back up through the mixer path. `AVAudioUnitEQ`
    /// exposes `globalGain` in dB (up to +24), so we use a band-less EQ
    /// purely as a >unity makeup gain. Driven by `setHostedMakeupGainDB`.
    private let hostedMakeupGain = AVAudioUnitEQ(numberOfBands: 0)
    /// Shared sarangi instrument-body formant stage: four parametric peak
    /// bands (skin first-formant / mid scoop / nasal / presence) that pull
    /// the bowed SWAM voice **and the sym halo together** toward a sarangi's
    /// parchment-body color. Sits on the `sarangiMixer` sub-bus (SWAM + halo),
    /// NOT the whole mix — the tanpura/sitar join after it. With SWAM run dry
    /// (its own internal body off) and the halo's `SymBodyFilter` bypassed,
    /// this is the single instrument body for the sarangi, shared by both
    /// sources (one bridge/body, physically). All bands ship bypassed; presets
    /// engage them via `setViolaBodyEnabled` / `setViolaBodyBand`.
    private let violaBodyEQ = AVAudioUnitEQ(numberOfBands: 4)
    /// Sums the bowed SWAM voice (post makeup gain) and the sym halo (post
    /// `symGain`) into one sarangi sub-bus, so the shared `violaBodyEQ` body
    /// stage colors both before the tanpura/sitar are mixed in.
    private let sarangiMixer = AVAudioMixerNode()
    /// Final spectral-envelope shaper AFTER the master reverb (3 parametric
    /// peak bands): tames the reverb tail's low-mid bloom and restores air, so
    /// "body + room" are handled entirely in our post-processing. All bands
    /// ship bypassed; presets engage them via `setPostReverbEnabled` /
    /// `setPostReverbBand`.
    private let postReverbEQ = AVAudioUnitEQ(numberOfBands: 3)
    /// Always-full-level sum of the hosted AU instances, sitting upstream of
    /// `hostedInstrumentGain` (which is pinned at 0). The model-drive tap is
    /// installed *here* so SWAM's dry audio reaches the model at full level even
    /// though the dry passthrough into the mix is muted.
    private let hostedDriveTap = AVAudioMixerNode()
    /// Output-gain stage for the sarangi source node. Pinned at unity — the
    /// model (run dry) is the played voice and feeds `preReverbMixer` → the
    /// shared master filter/reverb.
    private let symGain = AVAudioMixerNode()
    /// Master post-FX: resonant low-pass between source mixer and
    /// reverb. Driven by `setMasterFilter(cutoff:resonance:)`.
    private let masterFilter = AVAudioUnitEQ(numberOfBands: 1)
    private let lock = NSLock()
    /// The ported sarangi model: played-voice audio in → full stereo sarangi out
    /// (the v57 passive coupled bridge–body network). Built/swapped under `lock`
    /// on a structural change; nil until a model is configured (the effect
    /// outputs silence). Live scalar (gain) changes mutate `.scalars` in place.
    private var sarangiEngine: SarangiEngine?
    /// Calibration gain on the base-voice → model drive, applied in the render
    /// closure before the model. **Default 1× = unity**, which matches the
    /// standalone "Sarangi Live" app (it feeds its voice straight into
    /// `renderSample`; the fitted preset's `gin` carries the level calibration).
    /// Raise only when driving the network from a quieter source (e.g. a SWAM
    /// base voice). Set from `setSarangiDriveGain`.
    private var sarangiDriveGain: Double = 1

    /// Self-excited tanpura drone (StarpadDSP.TanpuraModel) on its own
    /// source node. Deliberately NOT summed into the sarangi render: the
    /// sarangi callback outputs silence when no hosted-AU drive ring exists.
    /// The drone must be independent, so it gets its own node:
    /// `tanpuraSource → tanpuraGain → preReverbMixer` (riding the same
    /// master filter + reverb and the audition recording tap). Guarded by
    /// its own lock so drone renders never contend with the sym path.
    private let tanpura: TanpuraModel
    private let tanpuraLock = NSLock()
    private var tanpuraSource: AVAudioSourceNode!
    /// Gain stage for the drone. An EQ (not a mixer) so it can boost
    /// above unity — `setTanpuraGainDB` drives `globalGain`, same
    /// pattern as `hostedMakeupGain`.
    private let tanpuraGain = AVAudioUnitEQ(numberOfBands: 0)

    /// Plucked sitar voice — the SAME harmonic-resolved string model as the
    /// tanpura (`TanpuraModel`), fitted to `sitar1.wav` and baked into
    /// `TanpuraParams.sitar`. Its own source node + lock, identical wiring to
    /// the drone (`sitarSource → sitarGain → preReverbMixer`). Independent of
    /// the tanpura so the two never contend. Eventually feeds the sym layer.
    private let sitar: TanpuraModel
    private let sitarLock = NSLock()
    private var sitarSource: AVAudioSourceNode!
    private let sitarGain = AVAudioUnitEQ(numberOfBands: 0)

    // MARK: - Sitar as base voice (excitation into the sarangi model)

    /// A THIRD `TanpuraModel`, used only when the **sitar is the selected base
    /// voice** (instead of a SWAM AU). Its note-driven plucks are the
    /// EXCITATION into the sarangi model: it is rendered INSIDE the sarangi
    /// process block and its audio replaces the SWAM drive, so the sympathetic
    /// bank / jawari / body / FX color the plucked sitar. Distinct from `sitar`
    /// (the Sitar tab's demo voice, which goes to the master room) so the two
    /// never collide. Mutated + rendered only under the main `lock`.
    private let voiceSitar: TanpuraModel
    private var useSitarBaseVoice = false
    /// Scratch buffers: render the base-voice sitar here, then collapse to mono
    /// to drive `renderSample`. Sized to `sitarDriveCapacity`.
    private var sitarDriveL: UnsafeMutablePointer<Float>?
    private var sitarDriveR: UnsafeMutablePointer<Float>?
    private let sitarDriveCapacity = 4096
    /// Voice pool for the base-voice sitar: MPE channel → string index. The
    /// model has `TanpuraModel.stringCount` strings (the sitar's timbre is
    /// pitch-invariant, so any string can play any note); notes round-robin /
    /// steal by `sitarStringAge`.
    private var sitarVoiceForChannel: [UInt8: Int] = [:]
    private var sitarStringAge = [UInt64](repeating: 0, count: TanpuraModel.stringCount)
    private var sitarVoiceCounter: UInt64 = 0
    /// Makeup gain on the base-voice sitar's drive into the model (~+18 dB,
    /// matching the Sitar tab's default `sitarGainDB`). The sitar model's raw
    /// output is far quieter than SWAM's, and `sarangiDriveGain` is tuned for
    /// SWAM — without this the sitar under-drives the model to near-silence.
    private let sitarBaseVoiceMakeup: Float = 8.0

    // MARK: - Sarangi model source (the String pure-physics bowed gut string)

    /// The String-physics source (`StringVoiceSource` wrapping
    /// `SarangiKit.BowEngine` — the C friction kernel with the modal-jawari
    /// taraf fused in-kernel), used when the **Sarangi (model)** base voice is
    /// selected. It replaced the v57 `ViolinSynth` + coupled-network pair
    /// (upstream 2026-07-21 String-only simplification). The kernel is the
    /// WHOLE instrument (played strings + taraf + body + radiation + room), so
    /// its node connects DIRECTLY to `symGain`, bypassing `SarangiProcessorAU`
    /// — running it through the coupled network would double the taraf. Runs
    /// at the artifact's native 48 kHz; the mixer input converts to the engine
    /// rate. Kept attached; connected/disconnected on voice switches.
    private var stringVoiceSource: StringVoiceSource?
    private var stringVoiceAttached = false
    private var stringVoiceConnected = false
    /// Guarded by `lock` (checked on the MIDI path like `useSitarBaseVoice`).
    private var useSarangiModelVoice = false
    /// Last structural tarab push, retained so the String engine can be
    /// (re)built from the current tuning when the voice is enabled later.
    private var lastSarangiStrings: [ResolvedString] = []
    private var lastSarangiT60Scale: Double = 1.0
    private var lastSarangiTonic: Double = 261.63
    /// String-editor / audition scalar overrides applied OVER the
    /// `bowed_string.json` artifact at every String engine build.
    public var stringVoiceOverrides: [String: Double] = [:]
    /// Serial build queue for the String engine (tables + kernel init + jt
    /// worker-pool spawn are too heavy for the main thread); `stringBuildGen`
    /// discards builds that were superseded while in flight.
    private let stringBuildQueue = DispatchQueue(label: "starpad.string.build",
                                                 qos: .userInitiated)
    private var stringBuildGen = 0

    @Published public var isRunning = false

    // MARK: - Hosted instrument (third-party Audio Unit)

    /// Polyphonic hosted-instrument slots. One AU instance per slot —
    /// each hosted AU (e.g. SWAM Viola 3) is monophonic, so polyphony
    /// comes from running N instances in parallel and mapping each MPE
    /// channel onto its own slot. Empty when no hosted preset is
    /// active; otherwise sized to `Config.maxHostedPolyVoices` with
    /// nil entries for slots whose async instantiation failed.
    private var hostedInstruments: [AVAudioUnit?] = []
    /// Preset-specified hosted-AU parameter defaults (identifier → value),
    /// e.g. SWAM Viola's Bow Position / Bow Pressure / Vibrato off. Applied to
    /// every slot as it instantiates (and immediately to loaded slots when
    /// set) so the instrument's own timbre matches the baked sarangi sound.
    private var hostedAUParameterDefaults: [String: Float] = [:]
    /// Preset-specified hosted-AU full document state, restored to every slot
    /// as it instantiates. This carries SWAM's OPAQUE encoded state — notably
    /// the per-control MIDI CC assignments (Expression/Vibrato/Bow Pressure/
    /// Bow Position), which are NOT exposed as AU parameters and so can't be
    /// set via `hostedAUParameterDefaults`. Applied BEFORE the param defaults
    /// on attach, so the explicit `hostedAUParameterDefaults` still win for the
    /// parameters we tune in code, while the blob supplies only the CC routing.
    private var hostedAUFullState: [String: Any]?
    /// Cached MIDI event block per slot. Calling these is realtime-
    /// safe per AUv3 spec, so we only lock to swap them on preset
    /// switch.
    private var hostedMIDIBlocks: [AUScheduleMIDIEventBlock?] = []
    /// Per-slot state for voice allocation.
    private struct HostedSlotState {
        var channel: UInt8?
        /// MIDI note number currently held on this slot, if any. Needed
        /// at slot-steal time so we can emit a Note Off for the
        /// displaced note before re-using the slot for a new channel —
        /// without that, SWAM keeps the previous note internally held
        /// on its old channel and we get a stuck-note bug whenever a
        /// new MPE channel has to evict an existing one (which happens
        /// on every Note On at poly=1).
        var note: UInt8?
        var age: UInt64
    }
    private var hostedSlotStates: [HostedSlotState] = []
    /// Reverse index: which slot is currently bound to which MPE
    /// channel.
    private var hostedChannelToSlot: [UInt8: Int] = [:]
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
    /// to the next-most-recent (not an arbitrary `Dictionary` key). Guarded
    /// by `lock`.
    private var heldChannelOrder: [UInt8] = []
    /// Monotonic counter for LRU stealing.
    private var hostedAgeCounter: UInt64 = 0
    /// Per-batch load bookkeeping.
    private var hostedLoadDescriptor: HostedAUDescriptor?
    private var hostedLoadTotal: Int = 0
    private var hostedLoadCompleted: Int = 0
    private var hostedLoadSuccess: Int = 0
    private var hostedLoadCompletion: ((Result<Void, Error>) -> Void)?
    /// Parameter observer registered on the primary slot. Mirrors UI
    /// edits onto every other instance so the user only configures one
    /// SWAM and polyphonic voices stay consistent.
    private var hostedParamObserverToken: AUParameterObserverToken?
    private var hostedParamObserverPrimarySlot: Int?
    /// Human-readable trace of the most recent load attempt.
    @Published public var hostedInstrumentStatus: String = "no instrument"
    /// Count of MIDI events forwarded to any hosted AU since the last
    /// load.
    @Published public var hostedMIDIEventCount: UInt64 = 0
    /// Peak absolute sample value observed at the hosted mixer's
    /// output over the last ~1 second.
    @Published public var hostedOutputPeak: Float = 0

    /// Lightweight lock guarding the performance-readout scalars below.
    /// Separate from `lock` so the Live tab's poll never contends with the
    /// audio render thread. Never held while `lock` is held.
    private let meterLock = NSLock()
    private var meterPitchHz: Double = 0
    private var meterExpr: Double = 0
    private var meterActive: Bool = false
    /// True iff at least one hosted instrument slot is loaded.
    /// `MIDIInput` checks this to route MPE to the AUs.
    public var isHostingInstrument: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hostedInstruments.contains(where: { $0 != nil })
    }

    /// The primary hosted AU (first non-nil slot). Used by the Mac UI
    /// to request the AU's view controller for in-app configuration.
    /// Edits made here propagate to the other slots via the parameter
    /// mirror installed in `installHostedParameterMirror`.
    public var hostedAUAudioUnit: AUAudioUnit? {
        lock.lock()
        defer { lock.unlock() }
        for inst in hostedInstruments {
            if let inst { return inst.auAudioUnit }
        }
        return nil
    }

    // MARK: - Profiling

    public private(set) var lastRenderTime: Double = 0
    public private(set) var maxRenderTime: Double = 0
    public private(set) var lastRenderFrames: Int = 0
    public private(set) var lockWaitNanos: UInt64 = 0
    public private(set) var lockAcquisitions: UInt64 = 0
    private var maxRenderTimeWindowEnd: Double = 0

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

    /// Inline AUv3 effect that runs the sarangi model on SWAM's audio in the
    /// SAME render pull (`hostedDriveTap → sarangiEffect → symGain`). Replaces
    /// the old tap → ring → separate source-node transport that added ~140 ms.
    /// Instantiated asynchronously in `setupSarangiEffect`; nil until it lands.
    private var sarangiEffect: AVAudioUnit?

    public init() {
        self.tanpura = TanpuraModel(sampleRate: Config.sampleRate)
        self.sitar = TanpuraModel(sampleRate: Config.sampleRate,
                                  params: TanpuraParams.sitar)
        self.voiceSitar = TanpuraModel(sampleRate: Config.sampleRate,
                                       params: TanpuraParams.sitar)
        sitarDriveL = .allocate(capacity: sitarDriveCapacity)
        sitarDriveR = .allocate(capacity: sitarDriveCapacity)
        sitarDriveL?.initialize(repeating: 0, count: sitarDriveCapacity)
        sitarDriveR?.initialize(repeating: 0, count: sitarDriveCapacity)
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

        // The played sarangi voice is rendered by the inline `sarangiEffect`
        // AUv3 node (see `setupSarangiEffect`), NOT a source node — it pulls
        // SWAM's audio in the same render pull, so there is no tap/ring latency.

        // Tanpura drone source: zero the buffers, then the model ADDS its
        // output. Allocation-free; all model access under tanpuraLock.
        tanpuraSource = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard ablPointer.count >= 2,
                  let dataL = ablPointer[0].mData?
                    .assumingMemoryBound(to: Float.self),
                  let dataR = ablPointer[1].mData?
                    .assumingMemoryBound(to: Float.self)
            else { return noErr }
            for i in 0..<frames {
                dataL[i] = 0
                dataR[i] = 0
            }
            self.tanpuraLock.lock()
            self.tanpura.renderAdd(intoL: dataL, intoR: dataR, frames: frames)
            self.tanpuraLock.unlock()
            return noErr
        }

        // Sitar source: identical pattern to the tanpura — zero, then ADD.
        sitarSource = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard ablPointer.count >= 2,
                  let dataL = ablPointer[0].mData?
                    .assumingMemoryBound(to: Float.self),
                  let dataR = ablPointer[1].mData?
                    .assumingMemoryBound(to: Float.self)
            else { return noErr }
            for i in 0..<frames {
                dataL[i] = 0
                dataR[i] = 0
            }
            self.sitarLock.lock()
            self.sitar.renderAdd(intoL: dataL, intoR: dataR, frames: frames)
            self.sitarLock.unlock()
            return noErr
        }

        engine.attach(symGain)
        engine.attach(tanpuraSource)
        engine.attach(tanpuraGain)
        engine.attach(sitarSource)
        engine.attach(sitarGain)
        engine.attach(preReverbMixer)
        engine.attach(hostedDriveTap)
        engine.attach(hostedInstrumentGain)
        engine.attach(hostedMakeupGain)
        engine.attach(sarangiMixer)
        engine.attach(violaBodyEQ)
        engine.attach(masterFilter)
        engine.attach(reverb)
        engine.attach(postReverbEQ)
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 25
        // Master filter as resonant low-pass, fully open at startup;
        // engaged by `setMasterFilter(...)` when a preset asks for it.
        let band = masterFilter.bands[0]
        band.filterType = .resonantLowPass
        band.frequency = 20000
        band.bandwidth = 4.0
        band.bypass = true
        // Viola body bands start bypassed at neutral defaults; presets
        // engage them. `.parametric` peak filters; bandwidth in octaves.
        for body in violaBodyEQ.bands {
            body.filterType = .parametric
            body.frequency = 1000
            body.gain = 0
            body.bandwidth = 0.7
            body.bypass = true
        }
        // Post-reverb shaper starts bypassed at neutral defaults; presets
        // engage it. `.parametric` peak filters; bandwidth in octaves.
        for band in postReverbEQ.bands {
            band.filterType = .parametric
            band.frequency = 1000
            band.gain = 0
            band.bandwidth = 0.7
            band.bypass = true
        }
        // Graph — the sarangi is the COMPLETE played voice. It runs the model
        // (incl. its per-voice FX rack) and bypasses Starpad's master post-
        // processing (filter/reverb/EQ) — `symGain → mainMixerNode` direct. The
        // model is rendered INLINE by `sarangiEffect` (an AUv3 effect spliced
        // hostedDriveTap → sarangiEffect → symGain in `setupSarangiEffect`), so
        // SWAM's audio drives it in the SAME render pull (no tap/ring latency).
        // The master FX chain remains the shared room for the tanpura + sitar:
        //   hosted AU(s) → hostedDriveTap → sarangiEffect (model) → symGain ───► mainMixerNode → output
        //   tanpuraSource → tanpuraGain ──────────────────────────────────────┐
        //   sitarSource   → sitarGain   ──────────────────────────────────────┤
        //                                            preReverbMixer ◄──────────┘
        //                                                  └─► masterFilter → reverb → postReverbEQ → mainMixerNode → output
        // `hostedDriveTap` sums the hosted AU instances and feeds the inline
        // effect. The old muted dry branch (hostedInstrumentGain → … →
        // preReverbMixer) is gone — its only job was keeping the tap pulled, and
        // the effect now pulls hostedDriveTap. hostedInstrumentGain/
        // hostedMakeupGain/sarangiMixer/violaBodyEQ stay ATTACHED-but-disconnected
        // so AppController's property setters stay valid.
        //
        // The inline sarangi effect is built + connected HERE, synchronously,
        // BEFORE engine.start() — connecting a custom AUAudioUnit into an already-
        // running engine does NOT allocate its render resources or pull it (the
        // node stays silent). `AVAudioUnitEffect(audioComponentDescription:)` is a
        // synchronous in-process instantiator, so the full graph is live at start.
        registerSarangiAUOnce()
        let effect = AVAudioUnitEffect(audioComponentDescription: sarangiAUComponentDescription)
        (effect.auAudioUnit as? SarangiProcessorAU)?.processBlock = makeSarangiProcessBlock()
        engine.attach(effect)
        sarangiEffect = effect

        engine.connect(hostedDriveTap, to: effect, format: format)
        engine.connect(effect, to: symGain, format: format)
        engine.connect(symGain, to: engine.mainMixerNode, format: format)
        engine.connect(tanpuraSource, to: tanpuraGain, format: format)
        engine.connect(tanpuraGain, to: preReverbMixer, format: format)
        engine.connect(sitarSource, to: sitarGain, format: format)
        engine.connect(sitarGain, to: preReverbMixer, format: format)
        engine.connect(preReverbMixer, to: masterFilter, format: format)
        engine.connect(masterFilter, to: reverb, format: format)
        engine.connect(reverb, to: postReverbEQ, format: format)
        engine.connect(postReverbEQ, to: engine.mainMixerNode, format: format)
        // `symGain` carries the full sarangi at unity. The tanpura/sitar room
        // mixer runs at unity unconditionally (previously this was gated on the
        // first hosted-AU attach, which left the room silent with no AU loaded).
        symGain.outputVolume = 1
        preReverbMixer.outputVolume = 1.0

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
        // clamped to its allowed range. The model needs ~0.9 ms of a buffer, so
        // there is ample headroom below the 512-frame default. Tunable live via
        // `setOutputBufferFrames`.
        let beforeBuf = outputBufferFrames
        let gotBuf = setOutputBufferFrames(Config.preferredOutputBufferFrames)
        NSLog("Starpad: output IO buffer \(beforeBuf)f → requested \(Config.preferredOutputBufferFrames)f → got \(gotBuf)f")
        logAudioLatencyReport("engine started")
        #endif
    }

    /// The per-buffer model render that the inline `sarangiEffect` runs on the
    /// realtime thread. This is the body the old source node ran, minus the ring
    /// read: the base voice's audio arrives as the effect's pulled input. All
    /// model state (`sarangiEngine`/`sarangiDriveGain`) is read under `lock`,
    /// exactly as before. The peak meter is computed from the INPUT
    /// unconditionally so it tracks the source even when no model is configured.
    private func makeSarangiProcessBlock() -> SarangiProcessBlock {
        return { [weak self] inL, inR, outL, outR, frames in
            guard let self else {
                for i in 0..<frames { outL[i] = 0; outR[i] = 0 }
                return
            }
            let renderStart = CACurrentMediaTime()

            // Peak meter from the pulled SWAM input — UNCONDITIONAL (matches the
            // old tap: the meter reflects SWAM's output even with no model). When
            // the sitar drives the model instead, the meter is recomputed from
            // its rendered scratch below.
            var peak: Float = 0
            for i in 0..<frames {
                let a = abs(inL[i]); if a > peak { peak = a }
                let b = abs(inR[i]); if b > peak { peak = b }
            }
            var capturedPeak = peak

            // Mono drive = 0.5·(L+R), lifted by `sarangiDriveGain` so the RAW
            // (quiet) SWAM output reaches the level the model was fit for; applied
            // BEFORE the amp follower AND the model. beginBuffer + the whole
            // per-sample loop stay inside ONE lock acquisition so `sarangiEngine`
            // can't be swapped mid-buffer.
            self.lock.lock()
            // String base voice: the kernel renders on its OWN source node
            // straight to symGain (its taraf/body/room are in-kernel) — the
            // coupled network must stay out of the path (double taraf) and
            // its silent-input render is pure wasted CPU. Pass silence.
            if self.useSarangiModelVoice {
                for i in 0..<frames { outL[i] = 0; outR[i] = 0 }
                self.lock.unlock()
                DispatchQueue.main.async { self.hostedOutputPeak = capturedPeak }
                return
            }
            // When the sitar is the base voice, render it here and use its audio
            // as the drive INSTEAD of the (unloaded) SWAM input. Same lock, so
            // its note-driven plucks/retunes can't race the render.
            var driveL = inL
            var driveR = inR
            if self.useSitarBaseVoice, let sl = self.sitarDriveL, let sr = self.sitarDriveR {
                let n = min(frames, self.sitarDriveCapacity)
                for i in 0..<n { sl[i] = 0; sr[i] = 0 }
                self.voiceSitar.renderAdd(intoL: sl, intoR: sr, frames: n)
                // The sitar model's RAW output is quiet (the Sitar tab lifts it
                // ~+18 dB to be audible); `sarangiDriveGain` is calibrated for
                // SWAM's very different level, so without makeup the sitar
                // under-drives the model to near-silence. Apply the same ~+18 dB
                // here so the sitar excites the model at a healthy level at the
                // default drive. Any tail beyond scratch capacity stays silent
                // (frames > 4096 never happens with our buffer sizes).
                let mk = self.sitarBaseVoiceMakeup
                var sPeak: Float = 0
                for i in 0..<n {
                    sl[i] *= mk; sr[i] *= mk
                    let a = abs(sl[i]); if a > sPeak { sPeak = a }
                    let b = abs(sr[i]); if b > sPeak { sPeak = b }
                }
                capturedPeak = sPeak
                driveL = UnsafePointer(sl)
                driveR = UnsafePointer(sr)
            }
            if let engine = self.sarangiEngine {
                let driveGain = self.sarangiDriveGain
                let n = self.useSitarBaseVoice ? min(frames, self.sitarDriveCapacity) : frames
                engine.beginBuffer()
                for i in 0..<n {
                    let x = driveGain * 0.5 * (Double(driveL[i]) + Double(driveR[i]))
                    let (l, r) = engine.renderSample(x)
                    outL[i] = Float(l)
                    outR[i] = Float(r)
                }
                for i in n..<frames { outL[i] = 0; outR[i] = 0 }
            } else {
                for i in 0..<frames { outL[i] = 0; outR[i] = 0 }
            }
            self.lock.unlock()

            DispatchQueue.main.async { self.hostedOutputPeak = capturedPeak }

            let elapsed = CACurrentMediaTime() - renderStart
            self.lastRenderTime = elapsed
            self.lastRenderFrames = frames
            let now = renderStart + elapsed
            if now > self.maxRenderTimeWindowEnd {
                self.maxRenderTime = elapsed
                self.maxRenderTimeWindowEnd = now + 1.0
            } else if elapsed > self.maxRenderTime {
                self.maxRenderTime = elapsed
            }
        }
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
    /// 44.1 kHz) so the engine → device path has no resampler — the sarangi/
    /// tanpura/sitar models are all fitted at 44.1 kHz, so device + engine +
    /// models align on one rate. Best-effort: skipped if the device does not
    /// support the rate (then AVAudioEngine's converter bridges as before).
    /// Remembers the device's prior rate; restore with `restoreOutputDeviceRate`.
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
    /// size, and the node presentation/AU latencies. `print` so it shows on
    /// stdout when the binary is run from a terminal; also NSLog for the device log.
    public func logAudioLatencyReport(_ context: String) {
        let engineSR = Config.sampleRate
        let deviceSR = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let buf = outputBufferFrames
        let bufMs = deviceSR > 0 ? Double(buf) / deviceSR * 1000 : 0
        let outLatMs = engine.outputNode.presentationLatency * 1000
        lock.lock(); let aus = hostedInstruments.compactMap { $0 }; lock.unlock()
        var swamSR = 0.0
        var swamLatMs = 0.0
        if let au = aus.first {
            swamSR = au.outputFormat(forBus: 0).sampleRate
            swamLatMs = au.auAudioUnit.latency * 1000
        }
        let effLatMs = sarangiEffect?.auAudioUnit.latency ?? 0
        let srcNote = (swamSR != 0 && swamSR != engineSR) ? " [SWAM→tap RESAMPLE]" : ""
        let outSrcNote = (deviceSR != engineSR) ? " [output RESAMPLE]" : ""
        let msg = """
        AUDIO LATENCY [\(context)]: engineSR=\(engineSR) deviceSR=\(deviceSR)\(outSrcNote) \
        ioBuffer=\(buf)f (\(String(format: "%.1f", bufMs))ms) \
        outputPresentationLatency=\(String(format: "%.1f", outLatMs))ms \
        SWAM_SR=\(swamSR)\(srcNote) SWAM_latency=\(String(format: "%.2f", swamLatMs))ms \
        sarangiEffect_latency=\(String(format: "%.2f", effLatMs * 1000))ms \
        modelMaxRender=\(String(format: "%.2f", maxRenderTime * 1000))ms/\(lastRenderFrames)f
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

    // MARK: - Output mix

    public func setReverbMix(_ percent: Float) {
        reverb.wetDryMix = max(0, min(100, percent))
    }

    /// Scale the hosted AU's output. Has no effect on the sym pool,
    /// which is fed from the source node via its own mixer input bus.
    public func setHostedInstrumentVolume(_ v: Float) {
        hostedInstrumentGain.outputVolume = max(0, v)
    }

    /// Makeup gain (dB) for the hosted AU, allowing it to be boosted
    /// **above** unity — which the mixer-based `setHostedInstrumentVolume`
    /// cannot do (mixer `outputVolume` clamps to [0, 1]). Use this when
    /// the hosted instrument (e.g. SWAM Viola) renders too quietly.
    /// Clamped to the EQ's valid range; `AVAudioUnitEQ.globalGain` tops
    /// out at +24 dB.
    public func setHostedMakeupGainDB(_ db: Float) {
        hostedMakeupGain.globalGain = max(-24, min(24, db))
    }

    /// Output gain (dB) for the tanpura drone, applied after the model's
    /// peak-normalized `masterGain` so volume changes never disturb the
    /// matched `TanpuraParams`. Boosts above unity are the point —
    /// `AVAudioUnitEQ.globalGain` allows up to +24 dB.
    public func setTanpuraGainDB(_ db: Float) {
        tanpuraGain.globalGain = max(-24, min(24, db))
    }

    // MARK: - Master post-FX (resonant low-pass)

    /// Engage the master resonant low-pass with the given cutoff (Hz)
    /// and resonance (0..1, where 0 = no resonance and 1 = strong
    /// resonant peak). `AVAudioUnitEQ` uses bandwidth in octaves
    /// (smaller = more resonant) for `.resonantLowPass`; we map the
    /// 0..1 resonance scale onto bandwidth [4.0..0.1].
    public func setMasterFilter(cutoff hz: Double, resonance: Double) {
        let band = masterFilter.bands[0]
        let clampedHz = max(20, min(20000, hz))
        let r = max(0, min(1, resonance))
        let bw = 4.0 * (1.0 - r) + 0.1 * r
        band.frequency = Float(clampedHz)
        band.bandwidth = Float(bw)
        band.bypass = false
    }

    // MARK: - Hosted instrument (Audio Unit)

    /// Identifies a hosted Audio Unit by its 3-tuple of 4-char codes —
    /// e.g. `("aumu", "Sva3", "AuMo")` for SWAM Viola 3.
    public struct HostedAUDescriptor: Equatable {
        public let type: String
        public let subType: String
        public let manufacturer: String

        public init(type: String, subType: String, manufacturer: String) {
            self.type = type
            self.subType = subType
            self.manufacturer = manufacturer
        }
    }

    /// Load N hosted-instrument AU instances (one per polyphony slot,
    /// where N = `Config.maxHostedPolyVoices`) and wire each into the
    /// graph alongside the sym source node. `sendHostedMIDI(...)`
    /// routes by MPE channel to the matching slot.
    public func loadHostedInstrument(_ descriptor: HostedAUDescriptor,
                                     completion: ((Result<Void, Error>) -> Void)? = nil) {
        unloadHostedInstrument()

        let typeCode = fourCharCode(descriptor.type)
        let subCode  = fourCharCode(descriptor.subType)
        let mfrCode  = fourCharCode(descriptor.manufacturer)
        let desc = AudioComponentDescription(
            componentType: typeCode,
            componentSubType: subCode,
            componentManufacturer: mfrCode,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        var lookupDesc = desc
        if AudioComponentFindNext(nil, &lookupDesc) == nil {
            let label = "\(descriptor.type)/\(descriptor.subType)/\(descriptor.manufacturer)"
            let msg = "AU not found: \(label)"
            NSLog("Starpad: \(msg)")
            DispatchQueue.main.async {
                self.hostedInstrumentStatus = msg
                completion?(.failure(NSError(domain: "Starpad", code: -2,
                                             userInfo: [NSLocalizedDescriptionKey: msg])))
            }
            return
        }

        let slotCount = Config.maxHostedPolyVoices
        DispatchQueue.main.async {
            self.hostedInstrumentStatus = "loading \(descriptor.subType) (0/\(slotCount))…"
        }
        NSLog("Starpad: loading \(slotCount)× AU \(descriptor.type)/\(descriptor.subType)/\(descriptor.manufacturer)")

        // Prime slot arrays BEFORE any async instantiate returns, so
        // `isHostingInstrument` flips to true atomically. The inline effect
        // pulls `hostedDriveTap` directly — no ring to allocate; the model runs
        // on silence until the AUs come up and SWAM starts sounding.
        lock.lock()
        hostedInstruments = Array(repeating: nil, count: slotCount)
        hostedMIDIBlocks = Array(repeating: nil, count: slotCount)
        hostedSlotStates = Array(repeating: HostedSlotState(channel: nil, note: nil, age: 0), count: slotCount)
        hostedChannelToSlot = [:]
        hostedChannelNote = [:]
        hostedChannelBend = [:]
        hostedChannelExpr = [:]
        heldChannelOrder = []
        sarangiEngine?.reset()
        hostedAgeCounter = 0
        hostedLoadDescriptor = descriptor
        hostedLoadTotal = slotCount
        hostedLoadCompleted = 0
        hostedLoadSuccess = 0
        hostedLoadCompletion = completion
        lock.unlock()
        storeMeter((0, 0, false))

        for slot in 0..<slotCount {
            AVAudioUnit.instantiate(with: desc, options: []) { [weak self] au, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.handleHostedSlotInstantiated(slot: slot,
                                                      au: au,
                                                      error: error,
                                                      descriptor: descriptor)
                }
            }
        }
    }

    private func handleHostedSlotInstantiated(slot: Int,
                                              au: AVAudioUnit?,
                                              error: Error?,
                                              descriptor: HostedAUDescriptor) {
        lock.lock()
        let isCurrent = (hostedLoadDescriptor == descriptor)
        lock.unlock()
        guard isCurrent else { return }

        if let error {
            NSLog("Starpad: AU slot \(slot) failed: \(error.localizedDescription)")
        } else if let au {
            attachHostedInstance(au, slot: slot)
            lock.lock()
            hostedLoadSuccess += 1
            lock.unlock()
        }

        lock.lock()
        hostedLoadCompleted += 1
        let total = hostedLoadTotal
        let completed = hostedLoadCompleted
        let success = hostedLoadSuccess
        let completion = hostedLoadCompletion
        lock.unlock()

        let progressMsg = "loading \(descriptor.subType) (\(completed)/\(total))…"
        DispatchQueue.main.async { self.hostedInstrumentStatus = progressMsg }

        guard completed == total else { return }
        finalizeHostedLoad(descriptor: descriptor,
                           successCount: success,
                           totalCount: total,
                           completion: completion)
    }

    private func finalizeHostedLoad(descriptor: HostedAUDescriptor,
                                    successCount: Int,
                                    totalCount: Int,
                                    completion: ((Result<Void, Error>) -> Void)?) {
        engine.prepare()
        resetHostedInstrumentControllers()
        installHostedParameterMirror()

        lock.lock()
        hostedLoadDescriptor = nil
        hostedLoadCompletion = nil
        lock.unlock()

        let failures = totalCount - successCount
        let failSuffix = failures > 0 ? ", \(failures) failed" : ""
        let runStatus = engine.isRunning ? "engine running" : "engine NOT running"
        let status = "loaded \(descriptor.subType) (\(successCount)/\(totalCount)\(failSuffix)) — \(runStatus)"
        NSLog("Starpad: \(status)")
        DispatchQueue.main.async { self.hostedInstrumentStatus = status }
        #if os(macOS)
        logAudioLatencyReport("after SWAM load")
        #endif

        if successCount > 0 {
            completion?(.success(()))
        } else {
            completion?(.failure(NSError(
                domain: "Starpad", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "All AU instances failed to load"])))
        }
    }

    /// Unload all currently-hosted AU instances. Safe to call when
    /// nothing is loaded.
    public func unloadHostedInstrument() {
        lock.lock()
        let existing = hostedInstruments
        hostedInstruments = []
        hostedMIDIBlocks = []
        hostedSlotStates = []
        hostedChannelToSlot = [:]
        hostedChannelNote = [:]
        hostedChannelBend = [:]
        hostedChannelExpr = [:]
        heldChannelOrder = []
        sarangiEngine?.reset()
        hostedAgeCounter = 0
        hostedLoadDescriptor = nil
        hostedLoadCompletion = nil
        let token = hostedParamObserverToken
        let primarySlot = hostedParamObserverPrimarySlot
        hostedParamObserverToken = nil
        hostedParamObserverPrimarySlot = nil
        lock.unlock()
        storeMeter((0, 0, false))

        if let token, let primarySlot, primarySlot < existing.count,
           let primary = existing[primarySlot] {
            primary.auAudioUnit.parameterTree?.removeParameterObserver(token)
        }

        // Detaching the SWAM instances leaves `hostedDriveTap` with no inputs;
        // it renders silence and the inline effect pulls silence (safe). No tap
        // to remove — the model pulls hostedDriveTap live.
        for inst in existing {
            guard let inst else { continue }
            engine.disconnectNodeOutput(inst)
            engine.detach(inst)
        }
        DispatchQueue.main.async {
            self.hostedInstrumentStatus = "no instrument"
            self.hostedMIDIEventCount = 0
            self.hostedOutputPeak = 0
        }
    }

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

    /// Snapshot of the sympathetic bank + recent drive for the Live-tab harmonic
    /// display. Copies state under `lock` (pure copies — the DFT runs in the
    /// caller, off-lock), then stamps the current played pitch from the meter.
    /// `lock` and `meterLock` are taken sequentially, never nested. Poll at
    /// ≤30 Hz; only call while the Live tab is visible.
    public func sarangiBankSnapshot() -> BankRawSnapshot? {
        lock.lock()
        let snap = sarangiEngine?.bankRawSnapshot()
        lock.unlock()
        guard var snap else { return nil }
        let r = performanceReadout()                 // its own meterLock
        snap.playedActive = r.active && r.pitchHz > 0
        snap.playedF0 = r.pitchHz
        return snap
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

    /// Push a 3-byte MIDI message into one of the hosted AUs.
    public func sendHostedMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let channel = UInt8(status & 0x0F)
        let statusHi = status & 0xF0

        // Sitar base voice: notes drive the plucked model, not a SWAM AU.
        if useSitarBaseVoice {
            routeSitarBaseVoiceMIDI(channel: channel, statusHi: statusHi,
                                    data1: data1, data2: data2)
            return
        }

        // Sarangi-model base voice: notes drive the fitted ViolinSynth source.
        if useSarangiModelVoice {
            routeSarangiModelMIDI(channel: channel, statusHi: statusHi,
                                  data1: data1, data2: data2)
            return
        }

        if channel == 0 {
            // Channel-0 (non-MPE controller on MIDI channel 1, or mono mode):
            // track the note/bend for MPE bookkeeping, then forward to SWAM. The
            // model derives its excitation directly from SWAM's audio, so there
            // is no per-note coupling to push anymore.
            let hi0 = status & 0xF0
            lock.lock()
            if hi0 == 0x90 && data2 > 0 {
                hostedChannelNote[0] = data1
                hostedChannelBend[0] = 8192
                heldChannelOrder.removeAll { $0 == 0 }
                heldChannelOrder.append(0)
            } else if hi0 == 0x80 || (hi0 == 0x90 && data2 == 0) {
                hostedChannelBend.removeValue(forKey: 0)
                hostedChannelNote.removeValue(forKey: 0)
                hostedChannelExpr.removeValue(forKey: 0)
                heldChannelOrder.removeAll { $0 == 0 }
            } else if hi0 == 0xE0 {
                let bend = (Int(data2) << 7) | Int(data1)
                if hostedChannelNote[0] != nil { hostedChannelBend[0] = bend }
            } else if hi0 == 0xB0 && data1 == 11 {
                hostedChannelExpr[0] = data2
            }
            let snap = meterSnapshotLocked()
            lock.unlock()
            storeMeter(snap)
            broadcastHostedMIDI(status: status, data1: data1, data2: data2, length: 3)
            return
        }
        if statusHi == 0xB0 {
            switch data1 {
            case 100, 101, 6, 38, 121:
                broadcastHostedMIDI(status: status, data1: data1, data2: data2, length: 3)
                return
            case 123:
                lock.lock()
                hostedChannelToSlot.removeAll(keepingCapacity: true)
                for i in 0..<hostedSlotStates.count {
                    hostedSlotStates[i].channel = nil
                    hostedSlotStates[i].note = nil
                }
                hostedChannelNote.removeAll(keepingCapacity: true)
                hostedChannelBend.removeAll(keepingCapacity: true)
                hostedChannelExpr.removeAll(keepingCapacity: true)
                heldChannelOrder.removeAll(keepingCapacity: true)
                lock.unlock()
                storeMeter((0, 0, false))
                broadcastHostedMIDI(status: status, data1: data1, data2: data2, length: 3)
                return
            default:
                break
            }
        }

        lock.lock()
        let slot: Int?
        // Any note that got evicted from its slot by this allocation —
        // emitted as a Note Off to the AU below so the AU doesn't keep
        // the displaced note held internally on its old channel.
        var displacedNoteOff: (channel: UInt8, note: UInt8)? = nil
        if statusHi == 0x90 && data2 > 0 {
            let result = allocateHostedSlotLocked(forChannel: channel, newNote: data1)
            slot = result?.slot
            displacedNoteOff = result?.displaced
            hostedChannelNote[channel] = data1
            // New note starts at centre bend; the surface's Note On sends the
            // initial bend immediately after.
            hostedChannelBend[channel] = 8192
            // The newest Note On becomes the voice the Live readout tracks.
            heldChannelOrder.removeAll { $0 == channel }
            heldChannelOrder.append(channel)
        } else if statusHi == 0x80 || (statusHi == 0x90 && data2 == 0) {
            slot = releaseHostedSlotLocked(forChannel: channel)
            hostedChannelBend.removeValue(forKey: channel)
            hostedChannelNote.removeValue(forKey: channel)
            hostedChannelExpr.removeValue(forKey: channel)
            heldChannelOrder.removeAll { $0 == channel }
        } else if statusHi == 0xE0 {
            // Pitch bend: 14-bit value = (MSB<<7)|LSB. Tracked per channel for
            // MPE bookkeeping; forwarded to SWAM below.
            let bend = (Int(data2) << 7) | Int(data1)
            if hostedChannelNote[channel] != nil { hostedChannelBend[channel] = bend }
            slot = hostedChannelToSlot[channel]
        } else if statusHi == 0xB0 && data1 == 11 {
            // Expression (loudness). Tracked for the Live readout; forwarded
            // to SWAM below like any other CC.
            hostedChannelExpr[channel] = data2
            slot = hostedChannelToSlot[channel]
        } else {
            slot = hostedChannelToSlot[channel]
        }
        let block: AUScheduleMIDIEventBlock? = {
            guard let s = slot, s < hostedMIDIBlocks.count else { return nil }
            return hostedMIDIBlocks[s]
        }()
        let meterSnap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(meterSnap)

        guard let block else { return }
        // Emit the displaced Note Off FIRST so the AU's internal voice
        // table releases the prior note before the new Note On lands on
        // the same slot. Without this, monophonic-per-channel AUs (e.g.
        // SWAM Viola) keep accumulating held notes across channels and
        // resume them when newer notes release — classic stuck-note
        // behavior, especially at poly=1 where every Note On steals.
        if let off = displacedNoteOff {
            block(AUEventSampleTimeImmediate, 0, 3,
                  [0x80 | off.channel, off.note, 0])
        }
        block(AUEventSampleTimeImmediate, 0, 3, [status, data1, data2])
        bumpHostedMIDICount()
    }

    /// Two-byte variant for Channel Pressure (0xDx) and Program Change
    /// (0xCx).
    public func sendHostedMIDI2(status: UInt8, data1: UInt8) {
        let channel = UInt8(status & 0x0F)

        // Sitar / sarangi-model base voices ignore channel pressure / program change.
        if useSitarBaseVoice || useSarangiModelVoice { return }

        if channel == 0 {
            broadcastHostedMIDI(status: status, data1: data1, data2: 0, length: 2)
            return
        }

        lock.lock()
        let slot = hostedChannelToSlot[channel]
        let block: AUScheduleMIDIEventBlock? = {
            guard let s = slot, s < hostedMIDIBlocks.count else { return nil }
            return hostedMIDIBlocks[s]
        }()
        lock.unlock()

        guard let block else { return }
        block(AUEventSampleTimeImmediate, 0, 2, [status, data1])
        bumpHostedMIDICount()
    }

    // MARK: - Sitar base-voice note bridge

    /// Route one MPE message to the base-voice sitar model (used instead of the
    /// SWAM path when `useSitarBaseVoice`). Note On plucks a pooled string tuned
    /// to the note; Pitch Bend glides it; Note Off frees the string (it rings
    /// out naturally). Also updates the `hostedChannel*` bookkeeping so the Live
    /// readout tracks pitch/expression exactly as it does for SWAM.
    private func routeSitarBaseVoiceMIDI(channel: UInt8, statusHi: UInt8,
                                         data1: UInt8, data2: UInt8) {
        lock.lock()
        if statusHi == 0x90 && data2 > 0 {
            hostedChannelNote[channel] = data1
            hostedChannelBend[channel] = 8192
            heldChannelOrder.removeAll { $0 == channel }
            heldChannelOrder.append(channel)
            let s = allocateSitarStringLocked(forChannel: channel)
            voiceSitar.clearString(s)                      // fresh — no glissando tail
            voiceSitar.retuneString(s, f0: sitarF0(note: data1, bend14: 8192))
            voiceSitar.pluck(string: s, velocity: Double(data2) / 127.0)
        } else if statusHi == 0x80 || (statusHi == 0x90 && data2 == 0) {
            // Free the string; let it ring out (plucked string, natural decay).
            sitarVoiceForChannel.removeValue(forKey: channel)
            hostedChannelNote.removeValue(forKey: channel)
            hostedChannelBend.removeValue(forKey: channel)
            hostedChannelExpr.removeValue(forKey: channel)
            heldChannelOrder.removeAll { $0 == channel }
        } else if statusHi == 0xE0 {
            let bend = (Int(data2) << 7) | Int(data1)
            if let note = hostedChannelNote[channel] {
                hostedChannelBend[channel] = bend
                if let s = sitarVoiceForChannel[channel] {
                    voiceSitar.retuneString(s, f0: sitarF0(note: note, bend14: bend))
                }
            }
        } else if statusHi == 0xB0 {
            if data1 == 11 { hostedChannelExpr[channel] = data2 }
            else if data1 == 123 {                          // all-notes-off
                sitarVoiceForChannel.removeAll(keepingCapacity: true)
                hostedChannelNote.removeAll(keepingCapacity: true)
                hostedChannelBend.removeAll(keepingCapacity: true)
                hostedChannelExpr.removeAll(keepingCapacity: true)
                heldChannelOrder.removeAll(keepingCapacity: true)
                voiceSitar.clearState()
            }
        }
        let snap = meterSnapshotLocked()
        lock.unlock()
        storeMeter(snap)
        bumpHostedMIDICount()
    }

    /// Pick a sitar string for a channel: reuse its existing one, else a free
    /// string, else steal the oldest. `lock` held.
    private func allocateSitarStringLocked(forChannel ch: UInt8) -> Int {
        if let s = sitarVoiceForChannel[ch] { sitarVoiceCounter &+= 1; sitarStringAge[s] = sitarVoiceCounter; return s }
        let used = Set(sitarVoiceForChannel.values)
        var chosen = (0..<TanpuraModel.stringCount).first { !used.contains($0) }
        if chosen == nil {
            // Steal the oldest string and unmap whoever held it.
            let victim = (0..<TanpuraModel.stringCount).min { sitarStringAge[$0] < sitarStringAge[$1] } ?? 0
            if let owner = sitarVoiceForChannel.first(where: { $0.value == victim })?.key {
                sitarVoiceForChannel.removeValue(forKey: owner)
            }
            chosen = victim
        }
        let s = chosen ?? 0
        sitarVoiceCounter &+= 1
        sitarStringAge[s] = sitarVoiceCounter
        sitarVoiceForChannel[ch] = s
        return s
    }

    /// MIDI note + 14-bit bend → Hz, using the app's wide bend range.
    private func sitarF0(note: UInt8, bend14: Int) -> Double {
        let semis = Double(note) + (Double(bend14 - 8192) / 8192.0) * Config.midiPitchBendRange
        return 440.0 * pow(2.0, (semis - 69.0) / 12.0)
    }

    /// Enable/disable the sitar as the base voice (excitation into the sarangi
    /// model). When enabling, the voice pool + ringing state are reset so a
    /// stale note can't sound. Load/unload of the SWAM AU is the caller's job.
    public func setSitarBaseVoiceEnabled(_ on: Bool) {
        lock.lock()
        useSitarBaseVoice = on
        sitarVoiceForChannel.removeAll(keepingCapacity: true)
        hostedChannelNote.removeAll(keepingCapacity: true)
        hostedChannelBend.removeAll(keepingCapacity: true)
        hostedChannelExpr.removeAll(keepingCapacity: true)
        heldChannelOrder.removeAll(keepingCapacity: true)
        voiceSitar.clearState()
        lock.unlock()
        storeMeter((0, 0, false))
    }

    /// Push the sitar timbre to the base-voice model (shares the Sitar tab's
    /// `TanpuraParams.sitar`-derived params). Structural — recomputes coeffs.
    public func setSitarBaseVoiceParams(_ params: TanpuraParams) {
        lock.lock()
        voiceSitar.setParams(params)
        lock.unlock()
    }

    /// Whether the sitar is currently the base voice.
    public var isSitarBaseVoice: Bool {
        lock.lock(); defer { lock.unlock() }
        return useSitarBaseVoice
    }

    // MARK: - Sarangi-model base-voice bridge (the String physics instrument)

    /// Route one MPE message to the String source (used instead of the SWAM
    /// path when `useSarangiModelVoice`). The `BowControlMapper` allocates
    /// gut-string slots physically (poly chords, mono meend on a single
    /// line) with per-channel MPE pitch bend; CCs 11/1/74/2/75 drive the
    /// expr/press/pos/tilt axes; aftertouch is player vibrato. Also updates
    /// the `hostedChannel*` bookkeeping so the Live readout tracks
    /// pitch/expression exactly as it does for SWAM.
    private func routeSarangiModelMIDI(channel: UInt8, statusHi: UInt8,
                                       data1: UInt8, data2: UInt8) {
        lock.lock()
        let mapper = stringVoiceSource?.mapper
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
        mapper?.midi(statusHi | channel, data1, data2)
        bumpHostedMIDICount()
    }

    /// Enable/disable the String physics instrument as the base voice. On
    /// first enable the source node is created and connected DIRECTLY to
    /// `symGain` (bypassing the coupled network — the kernel carries its own
    /// taraf/body/room), and the `BowEngine` is built off-main from the
    /// current tonic + tarab strings. Load/unload of the SWAM AU is the
    /// caller's job. Returns false when `bowed_string.json` is missing.
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
        hostedChannelNote.removeAll(keepingCapacity: true)
        hostedChannelBend.removeAll(keepingCapacity: true)
        hostedChannelExpr.removeAll(keepingCapacity: true)
        heldChannelOrder.removeAll(keepingCapacity: true)
        lock.unlock()
        if on { rebuildStringVoice(tonic: tonic, strings: strings) }
        storeMeter((0, 0, false))
        return true
    }

    /// Whether the String physics instrument is currently the base voice.
    public var isSarangiModelVoice: Bool {
        lock.lock(); defer { lock.unlock() }
        return useSarangiModelVoice
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

    /// Build a fresh String `BowEngine` for the tuning (tonic + tarab rows)
    /// off the main thread and publish it lock-free. The long-lived mapper
    /// keeps held notes/axes across the swap; a newer build supersedes any
    /// in-flight older one. Called on voice enable and on every structural
    /// tarab/tonic change while the String voice is active.
    private func rebuildStringVoice(tonic: Double, strings: [ResolvedString]) {
        guard let src = stringVoiceSource else { return }
        stringBuildGen += 1
        let gen = stringBuildGen
        let overrides = stringVoiceOverrides
        let mapper = src.mapper
        stringBuildQueue.async { [weak self] in
            let engine = StringVoiceSource.buildEngine(tonicHz: tonic,
                                                      strings: strings,
                                                      mapper: mapper,
                                                      overrides: overrides)
            DispatchQueue.main.async {
                guard let self, gen == self.stringBuildGen else { return }
                if engine == nil {
                    NSLog("Starpad: String engine build failed (bowed_string.json missing?)")
                }
                self.stringVoiceSource?.setEngine(engine)
            }
        }
    }

    /// Re-apply the String-editor / audition overrides with a rebuild (the
    /// artifact scalars are baked into the tables/kernel at build time).
    public func setStringVoiceOverrides(_ overrides: [String: Double]) {
        stringVoiceOverrides = overrides
        lock.lock()
        let on = useSarangiModelVoice
        let tonic = lastSarangiTonic
        let strings = lastSarangiStrings
        lock.unlock()
        if on { rebuildStringVoice(tonic: tonic, strings: strings) }
    }

    private func broadcastHostedMIDI(status: UInt8, data1: UInt8, data2: UInt8, length: Int) {
        lock.lock()
        let blocks = hostedMIDIBlocks
        lock.unlock()
        let bytes: [UInt8] = length == 3 ? [status, data1, data2] : [status, data1]
        for block in blocks {
            guard let block else { continue }
            block(AUEventSampleTimeImmediate, 0, length, bytes)
        }
        bumpHostedMIDICount()
    }

    /// Result of a Note On's slot allocation. `slot` is the AU-instance
    /// index the new note should be sent to; `displaced`, when non-nil,
    /// is a `(channel, note)` pair that must receive a Note Off first
    /// so the AU doesn't keep the previous note held in its internal
    /// voice table — see the call site for the full rationale.
    private struct HostedAllocResult {
        let slot: Int
        let displaced: (channel: UInt8, note: UInt8)?
    }

    /// Allocate a slot for a Note On of `newNote` on `ch`. Lock must be
    /// held by caller. Returns the chosen slot plus the (channel, note)
    /// to Note-Off-first if the allocation evicted a prior held note —
    /// happens both when stealing the LRU slot from another channel and
    /// when the same channel re-uses its slot for a different note
    /// number without a preceding Note Off.
    private func allocateHostedSlotLocked(forChannel ch: UInt8,
                                          newNote: UInt8) -> HostedAllocResult? {
        guard !hostedSlotStates.isEmpty else { return nil }
        if let existing = hostedChannelToSlot[ch] {
            var displaced: (channel: UInt8, note: UInt8)? = nil
            if let oldNote = hostedSlotStates[existing].note, oldNote != newNote {
                displaced = (channel: ch, note: oldNote)
            }
            hostedAgeCounter &+= 1
            hostedSlotStates[existing].age = hostedAgeCounter
            hostedSlotStates[existing].note = newNote
            return HostedAllocResult(slot: existing, displaced: displaced)
        }
        if let idleIdx = hostedSlotStates.firstIndex(where: { $0.channel == nil }) {
            hostedAgeCounter &+= 1
            hostedSlotStates[idleIdx] = HostedSlotState(
                channel: ch, note: newNote, age: hostedAgeCounter)
            hostedChannelToSlot[ch] = idleIdx
            return HostedAllocResult(slot: idleIdx, displaced: nil)
        }
        var oldestIdx = 0
        var oldestAge = hostedSlotStates[0].age
        for i in 1..<hostedSlotStates.count where hostedSlotStates[i].age < oldestAge {
            oldestIdx = i
            oldestAge = hostedSlotStates[i].age
        }
        var displaced: (channel: UInt8, note: UInt8)? = nil
        if let oldChannel = hostedSlotStates[oldestIdx].channel {
            hostedChannelToSlot.removeValue(forKey: oldChannel)
            if let oldNote = hostedSlotStates[oldestIdx].note {
                displaced = (channel: oldChannel, note: oldNote)
            }
        }
        hostedAgeCounter &+= 1
        hostedSlotStates[oldestIdx] = HostedSlotState(
            channel: ch, note: newNote, age: hostedAgeCounter)
        hostedChannelToSlot[ch] = oldestIdx
        return HostedAllocResult(slot: oldestIdx, displaced: displaced)
    }

    private func releaseHostedSlotLocked(forChannel ch: UInt8) -> Int? {
        guard let slot = hostedChannelToSlot.removeValue(forKey: ch) else { return nil }
        guard slot < hostedSlotStates.count else { return nil }
        hostedSlotStates[slot].channel = nil
        hostedSlotStates[slot].note = nil
        return slot
    }

    private func bumpHostedMIDICount() {
        let coalesced = (hostedMIDIEventCount + 1) % 32 == 0
        DispatchQueue.main.async {
            self.hostedMIDIEventCount &+= 1
            _ = coalesced
        }
    }

    /// Pack a 4-character ASCII string into a UInt32 for the
    /// AudioComponent APIs.
    private func fourCharCode(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        let bytes = Array(s.utf8.prefix(4))
        for b in bytes {
            v = (v << 8) | UInt32(b)
        }
        for _ in bytes.count..<4 {
            v <<= 8
        }
        return v
    }

    private func attachHostedInstance(_ au: AVAudioUnit, slot: Int) {
        engine.attach(au)
        let auOutputFormat = au.outputFormat(forBus: 0)
        NSLog("Starpad: AU slot \(slot) output format — sr=\(auOutputFormat.sampleRate) ch=\(auOutputFormat.channelCount)")
        engine.connect(au, to: hostedDriveTap, format: auOutputFormat)

        // Restore the preset's full document state FIRST (carries SWAM's opaque
        // MIDI CC assignments — not reachable as AU parameters). Setting this
        // can rebuild the AU's parameter tree, so it must precede both the
        // param-defaults pass and render-resource allocation.
        if let state = hostedAUFullState {
            au.auAudioUnit.fullStateForDocument = state
        }

        try? au.auAudioUnit.allocateRenderResources()

        // Apply the preset's hosted-AU parameter defaults (SWAM bow timbre +
        // vibrato off) now that the parameter tree + render resources exist.
        // These run AFTER the full-state restore so the values we tune in code
        // win over whatever the captured blob held.
        if let tree = au.auAudioUnit.parameterTree {
            for (ident, val) in hostedAUParameterDefaults {
                for p in tree.allParameters where p.identifier == ident {
                    p.setValue(val, originator: nil)
                }
            }
        }

        let midiBlock = au.auAudioUnit.scheduleMIDIEventBlock
        au.reset()
        lock.lock()
        if slot < hostedInstruments.count {
            hostedInstruments[slot] = au
            hostedMIDIBlocks[slot] = midiBlock
        }
        lock.unlock()
        // SWAM is now connected into `hostedDriveTap`, whose output the inline
        // `sarangiEffect` pulls — no tap to install. `preReverbMixer` is already
        // at unity (set in setupAudio); the hosted-AU path feeds the model, not
        // the room.
    }

    private func installHostedParameterMirror() {
        lock.lock()
        var primarySlot: Int? = nil
        for (i, inst) in hostedInstruments.enumerated() where inst != nil {
            primarySlot = i
            break
        }
        let snapshot = hostedInstruments
        lock.unlock()
        guard let primarySlot,
              let primary = snapshot[primarySlot],
              let tree = primary.auAudioUnit.parameterTree else { return }

        let token = tree.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.hostedInstruments
            let primaryIdx = self.hostedParamObserverPrimarySlot
            self.lock.unlock()
            for (i, inst) in snapshot.enumerated() {
                guard i != primaryIdx, let inst,
                      let p = inst.auAudioUnit.parameterTree?.parameter(withAddress: address)
                else { continue }
                p.setValue(value, originator: nil)
            }
        })

        lock.lock()
        hostedParamObserverToken = token
        hostedParamObserverPrimarySlot = primarySlot
        lock.unlock()
    }

    /// Seed every loaded instance with sensible per-channel defaults
    /// (CC123, CC121, RPN bend range, centered bend, expression mid,
    /// filter mid). Sent via broadcast so every instance receives
    /// regardless of channel allocation state.
    public func resetHostedInstrumentControllers() {
        lock.lock()
        let n = hostedMIDIBlocks.count
        lock.unlock()
        guard n > 0 else { return }
        let bendRange = UInt8(max(0, min(127, Int(Config.midiPitchBendRange))))
        for ch in UInt8(0)...UInt8(15) {
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 123, data2: 0,   length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 121, data2: 0,   length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 101, data2: 0,   length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 100, data2: 0,   length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 6,   data2: bendRange, length: 3)
            broadcastHostedMIDI(status: 0xE0 | ch, data1: 0x00, data2: 0x40, length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 11,  data2: 100, length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 71,  data2: 64,  length: 3)
            broadcastHostedMIDI(status: 0xB0 | ch, data1: 74,  data2: 64,  length: 3)
        }
    }

    // MARK: - Hosted AU parameter access (SWAM Viola vibrato/resonance/etc.)

    /// Enumerate the primary hosted AU's parameter tree: identifier, address,
    /// range, current value, unit. Used to discover SWAM Viola's controllable
    /// parameters (vibrato, bow pressure, resonance, …) for programmatic
    /// tuning — far more reaching than a post-AU EQ. Returns [] if no AU.
    public func hostedParameterDump() -> [[String: Any]] {
        lock.lock(); let snapshot = hostedInstruments; lock.unlock()
        guard let au = snapshot.compactMap({ $0 }).first,
              let tree = au.auAudioUnit.parameterTree else { return [] }
        return tree.allParameters.map { p in
            [
                "identifier": p.identifier,
                "address": p.address,
                "displayName": p.displayName,
                "min": p.minValue,
                "max": p.maxValue,
                "value": p.value,
                "unit": p.unit.rawValue,
            ]
        }
    }

    /// Install the preset's hosted-AU parameter defaults (identifier → value).
    /// Stored for slots that instantiate later, and applied immediately to any
    /// already-loaded instance. Set this BEFORE loading the hosted AU so each
    /// slot picks it up on attach.
    public func setHostedAUParameterDefaults(_ params: [String: Float]) {
        lock.lock()
        hostedAUParameterDefaults = params
        lock.unlock()
        for (ident, val) in params {
            setHostedParameter(identifier: ident, value: val)
        }
    }

    /// Install the preset's hosted-AU full document state (a serialized binary
    /// plist of `fullStateForDocument`). Stored for slots that instantiate
    /// later, and applied immediately to any already-loaded instance. Carries
    /// SWAM's opaque encoded state (incl. MIDI CC assignments). Pass `nil` to
    /// clear. Set this BEFORE loading the hosted AU so each slot picks it up on
    /// attach. The per-slot restore in `attachHostedInstance` runs before the
    /// parameter defaults, so `setHostedAUParameterDefaults` still overrides any
    /// parameter values the blob carried.
    public func setHostedAUFullState(_ data: Data?) {
        let dict = data.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        } as? [String: Any]
        lock.lock()
        hostedAUFullState = dict
        let snapshot = hostedInstruments
        lock.unlock()
        guard let dict else { return }
        for inst in snapshot {
            inst?.auAudioUnit.fullStateForDocument = dict
        }
    }

    /// Capture the primary hosted AU's current `fullStateForDocument` as a
    /// serialized binary plist — the inverse of `setHostedAUFullState`. Used to
    /// snapshot a hand-configured SWAM (e.g. after assigning MIDI CCs in its UI)
    /// so the state can be baked into a preset. Returns nil if no AU is loaded.
    public func captureHostedAUFullState() -> Data? {
        lock.lock(); let snapshot = hostedInstruments; lock.unlock()
        guard let au = snapshot.compactMap({ $0 }).first,
              let state = au.auAudioUnit.fullStateForDocument else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: state, format: .binary, options: 0)
    }

    /// Set a hosted-AU parameter (by identifier) on every loaded instance, so
    /// all polyphony slots stay in sync. Returns true if any instance had it.
    @discardableResult
    public func setHostedParameter(identifier: String, value: Float) -> Bool {
        lock.lock(); let snapshot = hostedInstruments; lock.unlock()
        var hit = false
        for inst in snapshot {
            guard let inst, let tree = inst.auAudioUnit.parameterTree else { continue }
            for p in tree.allParameters where p.identifier == identifier {
                p.setValue(value, originator: nil)
                hit = true
            }
        }
        return hit
    }

    /// Effective hardware sample rate of the current output device.
    public var outputSampleRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    // MARK: - Sarangi model configuration

    /// Build a fresh `SarangiEngine` from the current model state and swap it in
    /// (a STRUCTURAL change — raga/tonic/strings/filter-coefficient params). The
    /// build (web combs + modal body + radiation FIR) runs OUTSIDE the lock; only
    /// the pointer swap is under it. Callers debounce rapid slider drags in the
    /// UI. `coupled` is REQUIRED for sound since the v57-only simplification —
    /// the engine renders only the passive junction (silent when unarmed).
    public func rebuildSarangi(params: SarangiParams, strings: [ResolvedString],
                               tonic: Double, fx: FXRack,
                               eqBands: [VoiceEQBand] = [],
                               groups: [StringGroup] = [],
                               coupled: CoupledConfig? = nil) {
        let engine = SarangiEngine(params: params, strings: strings,
                                   tonic: tonic, sr: Config.sampleRate,
                                   eqBands: eqBands, coupled: coupled, fx: fx,
                                   groups: groups)
        engine.beginBuffer()                        // scalars (incl. live FX) set by init
        if !engine.isArmed {
            print("[AudioEngine] sarangi engine UNARMED — sarangi_coupled.json missing or not passive; output will be silent")
        }
        lockAndMeasure()
        sarangiEngine = engine
        lastSarangiStrings = strings
        lastSarangiT60Scale = params["B_t60_scale"]
        lastSarangiTonic = tonic
        let armModel = useSarangiModelVoice
        lock.unlock()
        // The String voice's kernel taraf tracks the same tuning as the bank
        // (rebuilt off-main; the mapper keeps held notes across the swap).
        if armModel { rebuildStringVoice(tonic: tonic, strings: strings) }
    }

    /// Apply a live (non-structural) scalar change — gains/mixes that need no
    /// filter redesign. Rebuilds `LiveScalars` from params + the live FX fields.
    /// No-op until a model has been built.
    public func applySarangiScalars(_ params: SarangiParams, fx: FXRack) {
        lockAndMeasure()
        var s = LiveScalars(params); s.applyFX(fx)
        sarangiEngine?.scalars = s
        lock.unlock()
    }

    /// Apply only the live FX fields (enabled + reverb mix/width per stage) —
    /// used when an FX toggle/mix slider moves.
    public func applySarangiFXScalars(_ fx: FXRack) {
        lockAndMeasure()
        sarangiEngine?.scalars.applyFX(fx)
        lock.unlock()
    }

    /// Apply a live FILTER edit — the graphical-EQ bands + the stage low-pass
    /// (cutoff/resonance) — by swapping the biquad coefficients in place on the
    /// running engine (no rebuild, click-free; see `VoiceFX.updateFilters`). This
    /// is the hot path for dragging EQ points. No-op until a model exists.
    public func applySarangiFXFilters(_ fx: FXRack) {
        lockAndMeasure()
        sarangiEngine?.setVoiceFXFilters(fx)
        lock.unlock()
    }

    /// Snapshot of the pre-EQ FX signals for the live FX-stage spectrum
    /// display. Copies the rings under `lock` (pure copies — the broadband FFT
    /// runs in the caller, off-lock), then releases. Poll at ≤30 Hz, only while an
    /// FX stage's spectrum is visible. Returns nil when no model is configured.
    public func sarangiFXSpectrumSnapshot() -> FXSpectrumSnapshot? {
        lock.lock()
        let snap = sarangiEngine?.fxSpectrumRawSnapshot()
        lock.unlock()
        return snap
    }

    /// Calibration gain lifting SWAM's raw output to the model's expected drive
    /// level (see `sarangiDriveGain`). Higher = louder + harder-ringing sym.
    public func setSarangiDriveGain(_ g: Double) {
        lockAndMeasure(); sarangiDriveGain = max(0, g); lock.unlock()
    }

    /// True iff a sarangi model is configured (the source node has a voice).
    public var hasSarangiModel: Bool {
        lock.lock(); defer { lock.unlock() }
        return sarangiEngine != nil
    }

    // MARK: - Viola body formants (hosted-AU path EQ)

    /// Enable/disable the sarangi skin-body formant stage on the
    /// hosted-AU path (flips bypass on all four parametric bands).
    public func setViolaBodyEnabled(_ enabled: Bool) {
        for band in violaBodyEQ.bands {
            band.bypass = !enabled
        }
    }

    /// Configure one of the four viola body bands. `widthOct` is the
    /// parametric bandwidth in octaves (AVAudioUnitEQ's native unit).
    public func setViolaBodyBand(_ index: Int, freq: Double,
                                 gainDB: Double, widthOct: Double) {
        guard index >= 0 && index < violaBodyEQ.bands.count else { return }
        let band = violaBodyEQ.bands[index]
        band.frequency = Float(max(20, min(20000, freq)))
        band.gain = Float(max(-24, min(24, gainDB)))
        band.bandwidth = Float(max(0.05, min(5.0, widthOct)))
    }

    // MARK: - Post-reverb shaper (final spectral envelope)

    /// Enable/disable the post-reverb spectral shaper (flips bypass on all
    /// three parametric bands).
    public func setPostReverbEnabled(_ enabled: Bool) {
        for band in postReverbEQ.bands {
            band.bypass = !enabled
        }
    }

    /// Configure one of the three post-reverb bands. `widthOct` is the
    /// parametric bandwidth in octaves.
    public func setPostReverbBand(_ index: Int, freq: Double,
                                  gainDB: Double, widthOct: Double) {
        guard index >= 0 && index < postReverbEQ.bands.count else { return }
        let band = postReverbEQ.bands[index]
        band.frequency = Float(max(20, min(20000, freq)))
        band.gain = Float(max(-24, min(24, gainDB)))
        band.bandwidth = Float(max(0.05, min(5.0, widthOct)))
    }

    /// Reset the sarangi model's internal state (bank/jawari/drone/reverb).
    /// Use as a "panic" to silence a ringing tail.
    public func clearSarangiState() {
        lockAndMeasure(); sarangiEngine?.reset(); lock.unlock()
    }

    // MARK: - Tanpura drone

    /// Swap the full tanpura parameter set (tuning, per-harmonic laws and
    /// trims, body, modulation). Cheap enough for live slider drags.
    public func setTanpuraParams(_ params: TanpuraParams) {
        tanpuraLock.lock(); tanpura.setParams(params); tanpuraLock.unlock()
    }

    /// Current tanpura parameters (read-only mirror).
    public var tanpuraParams: TanpuraParams {
        tanpuraLock.lock()
        defer { tanpuraLock.unlock() }
        return tanpura.params
    }

    /// Pluck one tanpura string (0–3); picked up at the next render block.
    public func tanpuraPluck(index: Int, velocity: Double) {
        tanpuraLock.lock()
        tanpura.pluck(string: index, velocity: velocity)
        tanpuraLock.unlock()
    }

    /// Silence the drone immediately (envelopes, noise, queued plucks).
    public func clearTanpuraState() {
        tanpuraLock.lock(); tanpura.clearState(); tanpuraLock.unlock()
    }

    // MARK: - Sitar (plucked, same model as the tanpura)

    /// Swap the full sitar parameter set. Cheap enough for live slider drags.
    public func setSitarParams(_ params: TanpuraParams) {
        sitarLock.lock(); sitar.setParams(params); sitarLock.unlock()
    }

    /// Current sitar parameters (read-only mirror).
    public var sitarParams: TanpuraParams {
        sitarLock.lock()
        defer { sitarLock.unlock() }
        return sitar.params
    }

    /// Pluck one sitar string (0–3); picked up at the next render block.
    public func sitarPluck(index: Int, velocity: Double) {
        sitarLock.lock()
        sitar.pluck(string: index, velocity: velocity)
        sitarLock.unlock()
    }

    /// Silence the sitar immediately.
    public func clearSitarState() {
        sitarLock.lock(); sitar.clearState(); sitarLock.unlock()
    }

    /// Output gain (dB) for the sitar, applied after the model's
    /// peak-normalized `masterGain`. Same EQ-makeup trick as the drone.
    public func setSitarGainDB(_ db: Float) {
        sitarGain.globalGain = max(-24, min(24, db))
    }

    deinit {
        #if os(macOS)
        restoreOutputDeviceRate()
        #endif
        engine.stop()
        sitarDriveL?.deallocate()
        sitarDriveR?.deallocate()
    }
}
