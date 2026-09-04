import Combine
import Foundation
import simd

/// THE GUIDED THREE-SWEEP TILT CALIBRATION, shared by the iPad ARM and
/// the Joy-Con WRIST. One instance = one three-dimensional attitude
/// stream → three −1…+1 control axes (rest = 0, sweep extremes = ±1,
/// the app-wide tilt convention). The Mac holds two: the ARM (the iPad's raw tilt
/// report, `tarabdaar.armCal.v2`) and the WRIST (the Joy-Con's fused
/// attitude, `tarabdaar.wristCal.v1`).
///
/// Capture: a REST phase then three guided sweeps, each starting from
/// the rest pose (ending there is good practice, not enforced).
/// Fit: each sweep's dominant direction by PCA (power iteration)
/// about the sweep's OWN mean; the joint least squares
/// `c = (DᵀD)⁻¹Dᵀ(f − f0)` separates non-perpendicular sweeps; extents
/// measured through the final solve and applied piecewise (asymmetric
/// lo/hi → rest 0, extremes ±1), absorbing first-order nonlinearity.
/// The rest pose is measured SEVEN times (the rest phase + each
/// sweep's first/last window) and merged ROBUSTLY — component-wise
/// median, inliers within `max(0.1, 2 × median distance)`, mean of the
/// inliers = f0 — so a player who can't reproduce the exact rest pose
/// gets outliers rejected, never a redo. A sweep that doesn't cross
/// rest both ways, or two near-identical sweeps (≥95% aligned; the
/// singular-Gram inversion as backstop), clears itself and repeats on
/// the spot with a message naming the offender. The feature vector is
/// EMA-smoothed per frame before the capture, the solve and the panel
/// marker (`Config.smoothAlpha`); messages within `frameGap` update
/// the current frame in place (the wire delivers one axis per message
/// — sampling each one recorded torn, staircase frames).
///
/// Main-thread class (every entry point except `isActive`); the host
/// hops the stream to main before ticking. Publishes for SwiftUI; the
/// host forwards `objectWillChange` if the panel observes the host.
public final class TiltCalibrator: ObservableObject {
    public struct Config {
        /// Short name for log lines ("arm", "wrist").
        public var name: String
        /// The four phase prompts: rest, then the three sweeps.
        public var stepNames: [String]
        /// Short sweep names for feedback ("ARM ↕" …), three.
        public var sweepNames: [String]
        /// Feature-axis labels for the 3D cloud ("t1"/"t2"/"t3").
        public var featureNames: [String]
        /// The "you are here" legend entry ("Arm now").
        public var markerName: String
        /// What to say when the sample count isn't rising.
        public var streamHint: String
        /// UserDefaults key of the persisted model.
        public var key: String
        /// Per-frame EMA constant for the feature vector.
        public var smoothAlpha: Double
        /// ORTHOGONAL MODE (the wrist): TWO sweeps, not three. Sweep 1's
        /// PCA direction IS axis 1, exactly; sweep 2's direction is
        /// orthogonalized against it (its axis-1 component removed) =
        /// axis 2, the best orthogonal fit; axis 3 = axis 1 × axis 2,
        /// inferred, with the mean of the two measured ranges as its
        /// extents. The rows of `m` are an orthonormal frame, so the
        /// solve is a projection — no Gram inverse, no cross-talk
        /// amplification. The joint mode's separation of
        /// non-perpendicular sweeps proved hard to control by hand for
        /// the wrist: any cross-talk in the capture became cross-talk
        /// in play.
        public var orthogonal: Bool
        /// Sweeps in the capture: 3 joint, 2 orthogonal (the third axis
        /// is inferred). `sweepNames` always names all three AXES.
        public var sweepCount: Int { orthogonal ? 2 : 3 }

        public init(name: String, stepNames: [String], sweepNames: [String],
                    featureNames: [String], markerName: String,
                    streamHint: String, key: String, smoothAlpha: Double,
                    orthogonal: Bool = false) {
            self.name = name
            self.stepNames = stepNames
            self.sweepNames = sweepNames
            self.featureNames = featureNames
            self.markerName = markerName
            self.streamHint = streamHint
            self.key = key
            self.smoothAlpha = smoothAlpha
            self.orthogonal = orthogonal
        }

