import Foundation

/// One sympathetic string as a **harmonic comb** (Karplus-Strong feedback comb),
/// the offline model's `blocks.comb_string`. Unlike a 2-pole resonator
/// (a pure sine), a comb rings at its fundamental AND its whole harmonic series —
/// the rich shimmer of a real taraf bank.
///
/// LEGACY form (web == false):
///   y[n] = (1−g)·x[n] + g·y[n−L],   L = round(sr/f0),
///   g = min(0.99985, 10^(−3L/(t60·sr)))      (unity gain at each harmonic)
///
/// WEB form (web == true — port of `blocks._comb_string_web`): fractional-delay
/// feedback comb with an in-loop dispersion allpass and an optional in-loop
/// damping filter:
///   loop = g·z^−L·A_frac(z)·A_disp(z)·F(z),
///   A_frac = (η+z⁻¹)/(1+ηz⁻¹)  (exact tuning; the legacy integer delay
///   quantizes high strings by up to ~±10 cents),
///   A_disp = (c+z⁻¹)/(1+cz⁻¹), c = −inharm  (NEGATIVE → loop delay falls
///   with frequency → partials ring SHARP like a stiff steel wire),
///   F = ((1−s_d)+s_d·z⁻¹)²  (in-loop f² string DAMPING, 2026-07-06: loss ≈ 0
///   at the fundamental growing ~f², so upper partials decay in fractions of
///   a second while the fundamental keeps the string's t60 — sympathetic
///   selectivity by harmonic order. Damping is an INSTRUMENT constant: the
///   per-string tap solves s_d(1−s_d) = 0.25·damp·(110/f0) so per-second decay
///   at an absolute frequency is string-independent. g is compensated by
///   |F(f0)| and capped so the comb's DC mode (a delay-line artifact) never
///   outrings 32 s = lti.T60_CAP.)
/// Expanded difference equation (b = (1−g)(1+ηz⁻¹)(1+cz⁻¹), s = η+c, p = η·c;
/// F taps c0,c1,c2 convolved with (η+z⁻¹)(c+z⁻¹) = [p, s, 1]):
///   y[n] = (1−g)(x + s·x₁ + p·x₂) − s·y₁ − p·y₂
///          + g·(w0·y_L + w1·y_{L+1} + w2·y_{L+2} + w3·y_{L+3} + w4·y_{L+4})
///   w = [p·c0, p·c1+s·c0, p·c2+s·c1+c0, s·c2+c1, c2]  (damp=0 → [p, s, 1, 0, 0])
/// Both forms end in the `bright` one-pole HF roll-off (gut-string purity,
/// fc = 1400 + bright·6000 Hz).
public struct CombString: Sendable {
    private var buf: [Double]           // y history ring (length L or L+5)
    private var idx: Int = 0
    private let g: Double
    private let oneMinusG: Double
    private let lpA: Double             // brightness one-pole coefficient
    private var lpState: Double = 0
    // web-form coefficients/state
    private let web: Bool
    private let s: Double               // η + c
    private let p: Double               // η · c
    private let w0: Double, w1: Double, w2: Double, w3: Double, w4: Double
    private let L: Int
    private var x1: Double = 0
    private var x2: Double = 0

