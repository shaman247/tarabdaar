import CoreGraphics
import Foundation

// MARK: - Fret Pad drag assist
//
// Intonation assistance for **drags** (the onset snap handles note starts):
// a stop or direction change near a scale pitch was intended to be ON it;
// fast movement is a glide and is left alone.
//
// Mechanism — a **stop-gated magnetic correction**. Each touch carries one
// state value, `correction` (log2 units), and the played pitch is always
//
//     played = uncorrectedLog + correction
//
// where `uncorrectedLog` is the fret-field pitch at the cursor plus the
// constant onset offset. `correction` is slewed toward the nearest qualifying
// fret at a rate that is the product of:
//
//   • **stopped OR turn impulse** — the gate: dwell within `stillRadiusPx`
//     of a still anchor for `stopDwellMin` (ramping over `stopDwellRamp`) —
//     a glide at any tempo keeps restarting the clock; or a direction flip
//     (deadbanded dx sign change) firing an impulse that decays over
//     `turnTau`. Gate = min(1, max(stopGate, turnGain·impulse)).
//   • **proximity** — within `radiusScale` × the Snap radius in px AND inside
//     the fret's vertical extent (Snap = 0 disables assist); full pull inside
//     half the radius, fading to 0 at the edge.
//   • `settleTau` under a hard **slew cap** (~1500 cents/s).
//
// A fret the touch is **receding** from exerts no pull. With no pull, a
// stationary touch keeps its correction frozen while a moving touch sheds it
// with distance (`correctionDecayPx`). The output is always the slew-filtered
// state, so no input event can step the pitch.
//
// Stops emit no move events, so hosts feed `move(...)` from drag events and
// `tick(time:)` from a ~60 Hz timer while touches are down, sending the
// result to `PitchPadEngine.glide`. Time is injected (`CACurrentMediaTime()`).
// The constants are fitted to recorded playing (`FretGestureRecorder` +
// `tools/fretpad_fit.py`).
public final class FretDragAssist {
    /// Per-touch result: corrected pitch (log2 above the tonic), fill-glow
    /// weights, and the stop gate (0 = moving … 1 = stopped, dwell only).
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

    /// px/s below which the touch is stationary (receding check + shed gate).
    public var speedFloor: Double = 59
    /// The speed (px/s) a fresh touch is born at — treated as moving.
    public var speedCeiling: Double = 375
    /// Smoothing time constant for the speed estimate (s).
    public var speedTau: Double = 0.026
    /// Slew time constant for the correction (s); the hard `slewCap` is what
    /// actually bounds the rate.
    public var settleTau: Double = 0.005
    /// Magnet basin = `radiusScale` × the Snap radius, in px (42 px at the
    /// default 24 px Snap; the onset snap stays at 1×).
    public var radiusScale: Double = 1.75
    /// Direction-flip impulse strength: a turn sets `impulse = 1` and the
    /// gate is `max(stopGate, turnGain × impulse)` clamped to 1 — values > 1
    /// hold the gate fully open for `turnTau·ln(turnGain)` after the flip.
    public var turnGain: Double = 2.0
    /// Decay time constant of the flip impulse (s).
    public var turnTau: Double = 0.026
    /// The stop detector's still disc (px): inside = jitter, beyond re-anchors
    /// and restarts the dwell clock. Keeps glides down to ~20 px/s transparent.
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
    /// this many px of travel (half the default snap radius — anchors fade
    /// on basin-scale travel).
    private let correctionDecayPx: Double = 12.0
    /// Hard cap on the correction's slew rate (log2/s ≈ 1500 cents/s, inside
    /// natural meend speeds) — the output pitch can never step.
    private let slewCap: Double = 1500.0 / 1200.0
    /// Ticks arriving within this gap of the last move event don't decay the
    /// speed estimate (the finger is still moving; events are just sparse).
    private let stationaryGap: TimeInterval = 0.04

    public init() {}

    public var isEmpty: Bool { touches.isEmpty }

    /// Refresh the geometry (every down/drag event); the timer reuses it.
    public func setContext(placements: [FretPlacement], snapDistance: CGFloat) {
        self.placements = placements
        self.radiusPx = Double(max(0, snapDistance)) * radiusScale
    }

    /// Register a touch at note-on. Every touch is **born stopped**: the gate
    /// starts open, so a tap snaps its landing immediately (slew-capped) and
    /// the first movement shuts it. Correction starts at 0 — no onset step.
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
        // Deadbanded direction-flip detection: a turn fires the gate impulse.
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

    /// Timer tick (~60 Hz while touches are down): decays idle speed
    /// estimates and advances the settle. One output per active touch.
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

    /// One slew step: gate × proximity eases `correction` toward the
    /// candidate under the slew cap; frozen or shed when nothing qualifies.
    private func integrate(_ s: inout TouchState, dt: Double,
                           time: TimeInterval) -> Output {
        s.lastUpdateTime = time

        // Stopped ∈ [0, 1]: dwell inside the still disc for `stopDwellMin`,
        // then a smoothstep ramp over `stopDwellRamp`; leaving the disc
        // re-anchors and restarts the clock. The turn impulse can hold the
        // gate open regardless.
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

        // Candidate: nearest fret (px) within the basin whose extent
        // contains the touch.
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
        // A fret the touch is receding from (moving away above the
        // stationary floor) exerts no pull — the magnet never fights an
        // escape.
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
            // No qualifying pull: a moving touch sheds the carried
            // correction with distance travelled (one 1/e step per
            // `correctionDecayPx`); the movement gate (0 at the stationary
            // floor, 1 at twice it) keeps rests frozen.
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
