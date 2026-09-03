import Foundation

// MARK: - GlideSequencer

/// THE GLIDE QUEUE: queued glissandi for the playing voice. `AudioEngine`
/// funnels its public `touchOn`/`touchGlide`/`touchOff` through ONE
/// instance, so every touch source gets the same law. With `ctl_glide_on`
/// armed, an onset that OVERLAPS the sounding chain in time (some member
/// still physically down) does not mount a fresh string — it is QUEUED as
/// a waypoint and the sounding voice glides to it. Non-overlapping onsets,
/// exempt touches (`glideExempt` — the strum chord) and everything
/// non-touch pass through. Releases are NEVER deferred. At the default
/// `ctl_glide_on` 0 the class is a pure pass-through (the parity contract).
///
/// Laws:
/// - **Overlap gate** — an onset joins only while the active chain has a
///   touch still down (owner, parked finger, or unreleased waypoint).
/// - **Speed** — `ctl_glide_rate` st/s, × `ctl_glide_held` (< 1) while the
///   touch being glided FROM is still down, × `ctl_glide_catchup` (> 1)
///   while the target is not the END of the queue.
/// - **Shape** — `fretWarp(progress, ctl_fret_warp)` in log-pitch space:
///   linear at 0, logistic at 1.
/// - **Overshoot** — the FINAL approach aims `ctl_glide_over` × distance
///   PAST the target (capped ±0.5 st), then settles back gentler.
///   Mid-queue arrivals never overshoot; a note queued mid-correction
///   glides on from wherever the pitch is; the waypoint is consumed at
///   the SETTLE.
/// - **Repeat tap** — an overlapping tap at the chain's current pitch
///   (±25 ¢, queue empty) is a real re-attack.
/// - **Ownership** — on arrival, the waypoint's touch OWNS the voice: its
///   drags meend it, its release ends it (mapped onto the voice's original
///   wire id). Arriving on an already-lifted finger releases on arrival.
/// - **Parked fingers & glide-back** — past members still down are PARKED:
///   only the owner's drags drive the voice; a parked finger's movements
///   are remembered SILENTLY (the head's id IS the voice's downstream id —
///   following it would yank the pitch back on every wiggle). Releasing
///   the owner glides BACK to the most recent parked finger's CURRENT
///   position at full rate; the bow comes up only when every member lifts.
///
/// A control-layer queue ABOVE allocation: a captured onset never becomes
/// a note-on, so every mounted note still gets a fresh string.
///
/// Threading: all entry points are thread-safe; downstream calls are
/// emitted OUTSIDE the lock in event order.
public final class GlideSequencer {
    /// Downstream taps (`AudioEngine`'s direct touch path); thread-safe.
    public var onTouchOn: ((UInt16, Double, Double) -> Void)?
    public var onTouchGlide: ((UInt16, Double) -> Void)?
    public var onTouchOff: ((UInt16) -> Void)?

    /// Repeat-tap window (semis).
    static let repeatEps = 0.25   // 25 cents
    /// Glide tick rate — matches the link's 120 Hz pacing.
    static let tickHz = 120.0
    /// Overshoot cap (semis).
    static let overshootCapSemis = 0.5
    /// The settle from the overshot peak runs at this fraction of the
    /// approach rate, but never faster than `correctionMinS`.
    static let correctionRateFrac = 0.3
    static let correctionMinS = 0.06

    private let lock = NSLock()
    private let clock: () -> Double
    private let drivesTimer: Bool

    // Control values (the ctl_glide_* registry keys + the shared warp).
    private var enabled = false
    private var rateStPerS = 40.0
    private var heldMul = 0.3
    private var catchUpMul = 4.0
    /// `ctl_glide_over`; must match the registry default.
    private var overFrac = 0.08
    private var warpAmount = 0.0

    private struct Waypoint {
        let id: UInt16
        var pitch: Double
        var released: Bool
    }

    /// One glissando lineage: the sounding voice (`voiceId`, the chain's
    /// FIRST touch), the owning touch and the pending waypoints. Only the
    /// NEWEST chain accepts new waypoints.
    private struct Chain {
        var voiceId: UInt16
        var voicePitch: Double
        var ownerId: UInt16
        var ownerHeld: Bool
        /// The owner's last known FINGER pitch, tracked even while its
        /// drags are ignored.
        var ownerPitch: Double
        var queue: [Waypoint] = []
        /// Past members still down, join-order (the glide-back stack).
        var parked: [(id: UInt16, pitch: Double)] = []
        var segStart = 0.0
        var segProgress = 0.0
        /// Settling back from an overshoot (`segStart` = the peak).
        var overshooting = false

        /// The OVERLAP gate.
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

