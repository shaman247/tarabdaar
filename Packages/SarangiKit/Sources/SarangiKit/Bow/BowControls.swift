import Foundation

/// MIDI/UI/touch events → kernel-rate bow controls (f0, vbow, fbow, beta,
/// gate). The control thread writes target state under a lock; once per
/// render buffer the audio thread snapshots it and fills per-sample arrays,
/// interpolating the axes linearly from the previous snapshot:
///
///   * f0    — slot pitch → log-f0 ramped across the block to the latest
///             target (meend is the finger's own movement), then the
///             calibrated `pitch_cents` correction.
///   * gate  — note state through a ~25 ms one-pole.
///   * vbow  — expression (CC11) → dB (rel ∈ [−14, +5]) → v =
///             v_ref·10^(rel/(20·dyn_p)) clipped to [v_lo, 1.3·v_hi]
///             (dyn_p ≤ 0.1: affine). Rides [bow_expr_lift, 1]; below the
///             lift the bow fades to SILENCE.
///   * fbow  — press (CC1) → LOG-force position across the analytic
///             Schelleng wedge, edges reachable (see `fill`).
///   * beta  — pos (CC74) affine in [bow_live_beta_lo, bow_live_beta_hi];
///             tilt (CC2, dB) moves toward the bridge (bow_tilt_beta, soft
///             knee) and brightens force (bow_tilt_force).
///
/// Starts from silence (no pre-roll). Articulation, vibrato and glide
/// gestures are the player's, supplied on the axes.
public final class BowControlMapper: @unchecked Sendable {

    /// Fixed slot-table size (the engine's `maxPoly` is clamped to this).
    public static let maxSlots = 16

    /// Note identity on a slot. `.midi` = the in-process MIDI path (pitch =
    /// note + per-channel bend; the parity substrate). `.touch` = the
    /// TarabLink path (pitch = the fractional-MIDI Double `touchSemis`).
    enum SlotKey: Equatable {
        case midi(note: UInt8, ch: UInt8)
        case touch(id: UInt16)
    }

    /// One voice slot = one gut string on the shared bridge. EVERY note-on
    /// mounts a FRESH string (unused slot, else longest-released, else the
    /// oldest sounding note is stolen) and bumps `serial` — the engine
    /// zeroes that kernel string and snaps its pitch, so pitch never glides
    /// BETWEEN notes. Note-off only lifts the bow; the string rings on.
    private struct Slot {
        var key: SlotKey = .midi(note: 69, ch: 0)
        var gateOn = false
        var used = false
        var serial: UInt32 = 0
        var lastOn: UInt64 = 0
        var lastOff: UInt64 = 0
        /// Onset strike velocity 0…1 (MIDI d2/127 or the touch frame's
        /// velocity byte); read only when `bow_attack_vel` > 0.
        var onVel: Double = 0.0
        /// Pitch of a `.touch` key, fractional MIDI (69.0 = A440): updated
        /// by `touchGlide` while gated, FROZEN on release.
        var touchSemis: Double = 69.0
        /// Per-slot expression scale on the GLOBAL expr axis (the strum
        /// chord's per-note expression); frozen on release. ×1.0 is an IEEE
        /// identity, so every path but the strum is bit-exact.
        var exprScale: Double = 1.0
    }

    // ---- control-thread state (locked) ----
    private var lock = os_unfair_lock()
    private var slots = [Slot](repeating: Slot(), count: BowControlMapper.maxSlots)
    private var slotLimit = 1
    private var evt: UInt64 = 0
    /// Pitch bend PER CHANNEL (semitones).
    private var chBend = [Double](repeating: 0.0, count: 16)
    private var expr: Double
    private var press: Double
    private var pos: Double
    private var tilt01: Double
    /// Player vibrato = aftertouch depth 0..1 into bow_vib_cents at
    /// bow_vib_hz — never free-running.
    private var vibAT = 0.0
    public var bendRange = 2.0             // semitones at full wheel

    /// Tilt axis dB mapping: CC2 0…127 spans [tiltMinDb, tiltMaxDb];
    /// neutral 0 dB ≈ CC 42.
    public static let tiltMinDb = -12.0
    public static let tiltMaxDb = 24.3

    /// Idle operating point: the calibrated medians the voice is fitted
    /// around, tilt neutral.
    public init() {
        expr = 0.251
        press = 0.562
        pos = 0.45
        tilt01 = -BowControlMapper.tiltMinDb
            / (BowControlMapper.tiltMaxDb - BowControlMapper.tiltMinDb)
    }

