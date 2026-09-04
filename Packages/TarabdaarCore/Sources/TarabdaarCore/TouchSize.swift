import Foundation

/// TOUCH SIZE — the shared control-rate law behind the `.touchSize`
/// dimension and the iPad's per-touch size arc: the playing fingertip's
/// contact radius (`UITouch.majorRadius`, the PERF_STATE `radius` byte)
/// as a UNIPOLAR 0…1 axis.
///
/// Measured on the instrument (not guessed): a normally curled fingertip
/// reads **20.8** or **31.3** pt, and deliberately FLATTENING the finger
/// reaches **73.0** pt controllably, sometimes higher. So the window is
/// `Config.touchSizeLoPt … Config.touchSizeHiPt` (31.3 → 73.0) — normal
/// playing sits at the bottom of the range and a flattened finger sweeps
/// it — clamped at both ends:
///
///     mapped = clamp((r − lo) / (hi − lo), 0, 1)
///
/// **The signal is a staircase, so this ESTIMATES the finger, it does not
/// filter the staircase.** Apple quantises `majorRadius` to multiples of
/// `Config.touchRadiusQuantumPt` (≈10.42 pt), and a smoother or a rate
/// limiter fed the quantised value can only chase each step after it
/// lands — it ramps, STALLS at the level, ramps again. What the quanta
/// actually carry is better than that:
///
///  * A **level TRANSITION is an exact position fix.** The moment the
///    report changes q_old → q_new, the true radius crossed their
///    midpoint. That instant, not the level, is the measurement.
///  * **Two consecutive fixes measure the velocity**, in points per
///    second, of the real (continuous) finger — provided they belong to
///    one gesture (`Config.touchSizeGestureGapS`). The first crossing of a
///    gesture has no predecessor, so it assumes
///    `Config.touchSizeDefaultVelPtS` (the whole window in
///    `touchSizeRampS`) in the direction of the step.
///  * **Between fixes the estimate coasts** (p += v·dt) and is CLAMPED to
///    the current bin in the direction of travel: it may not pass
///    q ± h — the next midpoint, whose crossing would have been reported
///    if it had happened. The clamp is the only thing the silence proves.
///  * Pinned against that edge (or a whole `touchSizeGestureGapS` with no
///    crossing), the finger has **stopped**: the velocity decays
///    (`touchSizeVelDecayS`) and the estimate relaxes to the level's
///    CENTRE (`touchSizeSettleS`), the best static guess when motion says
///    nothing.
///  * The output rides a **critically damped second-order tracker**
///    (`touchSizeSmoothS`), so `value` has continuous velocity: the
///    estimator's cornered ramp becomes an S-curve that starts and stops
///    the way a finger does, with no kink at a crossing and no overshoot.
///
/// One law, two independent instances (the `FingerAccelTracker` pattern):
/// the Mac's is the control truth, fed from the wire radius stream in
/// `ControlAxisEvaluator` (following the NEWEST SOUNDING touch, releases
/// falling back to the survivor); the iPad's is display-only, drawing the
/// smoothed value as an arc on its per-touch ring — the data's SOURCE
/// side draws its own readout, no extra wire traffic.
///
/// `radiusPt` nil (or 0 = unknown: a producer with no touchscreen) is no
/// finger: the estimate relaxes to one quantum BELOW the window (the
/// measured curled-finger 20.9 pt), which the map clamps to exact rest.
/// A finger arriving after that initialises position, level and tracker
/// AT the reported level with zero velocity — a fresh curled finger reads
/// 0 immediately and a fresh flat one reads 1, neither sweeping up from a
/// stale state. UNIPOLAR like `.strike`: rest is 0, the curve's LEFT end.
public struct TouchSizeTracker {

    /// Raw fingertip radius (points) → the axis's 0…1 target.
    public static func mapped(radiusPt: Double) -> Double {
        let lo = Config.touchSizeLoPt
        let hi = Config.touchSizeHiPt
        guard hi > lo else { return 0 }
        return min(max((radiusPt - lo) / (hi - lo), 0.0), 1.0)
    }

