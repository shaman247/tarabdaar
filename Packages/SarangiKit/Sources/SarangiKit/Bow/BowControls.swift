import Foundation

/// MIDI/UI events → kernel-rate bow controls (f0, vbow, fbow, beta, gate) —
/// the LIVE form of `bowstring.pair_controls`' control-mapping laws.
///
/// Block-rate in, kernel-rate out: the control thread (MIDI/UI) writes the
/// target state under a lock; once per render buffer the audio thread
/// snapshots it and fills per-sample arrays, linearly interpolating the axis
/// values from the previous snapshot and running the per-sample smoothers:
///
///   * f0    — held note + pitch bend → target log-f0, glided through TWO
///             cascaded one-poles at PITCH_SMOOTH_HZ (9 Hz, the offline meend
///             bandwidth: a bowed string glides, never jumps — the causal
///             stand-in for render_pitch's zero-phase butter2; ViolinSource's
///             per-note glideMs serves the additive voice, the friction loop
///             needs a continuous contour instead), then the calibrated
///             per-octave `pitch_cents` correction.
///   * gate  — note state softened by the ~25 ms one-pole (a step gate slams
///             the friction excitation = broadband swing overshoot).
///   * vbow  — expression (CC11) → loudness dB (rel ∈ [−14, +5], the range
///             the offline dynamics inversion spans) → the kernel's
///             calibrated loudness law v = v_ref·10^(rel/(20·dyn_p)),
///             clipped to [v_lo, 1.3·v_hi]; dyn_p ≤ 0.1 falls back to the
///             affine map. The loudness law rides [bow_expr_lift, 1]; the
///             zone below the lift is the fade-to-SILENCE release gesture
///             (the two must not overlap — offline pianissimo bows at the
///             velocity floor, never lifts).
///   * fbow  — press (CC1) → position INSIDE the playable Schelleng wedge
///             on a LOG-force axis (2026-07-16 remap, ear-approved ladders
///             reports/press_pos_authority.html): fb = f_min·(f_max/f_min)^press
///             with f_min = bow_live_press_under·wedge_lo (press 0 dips
///             BELOW the lock floor — under-pressed flautando/octave
///             whistle, deliberate) and f_max = bow_live_press_over·wedge_hi
///             (press 1 pushes past max lock — pressed grit). The OLD law
///             (absolute [f_lo, f_hi] then wedge clamp ×fmin_scale) had ZERO
///             press authority at 247/415 Hz (the floor exceeded the whole
///             mapped range) and ~0.3 dB of tilt where it survived: force
///             timbre lives at the wedge EDGES, which a clamp forbids.
///             Wedge-relative mapping is register-uniform by construction;
///             velocity co-drive comes through the bounds themselves
///             (fmin ∝ v). OFFLINE pair_controls keeps the absolute law —
///             the fitted contours were converged under it; the bowreplay
///             exporter INVERTS this live law so replay reproduces the
///             offline post-projection controls exactly.
///   * beta  — pos (CC74) affine in [bow_live_beta_lo, bow_live_beta_hi]
///             (0.04–0.22: sul ponticello ↔ sul tasto; the offline
///             bow_beta_lo/hi 0.063–0.165 were the RECORDING's contour
///             range, not the instrument's). tilt (CC2, dB) moves toward
///             the bridge via bow_tilt_beta through the soft deadband knee,
///             and brightens force via bow_tilt_force; optional
///             absolute-distance correction (bow_beta_f0).
///   * wedge — the MEASURED playable region (per-(f0, β, v) trilinear force
///             bounds) is the press axis' ENVELOPE, not a clamp; β beyond
///             the measured grid (0.06–0.13) extrapolates by the Schelleng
///             laws fmin ∝ 1/β², fmax ∝ 1/β until calibrate_wedge is re-run
///             on the wider grid. With NO wedge (the generic pure-physics
///             bowed string) the envelope is fully ANALYTIC: fmin = M·C·v/β²,
///             fmax = 2Zv/(β·Δμ) from the friction params. A final bow_f_cap
///             guards tilt/register pushes. The offline sul-tasto β projection, note-onset
///             articulation, technique overlays and glide bow-lightening
///             are OMITTED live: they are lookahead/zero-phase passes over
///             a known contour — a live player supplies those gestures on
///             the axes directly.
///
/// No pre-roll/pre-charge live: the instrument starts from silence
/// (the offline warm start models a mid-performance excerpt).
public final class BowControlMapper: @unchecked Sendable {