    /// Usable slot count = the engine's polyphony (the long-lived mapper
    /// keeps held notes across rebuilds). Shrinking releases the gates of
    /// the slots that fall outside.
    public func setSlotLimit(_ n: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let lim = min(max(n, 1), BowControlMapper.maxSlots)
        if lim < slotLimit {
            evt += 1
            for i in lim..<slotLimit where slots[i].gateOn {
                slots[i].gateOn = false
                slots[i].lastOff = evt
            }
        }
        slotLimit = lim
    }

    /// Every note-on = a fresh string. Returns the mounted slot index so
    /// the touch path can seed its pitch. Callers hold the lock.
    @discardableResult
    private func noteOn(key: SlotKey, vel: Double) -> Int {
        evt += 1
        let lim = slotLimit
        // a note-on for a key already gated = a retrigger: release that
        // slot, the old string rings on at its frozen pitch
        for i in 0..<lim where slots[i].gateOn && slots[i].key == key {
            slots[i].gateOn = false
            slots[i].lastOff = evt
        }
        // fresh string: unused slot, else longest-released, else steal
        // the oldest sounding note
        var i = -1
        for s in 0..<lim where !slots[s].used { i = s; break }
        if i < 0 {
            for s in 0..<lim where !slots[s].gateOn {
                if i < 0 || slots[s].lastOff < slots[i].lastOff { i = s }
            }
        }
        if i < 0 {
            for s in 0..<lim {
                if i < 0 || slots[s].lastOn < slots[i].lastOn { i = s }
            }
        }
        slots[i].serial &+= 1
        slots[i].key = key
        slots[i].gateOn = true
        slots[i].used = true
        slots[i].lastOn = evt
        slots[i].onVel = vel
        // a reused slot must not inherit a strum note's expression scale
        slots[i].exprScale = 1.0
        return i
    }

    private func noteOff(key: SlotKey) {
        evt += 1
        for i in 0..<slotLimit where slots[i].gateOn && slots[i].key == key {
            slots[i].gateOn = false
            slots[i].lastOff = evt
        }
    }

    /// In-process MIDI: note on/off, CC11 expr · CC1 press · CC74 pos ·
    /// CC2/CC75 tilt, per-channel bend, aftertouch vibrato, CC120/123
    /// all-off. The channel nibble keys note identity and bend; CCs are
    /// global.
    public func midi(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        let kind = status & 0xF0
        let ch = status & 0x0F
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        switch kind {
        case 0x90 where d2 > 0:
            noteOn(key: .midi(note: d1, ch: ch), vel: Double(d2) / 127.0)
        case 0x80, 0x90:
            noteOff(key: .midi(note: d1, ch: ch))
        case 0xE0:
            let raw = Int(d2) << 7 | Int(d1)
            chBend[Int(ch)] = (Double(raw) - 8192.0) / 8192.0 * bendRange
        case 0xD0:                          // channel aftertouch → vibrato
            vibAT = Double(d1) / 127.0
        case 0xA0:                          // poly aftertouch (any note)
            vibAT = Double(d2) / 127.0
        case 0xB0:
            let v = Double(d2) / 127.0
            switch d1 {
            case 11: expr = v
            case 1: press = v
            case 74: pos = v
            case 2, 75: tilt01 = v
            case 120, 123:
                evt += 1
                for i in slots.indices where slots[i].gateOn {
                    slots[i].gateOn = false
                    slots[i].lastOff = evt
                }
            default: break
            }
        default: break
        }
    }

    // MARK: TarabLink touch path (full-resolution pitch, touch-id keyed)