    public init(f0: Double, t60: Double, sr: Double, bright: Double,
                web: Bool = false, inharm: Double = 0, damp: Double = 0) {
        self.web = web
        if web {
            let c = -min(max(inharm, 0.0), 0.6)
            // per-string damping tap (blocks._comb_string_web; DAMP_F_REF=110,
            // q capped just under 1/4 — matches numpy exactly)
            let q = min(0.2499999, 0.25 * min(max(damp, 0.0), 1.0) * 110.0 / f0)
            let sd = 0.5 * (1.0 - (1.0 - 4.0 * q).squareRoot())
            // allpass DC delay comp + the damping filter's 2·s_d samples
            let D = sr / f0 - (1.0 - c) / (1.0 + c) - 2.0 * sd
            let Li = max(2, Int(floor(D - 0.5)))
            let d = D - Double(Li)                    // fractional in [0.5, 1.5)
            let eta = (1.0 - d) / (1.0 + d)
            L = Li
            s = eta + c
            p = eta * c
            let c0 = (1.0 - sd) * (1.0 - sd)
            let c1 = 2.0 * sd * (1.0 - sd)
            let c2 = sd * sd
            w0 = p * c0
            w1 = p * c1 + s * c0
            w2 = p * c2 + s * c1 + c0
            w3 = s * c2 + c1
            w4 = c2
            buf = [Double](repeating: 0, count: Li + 5)
            var gg = min(0.99985, pow(10.0, -3.0 * D / (max(t60, 0.05) * sr)))
            if sd > 0 {
                // keep t60 exact at the fundamental (divide out F's loss),
                // capped so the DC mode never outrings 32 s (lti.T60_CAP,
                // raised 26→30→32 in lockstep 2026-07-06)
                let w0f = 2.0 * Double.pi * f0 / sr
                let fMag = (1.0 - sd) * (1.0 - sd) + sd * sd
                    + 2.0 * sd * (1.0 - sd) * cos(w0f)
                gg = min(0.99985, gg / fMag,
                         pow(10.0, -3.0 * D / (32.0 * sr)))
            }
            g = gg
        } else {
            let Li = max(2, Int((sr / f0).rounded()))
            L = Li
            s = 0; p = 0
            w0 = 0; w1 = 0; w2 = 0; w3 = 0; w4 = 0
            buf = [Double](repeating: 0, count: Li)
            g = min(0.99985, pow(10.0, -3.0 * Double(Li) / (max(t60, 0.05) * sr)))
        }
        oneMinusG = 1 - g
        let fc = min(1400.0 + bright * 6000.0, 0.45 * sr)
        lpA = exp(-2.0 * Double.pi * fc / sr)
    }

    public mutating func process(_ x: Double) -> Double {
        let y: Double
        if web {
            let n = buf.count                        // L + 5
            // ring holds the last n outputs; idx = write position for y[n].
            // y[n−k] lives at (idx − k + n) % n.
            let y1 = buf[(idx + n - 1) % n]
            let y2 = buf[(idx + n - 2) % n]
            let yL0 = buf[(idx + n - L) % n]
            let yL1 = buf[(idx + n - L - 1) % n]
            let yL2 = buf[(idx + n - L - 2) % n]
            let yL3 = buf[(idx + n - L - 3) % n]
            let yL4 = buf[(idx + n - L - 4) % n]
            y = oneMinusG * (x + s * x1 + p * x2)
                - s * y1 - p * y2
                + g * (w0 * yL0 + w1 * yL1 + w2 * yL2 + w3 * yL3 + w4 * yL4)
            buf[idx] = y
            idx = (idx + 1) % n
            x2 = x1
            x1 = x
        } else {
            let yL = buf[idx]                        // y[n−L]
            y = oneMinusG * x + g * yL               // comb output (feeds back)
            buf[idx] = y
            idx = (idx + 1) % buf.count
        }
        lpState = (1 - lpA) * y + lpA * lpState      // brightness one-pole
        return lpState
    }

    public mutating func reset() {
        for i in buf.indices { buf[i] = 0 }
        idx = 0; lpState = 0; x1 = 0; x2 = 0
    }

    // MARK: passive wave junction (v57 live port, 2026-07-12)
    // The pre-LP comb output realizes T̃ = (1−g)/(1−G) with direct
    // feedthrough exactly (1−g) (G carries z^−L, L ≥ 2). Splitting
    // y = (1−g)·x + S with S state-only lets the delay-free bridge solve
    // run before the drive x = α·xv − zdrv·V is known — the same
    // pass-1/pass-2 structure as the C bow kernel's passive branch.
    // The bright one-pole is NOT part of the junction (string_G has no
    // output LP) — passiveCommit bypasses lpState entirely.

