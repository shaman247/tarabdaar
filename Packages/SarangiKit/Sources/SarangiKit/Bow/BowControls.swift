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
///   * force — the ANALYTIC Schelleng region is the press axis' ENVELOPE,
///             not a clamp: fmin = M·C·v/β² (the minimum force to sustain
///             Helmholtz), fmax = 2Zv/(β·Δμ) (the maximum before raucous),
///             both straight from the friction params. A final bow_f_cap
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

    /// Note identity on a slot. `.midi` = the in-process MIDI path (note +
    /// MPE channel, pitch = note + per-channel bend — the audition/keyboard
    /// substrate, byte-frozen for parity). `.touch` = the TarabLink path:
    /// identity is the iPad touch id and pitch is a full-resolution
    /// fractional-MIDI Double in `touchPitch` — no ±48-semi bend
    /// quantization, no 15-channel cap.
    enum SlotKey: Equatable {
        case midi(note: UInt8, ch: UInt8)
        case touch(id: UInt16)
    }

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
        /// TARABDAAR: note identity (was note+MPE channel; now either that
        /// or a TarabLink touch id — upstream behavior unchanged for .midi).
        var key: SlotKey = .midi(note: 69, ch: 0)
        var gateOn = false
        var used = false
        var serial: UInt32 = 0
        var lastOn: UInt64 = 0
        var lastOff: UInt64 = 0
        /// ONSET VELOCITY (2026-08-19): the strike velocity 0…1 of the
        /// slot's most recent articulation — MIDI d2/127 or the touch
        /// frame's velocity byte. Consumed by `BowControlFilter` only when
        /// `bow_attack_vel` > 0 (velocity → attack sharpness); the default
        /// 0 keeps the historic no-velocity-axis behavior bit-exact.
        var onVel: Double = 0.0
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
    /// TARABDAAR: entries carry their full identity (SlotKey).
    private var held: [SlotKey] = []
    /// TARABDAAR touch path: full-resolution fractional-MIDI pitch per live
    /// touch id. Entries survive release while any slot still references
    /// the id (a ringing string needs its pitch); pruned once unreferenced.
    private var touchPitch: [UInt16: Double] = [:]
    /// FRET LINGER (2026-08-18): fret-band y (0…1 top→bottom) per touch id,
    /// present only for touches whose producer reported one (the fret
    /// surfaces; keyboard/scripts don't — those keep the legacy behavior).
    /// `touchYTravel` accumulates |Δy| between snapshots — the render side
    /// consumes it as the vertical-movement drive that recharges expression
    /// and resets the auto-vibrato. `touchFretY` is the OUTWARD position
    /// within the touch's HOME fret's vertical extent (0 = the end nearest
    /// the pad's centre-line, 1 = the outer end) — the auto-vibrato ceiling
    /// axis; absent (unsnapped/fretless touches) reads as 0 = no
    /// auto-vibrato. All pruned alongside `touchPitch`.
    private var touchY: [UInt16: Double] = [:]
    private var touchYTravel: [UInt16: Double] = [:]
    private var touchFretY: [UInt16: Double] = [:]
    /// TARABDAAR MPE: pitch bend is PER CHANNEL (semitones) — each Pitch Pad
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

    private func noteOn(key: SlotKey, vel: Double) {
        evt += 1
        held.removeAll { $0 == key }
        held.append(key)
        let lim = slotLimit
        // re-bow a string already carrying this note
        for i in 0..<lim where slots[i].gateOn && slots[i].key == key {
            slots[i].lastOn = evt
            slots[i].onVel = vel
            return
        }
        var ring = -1
        for i in 0..<lim
        where slots[i].used && !slots[i].gateOn && slots[i].key == key {
            if ring < 0 || slots[i].lastOn > slots[ring].lastOn { ring = i }
        }
        if ring >= 0 {
            slots[ring].gateOn = true
            slots[ring].lastOn = evt
            slots[ring].onVel = vel
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
            slots[i].key = key
            slots[i].gateOn = true
            slots[i].used = true
            slots[i].lastOn = evt
            slots[i].onVel = vel
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
        slots[i].key = key
        slots[i].gateOn = true
        slots[i].used = true
        slots[i].lastOn = evt
        slots[i].onVel = vel
    }

    private func noteOff(key: SlotKey) {
        evt += 1
        held.removeAll { $0 == key }
        let back = held.last
        let backSounding = back != nil && (0..<slotLimit).contains {
            slots[$0].gateOn && slots[$0].key == back!
        }
        for i in 0..<slotLimit where slots[i].gateOn && slots[i].key == key {
            if let back, !backSounding {
                // glide back to the still-held predecessor on this string
                slots[i].key = back
                slots[i].lastOn = evt
            } else {
                slots[i].gateOn = false
                slots[i].lastOff = evt
            }
        }
    }

    /// Drops touchPitch entries no longer held and not referenced by any
    /// used slot (a ringing released string keeps its pitch alive).
    /// Callers hold the lock.
    private func pruneTouchPitchLocked() {
        guard !touchPitch.isEmpty else { return }
        var live = Set<UInt16>()
        for k in held { if case .touch(let id) = k { live.insert(id) } }
        for s in slots where s.used {
            if case .touch(let id) = s.key { live.insert(id) }
        }
        touchPitch = touchPitch.filter { live.contains($0.key) }
        touchY = touchY.filter { live.contains($0.key) }
        touchYTravel = touchYTravel.filter { live.contains($0.key) }
        touchFretY = touchFretY.filter { live.contains($0.key) }
    }

    /// Same event map as the voice (ViolinVoiceControl): note on/off (poly
    /// slot allocation above), CC11 expr · CC1 press · CC74 pos · CC2 tilt,
    /// pitch bend, CC120/123 all-off.
    /// TARABDAAR MPE: the status byte's channel nibble keys note identity and
    /// pitch bend (per-note channels, per-channel bend — the Pitch Pad's MPE);
    /// CC75 doubles as tilt (the iPad's mappable set); CCs stay global.
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

    // MARK: TarabLink touch path (full-resolution pitch, touch-id keyed)

    /// Note-on from a TarabLink state frame. `pitchSemis` is fractional
    /// MIDI (69.0 = A440) at full Double resolution — no note+bend split.
    /// Slot allocation / stealing / the mono meend law are IDENTICAL to
    /// the MIDI path (same `noteOn(key:vel:)`). `velocity` (0…1) is the
    /// ONSET STRIKE VELOCITY (2026-08-19): stored per slot and consumed
    /// by the filter's `bow_attack_vel` law (velocity → attack
    /// sharpness); with that key at its 0 default the value is inert —
    /// the historic no-velocity-axis behavior, bit-exact.
    /// `posY` = the touch's fret-band y (0…1), nil for producers without
    /// one — a y-less touch never engages the fret-linger machinery.
    /// `fretY` = the OUTWARD position within the touch's home fret's
    /// extent (0 = the fret's end nearest the pad's centre-line, 1 = its
    /// outer end — the surfaces orient it), nil for unsnapped/fretless
    /// onsets — those get no auto-vibrato (expression decay still runs
    /// off posY).
    public func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double,
                        posY: Double? = nil, fretY: Double? = nil) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        touchPitch[id] = pitchSemis
        if let y = posY {
            touchY[id] = min(max(y, 0.0), 1.0)
            touchYTravel[id] = 0.0
        } else {
            touchY.removeValue(forKey: id)
            touchYTravel.removeValue(forKey: id)
        }
        if let fy = fretY {
            touchFretY[id] = min(max(fy, 0.0), 1.0)
        } else {
            touchFretY.removeValue(forKey: id)
        }
        noteOn(key: .touch(id: id), vel: min(max(velocity, 0.0), 1.0))
        pruneTouchPitchLocked()
    }

    /// Pitch update for a live touch. Just writes the target — the render
    /// side's 9 Hz meend smoother provides continuity (this REPLACES the
    /// old 60 Hz bend re-send loop as the glide mechanism). Unknown ids
    /// are ignored (stale frame after a release). A `posY` change also
    /// accumulates vertical travel — the linger recharge drive.
    public func touchGlide(_ id: UInt16, pitchSemis: Double,
                           posY: Double? = nil, fretY: Double? = nil) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        // Only LIVE touches glide. touchPitch alone is not liveness — an
        // entry survives release while its string rings, and a stale glide
        // must not bend a ringing string.
        guard held.contains(.touch(id: id)) else { return }
        touchPitch[id] = pitchSemis
        if let y = posY {
            let clamped = min(max(y, 0.0), 1.0)
            if let old = touchY[id] {
                touchYTravel[id] = (touchYTravel[id] ?? 0.0)
                    + abs(clamped - old)
            }
            touchY[id] = clamped
        }
        if let fy = fretY {
            touchFretY[id] = min(max(fy, 0.0), 1.0)
        }
    }

    /// Note-off (bow lift) for a touch; the string keeps ringing on its
    /// slot, so the pitch entry survives until the slot is reused.
    public func touchOff(_ id: UInt16) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        noteOff(key: .touch(id: id))
        pruneTouchPitchLocked()
    }

    /// All bows off (link drop / panic) — the touch twin of CC123.
    public func touchAllOff() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        evt += 1
        held.removeAll()
        for i in slots.indices where slots[i].gateOn {
            slots[i].gateOn = false
            slots[i].lastOff = evt
        }
        pruneTouchPitchLocked()
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
        /// Onset strike velocity 0…1 of the slot's current articulation —
        /// read by the filter ONLY at a fresh-attack edge, and only when
        /// `bow_attack_vel` > 0 (default 0 = the legacy press-only law).
        var onVel: Double = 0.0
        // FRET LINGER (2026-08-18): per-slot inputs to the linger/auto-vib
        // envelopes. `lingerOn` false (every .midi slot, and any touch
        // without a reported y) leaves the filter's legacy path bit-exact.
        // `lingerFretY` is FRET-relative and OUTWARD-oriented (0 = the
        // home fret's end nearest the pad's centre-line = no auto-vibrato;
        // 1 = its outer end = full; unsnapped touches read as 0).
        var lingerOn = false
        var lingerFretY = 0.0              // outward within-fret y 0…1
        var lingerTravel = 0.0             // band |Δy| accumulated since snap
        var onEvt: UInt64 = 0              // articulation stamp (resets linger)
    }

    /// One voice slot as the render thread sees it. `serial` identifies the
    /// physical string generation: a change means "a fresh gut string was
    /// mounted on this slot" — the engine zeroes the kernel string state and
    /// snaps the slot's pitch smoother onto the new note. The linger fields
    /// mirror `Snapshot`'s (see there); `onEvt` is the slot's `lastOn` event
    /// stamp — any fresh articulation bumps it, and the filter resets its
    /// linger envelopes when it changes.
    public struct SlotSnapshot: Sendable {
        public var f0Target: Double = 440.0
        public var gate: Double = 0.0
        public var serial: UInt32 = 0
        /// Onset strike velocity 0…1 (see `Snapshot.onVel`).
        public var onVel: Double = 0.0
        public var lingerOn = false
        public var lingerFretY = 0.0
        public var lingerTravel = 0.0
        public var onEvt: UInt64 = 0
        /// The wire touch id behind a linger-active slot (display export:
        /// the LINGER_STATE frames key by it). 0 when lingerOn is false.
        public var lingerId: UInt16 = 0
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

    /// Pitch of a slot key. The .midi expression is byte-frozen — it must
    /// stay TEXTUALLY identical to the historic
    /// `440.0 * pow(2.0, (Double(note) - 69.0 + chBend[ch]) / 12.0)`:
    /// TarafRemovalParityTests pins a SHA-256 of the render, and FP
    /// associativity means any "simplification" here risks a last-bit
    /// change. Callers hold the lock.
    private func f0TargetLocked(_ key: SlotKey) -> Double {
        switch key {
        case .midi(let note, let ch):
            return 440.0 * pow(2.0, (Double(note) - 69.0 + chBend[Int(ch)]) / 12.0)
        case .touch(let id):
            return 440.0 * pow(2.0, ((touchPitch[id] ?? 69.0) - 69.0) / 12.0)
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

    /// The linger fields of a slot key: present only for .touch keys whose
    /// producer reported a fret-band y. CONSUMES the accumulated vertical
    /// travel (one reader per mapper — the engine's per-block snapshot).
    /// `fretY` falls back to 0 (the fret's inner end = no auto-vibrato)
    /// for touches without a home fret. Callers hold the lock.
    private func lingerFieldsLocked(_ s: Slot)
        -> (on: Bool, fretY: Double, travel: Double, evt: UInt64, id: UInt16) {
        guard case .touch(let id) = s.key, touchY[id] != nil else {
            return (false, 0.0, 0.0, s.lastOn, 0)
        }
        let travel = touchYTravel[id] ?? 0.0
        touchYTravel[id] = 0.0
        return (true, touchFretY[id] ?? 0.0, travel, s.lastOn, id)
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
            let lg = lingerFieldsLocked(s)
            snap.slots[i] = SlotSnapshot(
                f0Target: f0TargetLocked(s.key),
                gate: s.gateOn ? 1.0 : 0.0,
                serial: s.serial,
                onVel: s.onVel,
                lingerOn: lg.on, lingerFretY: lg.fretY,
                lingerTravel: lg.travel, onEvt: lg.evt, lingerId: lg.id)
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
        let f0 = f0TargetLocked(s.key)
        let tdb = BowControlMapper.tiltMinDb
            + tilt01 * (BowControlMapper.tiltMaxDb - BowControlMapper.tiltMinDb)
        let lg = lingerFieldsLocked(s)
        return Snapshot(f0Target: f0, gate: s.gateOn ? 1.0 : 0.0,
                        expr: expr, press: press, pos: pos, tiltDb: tdb,
                        vib: vibAT, onVel: s.onVel,
                        lingerOn: lg.on, lingerFretY: lg.fretY,
                        lingerTravel: lg.travel, onEvt: lg.evt)
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
    // ONSET VELOCITY → SHARPNESS (2026-08-19): the strike velocity 0…1
    // (touch frame byte / MIDI d2) ALSO sharpens the attack — sharpness =
    // max(press law, attackVel·velocity). Press stays the deliberate
    // articulation axis; velocity makes it per-note (tap hard = martelé,
    // place gently = the legato draw). attackVel 0 = bit-null (the
    // historic press-only law — velocity was never consumed before).
    var attackVel: Double
    // SETTLE EXEMPTION (2026-08-19): a SHARP attack keeps its level —
    // the post-onset settle depth is scaled by (1 − settleSharp·sharp),
    // so accented staccato holds its bite while calm sustains keep the
    // fitted settle balance. settleSharp 0 = bit-null.
    var settleSharp: Double
    // player vibrato (aftertouch): depth vibCents at vibHz, applied to the
    // SOUNDING pitch post-smoother (finger motion). vibCents 0 = off.
    var vibCents: Double, vibHz: Double
    // SUSTAIN LIVENESS + LEGATO LIGHTENING (2026-08-01, fitted to clean
    // SWAM Violin 3 captures — room off, vibrato 0, constant expression):
    //   * settle — a real sustained stroke sits slightly above its
    //     sustainable level right after capture and eases down (SWAM:
    //     +1.8 dB peak ~200 ms, level by ~500 ms; our friction loop alone
    //     overshoots +6.7 dB). settleDb·smoothstep(t/t0)·exp(-(t-t0)/tau)
    //     is subtracted from the bow velocity (dB): zero through the
    //     place+draw window t0 — the staccato bite is untouched — peaking
    //     right after it, gone by ~4·tau. Restarts per fresh attack; a
    //     legato steal keeps its stroke (no re-settle, like SWAM).
    //   * drift — the not-quite-vibrato life of a held note: three
    //     independent unit-variance Ornstein–Uhlenbeck walks (deterministic
    //     per-slot xorshift64, ~driftHz bandwidth) scale into pitch cents
    //     (SWAM: ±2 c std / 7 c p2p at 0.5–4 Hz), bow-velocity dB (±0.5 dB)
    //     and bow-force dB (timbre motion). The body + friction chain turns
    //     the pitch wander into the decorrelated per-harmonic ±1–5 dB
    //     shimmer measured in SWAM — do NOT try to inject that per band.
    //   * glide dip — bow lightening while the pitch is MOVING (the causal
    //     form of the offline glide-lightening pass): dip toward
    //     glideDipDb·r/(r+glideDipRate) where r = |sounding-pitch slew| in
    //     cents/s (fast ~15 ms attack, ~120 ms release); full dip on vbow,
    //     half on force. SWAM legato transitions dip 3.5–9 dB over ~40 ms;
    //     drift-rate motion (~20 c/s) is far below any audible dip.
    // All default 0 = bit-null (goldens untouched); shipped values live in
    // the bowed_string.json artifact.
    var settleDb: Double, settleTauS: Double
    var driftCents: Double, driftDb: Double, driftForceDb: Double
    var driftHz: Double
    var glideDipDb: Double, glideDipRate: Double
    var aDrift = 1.0, driftGain = 0.0   // OU pole + unit-variance step gain
    var aDipAtt = 0.0, aDipRel = 0.0    // dip smoother poles
    // FRET LINGER + Y-DEPTH AUTO-VIBRATO (2026-08-18): active only for
    // touch slots whose producer reported a fret-band y (`snap.lingerOn`)
    // — every .midi slot, the keyboard and the audition scores stay on the
    // legacy path bit-exact. Two per-slot envelopes evolved per sample:
    //   * charge (1 at articulation) — decays toward 0 with lingerDecayS
    //     while the finger is STILL; vertical movement drives it back to 1
    //     with lingerRechargeS. Expression is scaled by
    //     floor + (1-floor)·charge, so a lingering note eases down and a
    //     stroke of the finger along the fret swells it back.
    //   * auto-vib depth (0 at articulation) — grows toward the y-set
    //     maximum with avibGrowS while still (the ceiling axis is the
    //     touch's position within its HOME FRET's vertical extent, v5:
    //     the fret's centre = none, its ends = full; unsnapped/fretless
    //     touches have no home fret and get none), and vertical movement
    //     returns it to 0 with lingerRechargeS. Depth rides avibCents at
    //     avibHz on the sounding pitch, exactly like the aftertouch
    //     vibrato.
    // The movement drive is the |Δy| travel per snapshot converted to
    // band-heights/s, smoothed ~100 ms, normalized by lingerSpeedRef.
    var lingerDecayS: Double, lingerFloor: Double
    var lingerRechargeS: Double, lingerSpeedRef: Double
    var avibCents: Double, avibHz: Double
    var avibGrowS: Double, avibDead: Double
    var aMove = 0.0                     // movement-speed smoother pole
    let pitchKnots: [Double], pitchCentsTab: [Double]
    let pitchRefLog2: Double
    let pitchKnotsA: [Double]?, pitchCentsA: [Double]?
    let pitchCentsPress: [Double]?
    // smoother state
    var lf0A = 0.0, lf0B = 0.0   // cascaded one-pole states on log2 f0
    var gateState = 0.0
    var attackFms: Double
    var placeClock = 1.0e9       // seconds since the current attack began
    var attackSharp = 0.0        // onset-press sharpness of the current attack
    var vibPhase = 0.0
    // liveness state (drift walks, dip smoother, per-slot deterministic RNG)
    var driftSeed: UInt64 = 0x9E3779B97F4A7C15
    var rng: UInt64 = 0x9E3779B97F4A7C15
    var ouPitch = 0.0, ouLevel = 0.0, ouForce = 0.0
    var dipDb = 0.0
    var lastLf = 0.0, lastLfValid = false
    // linger state (per slot): expression charge, auto-vib depth/phase,
    // smoothed vertical speed, and the articulation stamp that resets them.
    // `lingerCharge`/`avibDepth`/`avibCeil` are public-readable — the
    // engine exports them per render block as the LINGER_STATE display
    // feed (the iPad's overlay shows what is actually evaluated here).
    public private(set) var lingerCharge = 1.0
    public private(set) var avibDepth = 0.0
    public private(set) var avibCeil = 0.0
    var avibPhase = 0.0
    var lingerSpd = 0.0
    var lastOnEvt: UInt64 = 0
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
        lingerDecayS = bp.v("bow_linger_decay", 8.0)
        lingerFloor = min(max(bp.v("bow_linger_floor", 0.0), 0.0), 1.0)
        lingerRechargeS = max(bp.v("bow_linger_recharge", 0.35), 0.02)
        lingerSpeedRef = max(bp.v("bow_linger_speed", 0.35), 0.01)
        avibCents = bp.v("bow_avib_cents", 30.0)
        avibHz = bp.v("bow_avib_hz", 5.2)
        avibGrowS = max(bp.v("bow_avib_grow", 2.5), 0.05)
        avibDead = min(max(bp.v("bow_avib_dead", 0.7), 0.0), 0.95)
        aDrift = exp(-2.0 * Double.pi * driftHz / srk)
        driftGain = sqrt(max(1.0 - aDrift * aDrift, 0.0) * 3.0)
        aDipAtt = exp(-1.0 / (0.015 * srk))
        aDipRel = exp(-1.0 / (0.12 * srk))
        aMove = exp(-1.0 / (0.1 * srk))
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
    }

    /// TARABDAAR LIVE PARAMETERS (2026-07-24): re-read the bp-derived
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
        lingerDecayS = bp.v("bow_linger_decay", 8.0)
        lingerFloor = min(max(bp.v("bow_linger_floor", 0.0), 0.0), 1.0)
        lingerRechargeS = max(bp.v("bow_linger_recharge", 0.35), 0.02)
        lingerSpeedRef = max(bp.v("bow_linger_speed", 0.35), 0.01)
        avibCents = bp.v("bow_avib_cents", 30.0)
        avibHz = bp.v("bow_avib_hz", 5.2)
        avibGrowS = max(bp.v("bow_avib_grow", 2.5), 0.05)
        avibDead = min(max(bp.v("bow_avib_dead", 0.7), 0.0), 0.95)
        aDrift = exp(-2.0 * Double.pi * driftHz / srk)
        driftGain = sqrt(max(1.0 - aDrift * aDrift, 0.0) * 3.0)
    }

    /// Decorrelate the liveness walks across poly slots (deterministic:
    /// the same slot always draws the same sequence — offline renders and
    /// the parity fixtures stay bit-reproducible).
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

    /// Onset sharpness of a fresh attack: the press law, sharpened by the
    /// strike velocity when `bow_attack_vel` is armed (whichever is
    /// sharper wins — a hard press OR a hard tap bites). attackVel 0
    /// reproduces `attackSharpOf(press)` exactly (bit-null).
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
        dipDb = 0.0                  // a pitch SNAP is not a glide
        lastLfValid = false
        resetLinger()                // a fresh string is a fresh articulation
    }

    /// Fresh articulation: full expression, no vibrato yet, movement
    /// history cleared. Fired by `notePrime` and by any `onEvt` bump
    /// (retrigger / legato re-point on a kept string).
    private mutating func resetLinger() {
        lingerCharge = 1.0
        avibDepth = 0.0
        avibCeil = 0.0
        avibPhase = 0.0
        lingerSpd = 0.0
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
                attackSharp = attackSharpAt(press: snap.press,
                                            onVel: snap.onVel)
            }
            prev = snap
            primed = true
        }
        // fresh attack (gate rising edge, or a freshly mounted string whose
        // gate never fell): restart the bow placement and capture the onset
        // sharpness = press above threshold (the player sets press
        // before/as they attack — a hard press = a sharp bite).
        // (No placeS gate: the settle envelope needs the attack clock even
        // when place-then-draw is off; with placeS 0 and settleDb 0 the
        // clock is never read, so the legacy path stays bit-identical.)
        if snap.gate > 0.5,
           freshMount || (prev?.gate ?? 0.0) <= 0.5 {
            placeClock = 0.0
            attackSharp = attackSharpAt(press: snap.press,
                                        onVel: snap.onVel)
        }
        freshMount = false
        // FRET LINGER: any fresh articulation on this slot (retrigger, or a
        // legato re-point that keeps the string) restores full expression
        // and the no-vibrato state. Bit-null for .midi slots — their state
        // is never read.
        if snap.onEvt != lastOnEvt {
            lastOnEvt = snap.onEvt
            resetLinger()
        }
        let lingerActive = snap.lingerOn
            && (lingerDecayS > 1e-6 || avibCents > 1e-9)
        // Accumulated |Δy| this snapshot → band-heights/s over the block.
        let spdInst = lingerActive ? snap.lingerTravel * srk / Double(n) : 0.0
        // Outward within-fret y → the auto-vibrato ceiling: the dead zone
        // is the `avibDead` fraction of the HOME fret from its INNER end
        // (the end toward the pad's centre-line — the surfaces orient
        // fretY outward); depth then ramps to full at the fret's outer
        // end. Unsnapped touches read 0 = none.
        let yOff = min(max(snap.lingerFretY, 0.0), 1.0)
        let avibMax = max(yOff - avibDead, 0.0) / max(1.0 - avibDead, 1e-6)
        if lingerActive { avibCeil = avibMax }
        let avibW = 2.0 * Double.pi * avibHz / srk
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
            // liveness drift: three independent OU walks (soft-bounded ±3σ),
            // pitch component rides the sounding pitch like vibrato does
            if driftCents > 1e-9 || driftDb > 1e-9 || driftForceDb > 1e-9 {
                ouPitch = min(max(aDrift * ouPitch + driftGain * nextUniform(), -3.0), 3.0)
                ouLevel = min(max(aDrift * ouLevel + driftGain * nextUniform(), -3.0), 3.0)
                ouForce = min(max(aDrift * ouForce + driftGain * nextUniform(), -3.0), 3.0)
                if driftCents > 1e-9 {
                    vibOct += driftCents * ouPitch / 1200.0
                }
            }
            // fret linger: evolve the expression charge and the auto-vib
            // depth. Stillness decays the charge (the note eases down) and
            // grows the depth toward the y-set ceiling; vertical movement
            // (the drive) recharges expression and returns the vibrato to
            // its no-vibrato birth state. First-order in both directions —
            // smooth by construction.
            var exprScale = 1.0
            if lingerActive {
                lingerSpd = (1.0 - aMove) * spdInst + aMove * lingerSpd
                let drive = min(lingerSpd / lingerSpeedRef, 1.0)
                if lingerDecayS > 1e-6 {
                    lingerCharge += (drive * (1.0 - lingerCharge) / lingerRechargeS
                        - (1.0 - drive) * lingerCharge / lingerDecayS) * dtk
                    lingerCharge = min(max(lingerCharge, 0.0), 1.0)
                    exprScale = lingerFloor + (1.0 - lingerFloor) * lingerCharge
                }
                if avibCents > 1e-9 {
                    avibDepth += ((1.0 - drive) * (avibMax - avibDepth) / avibGrowS
                        - drive * avibDepth / lingerRechargeS) * dtk
                    avibDepth = min(max(avibDepth, 0.0), 1.0)
                    avibPhase += avibW
                    if avibPhase > 2.0 * Double.pi {
                        avibPhase -= 2.0 * Double.pi
                    }
                    if avibDepth > 1e-6 {
                        vibOct += avibCents * avibDepth * sin(avibPhase) / 1200.0
                    }
                }
            }
            // glide lightening drive: sounding-pitch slew in cents/s
            if glideDipDb > 1e-9 {
                let r = lastLfValid ? abs(lf0B - lastLf) * 1200.0 * srk : 0.0
                let target = glideDipDb * r / (r + glideDipRate)
                let a = target > dipDb ? aDipAtt : aDipRel
                dipDb = (1.0 - a) * target + a * dipDb
                lastLf = lf0B
                lastLfValid = true
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
            // exprScale is exactly 1.0 whenever the linger is inactive, so
            // this multiply is bit-null on the legacy paths.
            let exprEff = expr * exprScale
            let e01 = min(max(exprEff, 0.0), 1.0)
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
            // ANALYTIC Schelleng wedge, from the friction params:
            // fmin = M·C·v/β² (minimum force to sustain Helmholtz),
            // fmax = 2Zv/(β·Δμ) (maximum before raucous). There used to be a
            // MEASURED alternative here (`BowWedge`, a per-(f0, β, v)
            // trilinear force table from the sarangi-era `calibrate_wedge`);
            // the pure-physics artifact Tarabdaar ships has never carried one,
            // so only this branch ever ran, and the table went with the rest
            // of the upstream machinery (2026-07-24).
            let lo = schellengMargin * schellengC * vb / max(beta * beta, 1e-6)
            let hi = max(2.0 * schellengZ * vb / (max(beta, 1e-3) * schellengDmu),
                         lo * 1.05)
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
                let lift = min(1.0, max(0.0, exprEff) / exprLift)
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
            placeClock += dtk
            if placeS > 0.0 {
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
            // liveness: level/force wander + post-onset settle + glide
            // lightening, all as dB on the bow controls
            var vbDb = driftDb * ouLevel
            var fbDb = driftForceDb * ouForce
            if settleDb > 1e-9 {
                // SETTLE EXEMPTION (2026-08-19): a sharp attack keeps its
                // level — depth scaled by (1 − settleSharp·sharp). The
                // guard keeps settleSharp 0 bit-exact (no new arithmetic
                // on the legacy path).
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
                // light force coupling only: a heavy force cut slows the
                // string's re-capture and smears the transition (measured
                // ~150 ms to re-lock at 0.5× vs ~90 ms at 0.3×)
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
        resetLinger()
        lastOnEvt = 0
    }
}