    /// Note-on from a TarabLink frame: fractional-MIDI pitch, onset strike
    /// `velocity` 0…1 (inert while `bow_attack_vel` is 0), `exprScale`
    /// (see `Slot.exprScale`). Same allocation as the MIDI path.
    public func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double,
                        exprScale: Double = 1.0) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let i = noteOn(key: .touch(id: id), vel: min(max(velocity, 0.0), 1.0))
        slots[i].touchSemis = pitchSemis
        slots[i].exprScale = min(max(exprScale, 0.0), 1.0)
    }

    /// Expression-scale update for a held touch (gated slot only).
    public func setExprScale(_ scale: Double, forTouch id: UInt16) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<slotLimit
        where slots[i].gateOn && slots[i].key == .touch(id: id) {
            slots[i].exprScale = min(max(scale, 0.0), 1.0)
        }
    }

    /// Pitch update for a held touch (gated slot only; the render side
    /// ramps to it within one block). A released string keeps its pitch.
    public func touchGlide(_ id: UInt16, pitchSemis: Double) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<slotLimit
        where slots[i].gateOn && slots[i].key == .touch(id: id) {
            slots[i].touchSemis = pitchSemis
        }
    }

    /// Note-off (bow lift) for a touch; the string rings on.
    public func touchOff(_ id: UInt16) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        noteOff(key: .touch(id: id))
    }

    /// All bows off (link drop / panic) — the touch twin of CC123.
    public func touchAllOff() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        evt += 1
        for i in slots.indices where slots[i].gateOn {
            slots[i].gateOn = false
            slots[i].lastOff = evt
        }
    }

    /// UI setters (the same axes the sliders drive through CCs).
    public func setAxis(expr e: Double? = nil, press p: Double? = nil,
                        pos ps: Double? = nil, tilt t: Double? = nil) {
        os_unfair_lock_lock(&lock)
        if let e { expr = min(max(e, 0), 1) }
        if let p { press = min(max(p, 0), 1) }
        if let ps { pos = min(max(ps, 0), 1) }
        if let t { tilt01 = min(max(t, 0), 1) }
        os_unfair_lock_unlock(&lock)
    }

    struct Snapshot {
        var f0Target: Double
        var gate: Double
        var expr: Double, press: Double, pos: Double, tiltDb: Double
        var vib: Double = 0.0              // aftertouch vibrato depth 0..1
        /// Onset strike velocity 0…1 (read at a fresh attack edge).
        var onVel: Double = 0.0
    }

    /// One voice slot as the render thread sees it; a `serial` change means
    /// a fresh string was mounted (the engine zeroes it and snaps pitch).
    public struct SlotSnapshot: Sendable {
        public var f0Target: Double = 440.0
        public var gate: Double = 0.0
        public var serial: UInt32 = 0
        /// Onset strike velocity 0…1 (see `Snapshot.onVel`).
        public var onVel: Double = 0.0
        /// Per-slot expression scale (see `Slot.exprScale`); 1 = neutral.
        public var exprScale: Double = 1.0
    }

    /// Poly snapshot into a preallocated buffer (render thread, no
    /// allocation). `lead` = newest gated slot, else newest used.
    public struct PolySnapshot: Sendable {
        public var expr = 0.0, press = 0.0, pos = 0.0, tiltDb = 0.0
        public var vib = 0.0               // aftertouch vibrato depth 0..1
        public var lead = 0
        public var slots: [SlotSnapshot]
        public init(count: Int) {
            slots = [SlotSnapshot](repeating: SlotSnapshot(),
                                   count: max(1, count))
        }
    }

    /// Pitch of a slot. Keep the .midi expression TEXTUALLY as it is — the
    /// render hash depends on its FP evaluation order. Callers hold the lock.
    private func f0TargetLocked(_ slot: Slot) -> Double {
        switch slot.key {
        case .midi(let note, let ch):
            return 440.0 * pow(2.0, (Double(note) - 69.0 + chBend[Int(ch)]) / 12.0)
        case .touch:
            return 440.0 * pow(2.0, (slot.touchSemis - 69.0) / 12.0)
        }
    }

    /// The newest slot: gated wins over released; ties broken by recency.
    private func leadIndex(_ lim: Int) -> Int {
        var best = 0
        var bestKey: (Int, UInt64) = (-1, 0)
        for i in 0..<lim {
            let s = slots[i]
            guard s.used else { continue }
            let key = (s.gateOn ? 1 : 0, s.lastOn)
            if key.0 > bestKey.0 || (key.0 == bestKey.0 && key.1 > bestKey.1) {
                bestKey = key
                best = i
            }
        }
        return best
    }

    public func snapshotPoly(into snap: inout PolySnapshot) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        snap.expr = expr
        snap.press = press
        snap.pos = pos
        snap.vib = vibAT
        snap.tiltDb = BowControlMapper.tiltMinDb
            + tilt01 * (BowControlMapper.tiltMaxDb - BowControlMapper.tiltMinDb)
        let lim = min(slotLimit, snap.slots.count)
        for i in 0..<lim {
            let s = slots[i]
            snap.slots[i] = SlotSnapshot(
                f0Target: f0TargetLocked(s),
                gate: s.gateOn ? 1.0 : 0.0,
                serial: s.serial,
                onVel: s.onVel,
                exprScale: s.exprScale)
        }
        for i in lim..<snap.slots.count {
            snap.slots[i].gate = 0.0
        }
        snap.lead = min(leadIndex(lim), snap.slots.count - 1)
    }

    /// Mono facade (fixtures, slotLimit-1 engines): the lead slot.
    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let i = leadIndex(slotLimit)
        let s = slots[i]
        let f0 = f0TargetLocked(s)
        let tdb = BowControlMapper.tiltMinDb
            + tilt01 * (BowControlMapper.tiltMaxDb - BowControlMapper.tiltMinDb)
        return Snapshot(f0Target: f0, gate: s.gateOn ? 1.0 : 0.0,
                        expr: expr * s.exprScale, press: press, pos: pos,
                        tiltDb: tdb, vib: vibAT, onVel: s.onVel)
    }
}