    /// Direct feedthrough of the pre-LP comb output: ∂y/∂x = 1−g.
    public var feedthrough: Double { oneMinusG }

    /// PASS 1: the state-only part of the next output (no mutation).
    public func passiveStatePart() -> Double {
        if web {
            let n = buf.count
            let y1 = buf[(idx + n - 1) % n]
            let y2 = buf[(idx + n - 2) % n]
            let yL0 = buf[(idx + n - L) % n]
            let yL1 = buf[(idx + n - L - 1) % n]
            let yL2 = buf[(idx + n - L - 2) % n]
            let yL3 = buf[(idx + n - L - 3) % n]
            let yL4 = buf[(idx + n - L - 4) % n]
            return oneMinusG * (s * x1 + p * x2)
                - s * y1 - p * y2
                + g * (w0 * yL0 + w1 * yL1 + w2 * yL2 + w3 * yL3 + w4 * yL4)
        }
        return g * buf[idx]
    }

    /// PASS 2: commit the sample at the solved drive. Returns the pre-LP
    /// output y = (1−g)·x + S (the junction force term; no bright LP).
    public mutating func passiveCommit(_ x: Double, statePart S: Double) -> Double {
        let y = oneMinusG * x + S
        if web {
            buf[idx] = y
            idx = (idx + 1) % buf.count
            x2 = x1
            x1 = x
        } else {
            buf[idx] = y
            idx = (idx + 1) % buf.count
        }
        return y
    }

    /// The string's exact complex frequency response `T(e^{jω})` at normalized
    /// angular frequency ω (rad/sample) — the z-transform of `process` read
    /// straight off the stored loop coefficients (no re-derivation from params,
    /// so it can't drift from the running filter). Build-time only, used by the
    /// coupled stability guard. `|T| ≤ 1` by construction.
    ///
    /// WEB: `H_y = (1−g)(1 + s z⁻¹ + p z⁻²) / [(1 + s z⁻¹ + p z⁻²)
    ///        − g z⁻ᴸ(w0 + w1 z⁻¹ + w2 z⁻² + w3 z⁻³ + w4 z⁻⁴)]`, then × bright LP.
    /// LEGACY: `H_y = (1−g)/(1 − g z⁻ᴸ)`, then × bright LP.
    func transfer(_ omega: Double) -> Cx {
        let one = Cx(1, 0)
        let z1 = Cx.expMinusJ(omega)
        let z2 = z1 * z1
        let z3 = z2 * z1
        let z4 = z2 * z2
        let lpDen: Cx = one - (z1 * lpA)
        let lp: Cx = Cx(1 - lpA, 0) / lpDen
        let zL = Cx.expMinusJ(omega * Double(L))
        if web {
            let poly: Cx = one + (z1 * s) + (z2 * p)
            var fbPoly: Cx = Cx(w0, 0)
            fbPoly = fbPoly + (z1 * w1)
            fbPoly = fbPoly + (z2 * w2)
            fbPoly = fbPoly + (z3 * w3)
            fbPoly = fbPoly + (z4 * w4)
            let fb: Cx = (zL * fbPoly) * g
            let num: Cx = poly * (1 - g)
            let den: Cx = poly - fb
            return (num / den) * lp
        }
        let num: Cx = Cx(1 - g, 0)
        let den: Cx = one - (zL * g)
        return (num / den) * lp
    }

    // MARK: - Starpad-local display accessors (Harmonics-tab heatmap)

    /// Delay-line length ≈ one period. (The web form's true period also includes
    /// the fractional-delay/allpass part — display-only approximation.)
    public var period: Int { L }

    /// Time-ordered copy (oldest first) of the most recent `period` outputs, for
    /// the one-period harmonic DFT. A rectangular DFT at integer bins is cyclic-
    /// shift invariant, so the legacy form's full ring copies exactly. Display-only.
    public func bufferCopy() -> [Double] {
        let n = buf.count
        var out = [Double](repeating: 0, count: L)
        for j in 0..<L { out[j] = buf[(idx + n - L + j) % n] }
        return out
    }
}
