import Foundation
import QuartzCore

// MARK: - Data Models

/// The state of a pitch channel's envelope.
public enum ChannelState {
    case idle
    case sounding   // may be gliding between pitches
    case releasing  // all touches lifted; finishing a glide then fading out
}

/// A pitch the in-process glide engine must visit, in queue order.
public struct GlideWaypoint {
    public let note: Int               // MIDI note
    public let timestamp: TimeInterval // creation time (CACurrentMediaTime)
}

/// A monophonic voice with continuous pitch; all changes go through `queue`.
public struct PitchChannel {
    public let index: Int
    public var state: ChannelState = .idle
    public var currentFrequency: Double = 440.0   // Hz, sounding now
    public var targetFrequency: Double = 440.0    // Hz, gliding toward
    public var startFrequency: Double = 440.0     // Hz, at the start of the segment
    public var baseNote: Int = 69                 // pitch bend origin
    public var targetNote: Int = 69
    public var velocity: Int = 80
    public var glideProgress: Double = 1.0        // 0 = segment start, 1 = arrived
    public var glideDuration: Double = 0.4        // s, current segment
    public var touchNotes: [Int: Int] = [:]       // touchId → held MIDI note
    public var midiChannel: UInt8 = 1             // MPE member channel

    /// Notes to visit in order (a release appends the held note as return).
    public var queue: [GlideWaypoint] = []
    public var dragging: Bool = false           // finger-drag mode
    public var dragTargetFreq: Double = 0       // Hz the pitch chases during drag
    public var snapping: Bool = false           // quantizing after the finger stopped
    public var releaseAfterSnap: Bool = false   // lifted mid-drag; release once the snap converges
    public var displayNote: Int?                // key under the finger (highlight)

    public var accelPressure: Double = 0.5
    public var keyY: Double = 0.5

    public var touchIds: Set<Int> { Set(touchNotes.keys) }
}

// MARK: - NoteManager

/// The iPad's 60 Hz tick. Its live job is `sendTiltReport`: sampling the
/// motion source's tilts, raw acceleration and strike envelope into
/// `OutboundPlayState`, the wire state the link paces (the iPad evaluates
/// no parameter mappings — the Mac interprets). It also hosts the
/// in-process monophonic keyboard/glide engine that audition scripts
/// exercise through `MIDIEngine`: touches feed a waypoint queue, each
/// segment glides with an asymmetric sigmoid in log-frequency space, and
/// every activation takes a fresh MPE channel (round-robin 1–15).
public class NoteManager: ObservableObject {

    public var pitchChannels: [PitchChannel] = (0..<Config.maxPolyVoices).map { PitchChannel(index: $0) }

