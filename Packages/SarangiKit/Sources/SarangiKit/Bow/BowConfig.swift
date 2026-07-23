import Foundation

/// String table + tonic feeding the bow kernel's voice expansion — the Swift
/// twin of the offline `tuning` dict (`raga.get`): `strings` are the raw
/// (f, rel_gain, t60, bright) rows BEFORE choir expansion, `stringClass`
/// carries the per-string raga/chrom jawari classification (per-bank jawari
/// depths; the additive-era `bright` flag is NOT a raga marker — choir C's
/// Ab3 lesson). When no class list is available the offline fallback applies
/// (bright choir → "raga", clean → "chrom").
public struct BowTuning: Sendable {
    public var tonic: Double
    public var strings: [(f: Double, gain: Double, t60: Double, bright: Bool)]
    public var stringClass: [String]?
    /// Rows whose t60 is a MEASURED-ABSOLUTE decay (the ring-tuning
    /// artifact): downstream must not scale or cap it (2026-07-16i port —
    /// python coupled.network_strings has honored this since 07-15).
    public var t60AbsIdx: Set<Int> = []

    public init(tonic: Double,
                strings: [(f: Double, gain: Double, t60: Double, bright: Bool)],
                stringClass: [String]? = nil, t60AbsIdx: Set<Int> = []) {
        self.tonic = tonic
        self.strings = strings
        self.stringClass = stringClass
        self.t60AbsIdx = t60AbsIdx
    }

    /// Live construction from the app's resolved bank. Classification: the
    /// canonical `RagaTuning.buildStrings` layout puts the 15 chromatic
    /// choir-A rows first and everything after is raga-tuned (the same rule
    /// `raga.build_strings` encodes); a manually edited bank falls back to
    /// the offline stale-cache rule (bright → raga).
    /// `t60AbsIdx` indexes the FULL `resolved` array (the ring-tuning slot
    /// numbering); it is remapped here onto the enabled-only `strings` rows.
    public init(tonic: Double, resolved: [ResolvedString], canonicalLayout: Bool,
                t60AbsIdx: Set<Int> = []) {
        let active = resolved.filter(\.enabled)
        self.tonic = tonic
        strings = active.map { ($0.freq, $0.gain, $0.t60, $0.bright) }
        var absActive: Set<Int> = []
        var j = 0
        for (i, s) in resolved.enumerated() where s.enabled {
            if t60AbsIdx.contains(i) { absActive.insert(j) }
            j += 1
        }
        self.t60AbsIdx = absActive
        if canonicalLayout {
            stringClass = active.indices.map { $0 < 15 ? "chrom" : "raga" }
        } else {
            stringClass = nil
        }
    }
}