/// The render-thread half: per-sample state + the mapping constants baked
/// from BowParams; fills kernel-rate control arrays. One instance per
/// engine build (the mapper it reads is long-lived).
public struct BowControlFilter: Sendable {
    let srk: Double
    // baked mapping constants
    let aGate: Double            // 25 ms gate one-pole
    var vLo = 0.0, vHi = 0.0
    var betaLo = 0.0, betaHi = 0.0
    var pressUnder = 0.0, pressOver = 0.0   // wedge-edge overshoot factors
    var dynP = 0.0, fCap = 0.0
    var exprLift = 0.0           // expression below which the bow lifts to silence
    var schellengC = 0.0, schellengMargin = 0.0
    var schellengZ = 0.0, schellengDmu = 0.0   // analytic fmax = 2Zv/(βΔμ)
    var tiltBeta = 0.0, tiltForce = 0.0, tiltKnee = 0.0
    var betaF0Gamma = 0.0
    var fReg = 0.0, tonicHz = 261.63   // register force (f0/tonic)^k
    // PLACE-then-DRAW: at a fresh attack velocity holds ~0 for placeS (bow
    // set, static stick) then rises over drawS (smoothstep). 0 = bit-null.
    var placeS = 0.0, drawS = 0.0
    // ATTACK SHARPNESS = onset press above attackThresh: a sharp attack
    // draws fast (drawS → drawMinS) and briefly over-forces
    // (fb *= 1 + attackBite·sharp·exp(-t/biteTau)). attackBite 0 = off.
    var drawMinS = 0.0, attackBite = 0.0
    var attackBiteTau = 0.0, attackThresh = 0.0
    // sharpness = max(press law, attackVel·strike velocity). 0 = bit-null.
    var attackVel = 0.0
    // settle depth × (1 − settleSharp·sharp): accents keep their level.
    var settleSharp = 0.0
    // player vibrato (aftertouch): vibCents at vibHz on the sounding pitch
    var vibCents = 0.0, vibHz = 0.0
    // SUSTAIN LIVENESS, as dB on the bow controls (0 = bit-null):
    //   settle — settleDb·smoothstep(t/t0)·exp(-(t-t0)/tau) off the bow
    //     velocity after the place+draw window t0; restarts per attack.
    //   drift — three unit-variance OU walks (deterministic per-slot
    //     xorshift64, ~driftHz) into pitch cents, velocity dB, force dB;
    //     the body + friction chain makes the per-harmonic shimmer itself.
    //   glide dip — lightening while the pitch MOVES: glideDipDb·r/(r+rate),
    //     r = |pitch slew| cents/s (~15 ms attack, ~120 ms release); full on
    //     vbow, 0.3× on force.
    var settleDb = 0.0, settleTauS = 0.0
    var driftCents = 0.0, driftDb = 0.0, driftForceDb = 0.0
    var driftHz = 0.0
    var glideDipDb = 0.0, glideDipRate = 0.0
    var aDrift = 1.0, driftGain = 0.0   // OU pole + unit-variance step gain
    var aDipAtt = 0.0, aDipRel = 0.0    // dip smoother poles
    let pitchKnots: [Double], pitchCentsTab: [Double]
    let pitchRefLog2: Double
    let pitchKnotsA: [Double]?, pitchCentsA: [Double]?
    let pitchCentsPress: [Double]?
    var lf0 = 0.0                // sounding log2 f0 at the last sample
    var gateState = 0.0
    var attackFms = 0.0
    var placeClock = 1.0e9       // seconds since the current attack began
    var attackSharp = 0.0        // onset sharpness of the current attack
    var vibPhase = 0.0
    // liveness state (drift walks, dip smoother, per-slot deterministic RNG)
    var driftSeed: UInt64 = 0x9E3779B97F4A7C15
    var rng: UInt64 = 0x9E3779B97F4A7C15
    var ouPitch = 0.0, ouLevel = 0.0, ouForce = 0.0
    var dipDb = 0.0
    var lastLf = 0.0, lastLfValid = false
    var prev: BowControlMapper.Snapshot?
    var primed = false
    /// Fresh string mounted: the next fill captures its OWN onset sharpness
    /// (a steal happens with the gate already high — no rising edge).
    var freshMount = false