        /// The iPad ARM calibration : feature = the iPad's
        /// raw tilt report (pitch/roll/high-passed yaw at ±90° full
        /// scale). α 0.25: the report is 7-bit-quantized attitude and a
        /// resting arm flickers ±1–2 steps across quantization
        /// boundaries, which the solve's Gram-inverse rows amplify.
        public static let arm = Config(
            name: "arm",
            stepNames: [
                "REST: hold the arm still in playing position",
                "Sweep the ARM up and down — start from rest, end near rest",
                "Sweep the ARM inward and outward — start from rest, end near rest",
                "Rotate the ARM inward and outward — start from rest, end near rest",
            ],
            sweepNames: ["ARM ↕", "ARM ↔", "ARM ⟲"],
            featureNames: ["t1", "t2", "t3"],
            markerName: "Arm now",
            streamHint: "the iPad tilt stream isn't flowing",
            key: "tarabdaar.armCal.v2",
            smoothAlpha: 0.25)

        /// The Joy-Con WRIST calibration : feature = the
        /// Joy-Con's fused attitude (gravity pitch/roll + drift-learned
        /// relative yaw, all at ±90° full scale). The fusion is already
        /// smooth, so a lighter EMA keeps the axes responsive. ORTHOGONAL:
        /// up/down defines axis 1 exactly, in/out is fitted orthogonal to
        /// it, rotation is inferred as their cross product.
        public static let wrist = Config(
            name: "wrist",
            stepNames: [
                "REST: hold the Joy-Con hand still in playing position",
                "Move the WRIST up and down — start from rest, end near rest (this motion defines axis 1 exactly)",
                "Move the WRIST inward and outward — start from rest, end near rest (fitted orthogonal to axis 1; rotation is inferred)",
            ],
            sweepNames: ["WRIST ↕", "WRIST ↔", "WRIST ⟲"],
            featureNames: ["pitch", "roll", "yaw"],
            markerName: "Wrist now",
            streamHint: "the Joy-Con motion stream isn't flowing (Joy-Con 2 over BLE, or a controller with GC motion)",
            key: "tarabdaar.wristCal.v1",
            smoothAlpha: 0.5,
            orthogonal: true)
    }

    /// The fitted model: rest, solve matrix, per-axis extents.
    public struct Model: Codable, Equatable {
        public var f0: [Double]       // rest feature vector (3)
        public var m: [[Double]]      // solve matrix (3×3)
        public var lo: [Double]       // per-axis negative extent (3, < 0)
        public var hi: [Double]       // per-axis positive extent (3, > 0)
    }

    /// Model geometry for the 3D panel: the rest point plus the three
    /// solved movement SEGMENTS — each fitted direction scaled by its
    /// lo/hi extents. Because `m·d = 1` by construction, the extents
    /// are feature-space lengths along each direction, so the segments
    /// are exactly the linear model the live solve applies. Rebuilt at
    /// fit, on load (directions = the columns of `m⁻¹`) and on re-zero.
    public struct Viz {
        public var f0: SIMD3<Double>
        public var axes: [(dir: SIMD3<Double>, lo: Double, hi: Double)]
    }

    public static let dims = 3
    /// Samples a phase must hold before it may advance (rest / sweep).
    public static let restNeed = 20
    public static let sweepNeed = 30
    /// Messages within this gap update the current frame in place.
    public static let frameGap: TimeInterval = 0.004
    /// Rest-window length used to read a sweep's start/end rest pose.
    static let restWindow = 15

    public let config: Config
    private let defaults: UserDefaults