/// Bow-physics parameters (`params/sarangi_bow.json` over the
/// `default_bow_params` defaults): friction/control-law scalars, the
/// per-octave pitch correction and the measured Schelleng wedge.
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
    public var wedge: BowWedge?

    /// Scalar with the same fallback semantics as python's `bp.get(k, d)` —
    /// the defaults are `default_bow_params`' values, passed at call sites so
    /// the two stay greppably side by side.
    public func v(_ k: String, _ d: Double) -> Double { num[k] ?? d }

    public init(num: [String: Double] = [:], pitchKnotsOct: [Double] = [-1, 0, 1, 2],
                pitchCents: [Double] = [0, 0, 0, 0], wedge: BowWedge? = nil) {
        self.num = num
        self.pitchKnotsOct = pitchKnotsOct
        self.pitchCents = pitchCents
        self.wedge = wedge
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
        if let w = json["wedge"] as? [String: Any] {
            wedge = BowWedge(json: w)
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

/// The measured playable wedge (calibrate_wedge): per-(f0, beta, v) locked
/// bow-force range, trilinearly interpolated. `bounds` mirrors
/// `bowstring._wedge_bounds` including its safety margins.
public struct BowWedge: Sendable {
    public var f0: [Double]          // grid axes (f0 in Hz; interp over log2)
    public var beta: [Double]
    public var v: [Double]
    public var fmin: [Double]        // flattened (nf, nb, nv), C order
    public var fmax: [Double]
    let gf: [Double]                 // log2(f0) axis, precomputed — bounds()
                                     // runs per kernel sample on the render
                                     // thread (no allocation allowed there)

    public init?(json: [String: Any]) {
        func axis(_ k: String) -> [Double]? {
            (json[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        func grid(_ k: String) -> [Double]? {
            guard let rows = json[k] as? [Any] else { return nil }
            var out: [Double] = []
            for r in rows {
                guard let cols = r as? [Any] else { return nil }
                for c in cols {
                    guard let vs = c as? [Any] else { return nil }
                    for x in vs {
                        guard let n = x as? NSNumber else { return nil }
                        out.append(n.doubleValue)
                    }
                }
            }
            return out
        }
        guard let f0 = axis("f0"), let beta = axis("beta"), let v = axis("v"),
              let fmin = grid("fmin"), let fmax = grid("fmax"),
              f0.count >= 2, beta.count >= 2, v.count >= 2,
              fmin.count == f0.count * beta.count * v.count,
              fmax.count == fmin.count
        else { return nil }
        self.f0 = f0; self.beta = beta; self.v = v
        self.fmin = fmin; self.fmax = fmax
        gf = f0.map { log2($0) }
    }

    /// (f_lo, f_hi) force bounds at one control point — trilinear interp of
    /// the measured grids over (log2 f0, beta, v) + the offline safety
    /// margins (lo·1.15, max(hi·0.85, lo·1.15·1.05)).
    public func bounds(f0 fHz: Double, beta b: Double, v vb: Double)
        -> (lo: Double, hi: Double) {
        let nb = beta.count, nv = v.count
        func clampIdx(_ axis: [Double], _ x: Double) -> (Int, Double) {
            let xc = min(max(x, axis[0]), axis[axis.count - 1])
            var i = 0
            while i + 1 < axis.count - 1 && axis[i + 1] <= xc { i += 1 }
            let w = (xc - axis[i]) / max(axis[i + 1] - axis[i], 1e-12)
            return (i, w)
        }
        let (ix, wx) = clampIdx(gf, log2(max(fHz, 1.0)))
        let (iy, wy) = clampIdx(beta, b)
        let (iz, wz) = clampIdx(v, vb)
        func tri(_ G: [Double]) -> Double {
            var out = 0.0
            for dx in 0...1 {
                for dy in 0...1 {
                    for dz in 0...1 {
                        let w = (dx == 1 ? wx : 1 - wx)
                            * (dy == 1 ? wy : 1 - wy)
                            * (dz == 1 ? wz : 1 - wz)
                        out += w * G[((ix + dx) * nb + iy + dy) * nv + iz + dz]
                    }
                }
            }
            return out
        }
        let lo = tri(fmin), hi = tri(fmax)
        let lo2 = lo * 1.15
        return (lo2, max(hi * 0.85, lo2 * 1.05))
    }
}

/// Coupled-network + chain parameters as the bow table builder consumes them
/// (the merged `q` dict of `render_bow_pair`: fitted chain params + coupled
/// artifact + `bow_N_*` dev-bridge overrides). Kept as a dict-with-defaults
/// (not typed fields) so key names stay greppable against `src/coupled.py` /
/// `src/bowstring.py` and new fitted keys flow through without a schema bump.
public struct BowNetParams: Sendable {
    public var num: [String: Double]
    public var modes: [[Double]]       // N_modes rows [f_hz, Q]
    public var resA: [Double]          // N_a
    public var resC: [Double]          // N_c
    public var rfir: [Double]          // N_rfir (44.1k design)
    public var rfir48: [Double]        // N_rfir_48k (live engines)
    public var junction: String        // N_junction ("passive" | "")

    public func v(_ k: String, _ d: Double) -> Double { num[k] ?? d }
    public var isPassive: Bool { junction == "passive" }

    public init(num: [String: Double] = [:], modes: [[Double]] = [],
                resA: [Double] = [], resC: [Double] = [],
                rfir: [Double] = [], rfir48: [Double] = [],
                junction: String = "") {
        self.num = num; self.modes = modes; self.resA = resA
        self.resC = resC; self.rfir = rfir; self.rfir48 = rfir48
        self.junction = junction
    }

    /// Merge another params json OVER this one (chain → coupled layering).
    public mutating func merge(json: [String: Any]) {
        for (k, v) in json {
            if let n = v as? NSNumber { num[k] = n.doubleValue }
        }
        func arr(_ k: String) -> [Double]? {
            (json[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        if let m = json["N_modes"] as? [[Any]] {
            modes = m.compactMap { row in
                guard row.count >= 2,
                      let f = (row[0] as? NSNumber)?.doubleValue,
                      let q = (row[1] as? NSNumber)?.doubleValue
                else { return nil }
                return [f, q]
            }
        }
        if let a = arr("N_a") { resA = a }
        if let c = arr("N_c") { resC = c }
        if let r = arr("N_rfir") { rfir = r }
        if let r = arr("N_rfir_48k") { rfir48 = r }
        if let j = json["N_junction"] as? String { junction = j }
    }
}

/// Everything the live bow mode loads from disk: the merged network params +
/// bow physics params — built by `BowSetup.load` from the three artifacts
/// (`sarangi_chain.json`, `sarangi_coupled.json`, `sarangi_bow.json`),
/// mirroring `render_bow_pair`'s `q` construction (chain → coupled →
/// `bow_N_*`/`bow_B_*` dev-bridge overrides + the pgain/taraf gain trims).
public struct BowSetup: Sendable {
    public var q: BowNetParams
    public var bp: BowParams
    /// The bow render's room — snapshotted from the CHAIN params BEFORE the
    /// session q-deltas, exactly like `render_bow_pair` (its reverb reads
    /// the pair/chain `F_*`; the preset's `F_mix 0` is the v57 additive
    /// ear-law and must NOT silence the bow room).
    public var reverbRT60 = 1.2
    public var reverbMix = 0.12
    public var reverbPredelayMs = 20.0

    /// The offline `render_bow_pair` q-override list — bow-artifact keys that
    /// shadow coupled-family params for BOW renders (bake on acceptance).
    static let devBridgeKeys = [
        "N_jaw_raga", "N_jaw_chrom", "N_jaw_played", "B_bright",
        "N_tdir_chrom", "N_tdir_played",
        "N_jaw_loss", "N_jaw_thr", "N_jaw2", "N_jaw2_thr",
        "N_kap_tilt", "N_t60_played_scale", "N_taraf_out",
        "N_taraf_dir", "N_bright_scale", "N_damp_scale",
    ]

    public init(q: BowNetParams, bp: BowParams) {
        self.q = q
        self.bp = bp
    }

    /// `qExtra` = the offline `q_extra` session deltas (the Pilu preset's
    /// chain-param overrides: B_bright, N_jaw_*, F_mix 0, mix_drone 0…) —
    /// applied AFTER the artifacts, BEFORE the bow dev-bridge, exactly like
    /// `render_bow_pair`. Without B_bright from the preset the whole
    /// jawari-bridge choir is silent (the artifacts still carry the legacy
    /// B_bright 0 pin — the round-5 silent-jawari catch).
    public static func load(bowURL: URL, coupledURL: URL, chainURL: URL?,
                            qExtra: [String: Double] = [:]) -> BowSetup? {
        func dict(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return obj as? [String: Any]
        }
        guard let bowJSON = dict(bowURL), let coupledJSON = dict(coupledURL),
              var bp = BowParams(json: bowJSON)
        else { return nil }
        var q = BowNetParams()
        if let chainURL, let chainJSON = dict(chainURL) {
            q.merge(json: chainJSON)
        }
        q.merge(json: coupledJSON)
        for (k, v) in qExtra { q.num[k] = v }
        for k in devBridgeKeys {
            if let v = bp.num["bow_" + k] { q.num[k] = v }
        }
        if let s = bp.num["bow_pgain_scale"] {
            q.num["N_pgain"] = q.v("N_pgain", 1.0) * s
        }
        if let s = bp.num["bow_taraf_gain"] {
            q.num["B_gain"] = q.v("B_gain", 1.0) * s
        }
        // LIVE policy: no pre-roll and no string pre-charge — the offline
        // values model a mid-performance excerpt (a take property); the live
        // instrument starts from silence.
        bp.num["bow_preroll_s"] = 0.0
        bp.num["bow_precharge"] = 0.0
        return BowSetup(q: q, bp: bp)
    }
}