    public init(bp: BowParams, srk: Double, tonic: Double = 261.63) {
        self.srk = srk
        tonicHz = max(tonic, 40.0)
        aGate = exp(-1.0 / (0.025 * srk))
        aDipAtt = exp(-1.0 / (0.015 * srk))
        aDipRel = exp(-1.0 / (0.12 * srk))
        // two-component pitch correction when the artifact carries it
        // (A(f0) absolute + B(f0/tonic) body residual), else the single
        // 220 Hz-referenced table
        if let knR = bp.pitchKnotsRel, let ceR = bp.pitchCentsRel,
           let knA = bp.pitchKnotsAbs, let ceA = bp.pitchCentsAbs {
            pitchKnots = knR
            pitchCentsTab = ceR
            pitchRefLog2 = log2(max(tonic, 40.0))
            pitchKnotsA = knA
            pitchCentsA = ceA
            pitchCentsPress = bp.pitchCentsPress
        } else {
            pitchKnots = bp.pitchKnotsOct
            pitchCentsTab = bp.pitchCents
            pitchRefLog2 = log2(220.0)
            pitchKnotsA = nil
            pitchCentsA = nil
            pitchCentsPress = nil
        }
        loadMappingConstants(bp: bp)
    }

    /// Bake the mapping constants from the artifact. Called by `init` and
    /// by `updateLiveParams`, so a live parameter edit and a fresh filter
    /// can never read the values differently.
    private mutating func loadMappingConstants(bp: BowParams) {
        vLo = bp.v("bow_v_lo", 0.05)
        vHi = bp.v("bow_v_hi", 0.35)
        betaLo = bp.v("bow_live_beta_lo", 0.04)
        betaHi = bp.v("bow_live_beta_hi", 0.22)
        pressUnder = bp.v("bow_live_press_under", 0.55)
        pressOver = bp.v("bow_live_press_over", 1.25)
        dynP = bp.v("dyn_p", 0.0)
        fCap = bp.v("bow_f_cap", 2.6)
        exprLift = bp.v("bow_expr_lift", 0.0)
        schellengC = bp.v("bow_schelleng_c", 0.055)
        schellengMargin = bp.v("bow_schelleng_margin", 1.2)
        schellengZ = bp.v("bow_Z", 1.0)
        schellengDmu = max(bp.v("bow_mu_s", 0.8) - bp.v("bow_mu_d", 0.3), 1e-3)
        tiltBeta = bp.v("bow_tilt_beta", 0.0)
        tiltForce = bp.v("bow_tilt_force", 0.0)
        tiltKnee = bp.v("bow_tilt_knee", 0.0)
        betaF0Gamma = bp.v("bow_beta_f0", 0.0)
        fReg = bp.v("bow_f_reg", 0.0)
        placeS = bp.v("bow_place_ms", 0.0) / 1000.0
        drawS = max(bp.v("bow_draw_ms", 1.0), 1.0) / 1000.0
        drawMinS = max(bp.v("bow_draw_min_ms", bp.v("bow_draw_ms", 1.0)),
                       1.0) / 1000.0
        attackBite = bp.v("bow_attack_bite", 0.0)
        attackBiteTau = max(bp.v("bow_attack_bite_ms", 60.0), 5.0) / 1000.0
        attackFms = max(bp.v("bow_attack_fms", 15.0), 2.0) / 1000.0
        attackThresh = bp.v("bow_attack_thresh", 0.5)
        attackVel = min(max(bp.v("bow_attack_vel", 0.0), 0.0), 1.0)
        vibCents = bp.v("bow_vib_cents", 0.0)
        vibHz = bp.v("bow_vib_hz", 5.5)
        settleDb = bp.v("bow_settle_db", 0.0)
        settleTauS = max(bp.v("bow_settle_ms", 150.0), 10.0) / 1000.0
        settleSharp = min(max(bp.v("bow_settle_sharp", 0.0), 0.0), 1.0)
        driftCents = bp.v("bow_drift_cents", 0.0)
        driftDb = bp.v("bow_drift_db", 0.0)
        driftForceDb = bp.v("bow_drift_force_db", 0.0)
        driftHz = min(max(bp.v("bow_drift_hz", 1.4), 0.05), 10.0)
        glideDipDb = bp.v("bow_glide_dip_db", 0.0)
        glideDipRate = max(bp.v("bow_glide_dip_rate", 900.0), 1.0)
        aDrift = exp(-2.0 * Double.pi * driftHz / srk)
        driftGain = sqrt(max(1.0 - aDrift * aDrift, 0.0) * 3.0)
    }