    @Published public var synthEnabled: Bool = UserDefaults.standard.object(forKey: "synthEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(synthEnabled, forKey: "synthEnabled")
        }
    }

    @Published public var midiOutputEnabled: Bool = UserDefaults.standard.object(forKey: "midiOutputEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(midiOutputEnabled, forKey: "midiOutputEnabled")
        }
    }


    // MARK: - Profiling counters (ms, refreshed every UI tick)
    public private(set) var lastGlideTickMs: Double = 0
    public private(set) var maxGlideTickMs: Double = 0
    public private(set) var lastLockWaitMicros: Double = 0
    public private(set) var lastLockAcquisitions: UInt64 = 0
    private var profilingWindowStart: TimeInterval = 0
    private var maxGlideTickInWindow: Double = 0

    private var uiUpdateCounter: Int = 0
    private let uiUpdateInterval: Int = 4  // publish every 4th tick (~15Hz)

    /// Pauses the glide loop and motion processing.
    public var paused: Bool = false

    /// Raw tilt values cached each tick (3 axes, −1…+1).
    public var currentTilt: [Double] = [0, 0, 0]

    /// Slider values (0…1); revert to their defaults when not touched.
    public var slider1Value: Double = Config.slider1Default
    public var slider2Value: Double = Config.slider2Default
    public var slider1Touched: Bool = false
    public var slider2Touched: Bool = false

    /// Per-note dimension values of the most recent voice (UI display).
    public var lastActiveAccelPressure: Double { pitchChannels[lastActiveVoiceIndex].accelPressure }
    public var lastActiveKeyY: Double { pitchChannels[lastActiveVoiceIndex].keyY }

    /// Index of the most recently activated voice — the per-note fallback.
    private var lastActiveVoiceIndex: Int = 0

    /// A dimension's normalized value: tilts −1…+1 (rest 0), else 0…1.
    public func normalizedDimension(for dim: InputDimension, voiceIndex: Int? = nil) -> Double {
        switch dim {
        case .tilt1:
            return currentTilt.count > 0 ? currentTilt[0] : 0
        case .tilt2:
            return currentTilt.count > 1 ? currentTilt[1] : 0
        case .tilt3:
            return currentTilt.count > 2 ? currentTilt[2] : 0
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
        case .tilt4, .wrist2, .wrist3, .jcAccel, .stickX, .stickY,
             .strike, .acceleration, .fingerAccel:
            return 0
        case .none:
            return 0.5
        }
    }

    /// Glide time per semitone (s).
    public var glideTimePerSemitone: Double {
        NoteManager.glideSpeedSecPerSemitone
    }

    /// Mid-glide compression threshold (s).
    public var glideMaxWait: Double {
        NoteManager.glideCompressionSec
    }

    public var motionSource: MotionSource?
    public var midiEngine: MIDIEngine?

    /// The keyboard layout + tuning, persisted.
    public var scale: Scale = Scale.load() {
        didSet { scale.save() }
    }

    public var startNote: Int { scale.startNote }
    public var noteCount: Int { scale.noteCount }

    // MARK: - Drag State
    private var dragSnapTimer: Timer?
    private var touchOriginX: [Int: Double] = [:]  // touchId → origin xFraction
    private var drag = DragInfo(lastDragX: 0)

    /// Nearest enabled note (`whiteOnly` skips black keys).
    private func nearestEnabledNote(to semitone: Double, whiteOnly: Bool = false) -> Int {
        return scale.nearestEnabledNote(to: semitone, whiteOnly: whiteOnly)
    }

    /// x fraction → continuous MIDI note through the white-key layout.
    private func continuousMidiNote(xFraction: Double) -> Double {
        let whites = whiteNotes
        let whiteCount = whites.count
        guard whiteCount > 1 else { return Double(startNote) }

        let clamped = max(0, min(1, xFraction))
        let keyPos = clamped * Double(whiteCount) - 0.5
        let lowerIdx = max(0, min(whiteCount - 1, Int(floor(keyPos))))
        let upperIdx = min(lowerIdx + 1, whiteCount - 1)
        let frac = max(0, min(1, keyPos - Double(lowerIdx)))

        let lowerNote = Double(whites[lowerIdx])
        let upperNote = Double(whites[upperIdx])
        return lowerNote + frac * (upperNote - lowerNote)
    }

    // MARK: - MPE Channel Allocation

    /// Round-robin through channels 1–15 (0 is the MPE master).
    private var nextMpeChannel: UInt8 = 1
    /// Channels whose bend-range RPN has been sent (first use only;
    /// `panic()` doesn't reset it — CC 123 leaves RPN state untouched).
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

    /// A registered touch whose note has not fired yet.
    private struct PendingTouch {
        let touchId: Int
        let midiNote: Int
        let touchTimestamp: TimeInterval
        let keyY: Double
        let timer: Timer
    }
    private var pendingTouches: [Int: PendingTouch] = [:]

    /// A touch within `Config.releaseGracePeriod` of the last lift connects
    /// as a glide.
    private var releaseGraceTimer: Timer?

    // MARK: - Drag Tracking

    private struct DragInfo {
        var lastDragX: Double
        var dragDirection: Int = 0
        var dragInWhiteZone: Bool = true
        var snapOriginX: Double = 0  // x when the snap engaged (dead zone)
    }

    // MARK: - Glide Speed Physics


    // MARK: - Glide Update Loop

    private var glideTimer: Timer?
    private var lastTickTime: TimeInterval = 0

    // Fixed glide-engine constants for the in-process keyboard/audition
    // path; nothing on the live playing path reads them.
    static let glideSpeedSecPerSemitone = 0.110
    static let glideCompressionSec = 0.0275
    static let dragSmoothingCoeff = 0.3
    static let glideCurveK = 7.5
    static let fixedVelocity = 92

    public init() {
        startGlideLoop()
    }

    /// Starts the 60 Hz timer.
    private func startGlideLoop() {
        lastTickTime = CACurrentMediaTime()
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.glideUpdate()
        }
    }

    /// The 60 Hz tick: glide + tilt report.
    private func glideUpdate() {
        if paused {
            lastTickTime = CACurrentMediaTime()
            return
        }
        let tickStart = CACurrentMediaTime()

        if let tilts = motionSource?.normalizedTilts {
            for i in 0..<min(tilts.count, 3) {
                currentTilt[i] = max(-1, min(1, tilts[i]))
            }
        }

        let now = CACurrentMediaTime()
        let dt = now - lastTickTime
        lastTickTime = now

        if pitchChannels[0].state != .idle {
            updateVoiceGlide(voiceIndex: 0, dt: dt)
            updateVoiceExpression(voiceIndex: 0, dt: dt)
        }
        // The raw tilt report streams CONTINUOUSLY, not just while a note
        // sounds — the Mac's body fusion consumes it as its arm sensor,
        // including during calibration with no note down.
        sendTiltReport()

        let tickElapsed = (CACurrentMediaTime() - tickStart) * 1000.0
        lastGlideTickMs = tickElapsed
        if tickElapsed > maxGlideTickInWindow { maxGlideTickInWindow = tickElapsed }

        uiUpdateCounter += 1
        if uiUpdateCounter >= uiUpdateInterval {
            uiUpdateCounter = 0
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

    /// Advances one voice's drag smoothing, glide segment and release.
    private func updateVoiceGlide(voiceIndex i: Int, dt: Double) {
        if pitchChannels[i].dragging && pitchChannels[i].dragTargetFreq > 0 {
            let logCurrent = log2(pitchChannels[i].currentFrequency)
            let logTarget = log2(pitchChannels[i].dragTargetFreq)
            let baseSmoothingVal = NoteManager.dragSmoothingCoeff
            let smoothing = pitchChannels[i].snapping ? min(baseSmoothingVal * 2.0, 1.0) : baseSmoothingVal
            let logSmoothed = logCurrent + (logTarget - logCurrent) * smoothing
            pitchChannels[i].currentFrequency = pow(2.0, logSmoothed)
            pitchChannels[i].targetFrequency = pitchChannels[i].dragTargetFreq

            sendPitchBend(for: i)

            // Released mid-drag: release once the snap converges.
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

        if !pitchChannels[i].dragging && pitchChannels[i].glideProgress < 1.0 {
            pitchChannels[i].glideProgress += dt / pitchChannels[i].glideDuration
            pitchChannels[i].glideProgress = min(pitchChannels[i].glideProgress, 1.0)

            // Asymmetric sigmoid easing in log-frequency space.
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

        if pitchChannels[i].state == .releasing && pitchChannels[i].glideProgress >= 1.0 {
            if midiOutputEnabled {
                let midiCh = pitchChannels[i].midiChannel
                midiEngine?.sendNoteOff(note: UInt8(pitchChannels[i].baseNote), channel: midiCh)
                midiEngine?.sendPitchBend(value: 8192, channel: midiCh)
            }
            pitchChannels[i].state = .idle
        }
    }

    /// Pitch bend only (no aftertouch/CC — the Mac evaluates tilt).
    private func updateVoiceExpression(voiceIndex i: Int, dt: Double) {
        guard midiOutputEnabled else { return }
        sendPitchBend(for: i)
    }

    /// The outbound play state the tick writes raw tilt (uncalibrated
    /// attitude), acceleration and strike into — change-gated there, atomic
    /// with pitch on the wire.
    public weak var playState: OutboundPlayState?

    private func sendTiltReport() {
        guard let playState else { return }
        for (i, dim) in TiltAxisWire.dims.enumerated() {
            playState.setTilt(i, normalizedDimension(for: dim))
        }
        if let a = motionSource?.rawAccel, a.count >= 3 {
            playState.setAccel(a[0], a[1], a[2])
        }
        if let s = motionSource?.strikeLevel {
            playState.setStrike(s)
        }
    }

    // MARK: - Glide Queue

    /// A segment reached progress 1: pop the next waypoint.
    private func glideCompleted(voiceIndex: Int = 0) {
        pitchChannels[voiceIndex].currentFrequency = pitchChannels[voiceIndex].targetFrequency
        advanceQueue(voiceIndex: voiceIndex)
    }

    /// Pops the next waypoint and begins gliding to it.
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

    /// White-key MIDI notes in the keyboard range.
    public var whiteNotes: [Int] {
        scale.whiteNotesInRange()
    }

    /// yFraction (0 = top) → key Y (0 = bottom); black keys span the top 60%.
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

    /// Which key a touch hits (black keys: 75% width, top 60% of height).
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

        let whiteNote = whites[clampedWhiteIndex]
        if scale.isEnabled(whiteNote) {
            return HitResult(note: whiteNote, isBlackKey: false)
        }
        let nearest = scale.nearestEnabledNote(to: Double(whiteNote))
        return HitResult(note: nearest, isBlackKey: Scale.isBlackKey(nearest))
    }

    // MARK: - Touch Events

    /// Called when a finger touches the keyboard; the note fires
    /// immediately with the fixed velocity.
    public func touchBegan(touchId: Int, xFraction: Double, yFraction: Double, motionTimestamp: TimeInterval) {
        let hit = hitTest(xFraction: xFraction, yFraction: yFraction)
        let note = hit.note
        touchOriginX[touchId] = xFraction

        let normalizedY = Self.normalizedKeyY(yFraction: yFraction, isBlackKey: hit.isBlackKey)

        fireNote(touchId: touchId, note: note, motionTimestamp: motionTimestamp, keyY: normalizedY)
    }

    /// A finger lifted: the last lift releases after the grace period,
    /// otherwise the return to the held note is queued.
    public func touchEnded(touchId: Int) {
        touchOriginX.removeValue(forKey: touchId)

        if let pending = pendingTouches.removeValue(forKey: touchId) {
            pending.timer.invalidate()
            fireNote(touchId: touchId, note: pending.midiNote,
                     motionTimestamp: pending.touchTimestamp, keyY: pending.keyY)
        }

        dragSnapTimer?.invalidate()
        dragSnapTimer = nil

        if pitchChannels[0].dragging {
            snapToNearestPitch()
            pitchChannels[0].releaseAfterSnap = true
        } else {
            pitchChannels[0].dragging = false
        }

        guard pitchChannels[0].touchNotes.keys.contains(touchId) else { return }
        pitchChannels[0].touchNotes.removeValue(forKey: touchId)

        if pitchChannels[0].touchNotes.isEmpty {
            pitchChannels[0].queue.removeAll()
            releaseGraceTimer?.invalidate()
            releaseGraceTimer = Timer.scheduledTimer(withTimeInterval: Config.releaseGracePeriod, repeats: false) { [weak self] _ in
                guard let self else { return }
                guard self.pitchChannels[0].touchNotes.isEmpty else { return }
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
            let now = CACurrentMediaTime()
            if let remainingNote = pitchChannels[0].touchNotes.values.first {
                let isCurrentTarget = pitchChannels[0].targetNote == remainingNote
                let alreadyQueued = pitchChannels[0].queue.contains { $0.note == remainingNote }
                if !isCurrentTarget && !alreadyQueued {
                    pitchChannels[0].queue.append(GlideWaypoint(note: remainingNote, timestamp: now))

                    if pitchChannels[0].glideProgress < 1.0 {
                        let remaining = 1.0 - pitchChannels[0].glideProgress
                        let currentRemaining = remaining * pitchChannels[0].glideDuration
                        if currentRemaining > glideMaxWait {
                            pitchChannels[0].glideDuration = glideMaxWait / remaining
                        }
                    }
                }

                if pitchChannels[0].glideProgress >= 1.0 && !pitchChannels[0].queue.isEmpty {
                    advanceQueue()
                }
            }
        }
    }

    /// A finger moved: a single finger drags pitch continuously and snaps
    /// when it stops.
    public func touchMoved(touchId: Int, xFraction: Double, yFraction: Double) {
        guard pitchChannels[0].state == .sounding,
              pitchChannels[0].touchNotes.keys.contains(touchId) else { return }

        let hit = hitTest(xFraction: xFraction, yFraction: yFraction)
        pitchChannels[0].keyY = Self.normalizedKeyY(yFraction: yFraction, isBlackKey: hit.isBlackKey)

        guard pitchChannels[0].touchNotes.count == 1 else { return }

        if tryEnterDrag(voiceIndex: 0, touchId: touchId, xFraction: xFraction, yFraction: yFraction) {
            drag = DragInfo(lastDragX: xFraction, dragDirection: 0, dragInWhiteZone: yFraction >= 0.6)
        }
        guard pitchChannels[0].dragging else { return }

        processDrag(voiceIndex: 0, touchId: touchId, xFraction: xFraction, yFraction: yFraction,
                    hit: hit, drag: &drag)

        dragSnapTimer?.invalidate()
        let snapX = xFraction
        dragSnapTimer = Timer.scheduledTimer(withTimeInterval: Config.dragSnapDelay, repeats: false) { [weak self] _ in
            self?.drag.snapOriginX = snapX
            self?.snapToNearestPitch()
        }
    }

    /// Drag target from finger movement, with reversal correction and the
    /// snap dead zone.
    private func processDrag(voiceIndex: Int, touchId: Int, xFraction: Double, yFraction: Double,
                             hit: HitResult, drag: inout DragInfo) {
        drag.dragInWhiteZone = yFraction >= 0.6
        pitchChannels[voiceIndex].displayNote = hit.note

        let continuousNote = continuousMidiNote(xFraction: xFraction)
        let fingerFreq = scale.frequency(for: continuousNote)

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

    /// Enters drag mode after a third of a key; true on the entering tick.
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

    /// Drag target = the nearest scale tone.
    private func snapToNearestPitch(voiceIndex: Int = 0, whiteOnly: Bool? = nil) {
        guard pitchChannels[voiceIndex].state == .sounding, pitchChannels[voiceIndex].dragging else { return }

        let useWhiteOnly = whiteOnly ?? drag.dragInWhiteZone
        let currentSemitone = 12.0 * log2(pitchChannels[voiceIndex].currentFrequency / 440.0) + 69.0
        let nearestNote = nearestEnabledNote(to: currentSemitone, whiteOnly: useWhiteOnly)
        let targetFreq = scale.frequency(for: nearestNote)

        pitchChannels[voiceIndex].dragTargetFreq = targetFreq
        pitchChannels[voiceIndex].targetNote = nearestNote
        pitchChannels[voiceIndex].displayNote = nearestNote
        pitchChannels[voiceIndex].snapping = true
    }

    // MARK: - Note Firing

    /// Fires a note: activates an idle channel, registers a touch on the
    /// current note, or queues a glide.
    private func fireNote(touchId: Int, note: Int, motionTimestamp: TimeInterval, keyY: Double) {
        pendingTouches.removeValue(forKey: touchId)

        let normalized = 0.5
        pitchChannels[lastActiveVoiceIndex].accelPressure = normalized
        pitchChannels[lastActiveVoiceIndex].keyY = keyY
        let velocity = NoteManager.fixedVelocity

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

        if pitchChannels[0].state == .idle {
            activateChannel(touchId: touchId, note: note, velocity: velocity,
                            accelPressure: normalized, keyY: keyY)
            return
        }

        startGlide(touchId: touchId, targetNote: note, velocity: velocity)
    }

    /// Activates an idle voice: fresh MPE channel, bend range, noteOn.
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

    /// Queues a glide (started at once when at rest).
    private func startGlide(touchId: Int, targetNote: Int, velocity: Int, voiceIndex: Int = 0) {
        let now = CACurrentMediaTime()
        releaseGraceTimer?.invalidate()
        releaseGraceTimer = nil
        pitchChannels[voiceIndex].touchNotes[touchId] = targetNote
        pitchChannels[voiceIndex].state = .sounding
        pitchChannels[voiceIndex].dragging = false
        pitchChannels[voiceIndex].releaseAfterSnap = false

        let waypoint = GlideWaypoint(note: targetNote, timestamp: now)
        pitchChannels[voiceIndex].queue.append(waypoint)

        if pitchChannels[voiceIndex].glideProgress >= 1.0 {
            advanceQueue(voiceIndex: voiceIndex)
        } else {
            let remaining = 1.0 - pitchChannels[voiceIndex].glideProgress
            let currentRemaining = remaining * pitchChannels[voiceIndex].glideDuration
            if currentRemaining > glideMaxWait {
                pitchChannels[voiceIndex].glideDuration = glideMaxWait / remaining
            }
        }
    }

    /// noteOff at rest, an accelerated `.releasing` glide otherwise.
    private func releaseVoice(_ voiceIndex: Int) {
        pitchChannels[voiceIndex].touchNotes.removeAll()
        pitchChannels[voiceIndex].queue.removeAll()

        if pitchChannels[voiceIndex].glideProgress < 1.0 {
            pitchChannels[voiceIndex].glideDuration *= 0.3
            pitchChannels[voiceIndex].state = .releasing
        } else {
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

    /// Silences everything and clears all state.
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
        dragSnapTimer?.invalidate()
        dragSnapTimer = nil
        touchOriginX.removeAll()
    }

    deinit {
        glideTimer?.invalidate()
    }
}