    /// Fixed slot-table size (the engine's `maxPoly` is clamped to this).
    public static let maxSlots = 16

    /// One POLYPHONIC voice slot = one gut string on the shared bridge
    /// (2026-07-16). Allocation is physical:
    ///   * note-on for a note already sounding → re-bow that string
    ///     (retrigger if gated, gate-on if it was ringing released);
    ///   * note-on while NOTHING is gated → re-bow the most recent string
    ///     at the new pitch (the mono meend law: a single line stays on one
    ///     string, pitch glides through the 9 Hz smoother — this is what
    ///     bowreplay and detached playing exercise);
    ///   * note-on while other notes are HELD → a fresh string (chord):
    ///     unused slot, else the longest-released, else steal the oldest
    ///     held. A fresh string bumps `serial` — the engine zeroes that
    ///     kernel string and snaps its pitch (no cross-string portamento).
    /// Note-off only lifts the bow: the string keeps ringing on its slot.
    private struct Slot {
        var note: UInt8 = 69
        /// STARPAD: MPE source channel of the note on this string (0 for
        /// single-channel controllers — upstream behavior unchanged).
        var ch: UInt8 = 0
        var gateOn = false
        var used = false
        var serial: UInt32 = 0
        var lastOn: UInt64 = 0
        var lastOff: UInt64 = 0
    }

    // ---- control-thread state (locked) ----
    private var lock = os_unfair_lock()
    private var slots = [Slot](repeating: Slot(), count: BowControlMapper.maxSlots)
    private var slotLimit = 1
    private var evt: UInt64 = 0
    /// Held-note stack (legacy last-note priority): when a released note's
    /// slot has a still-held predecessor that is not sounding on any other
    /// slot, the slot RE-POINTS to it gated (glide back — the mono law; at
    /// full polyphony the predecessor has its own slot and this never fires).
    /// STARPAD: entries carry their MPE channel (note identity = note+channel).
    private var held: [(note: UInt8, ch: UInt8)] = []
    /// STARPAD MPE: pitch bend is PER CHANNEL (semitones) — each Pitch Pad
    /// finger bends only its own note. A single-channel controller uses
    /// index 0 and behaves exactly like the upstream global bend.
    private var chBend = [Double](repeating: 0.0, count: 16)
    private var expr: Double
    private var press: Double
    private var pos: Double
    private var tilt01: Double
    /// Player vibrato = AFTERTOUCH (channel 0xD0 / poly 0xA0): depth 0..1
    /// into bow_vib_cents at bow_vib_hz — deliberate finger motion, the
    /// ear-law-compliant liveness (never free-running).
    private var vibAT = 0.0
    public var bendRange = 2.0             // semitones at full wheel

    /// Tilt axis dB mapping (shared with the voice: CC2 0…127 spans
    /// [tiltMinDb, tiltMaxDb]; neutral 0 dB ≈ CC 42).
    public static let tiltMinDb = -12.0
    public static let tiltMaxDb = 24.3

    /// Idle operating point = pair-3 gated medians (the same defaults the
    /// voice axes use): expr 0.251 · press ~0.56 axis · pos 0.45 (the
    /// control_track default) · tilt neutral.
    public init() {
        expr = 0.251
        press = 0.562
        pos = 0.45
        tilt01 = -BowControlMapper.tiltMinDb
            / (BowControlMapper.tiltMaxDb - BowControlMapper.tiltMinDb)
    }

    /// Usable slot count = the engine's polyphony (set at engine build; the
    /// long-lived mapper keeps held notes across rebuilds when unchanged).
    /// Shrinking releases the gates of the slots that fall outside.
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

