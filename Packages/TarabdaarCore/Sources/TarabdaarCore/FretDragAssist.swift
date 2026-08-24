import CoreGraphics
import Foundation

// MARK: - Fret Pad drag assist
//
// Intonation assistance for **drags** on the Fret Pad (the onset snap handles
// note starts — see `fretSnap`). Musical premise: when a player *stops* or
// *changes direction* near a scale pitch, that inflection point was intended
// to be **on** the pitch; while they're moving quickly, they're gliding and
// must be left alone.
//
// Mechanism — a **stop-gated magnetic correction**, continuous by
// construction. Each touch carries one state value, `correction` (log2
// units), and the played pitch is always
//
//     played = uncorrectedLog + correction
//
// where `uncorrectedLog` is the fret-field pitch at the cursor plus the
// constant onset offset. `correction` is *slewed* toward the nearest
// qualifying fret with a rate that is the product of three continuous
// factors:
//
//   • **stopped OR turn impulse** — the gate. "Stopped" is a genuine stop
//     detector (2026-08-17): the touch must dwell within `stillRadiusPx` of
//     a still anchor for `stopDwellMin` before the gate starts opening
//     (ramping to 1 over `stopDwellRamp`). A slow deliberate glide keeps
//     leaving the still disc, so the dwell clock keeps restarting and the
//     gate stays shut — pitch follows the finger at ANY glide tempo. (The
//     original gate was a smoothed-speed smoothstep, fitted 59/375 px/s;
//     it read a ~120 px/s glide as ~90% stationary and pulled slow glides
//     toward every approaching fret.) Jitter wanders inside the disc and
//     never restarts the clock, so rests still engage the magnet. Fast
//     connected playing turns in ~30 ms — too fast for any dwell — so a
//     causally-detected **direction flip** (deadbanded dx sign change, ~one
//     event of latency) fires an impulse that holds the gate open while it
//     decays (`turnGain`, `turnTau`). Gate = min(1, max(stopGate,
//     turnGain·impulse)).
//   • **proximity** — the fret must be within the assist basin
//     (`radiusScale` × the Snap radius, in **screen px** — frets are freely
//     positioned, so screen distance to the fret line is the natural metric,
//     matching the onset snap; fast landings are far sloppier than onsets)
//     of the touch AND the touch's y must be inside the fret's vertical
//     extent (above/below a segment stays free, and Snap = 0 disables assist
//     entirely). The pull is full inside half the radius and fades linearly
//     to 0 at the edge, so the field is continuous in space as well as time.
//   • a **settle time constant** (`settleTau`) with a hard **slew cap**
//     (~1500 cents/s) on the correction — smoothness is guaranteed by
//     construction, whatever the fitted constants say.
//
// The constants are FITTED to recorded real playing (`FretGestureRecorder` +
// `tools/fretpad_fit.py`); see the property comments for the fit provenance.
//
// A candidate the touch is actively **receding** from (moving away, smoothed
// speed above `speedFloor`) exerts NO pull — the magnet corrects approaches
// and rests, never fights an escape from a fret. When **no pull qualifies**,
// the correction's fate depends on motion: a **stationary** touch keeps it
// FROZEN (a deliberate microtonal hold doesn't drift, and touch jitter stays
// under the movement gate's floor), while a **moving** touch sheds it toward
// zero with distance travelled (`correctionDecayPx`, under the same slew
// cap) — so a glide away from an assisted landing converges on the raw
// field pitch however slow the tempo, and the next approach lands true
// instead of carrying the departed fret's anchor.
//
// Because the output is always the slew-filtered state, no input event —
// candidate switch, zone entry/exit, speed spike — can produce a pitch
// discontinuity.
//
// **Stops emit no move events**, so the settle must be driven by a ~60 Hz
// timer while touches are down: hosts feed `move(...)` from drag events and
// `tick(time:)` from the timer, and send the returned pitch to
// `PitchPadEngine.glide`. Time is injected (no internal clock) — callers pass
// `CACurrentMediaTime()`.
public final class FretDragAssist {
    /// Assisted result for one touch: the corrected pitch (log2 above the
    /// tonic), the fill-glow weights for the assisting fret, and the stop
    /// gate (0 = moving … 1 = stopped — the dwell detector's state, without
    /// the turn impulse) for per-touch indicator overlays.
    public struct Output {
        public let log2Pitch: Double
        public let weights: [String: Double]
        public let stopGate: Double
    }

