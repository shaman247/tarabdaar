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
/// **Then a RATE LIMITER, not a filter.** Apple quantises `majorRadius`
/// hard, so the mapped value arrives as a staircase of jumps. A one-pole
/// would round every step into an exponential nudge and never arrive; the
/// limiter instead moves the output toward the mapped value at a constant
/// `1 / Config.touchSizeRampS` per second (0.5 s for the full 0…1 range),
/// in BOTH directions, so a step becomes a straight half-second ramp and
/// the output lands exactly on the target and stops.
///
/// One law, two independent instances (the `FingerAccelTracker` pattern):
/// the Mac's is the control truth, fed from the wire radius stream in
/// `ControlAxisEvaluator` (following the NEWEST SOUNDING touch, releases
/// falling back to the survivor); the iPad's is display-only, drawing the
/// smoothed value as an arc on its per-touch ring — the data's SOURCE
/// side draws its own readout, no extra wire traffic.
///
/// `radiusPt` nil (or 0 = unknown: a producer with no touchscreen) targets
/// 0, so the axis ramps back to rest when no finger is down. UNIPOLAR
/// like `.strike`: rest is 0, the curve's LEFT end — a binding reads
/// silence there.
public struct TouchSizeTracker {

    /// Raw fingertip radius (points) → the axis's 0…1 target.
    public static func mapped(radiusPt: Double) -> Double {
        let lo = Config.touchSizeLoPt
        let hi = Config.touchSizeHiPt
        guard hi > lo else { return 0 }
        return min(max((radiusPt - lo) / (hi - lo), 0.0), 1.0)
    }

    /// Seconds for the output to traverse the whole 0…1 range.
    public let rampS: Double

    /// The rate-limited output, 0…1.
    public private(set) var value: Double = 0

    private var lastT: TimeInterval?

    public init(rampS: Double = Config.touchSizeRampS) {
        self.rampS = max(rampS, 1e-3)
    }

    /// Feed one control-rate sample. `radiusPt` nil = no sounding touch
    /// (the axis ramps to 0). Returns the updated `value`.
    @discardableResult
    public mutating func sample(radiusPt: Double?,
                                at t: TimeInterval) -> Double {
        let dt = min(max(t - (lastT ?? t), 0.0), 0.25)
        lastT = t
        let target = radiusPt.map { Self.mapped(radiusPt: $0) } ?? 0.0
        let step = dt / rampS
        let d = target - value
        value += abs(d) <= step ? d : (d < 0 ? -step : step)
        return value
    }

    public mutating func reset() {
        value = 0
        lastT = nil
    }
}