    private func noteOn(_ d1: UInt8, _ ch: UInt8) {
        evt += 1
        held.removeAll { $0.note == d1 && $0.ch == ch }
        held.append((d1, ch))
        let lim = slotLimit
        // re-bow a string already carrying this note
        for i in 0..<lim where slots[i].gateOn && slots[i].note == d1 && slots[i].ch == ch {
            slots[i].lastOn = evt
            return
        }
        var ring = -1
        for i in 0..<lim
        where slots[i].used && !slots[i].gateOn && slots[i].note == d1 && slots[i].ch == ch {
            if ring < 0 || slots[i].lastOn > slots[ring].lastOn { ring = i }
        }
        if ring >= 0 {
            slots[ring].gateOn = true
            slots[ring].lastOn = evt
            return
        }
        let anyGated = (0..<lim).contains { slots[$0].gateOn }
        if !anyGated {
            // single line: stay on the most recent string, glide to the
            // new pitch (the mono meend law — no serial bump)
            var i = 0
            var found = false
            for s in 0..<lim where slots[s].used {
                if !found || slots[s].lastOn > slots[i].lastOn { i = s }
                found = true
            }
            if !found { slots[i].serial &+= 1 }        // first note = fresh string
            slots[i].note = d1
            slots[i].ch = ch
            slots[i].gateOn = true
            slots[i].used = true
            slots[i].lastOn = evt
            return
        }
        // chord: a fresh string — unused slot, else longest-released,
        // else steal the oldest held note
        var i = -1
        for s in 0..<lim where !slots[s].used { i = s; break }
        if i < 0 {
            for s in 0..<lim where !slots[s].gateOn {
                if i < 0 || slots[s].lastOff < slots[i].lastOff { i = s }
            }
        }
        var stoleGated = false
        if i < 0 {
            for s in 0..<lim {
                if i < 0 || slots[s].lastOn < slots[i].lastOn { i = s }
            }
            stoleGated = true
        }
        // stealing the ONLY gated slot is legato on that string (the
        // effective-mono case, slotLimit 1): glide, keep the string
        let gatedCount = (0..<lim).reduce(0) { $0 + (slots[$1].gateOn ? 1 : 0) }
        if !(stoleGated && gatedCount == 1) {
            slots[i].serial &+= 1
        }
        slots[i].note = d1
        slots[i].ch = ch
        slots[i].gateOn = true
        slots[i].used = true
        slots[i].lastOn = evt
    }

    private func noteOff(_ d1: UInt8, _ ch: UInt8) {
        evt += 1
        held.removeAll { $0.note == d1 && $0.ch == ch }
        let back = held.last
        let backSounding = back != nil && (0..<slotLimit).contains {
            slots[$0].gateOn && slots[$0].note == back!.note && slots[$0].ch == back!.ch
        }
        for i in 0..<slotLimit where slots[i].gateOn && slots[i].note == d1 && slots[i].ch == ch {
            if let back, !backSounding {
                // glide back to the still-held predecessor on this string
                slots[i].note = back.note
                slots[i].ch = back.ch
                slots[i].lastOn = evt
            } else {
                slots[i].gateOn = false
                slots[i].lastOff = evt
            }
        }
    }

    /// Same event map as the voice (ViolinVoiceControl): note on/off (poly
    /// slot allocation above), CC11 expr · CC1 press · CC74 pos · CC2 tilt,
    /// pitch bend, CC120/123 all-off.
    /// STARPAD MPE: the status byte's channel nibble keys note identity and
    /// pitch bend (per-note channels, per-channel bend — the Pitch Pad's MPE);
    /// CC75 doubles as tilt (the iPad's mappable set); CCs stay global.
    public func midi(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        let kind = status & 0xF0
        let ch = status & 0x0F
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        switch kind {
        case 0x90 where d2 > 0:
            noteOn(d1, ch)
        case 0x80, 0x90:
            noteOff(d1, ch)
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
                held.removeAll()
                for i in slots.indices where slots[i].gateOn {
                    slots[i].gateOn = false
                    slots[i].lastOff = evt
                }
            default: break
            }
        default: break
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
    }

    /// One voice slot as the render thread sees it. `serial` identifies the
    /// physical string generation: a change means "a fresh gut string was
    /// mounted on this slot" — the engine zeroes the kernel string state and
    /// snaps the slot's pitch smoother onto the new note.
    public struct SlotSnapshot: Sendable {
        public var f0Target: Double = 440.0
        public var gate: Double = 0.0
        public var serial: UInt32 = 0
    }