    /// nil = idle; 0 = rest capture; 1…`config.sweepCount` = the sweeps.
    @Published public private(set) var step: Int? = nil
    @Published public private(set) var info = ""
    /// Secondary feedback: the last phase's verdict while capturing,
    /// the separation summary or discard advice afterward.
    @Published public private(set) var detail = ""
    /// Live calibrated axes for the panel (−1…+1 ×3, ~10 Hz).
    @Published public private(set) var axes: [Double] = []
    /// Live 3D sample cloud per phase (rest + three sweeps), decimated
    /// for display, ~20 Hz while samples stream in. Kept after the fit;
    /// cleared when a new capture begins. The fit uses `samples`.
    @Published public private(set) var cloud: [[SIMD3<Double>]] = []
    @Published public private(set) var viz: Viz?

    /// Calibrated axes, change-gated + 1/256-quantized. Main thread.
    public var onAxes: ((Double, Double, Double) -> Void)?

    private var model: Model? {
        didSet {
            lock.lock()
            activeFlag = model != nil || step != nil
            lock.unlock()
        }
    }
    private var samples: [[[Double]]] = []
    private var dirs: [[Double]?] = [nil, nil, nil]
    private var restMean: [Double]?
    private var lastSent: SIMD3<Double>?
    private var lastPublish: TimeInterval = 0
    private var lastCloudPublish: TimeInterval = 0
    private var smooth: SIMD3<Double>?
    private var smoothPrev: SIMD3<Double>?
    private var lastMsgT: TimeInterval = 0
    private let lock = NSLock()
    private var activeFlag = false

