import Foundation

// MARK: - GlideSequencer

/// THE GLIDE QUEUE (2026-08-31): queued glissandi for the playing voice.
///
/// Sits between the link ingest's touch stream and the voice routing —
/// `AudioEngine` funnels its public `touchOn`/`touchGlide`/`touchOff`
/// through ONE instance — so every touch source (iPad wire, Mac pads,
/// the keyboard player, audition `touchOn` scores) gets the same law:
/// with `ctl_glide_on` armed, a new onset that OVERLAPS the previous
/// note IN TIME (some member of the active chain is still physically
/// down) does NOT mount a fresh string — it is QUEUED as a waypoint
/// and the sounding voice GLIDES to it, hitting every queued pitch in
/// sequence. Non-overlapping onsets, exempt touches (the strum chord —
/// `glideExempt` rides the in-process touch record like `exprScale`)
/// and everything non-touch pass through untouched; releases are NEVER
/// deferred (staccato articulation is exactly the historic one — the
/// 2026-08-31 threshold-window/release-grace first cut sustained every
/// short tap and was replaced by this overlap rule the same day). The
/// whole feature is a PURE PASS-THROUGH at the default `ctl_glide_on`
/// 0 (the inert-default/parity contract).
///
/// Laws:
/// - **Overlap gate** — an onset joins the glissando only while the
///   active chain has a touch still down (its resting owner, or a
///   queued note not yet released). Once every member has lifted the
///   chain is over — the next tap is a fresh attack.
/// - **Speed** — `ctl_glide_rate` semitones/second over each segment,
///   × `ctl_glide_held` (< 1, slower) while the touch we are gliding
///   FROM is still down (expressive meend), × `ctl_glide_catchup`
///   (> 1, faster) while the current target is not the END of the
///   queue — the trajectory hurries to catch the player up.
/// - **Shape** — each segment runs through `fretWarp(progress,
///   ctl_fret_warp)` in log-pitch space: linear at warp 0, logistic at
///   1, exactly the curve a finger tracing between two adjacent frets
///   would play on the warped field.
/// - **Overshoot** — the run's FINAL approach (nothing further queued)
///   aims `ctl_glide_over` × the glide distance PAST the target
///   (capped ±0.5 st), then settles back onto the exact pitch at a
///   gentler rate — the human player's land-and-correct. Mid-queue
///   arrivals never overshoot (the trajectory is hurrying), a note
///   queued mid-correction abandons the settle and glides on from
///   wherever the pitch is, and the waypoint is consumed only at the
///   SETTLE, so ownership/release/glide-back semantics are untouched.
/// - **Repeat tap** — an overlapping tap at the chain's current pitch
///   (±25 ¢, queue empty) passes through as a real re-attack, so a
///   second finger can re-strike the sounding note.
/// - **Ownership** — after arriving at a waypoint, that waypoint's
///   physical touch OWNS the sounding voice: its drags meend it, its
///   release ends it (mapped onto the voice's original wire id — the
///   downstream never learns the queued ids). Arriving on a waypoint
///   whose finger has already lifted releases the voice on arrival.
/// - **Parked fingers & glide-back** — past chain members still down
///   are PARKED: only the current owner's drags drive the voice, a
///   parked finger's movements are remembered SILENTLY (without this,
///   a held first finger's wire id — the voice's own downstream id —
///   fell through to pass-through and every wiggle yanked the pitch
///   back: the two-finger oscillation bug). Releasing the owner with
///   parked fingers remaining glides BACK to the most recent one, at
///   the finger's CURRENT position, full rate (the source lifted);
///   only when every member has lifted does the bow come up.
///
/// This is NOT a revival of the 2026-08-24-removed legato/steal
/// allocation laws: it is a control-layer queue ABOVE allocation — a
/// captured onset never becomes a note-on at all, so every note that
/// actually mounts still gets a fresh string, and pitch still tracks
/// the finger directly whenever no queue is in flight.
///
/// Threading: all entry points are thread-safe (link receive queue,
/// main-thread local pumps, the internal 120 Hz glide timer). Downstream
/// calls are emitted OUTSIDE the lock in event order.
public final class GlideSequencer {
    /// Downstream taps — `AudioEngine` wires these to its direct touch
    /// path. Called outside the sequencer's lock; must be thread-safe.
    public var onTouchOn: ((UInt16, Double, Double) -> Void)?
    public var onTouchGlide: ((UInt16, Double) -> Void)?
    public var onTouchOff: ((UInt16) -> Void)?