    /// Poly snapshot into a preallocated buffer (render thread; no
    /// allocation). `lead` = the melody slot (newest gated, else newest
    /// used) — the fingerprint mask rides its sounding pitch.
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
                f0Target: 440.0 * pow(2.0, (Double(s.note) - 69.0 + chBend[Int(s.ch)]) / 12.0),
                gate: s.gateOn ? 1.0 : 0.0,
                serial: s.serial)
        }
        for i in lim..<snap.slots.count {
            snap.slots[i].gate = 0.0
        }
        snap.lead = min(leadIndex(lim), snap.slots.count - 1)
    }

    /// Mono facade (the fixture/e2e path and slotLimit-1 engines): the lead
    /// slot's note and gate — identical to the legacy last-note-priority
    /// stack for every on/off pattern.
    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let i = leadIndex(slotLimit)
        let s = slots[i]
        let f0 = 440.0 * pow(2.0, (Double(s.note) - 69.0 + chBend[Int(s.ch)]) / 12.0)
        let tdb = BowControlMapper.tiltMinDb
            + tilt01 * (BowControlMapper.tiltMaxDb - BowControlMapper.tiltMinDb)
        return Snapshot(f0Target: f0, gate: s.gateOn ? 1.0 : 0.0,
                        expr: expr, press: press, pos: pos, tiltDb: tdb,
                        vib: vibAT)
    }
}

/// The render-thread half: holds the per-sample smoother state and the
/// mapping constants baked from BowParams, fills kernel-rate control arrays.
/// Owned by BowEngine (one instance per engine build; the mapper it reads is
/// long-lived so held notes/axes survive structural rebuilds).
public struct BowControlFilter: Sendable {
    let srk: Double
    // baked mapping constants (bowstring.pair_controls)
    let aGate: Double            // 25 ms gate one-pole
    let aPitch: Double           // 9 Hz meend one-pole (applied twice)
    var vLo: Double, vHi: Double
    var betaLo: Double, betaHi: Double
    var pressUnder: Double, pressOver: Double   // wedge-edge overshoot factors
    var dynP: Double, fCap: Double
    var exprLift: Double         // expression below which the bow lifts to silence
    var schellengC: Double, schellengMargin: Double
    var schellengZ: Double, schellengDmu: Double   // analytic fmax = 2Zv/(βΔμ)
    var tiltBeta: Double, tiltForce: Double, tiltKnee: Double
    var betaF0Gamma: Double
    var fReg: Double, tonicHz: Double   // register force (f0/tonic)^k
    // PLACE-then-DRAW articulation (2026-07-16b): at a fresh attack the
    // force rides the gate ramp while VELOCITY holds ~0 for placeS (bow
    // set on the string — static stick, silence) then rises over drawS
    // (smoothstep) — the friction loop produces the authentic
    // pre-Helmholtz crunch with no injected noise. placeS 0 = off
    // (bit-null: the sarangi bow artifact carries no key).
    var placeS: Double, drawS: Double
    // ATTACK SHARPNESS (2026-07-17d): a sharp, accented onset is a FAST,
    // FORCEFUL bite. Sharpness = onset PRESS above attackThresh (the player
    // law: "a sharper sound from higher pressure"). A sharp attack DRAWS
    // fast (drawS → drawMinS) and briefly OVER-forces (fb *= 1 +
    // attackBite·sharp·exp(-t/biteTau)): the high force under a fast
    // velocity onset drives the friction loop through a transient
    // MULTI-SLIP regime = a burst of upper-harmonic energy (the kernel's
    // own physics, no injected noise). attackBite 0 = off (legato draw).
    var drawMinS: Double, attackBite: Double
    var attackBiteTau: Double, attackThresh: Double
    // player vibrato (aftertouch): depth vibCents at vibHz, applied to the
    // SOUNDING pitch post-smoother (finger motion). vibCents 0 = off.
    var vibCents: Double, vibHz: Double
    let pitchKnots: [Double], pitchCentsTab: [Double]
    let pitchRefLog2: Double
    let pitchKnotsA: [Double]?, pitchCentsA: [Double]?
    let pitchCentsPress: [Double]?
    let wedge: BowWedge?
    // smoother state
    var lf0A = 0.0, lf0B = 0.0   // cascaded one-pole states on log2 f0
    var gateState = 0.0
    var attackFms: Double
    var placeClock = 1.0e9       // seconds since the current attack began
    var attackSharp = 0.0        // onset-press sharpness of the current attack
    var vibPhase = 0.0
    var prev: BowControlMapper.Snapshot?
    var primed = false
    /// A fresh string was mounted on this slot: the next fill must capture
    /// its OWN onset sharpness. A steal happens with the gate already high,
    /// so the rising-edge test alone never fires and the new string would
    /// articulate with the stolen note's sharpness.
    var freshMount = false

