import Foundation
import SarangiKit

// Display-only readouts: the Live tab's performance readout, the iPad
// volume levels, the voice telemetry passthroughs and the Scope snapshot.
extension AudioEngine {
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
    /// Expression reads 0 — the axis idles in the mapper.
    func meterSnapshotLocked() -> (Double, Double, Bool) {
        guard let id = heldTouchOrder.last, let semis = touchPitchSemis[id] else {
            return (0, 0, false)
        }
        return (Pitch.hz(fractionalMidi: semis), 0, true)
    }

    /// Publish a snapshot. Takes `meterLock`, which must never nest with `lock`.
    func storeMeter(_ snap: (Double, Double, Bool)) {
        meterLock.lock()
        meterPitchHz = snap.0
        meterExpr = snap.1
        meterActive = snap.2
        meterLock.unlock()
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
                    held: s.gated, level: Self.bowScopeLevel01(s.level),
                    capture: s.capture, grip: s.grip))
            }
        case .tanpura, .sitar:
            guard let engine = pluck?.currentEngine() else { break }
            for (i, s) in engine.scopeSlots().enumerated()
                where s.level > 0 {
                snap.voices.append(.init(
                    id: i, pitchHz: s.hz, held: heldSlots.contains(i),
                    level: Self.pluckScopeLevel01(s.level),
                    capture: 0, grip: 0))
            }
        }
        return snap
    }

    // MARK: - Body response (Body tab)

    /// Identity of the String voice's published engine — changes on every
    /// rebuild, so the Body tab recomputes only when the body did. Cheap.
    public func stringVoiceEngineIdentity() -> ObjectIdentifier? {
        lock.lock()
        let src = stringVoiceSource
        lock.unlock()
        guard let engine = src?.currentEngine() else { return nil }
        return ObjectIdentifier(engine)
    }

    /// The formula body's frequency response as built into the running
    /// engine (see `BowEngine.bodyResponse`). Allocates; nil unarmed.
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