    /// Re-read the mapping constants on a running filter; render state is
    /// untouched so a parameter edit does not re-articulate a sounding
    /// note (the pitch tables are structural and stay put).
    public mutating func updateLiveParams(bp: BowParams) {
        loadMappingConstants(bp: bp)
    }

    /// Decorrelate the liveness walks across slots, deterministically
    /// (renders stay bit-reproducible).
    public mutating func seedDrift(_ slot: UInt64) {
        driftSeed = 0x9E3779B97F4A7C15 &+ (slot &+ 1) &* 0xBF58476D1CE4E5B9
        rng = driftSeed
    }

    @inline(__always) private mutating func nextUniform() -> Double {
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        return Double(Int64(bitPattern: rng)) * (1.0 / 9.223372036854775808e18)
    }

    @inline(__always) func attackSharpOf(_ press: Double) -> Double {
        min(max((press - attackThresh) / max(1.0 - attackThresh, 1e-6),
                0.0), 1.0)
    }

    /// Onset sharpness: the press law, or the strike velocity when armed —
    /// whichever is sharper. attackVel 0 = `attackSharpOf(press)` exactly.
    @inline(__always) func attackSharpAt(press: Double, onVel: Double)
        -> Double {
        var s = attackSharpOf(press)
        if attackVel > 1e-9 {
            s = max(s, min(attackVel * min(max(onVel, 0.0), 1.0), 1.0))
        }
        return s
    }

    @inline(__always) func interpKnots(_ x: Double, _ kn: [Double],
                                       _ ce: [Double]) -> Double {
        if x <= kn[0] { return ce[0] }
        let last = kn.count - 1
        if x >= kn[last] { return ce[last] }
        var i = 0
        while i + 1 < kn.count && kn[i + 1] < x { i += 1 }
        let t = (x - kn[i]) / max(kn[i + 1] - kn[i], 1e-12)
        return ce[i] + t * (ce[i + 1] - ce[i])
    }

    @inline(__always) func pitchCorrection(_ lf0: Double) -> Double {
        // piecewise-linear log2(f0/ref) knots → cents, clamped ends
        if let knA = pitchKnotsA, let ceA = pitchCentsA {
            return interpKnots(lf0 - log2(220.0), knA, ceA)
                + interpKnots(lf0 - pitchRefLog2, pitchKnots, pitchCentsTab)
        }
        let x = lf0 - pitchRefLog2
        if x <= pitchKnots[0] { return pitchCentsTab[0] }
        let last = pitchKnots.count - 1
        if x >= pitchKnots[last] { return pitchCentsTab[last] }
        var i = 0
        while i + 1 < pitchKnots.count && pitchKnots[i + 1] < x { i += 1 }
        let t = (x - pitchKnots[i]) / max(pitchKnots[i + 1] - pitchKnots[i], 1e-12)
        return pitchCentsTab[i] + t * (pitchCentsTab[i + 1] - pitchCentsTab[i])
    }

    /// Fill `n` kernel-rate samples from the mapper state.
    public mutating func fill(from mapper: BowControlMapper, n: Int,
                              f0 f0Out: UnsafeMutablePointer<Double>,
                              vb vbOut: UnsafeMutablePointer<Double>,
                              fb fbOut: UnsafeMutablePointer<Double>,
                              beta betaOut: UnsafeMutablePointer<Double>,
                              gate gateOut: UnsafeMutablePointer<Double>) {
        fill(snapshot: mapper.snapshot(), n: n, f0: f0Out, vb: vbOut,
             fb: fbOut, beta: betaOut, gate: gateOut)
    }

    /// Fresh string mounted: start ON the new pitch with the gate closed.
    public mutating func notePrime(f0Target: Double) {
        lf0 = log2(max(f0Target, 40.0))
        gateState = 0.0
        placeClock = 0.0             // a fresh string gets a fresh placement
        freshMount = true
        primed = true
        dipDb = 0.0                  // a pitch SNAP is not a glide
        lastLfValid = false
    }

