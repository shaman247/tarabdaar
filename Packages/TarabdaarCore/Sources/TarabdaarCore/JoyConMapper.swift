import Foundation

/// STICK CALIBRATION. The gate is a circle around an off-centre rest,
/// so per-axis min/max can never send a diagonal to (±1, ±1): the RIM
/// is captured as a radius per angle bin (sweep a full circle) and
/// mapped circle → square at runtime (diagonal rim = (1, 1)). Persisted
/// by the host — ONE calibration is stored, shared by every bearer, so
/// recalibrate after switching Joy-Con generations.
public struct JoyConStickCal: Codable, Equatable {
    /// Rest, raw 12-bit units.
    public var cx, cy: Double
    /// Gate radius per angle bin, raw units.
    public var rim: [Double]

    public init(cx: Double, cy: Double, rim: [Double]) {
        self.cx = cx
        self.cy = cy
        self.rim = rim
    }
}

public enum JoyConStickCalPhase { case idle, rest, range }

/// What one raw stick sample did.
public enum JoyConStickSample: Equatable {
    /// Phase 1 consumed it (the in-grip rest capture).
    case capturingRest
    /// Phase 2 consumed it (the rim sweep) — the host republishes
    /// `calSummary`.
    case capturingRange
    /// Mapped to the unit square.
    case axes(Double, Double)
    /// Uncalibrated and the fallback centre is not established yet.
    case pending
}

public enum JoyConStickCalResult: Equatable {
    case accepted(JoyConStickCal)
    /// Some rim bin was never swept — an empty one divides by ~zero.
    case discarded(missingBins: Int)
    case noDraft
}

/// The gated stick output. `axes` is non-nil only when the change gate
/// opened — a held or centred stick is silent.
public struct JoyConStickOutput: Equatable {
    public var raw: SIMD2<Double>
    public var active: Bool
    public var axes: SIMD2<Double>?
}

/// REPORT → CONTROL. The pure half of the Joy-Con path: button edges,
/// the stick's deadband / calibration / change gate. No frameworks, no
/// device state, no publishing — the host coordinator owns those and
/// asks this type what a report MEANS.
///
/// Button state is tracked PER BEARER, because two bearers can be live
/// at once (a classic Joy-Con's GameController profile beside its raw
/// HID side-channel) and each has its own idea of what is held.
public final class JoyConMapper {

    // MARK: Buttons

    /// The union view the panel chips draw.
    public private(set) var buttonsDown: Set<JoyConControl> = []
    private var snapshots: [JoyConReport.Source: Set<JoyConControl>] = [:]
    private var generations: [JoyConReport.Source: Int] = [:]

    public init() {}

    /// Apply one report's button update and return the edges to deliver,
    /// in press-then-release order.
    public func edges(_ update: JoyConButtonUpdate,
                      from source: JoyConReport.Source,
                      generation: Int = 0) -> [(JoyConControl, Bool)] {
        if generations[source] != generation {
            generations[source] = generation
            snapshots[source] = []
        }
        switch update {
        case .edge(let control, let pressed):
            var held = snapshots[source] ?? []
            if pressed { held.insert(control) } else { held.remove(control) }
            snapshots[source] = held
            apply(control, pressed)
            return [(control, pressed)]
        case .snapshot(let down):
            let held = snapshots[source] ?? []
            var out: [(JoyConControl, Bool)] = []
            for c in down.subtracting(held) { apply(c, true); out.append((c, true)) }
            for c in held.subtracting(down) { apply(c, false); out.append((c, false)) }
            snapshots[source] = down
            return out
        }
    }

    /// A bearer went away: release everything it was holding.
    public func release(source: JoyConReport.Source) -> [(JoyConControl, Bool)] {
        let held = snapshots[source] ?? []
        snapshots[source] = []
        var out: [(JoyConControl, Bool)] = []
        for c in held {
            apply(c, false)
            out.append((c, false))
        }
        return out
    }

    /// Release everything currently SHOWN as down, whichever bearer
    /// delivered it — the HID full-mode handover (GC bindings stand down
    /// and must not leave a press stuck). Bearer snapshots are left
    /// alone; each still owns its own idea of what is held.
    public func releaseAll() -> [(JoyConControl, Bool)] {
        let held = buttonsDown
        var out: [(JoyConControl, Bool)] = []
        for c in held {
            apply(c, false)
            out.append((c, false))
        }
        return out
    }

    /// Drop the held view WITHOUT emitting edges (controller detach —
    /// the panel simply goes blank).
    public func clearButtons(source: JoyConReport.Source? = nil) {
        if let source { snapshots[source] = [] } else { snapshots = [:] }
        buttonsDown = []
    }

    private func apply(_ control: JoyConControl, _ pressed: Bool) {
        if pressed { buttonsDown.insert(control) }
        else { buttonsDown.remove(control) }
    }

    // MARK: Stick — calibration

    /// Per-axis deflection gate: |v| below this pins the axis to exact
    /// centre (the neutral drifts). Both axes under threshold = rest.
    public static let deadzone = 0.1
    public static let calBins = 16
    /// Rim samples closer to rest than this are noise, not the gate.
    public static let calMinRadius = 150.0
    /// 12-bit units of full deflection from centre (typical span; the
    /// output is clamped). Used only by the uncalibrated fallback.
    public static let stickSpan = 1400.0

    public private(set) var calPhase: JoyConStickCalPhase = .idle
    public var stickCal: JoyConStickCal?
    private var calDraft: JoyConStickCal?
    private var calRestAccum: [(Double, Double)] = []
    /// Uncalibrated fallback: rest from the first samples + a fixed span.
    private var stickCenter: (x: Double, y: Double)?
    private var centerAccum: [(Double, Double)] = []