    /// Repeat-tap articulation exception: an onset this close (semis) to
    /// the chain's current pitch with an empty queue is a fresh attack.
    static let repeatEps = 0.25   // 25 cents
    /// Glide tick rate — matches the link's 120 Hz pacing; the mapper
    /// ramps to each update within one render block anyway.
    static let tickHz = 120.0
    /// Overshoot cap in semitones (±50 ¢) — `ctl_glide_over` scales with
    /// the glide distance, this keeps a big jump's miss human-sized.
    static let overshootCapSemis = 0.5
    /// The settle back from the overshot peak runs at this fraction of
    /// the approach rate (the correction is gentler than the swing)…
    static let correctionRateFrac = 0.3
    /// …but never faster than this floor (s) — a tiny overshoot still
    /// reads as a touch-and-settle, not a click.
    static let correctionMinS = 0.06

    private let lock = NSLock()
    private let clock: () -> Double
    private let drivesTimer: Bool

    // Control values (the ctl_glide_* registry keys + the shared warp).
    private var enabled = false
    private var rateStPerS = 40.0
    private var heldMul = 0.3
    private var catchUpMul = 4.0
    /// Fraction of the glide distance overshot past the final target
    /// (`ctl_glide_over`; must match the registry default).
    private var overFrac = 0.08
    private var warpAmount = 0.0

    private struct Waypoint {
        let id: UInt16
        var pitch: Double
        var released: Bool
    }

    /// One glissando lineage: the sounding voice (downstream id =
    /// `voiceId`, always the chain's FIRST touch), the touch currently
    /// owning the position, and the pending waypoints. A chain lives as
    /// long as its voice sounds — resting chains (empty queue, held
    /// owner) stay in the array so owner drags/releases keep routing to
    /// `voiceId`; only the NEWEST chain accepts new waypoints.
    private struct Chain {
        var voiceId: UInt16
        var voicePitch: Double
        var ownerId: UInt16
        var ownerHeld: Bool
        /// The owner's last known FINGER pitch — tracked even while its
        /// drags are ignored (gliding away), so parking it remembers
        /// where the finger actually is.
        var ownerPitch: Double
        var queue: [Waypoint] = []
        /// Past members still physically down, join-order (most recent
        /// last — the glide-back priority stack). Their drags update
        /// `pitch` silently; the voice never follows them.
        var parked: [(id: UInt16, pitch: Double)] = []
        var segStart = 0.0
        var segProgress = 0.0
        /// Correction phase: the approach overshot the final target and
        /// the pitch is settling back onto it (`segStart` = the peak).
        var overshooting = false

        /// The OVERLAP gate: is any of this chain's touches still
        /// physically down? Only then may a new onset join it.
        var hasHeldTouch: Bool {
            ownerHeld || !parked.isEmpty || queue.contains { !$0.released }
        }
    }

    private var chains: [Chain] = []
    private var exempt: Set<UInt16> = []
    private var timer: DispatchSourceTimer?
    private var lastTickTime = 0.0
    private let timerQueue = DispatchQueue(
        label: "com.tarabdaar.glide-sequencer", qos: .userInteractive)

    private enum Action {
        case on(UInt16, Double, Double)
        case glide(UInt16, Double)
        case off(UInt16)
    }

    /// `drivesTimer: false` + an injected `clock` = the test harness:
    /// call `tick(now:)` by hand.
    public init(drivesTimer: Bool = true,
                clock: @escaping () -> Double = {
                    ProcessInfo.processInfo.systemUptime
                }) {
        self.drivesTimer = drivesTimer
        self.clock = clock
    }

    // MARK: Controls