    public init(bp: BowParams, srk: Double, tonic: Double = 261.63) {
        self.srk = srk
        tonicHz = max(tonic, 40.0)
        aGate = exp(-1.0 / (0.025 * srk))
        aPitch = exp(-2.0 * Double.pi * 9.0 / srk)     // PITCH_SMOOTH_HZ
        vLo = bp.v("bow_v_lo", 0.05)
        vHi = bp.v("bow_v_hi", 0.35)
        // LIVE performance ranges (bow_live_*): wider than the offline
        // bow_beta_lo/hi, which are the fitted RECORDING contour range
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
        vibCents = bp.v("bow_vib_cents", 0.0)
        vibHz = bp.v("bow_vib_hz", 5.5)
        // TWO-COMPONENT correction when the String artifact carries it
        // (corr = A(f0) bare-loop absolute + B(f0/tonic) body residual);
        // the sarangi bow has neither and keeps the legacy 220 table
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
        wedge = bp.wedge
    }

    /// STARPAD LIVE PARAMETERS (2026-07-24): re-read the bp-derived
    /// mapping constants on a filter that is already running. Only the
    /// config above is touched — the smoother state (`lf0A`/`lf0B`,
    /// `gateState`, `placeClock`, `attackSharp`, `vibPhase`, `prev`,
    /// `primed`) is left exactly as it stands, so a parameter edit does
    /// not re-articulate a sounding note. Keep in lockstep with `init`.
    /// (Pitch tables/wedge are structural and stay put.)
    public mutating func updateLiveParams(bp: BowParams) {
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
        vibCents = bp.v("bow_vib_cents", 0.0)
        vibHz = bp.v("bow_vib_hz", 5.5)
    }

