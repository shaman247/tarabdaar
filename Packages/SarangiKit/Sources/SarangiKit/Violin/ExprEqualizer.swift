import Foundation

/// LIVE port of the offline expression inversion (`sarangi_fit.ExprInverter`):
/// makes the expression axis a LOUDNESS axis.
///
/// The fitted surfaces bake each note's loudness-as-recorded into the
/// per-(note, harmonic) fingerprint — at FIXED expr the voice varies by
/// ~16 dB across the raga (measured 2026-07-06: Bb +10, B +12 dB vs Sa).
/// Offline, the control track's expr is solved per block from the target
/// loudness, so this never shows; live, raw expr passes it straight through
/// (the "some notes ring very loudly" failure). Here: the player's expr is
/// read as a loudness REQUEST on a reference-note curve, then inverted onto
/// the CURRENT note's own loudness-vs-expr curve — same loudness request →
/// same realized loudness on every note.
///
/// Mirrors the Python inverter's conditioning: the loudness curve plateaus
/// and wiggles non-monotonically above ~expr 0.27, so inversion runs on the
/// MONOTONIC cumulative-max envelope (the quietest bowing that reaches the
/// requested loudness). Curves are cached per (midi ¼-tone, press 0.05,
/// pos 0.05) quantized cell.
public final class ExprEqualizer {
    public static let referenceMidi = 63.0     // Eb4 ≈ the E♭-raga tonic

    /// How much per-note loudness compensation the player gets (an EAR
    /// experiment surface, 2026-07-14 — "I'd like to try playing without
    /// them"): `.full` = surface inversion + the measured live_comp table;
    /// `.surface` = surface inversion only (pre-calibration behavior);
    /// `.raw` = no equalization — expr passes straight through and each
    /// note keeps the fitted surfaces' baked loudness (~16 dB spread).
    public enum Mode: String, CaseIterable, Sendable {
        case full, surface, raw
    }

    private let model: ViolinModel
    private let exprGrid: [Double]
    private var cache: [Int64: [Double]] = [:]  // key -> cummax total-dB curve
    private var harmScratch: [Double]
    private var noiseScratch: [Double]

    public init(model: ViolinModel, nExpr: Int = 17) {
        self.model = model
        let ax = model.exprAxis
        let lo = ax.first ?? 0, hi = ax.last ?? 1
        exprGrid = (0..<nExpr).map { lo + (hi - lo) * Double($0) / Double(nExpr - 1) }
        harmScratch = [Double](repeating: 0, count: model.hMax)
        noiseScratch = [Double](repeating: 0, count: model.nBands)
    }

    /// End-to-end per-midi loudness EXCESS (dB) measured through the FULL
    /// live chain (closed-loop calibration, params/live_comp.json — written
    /// by app/tools/calibrate_live_loudness.py). The pure-surface curves
    /// cannot see the symp coupling's note-dependent gain or the chain EQ's
    /// coloration of each note's spectrum; the calibration table folds those
    /// in. Empty = surfaces only.
    private var compMidi: [Double] = []
    private var compDb: [Double] = []
    private var modeLock = os_unfair_lock()
    private var _mode: Mode = .full

    /// Settable from the UI thread while the render thread equalizes
    /// (lock-protected — the codebase's control-state pattern).
    public var mode: Mode {
        get {
            os_unfair_lock_lock(&modeLock)
            defer { os_unfair_lock_unlock(&modeLock) }
            return _mode
        }
        set {
            os_unfair_lock_lock(&modeLock)
            _mode = newValue
            os_unfair_lock_unlock(&modeLock)
        }
    }

    public func setComp(midis: [Double], db: [Double]) {
        compMidi = midis
        compDb = db
    }

    /// The equalized expr for (midi, exprUI, press, pos).
    public func equalize(midi: Double, expr: Double, press: Double, pos: Double) -> Double {
        let m = mode
        if m == .raw { return expr }
        let ref = curve(midi: ExprEqualizer.referenceMidi, press: press, pos: pos)
        let cur = curve(midi: midi, press: press, pos: pos)
        var target = interp(x: expr, xs: exprGrid, ys: ref)
        if m == .full && !compMidi.isEmpty {
            target -= interp(x: midi, xs: compMidi, ys: compDb)
        }
        return invert(loudnessDb: target, curve: cur)
    }

    private func key(_ midi: Double, _ press: Double, _ pos: Double) -> Int64 {
        // press/pos can be NEGATIVE with the extrapolated axes — bias before
        // packing (bit-OR of negative components would collide keys)
        let m = Int64((midi * 4).rounded()) + 2048         // ¼-tone
        let p = Int64((press * 20).rounded()) + 512
        let q = Int64((pos * 20).rounded()) + 512
        return (m * 4096 + p) * 4096 + q
    }

    private func curve(midi: Double, press: Double, pos: Double) -> [Double] {
        let k = key(midi, press, pos)
        if let c = cache[k] { return c }
        let mq = (midi * 4).rounded() / 4
        let pq = (press * 20).rounded() / 20
        let qq = (pos * 20).rounded() / 20
        var tots = [Double](repeating: 0, count: exprGrid.count)
        for (i, e) in exprGrid.enumerated() {
            model.evalSurfaces(midi: mq, expr: e, press: pq, pos: qq,
                               harmOut: &harmScratch, noiseOut: &noiseScratch)
            var sum = 0.0
            for h in harmScratch {
                sum += h.isFinite ? pow(10.0, h / 10.0) : 0.0
            }
            tots[i] = 10.0 * log10(sum + 1e-30)
        }
        // monotonic lower envelope (cumulative max), as the Python inverter
        for i in 1..<tots.count { tots[i] = max(tots[i], tots[i - 1]) }
        cache[k] = tots
        return tots
    }

    private func interp(x: Double, xs: [Double], ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && xs[i + 1] < x { i += 1 }
        let t = (x - xs[i]) / max(xs[i + 1] - xs[i], 1e-12)
        return ys[i] + (ys[i + 1] - ys[i]) * t
    }

    private func invert(loudnessDb L: Double, curve: [Double]) -> Double {
        if L <= curve[0] { return exprGrid[0] }
        if L >= curve[curve.count - 1] { return exprGrid[exprGrid.count - 1] }
        var i = 0
        while i < curve.count - 2 && curve[i + 1] < L { i += 1 }
        let t = (L - curve[i]) / max(curve[i + 1] - curve[i], 1e-12)
        return exprGrid[i] + (exprGrid[i + 1] - exprGrid[i]) * t
    }
}