    /// Per-slot fill (the slot's f0/gate + the global axes).
    mutating func fill(snapshot snap: BowControlMapper.Snapshot, n: Int,
                       f0 f0Out: UnsafeMutablePointer<Double>,
                       vb vbOut: UnsafeMutablePointer<Double>,
                       fb fbOut: UnsafeMutablePointer<Double>,
                       beta betaOut: UnsafeMutablePointer<Double>,
                       gate gateOut: UnsafeMutablePointer<Double>) {
        let lfTarget = log2(max(snap.f0Target, 40.0))
        if !primed {
            // first buffer: start ON the target with the gate closed
            lf0 = lfTarget
            gateState = 0.0
            if snap.gate > 0.5 {                       // born mid-attack
                placeClock = 0.0
                attackSharp = attackSharpAt(press: snap.press,
                                            onVel: snap.onVel)
            }
            prev = snap
            primed = true
        }
        // fresh attack (gate rising edge, or a fresh mount whose gate never
        // fell): restart the placement clock, capture the onset sharpness
        if snap.gate > 0.5,
           freshMount || (prev?.gate ?? 0.0) <= 0.5 {
            placeClock = 0.0
            attackSharp = attackSharpAt(press: snap.press,
                                        onVel: snap.onVel)
        }
        freshMount = false
        let p = prev ?? snap
        let vRef = 0.75 * vHi
        let dtk = 1.0 / srk
        let vibW = 2.0 * Double.pi * vibHz / srk
        // ramp log2 f0 linearly from the last block's end to the target
        let lfStart = lf0
        for i in 0..<n {
            let u = Double(i + 1) / Double(n)      // block → kernel-rate lerp
            let expr = p.expr + u * (snap.expr - p.expr)
            let press = p.press + u * (snap.press - p.press)
            let pos = p.pos + u * (snap.pos - p.pos)
            let tk = p.tiltDb + u * (snap.tiltDb - p.tiltDb)
            let lf = lfStart + u * (lfTarget - lfStart)
            lf0 = lf
            // player vibrato (aftertouch depth) on the sounding pitch
            var vibOct = 0.0
            if vibCents > 1e-9 {
                vibPhase += vibW
                if vibPhase > 2.0 * Double.pi { vibPhase -= 2.0 * Double.pi }
                let amt = p.vib + u * (snap.vib - p.vib)
                if amt > 1e-6 {
                    vibOct = vibCents * amt * sin(vibPhase) / 1200.0
                }
            }
            // liveness drift: three OU walks, soft-bounded ±3σ
            if driftCents > 1e-9 || driftDb > 1e-9 || driftForceDb > 1e-9 {
                ouPitch = min(max(aDrift * ouPitch + driftGain * nextUniform(), -3.0), 3.0)
                ouLevel = min(max(aDrift * ouLevel + driftGain * nextUniform(), -3.0), 3.0)
                ouForce = min(max(aDrift * ouForce + driftGain * nextUniform(), -3.0), 3.0)
                if driftCents > 1e-9 {
                    vibOct += driftCents * ouPitch / 1200.0
                }
            }
            // glide lightening drive: sounding-pitch slew in cents/s
            if glideDipDb > 1e-9 {
                let r = lastLfValid ? abs(lf - lastLf) * 1200.0 * srk : 0.0
                let target = glideDipDb * r / (r + glideDipRate)
                let a = target > dipDb ? aDipAtt : aDipRel
                dipDb = (1.0 - a) * target + a * dipDb
                lastLf = lf
                lastLfValid = true
            }
            var corr = pitchCorrection(lf)
            if let ks = pitchKnotsA, let ps = pitchCentsPress, ps.count == ks.count {
                let pr = p.press + u * (snap.press - p.press)
                corr += interpKnots(lf - log2(220.0), ks, ps) * (pr - 0.55)
            }
            let f0 = exp2(lf + vibOct + corr / 1200.0)
            // 25 ms softened gate
            gateState = (1.0 - aGate) * snap.gate + aGate * gateState
            // dynamics: expr → dB → v. The law rides [exprLift, 1]; the
            // fade-to-silence zone below the lift must NOT overlap it.
            var vb: Double
            let e01 = min(max(expr, 0.0), 1.0)
            let eDyn = exprLift > 1e-6 && exprLift < 1.0
                ? min(max((e01 - exprLift) / (1.0 - exprLift), 0.0), 1.0)
                : e01
            if dynP > 0.1 {
                let rel = -14.0 + 19.0 * eDyn
                vb = min(max(vRef * pow(10.0, rel / (20.0 * dynP)), vLo),
                         1.3 * vHi)
            } else {
                vb = vLo + (vHi - vLo) * eDyn
            }
            var beta = betaLo + (betaHi - betaLo) * pos
            // tilt → bow position (soft deadband knee)
            if tiltBeta > 1e-9 {
                let tkb = tiltKnee > 1e-9
                    ? tk * tk * tk / (tk * tk + tiltKnee * tiltKnee) : tk
                beta *= exp2(-tiltBeta * tkb / 12.0)
            }
            // absolute-distance bowing (β rises as f0 falls)
            if betaF0Gamma > 1e-3 {
                beta = min(max(beta * pow(466.16 / max(f0, 80.0), betaF0Gamma),
                               0.04), 0.22)
            }
            // press = log-force position across the analytic Schelleng
            // wedge at this (f0, β, v): fmin = M·C·v/β² (Helmholtz floor),
            // fmax = 2Zv/(β·Δμ) (raucous ceiling). The edges are reachable
            // on purpose: pressUnder·fmin = flautando, pressOver·fmax =
            // pressed grit — force timbre lives at the wedge edges.
            let lo = schellengMargin * schellengC * vb / max(beta * beta, 1e-6)
            let hi = max(2.0 * schellengZ * vb / (max(beta, 1e-3) * schellengDmu),
                         lo * 1.05)
            let fMin = pressUnder * lo
            let fMax = max(pressOver * hi, fMin * 1.0001)
            var fb = fMin * pow(fMax / fMin, press)
            // tilt brightens force; register force (more force to lock a
            // lossy stopped gut string up high)
            if tiltForce > 1e-9 {
                fb *= exp2(tiltForce * tk / 12.0)
            }
            if fReg > 1e-3 {
                fb *= pow(max(f0 / tonicHz, 1.0), fReg)
            }
            fb = min(fb, fCap)
            // BOW LIFTS TO SILENCE below exprLift: force AND velocity fade
            // to 0 (the wedge floor alone would keep the string speaking).
            if exprLift > 1e-6 {
                let lift = min(1.0, max(0.0, expr) / exprLift)
                fb *= lift
                vb *= lift
            }
            // PLACE-then-DRAW (+ attack bite): velocity ~0 while the bow is
            // set, then a smoothstep draw; a sharp attack draws fast
            placeClock += dtk
            if placeS > 0.0 {
                let drawEff = drawS + (drawMinS - drawS) * attackSharp
                let ud = min(max((placeClock - placeS) / drawEff, 0.0), 1.0)
                let stepSoft = ud * ud * (3.0 - 2.0 * ud)
                // sharp attacks lead with velocity (martelé/collé — a moving
                // bow that grips) and ramp force over attackFms
                let uf = min(max(placeClock / attackFms, 0.0), 1.0)
                vb *= (1.0 - attackSharp) * stepSoft + attackSharp
                fb *= (1.0 - attackSharp)
                    + attackSharp * (uf * uf * (3.0 - 2.0 * uf))
                if attackBite > 1e-6, attackSharp > 1e-6 {
                    fb *= 1.0 + attackBite * attackSharp
                        * exp(-max(placeClock, 0.0) / attackBiteTau)
                }
            }
            // liveness: wander + settle + glide lightening, as dB
            var vbDb = driftDb * ouLevel
            var fbDb = driftForceDb * ouForce
            if settleDb > 1e-9 {
                // the guard keeps settleSharp 0 bit-exact
                let sDb = settleSharp > 1e-9
                    ? settleDb * max(1.0 - settleSharp * attackSharp, 0.0)
                    : settleDb
                let t0 = max(placeS + drawS, 0.02)
                if placeClock < t0 + 6.0 * settleTauS {
                    let us = min(max(placeClock / t0, 0.0), 1.0)
                    let shape = us * us * (3.0 - 2.0 * us)
                    vbDb -= sDb * shape
                        * exp(-max(placeClock - t0, 0.0) / settleTauS)
                }
            }
            if dipDb > 1e-12 {
                vbDb -= dipDb
                // light force coupling: a heavy cut slows re-capture
                fbDb -= 0.3 * dipDb
            }
            if vbDb != 0.0 { vb *= exp(vbDb * 0.11512925464970229) }
            if fbDb != 0.0 { fb *= exp(fbDb * 0.11512925464970229) }
            f0Out[i] = f0
            vbOut[i] = vb
            fbOut[i] = fb
            betaOut[i] = beta
            gateOut[i] = min(max(gateState, 0.0), 1.0)
        }
        prev = snap
    }

    public mutating func reset() {
        primed = false
        freshMount = false
        gateState = 0
        prev = nil
        rng = driftSeed              // reproducible renders after a panic
        ouPitch = 0.0
        ouLevel = 0.0
        ouForce = 0.0
        dipDb = 0.0
        lastLfValid = false
    }
}