    private struct TouchState {
        var x: CGFloat
        var y: CGFloat
        var uncorrectedLog: Double
        var speed: Double            // smoothed |dx/dt|, px/s
        var correction: Double       // log2 units, slew-filtered
        var impulse: Double          // direction-flip impulse, decaying 1→0
        var dxSign: Int              // last movement direction (±1, 0 unknown)
        var anchorX: CGFloat         // still anchor of the stopped detector
        var anchorY: CGFloat
        var stillStart: TimeInterval // when the touch last (re)entered the disc
        var lastMoveTime: TimeInterval
        var lastUpdateTime: TimeInterval
    }

    private var touches: [Int: TouchState] = [:]
    private var placements: [FretPlacement] = []
    private var radiusPx: Double = 0

    // Constants fitted to real iPad playing (2026-07-16: 8 repetitions of the
    // connected phrase p n d n p d m p g, `tools/fretpad_fit.py fit --phrase`;
    // landing error 39.7c → 29.3c, transit warping 2.3c). The recording was
    // fast connected playing — refit as more styles are recorded. Fitted
    // under the pitch-mapped ribbon (basin was ≈75¢ in log-pitch); since the
    // 2026-07-23 free-fret change the basin is the same 42 px in screen
    // space — re-record and refit on the new surface to re-verify.

    /// px/s below which the touch counts as fully stationary. Since the
    /// stopped-detector gate (2026-08-17) this no longer opens the magnet —
    /// it only bounds the receding check and the correction-shed movement
    /// gate.
    public var speedFloor: Double = 59
    /// px/s above which the speed-based shed gate saturates; also the speed
    /// a fresh touch is born at (treated as moving). No longer part of the
    /// magnet gate (2026-08-17).
    public var speedCeiling: Double = 375
    /// Smoothing time constant for the speed estimate (s).
    public var speedTau: Double = 0.026
    /// Slew time constant for the correction (s). Fitted very fast — the
    /// hard `slewCap` below is what actually bounds the correction rate,
    /// guaranteeing smoothness regardless of the fitted taus.
    public var settleTau: Double = 0.005
    /// The assist's magnet basin = `radiusScale` × the Snap radius, in px
    /// (the onset snap stays at 1× — fast landings are far sloppier than
    /// onsets). Fitted together with the Fret Pad's 24 px default Snap
    /// (basin = 42 px).
    public var radiusScale: Double = 1.75
    /// Direction-flip impulse strength: a causally-detected turn (dx sign
    /// flip) sets `impulse = 1`, and the gate is `max(speedGate, turnGain ×
    /// impulse)` clamped to 1 — values > 1 hold the gate fully open for
    /// `turnTau·ln(turnGain)` after the flip. The speed gate alone cannot
    /// open during a ~30 ms turn at fast tempi; the flip can.
    public var turnGain: Double = 2.0
    /// Decay time constant of the flip impulse (s).
    public var turnTau: Double = 0.026
    /// The stopped detector's still disc (px): wander within this radius of
    /// the anchor is jitter, not movement; drifting beyond it re-anchors and
    /// restarts the dwell clock. Must sit above resting-finger jitter and
    /// below the displacement a deliberate glide covers in `stopDwellMin` —
    /// 2 px keeps glides down to ~20 px/s transparent.
    public var stillRadiusPx: Double = 2.0
    /// Dwell (s) inside the still disc before the stop gate starts opening.
    public var stopDwellMin: Double = 0.10
    /// Ramp (s) over which the stop gate opens 0 → 1 past `stopDwellMin`.
    public var stopDwellRamp: Double = 0.15

    /// px of movement below which direction is not re-evaluated (touch jitter
    /// must not fire flips).
    private let turnDeadband: CGFloat = 0.7
    /// Distance constant (px) of the carried-correction shed: with no
    /// qualifying pull, a moving touch's correction loses a 1/e step per
    /// this many px of travel. Half the default 24 px snap radius — carried
    /// anchors are basin-scale artifacts, so they fade on basin-scale
    /// travel. Chosen analytically, not yet refit against recordings
    /// (2026-08-01).
    private let correctionDecayPx: Double = 12.0
    /// Hard cap on the correction's slew rate (log2 units/s ≈ 1500 cents/s,
    /// well inside natural meend speeds) — **smoothness by construction**:
    /// whatever the fitted constants, the output pitch can never step.
    private let slewCap: Double = 1500.0 / 1200.0
    /// Ticks arriving within this gap of the last move event don't decay the
    /// speed estimate (the finger is still moving; events are just sparse).
    private let stationaryGap: TimeInterval = 0.04

