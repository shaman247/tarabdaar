import Foundation

/// The COUPLED bridge–body network's body: K modal 2-pole bandpass sections
/// with ONE shared state bank and TWO residue tap vectors — the bridge
/// ADMITTANCE `V = y∞·DCblock(F) + Σ aₖ·Bₖ(F)` (what loads/re-excites the
/// strings) and the RADIATION `rad = c₀·F + Σ cₖ·Bₖ(F)` (what the listener
/// hears; SIGNED cₖ ⇒ real interference antiresonances). Port of
/// `coupled.body_YW` / the numpy per-sample twin in `coupled_tests._TdBody`.
///
/// Sections are normalized bandpasses `Bₖ = n₀(1−z⁻²)/(1−2R·cosθ·z⁻¹+R²z⁻²)`
/// with |Bₖ| = 1 at resonance; modes at/above 0.45·sr are dropped (numpy
/// parity). The y∞ branch carries a one-pole DC blocker (25 Hz,
/// `coupled.DC_BLOCK_HZ`): the combs' DC mode is a delay-line artifact and
/// must never circulate through the bridge.
public struct BodyAdmittance: Sendable {
    struct Sec {
        var a1: Double, a2: Double, n0: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    }
    var secs: [Sec]
    var resA: [Double]
    var resC: [Double]
    let yinf: Double
    let c0: Double
    // y∞-branch DC blocker (coupled.DC_BLOCK_HZ = 25 Hz)
    let hpRho: Double
    let hpG: Double
    var hpY = 0.0
    var hpX1 = 0.0

    public init(modes: [(f: Double, q: Double)], a: [Double], c: [Double],
                yinf: Double, c0: Double, sr: Double) {
        var ss: [Sec] = []
        var aa: [Double] = []
        var cc: [Double] = []
        for (i, m) in modes.enumerated() {
            guard m.f < 0.45 * sr else { continue }
            let R = exp(-Double.pi * m.f / (max(m.q, 0.5) * sr))
            let th = 2.0 * Double.pi * m.f / sr
            // |B(e^{jθ})| normalization, matching coupled.modal_bank_B
            let zr = Cx(cos(th), -sin(th))
            let zr2 = zr * zr
            let den = Cx(1, 0) - Cx(2.0 * R * cos(th), 0) * zr
                + Cx(R * R, 0) * zr2
            let num = Cx(1, 0) - zr2
            let n0 = max((num / den).magnitude, 1e-12)
            ss.append(Sec(a1: 2.0 * R * cos(th), a2: -(R * R), n0: 1.0 / n0))
            aa.append(i < a.count ? a[i] : 0)
            cc.append(i < c.count ? c[i] : 0)
        }
        secs = ss
        resA = aa
        resC = cc
        self.yinf = yinf
        self.c0 = c0
        hpRho = exp(-2.0 * Double.pi * 25.0 / sr)
        hpG = 0.5 * (1.0 + hpRho)
    }

    /// One sample of bridge force in → (bridge velocity V, radiated signal).
    public mutating func process(_ x: Double) -> (v: Double, rad: Double) {
        hpY = hpG * (x - hpX1) + hpRho * hpY
        hpX1 = x
        var v = yinf * hpY
        var rad = c0 * x
        for i in secs.indices {
            let y = secs[i].n0 * (x - secs[i].x2)
                + secs[i].a1 * secs[i].y1 + secs[i].a2 * secs[i].y2
            secs[i].x2 = secs[i].x1
            secs[i].x1 = x
            secs[i].y2 = secs[i].y1
            secs[i].y1 = y
            v += resA[i] * y
            rad += resC[i] * y
        }
        return (v, rad)
    }

    public mutating func reset() {
        for i in secs.indices {
            secs[i].x1 = 0; secs[i].x2 = 0; secs[i].y1 = 0; secs[i].y2 = 0
        }
        hpY = 0; hpX1 = 0
    }

    // MARK: passive wave junction (v57 live port, 2026-07-12)
    // V = y0·F + stateV() with y0 the instantaneous admittance coefficient —
    // the split behind the delay-free solve V = (Vst + y0·F0)/(1 + y0·ΣZ)
    // (C kernel: jy0/jden). process(F) then recomputes the same V from the
    // solved F and owns the state updates (exact by linearity).

    /// Instantaneous coefficient ∂V/∂F (per sample).
    public var y0: Double {
        var v = yinf * hpG
        for i in secs.indices { v += resA[i] * secs[i].n0 }
        return v
    }

    /// The state-only part of the next V (no mutation).
    public func stateV() -> Double {
        var v = yinf * (hpRho * hpY - hpG * hpX1)
        for i in secs.indices {
            v += resA[i] * (secs[i].a1 * secs[i].y1 + secs[i].a2 * secs[i].y2
                            - secs[i].n0 * secs[i].x2)
        }
        return v
    }