    /// `drivesTimer: false` + an injected `clock` = the test harness.
    public init(drivesTimer: Bool = true,
                clock: @escaping () -> Double = {
                    ProcessInfo.processInfo.systemUptime
                }) {
        self.drivesTimer = drivesTimer
        self.clock = clock
    }

    // MARK: Controls

    /// One setter for the `ctl_glide_*` family; unknown keys are ignored.
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

    /// `ctl_fret_warp` (0…1) — the segment shape.
    public func setWarp(_ amount: Double) {
        lock.lock()
        warpAmount = min(max(amount, 0), 1)
        lock.unlock()
    }

    // MARK: Touch stream (upstream: the link ingests)

    /// Pre-onset exemption (the strum chord): `id`'s next onset and its
    /// whole life pass through untouched.
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

        let joinable = enabled && !chains.isEmpty
            && chains[chains.count - 1].hasHeldTouch
        let repeatTap = joinable && chains[chains.count - 1].queue.isEmpty
            && abs(pitchSemis - chains[chains.count - 1].voicePitch)
                < Self.repeatEps

        if joinable && !repeatTap {
            // QUEUE: a waypoint, no fresh string.
            let i = chains.count - 1
            if chains[i].queue.isEmpty {
                chains[i].segStart = chains[i].voicePitch
                chains[i].segProgress = 0
            }
            // A coalesced lift+re-press supersedes a parked entry.
            chains[i].parked.removeAll { $0.id == id }
            chains[i].queue.append(
                Waypoint(id: id, pitch: pitchSemis, released: false))
            startTickingLocked(now: now)
        } else {
            // PASS THROUGH: a fresh note and the new active chain. A
            // retrigger of a resting chain's owner releases that voice first.
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
                chains[i].queue[w].pitch = pitchSemis
            } else if chains[i].ownerId == id {
                chains[i].ownerPitch = pitchSemis
                if chains[i].queue.isEmpty {
                    // Plain meend on the resting voice.
                    chains[i].voicePitch = pitchSemis
                    actions.append(.glide(chains[i].voiceId, pitchSemis))
                }
            } else if let p = chains[i].parked.lastIndex(where: {
                $0.id == id
            }) {
                // A PARKED finger moving: remember silently — falling
                // through to pass-through would yank the pitch back.
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
                // Released before reached: stays queued, unowned.
                chains[i].queue[w].released = true
            } else if chains[i].ownerId == id {
                if !chains[i].queue.isEmpty {
                    // Gliding away from a lifted finger.
                    chains[i].ownerHeld = false
                } else if let back = chains[i].parked.popLast() {
                    // GLIDE BACK to the most recent parked finger's CURRENT
                    // position at full rate; it takes ownership on arrival.
                    chains[i].queue = [Waypoint(id: back.id,
                                                pitch: back.pitch,
                                                released: false)]
                    chains[i].segStart = chains[i].voicePitch
                    chains[i].segProgress = 0
                    chains[i].ownerHeld = false
                    startTickingLocked(now: clock())
                } else {
                    // Ordinary release, immediately.
                    actions.append(.off(chains[i].voiceId))
                    chains.remove(at: i)
                }
            } else {
                // A parked finger lifting.
                chains[i].parked.removeAll { $0.id == id }
            }
        } else {
            actions.append(.off(id))
        }
        lock.unlock()
        run(actions)
    }

    /// The kill path: forget everything. The caller has already silenced
    /// the voices, so no releases are emitted.
    public func reset() {
        lock.lock()
        chains.removeAll()
        exempt.removeAll()
        stopTimerLocked()
        lock.unlock()
    }

    // MARK: Glide clock

    /// Advance every in-flight glide (the 120 Hz timer, or a test's `now`).
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
                    // Arrived on a lifted note: glide back (see touchOff).
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

    /// Advance one chain by `dt`, cascading through as many waypoints as
    /// the time budget reaches.
    private func advanceChainLocked(_ c: inout Chain, dt: Double,
                                    into actions: inout [Action]) {
        var remaining = dt
        while remaining > 0, !c.queue.isEmpty {
            let target = c.queue[0].pitch
            let rate = rateStPerS
                * (c.ownerHeld ? heldMul : 1.0)
                * (c.queue.count > 1 ? catchUpMul : 1.0)
            // Overshoot only on the run's FINAL approach.
            let ovApplies = overFrac > 0 && c.queue.count == 1

            if c.overshooting && !ovApplies {
                // Queued mid-correction: abandon the settle, glide on.
                c.overshooting = false
                c.segStart = c.voicePitch
                c.segProgress = 0
            }

            if c.overshooting {
                // CORRECTION: settle from the peak onto the target.
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

            // APPROACH: toward the target, or past it on a final approach.
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
                    // Peak reached: emit the miss, then settle.
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

    /// Consume `queue[0]`: hit the waypoint exactly and hand it ownership;
    /// a still-held old owner PARKS. The tick loop handles a lifted arrival.
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