    public init() {}

    public var isEmpty: Bool { touches.isEmpty }

    /// Refresh the geometry the assist resolves against. Call from the
    /// surface whenever it has fresh placements (every down/drag event); the
    /// timer reuses the last context between events.
    public func setContext(placements: [FretPlacement], snapDistance: CGFloat) {
        self.placements = placements
        self.radiusPx = Double(max(0, snapDistance)) * radiusScale
    }

    /// Register a play touch at note-on. Every touch is **born stopped**
    /// (2026-08-18; legato-only 2026-08-17): a fresh finger isn't moving
    /// until it actually moves, so the dwell gate starts fully open — a
    /// staccato tap or legato strike snaps its sloppy landing onto the fret
    /// immediately (still slew-capped) instead of waiting out the stop
    /// dwell. The first ≥`stillRadiusPx` of movement re-anchors and shuts
    /// the gate, so a touch that turns into a glide is left alone from its
    /// first events; the documented approach-path starts (above/below a
    /// fret's extent, or in open space) have no magnet candidate at all.
    /// The onset itself never steps — correction starts at 0 and the onset
    /// snap owns the exact start pitch.
    public func begin(touchId: Int, x: CGFloat, y: CGFloat,
                      uncorrectedLog: Double, time: TimeInterval) {
        touches[touchId] = TouchState(x: x, y: y, uncorrectedLog: uncorrectedLog,
                                      speed: speedCeiling, correction: 0,
                                      impulse: 0, dxSign: 0,
                                      anchorX: x, anchorY: y,
                                      stillStart: time - stopDwellMin
                                          - stopDwellRamp,
                                      lastMoveTime: time, lastUpdateTime: time)
    }

    /// Feed a drag event; returns the assisted pitch to glide to.
    public func move(touchId: Int, x: CGFloat, y: CGFloat,
                     uncorrectedLog: Double, time: TimeInterval) -> Output {
        guard var s = touches[touchId] else {
            begin(touchId: touchId, x: x, y: y,
                  uncorrectedLog: uncorrectedLog, time: time)
            return Output(log2Pitch: uncorrectedLog, weights: [:], stopGate: 0)
        }
        let dt = min(max(time - s.lastUpdateTime, 1e-4), 0.1)
        s.impulse *= exp(-dt / turnTau)
        let dx = x - s.x
        let inst = Double(abs(dx)) / dt
        let alpha = 1 - exp(-dt / speedTau)
        s.speed += (inst - s.speed) * alpha
        // Causal direction-flip detection (deadbanded against jitter): a
        // genuine turn fires the impulse that opens the gate — the speed
        // gate alone can't react within a fast turn.
        if abs(dx) >= turnDeadband {
            let sign = dx > 0 ? 1 : -1
            if s.dxSign != 0 && sign != s.dxSign { s.impulse = 1.0 }
            s.dxSign = sign
        }
        s.x = x
        s.y = y
        s.uncorrectedLog = uncorrectedLog
        s.lastMoveTime = time
        let out = integrate(&s, dt: dt, time: time)
        touches[touchId] = s
        return out
    }

    /// Timer tick (~60 Hz while touches are down): decays the speed estimate
    /// of touches that have stopped emitting move events and advances the
    /// settle. Returns one assisted output per active touch.
    public func tick(time: TimeInterval) -> [(touchId: Int, output: Output)] {
        var outs: [(Int, Output)] = []
        for (id, state) in touches {
            var s = state
            let dt = min(max(time - s.lastUpdateTime, 1e-4), 0.1)
            s.impulse *= exp(-dt / turnTau)
            if time - s.lastMoveTime > stationaryGap {
                let alpha = 1 - exp(-dt / speedTau)
                s.speed += (0 - s.speed) * alpha
            }
            let out = integrate(&s, dt: dt, time: time)
            touches[id] = s
            outs.append((id, out))
        }
        return outs
    }