    /// Start the two-phase calibration: rest capture, then the rim sweep
    /// until `finishCalibration`. The stick stops driving axes meanwhile.
    public func beginCalibration() {
        calRestAccum = []
        calDraft = nil
        calPhase = .rest
    }

    public func finishCalibration() -> JoyConStickCalResult {
        defer { calPhase = .idle }
        guard let d = calDraft else { return .noDraft }
        let missing = d.rim.filter { $0 < Self.calMinRadius }.count
        guard missing == 0 else { return .discarded(missingBins: missing) }
        stickCal = d
        return .accepted(d)
    }

    /// Abort any capture in progress (device removal).
    public func cancelCalibration() {
        calPhase = .idle
        calDraft = nil
        calRestAccum = []
        stickCenter = nil
        centerAccum = []
    }

    /// Live summary of the rim sweep, for the panel.
    public var calSummary: String {
        guard let d = calDraft else { return "" }
        let swept = d.rim.filter { $0 >= Self.calMinRadius }.count
        return String(format: "rest (%.0f, %.0f) · rim %d/%d segments swept",
                      d.cx, d.cy, swept, d.rim.count)
    }

    /// Angle-bin position (0…bins) of an offset from rest.
    static func binPos(dx: Double, dy: Double, bins: Int) -> Double {
        let b = Double(bins)
        return (atan2(dy, dx) / (2 * .pi) * b + b).truncatingRemainder(dividingBy: b)
    }

    /// Rest-relative raw offset → the unit square: radius normalized by
    /// the interpolated rim radius at this angle, then scaled so the larger
    /// component reaches 1 at the rim (circle → square).
    public static func calMap(dx: Double, dy: Double,
                              cal: JoyConStickCal) -> (Double, Double) {
        let r = (dx * dx + dy * dy).squareRoot()
        guard r > 1 else { return (0, 0) }
        let pos = binPos(dx: dx, dy: dy, bins: cal.rim.count)
        let i0 = Int(pos) % cal.rim.count
        let i1 = (i0 + 1) % cal.rim.count
        let f = pos - pos.rounded(.down)
        let rimR = cal.rim[i0] * (1 - f) + cal.rim[i1] * f
        let rho = min(r / max(rimR, 1), 1)
        let c = dx / r, s = dy / r
        let m = max(abs(c), abs(s))
        return (rho * c / m, rho * s / m)
    }

    /// The shared raw-stick pipeline — HID full mode and BLE both land
    /// here with 12-bit device-frame values: the calibration state
    /// machine, then the calibrated map into the unit square.
    public func ingestRawStick(_ s0: Double, _ s1: Double) -> JoyConStickSample {
        switch calPhase {
        case .rest:
            // Phase 1: the in-grip rest position.
            calRestAccum.append((s0, s1))
            if calRestAccum.count >= 30 {
                let cx = calRestAccum.map(\.0).reduce(0, +) / Double(calRestAccum.count)
                let cy = calRestAccum.map(\.1).reduce(0, +) / Double(calRestAccum.count)
                calDraft = JoyConStickCal(
                    cx: cx, cy: cy,
                    rim: Array(repeating: 0, count: Self.calBins))
                calPhase = .range
            }
            return .capturingRest
        case .range:
            // Phase 2: the rim sweep — grow each angle bin's radius.
            if var d = calDraft {
                let dx = s0 - d.cx, dy = s1 - d.cy
                let r = (dx * dx + dy * dy).squareRoot()
                if r >= Self.calMinRadius {
                    let idx = Int(Self.binPos(dx: dx, dy: dy,
                                              bins: d.rim.count)) % d.rim.count
                    d.rim[idx] = max(d.rim[idx], r)
                    calDraft = d
                }
            }
            return .capturingRange
        case .idle:
            if let cal = stickCal {
                let (x, y) = Self.calMap(dx: s0 - cal.cx, dy: s1 - cal.cy, cal: cal)
                return .axes(x, y)
            }
            // Uncalibrated fallback: rest from the first samples.
            if stickCenter == nil {
                centerAccum.append((s0, s1))
                if centerAccum.count >= 24 {
                    let cx = centerAccum.map(\.0).reduce(0, +) / Double(centerAccum.count)
                    let cy = centerAccum.map(\.1).reduce(0, +) / Double(centerAccum.count)
                    stickCenter = (cx, cy)
                    centerAccum = []
                }
            }
            guard let c = stickCenter else { return .pending }
            return .axes(min(max((s0 - c.x) / Self.stickSpan, -1), 1),
                         min(max((s1 - c.y) / Self.stickSpan, -1), 1))
        }
    }

    // MARK: Stick — the control axes

    private var lastStickSent: SIMD2<Double>?

    /// Deadzone gate, rescaled for continuity (deadzone → 0, full → ±1).
    public static func gate(_ v: Double) -> Double {
        guard abs(v) >= deadzone else { return 0 }
        return (v - (v < 0 ? -deadzone : deadzone)) / (1 - deadzone)
    }

    /// The stick path → its two axes: gated, quantized (~9 bits),
    /// change-gated.
    public func gateStick(x: Double, y: Double) -> JoyConStickOutput {
        let gx = Self.gate(x)
        let gy = Self.gate(y)
        func q(_ v: Double) -> Double { (v * 256).rounded() / 256 }
        let s = SIMD2(q(gx), q(gy))
        var out = JoyConStickOutput(raw: SIMD2(x, y),
                                    active: gx != 0 || gy != 0,
                                    axes: nil)
        if lastStickSent == s { return out }
        lastStickSent = s
        out.axes = s
        return out
    }

    /// Forget the last sent axes so the next value always sends (device
    /// removal parks the axes at centre).
    public func resetStickSend() { lastStickSent = nil }
}
