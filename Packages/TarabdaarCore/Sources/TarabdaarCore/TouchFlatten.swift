import Foundation

/// FINGERTIP FLATTEN — the shared law behind the flatten→vibrato ease and
/// the iPad's per-touch radius indicator.
///
/// `UITouch.majorRadius` is not a continuous pressure axis: every finger
/// reads essentially ONE size, and Apple quantises it coarsely, so the
/// only reliable gesture in it is deliberately FLATTENING the fingertip —
/// which moves the reading up by about one size step. This detector turns
/// that into a BINARY per-touch state.
///
/// Per touch:
///
///  * **Baseline** — the MEDIAN of every radius sample in the first
///    `baselineWindowS` (150 ms) after onset. A median, not a mean: the
///    first samples of a landing finger ramp as the contact spreads, and a
///    single outlier must not move the reference.
///  * **Hysteresis** — flattened once `radius ≥ baseline + step`,
///    un-flattened again once `radius ≤ baseline + step/2`; in between the
///    state holds. `step` is `Config.touchFlattenStepPt` (one Apple size
///    step).
///
/// Because the baseline is the touch's OWN onset size, the state is
/// relative: a touch that lands ALREADY flattened reads un-flattened (its
/// flattened size IS its baseline) and only triggers if the player lets
/// the fingertip lift back to normal and flattens it again. That is
/// deliberate — the gesture is "flatten from where you were", so the law
/// never depends on absolute finger size, and a big thumb and a small
/// finger behave identically.
///
/// One law, two independent instances (the `FingerAccelTracker` pattern):
/// the Mac's is the control truth, fed by `LinkIngest.onTouchRadius` and
/// driving `FlattenVibrato`; the iPad's is display-only, highlighting its
/// own per-touch indicator ring.
public struct TouchFlattenDetector {
    /// How long the onset baseline window collects samples.
    public static let baselineWindowS: TimeInterval = 0.15

    /// The rise above baseline that reads as flattened.
    public let stepPt: Double

    private struct Track {
        var bornAt: TimeInterval
        var samples: [Double] = []
        var baseline: Double?
        var flattened = false
        var lastRadius: Double = 0
    }
    private var tracks: [Int: Track] = [:]

    public init(stepPt: Double = Config.touchFlattenStepPt) {
        self.stepPt = max(stepPt, 1e-6)
    }

    /// Start tracking a touch. Its first radius sample seeds the baseline
    /// window; the touch reads un-flattened until the window closes.
    public mutating func begin(_ id: Int, radiusPt: Double,
                               at t: TimeInterval) {
        var tr = Track(bornAt: t)
        tr.lastRadius = radiusPt
        if radiusPt > 0 { tr.samples.append(radiusPt) }
        tracks[id] = tr
    }

    /// Feed one radius sample (points). Returns the touch's flatten state.
    /// An unknown id is begun implicitly, so a producer that only ever
    /// calls `sample` still works.
    @discardableResult
    public mutating func sample(_ id: Int, radiusPt: Double,
                                at t: TimeInterval) -> Bool {
        guard var tr = tracks[id] else {
            begin(id, radiusPt: radiusPt, at: t)
            return false
        }
        tr.lastRadius = radiusPt
        if tr.baseline == nil {
            if radiusPt > 0 { tr.samples.append(radiusPt) }
            if t - tr.bornAt >= Self.baselineWindowS {
                tr.baseline = TouchFlattenDetector.median(tr.samples)
            }
            tracks[id] = tr
            return tr.flattened
        }
        if let b = tr.baseline, b > 0 {
            if tr.flattened {
                if radiusPt <= b + 0.5 * stepPt { tr.flattened = false }
            } else if radiusPt >= b + stepPt {
                tr.flattened = true
            }
        }
        tracks[id] = tr
        return tr.flattened
    }

    /// Close the baseline window on a touch whose radius has not changed
    /// since onset (UIKit only reports a touch that moves). Call it on any
    /// tick; it is a no-op once the baseline is settled.
    public mutating func tick(_ id: Int, at t: TimeInterval) {
        guard var tr = tracks[id], tr.baseline == nil,
              t - tr.bornAt >= Self.baselineWindowS else { return }
        tr.baseline = TouchFlattenDetector.median(tr.samples)
        tracks[id] = tr
    }

    public func isFlattened(_ id: Int) -> Bool {
        tracks[id]?.flattened ?? false
    }

    /// The settled onset baseline in points (nil while the window is open).
    public func baseline(_ id: Int) -> Double? {
        tracks[id]?.baseline
    }

    /// The last radius fed for a touch, points (nil = untracked).
    public func radius(_ id: Int) -> Double? {
        tracks[id]?.lastRadius
    }

    public var activeIds: [Int] { Array(tracks.keys) }

    public mutating func end(_ id: Int) {
        tracks.removeValue(forKey: id)
    }

    public mutating func reset() {
        tracks.removeAll()
    }

    /// Median of a sample list; 0 when empty (an unknown radius).
    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }
}