    public var isCalibrated: Bool { model != nil }
    public var isCapturing: Bool { step != nil }
    /// True when the calibrator CONSUMES its stream (a model exists or
    /// a capture is running). Readable from any thread.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeFlag
    }
    /// The smoothed feature vector — the panel's "you are here".
    public var livePos: SIMD3<Double>? { smooth }
    public var currentModel: Model? { model }

    public init(config: Config, defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        if let cal = DefaultsStore.load(Model.self, key: config.key, from: defaults),
           cal.f0.count == Self.dims, cal.m.count == Self.dims {
            model = cal
            info = "Calibrated"
            if let inv = Self.invert(cal.m) {
                viz = Viz(
                    f0: SIMD3(cal.f0[0], cal.f0[1], cal.f0[2]),
                    axes: (0..<Self.dims).map { k in
                        (SIMD3(inv[0][k], inv[1][k], inv[2][k]),
                         cal.lo[k], cal.hi[k])
                    })
            }
        }
    }

    // MARK: Stream

    /// One feature-stream tick (main thread): smooth, then append to
    /// the running capture phase, or solve and drive the axes.
    public func tick(_ raw: SIMD3<Double>, at now: TimeInterval) {
        let newFrame = now - lastMsgT >= Self.frameGap
        lastMsgT = now
        if newFrame { smoothPrev = smooth ?? raw }
        let base = smoothPrev ?? raw
        let sm = base + (raw - base) * config.smoothAlpha
        smooth = sm
        if let step {
            let fs = [sm.x, sm.y, sm.z]
            if newFrame || samples[step].isEmpty {
                samples[step].append(fs)
            } else {
                samples[step][samples[step].count - 1] = fs
            }
            let count = samples[step].count
            if count % 15 == 0 {
                let need = step == 0 ? Self.restNeed : Self.sweepNeed
                info = config.stepNames[step]
                    + (count >= need ? "  (\(count) samples ✓)"
                                     : "  (\(count) of \(need) samples)")
            }
            if now - lastCloudPublish > 0.05 {
                lastCloudPublish = now
                publishCloud()
            }
            return
        }
        guard let cal = model else { return }
        let n = Self.dims
        // the solve, allocation-free: it runs per IMU sample
        var q = SIMD3<Double>(repeating: 0)
        for k in 0..<n {
            var c = 0.0
            for i in 0..<n { c += cal.m[k][i] * (sm[i] - cal.f0[i]) }
            let o = c >= 0 ? min(c / cal.hi[k], 1) : -min(c / cal.lo[k], 1)
            q[k] = (o * 256).rounded() / 256
        }
        if q != lastSent {
            lastSent = q
            onAxes?(q.x, q.y, q.z)
        }
        if now - lastPublish > 0.1 {
            lastPublish = now
            axes = [q.x, q.y, q.z]
        }
    }

    /// Snapshot `samples` for the 3D scatter, ≤600 points per phase.
    private func publishCloud() {
        cloud = samples.map { phase in
            let step = max(1, phase.count / 600)
            return phase.enumerated().compactMap { i, s in
                i % step == 0 ? SIMD3(s[0], s[1], s[2]) : nil
            }
        }
    }

    private func refreshActiveFlag() {
        lock.lock()
        activeFlag = model != nil || step != nil
        lock.unlock()
    }

    // MARK: Capture control

    public func begin() {
        samples = Array(repeating: [], count: config.sweepCount + 1)
        dirs = Array(repeating: nil, count: config.sweepCount)
        restMean = nil
        detail = ""
        step = 0
        info = config.stepNames[0]
        publishCloud()
        refreshActiveFlag()
    }

    /// Advance to the next phase; after the last sweep, fit. A phase
    /// that hasn't captured enough samples refuses to advance and says
    /// why; each completed sweep gets an instant verdict
    /// (`evaluateSweep`) so a doomed run is visible before the fit.
    public func advance() {
        guard let step else { return }
        let need = step == 0 ? Self.restNeed : Self.sweepNeed
        guard samples[step].count >= need else {
            detail = "⚠ Can't advance — only \(samples[step].count) of \(need) samples; if the count isn't rising, \(config.streamHint)"
            return
        }
        let n = Self.dims
        if step == 0 {
            var mean = [Double](repeating: 0, count: n)
            for s in samples[0] { for i in 0..<n { mean[i] += s[i] } }
            for i in 0..<n { mean[i] /= Double(samples[0].count) }
            restMean = mean
            detail = "✓ Rest captured (\(samples[0].count) samples)"
        } else if !evaluateSweep(step) {
            // A fatally bad sweep redoes ITSELF immediately.
            samples[step] = []
            info = config.stepNames[step] + "  — REDO"
            publishCloud()
            return
        }
        if step < config.sweepCount {
            self.step = step + 1
            info = config.stepNames[step + 1]
        } else {
            self.step = nil
            fit()
        }
        refreshActiveFlag()
    }

    /// Step BACK one phase and re-capture it — the current phase's
    /// partial samples and the previous phase's samples are cleared,
    /// everything captured before them stands.
    public func redoPrevious() {
        guard let step, step > 0 else { return }
        samples[step] = []
        samples[step - 1] = []
        if step == 1 {
            restMean = nil
        } else {
            dirs[step - 2] = nil
        }
        self.step = step - 1
        info = config.stepNames[step - 1] + "  — redo"
        detail = ""
        publishCloud()
        refreshActiveFlag()
    }

    public func cancel() {
        step = nil
        samples = []
        detail = ""
        info = model != nil ? "Calibrated" : ""
        refreshActiveFlag()
    }

    /// Quick re-zero: the CURRENT (smoothed) pose becomes rest without
    /// re-fitting the directions. No-op while uncalibrated.
    public func recenter() {
        guard var cal = model, let sm = smooth else { return }
        cal.f0 = [sm.x, sm.y, sm.z]
        model = cal
        viz?.f0 = sm
        persist()
    }

    private func persist() {
        if let cal = model { DefaultsStore.save(cal, key: config.key, to: defaults) }
    }

    // MARK: Verdicts + fit

    /// Verdict when a sweep phase ends: dominant direction, both-ways
    /// about its OWN nearest rest reading, alignment against the
    /// sweeps already captured. False = the sweep must be REDONE.
    /// ≥95% alignment fails; 80–95% warns but advances.
    private func evaluateSweep(_ step: Int) -> Bool {
        let idx = step - 1
        let name = config.sweepNames[idx]
        let sweep = samples[step]
        let (startRest, endRest) = Self.restWindowMeans(of: sweep)
        let anchor = restMean ?? startRest
        let startOff = Self.dist(startRest, anchor)
        let endOff = Self.dist(endRest, anchor)
        let local = startOff <= endOff ? startRest : endRest
        if config.orthogonal {
            return evaluateOrthogonalSweep(idx, sweep: sweep, local: local,
                                           startOff: startOff, endOff: endOff)
        }
        let dir = Self.dominantDirection(of: sweep)
        var lo = 0.0, hi = 0.0
        for s in sweep {
            var c = 0.0
            for i in 0..<dir.count { c += dir[i] * (s[i] - local[i]) }
            lo = min(lo, c)
            hi = max(hi, c)
        }
        guard hi > 0.04, -lo > 0.04 else {
            dirs[idx] = nil
            detail = String(
                format: "⚠ %@ was one-sided about its rest (%+.3f / %+.3f, need ±0.04) — redo, sweeping past the rest pose both ways; if rest sits at one end of this motion's range, the motion can't calibrate.",
                name, lo, hi)
            return false
        }
        var worst = 0.0
        var worstIdx = -1
        for j in 0..<idx {
            guard let other = dirs[j] else { continue }
            let cos = Self.alignment(dir, other)
            if cos > worst { worst = cos; worstIdx = j }
        }
        let pct = Int((worst * 100).rounded())
        if worstIdx >= 0, worst >= 0.95 {
            dirs[idx] = nil
            detail = "⚠ \(name) was \(pct)% aligned with \(config.sweepNames[worstIdx]) — near-identical movements can't be separated; redo with a distinct motion (or Cancel if \(config.sweepNames[worstIdx]) was the bad capture)"
            return false
        }
        dirs[idx] = dir
        var msg = "\(name) captured (\(sweep.count) samples)"
        if max(startOff, endOff) > 0.1 {
            msg += String(
                format: ", %@ sat %.3f off rest (fine — using the %@ reading)",
                startOff > endOff ? "start" : "end", max(startOff, endOff),
                startOff > endOff ? "end" : "start")
        }
        var warning = ""
        if worstIdx >= 0 {
            if worst >= 0.8 {
                warning = "\(pct)% aligned with \(config.sweepNames[worstIdx]) — separable, but the axes will cross-talk; consider Cancel and a cleaner run"
            } else {
                msg += ", closest to \(config.sweepNames[worstIdx]) at \(pct)%"
            }
        }
        detail = warning.isEmpty ? "✓ \(msg)" : "⚠ \(msg) — \(warning)"
        return true
    }

    /// Orthogonal-mode verdict. Sweep 1: its PCA direction is axis 1.
    /// Sweep 2: its PCA direction with the axis-1 component removed —
    /// too aligned with axis 1 (under ~25° apart) = redo; otherwise the
    /// verdict reports how far the raw motion sat from orthogonal.
    /// Both-ways is judged along the resulting axis.
    private func evaluateOrthogonalSweep(_ idx: Int, sweep: [[Double]],
                                         local: [Double],
                                         startOff: Double, endOff: Double) -> Bool {
        let name = config.sweepNames[idx]
        let raw = Self.dominantDirection(of: sweep)
        var dir = raw
        var offOrtho = 0.0
        if idx == 1, let d1 = dirs[0] {
            guard let o = Self.orthogonalize(raw, against: d1) else {
                dirs[idx] = nil
                detail = "⚠ \(name) moved almost entirely along \(config.sweepNames[0])'s axis (\(Int((Self.alignment(raw, d1) * 100).rounded()))% aligned) — redo with a motion at right angles to it"
                return false
            }
            dir = o
            offOrtho = Self.alignment(raw, d1)
        }
        var lo = 0.0, hi = 0.0
        for s in sweep {
            var c = 0.0
            for i in 0..<dir.count { c += dir[i] * (s[i] - local[i]) }
            lo = min(lo, c)
            hi = max(hi, c)
        }
        guard hi > 0.04, -lo > 0.04 else {
            dirs[idx] = nil
            detail = String(
                format: "⚠ %@ was one-sided about its rest (%+.3f / %+.3f, need ±0.04) — redo, moving past the rest pose both ways; if rest sits at one end of this motion's range, the motion can't calibrate.",
                name, lo, hi)
            return false
        }
        dirs[idx] = dir
        var msg = String(format: "%@ captured (%d samples), range %+.2f / %+.2f",
                         name, sweep.count, lo, hi)
        if idx == 1 {
            msg += String(format: " · fitted orthogonal to %@ (raw motion %d%% aligned with it — the shared part is dropped)",
                          config.sweepNames[0], Int((offOrtho * 100).rounded()))
        }
        if max(startOff, endOff) > 0.1 {
            msg += String(
                format: ", %@ sat %.3f off rest (fine — using the %@ reading)",
                startOff > endOff ? "start" : "end", max(startOff, endOff),
                startOff > endOff ? "end" : "start")
        }
        detail = (idx == 1 && offOrtho >= 0.8)
            ? "⚠ \(msg) — mostly the same motion as \(config.sweepNames[0]); the orthogonal remainder is small, consider Cancel and a cleaner run"
            : "✓ \(msg)"
        return true
    }

    /// `v` with its `axis` component removed and renormalized; nil when
    /// the remainder is too small to define a direction (|sin| < ~0.42,
    /// i.e. under ~25° from the axis).
    static func orthogonalize(_ v: [Double], against axis: [Double]) -> [Double]? {
        let dot = zip(v, axis).reduce(0) { $0 + $1.0 * $1.1 }
        let r = zip(v, axis).map { $0 - dot * $1 }
        let len = (r.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard len > 0.42 else { return nil }
        return r.map { $0 / len }
    }

    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1],
         a[2] * b[0] - a[0] * b[2],
         a[0] * b[1] - a[1] * b[0]]
    }

    /// Fit the three-axis map from the recorded phases: the joint solve,
    /// or (orthogonal mode) one feature axis per sweep.
    private func fit() {
        let n = Self.dims
        let rest = samples[0]
        guard rest.count >= Self.restNeed else {
            info = "Discarded — rest phase too short"
            refreshActiveFlag()
            return
        }
        var readings: [[Double]] = []
        var mean0 = [Double](repeating: 0, count: n)
        for s in rest { for i in 0..<n { mean0[i] += s[i] } }
        for i in 0..<n { mean0[i] /= Double(rest.count) }
        readings.append(mean0)

        var sweepDirs: [[Double]] = []
        var windows: [(start: [Double], end: [Double])] = []
        let sweeps = config.sweepCount
        for k in 1...sweeps {
            let sweep = samples[k]
            guard sweep.count >= Self.sweepNeed else {
                info = "Discarded — sweep \(k) (\(config.sweepNames[k - 1])) too short (\(sweep.count) of \(Self.sweepNeed) samples)"
                refreshActiveFlag()
                return
            }
            sweepDirs.append(Self.dominantDirection(of: sweep))
            let w = Self.restWindowMeans(of: sweep)
            windows.append(w)
            readings.append(w.start)
            readings.append(w.end)
        }

        var med = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let col = readings.map { $0[i] }.sorted()
            med[i] = col[col.count / 2]
        }
        let dists = readings.map { Self.dist($0, med) }
        let tol = max(0.1, 2 * dists.sorted()[dists.count / 2])
        let inliers = zip(readings, dists).filter { $0.1 <= tol }.map { $0.0 }
        var f0 = [Double](repeating: 0, count: n)
        for e in inliers { for i in 0..<n { f0[i] += e[i] } }
        for i in 0..<n { f0[i] /= Double(max(inliers.count, 1)) }
        if inliers.isEmpty { f0 = med }
        var restSpread = 0.0
        for e in inliers { restSpread = max(restSpread, Self.dist(e, f0)) }
        let rejected = readings.count - max(inliers.count, 1)

        var localRests: [[Double]] = []
        for w in windows {
            let ds = Self.dist(w.start, f0)
            let de = Self.dist(w.end, f0)
            let best = ds <= de ? w.start : w.end
            localRests.append(min(ds, de) <= tol ? best : f0)
        }

        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var separation = ""
        if config.orthogonal {
            // Axis 1 = sweep 1's direction, exactly; axis 2 = sweep 2's
            // direction orthogonalized against it; axis 3 = 1 × 2. An
            // orthonormal frame, so the solve is a projection.
            guard let d2 = Self.orthogonalize(sweepDirs[1], against: sweepDirs[0]) else {
                info = "Discarded — \(config.sweepNames[1]) moved almost entirely along \(config.sweepNames[0])'s axis"
                detail = "The second motion must be at right angles to the first — redo with two clearly different wrist movements"
                refreshActiveFlag()
                return
            }
            sweepDirs[1] = d2
            sweepDirs.append(Self.cross(sweepDirs[0], d2))
            for k in 0..<n { m[k] = sweepDirs[k] }
            separation = String(format: "Axes: %@ exact, %@ fitted orthogonal (raw motion %d%% aligned with it), %@ inferred as their cross product with the mean of the two measured ranges",
                                config.sweepNames[0], config.sweepNames[1],
                                Int((Self.alignment(Self.dominantDirection(of: samples[2]), sweepDirs[0]) * 100).rounded()),
                                config.sweepNames[2])
        } else {
            var worst = 0.0
            var worstA = 0
            var worstB = 1
            for a in 0..<n {
                for b in (a + 1)..<n {
                    let cos = Self.alignment(sweepDirs[a], sweepDirs[b])
                    if cos > worst { worst = cos; worstA = a; worstB = b }
                }
            }
            let worstPct = Int((worst * 100).rounded())
            let worstPair = "sweeps \(worstA + 1) (\(config.sweepNames[worstA])) and \(worstB + 1) (\(config.sweepNames[worstB]))"

            var gram = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            for a in 0..<n {
                for b in 0..<n {
                    gram[a][b] = zip(sweepDirs[a], sweepDirs[b]).reduce(0) { $0 + $1.0 * $1.1 }
                }
            }
            guard worst < 0.95, let gInv = Self.invert(gram) else {
                info = "Discarded — \(worstPair) were nearly identical movements (\(worstPct)% aligned)"
                detail = "Redo with more distinct motions — three clearly different movements (up/down, in/out, rotation)"
                refreshActiveFlag()
                return
            }
            for k in 0..<n {
                for i in 0..<n {
                    for a in 0..<n { m[k][i] += gInv[k][a] * sweepDirs[a][i] }
                }
            }
            separation = "Axis separation: closest sweep pair \(worstPair) at \(worstPct)% aligned (lower separates more cleanly)"
        }

        var lo = [Double](repeating: 0, count: n)
        var hi = [Double](repeating: 0, count: n)
        var flipped = [Bool](repeating: false, count: n)
        for k in 0..<sweeps {
            for s in samples[k + 1] {
                var c = 0.0
                for i in 0..<n { c += m[k][i] * (s[i] - localRests[k][i]) }
                lo[k] = min(lo[k], c)
                hi[k] = max(hi[k], c)
            }
            if -lo[k] > hi[k] {          // dominant side positive
                for i in 0..<n { m[k][i] = -m[k][i] }
                (lo[k], hi[k]) = (-hi[k], -lo[k])
                flipped[k] = true
            }
            guard hi[k] > 0.04, lo[k] < -0.04 else {
                info = "Discarded — sweep \(k + 1) (\(config.sweepNames[k])) didn't move both ways from rest"
                detail = "Each sweep must cross the rest pose in both directions — e.g. \(config.sweepNames[0]) goes above AND below the rest pose"
                refreshActiveFlag()
                return
            }
        }
        if sweeps < n {
            // The inferred axis: direction from the (possibly flipped)
            // measured axes, extents = the mean of theirs.
            let d3 = Self.cross(m[0], m[1])
            m[2] = d3
            sweepDirs[2] = d3
            lo[2] = (lo[0] + lo[1]) / 2
            hi[2] = (hi[0] + hi[1]) / 2
        }

        model = Model(f0: f0, m: m, lo: lo, hi: hi)
        viz = Viz(
            f0: SIMD3(f0[0], f0[1], f0[2]),
            axes: (0..<n).map { k in
                let sign = flipped[k] ? -1.0 : 1.0
                return (SIMD3(sweepDirs[k][0], sweepDirs[k][1], sweepDirs[k][2]) * sign,
                        lo[k], hi[k])
            })
        persist()
        samples = []
        info = String(
            format: "Calibrated · extents %@",
            (0..<n).map { String(format: "%.2f/%.2f", -lo[$0], hi[$0]) }
                .joined(separator: "  "))
        detail = String(
            format: "%@ · rest: %d of %d readings agreed (±%.3f)%@",
            separation, readings.count - rejected, readings.count,
            restSpread,
            rejected > 0 ? ", \(rejected) off-rest reading\(rejected == 1 ? "" : "s") ignored" : "")
        NSLog("Tarabdaar: %@ calibration fitted — %@ · %@", config.name, info, detail)
        refreshActiveFlag()
    }

    // MARK: Math

    /// Mean of a sweep's first and last `restWindow` samples.
    static func restWindowMeans(of samples: [[Double]])
        -> (start: [Double], end: [Double]) {
        let n = samples.first?.count ?? dims
        let m = max(1, min(restWindow, samples.count / 2))
        var a = [Double](repeating: 0, count: n)
        var b = a
        for s in samples.prefix(m) { for i in 0..<n { a[i] += s[i] } }
        for s in samples.suffix(m) { for i in 0..<n { b[i] += s[i] } }
        return (a.map { $0 / Double(m) }, b.map { $0 / Double(m) })
    }

    static func dist(_ a: [Double], _ b: [Double]) -> Double {
        var d = 0.0
        for (x, y) in zip(a, b) { d += (x - y) * (x - y) }
        return d.squareRoot()
    }

    /// |cos| between two direction vectors, defensively normalized.
    static func alignment(_ a: [Double], _ b: [Double]) -> Double {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let la = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        let lb = (b.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard la > 1e-12, lb > 1e-12 else { return 0 }
        return abs(dot / (la * lb))
    }

    /// Principal direction by power iteration on the covariance about
    /// the samples' OWN mean (about rest, a sweep whose average pose
    /// settled slightly off rest had its direction rotated toward the
    /// constant offset — the "+0.000 extents" failure).
    static func dominantDirection(of samples: [[Double]]) -> [Double] {
        let n = samples.first?.count ?? dims
        var mean = [Double](repeating: 0, count: n)
        for s in samples { for i in 0..<n { mean[i] += s[i] } }
        for i in 0..<n { mean[i] /= Double(max(samples.count, 1)) }
        var cov = [Double](repeating: 0, count: n * n)
        for s in samples {
            for i in 0..<n {
                let di = s[i] - mean[i]
                for j in 0..<n { cov[i * n + j] += di * (s[j] - mean[j]) }
            }
        }
        var v = [Double](repeating: 1, count: n)
        for _ in 0..<100 {
            var w = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in 0..<n { w[i] += cov[i * n + j] * v[j] }
            }
            let len = (w.reduce(0) { $0 + $1 * $1 }).squareRoot()
            guard len > 1e-12 else { break }
            v = w.map { $0 / len }
        }
        return v
    }

    /// n×n inverse by Gauss-Jordan with partial pivoting.
    static func invert(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        var m = a
        var inv = (0..<n).map { r in
            (0..<n).map { c in r == c ? 1.0 : 0.0 }
        }
        for col in 0..<n {
            var p = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[p][col]) { p = r }
            guard abs(m[p][col]) > 1e-9 else { return nil }
            m.swapAt(col, p)
            inv.swapAt(col, p)
            let d = m[col][col]
            for j in 0..<n {
                m[col][j] /= d
                inv[col][j] /= d
            }
            for r in 0..<n where r != col {
                let f = m[r][col]
                guard f != 0 else { continue }
                for j in 0..<n {
                    m[r][j] -= f * m[col][j]
                    inv[r][j] -= f * inv[col][j]
                }
            }
        }
        return inv
    }
}