    /// Bridge admittance `Y(e^{jω})` from the stored y∞ (DC-blocked) branch +
    /// modal sections — the frequency-domain twin of `process().v` (the .rad
    /// residues are excluded; only the admittance loads the strings). Build-time
    /// only, used by the coupled stability guard.
    /// `Bₖ = n0(1 − z⁻²)/(1 − a1 z⁻¹ − a2 z⁻²)`, `hp = hpG(1 − z⁻¹)/(1 − ρ z⁻¹)`.
    func admittance(_ omega: Double) -> Cx {
        let one = Cx(1, 0)
        let z1 = Cx.expMinusJ(omega)
        let z2 = z1 * z1
        let hpNum: Cx = one - z1
        let hpDen: Cx = one - (z1 * hpRho)
        let hp: Cx = (hpNum * hpG) / hpDen
        var y: Cx = hp * yinf
        for i in secs.indices {
            let num: Cx = (one - z2) * secs[i].n0
            let den: Cx = one - (z1 * secs[i].a1) - (z2 * secs[i].a2)
            y = y + ((num / den) * resA[i])
        }
        return y
    }
}

/// Radiation-only modal bank (the W taps of `BodyAdmittance` without the
/// admittance) — used for the stereo SIDE channel: the panned taraf forces'
/// (L−R) component radiates through the same W as the mono sum, so
/// L = ½(rad + side), R = ½(rad − side) reproduces the offline per-string
/// panning exactly (linearity of W).
public struct WModalBank: Sendable {
    var body: BodyAdmittance
    public init(modes: [(f: Double, q: Double)], c: [Double], c0: Double,
                sr: Double) {
        body = BodyAdmittance(modes: modes, a: [Double](repeating: 0, count: modes.count),
                              c: c, yinf: 0, c0: c0, sr: sr)
    }
    public mutating func process(_ x: Double) -> Double {
        body.process(x).rad
    }
    public mutating func reset() { body.reset() }
}

/// The coupled network's structural configuration — decoded from
/// `params/sarangi_coupled.json` (the artifact written by coupled-calibrate /
/// coupled-fingerprint / diff-export). Absent file / `topology != "coupled"`
/// ⇒ the engine runs the legacy feedforward path unchanged.
public struct CoupledConfig: Sendable {
    public var modes: [(f: Double, q: Double)] = []
    public var resA: [Double] = []
    public var resC: [Double] = []
    public var c0 = 0.15
    public var yinf = 0.08
    public var kappa = 1.0
    public var kappaPlayed = 1.0
    public var loop = 1.0
    public var alpha = 0.6
    public var pGain = 1.0
    public var pFc = 12000.0
    public var playedGain = 0.35
    public var playedT60 = 2.0
    public var playedBright = 0.15
    public var rfir: [Double] = []
    public var rfir48: [Double] = []      // 48 kHz redesign (live engines)
    // PASSIVE WAVE JUNCTION (N_junction "passive", 2026-07-09 physics; live
    // port 2026-07-12): every string loads the bridge with Z_in = Z(1+G)/(1−G)
    // — structurally stable, no κ, no guard. zTaraf/zPlayed are the TWO
    // physical impedance scalars (per-string ratios ∝ fitted rel weights,
    // coupled.junction_Z). junction != "passive" keeps the κ fallback.
    public var junction = ""
    public var zTaraf = 0.0
    public var zPlayed = 0.0
    public var passive: Bool { junction == "passive" && zTaraf > 0 }
    /// Sa/Pa(3/4)/lowSa open tunings (coupled.PLAYED_RATIOS lockstep)
    public static let playedRatios: [Double] = [1.0, 0.75, 0.5]

    /// The radiation FIR for a given engine sample rate.
    public func rfirTaps(sr: Double) -> [Double] {
        if abs(sr - 48000.0) < 1.0, !rfir48.isEmpty { return rfir48 }
        return rfir
    }

    public init() {}

    public init?(json: [String: Any]) {
        guard (json["topology"] as? String) == "coupled" else { return nil }
        func arr(_ k: String) -> [Double]? {
            (json[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        func num(_ k: String, _ d: Double) -> Double {
            (json[k] as? NSNumber)?.doubleValue ?? d
        }
        if let m = json["N_modes"] as? [[Any]] {
            modes = m.compactMap { row in
                guard row.count >= 2,
                      let f = (row[0] as? NSNumber)?.doubleValue,
                      let q = (row[1] as? NSNumber)?.doubleValue
                else { return nil }
                return (f, q)
            }
        }
        resA = arr("N_a") ?? []
        resC = arr("N_c") ?? []
        c0 = num("N_c0", c0)
        yinf = num("N_yinf", yinf)
        kappa = num("N_kappa", kappa)
        kappaPlayed = num("N_kappa_played", kappaPlayed)
        loop = num("N_loop", loop)
        alpha = num("N_alpha", alpha)
        pGain = num("N_pgain", pGain)
        pFc = num("N_pfc", pFc)
        playedGain = num("N_played_gain", playedGain)
        playedT60 = num("N_played_t60", playedT60)
        playedBright = num("N_played_bright", playedBright)
        rfir = arr("N_rfir") ?? []
        rfir48 = arr("N_rfir_48k") ?? []
        junction = (json["N_junction"] as? String) ?? ""
        zTaraf = num("N_Z_taraf", 0.0)
        zPlayed = num("N_Z_played", 0.0)
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        self.init(json: dict)
    }
}