/// The Mac-side controller: fingertip flatten → per-touch vibrato depth.
///
/// It replaces MANUAL vibrato on a trailing note, where moving the finger
/// would add unwanted energy to the gesture: flatten the fingertip and the
/// note's own vibrato eases in over `Config.flattenVibratoEaseInS`; relax
/// it and the vibrato eases back out over `Config.flattenVibratoEaseOutS`.
/// The depth is PER TOUCH — every other sounding note is untouched.
///
/// It pushes only what it drives: a touch whose depth is 0 and has always
/// been 0 never writes the mapper, so a tilt binding on the vibrato axis
/// keeps working on untouched notes.
public final class FlattenVibrato {
    /// (wire touch id, depth 0…1) — fired on the tick queue, change-gated.
    public var onDepth: ((UInt16, Double) -> Void)?

    private let lock = NSLock()
    private var detector: TouchFlattenDetector
    private var depth: [UInt16: Double] = [:]
    private var pushed: [UInt16: Double] = [:]
    private var down: Set<UInt16> = []
    private var lastTick: TimeInterval?
    private var timer: DispatchSourceTimer?
    private let tickHz: Double
    /// False = no internal timer; the owner (a test) calls `tick` itself.
    private let autoTick: Bool
    private let queue = DispatchQueue(label: "tarabdaar.flattenVibrato")

    public init(stepPt: Double = Config.touchFlattenStepPt,
                tickHz: Double = 30.0, autoTick: Bool = true) {
        detector = TouchFlattenDetector(stepPt: stepPt)
        self.tickHz = max(tickHz, 1.0)
        self.autoTick = autoTick
    }

    deinit { timer?.cancel() }

    /// Note-lifecycle edge (the ingest's `onTouchGate`).
    public func touchGate(_ id: UInt16, _ on: Bool) {
        lock.lock()
        if on {
            down.insert(id)
            depth[id] = 0
            detector.end(Int(id))
        } else {
            down.remove(id)
            detector.end(Int(id))
            // A released note eases out like an un-flattened one; it is
            // dropped once its depth reaches 0 (see `tick`).
        }
        let needTimer = !down.isEmpty || !pushed.isEmpty || !depth.isEmpty
        lock.unlock()
        if needTimer { startTimer() }
    }

    /// Fingertip radius in points (the ingest's `onTouchRadius`).
    public func touchRadius(_ id: UInt16, radiusPt: Double,
                            at now: TimeInterval
                            = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if detector.baseline(Int(id)) == nil,
           detector.radius(Int(id)) == nil {
            detector.begin(Int(id), radiusPt: radiusPt, at: now)
        } else {
            detector.sample(Int(id), radiusPt: radiusPt, at: now)
        }
        lock.unlock()
        startTimer()
    }

    /// Everything released (link drop / panic): eased out immediately.
    public func reset() {
        lock.lock()
        detector.reset()
        down.removeAll()
        depth.removeAll()
        let ids = Array(pushed.keys)
        pushed.removeAll()
        lock.unlock()
        for id in ids { onDepth?(id, 0) }
    }

    /// Current depth for a touch (tests / diagnostics).
    public func depth(for id: UInt16) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return depth[id] ?? 0
    }

    /// One control tick; `dt` seconds. Exposed for tests — the timer calls
    /// it with the measured interval.
    public func tick(dt: Double, now: TimeInterval
                     = ProcessInfo.processInfo.systemUptime) {
        var pushes: [(UInt16, Double)] = []
        lock.lock()
        for id in down { detector.tick(Int(id), at: now) }
        let ids = Set(depth.keys).union(down)
        for id in ids {
            let flat = down.contains(id) && detector.isFlattened(Int(id))
            var d = depth[id] ?? 0
            if flat {
                d = min(1.0, d + dt / max(Config.flattenVibratoEaseInS, 1e-3))
            } else {
                d = max(0.0, d - dt / max(Config.flattenVibratoEaseOutS, 1e-3))
            }
            if d <= 0, !down.contains(id) {
                depth.removeValue(forKey: id)
            } else {
                depth[id] = d
            }
            // Only ever write a touch this controller has actually driven:
            // an untouched note must keep whatever the vibrato axis set.
            let had = pushed[id]
            if had == nil, d <= 0 { continue }
            if let had, abs(had - d) < 1e-4 { continue }
            if d <= 0 {
                pushed.removeValue(forKey: id)
            } else {
                pushed[id] = d
            }
            pushes.append((id, d))
        }
        let idle = down.isEmpty && depth.isEmpty && pushed.isEmpty
        lock.unlock()
        for (id, d) in pushes { onDepth?(id, d) }
        if idle { stopTimer() }
    }

    private func startTimer() {
        guard autoTick else { return }
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / self.tickHz,
                       leeway: .milliseconds(4))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = min(max(now - (self.lastTick ?? now - 1.0 / self.tickHz),
                                 1e-4), 0.25)
                self.lastTick = now
                self.tick(dt: dt, now: now)
            }
            t.resume()
            self.timer = t
        }
    }

    private func stopTimer() {
        queue.async { [weak self] in
            guard let self, let t = self.timer else { return }
            t.cancel()
            self.timer = nil
            self.lastTick = nil
        }
    }
}
