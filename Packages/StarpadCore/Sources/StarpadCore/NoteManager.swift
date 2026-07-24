import Foundation
import QuartzCore

// MARK: - Data Models

/// The state of a pitch channel's envelope.
public enum ChannelState {
    case idle       // No sound. Waiting for a touch to activate.
    case sounding   // Actively producing sound. May be gliding between pitches.
    case releasing  // All touches lifted; finishing a glide then fading out.
}

/// A pitch that the glide system must visit.
///
/// The glide system maintains an ordered queue of waypoints. The pitch moves
/// through them one at a time, using a sigmoid curve for each segment. This
/// queue-based design means every note the player touches will be heard —
/// the system speeds up as needed rather than skipping notes.
///
/// The timestamp records when the waypoint was created. Staleness (how long
/// a waypoint has been waiting in the queue) drives the physics-based speed
/// multiplier — older waypoints cause the glide to accelerate.
public struct GlideWaypoint {
    public let note: Int               // MIDI note number to glide to
    public let timestamp: TimeInterval // when this waypoint was created (CACurrentMediaTime)
}

/// A single monophonic voice with continuous pitch control.
///
/// The pitch channel tracks:
/// - The current sounding frequency (updated at 60 Hz by the glide loop)
/// - A queue of target pitches (waypoints) to visit in order
/// - Which touches are currently held and what note each maps to
///
/// All pitch changes go through the waypoint queue. There is no special-case
/// logic for staccato, ornaments, or returns — they all emerge naturally from
/// how touches add and remove waypoints.
public struct PitchChannel {
    public let index: Int
    public var state: ChannelState = .idle
    public var currentFrequency: Double = 440.0   // Hz — the actual sounding pitch right now
    public var targetFrequency: Double = 440.0    // Hz — the pitch we're currently gliding toward
    public var startFrequency: Double = 440.0     // Hz — the pitch at the start of the current glide
    public var baseNote: Int = 69                 // MIDI note used as the pitch bend origin
    public var targetNote: Int = 69               // MIDI note we're gliding toward
    public var velocity: Int = 80                 // 0-127, from accelerometer at note onset
    public var glideProgress: Double = 1.0        // 0.0 = start of glide, 1.0 = arrived at target
    public var glideDuration: Double = 0.4        // seconds for the current glide segment
    public var touchNotes: [Int: Int] = [:]       // touchId -> MIDI note (all currently held touches)
    public var midiChannel: UInt8 = 1             // MPE member channel (rotated per activation)
    /// Audio-engine bank slot driving this voice. `nil` means "same as
    /// `index`" — the natural mapping when nothing's been overridden.
    /// In mono mode, each new note may pick a different idle bank so
    /// the previous note's bank can keep decaying naturally — see the
    /// click-on-retrigger fix in `activateChannel`. The audio engine
    /// has `Config.maxPolyVoices` bank slots; we hop across them while
    /// the logical voice stays at index 0.
    public var bankIndexOverride: Int? = nil
    /// Effective audio-engine bank slot. Use this for every audioEngine
    /// call that takes a `channel:` argument.
    public var bankIndex: Int { bankIndexOverride ?? index }

    /// Queue of notes the pitch must visit in order.
    ///
    /// New notes are appended here. When the current glide finishes, the next
    /// waypoint is popped and a new glide begins. If a touch is released, its
    /// waypoints are marked as `released` (which makes the glide faster), and
    /// the remaining held note is appended as the return destination.
    public var queue: [GlideWaypoint] = []
    public var dragging: Bool = false           // true when in finger-drag mode
    public var dragTargetFreq: Double = 0       // the frequency the pitch is chasing during drag
    public var snapping: Bool = false           // true when quantizing to a note after finger stops
    public var releaseAfterSnap: Bool = false   // true when touch lifted mid-drag; release once snap converges
    public var displayNote: Int?                // the key visually under the finger (for highlighting)

    // Per-note dimension values (0..1)
    public var accelPressure: Double = 0.5      // normalized accelerometer pressure at note onset
    public var keyY: Double = 0.5              // normalized key y-position (updated on touch move)

    public var touchIds: Set<Int> { Set(touchNotes.keys) }
}

/// A snapshot of pitch state for the pitch graph display.
public struct PitchSample {
    public let timestamp: TimeInterval
    public let frequencies: [Double?]   // one per voice (up to maxPolyVoices), nil if idle
    public let draggingFlags: [Bool]    // per-voice drag state
    public let snappingFlags: [Bool]    // per-voice snap state
    public let touchNotes: [Int]        // MIDI notes of all currently held touches

    /// Convenience accessors for backward compatibility.
    public var frequency0: Double? { frequencies.indices.contains(0) ? frequencies[0] : nil }
    public var dragging: Bool { draggingFlags.contains(true) }
    public var snapping: Bool { snappingFlags.contains(true) }
}

// MARK: - NoteManager