    /// One setter for the whole `ctl_glide_*` family (the AppController
    /// interception forwards the raw registry value). Unknown keys are
    /// ignored. Thread-safe.
    public func setControl(_ key: String, _ value: Double) {
        lock.lock()
        switch key {
        case "ctl_glide_on":      enabled = value >= 0.5
        case "ctl_glide_rate":    rateStPerS = max(0.1, value)
        case "ctl_glide_held":    heldMul = min(max(value, 0.01), 1)
        case "ctl_glide_catchup": catchUpMul = max(1, value)
        case "ctl_glide_over":    overFrac = min(max(value, 0), 0.3)
        default: break
        }
        lock.unlock()
    }

    /// The shared `ctl_fret_warp` amount (0…1) — the segment shape.
    public func setWarp(_ amount: Double) {
        lock.lock()
        warpAmount = min(max(amount, 0), 1)
        lock.unlock()
    }

    // MARK: Touch stream (upstream: the link ingests)

    /// Pre-onset exemption mark (the strum chord): the NEXT onset of
    /// `id` — and its whole life — passes through untouched and never
    /// joins or starts a chain.
    public func markExempt(_ id: UInt16) {
        lock.lock()
        exempt.insert(id)
        lock.unlock()
    }

    public func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double) {
        lock.lock()
        let now = clock()
        var actions: [Action] = []

        if exempt.contains(id) {
            actions.append(.on(id, pitchSemis, velocity))
            lock.unlock()
            run(actions)
            return
        }

        // The OVERLAP gate: the onset joins the glissando only while
        // the active chain still has a touch physically down.
        let joinable = enabled && !chains.isEmpty
            && chains[chains.count - 1].hasHeldTouch
        let repeatTap = joinable && chains[chains.count - 1].queue.isEmpty
            && abs(pitchSemis - chains[chains.count - 1].voicePitch)
                < Self.repeatEps

        if joinable && !repeatTap {
            // QUEUE: the onset becomes a waypoint — no fresh string.
            let i = chains.count - 1
            if chains[i].queue.isEmpty {
                chains[i].segStart = chains[i].voicePitch
                chains[i].segProgress = 0
            }
            // A coalesced lift+re-press of a parked finger: its parked
            // entry is superseded by the fresh waypoint.
            chains[i].parked.removeAll { $0.id == id }
            chains[i].queue.append(
                Waypoint(id: id, pitch: pitchSemis, released: false))
            startTickingLocked(now: now)
        } else {
            // PASS THROUGH: a fresh note, and the new active chain.
            // A retrigger of an id that owns a resting chain is a
            // coalesced lift+re-press: release that voice first.
            if let i = chains.firstIndex(where: {
                $0.ownerId == id && $0.queue.isEmpty
            }) {
                actions.append(.off(chains[i].voiceId))
                chains.remove(at: i)
            }
            actions.append(.on(id, pitchSemis, velocity))
            chains.append(Chain(voiceId: id, voicePitch: pitchSemis,
                                ownerId: id, ownerHeld: true,
                                ownerPitch: pitchSemis))
        }
        lock.unlock()
        run(actions)
    }

    public func touchGlide(_ id: UInt16, pitchSemis: Double) {
        lock.lock()
        var actions: [Action] = []
        if !exempt.contains(id), let i = chainIndex(containing: id) {
            if let w = chains[i].queue.lastIndex(where: { $0.id == id }) {
                // A queued finger adjusting where the glide will land.
                chains[i].queue[w].pitch = pitchSemis
            } else if chains[i].ownerId == id {
                chains[i].ownerPitch = pitchSemis
                if chains[i].queue.isEmpty {
                    // Plain meend on the resting voice (mapped id).
                    chains[i].voicePitch = pitchSemis
                    actions.append(.glide(chains[i].voiceId, pitchSemis))
                }
                // else: we're already gliding away from this finger —
                // its residual movement only updates the remembered
                // finger position.
            } else if let p = chains[i].parked.lastIndex(where: {
                $0.id == id
            }) {
                // A PARKED finger moving: remember silently — the voice
                // belongs to the current owner (following it here was
                // the two-finger oscillation bug: the head's id IS the
                // voice's downstream id, so falling through to the
                // pass-through yanked the pitch back on every wiggle).
                // A later glide-back returns to where the finger is.
                chains[i].parked[p].pitch = pitchSemis
            }
        } else {
            actions.append(.glide(id, pitchSemis))
        }
        lock.unlock()
        run(actions)
    }

    public func touchOff(_ id: UInt16) {
        lock.lock()
        var actions: [Action] = []
        if exempt.remove(id) != nil {
            actions.append(.off(id))
        } else if let i = chainIndex(containing: id) {
            if let w = chains[i].queue.lastIndex(where: { $0.id == id }) {
                // A queued note released before we reached it: it stays
                // queued (the trajectory still hits it), just unowned.
                chains[i].queue[w].released = true
            } else if chains[i].ownerId == id {
                if !chains[i].queue.isEmpty {
                    // Gliding away from a lifted finger: speed up.
                    chains[i].ownerHeld = false
                } else if let back = chains[i].parked.popLast() {
                    // GLIDE BACK: the owner lifted but an earlier chain
                    // member is still down — return to that finger's
                    // CURRENT position, at the full (released) rate; it
                    // takes ownership on arrival.
                    chains[i].queue = [Waypoint(id: back.id,
                                                pitch: back.pitch,
                                                released: false)]
                    chains[i].segStart = chains[i].voicePitch
                    chains[i].segProgress = 0
                    chains[i].ownerHeld = false
                    startTickingLocked(now: clock())
                } else {
                    // Nothing queued, nobody parked: an ordinary
                    // release, immediately — staccato articulation is
                    // exactly the historic one.
                    actions.append(.off(chains[i].voiceId))
                    chains.remove(at: i)
                }
            } else {
                // A parked finger lifting: silently out of the chain.
                chains[i].parked.removeAll { $0.id == id }
            }
        } else {
            actions.append(.off(id))
        }
        lock.unlock()
        run(actions)
    }

    /// The kill path (link drop / panic / instrument switch): forget
    /// everything. The caller has already silenced the voices, so no
    /// releases are emitted.
    public func reset() {
        lock.lock()
        chains.removeAll()
        exempt.removeAll()
        stopTimerLocked()
        lock.unlock()
    }

    // MARK: Glide clock

    /// Advance every in-flight glide. The internal 120 Hz timer calls
    /// this with the real clock; tests inject `now`.
    public func tick(now: Double? = nil) {
        lock.lock()
        let t = now ?? clock()
        let dt = max(0, t - lastTickTime)
        lastTickTime = t
        var actions: [Action] = []

        var i = 0
        while i < chains.count {
            advanceChainLocked(&chains[i], dt: dt, into: &actions)
            if chains[i].queue.isEmpty, !chains[i].ownerHeld {
                if let back = chains[i].parked.popLast() {
                    // Arrived on a lifted note with an earlier finger
                    // still down: glide back to it (see touchOff).
                    chains[i].queue = [Waypoint(id: back.id,
                                                pitch: back.pitch,
                                                released: false)]
                    chains[i].segStart = chains[i].voicePitch
                    chains[i].segProgress = 0
                    i += 1
                } else {
                    // The run is over — bow up.
                    actions.append(.off(chains[i].voiceId))
                    chains.remove(at: i)
                }
            } else {
                i += 1
            }
        }
        if !needsTicksLocked { stopTimerLocked() }
        lock.unlock()
        run(actions)
    }

    /// Advance one chain's glide by `dt`, cascading through as many
    /// waypoints (and overshoot corrections) as the time budget reaches.
    private func advanceChainLocked(_ c: inout Chain, dt: Double,
                                    into actions: inout [Action]) {
        var remaining = dt
        while remaining > 0, !c.queue.isEmpty {
            let target = c.queue[0].pitch
            let rate = rateStPerS
                * (c.ownerHeld ? heldMul : 1.0)
                * (c.queue.count > 1 ? catchUpMul : 1.0)
            // Overshoot only on the run's FINAL approach — a mid-queue
            // arrival is already hurrying to catch up.
            let ovApplies = overFrac > 0 && c.queue.count == 1

            if c.overshooting && !ovApplies {
                // A new note queued mid-correction: abandon the settle
                // and glide onward from wherever the pitch is.
                c.overshooting = false
                c.segStart = c.voicePitch
                c.segProgress = 0
            }

            if c.overshooting {
                // CORRECTION: settle from the overshot peak back onto
                // the target, gentler than the approach.
                let dist = abs(target - c.segStart)
                let duration = max(dist / (Self.correctionRateFrac * rate),
                                   Self.correctionMinS)
                let need = (1.0 - c.segProgress) * duration
                if remaining >= need || dist < 1e-9 {
                    remaining -= max(need, 0)
                    arriveLocked(&c, at: target, into: &actions)
                } else {
                    c.segProgress += remaining / duration
                    remaining = 0
                    let shaped = fretWarp(c.segProgress, amount: warpAmount)
                    c.voicePitch = c.segStart
                        + (target - c.segStart) * shaped
                    actions.append(.glide(c.voiceId, c.voicePitch))
                }
                continue
            }

            // APPROACH: toward the target — or, on a final approach, a
            // touch past it (proportional to the distance, capped
            // human-sized) before settling back.
            let dist0 = abs(target - c.segStart)
            let ov = ovApplies
                ? min(Self.overshootCapSemis, overFrac * dist0) : 0
            let phaseTarget = target + (target >= c.segStart ? ov : -ov)
            let dist = abs(phaseTarget - c.segStart)
            let duration = dist / rate
            let need = (1.0 - c.segProgress) * duration
            if remaining >= need || dist < 1e-9 {
                remaining -= max(need, 0)
                if ov > 1e-9 {
                    // Peak reached: emit the miss, then settle back.
                    c.voicePitch = phaseTarget
                    actions.append(.glide(c.voiceId, phaseTarget))
                    c.overshooting = true
                    c.segStart = phaseTarget
                    c.segProgress = 0
                } else {
                    arriveLocked(&c, at: target, into: &actions)
                }
            } else {
                c.segProgress += remaining / duration
                remaining = 0
                let shaped = fretWarp(c.segProgress, amount: warpAmount)
                c.voicePitch = c.segStart
                    + (phaseTarget - c.segStart) * shaped
                actions.append(.glide(c.voiceId, c.voicePitch))
            }
        }
    }

    /// Consume `queue[0]` at `target`: hit the waypoint exactly and hand
    /// it ownership. A still-held old owner PARKS (its later drags are
    /// silent; releasing the new owner glides back to it). Landing on an
    /// already-lifted note with nothing further queued ends the run —
    /// the tick loop emits the off (or the glide-back).
    private func arriveLocked(_ c: inout Chain, at target: Double,
                              into actions: inout [Action]) {
        let w = c.queue.removeFirst()
        if c.ownerHeld {
            c.parked.append((c.ownerId, c.ownerPitch))
        }
        c.voicePitch = target
        c.segStart = target
        c.segProgress = 0
        c.overshooting = false
        c.ownerId = w.id
        c.ownerHeld = !w.released
        c.ownerPitch = target
        actions.append(.glide(c.voiceId, target))
    }

    // MARK: Internals

    private func chainIndex(containing id: UInt16) -> Int? {
        chains.firstIndex { c in
            c.ownerId == id || c.queue.contains { $0.id == id }
                || c.parked.contains { $0.id == id }
        }
    }

    private var needsTicksLocked: Bool {
        chains.contains { !$0.queue.isEmpty }
    }

    private func startTickingLocked(now: Double) {
        guard drivesTimer, timer == nil else {
            if timer == nil { lastTickTime = now }   // manual-tick harness
            return
        }
        lastTickTime = now
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 1.0 / Self.tickHz,
                   repeating: 1.0 / Self.tickHz,
                   leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func run(_ actions: [Action]) {
        for a in actions {
            switch a {
            case .on(let id, let p, let v): onTouchOn?(id, p, v)
            case .glide(let id, let p):     onTouchGlide?(id, p)
            case .off(let id):              onTouchOff?(id)
            }
        }
    }
}
