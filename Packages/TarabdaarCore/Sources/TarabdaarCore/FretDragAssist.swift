import CoreGraphics
import Foundation

/// Stable order of the resolved assist controls in JOYCON_STATE.
public enum FretAssistControl: Int, CaseIterable, Sendable {
    case amount, radius, stillRadius, dwell, ramp, settle, slew, turnGain, turnDecay, release

    public var key: String {
        let suffix: String
        switch self {
        case .amount: suffix = "amount"
        case .radius: suffix = "radius"
        case .stillRadius: suffix = "still_px"
        case .dwell: suffix = "dwell_ms"
        case .ramp: suffix = "ramp_ms"
        case .settle: suffix = "settle_ms"
        case .slew: suffix = "slew"
        case .turnGain: suffix = "turn"
        case .turnDecay: suffix = "turn_ms"
        case .release: suffix = "release_px"
        }
        return "ctl_fret_assist_" + suffix
    }
}

/// Mac-resolved performance values, in registry units; no bindings run on the pad.
public struct FretAssistSettings: Equatable, Sendable {
    // Binary32 keeps the local and remote pads on exactly the same controls.
    private var values: [Float]

    public init() {
        values = FretAssistControl.allCases.map { Float(ParamRegistry.spec($0.key)!.def) }
    }

    public subscript(_ control: FretAssistControl) -> Double {
        get { Double(values[control.rawValue]) }
        set {
            guard newValue.isFinite else { return }
            values[control.rawValue] = Float(ParamRegistry.spec(control.key)!.clamp(newValue))
        }
    }
}