/// Manages the monophonic pitch pipeline from touch input to audio/MIDI output.
///
/// ## Architecture
///
/// The system has three stages:
///
/// 1. **Touch input** (`touchBegan` / `touchEnded` / `touchMoved`)
///    - `touchBegan`: starts a 20ms velocity capture timer. After the timer fires,
///      the note is either activated (if idle) or queued as a glide waypoint.
///    - `touchEnded`: if other touches are still held, the held note is queued as
///      a return destination. If all touches are released, the channel enters the
///      releasing state.
///    - `touchMoved`: updates the finger position for the active touch.
///
/// 2. **Glide engine** (60 Hz timer: `glideUpdate`)
///    - Advances `glideProgress` each tick.
///    - Interpolates frequency using an asymmetric sigmoid curve in log-frequency
///      space (perceptually linear pitch).
///    - When a glide completes, pops the next waypoint from the queue.
///    - Also runs tilt-based amplitude modulation.
///
/// 3. **Output** (audio + MIDI)
///    - Audio: sets frequency and amplitude on the AudioEngine voice.
///    - MIDI: sends pitch bend and channel pressure (from tilt)
///      on the note's MPE channel.
///
/// ## Glide Queue
///
/// The waypoint queue is the core mechanism for all pitch changes. Every scenario
/// reduces to the same queue operations:
///
/// **Simple glide (play C, then E):**
/// - C activates the channel (no queue needed).
/// - E is queued. Since the channel is at rest (progress=1.0), `advanceQueue`
///   immediately starts a glide from C to E.
///
/// **Staccato ornament (hold C, tap E briefly):**
/// - C activates. E is queued → glide starts toward E.
/// - E is released while gliding. E's waypoint is marked `released` (faster glide).
///   C is appended to the queue as the return destination.
/// - Glide reaches E → pops C from queue → glides back to C.
///
/// **Fast ornament (hold C, tap E then D quickly):**
/// - C activates. E is queued → glide starts.
/// - D arrives mid-glide to E. D is queued. The current glide to E speeds up
///   (each queued item doubles the speed).
/// - Glide reaches E → pops D → glides to D.
/// - If E was released, C would also be queued as a return.
///
/// **All touches released:**
/// - Queue is cleared. If mid-glide, the glide accelerates and the channel
///   enters `.releasing` state. When the glide finishes, noteOff is sent.
///
/// ## Glide Speed
///
/// Each glide segment's duration is the **minimum** of two values:
///
/// 1. **Distance-based**: `glideTimePerSemitone × semitones` (e.g., 40ms/semitone)
///    A C→E glide (4 semitones) takes 160ms. A C→G (7 semitones) takes 280ms.
///
/// 2. **Time-gap**: the time between consecutive waypoint timestamps.
///    This caps the glide so the pitch tracks the player's tempo.
///
/// This single rule handles all cases:
/// - Slow playing → time gap is large, distance-based duration wins → smooth glide
/// - Fast ornament (C E D) → time gaps are short → glides are fast, pitch keeps up
/// - Staccato (hold C, tap E) → the return-to-C waypoint is timestamped at E's
///   release, so the gap from E to C equals the staccato hold duration
///
/// ## Velocity / Expression
///
/// - **Onset velocity**: derived from the accelerometer spike in the 20ms after
///   touch (see `fireNote`). Maps log-scale from `velocityMinG` to `velocityMaxG`.
/// - **Tilt expression**: the calibrated up/down tilt value modulates amplitude
///   continuously via `tiltVelocityMin`/`tiltVelocityMax`, sent as MIDI channel
///   pressure (MPE aftertouch).
///
/// ## MPE
///
/// Each channel activation gets a fresh MIDI channel (round-robin 1-15). This
/// ensures pitch bends on a new note don't affect reverb tails of old notes.
/// Pitch bend range is set via RPN on each channel at activation time.
public class NoteManager: ObservableObject {

    // Internal state — mutated at 60Hz but only published to SwiftUI at ~15Hz
    public var pitchChannels: [PitchChannel] = (0..<Config.maxPolyVoices).map { PitchChannel(index: $0) }

    /// Polyphonic mode toggle. When true, up to 6 simultaneous voices are supported.
    /// Persisted via UserDefaults. Toggling silences all sound via panic().
    @Published public var polyphonicMode: Bool = UserDefaults.standard.bool(forKey: "polyphonicMode") {
        didSet {
            UserDefaults.standard.set(polyphonicMode, forKey: "polyphonicMode")
            panic()
        }
    }

