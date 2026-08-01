import Foundation

/// Bow-physics parameters (`params/sarangi_bow.json` over the
/// `default_bow_params` defaults): friction/control-law scalars, the
/// per-octave pitch correction.
public struct BowParams: Sendable {
    public var num: [String: Double]
    public var pitchKnotsOct: [Double]
    public var pitchCents: [Double]
    /// TONIC-RELATIVE knots (2026-07-18, String instrument): the formula
    /// body scales with the open string, so pull(f/tonic) is
    /// tuning-invariant — when present these take precedence and the
    /// correction is interpolated at log2(f0/tonic). Absent (the sarangi
    /// bow artifact) -> the legacy absolute-220 path.
    public var pitchKnotsRel: [Double]?
    public var pitchCentsRel: [Double]?
    /// Bare-loop absolute component (paired with the rel table: corr =
    /// A(f0) + B(f0/tonic) — the two scaling laws of the pull).
    public var pitchKnotsAbs: [Double]?
    public var pitchCentsAbs: [Double]?
    /// cents-per-press slope on the abs knots (the pull is operating-
    /// point dependent; applied as slope·(press−0.55))
    public var pitchCentsPress: [Double]?

    /// Scalar with the same fallback semantics as python's `bp.get(k, d)` —
    /// the defaults are `default_bow_params`' values, passed at call sites so
    /// the two stay greppably side by side.
    public func v(_ k: String, _ d: Double) -> Double { num[k] ?? d }

    public init(num: [String: Double] = [:], pitchKnotsOct: [Double] = [-1, 0, 1, 2],
                pitchCents: [Double] = [0, 0, 0, 0]) {
        self.num = num
        self.pitchKnotsOct = pitchKnotsOct
        self.pitchCents = pitchCents
    }

    public init?(json: [String: Any]) {
        num = [:]
        pitchKnotsOct = [-1, 0, 1, 2]
        pitchCents = [0, 0, 0, 0]
        for (k, v) in json {
            if let n = v as? NSNumber { num[k] = n.doubleValue }
        }
        func arr(_ k: String) -> [Double]? {
            (json[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        if let kn = arr("pitch_knots_oct"), let ce = arr("pitch_cents"),
           kn.count == ce.count, kn.count >= 2 {
            pitchKnotsOct = kn
            pitchCents = ce
        }
        if let kn = arr("pitch_knots_rel"), let ce = arr("pitch_cents_rel"),
           kn.count == ce.count, kn.count >= 2 {
            pitchKnotsRel = kn
            pitchCentsRel = ce
        }
        if let kn = arr("pitch_knots_abs"), let ce = arr("pitch_cents_abs"),
           kn.count == ce.count, kn.count >= 2 {
            pitchKnotsAbs = kn
            pitchCentsAbs = ce
        }
        if let ps = arr("pitch_cents_press"), ps.count >= 2 {
            pitchCentsPress = ps
        }
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        self.init(json: dict)
    }

    /// Per-octave pitch correction (cents at log2(f0/220) knots) —
    /// `np.interp` semantics (clamped at the knot ends).
    public func pitchCorrection(f0: Double) -> Double {
        let x = log2(max(f0, 1.0) / 220.0)
        if x <= pitchKnotsOct[0] { return pitchCents[0] }
        if x >= pitchKnotsOct[pitchKnotsOct.count - 1] {
            return pitchCents[pitchCents.count - 1]
        }
        var i = 0
        while i + 1 < pitchKnotsOct.count && pitchKnotsOct[i + 1] < x { i += 1 }
        let t = (x - pitchKnotsOct[i])
            / max(pitchKnotsOct[i + 1] - pitchKnotsOct[i], 1e-12)
        return pitchCents[i] + t * (pitchCents[i + 1] - pitchCents[i])
    }
}