// MARK: - Fret Pad drag assist
//
// Intonation assistance for **drags** (the onset snap handles note starts):
// a stop or direction change near a scale pitch was intended to be ON it;
// fast movement is a glide and is left alone.
//
// Mechanism — a **stop-gated magnetic correction**. Each touch carries one
// state value per region, `correction` (log2 units), and the played pitch is always
//
//     played = uncorrectedLog + correction
//
// where `uncorrectedLog` is the fret-field pitch at the cursor plus the
// region's constant onset offset. `correction` is slewed toward the nearest qualifying
// fret at a rate that is the product of:
//
//   • **stopped OR turn impulse** — the gate: dwell within `stillRadiusPx`
//     of a still anchor for `stopDwellMin` (ramping over `stopDwellRamp`) —
//     a glide at any tempo keeps restarting the clock; or a direction flip
//     (deadbanded dx sign change) firing an impulse that decays over
//     `turnTau`. Gate = min(1, max(stopGate, turnGain·impulse)).
//   • **proximity** — within `radiusScale` × the Snap radius in px within
//     the same region (Snap = 0 disables assist); full pull inside
//     half the radius, fading to 0 at the edge.
//   • `settleTau` under a hard **slew cap** (~1500 cents/s).
//
// A fret the touch is **receding** from exerts no pull. With no pull, a
// stationary touch keeps its correction frozen while a moving touch sheds it
// with distance (`correctionDecayPx`). Each correction is slew-filtered;
// spatial blending keeps region boundaries continuous.
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
        public let uncorrectedLog: Double
        public let weights: [String: Double]
        public let stopGate: Double
    }

    private struct TouchState {
        var x: CGFloat
        var y: CGFloat
        var uncorrectedLog: Double
        var speed: Double            // smoothed |dx/dt|, px/s
        var corrections: [FretRegion: Double] // independent, slew-filtered region offsets
        var regionLogs: [FretRegion: Double]
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
    private var snapDistance: Double = 0
    private var radiusPx: Double { snapDistance * radiusScale }
    public var settings = FretAssistSettings()
    public var amount: Double { settings[.amount] }

    /// px/s below which the touch is stationary (receding check + shed gate).
    public var speedFloor: Double = 59
    /// The speed (px/s) a fresh touch is born at — treated as moving.
    public var speedCeiling: Double = 375
    /// Smoothing time constant for the speed estimate (s).
    public var speedTau: Double = 0.026
    /// Slew time constant for the correction (s); the hard `slewCap` is what
    /// actually bounds the rate.
    public var settleTau: Double { settings[.settle] / 1000 }
    /// Magnet basin = `radiusScale` × the Snap radius, in px (42 px at the
    /// default 24 px Snap; the onset snap stays at 1×).
    public var radiusScale: Double { settings[.radius] }
    /// Direction-flip impulse strength: a turn sets `impulse = 1` and the
    /// gate is `max(stopGate, turnGain × impulse)` clamped to 1 — values > 1
    /// hold the gate fully open for `turnTau·ln(turnGain)` after the flip.
    public var turnGain: Double { settings[.turnGain] }
    /// Decay time constant of the flip impulse (s).
    public var turnTau: Double { settings[.turnDecay] / 1000 }
    /// The stop detector's still disc (px): inside = jitter, beyond re-anchors
    /// and restarts the dwell clock. Keeps glides down to ~20 px/s transparent.
    public var stillRadiusPx: Double { settings[.stillRadius] }
    /// Dwell (s) inside the still disc before the stop gate starts opening.
    public var stopDwellMin: Double { settings[.dwell] / 1000 }
    /// Ramp (s) over which the stop gate opens 0 → 1 past `stopDwellMin`.
    public var stopDwellRamp: Double { settings[.ramp] / 1000 }

    /// px of movement below which direction is not re-evaluated (touch jitter
    /// must not fire flips).
    private let turnDeadband: CGFloat = 0.7
    /// Distance constant (px) of the carried-correction shed: with no
    /// qualifying pull, a moving touch's correction loses a 1/e step per
    /// this many px of travel (half the default snap radius — anchors fade
    /// on basin-scale travel).
    public var correctionDecayPx: Double { settings[.release] }
    /// Hard cap on the correction's slew rate (log2/s ≈ 1500 cents/s, inside
    /// natural meend speeds) for each region's correction.
    public var slewCap: Double { settings[.slew] / 1200 }
    /// Ticks arriving within this gap of the last move event don't decay the
    /// speed estimate (the finger is still moving; events are just sparse).
    private let stationaryGap: TimeInterval = 0.04

    public init() {}

    public var isEmpty: Bool { touches.isEmpty }

    /// Refresh the geometry (every down/drag event); the timer reuses it.
    public func setContext(placements: [FretPlacement], snapDistance: CGFloat) {
        self.placements = placements
        self.snapDistance = Double(max(0, snapDistance))
    }

    /// Register a touch at note-on. Every touch is **born stopped**: the gate
    /// starts open, so a tap snaps its landing immediately (slew-capped) and
    /// the first movement shuts it. Correction starts at 0 — no onset step.
    public func begin(touchId: Int, x: CGFloat, y: CGFloat,
                      uncorrectedLog: Double, time: TimeInterval,
                      regionLogs: [FretRegion: Double]? = nil) {
        touches[touchId] = TouchState(x: x, y: y, uncorrectedLog: uncorrectedLog,
                                      speed: speedCeiling, corrections: [:],
                                      regionLogs: regionLogs ?? fallbackRegionLogs(uncorrectedLog),
                                      impulse: 0, dxSign: 0,
                                      anchorX: x, anchorY: y,
                                      stillStart: time - stopDwellMin
                                          - stopDwellRamp,
                                      lastMoveTime: time, lastUpdateTime: time)
    }

    /// Feed a drag event; returns the assisted pitch to glide to.
    public func move(touchId: Int, x: CGFloat, y: CGFloat,
                     uncorrectedLog: Double, time: TimeInterval,
                     regionLogs: [FretRegion: Double]? = nil) -> Output {
        guard var s = touches[touchId] else {
            begin(touchId: touchId, x: x, y: y,
                  uncorrectedLog: uncorrectedLog, time: time, regionLogs: regionLogs)
            return Output(log2Pitch: uncorrectedLog, uncorrectedLog: uncorrectedLog,
                          weights: [:], stopGate: 0)
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
        s.regionLogs = regionLogs ?? fallbackRegionLogs(uncorrectedLog)
        s.lastMoveTime = time
        let out = integrate(&s, dt: dt, time: time)
        touches[touchId] = s
        return out
    }

    /// Settle without a pointer move; optional field updates preserve motion history.
    public func tick(time: TimeInterval,
                     regionLogs: [Int: [FretRegion: Double]] = [:]) -> [(touchId: Int, output: Output)] {
        var outs: [(Int, Output)] = []
        for (id, state) in touches {
            var s = state
            if let logs = regionLogs[id],
               let raw = fretRegionValue(logs, atY: s.y, placements: placements) {
                s.regionLogs = logs
                s.uncorrectedLog = raw
            }
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

    private func fallbackRegionLogs(_ raw: Double) -> [FretRegion: Double] {
        Dictionary(uniqueKeysWithValues: FretRegion.allCases.map { ($0, raw) })
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

        let regionWeights = fretRegionWeights(atY: s.y, placements: placements)
        var weights: [String: Double] = [:]
        for row in FretRegion.allCases {
            guard let raw = s.regionLogs[row] else { continue }
            // Each row owns its candidate and carried offset.
            let cand = radiusPx > 0 ? row.frets(in: placements).filter {
                abs($0.x - s.x) <= radiusPx
            }.min { abs($0.x - s.x) < abs($1.x - s.x) } : nil
            var correction = s.corrections[row] ?? 0
            let receding: Bool = {
                guard let cand, s.dxSign != 0, s.speed > speedFloor,
                      cand.x != s.x else { return false }
                return (cand.x > s.x ? 1 : -1) != s.dxSign
            }()
            if amount == 0 {
                let step = -correction * (1 - exp(-dt / settleTau))
                correction += min(slewCap * dt, max(-slewCap * dt, step))
            } else if let cand, !receding {
                let distance = Double(abs(cand.x - s.x))
                let prox = max(0.0, min(1.0, 2.0 * (1.0 - distance / radiusPx)))
                let rate = (1 - exp(-dt / settleTau)) * gate * prox
                let target = (log2(cand.ratio) - raw) * amount
                let step = (target - correction) * rate
                correction += min(slewCap * dt, max(-slewCap * dt, step))
                let glow = (1 - distance / radiusPx) * (0.3 + 0.7 * gate) * amount
                    * (regionWeights[row] ?? 0)
                if glow > 0 { weights[cand.id] = min(1, (weights[cand.id] ?? 0) + glow) }
            } else if correction != 0 {
                let mv = max(0.0, min(1.0, (s.speed - speedFloor) / speedFloor))
                let rate = (1 - exp(-s.speed * dt / correctionDecayPx)) * mv * mv * (3 - 2 * mv)
                let step = -correction * rate
                correction += min(slewCap * dt, max(-slewCap * dt, step))
            }
            s.corrections[row] = correction
        }
        let correction = fretRegionValue(s.corrections, atY: s.y, placements: placements) ?? 0

        return Output(log2Pitch: s.uncorrectedLog + correction,
                      uncorrectedLog: s.uncorrectedLog,
                      weights: weights, stopGate: w)
    }
}