    public func end(touchId: Int) {
        touches.removeValue(forKey: touchId)
    }

    // MARK: Internals

    /// One slew step: gate (stationarity OR turn impulse, × proximity) →
    /// ease `correction` toward the candidate fret under the hard slew cap;
    /// freeze when nothing qualifies.
    private func integrate(_ s: inout TouchState, dt: Double,
                           time: TimeInterval) -> Output {
        s.lastUpdateTime = time

        // Stopped ∈ [0, 1]: the touch must dwell inside the still disc for
        // `stopDwellMin` before the gate opens (smoothstep ramp over
        // `stopDwellRamp`). A sustained drag — however slow — keeps leaving
        // the disc and restarting the clock, so the magnet never pulls a
        // glide; jitter stays inside the disc, so rests still engage it.
        // The turn impulse can hold the gate open regardless. Clamped to 1.
        let drift = Double(hypot(s.x - s.anchorX, s.y - s.anchorY))
        if drift > stillRadiusPx {
            s.anchorX = s.x
            s.anchorY = s.y
            s.stillStart = time
        }
        let v = max(0.0, min(1.0, (time - s.stillStart - stopDwellMin)
                                    / stopDwellRamp))
        let w = v * v * (3 - 2 * v)
        let gate = min(1.0, max(w, turnGain * s.impulse))

        // Candidate: nearest fret (in screen px — frets are freely
        // positioned) within the assist basin (radiusScale × Snap) whose
        // vertical extent contains the touch.
        var cand: FretPlacement? = nil
        var candD = Double.infinity
        if radiusPx > 0 {
            for p in placements {
                guard s.y >= p.topY, s.y <= p.bottomY else { continue }
                let d = Double(abs(p.x - s.x))
                if d <= radiusPx, d < candD {
                    cand = p
                    candD = d
                }
            }
        }

        var weights: [String: Double] = [:]
        // A fret the touch is actively RECEDING from (moving away from it,
        // smoothed speed above the stationary floor) exerts no pull — the
        // magnet corrects approaches and rests, never fights an escape.
        // (It used to: a slow glide off a fret kept re-anchoring to it all
        // the way across the basin, and the residue froze at the basin edge
        // and carried the departed fret's pitch into the next landing.)
        let receding: Bool = {
            guard let cand, s.dxSign != 0, s.speed > speedFloor,
                  cand.x != s.x else { return false }
            return (cand.x > s.x ? 1 : -1) != s.dxSign
        }()
        if let cand, !receding {
            // Full pull inside half the radius, fading to 0 at the edge —
            // continuous in space.
            let prox = max(0.0, min(1.0, 2.0 * (1.0 - candD / radiusPx)))
            let rate = (1 - exp(-dt / settleTau)) * gate * prox
            let target = log2(cand.ratio) - s.uncorrectedLog
            let cap = slewCap * dt
            let step = (target - s.correction) * rate
            s.correction += min(cap, max(-cap, step))
            // Glow: proximity-shaped, brightening as the gate opens.
            let glow = (1.0 - candD / radiusPx) * (0.3 + 0.7 * gate)
            if glow > 0.05 { weights[cand.id] = min(1.0, glow) }
        } else if s.correction != 0 {
            // No qualifying pull: a MOVING touch sheds the carried
            // correction with DISTANCE travelled (one 1/e step per
            // `correctionDecayPx`), so a glide away from an assisted
            // landing converges on the field's truth however slow the
            // tempo, and the next landing starts true rather than
            // sharp/flat by the old anchor. The movement gate (0 at the
            // stationary floor, 1 at twice it) keeps rests — including
            // touch jitter — frozen: a deliberate microtonal hold must
            // not drift.
            let mv = max(0.0, min(1.0, (s.speed - speedFloor) / speedFloor))
            let moveGate = mv * mv * (3 - 2 * mv)
            let travel = s.speed * dt
            let rate = (1 - exp(-travel / correctionDecayPx)) * moveGate
            let cap = slewCap * dt
            let step = -s.correction * rate
            s.correction += min(cap, max(-cap, step))
        }

        return Output(log2Pitch: s.uncorrectedLog + s.correction,
                      weights: weights, stopGate: w)
    }
}