    @inline(__always) func attackSharpOf(_ press: Double) -> Double {
        min(max((press - attackThresh) / max(1.0 - attackThresh, 1e-6),
                0.0), 1.0)
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
        // np.interp over (log2(f0/ref) knots → cents), clamped ends;
        // ref = the tonic for rel knots, 220 Hz for the legacy table.
        // Two-component artifacts add the bare-loop absolute table A.
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

    /// Fill `n` kernel-rate samples from the mapper state. Outputs ride the
    /// wedge-relative performance envelope: fb inside
    /// [pressUnder·wedge_lo, pressOver·wedge_hi] (× tilt/register pushes,
    /// hard-capped at bow_f_cap), v/beta inside their live ranges.
    /// `f0Snd` (optional) receives the PRE-correction smoothed f0 — the
    /// pitch the string will actually SOUND at (the knot correction exists
    /// to cancel the friction pull); the fingerprint mask must track this,
    /// not the corrected control (offline masks ride the recording's line).
    public mutating func fill(from mapper: BowControlMapper, n: Int,
                              f0 f0Out: UnsafeMutablePointer<Double>,
                              vb vbOut: UnsafeMutablePointer<Double>,
                              fb fbOut: UnsafeMutablePointer<Double>,
                              beta betaOut: UnsafeMutablePointer<Double>,
                              gate gateOut: UnsafeMutablePointer<Double>,
                              f0Snd: UnsafeMutablePointer<Double>? = nil) {
        fill(snapshot: mapper.snapshot(), n: n, f0: f0Out, vb: vbOut,
             fb: fbOut, beta: betaOut, gate: gateOut, f0Snd: f0Snd)
    }

    /// A fresh string was mounted on this slot: start the pitch smoother ON
    /// the new note (no cross-string portamento) with the gate closed (a
    /// fresh attack softens in from silence).
    public mutating func notePrime(f0Target: Double) {
        lf0A = log2(max(f0Target, 40.0))
        lf0B = lf0A
        gateState = 0.0
        placeClock = 0.0             // a fresh string gets a fresh placement
        freshMount = true
        primed = true
    }

    /// Per-slot fill (the poly engine snapshots the mapper ONCE and hands
    /// each slot its own Snapshot: the slot's f0/gate + the global axes).
    mutating func fill(snapshot snap: BowControlMapper.Snapshot, n: Int,
                       f0 f0Out: UnsafeMutablePointer<Double>,
                       vb vbOut: UnsafeMutablePointer<Double>,
                       fb fbOut: UnsafeMutablePointer<Double>,
                       beta betaOut: UnsafeMutablePointer<Double>,
                       gate gateOut: UnsafeMutablePointer<Double>,
                       f0Snd: UnsafeMutablePointer<Double>? = nil) {
        let lfTarget = log2(max(snap.f0Target, 40.0))
        if !primed {
            // first buffer: start ON the target (no glide from a fictitious
            // A4) with the gate closed — silence until the first note-on.
            lf0A = lfTarget
            lf0B = lfTarget
            gateState = 0.0
            if snap.gate > 0.5 {                       // born mid-attack
                placeClock = 0.0
                attackSharp = attackSharpOf(snap.press)
            }
            prev = snap
            primed = true
        }
        // fresh attack (gate rising edge, or a freshly mounted string whose
        // gate never fell): restart the bow placement and capture the onset
        // sharpness = press above threshold (the player sets press
        // before/as they attack — a hard press = a sharp bite)
        if placeS > 0.0, snap.gate > 0.5,
           freshMount || (prev?.gate ?? 0.0) <= 0.5 {
            placeClock = 0.0
            attackSharp = attackSharpOf(snap.press)
        }
        freshMount = false
        let p = prev ?? snap
        let vRef = 0.75 * vHi
        let dtk = 1.0 / srk
        let vibW = 2.0 * Double.pi * vibHz / srk
        for i in 0..<n {
            let u = Double(i + 1) / Double(n)      // block → kernel-rate lerp
            let expr = p.expr + u * (snap.expr - p.expr)
            let press = p.press + u * (snap.press - p.press)
            let pos = p.pos + u * (snap.pos - p.pos)
            let tk = p.tiltDb + u * (snap.tiltDb - p.tiltDb)
            // meend-limited pitch: two cascaded one-poles on log2 f0
            lf0A = (1.0 - aPitch) * lfTarget + aPitch * lf0A
            lf0B = (1.0 - aPitch) * lf0A + aPitch * lf0B
            // player vibrato (aftertouch-depth finger motion on the
            // sounding pitch — post-smoother, pre-knot-correction)
            var vibOct = 0.0
            if vibCents > 1e-9 {
                vibPhase += vibW
                if vibPhase > 2.0 * Double.pi { vibPhase -= 2.0 * Double.pi }
                let amt = p.vib + u * (snap.vib - p.vib)
                if amt > 1e-6 {
                    vibOct = vibCents * amt * sin(vibPhase) / 1200.0
                }
            }
            var corr = pitchCorrection(lf0B)
            if let ks = pitchKnotsA, let ps = pitchCentsPress, ps.count == ks.count {
                let pr = p.press + u * (snap.press - p.press)
                corr += interpKnots(lf0B - log2(220.0), ks, ps) * (pr - 0.55)
            }
            let f0 = exp2(lf0B + vibOct + corr / 1200.0)
            if let snd = f0Snd { snd[i] = exp2(lf0B + vibOct) }
            // 25 ms softened gate
            gateState = (1.0 - aGate) * snap.gate + aGate * gateState
            // dynamics: expr → dB → (v, f) through the calibrated law.
            // The loudness law rides [exprLift, 1] — the fade-to-silence
            // zone below the lift must NOT overlap it: offline pianissimo
            // bows at the velocity floor (the speak_min lesson), and
            // mapping rel −14 dB into the lift zone silenced the quiet
            // connective strokes that charge the joda lattice (measured
            // −3–4 dB @125–250 on fast material).
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
            // press = log-force position across the playable wedge at this
            // (f0, β, v), edges DELIBERATELY reachable: pressUnder·fmin =
            // under-pressed flautando/octave whistle, pressOver·fmax =
            // pressed grit. The former absolute-range + clamp law had no
            // authority where the floor exceeded the whole range (247/415 Hz)
            // — force timbre lives at the wedge edges. Velocity co-drive
            // rides the bounds (fmin ∝ v), replacing the old (v/vRef)^0.7.
            var lo: Double, hi: Double
            if let w = wedge {
                // Schelleng extrapolation beyond the measured β grid
                // (fmin ∝ 1/β², fmax ∝ 1/β) until the wedge is re-measured
                let bg = min(max(beta, w.beta[0]), w.beta[w.beta.count - 1])
                let b = w.bounds(f0: f0, beta: bg, v: vb)
                let r = bg / beta
                lo = b.lo * r * r
                hi = max(b.hi * r, lo * 1.05)
            } else {
                // ANALYTIC Schelleng wedge (no measured table — the generic
                // pure-physics string): fmin = M·C·v/β² (minimum force to
                // sustain Helmholtz), fmax = 2Zv/(β·Δμ) (maximum before
                // raucous). Pure formulas from the friction params.
                lo = schellengMargin * schellengC * vb / max(beta * beta, 1e-6)
                hi = max(2.0 * schellengZ * vb / (max(beta, 1e-3) * schellengDmu),
                         lo * 1.05)
            }
            let fMin = pressUnder * lo
            let fMax = max(pressOver * hi, fMin * 1.0001)
            var fb = fMin * pow(fMax / fMin, press)
            // tilt brightens force; register force: a player presses harder
            // at high positions (a lossy stopped gut string needs more
            // force to lock up high)
            if tiltForce > 1e-9 {
                fb *= exp2(tiltForce * tk / 12.0)
            }
            if fReg > 1e-3 {
                fb *= pow(max(f0 / tonicHz, 1.0), fReg)
            }
            fb = min(fb, fCap)
            // BOW LIFTS TO SILENCE at low expression.  The wedge/Schelleng
            // floor keeps the string SPEAKING for any positive force, so
            // expression alone never reached zero — expr=0 still bowed a
            // full-level note (which then drove the sympathetics: the "note
            // with expression at 0" the user heard).  Below exprLift the
            // force AND velocity fade to 0: the friction stops (Fb<1e-6),
            // the played string goes silent, and its sympathetic ring —
            // driven ONLY by the bridge — falls with it.  This is the live
            // form of the offline control_track's "expr axis reaches true
            // silence at 0".  exprLift = 0 keeps the legacy always-on bow.
            if exprLift > 1e-6 {
                let lift = min(1.0, max(0.0, expr) / exprLift)
                fb *= lift
                vb *= lift
            }
            // PLACE-then-DRAW (+ ATTACK BITE): hold velocity ~0 while the
            // bow is being set (force riding the gate ramp — static stick),
            // then draw with a smoothstep. A SHARP attack (onset press high)
            // draws FAST (drawS → drawMinS) and briefly OVER-forces
            // (attackBite): the high force under the fast velocity onset
            // drives the friction loop's own transient multi-slip = the
            // upper-harmonic bite. attackBite 0 leaves the plain place-draw.
            if placeS > 0.0 {
                placeClock += dtk
                let drawEff = drawS + (drawMinS - drawS) * attackSharp
                let ud = min(max((placeClock - placeS) / drawEff, 0.0), 1.0)
                let stepSoft = ud * ud * (3.0 - 2.0 * ud)
                // VELOCITY-LEADS-FORCE sharp attacks (2026-07-18l,
                // martelé/collé mechanics — a moving bow that GRIPS: the
                // first slip releases a full drag displacement = instant
                // full-amplitude fundamental; lockstep with controls_of):
                // sharpness blends velocity-waits (soft) with velocity-
                // immediate + force ramp over bow_attack_fms.
                let uf = min(max(placeClock / attackFms, 0.0), 1.0)
                vb *= (1.0 - attackSharp) * stepSoft + attackSharp
                fb *= (1.0 - attackSharp)
                    + attackSharp * (uf * uf * (3.0 - 2.0 * uf))
                if attackBite > 1e-6, attackSharp > 1e-6 {
                    fb *= 1.0 + attackBite * attackSharp
                        * exp(-max(placeClock, 0.0) / attackBiteTau)
                }
            }
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
    }
}