    /// Built-in synthesizer output toggle.
    @Published public var synthEnabled: Bool = UserDefaults.standard.object(forKey: "synthEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(synthEnabled, forKey: "synthEnabled")
        }
    }

    /// MIDI output toggle.
    @Published public var midiOutputEnabled: Bool = UserDefaults.standard.object(forKey: "midiOutputEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(midiOutputEnabled, forKey: "midiOutputEnabled")
        }
    }


    /// Indices of voices that are currently sounding or releasing.
    public var activeVoiceIndices: [Int] {
        pitchChannels.indices.filter { pitchChannels[$0].state != .idle }
    }

    /// Index of the first idle voice slot, or nil if all voices are in use.
    public var firstIdleVoiceIndex: Int? {
        pitchChannels.indices.first { pitchChannels[$0].state == .idle }
    }

    private var pitchHistoryBuffer: [PitchSample] = []
    private var pitchHistoryIndex: Int = 0

    /// Ordered pitch history (oldest first) for the graph display.
    public var pitchHistory: [PitchSample] {
        guard pitchHistoryBuffer.count >= Config.pitchHistoryLength else {
            return pitchHistoryBuffer
        }
        let start = pitchHistoryIndex % Config.pitchHistoryLength
        return Array(pitchHistoryBuffer[start...]) + Array(pitchHistoryBuffer[..<start])
    }
    public var recentPeakDelays: [Double] = []

    // MARK: - Profiling counters (in ms; refreshed every UI tick)
    public private(set) var lastGlideTickMs: Double = 0
    public private(set) var maxGlideTickMs: Double = 0
    public private(set) var lastLockWaitMicros: Double = 0
    public private(set) var lastLockAcquisitions: UInt64 = 0
    private var profilingWindowStart: TimeInterval = 0
    private var maxGlideTickInWindow: Double = 0

    // Throttled UI update counter
    private var uiUpdateCounter: Int = 0
    private let uiUpdateInterval: Int = 4  // publish every 4th tick (~15Hz)

    /// When true, the glide loop and motion processing are paused (e.g., during parameter tuning).
    public var paused: Bool = false

    /// Tilt values cached each tick (3 axes, -1..+1 each). Index 0 = primary (up/down).
    public var currentTilt: [Double] = [0, 0, 0]

    /// Slider values (0..1). Revert to their configured defaults when not touched.
    public var slider1Value: Double = Config.slider1Default
    public var slider2Value: Double = Config.slider2Default
    public var slider1Touched: Bool = false
    public var slider2Touched: Bool = false

    // (2026-07-24 dead-param deletion: the dimension-mapping machinery —
    // `dimensionMapping`, the binding caches, `cachedParamValue`,
    // `activeCCs`, `pressureInUse` — is GONE. All parameter mapping is
    // Mac-side now; this class only reports raw tilts and plays the
    // legacy glide engine with fixed constants.)

    /// Per-note dimension values from the most recently activated voice (for UI display).
    public var lastActiveAccelPressure: Double { pitchChannels[lastActiveVoiceIndex].accelPressure }
    public var lastActiveKeyY: Double { pitchChannels[lastActiveVoiceIndex].keyY }

    /// Index of the most recently activated voice, used as fallback when
    /// a per-note dimension is mapped to a global parameter.
    private var lastActiveVoiceIndex: Int = 0

    /// Returns 0..1 normalized value for a dimension, resolved for a specific voice.
    /// For per-note dimensions, pass `voiceIndex` to get that voice's value;
    /// if omitted, falls back to `lastActiveVoiceIndex`.
    public func normalizedDimension(for dim: InputDimension, voiceIndex: Int? = nil) -> Double {
        switch dim {
        case .tilt1:
            return currentTilt.count > 0 ? (currentTilt[0] + 1.0) / 2.0 : 0.5
        case .tilt2:
            return currentTilt.count > 1 ? (currentTilt[1] + 1.0) / 2.0 : 0.5
        case .tilt3:
            return currentTilt.count > 2 ? (currentTilt[2] + 1.0) / 2.0 : 0.5
        case .accelPressure:
            let vi = voiceIndex ?? lastActiveVoiceIndex
            return pitchChannels[vi].accelPressure
        case .keyY:
            let vi = voiceIndex ?? lastActiveVoiceIndex
            return pitchChannels[vi].keyY
        case .slider1:
            return slider1Value
        case .slider2:
            return slider2Value
        case .none:
            return 0.5
        }
    }

    /// Glide time per semitone (seconds).
    public var glideTimePerSemitone: Double {
        NoteManager.glideSpeedSecPerSemitone
    }

    /// Glide max wait — mid-glide compression threshold (seconds).
    public var glideMaxWait: Double {
        NoteManager.glideCompressionSec
    }

    public var motionSource: MotionSource?
    public var midiEngine: MIDIEngine?

    /// The playing scale (keyboard layout + tuning). Loaded from persistence.
    public var scale: Scale = Scale.load() {
        didSet { scale.save() }
    }

    // Sympathetic-strings concerns live entirely on the Mac side now
    // (StarpadMac/AppController.swift). iPad has no audio engine and
    // no sym scale.

    public var startNote: Int { scale.startNote }
    public var noteCount: Int { scale.noteCount }

    // MARK: - Drag State
    private var dragSnapTimer: Timer?
    private var polySnapTimers: [Int: Timer] = [:]  // voiceIndex -> snap timer
    private var touchOriginX: [Int: Double] = [:]  // touchId -> original xFraction
    private var monoDrag = DragInfo(lastDragX: 0)  // monophonic drag tracking

    /// Find the nearest enabled note to a fractional semitone value.
    /// If `whiteOnly`, restricts to non-black-key enabled notes.
    private func nearestEnabledNote(to semitone: Double, whiteOnly: Bool = false) -> Int {
        return scale.nearestEnabledNote(to: semitone, whiteOnly: whiteOnly)
    }

    /// Convert x fraction to a continuous (fractional) MIDI note number.
    /// Maps through the white key layout so the result matches the visual keyboard.
    /// Each white key's center maps exactly to its MIDI note; edges interpolate
    /// between adjacent white keys.
    private func continuousMidiNote(xFraction: Double) -> Double {
        let whites = whiteNotes
        let whiteCount = whites.count
        guard whiteCount > 1 else { return Double(startNote) }

        let clamped = max(0, min(1, xFraction))
        // Map so that the center of key i is at (i + 0.5) / whiteCount
        // Shift by -0.5 so key centers land on integer indices
        let keyPos = clamped * Double(whiteCount) - 0.5
        let lowerIdx = max(0, min(whiteCount - 1, Int(floor(keyPos))))
        let upperIdx = min(lowerIdx + 1, whiteCount - 1)
        let frac = max(0, min(1, keyPos - Double(lowerIdx)))

        let lowerNote = Double(whites[lowerIdx])
        let upperNote = Double(whites[upperIdx])
        return lowerNote + frac * (upperNote - lowerNote)
    }

    // MARK: - MPE Channel Allocation

    /// Round-robin through MIDI channels 1-15. Channel 0 is the MPE master channel.
    private var nextMpeChannel: UInt8 = 1
    /// MPE channels that have already had `Config.midiPitchBendRange`
    /// asserted via RPN. The hosted-AU's per-channel state is sticky,
    /// so once the RPN lands we don't need to resend it on every Note
    /// On — only first use. `panic()` doesn't reset this because
    /// CC 123 (All Notes Off) leaves RPN state untouched at the AU.
    private var bendRangeSet: Set<UInt8> = []

    private func allocateMpeChannel() -> UInt8 {
        let ch = nextMpeChannel
        nextMpeChannel = nextMpeChannel >= 15 ? 1 : nextMpeChannel + 1
        return ch
    }

    private func configureBendRangeIfNeeded(channel: UInt8) {
        guard bendRangeSet.insert(channel).inserted else { return }
        midiEngine?.sendPitchBendRange(
            semitones: UInt8(Int(Config.midiPitchBendRange)),
            channel: channel
        )
    }

    // MARK: - Pending Touches (velocity capture)

    /// A touch that has been registered but is waiting for the accelerometer
    /// spike to arrive (20ms delay) before the note fires.
    private struct PendingTouch {
        let touchId: Int
        let midiNote: Int
        let touchTimestamp: TimeInterval  // CMMotionManager timestamp for accel correlation
        let keyY: Double
        let timer: Timer
    }
    private var pendingTouches: [Int: PendingTouch] = [:]

    /// Grace period timer: delays the transition to idle/releasing after all
    /// touches lift, so a new touch arriving within the window connects as a glide.
    private var releaseGraceTimer: Timer?

    // MARK: - Polyphonic Per-Touch Drag State

    /// Per-touch drag tracking. Used for both mono (single instance) and poly
    /// (per-touch dictionary) modes.
    private struct DragInfo {
        var lastDragX: Double
        var dragDirection: Int = 0
        var dragInWhiteZone: Bool = true
        var snapOriginX: Double = 0  // x position when snap engaged (for dead zone)
    }
    private var polyDragState: [Int: DragInfo] = [:]

    // MARK: - Glide Speed Physics


    // MARK: - Glide Update Loop

    private var glideTimer: Timer?
    private var lastTickTime: TimeInterval = 0

    // Legacy glide-engine constants (2026-07-24 dead-param deletion):
    // formerly dimension-mapped; nothing on the live playing path reads
    // them, and the audition/keyboard path uses these fixed values (the
    // old defaults' resting midpoints).
    static let glideSpeedSecPerSemitone = 0.110
    static let glideCompressionSec = 0.0275
    static let dragSmoothingCoeff = 0.3
    static let glideCurveK = 7.5
    static let fixedVelocity = 92

    public init() {
        startGlideLoop()
    }

    /// Starts the 60 Hz timer that drives all continuous pitch updates.
    private func startGlideLoop() {
        lastTickTime = CACurrentMediaTime()
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.glideUpdate()
        }
    }

    /// Called 60 times per second. Advances the glide and tilt modulation.
    private func glideUpdate() {
        if paused {
            lastTickTime = CACurrentMediaTime()
            return
        }
        let tickStart = CACurrentMediaTime()

        // Cache tilt for consistent use this tick
        if let tilts = motionSource?.normalizedTilts {
            for i in 0..<min(tilts.count, 3) {
                currentTilt[i] = max(-1, min(1, tilts[i]))
            }
        }

        let now = CACurrentMediaTime()
        let dt = now - lastTickTime
        lastTickTime = now

        if polyphonicMode {
            var anyActive = false
            for i in 0..<Config.maxPolyVoices where pitchChannels[i].state != .idle {
                updateVoiceGlide(voiceIndex: i, dt: dt)
                updateVoiceExpression(voiceIndex: i, dt: dt)
                anyActive = true
            }
            if anyActive { sendTiltReport() }
        } else {
            if pitchChannels[0].state != .idle {
                updateVoiceGlide(voiceIndex: 0, dt: dt)
                updateVoiceExpression(voiceIndex: 0, dt: dt)
                sendTiltReport()
            }
        }

        // Push all control-rate modal-synth parameters and sym-coupling gains
        // Voice timbre / reverb / sym amp pushes used to live here;
        // they're Mac-only concerns now (AppController.pushTimbre etc.)
        // and the iPad has no audioEngine to push to.

        // --- Record pitch history for the graph ---
        let frequencies: [Double?] = (0..<Config.maxPolyVoices).map { i in
            guard pitchChannels[i].state != .idle else { return nil }
            return pitchChannels[i].currentFrequency
        }

        // Only compute display-only data on UI update ticks
        let isUITick = uiUpdateCounter + 1 >= uiUpdateInterval
        let heldNotes: [Int]
        if isUITick {
            var notes: Set<Int> = []
            for ch in pitchChannels { notes.formUnion(ch.touchNotes.values) }
            heldNotes = Array(notes)
        } else {
            heldNotes = []
        }

        let sample = PitchSample(
            timestamp: now,
            frequencies: frequencies,
            draggingFlags: (0..<Config.maxPolyVoices).map { pitchChannels[$0].dragging },
            snappingFlags: (0..<Config.maxPolyVoices).map { pitchChannels[$0].snapping },
            touchNotes: heldNotes
        )
        if pitchHistoryBuffer.count >= Config.pitchHistoryLength {
            pitchHistoryBuffer[pitchHistoryIndex % Config.pitchHistoryLength] = sample
        } else {
            pitchHistoryBuffer.append(sample)
        }
        pitchHistoryIndex += 1

        // Per-tick profiling: track this tick's duration vs. the rolling max.
        let tickElapsed = (CACurrentMediaTime() - tickStart) * 1000.0
        lastGlideTickMs = tickElapsed
        if tickElapsed > maxGlideTickInWindow { maxGlideTickInWindow = tickElapsed }

        // Throttle SwiftUI updates to ~15Hz
        uiUpdateCounter += 1
        if uiUpdateCounter >= uiUpdateInterval {
            uiUpdateCounter = 0
            // Snapshot rolling stats once per UI tick (~15Hz).
            let nowSec = CACurrentMediaTime()
            if profilingWindowStart == 0 { profilingWindowStart = nowSec }
            let windowElapsed = nowSec - profilingWindowStart
            if windowElapsed >= 0.5 {
                maxGlideTickMs = maxGlideTickInWindow
                maxGlideTickInWindow = 0
                profilingWindowStart = nowSec
            }
            objectWillChange.send()
        }
    }

    /// Advances glide interpolation for a single voice.
    private func updateVoiceGlide(voiceIndex i: Int, dt: Double) {
        // --- Drag smoothing ---
        if pitchChannels[i].dragging && pitchChannels[i].dragTargetFreq > 0 {
            let logCurrent = log2(pitchChannels[i].currentFrequency)
            let logTarget = log2(pitchChannels[i].dragTargetFreq)
            let baseSmoothingVal = NoteManager.dragSmoothingCoeff
            let smoothing = pitchChannels[i].snapping ? min(baseSmoothingVal * 2.0, 1.0) : baseSmoothingVal
            let logSmoothed = logCurrent + (logTarget - logCurrent) * smoothing
            pitchChannels[i].currentFrequency = pow(2.0, logSmoothed)
            pitchChannels[i].targetFrequency = pitchChannels[i].dragTargetFreq

            sendPitchBend(for: i)

            // If touch was released mid-drag, release once snap converges
            if pitchChannels[i].releaseAfterSnap && pitchChannels[i].snapping {
                let centsDelta = abs(logTarget - logCurrent) * 1200.0
                if centsDelta < 1.0 {
                    pitchChannels[i].currentFrequency = pitchChannels[i].dragTargetFreq
                    sendPitchBend(for: i)
                    pitchChannels[i].dragging = false
                    pitchChannels[i].releaseAfterSnap = false
                    releaseVoice(i)
                }
            }
        }

        // --- Glide interpolation (waypoint-based, used when not dragging) ---
        if !pitchChannels[i].dragging && pitchChannels[i].glideProgress < 1.0 {
            pitchChannels[i].glideProgress += dt / pitchChannels[i].glideDuration
            pitchChannels[i].glideProgress = min(pitchChannels[i].glideProgress, 1.0)

            // Asymmetric sigmoid easing in log-frequency space
            let t = pitchChannels[i].glideProgress
            let k = NoteManager.glideCurveK
            let m = Config.glideMidpoint
            let raw = 1.0 / (1.0 + exp(-k * (t - m)))
            let low = 1.0 / (1.0 + exp(-k * (0.0 - m)))
            let high = 1.0 / (1.0 + exp(-k * (1.0 - m)))
            let eased = (raw - low) / (high - low)

            let logStart = log2(pitchChannels[i].startFrequency)
            let logTarget = log2(pitchChannels[i].targetFrequency)
            let logCurrent = logStart + (logTarget - logStart) * eased
            pitchChannels[i].currentFrequency = pow(2.0, logCurrent)

            if pitchChannels[i].glideProgress >= 1.0 {
                glideCompleted(voiceIndex: i)
            }
        }

        // --- Release handling ---
        if pitchChannels[i].state == .releasing && pitchChannels[i].glideProgress >= 1.0 {
            if midiOutputEnabled {
                let midiCh = pitchChannels[i].midiChannel
                midiEngine?.sendNoteOff(note: UInt8(pitchChannels[i].baseNote), channel: midiCh)
                midiEngine?.sendPitchBend(value: 8192, channel: midiCh)
            }
            pitchChannels[i].state = .idle
        }
    }

    /// Applies pitch bend to a single voice. (2026-07-24: per-voice
    /// aftertouch/CC emission is GONE — the controller streams only the
    /// raw tilt report (`sendTiltReport`) and the Mac evaluates its own
    /// tilt bindings.)
    private func updateVoiceExpression(voiceIndex i: Int, dt: Double) {
        guard midiOutputEnabled else { return }
        sendPitchBend(for: i)
    }

    /// RAW TILT REPORT (2026-07-24): stream the three calibrated tilt
    /// values (normalized 0…1 → 0…127) on the fixed axis messages
    /// (`TiltAxisWire`), change-gated. The controller knows nothing about
    /// parameters, slots, or mappings — the Mac interprets.
    private var lastTiltSent: [UInt8] = [255, 255, 255]

    private func sendTiltReport() {
        guard midiOutputEnabled else { return }
        for (i, cc) in TiltAxisWire.ccs.enumerated() {
            let norm = normalizedDimension(for: TiltAxisWire.dims[i])
            let v = UInt8(max(0, min(127, Int((norm * 127).rounded()))))
            if v != lastTiltSent[i] {
                lastTiltSent[i] = v
                midiEngine?.sendControlChange(controller: cc, value: v, channel: 0)
            }
        }
    }

    // MARK: - Glide Queue

    /// Called when the current glide segment reaches progress=1.0.
    /// Pops the next waypoint from the queue and starts a new glide.
    private func glideCompleted(voiceIndex: Int = 0) {
        pitchChannels[voiceIndex].currentFrequency = pitchChannels[voiceIndex].targetFrequency
        advanceQueue(voiceIndex: voiceIndex)
    }

    /// Pops the next waypoint from the queue and begins gliding to it.
    /// Each waypoint must be reached within `glideMaxStaleness`.
    private func advanceQueue(voiceIndex: Int = 0) {
        guard !pitchChannels[voiceIndex].queue.isEmpty else { return }

        let waypoint = pitchChannels[voiceIndex].queue.removeFirst()
        let targetFreq = scale.frequency(for: waypoint.note)

        pitchChannels[voiceIndex].startFrequency = pitchChannels[voiceIndex].currentFrequency
        pitchChannels[voiceIndex].targetFrequency = targetFreq
        pitchChannels[voiceIndex].targetNote = waypoint.note
        pitchChannels[voiceIndex].glideProgress = 0.0
        let semitones = abs(12.0 * log2(targetFreq / pitchChannels[voiceIndex].currentFrequency))
        let scaledDistance = pow(max(1.0, semitones), Config.glideDistanceExponent)
        pitchChannels[voiceIndex].glideDuration = glideTimePerSemitone * scaledDistance
    }

    // MARK: - MIDI Pitch Bend

    /// Sends MIDI pitch bend for a voice.
    private func sendPitchBend(for channelIndex: Int) {
        let ch = pitchChannels[channelIndex]
        let baseSemitone = Double(ch.baseNote)
        let currentSemitone = 12.0 * log2(ch.currentFrequency / 440.0) + 69.0
        let semitoneOffset = currentSemitone - baseSemitone
        let normalizedBend = max(-1.0, min(1.0, semitoneOffset / Config.midiPitchBendRange))
        let midiValue = UInt16(8192 + Int(normalizedBend * 8191.0))
        midiEngine?.sendPitchBend(value: midiValue, channel: ch.midiChannel)
    }

    // MARK: - Piano Layout Hit Testing

    /// All white key MIDI notes in the current keyboard range (for layout).
    public var whiteNotes: [Int] {
        scale.whiteNotesInRange()
    }

    /// Converts raw yFraction (0=top, 1=bottom) to normalized key Y (0=bottom, 1=top),
    /// accounting for black keys being shorter (60% of keyboard height).
    public static func normalizedKeyY(yFraction: Double, isBlackKey: Bool) -> Double {
        if isBlackKey {
            let withinKey = min(1.0, yFraction / 0.6)
            return 1.0 - withinKey
        }
        return 1.0 - yFraction
    }

    public struct HitResult {
        public let note: Int
        public let isBlackKey: Bool
    }

    /// Determines which piano key a touch at (xFraction, yFraction) hits.
    ///
    /// The keyboard is laid out with white keys spanning the full width.
    /// Black keys are 75% of white key width and 60% of keyboard height,
    /// overlaid in the top portion. Touches in the top 60% can hit black keys;
    /// touches in the bottom 40% always hit white keys.
    public func hitTest(xFraction: Double, yFraction: Double) -> HitResult {
        let whites = whiteNotes
        let whiteCount = whites.count
        let whiteIndex = Int(xFraction * Double(whiteCount))
        let clampedWhiteIndex = min(max(whiteIndex, 0), whiteCount - 1)

        if yFraction < 0.6 {
            let whiteW = 1.0 / Double(whiteCount)
            let blackW = whiteW * 0.75
            let whiteNote = whites[clampedWhiteIndex]

            if Scale.isBlackKey(whiteNote - 1) && whiteNote - 1 >= startNote && scale.isEnabled(whiteNote - 1) {
                let blackCenter = Double(clampedWhiteIndex) * whiteW
                if xFraction >= blackCenter - blackW / 2 && xFraction <= blackCenter + blackW / 2 {
                    return HitResult(note: whiteNote - 1, isBlackKey: true)
                }
            }

            if Scale.isBlackKey(whiteNote + 1) && whiteNote + 1 < startNote + noteCount && scale.isEnabled(whiteNote + 1) {
                let blackCenter = Double(clampedWhiteIndex + 1) * whiteW
                if xFraction >= blackCenter - blackW / 2 && xFraction <= blackCenter + blackW / 2 {
                    return HitResult(note: whiteNote + 1, isBlackKey: true)
                }
            }
        }

        // Return the white key only if it's enabled; otherwise find nearest enabled
        let whiteNote = whites[clampedWhiteIndex]
        if scale.isEnabled(whiteNote) {
            return HitResult(note: whiteNote, isBlackKey: false)
        }
        let nearest = scale.nearestEnabledNote(to: Double(whiteNote))
        return HitResult(note: nearest, isBlackKey: Scale.isBlackKey(nearest))
    }

    // MARK: - Touch Events

    /// Called when a finger touches the keyboard.
    ///
    /// Starts a velocity capture timer (if pressure is in use) or fires immediately.
    /// The note doesn't sound until `fireNote` is called.
    public func touchBegan(touchId: Int, xFraction: Double, yFraction: Double, motionTimestamp: TimeInterval) {
        let hit = hitTest(xFraction: xFraction, yFraction: yFraction)
        let note = hit.note
        touchOriginX[touchId] = xFraction

        let normalizedY = Self.normalizedKeyY(yFraction: yFraction, isBlackKey: hit.isBlackKey)

        // (2026-07-24: velocity is a fixed constant — the accelerometer
        // capture delay is gone; notes always fire immediately.)
        fireNote(touchId: touchId, note: note, motionTimestamp: motionTimestamp, keyY: normalizedY)
    }

    /// Called when a finger lifts from the keyboard.
    ///
    /// Three cases:
    /// 1. Touch was still pending (velocity timer) → fire the note immediately, then release.
    /// 2. All touches released → clear queue, enter releasing state.
    /// 3. Other touches still held → mark released waypoints, queue return to held note.
    public func touchEnded(touchId: Int) {
        touchOriginX.removeValue(forKey: touchId)

        // Case 1: velocity timer hasn't fired yet — fire the note now, then fall through to release
        if let pending = pendingTouches.removeValue(forKey: touchId) {
            pending.timer.invalidate()
            fireNote(touchId: touchId, note: pending.midiNote,
                     motionTimestamp: pending.touchTimestamp, keyY: pending.keyY)
        }

        // --- Polyphonic mode ---
        if polyphonicMode {
            polyTouchEnded(touchId: touchId)
            return
        }

        // --- Monophonic mode ---
        dragSnapTimer?.invalidate()
        dragSnapTimer = nil

        // If dragging, snap to nearest note before releasing
        if pitchChannels[0].dragging {
            snapToNearestPitch()
            pitchChannels[0].releaseAfterSnap = true
        } else {
            pitchChannels[0].dragging = false
        }

        guard pitchChannels[0].touchNotes.keys.contains(touchId) else { return }
        pitchChannels[0].touchNotes.removeValue(forKey: touchId)

        if pitchChannels[0].touchNotes.isEmpty {
            // Case 2: all touches released — start grace period.
            // If a new touch arrives within the window, it will connect as a glide
            // instead of starting a new note.
            pitchChannels[0].queue.removeAll()
            releaseGraceTimer?.invalidate()
            releaseGraceTimer = Timer.scheduledTimer(withTimeInterval: Config.releaseGracePeriod, repeats: false) { [weak self] _ in
                guard let self else { return }
                // Only release if still no touches (not reclaimed during grace period)
                guard self.pitchChannels[0].touchNotes.isEmpty else { return }
                // If snap-then-release is pending, the glide loop will handle release
                guard !self.pitchChannels[0].releaseAfterSnap else { return }
                if self.pitchChannels[0].glideProgress < 1.0 {
                    self.pitchChannels[0].glideDuration *= 0.3
                    self.pitchChannels[0].state = .releasing
                } else {
                    if self.midiOutputEnabled {
                        let midiCh = self.pitchChannels[0].midiChannel
                        self.midiEngine?.sendNoteOff(note: UInt8(self.pitchChannels[0].baseNote), channel: midiCh)
                        self.midiEngine?.sendPitchBend(value: 8192, channel: midiCh)
                    }
                    self.pitchChannels[0].state = .idle
                }
            }
        } else {
            // Case 3: other touches still held
            let now = CACurrentMediaTime()
            if let remainingNote = pitchChannels[0].touchNotes.values.first {
                // Queue the return to the held note (unless already the target or queued)
                let isCurrentTarget = pitchChannels[0].targetNote == remainingNote
                let alreadyQueued = pitchChannels[0].queue.contains { $0.note == remainingNote }
                if !isCurrentTarget && !alreadyQueued {
                    pitchChannels[0].queue.append(GlideWaypoint(note: remainingNote, timestamp: now))

                    // Compress current glide to finish within maxWait
                    if pitchChannels[0].glideProgress < 1.0 {
                        let remaining = 1.0 - pitchChannels[0].glideProgress
                        let currentRemaining = remaining * pitchChannels[0].glideDuration
                        if currentRemaining > glideMaxWait {
                            pitchChannels[0].glideDuration = glideMaxWait / remaining
                        }
                    }
                }

                // If at rest, start processing the queue
                if pitchChannels[0].glideProgress >= 1.0 && !pitchChannels[0].queue.isEmpty {
                    advanceQueue()
                }
            }
        }
    }

    /// Called when a finger moves on the keyboard.
    /// With a single finger: enters drag mode and tracks pitch continuously.
    /// When the finger stops, snaps to the nearest 12-tone pitch.
    public func touchMoved(touchId: Int, xFraction: Double, yFraction: Double) {
        // Poly mode: each touch drags its own voice
        if polyphonicMode {
            polyTouchMoved(touchId: touchId, xFraction: xFraction, yFraction: yFraction)
            return
        }

        guard pitchChannels[0].state == .sounding,
              pitchChannels[0].touchNotes.keys.contains(touchId) else { return }

        // Update per-note key y dimension
        let hit = hitTest(xFraction: xFraction, yFraction: yFraction)
        pitchChannels[0].keyY = Self.normalizedKeyY(yFraction: yFraction, isBlackKey: hit.isBlackKey)

        // Drag glide: only when a single touch is present
        guard pitchChannels[0].touchNotes.count == 1 else { return }

        if tryEnterDrag(voiceIndex: 0, touchId: touchId, xFraction: xFraction, yFraction: yFraction) {
            monoDrag = DragInfo(lastDragX: xFraction, dragDirection: 0, dragInWhiteZone: yFraction >= 0.6)
        }
        guard pitchChannels[0].dragging else { return }

        processDrag(voiceIndex: 0, touchId: touchId, xFraction: xFraction, yFraction: yFraction,
                    hit: hit, drag: &monoDrag)

        // Reset snap timer — when finger stops, smoothly target the nearest scale tone
        dragSnapTimer?.invalidate()
        let snapX = xFraction
        dragSnapTimer = Timer.scheduledTimer(withTimeInterval: Config.dragSnapDelay, repeats: false) { [weak self] _ in
            self?.monoDrag.snapOriginX = snapX
            self?.snapToNearestPitch()
        }
    }

    /// Core drag processing shared by mono and poly modes.
    /// Updates pitch channel state and drag info based on finger movement.
    /// Returns true if drag was initialized this tick (caller should skip further processing).
    private func processDrag(voiceIndex: Int, touchId: Int, xFraction: Double, yFraction: Double,
                             hit: HitResult, drag: inout DragInfo) {
        drag.dragInWhiteZone = yFraction >= 0.6
        pitchChannels[voiceIndex].displayNote = hit.note

        let continuousNote = continuousMidiNote(xFraction: xFraction)
        let fingerFreq = scale.frequency(for: continuousNote)

        // Direction reversal correction
        var reversalThisTick = false
        let dx = xFraction - drag.lastDragX
        if abs(dx) > 0.0001 {
            let newDirection = dx > 0 ? 1 : -1
            if drag.dragDirection != 0 && newDirection != drag.dragDirection {
                let reversalNote = continuousMidiNote(xFraction: drag.lastDragX)
                let snappedNote = nearestEnabledNote(to: reversalNote, whiteOnly: drag.dragInWhiteZone)
                pitchChannels[voiceIndex].dragTargetFreq = scale.frequency(for: snappedNote)
                pitchChannels[voiceIndex].targetNote = snappedNote
                reversalThisTick = true
            }
            drag.dragDirection = newDirection
        }
        drag.lastDragX = xFraction

        if !reversalThisTick {
            if pitchChannels[voiceIndex].snapping {
                let keyWidth = 1.0 / Double(noteCount)
                let threshold = keyWidth / 3.0
                if abs(xFraction - drag.snapOriginX) >= threshold {
                    pitchChannels[voiceIndex].dragTargetFreq = fingerFreq
                    pitchChannels[voiceIndex].snapping = false
                }
            } else {
                pitchChannels[voiceIndex].dragTargetFreq = fingerFreq
            }
        }
        pitchChannels[voiceIndex].glideProgress = 1.0
        pitchChannels[voiceIndex].queue.removeAll()
        pitchChannels[voiceIndex].touchNotes[touchId] = Int(round(continuousNote))
        pitchChannels[voiceIndex].targetNote = Int(round(continuousNote))
    }

    /// Checks if a touch has moved enough to enter drag mode.
    /// Returns true if drag mode was just activated (caller should initialize drag state).
    private func tryEnterDrag(voiceIndex: Int, touchId: Int, xFraction: Double, yFraction: Double) -> Bool {
        guard !pitchChannels[voiceIndex].dragging else { return false }
        guard let originX = touchOriginX[touchId] else { return false }
        let keyWidth = 1.0 / Double(noteCount)
        let threshold = keyWidth / 3.0
        guard abs(xFraction - originX) >= threshold else { return false }
        pitchChannels[voiceIndex].dragging = true
        pitchChannels[voiceIndex].dragTargetFreq = pitchChannels[voiceIndex].currentFrequency
        return true
    }

    /// When finger stops, set the drag target to the nearest scale tone.
    /// The glide loop's smoothing will glide there naturally.
    private func snapToNearestPitch(voiceIndex: Int = 0, whiteOnly: Bool? = nil) {
        guard pitchChannels[voiceIndex].state == .sounding, pitchChannels[voiceIndex].dragging else { return }

        let useWhiteOnly = whiteOnly ?? monoDrag.dragInWhiteZone
        let currentSemitone = 12.0 * log2(pitchChannels[voiceIndex].currentFrequency / 440.0) + 69.0
        let nearestNote = nearestEnabledNote(to: currentSemitone, whiteOnly: useWhiteOnly)
        let targetFreq = scale.frequency(for: nearestNote)

        pitchChannels[voiceIndex].dragTargetFreq = targetFreq
        pitchChannels[voiceIndex].targetNote = nearestNote
        pitchChannels[voiceIndex].displayNote = nearestNote
        pitchChannels[voiceIndex].snapping = true
    }

    // MARK: - Note Firing

    /// Called after the 20ms velocity capture delay.
    ///
    /// Reads the peak accelerometer magnitude since the touch timestamp,
    /// converts it to MIDI velocity (1-127, log scale), then either:
    /// - Activates the channel (if idle)
    /// - Adds the touch to an existing channel on the same note
    /// - Queues a glide to the new note
    private func fireNote(touchId: Int, note: Int, motionTimestamp: TimeInterval, keyY: Double) {
        pendingTouches.removeValue(forKey: touchId)

        // (2026-07-24: accelerometer velocity capture deleted with the
        // dead velocity parameter — fixed velocity, per-note dims kept
        // only as UI state.)
        let normalized = 0.5
        pitchChannels[lastActiveVoiceIndex].accelPressure = normalized
        pitchChannels[lastActiveVoiceIndex].keyY = keyY
        let velocity = NoteManager.fixedVelocity

        // --- Polyphonic mode: each touch gets its own voice ---
        if polyphonicMode {
            // If a voice is already sounding this exact note, register this touch on it
            if let existingVoice = (0..<Config.maxPolyVoices).first(where: {
                pitchChannels[$0].state != .idle && pitchChannels[$0].targetNote == note
            }) {
                pitchChannels[existingVoice].touchNotes[touchId] = note
                return
            }

            // Find an idle voice and activate it
            guard let voiceIdx = firstIdleVoiceIndex else { return }
            activateChannel(touchId: touchId, note: note, velocity: velocity, voiceIndex: voiceIdx,
                            accelPressure: normalized, keyY: keyY)
            return
        }

        // --- Monophonic mode ---

        // Same note as current target? Just register the touch.
        if pitchChannels[0].state != .idle && pitchChannels[0].targetNote == note {
            releaseGraceTimer?.invalidate()
            releaseGraceTimer = nil
            pitchChannels[0].releaseAfterSnap = false
            pitchChannels[0].touchNotes[touchId] = note
            pitchChannels[0].accelPressure = normalized
            pitchChannels[0].keyY = keyY
            lastActiveVoiceIndex = 0
            return
        }

        // Channel idle? Activate it with this note.
        if pitchChannels[0].state == .idle {
            activateChannel(touchId: touchId, note: note, velocity: velocity,
                            accelPressure: normalized, keyY: keyY)
            return
        }

        // Channel active with a different note? Queue a glide.
        startGlide(touchId: touchId, targetNote: note, velocity: velocity)
    }

    /// Activates a voice from idle with a new note.
    /// Allocates a fresh MPE channel, sets pitch bend range, sends noteOn.
    private func activateChannel(touchId: Int, note: Int, velocity: Int, voiceIndex: Int = 0,
                                 accelPressure: Double = 0.5, keyY: Double = 0.5) {
        let freq = scale.frequency(for: note)
        let midiCh = allocateMpeChannel()

        pitchChannels[voiceIndex] = PitchChannel(index: voiceIndex)
        pitchChannels[voiceIndex].state = .sounding
        pitchChannels[voiceIndex].currentFrequency = freq
        pitchChannels[voiceIndex].targetFrequency = freq
        pitchChannels[voiceIndex].startFrequency = freq
        pitchChannels[voiceIndex].baseNote = note
        pitchChannels[voiceIndex].targetNote = note
        pitchChannels[voiceIndex].velocity = velocity
        pitchChannels[voiceIndex].glideProgress = 1.0
        pitchChannels[voiceIndex].touchNotes = [touchId: note]
        pitchChannels[voiceIndex].midiChannel = midiCh
        pitchChannels[voiceIndex].accelPressure = accelPressure
        pitchChannels[voiceIndex].keyY = keyY
        lastActiveVoiceIndex = voiceIndex

        if midiOutputEnabled {
            configureBendRangeIfNeeded(channel: midiCh)
            midiEngine?.sendPitchBend(value: 8192, channel: midiCh)
            midiEngine?.sendNoteOn(note: UInt8(note), velocity: UInt8(velocity), channel: midiCh)
        }
    }

    /// Queues a glide to a new note on a specific voice.
    ///
    /// If the voice is mid-glide, the new note is appended to the queue.
    /// If the voice is at rest (glide complete), the queue is started
    /// immediately via `advanceQueue`. Cancels any release grace timer.
    private func startGlide(touchId: Int, targetNote: Int, velocity: Int, voiceIndex: Int = 0) {
        let now = CACurrentMediaTime()
        releaseGraceTimer?.invalidate()
        releaseGraceTimer = nil
        pitchChannels[voiceIndex].touchNotes[touchId] = targetNote
        pitchChannels[voiceIndex].state = .sounding
        pitchChannels[voiceIndex].dragging = false  // tap-based glide, not a drag
        pitchChannels[voiceIndex].releaseAfterSnap = false

        let waypoint = GlideWaypoint(note: targetNote, timestamp: now)
        pitchChannels[voiceIndex].queue.append(waypoint)

        if pitchChannels[voiceIndex].glideProgress >= 1.0 {
            // At rest: start gliding immediately
            advanceQueue(voiceIndex: voiceIndex)
        } else {
            // Mid-glide: compress remaining duration so we finish within
            // maxStaleness of the new waypoint's creation time.
            let remaining = 1.0 - pitchChannels[voiceIndex].glideProgress
            let currentRemaining = remaining * pitchChannels[voiceIndex].glideDuration
            if currentRemaining > glideMaxWait {
                pitchChannels[voiceIndex].glideDuration = glideMaxWait / remaining
            }
        }
    }

    // MARK: - Polyphonic Touch Handling

    /// Handles touch release in polyphonic mode. Simply releases the voice
    /// that owns the released touch.
    private func polyTouchEnded(touchId: Int) {
        let dragInfo = polyDragState.removeValue(forKey: touchId)

        // Find which voice owns this touch
        guard let voiceIdx = pitchChannels.indices.first(where: { pitchChannels[$0].touchNotes[touchId] != nil }) else { return }
        pitchChannels[voiceIdx].touchNotes.removeValue(forKey: touchId)

        // If no more touches on this voice, snap then release
        if pitchChannels[voiceIdx].touchNotes.isEmpty {
            polySnapTimers[voiceIdx]?.invalidate()
            polySnapTimers.removeValue(forKey: voiceIdx)

            if pitchChannels[voiceIdx].dragging {
                // Snap to nearest note, then the glide loop will release once converged
                let whiteOnly = dragInfo?.dragInWhiteZone ?? true
                snapToNearestPitch(voiceIndex: voiceIdx, whiteOnly: whiteOnly)
                pitchChannels[voiceIdx].releaseAfterSnap = true
            } else {
                releaseVoice(voiceIdx)
            }
        }
    }

    /// Handles touch movement in polyphonic mode. Each touch can independently
    /// drag its voice's pitch across the keyboard.
    private func polyTouchMoved(touchId: Int, xFraction: Double, yFraction: Double) {
        let hit = hitTest(xFraction: xFraction, yFraction: yFraction)


        // Find which voice owns this touch
        guard let voiceIdx = pitchChannels.indices.first(where: {
            pitchChannels[$0].state == .sounding && pitchChannels[$0].touchNotes[touchId] != nil
        }) else { return }

        // Update per-note key y dimension
        pitchChannels[voiceIdx].keyY = Self.normalizedKeyY(yFraction: yFraction, isBlackKey: hit.isBlackKey)

        if tryEnterDrag(voiceIndex: voiceIdx, touchId: touchId, xFraction: xFraction, yFraction: yFraction) {
            polyDragState[touchId] = DragInfo(lastDragX: xFraction, dragDirection: 0, dragInWhiteZone: yFraction >= 0.6)
            return
        }

        guard var drag = polyDragState[touchId] else { return }

        processDrag(voiceIndex: voiceIdx, touchId: touchId, xFraction: xFraction, yFraction: yFraction,
                    hit: hit, drag: &drag)
        polyDragState[touchId] = drag

        // Reset snap timer
        let whiteOnly = drag.dragInWhiteZone
        let snapX = xFraction
        polySnapTimers[voiceIdx]?.invalidate()
        polySnapTimers[voiceIdx] = Timer.scheduledTimer(withTimeInterval: Config.dragSnapDelay, repeats: false) { [weak self] _ in
            self?.polyDragState[touchId]?.snapOriginX = snapX
            self?.snapToNearestPitch(voiceIndex: voiceIdx, whiteOnly: whiteOnly)
        }
    }

    /// Releases a single voice: sends noteOff or enters releasing state if mid-glide.
    private func releaseVoice(_ voiceIndex: Int) {
        pitchChannels[voiceIndex].touchNotes.removeAll()
        pitchChannels[voiceIndex].queue.removeAll()

        if pitchChannels[voiceIndex].glideProgress < 1.0 {
            // Mid-glide: accelerate and mark releasing
            pitchChannels[voiceIndex].glideDuration *= 0.3
            pitchChannels[voiceIndex].state = .releasing
        } else {
            // At rest: immediate noteOff
            if midiOutputEnabled {
                let midiCh = pitchChannels[voiceIndex].midiChannel
                midiEngine?.sendNoteOff(note: UInt8(pitchChannels[voiceIndex].baseNote), channel: midiCh)
                midiEngine?.sendPitchBend(value: 8192, channel: midiCh)
            }
            pitchChannels[voiceIndex].state = .idle
        }
    }

    // MARK: - Helpers

    public static func noteName(for midiNote: Int) -> String {
        Scale.noteName(for: midiNote)
    }

    public static func isBlackKey(_ midiNote: Int) -> Bool {
        Scale.isBlackKey(midiNote)
    }

    public var averagePeakDelay: Double? {
        guard !recentPeakDelays.isEmpty else { return nil }
        return recentPeakDelays.reduce(0, +) / Double(recentPeakDelays.count)
    }

    public var maxPeakDelay: Double? {
        recentPeakDelays.max()
    }

    /// Emergency reset: silences all sound and clears all state.
    public func panic() {
        for i in 0..<pitchChannels.count {
            if pitchChannels[i].state != .idle {
                let midiCh = pitchChannels[i].midiChannel
                midiEngine?.sendNoteOff(note: UInt8(pitchChannels[i].baseNote), channel: midiCh)
                midiEngine?.sendPitchBend(value: 8192, channel: midiCh)
            }
            pitchChannels[i] = PitchChannel(index: i)
        }
        for ch: UInt8 in 0...15 {
            midiEngine?.sendControlChange(controller: 123, value: 0, channel: ch)
            midiEngine?.sendPitchBend(value: 8192, channel: ch)
        }
        pendingTouches.values.forEach { $0.timer.invalidate() }
        pendingTouches.removeAll()
        releaseGraceTimer?.invalidate()
        releaseGraceTimer = nil
        polyDragState.removeAll()
        polySnapTimers.values.forEach { $0.invalidate() }
        polySnapTimers.removeAll()
        dragSnapTimer?.invalidate()
        dragSnapTimer = nil
        touchOriginX.removeAll()
    }

    deinit {
        glideTimer?.invalidate()
    }
}