    /// The estimated axis value, 0…1.
    public private(set) var value: Double = 0

    // MARK: Finger estimate (points)

    private var pos: Double = 0          // position estimate
    private var vel: Double = 0          // velocity estimate, pt/s
    private var level: Double = 0        // the level currently reported
    private var halfWidth = Config.touchRadiusQuantumPt / 2
    private var stopped = true
    private var lastCrossT: TimeInterval = 0
    private var prevFix: Double?
    private var prevCrossT: TimeInterval = 0
    private var down = false

    // MARK: Output tracker

    private var smooth: Double = 0
    private var smoothVel: Double = 0
    private var lastT: TimeInterval?

    /// No finger: one quantum below the window, which the map clamps to
    /// exact 0 (relaxing to `lo` itself would only creep at the clamp).
    private var restPt: Double {
        Config.touchSizeLoPt - Config.touchRadiusQuantumPt
    }

    public init() {}

    /// Feed one control-rate sample. `radiusPt` nil = no sounding touch
    /// (the axis relaxes to 0). Returns the updated `value`.
    @discardableResult
    public mutating func sample(radiusPt: Double?,
                                at t: TimeInterval) -> Double {
        let dt = min(max(t - (lastT ?? t), 0.0), 0.25)
        lastT = t

        let reported: Double? = radiusPt.flatMap { $0 > 0 ? $0 : nil }

        if let r = reported {
            if !down {
                // A NEW finger: the level IS the estimate. No ramp-up.
                down = true
                pos = r
                level = r
                vel = 0
                halfWidth = Config.touchRadiusQuantumPt / 2
                stopped = true
                lastCrossT = t
                prevFix = nil
                smooth = r
                smoothVel = 0
                value = Self.mapped(radiusPt: smooth)
                return value
            }
            if abs(r - level) > 0.05 {
                // A LEVEL TRANSITION — an exact position fix: the true
                // radius crossed the midpoint of the two levels, now.
                let fix = 0.5 * (level + r)
                halfWidth = 0.5 * abs(r - level)
                let gap = t - prevCrossT
                if let pf = prevFix, gap > 1e-6,
                   gap < Config.touchSizeGestureGapS {
                    vel = (fix - pf) / gap          // two fixes = a speed
                } else {
                    vel = (r > level ? 1.0 : -1.0)
                        * Config.touchSizeDefaultVelPtS
                }
                prevFix = fix
                prevCrossT = t
                lastCrossT = t
                level = r
                pos = fix
                stopped = false
            }
        } else if down {
            down = false
            stopped = true
        }

        // Coast, or settle onto the best static guess.
        let centre = down ? level : restPt
        if stopped {
            vel *= exp(-dt / Config.touchSizeVelDecayS)
            pos += (centre - pos)
                 * (1 - exp(-dt / Config.touchSizeSettleS))
        } else {
            pos += vel * dt
            let edge = vel >= 0 ? level + halfWidth : level - halfWidth
            if (vel >= 0 && pos >= edge) || (vel < 0 && pos <= edge) {
                pos = edge          // the crossing that would prove more
                stopped = true      // has not been reported: it stopped
            } else if t - lastCrossT > Config.touchSizeGestureGapS {
                stopped = true
            }
        }

        // Critically damped second-order tracker, integrated in closed
        // form so any control rate (30 Hz tick, 120 Hz wire) is stable.
        if dt > 0 {
            let w = 5.8 / max(Config.touchSizeSmoothS, 1e-3)
            let x0 = smooth - pos
            let b = smoothVel + w * x0
            let decay = exp(-w * dt)
            smooth = pos + (x0 + b * dt) * decay
            smoothVel = (b - w * x0 - w * b * dt) * decay
        }

        value = Self.mapped(radiusPt: smooth)
        return value
    }

    public mutating func reset() {
        value = 0
        pos = 0
        vel = 0
        level = 0
        halfWidth = Config.touchRadiusQuantumPt / 2
        stopped = true
        lastCrossT = 0
        prevFix = nil
        prevCrossT = 0
        down = false
        smooth = 0
        smoothVel = 0
        lastT = nil
    }
}
