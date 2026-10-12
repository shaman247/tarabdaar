import Foundation
import SarangiKit

// Display-only readouts: the Live tab's performance readout, the iPad
// volume levels, the voice telemetry passthroughs and the Scope snapshot.
extension AudioEngine {
    public func pitchProfile(tonicSemis: Double, ratios: [Double]) -> PerformancePitchProfile.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        performanceProfile.configure(tonicSemis: tonicSemis, ratios: ratios, at: now)
        return performanceProfile.snapshot(at: now)
    }

    public func resetPitchProfile(seed: Bool = false) {
        lock.lock()
        performanceProfile.reset(at: ProcessInfo.processInfo.systemUptime, seed: seed)
        lock.unlock()
    }

    public func finishPitchProfileSeed() {
        lock.lock()
        performanceProfile.finishSeed(at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    public func setPerformanceTarafProfile(tonic: Double, ratios: [Double], gains: [Double], unmatchedGain: Double) {
        lock.lock()
        let source = stringVoiceSource
        lock.unlock()
        source?.setPerformanceProfile(tonic: tonic, ratios: ratios, gains: gains, unmatchedGain: unmatchedGain)
    }

    /// Evaluated controls of the highest held bowed note; plucked voices have no bow controls.
    public func noteControls() -> TLPNoteControls {
        lock.lock()
        let source = mainInstrumentStorage == .string ? stringVoiceSource : nil
        lock.unlock()
        guard let source else { return .idle }
        return Self.noteControls(mapper: source.mapper)
    }

    static func noteControls(mapper: BowControlMapper) -> TLPNoteControls {
        var snapshot = BowControlMapper.PolySnapshot(count: BowControlMapper.maxSlots)
        mapper.snapshotPoly(into: &snapshot)
        guard let highest = snapshot.slots.filter({ $0.gate > 0 })
            .max(by: { $0.f0Target < $1.f0Target }) else { return .idle }
        return TLPNoteControls(expression: snapshot.expr * highest.exprScale,
                               pressure: snapshot.press, position: snapshot.pos)
    }

    // MARK: - Live performance readout (Live tab)

    /// Live-tab readout: held pitch and the latest main-voice interval RMS.
    /// Released strings can still sound while `active` is false.
    public struct PerformanceReadout {
        public let pitchHz: Double
        public let voiceRMS: Double
        public let active: Bool
    }

    /// The destructive meter poll and nondestructive UI snapshots share this cache.
    final class PerformanceMeter {
        private let lock = NSLock()
        private var pitchHz = 0.0
        private var voiceRMS = 0.0
        private var active = false

        func storeTouch(_ touch: (Double, Bool)) {
            lock.lock()
            pitchHz = touch.0
            active = touch.1
            lock.unlock()
        }

        func captureVolume(_ sample: () -> (voice: Double, chromatic: Double, raga: Double))
            -> (voice: Double, chromatic: Double, raga: Double) {
            let levels = sample()
            lock.lock()
            voiceRMS = levels.voice
            lock.unlock()
            return levels
        }

        func readout() -> PerformanceReadout {
            lock.lock()
            defer { lock.unlock() }
            return PerformanceReadout(pitchHz: pitchHz, voiceRMS: voiceRMS, active: active)
        }
    }

    /// Thread-safe, nondestructive snapshot; polling never consumes audio meters.
    public func performanceReadout() -> PerformanceReadout { performanceMeter.readout() }

    /// Bus levels of the main voice, chromatic taraf and raga taraf for
    /// the iPad's volume scope. Voice = the String voice bus plus the main
    /// instrument's node when plucked (energy sum; the drone never counts).
    /// Interval RMS since the previous poll, linear, 1.0 ≈ 0 dBFS. ONE poller.
    public func volumeLevels() -> (voice: Double, chromatic: Double, raga: Double) {
        performanceMeter.captureVolume {
            let bus = stringVoiceSource?.busLevels() ?? (voice: 0, taraf: 0, chromatic: 0, raga: 0)
            lock.lock()
            let voice = playedVoiceLocked(mainInstrumentStorage)
            lock.unlock()
            var voiceSq = bus.voice * bus.voice
            if let l = voice?.outputLevel() { voiceSq += l * l }
            return (voiceSq.squareRoot(), bus.chromatic, bus.raga)
        }
    }

    /// `(pitchHz, active)` for the primary held voice. `lock` held.
    func meterSnapshotLocked() -> (Double, Bool) {
        guard let id = heldTouchOrder.last, let semis = touchPitchSemis[id] else {
            return (0, false)
        }
        return (Pitch.hz(fractionalMidi: semis), true)
    }

    /// Publish after releasing `lock`; a touch release leaves ringing RMS intact.
    func storeMeter(_ snap: (Double, Bool)) { performanceMeter.storeTouch(snap) }

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
            /// String voice only: fundamental dominance P1 / max(P2…P4)
            /// (Helmholtz motion > 1; an overtone lock reads under 0.1) and
            /// the regime grip amount 0…1. 0 for the plucked voices.
            public let capture: Double
            public let grip: Double
        }
        public var voices: [Voice] = []
        public var taraf: [BowEngine.ScopeRow] = []
        public var instrument: MainInstrument = .string
    }

    /// Arm/disarm the kernel's display meters (unarmed = byte-null).
    public func setScopeArmed(_ on: Bool) {
        stringVoiceSource?.setScopeArmed(on)
    }

    /// Bowed-string ring envelope (0.5 = full scale) → the ONE 0…1 level
    /// law (`TLPVolume.level01`, 60 dB range).
    static func bowScopeLevel01(_ senv: Double) -> Double {
        TLPVolume.level01(linear: senv / 0.5)
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
        let voice = playedVoiceLocked(inst)
        lock.unlock()
        var snap = ScopeSnapshot()
        snap.instrument = inst
        snap.taraf = src?.scopeRows() ?? []
        snap.voices = voice?.scopeVoices() ?? []
        return snap
    }

    // MARK: - Body response (Body tab)

    /// Identity of the String voice's published engine — changes on every rebuild.
    public func stringVoiceEngineIdentity() -> ObjectIdentifier? {
        lock.lock()
        let src = stringVoiceSource
        lock.unlock()
        guard let engine = src?.currentEngine() else { return nil }
        return ObjectIdentifier(engine)
    }

    public struct BodyResponseVersion: Equatable {
        public let engine: ObjectIdentifier
        public let coefficients: UInt64
    }

    /// Cheap revision for both engine replacements and adopted in-place coefficient changes.
    public func stringVoiceBodyVersion() -> BodyResponseVersion? {
        lock.lock()
        let src = stringVoiceSource
        lock.unlock()
        guard let engine = src?.currentEngine() else { return nil }
        return BodyResponseVersion(engine: ObjectIdentifier(engine),
                                   coefficients: engine.bodyResponseRevision)
    }

    /// The formula body's adopted coefficient response (see `BowEngine.bodyResponse`).
    /// Allocates; nil unarmed.
    public func stringVoiceBodyResponse(points: Int = 1024)
        -> BowEngine.BodyResponse? {
        lock.lock()
        let src = stringVoiceSource
        lock.unlock()
        return src?.currentEngine()?.bodyResponse(points: points)
    }

    /// Render-deadline telemetry (see `StringVoiceSource.renderStats`); nil without a voice.
    public func stringVoiceRenderStats() -> (maxMs: Double, overruns: UInt64,
                                             callbacks: UInt64)? {
        stringVoiceSource?.renderStats()
    }
}
