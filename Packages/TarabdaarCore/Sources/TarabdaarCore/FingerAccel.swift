import Foundation

/// FINGER ACCELERATION (2026-08-24) — the shared control-rate law behind
/// the `.fingerAccel` dimension and the iPad's finger-accel readout: the
/// SIGNED second derivative of the playing finger's pitch trajectory,
/// soft-saturated to −1…+1. Positive = the pitch's motion is accelerating
/// upward, negative = downward; a finger at rest or moving at constant
/// rate reads 0 (rest = curve centre, the bipolar tilt convention).
///
/// One law, two independent instances (the Mac's is the control truth —
/// it feeds bindings from the wire pitch stream in `AppController`; the
/// iPad's is display-only, sampled from its own `OutboundPlayState` for
/// the toolbar scope — the strike-scope ownership pattern: the data's
/// SOURCE side draws its own readout, no extra wire traffic).
///
/// Mechanics mirror the kernel's slide tracker (`bow_slide_*`,
/// bow_kernel_poly.c) scaled to control rate: velocity = the pitch's
/// per-sample delta through a ~25 ms SIGNED smoother (signed first, so
/// sensor/frame jitter cancels instead of rectifying), acceleration = the
/// smoothed velocity's delta through a second ~25 ms smoother, output =
/// a/(|a| + ref) with ref 25 000 ¢/s² — the same half-saturation scale as
/// the kernel noise's `bow_slide_acc` default, so the dimension and the
/// slide noise agree about what a "strong" gesture is (a smooth 700 ¢
/// meend over 0.35 s peaks near ±0.53). Feeding the SAME pitch again (or
/// `nil` = no touch) relaxes both stages toward 0, so the value decays at
/// the smoother rate between updates — callers tick it on a timer while
/// idle. A tracked-identity change or a > 2-semitone jump in one sample
/// is a new finger or a snap, never a slide: the chain reseeds without
/// driving.
public struct FingerAccelTracker {
    /// Half-saturation acceleration, ¢/s².
    public static let accelRef = 25_000.0
    /// Velocity / acceleration smoother time constants, seconds.
    public static let tau = 0.025
    /// A per-sample pitch jump beyond this is a snap/steal, not a slide.
    public static let snapSemis = 2.0

    private var trackedId: Int?
    private var lastPitch: Double?
    private var lastT: TimeInterval?
    private var vel = 0.0        // smoothed, ¢/s
    private var acc = 0.0        // smoothed, ¢/s²

    public init() {}

    /// Current −1…+1 output.
    public var value: Double { acc / (abs(acc) + Self.accelRef) }

    /// Feed one control-rate sample. `id`/`pitchSemis` nil = no sounding
    /// touch (both stages relax toward 0). Returns the updated `value`.
    @discardableResult
    public mutating func sample(id: Int?, pitchSemis: Double?,
                                at t: TimeInterval) -> Double {
        let dt = min(max(t - (lastT ?? t), 1e-4), 0.05)
        lastT = t
        let k = 1.0 - exp(-dt / Self.tau)
        guard let id, let p = pitchSemis else {
            trackedId = nil
            lastPitch = nil
            vel += k * (0.0 - vel)
            acc += k * (0.0 - acc)
            return value
        }
        if trackedId != id || lastPitch == nil {
            // fresh finger: reseed, no drive (its motion starts counting
            // from here; the previous finger's envelopes carry over and
            // decay — an audible ring never snaps a bound parameter)
            trackedId = id
            lastPitch = p
            vel += k * (0.0 - vel)
            acc += k * (0.0 - acc)
            return value
        }
        let dp = p - lastPitch!
        lastPitch = p
        if abs(dp) > Self.snapSemis {
            // snap/steal — reseed without driving (the kernel tracker's
            // "a pitch SNAP is not a glide" rule)
            vel += k * (0.0 - vel)
            acc += k * (0.0 - acc)
            return value
        }
        let rawV = dp / dt * 100.0            // ¢/s
        let vPrev = vel
        vel += k * (rawV - vel)
        let rawA = (vel - vPrev) / dt         // ¢/s²
        acc += k * (rawA - acc)
        return value
    }

    public mutating func reset() {
        trackedId = nil
        lastPitch = nil
        lastT = nil
        vel = 0
        acc = 0
    }
}

/// The iPad's DISPLAY-ONLY finger-accel feed: a 120 Hz off-main sampler
/// reading the newest sounding touch from the app-wide
/// `OutboundPlayState` through a `FingerAccelTracker`, kept as a short
/// rolling history for the toolbar scope. Non-published by design — the
/// scope polls at UI rate inside a `TimelineView` (the strike-scope
/// pattern: motion samples must never re-render the toolbar).
public final class FingerAccelSampler {
    public static let window: TimeInterval = 5.0

    private let state: OutboundPlayState
    private let lock = NSLock()
    private var tracker = FingerAccelTracker()
    private var hist: [(t: TimeInterval, v: Double)] = []
    private var timer: DispatchSourceTimer?

    public init(state: OutboundPlayState) {
        self.state = state
        let t = DispatchSource.makeTimerSource(
            queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: 1.0 / 120.0,
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let touch = state.newestTouch()
        lock.lock()
        let v = tracker.sample(id: touch.map { Int($0.id) },
                               pitchSemis: touch?.pitchSemis, at: now)
        hist.append((now, v))
        let cutoff = now - Self.window
        if let first = hist.first, first.t < cutoff {
            hist.removeFirst(hist.firstIndex { $0.t >= cutoff } ?? 0)
        }
        lock.unlock()
    }

    /// Snapshot for the scope (any thread).
    public func history() -> [(t: TimeInterval, v: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return hist
    }

    public var current: Double {
        lock.lock()
        defer { lock.unlock() }
        return hist.last?.v ?? 0
    }
}
