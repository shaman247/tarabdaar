import Foundation

/// The complete marshaled input set of the C bow kernel — the per-voice
/// columns (empty since the linear web was deleted), 5 modal-body arrays and
/// the 66-scalar list, in the exact C-signature order.
public struct BowKernelTables: Sendable {
    public var sr: Double
    public var L: [Int32]
    // per-voice columns (order of the C call): cs cp w0..w4 g lpA wout kap
    // alphaw jw jl jn chg zdrv zi twt
    public var cs: [Double] = [], cp: [Double] = []
    public var w0: [Double] = [], w1: [Double] = [], w2: [Double] = []
    public var w3: [Double] = [], w4: [Double] = []
    public var g: [Double] = [], lpA: [Double] = [], wout: [Double] = []
    public var kap: [Double] = [], alphaw: [Double] = []
    public var jw: [Double] = [], jl: [Double] = [], jn: [Double] = []
    public var chg: [Double] = [], zdrv: [Double] = [], zi: [Double] = []
    public var twt: [Double] = []
    // body modal sections
    public var ba1: [Double] = [], ba2: [Double] = [], bn0: [Double] = []
    public var bA: [Double] = [], bC: [Double] = []
    /// The 52 scalars (yinf, c0, dc, pgain, a_p, bowW, kret, retA, retMode,
    /// rb0, ra1, ra2, kdisp, bowWidth, bowCont, Z, Zt, mu_s, mu_d, v0,
    /// nutA, brA, thLeak, thA, thD, thFloor, bowDisp, jq, jq2, zload,
    /// tdirect, tshape, tmix, nA, nT, nPow, nzHi, nzLo, nDir, nzHiD,
    /// passive, gutG, dispN, nailK, f0Open, gutA2, tdirUni, torsRatio,
    /// torsG, torsC, ageA, ageMs) — C-signature order, same layout the
    /// goldens dump (torsional loop 2026-07-17, contact aging 2026-07-17g).
    public var scalars: [Double] = []
    /// MODAL-JAWARI table block (2026-07-21, gutstring.jt_tables
    /// lockstep) — nil = block off (the kernel is byte-null without a
    /// bow_jt_load call).
    public var jt: JtTables? = nil

    public init(sr: Double, L: [Int32] = []) {
        self.sr = sr
        self.L = L
    }
}

/// Concatenated modal-jawari tables in the C loader's layouts (all
/// dt-dependence baked here; the C only applies tables).
public struct JtTables: Sendable {
    public var J: Int32 = 0
    public var M: [Int32] = []
    public var ca: [Double] = [], cb: [Double] = []
    public var ca4: [Double] = [], cb4: [Double] = []
    public var wd: [Double] = [], phiD: [Double] = []
    public var phiU: [Double] = [], phiF: [Double] = []
    public var b: [Double] = [], G: [Double] = [], G4: [Double] = []
    public var gd: [Double] = [], gd4: [Double] = []
    public var phys: [Double] = [], q0: [Double] = []
    /// persistent worker-pool size for the deferred jt post-pass
    /// (bow_jt_threads; < 2 = the serial bit-exact path; workers are
    /// spawned at engine BUILD, never on the audio thread)
    public var threads: Int32 = 0
    /// async one-block-late live mode (bow_jt_async): the callback
    /// never waits — a dispatcher thread runs the pool and the wash
    /// rides a completed-sample FIFO (flat-fill under overload)
    public var async: Int32 = 0
    /// Per-row fundamentals (Hz), in kernel row order — Swift-side only
    /// (not passed to C). Lets the host map a requested drone pitch to
    /// its nearest jawari-taraf row (`BowEngine.dronePress`).
    public var rowFreqs: [Double] = []
    /// BRIDGE-FORCE RADIATION (2026-09-02; the only radiation since
    /// 2026-09-03), per row: the force → radiated-velocity unit match
    /// gout·π·wj/(mu·L·wd1) that multiplies the kernel's zone
    /// force-density sum (gout = gain × the t60 norm — the level law the
    /// deleted pickup shape used to carry). Load-ABI `radScale`.
    public var rowForceScale: [Double] = []
    /// One-pole tone-control coefficient on the radiated jt sum
    /// (bow_jt_lp, Hz; ≥ 20 kHz ⇒ 0 = bypass, the byte-exact legacy
    /// path). Applied via bow_jt_set_lp — NOT part of the load ABI.
    public var lpA: Double = 0
    /// MELODY FOLLOWER (Tarabdaar 2026-07-25): index of the row that
    /// live-retunes to the played pitch (-1 = none), plus the law
    /// constants the kernel's in-place retune re-applies (the row's
    /// t60 and the builder's `bow_jt_fhf`/`bow_jt_bst`). Armed via
    /// `bow_poly_jt_track_config` — NOT part of the load ABI, so
    /// never arming it is byte-null.
    public var trackRow: Int32 = -1
    public var trackT60: Double = 0
    public var trackFhf: Double = 4000
    public var trackBst: Double = 2.0e-4
    /// TWO BRIDGES (2026-09-02): per row, whether it sits on the
    /// CHROMATIC bridge (`bow_jtc_*`) rather than the raga one
    /// (`bow_jt_*`), plus the per-row contact constants the kernel
    /// applies through `bow_poly_jt_set_row_contact` (alpha / hcB and
    /// the deep-substep threshold 2.5 × the row's own apex) and the
    /// row's apex for the engine's per-bridge evolve map. `hasChromatic`
    /// false = every row is raga = the setter is never called (byte-null)
    /// and the evolve map is the one global lift.
    public var rowChromatic: [Bool] = []
    public var rowApex: [Double] = []
    public var rowAlpha: [Double] = []
    public var rowHcB: [Double] = []
    public var hasChromatic: Bool = false
    /// The raga bridge's apex (`bow_jt_apex` at build) — the evolve
    /// map's reference for raga rows (phys[3] / 2.5).
    public var apexRef: Double = 1.0e-5
    public init() {}
}

public enum BowTables {

    /// Two-pole bridge-hill filter used by the kernel's return path.
    static func brgCoeffs(fB: Double, qB: Double, sr: Double)
        -> (rb0: Double, ra1: Double, ra2: Double) {
        let R = exp(-Double.pi * fB / (max(qB, 0.3) * sr))
        let th = 2.0 * Double.pi * fB / sr
        let ra1 = -2.0 * R * cos(th)
        let ra2 = R * R
        return (1.0 + ra1 + ra2, ra1, ra2)
    }

    /// Raga-lattice membership — gutstring._steel_row lockstep: within
    /// 1% of a just ratio m/n (m,n <= 6) of the tonic.
    public static func jtSteelRow(_ f: Double, tonic: Double) -> Bool {
        for m in 1...6 {
            for n in 1...6 {
                if abs(Double(m) * f / (Double(n) * tonic) - 1.0) < 0.01 {
                    return true
                }
            }
        }
        return false
    }

    /// MODAL-JAWARI tables — gutstring.jt_tables VERBATIM (lockstep:
    /// keep every literal and the arithmetic order identical; the C
    /// converts zone tables to float, so sub-1e-7 double drift between
    /// the twins is invisible). rows = the jawari-class subset.
    /// `trackRowIndex` (Tarabdaar 2026-07-25): marks one row as the melody
    /// FOLLOWER — the kernel live-retunes it to the played pitch. The row
    /// is built like any other (at its nominal `f`, which should sit low —
    /// the mode allocation is fixed at build, and the kernel only ever
    /// TRIMS the active count as the pitch rises); the tables just carry
    /// the row index + the law constants for `bow_poly_jt_track_config`.
    /// THE CHROMATIC BRIDGE'S RESTING VALUES (2026-09-02): what a
    /// chromatic row is built with when the artifact/overrides carry no
    /// `bow_jtc_*` key — by construction the SAME numbers the raga bridge
    /// ships with (the artifact's `bow_jt_*` values and the builder's
    /// legacy fallbacks), so at rest the two bridges are the same jawari
    /// and the split changes nothing but the string set; every knob then
    /// diverges independently. The registry's `bow_jtc_*` defaults MUST
    /// equal these (the DEFAULT = ENGINE-TRUTH contract, pinned by
    /// `TarabSetTests`) — the artifact never carries the keys, so what
    /// the Parameters tab shows is what the engine plays.
    public static let chromaticBridgeDefaults: [String: Double] = [
        "bow_jtc_gain": 0.3, "bow_jtc_drive": 0.03,
        "bow_jtc_apex": 1.0e-5, "bow_jtc_zone": 0.006,
        "bow_jtc_radius": 0.3,
        "bow_jtc_alpha": 1.3, "bow_jtc_hcb": 8.0,
        "bow_jtc_norm": 0.0, "bow_jtc_fhf": 4000.0,
        "bow_jtc_bst": 2.0e-4, "bow_jtc_evolve": 0.5,
    ]

    /// `chromatic` (2026-09-02, index-aligned with `rows`; nil = every row
    /// on the raga bridge, the byte-exact legacy build): rows flagged
    /// true are built with the CHROMATIC bridge's geometry and contact
    /// law (`bow_jtc_*`, resting at `chromaticBridgeDefaults`) — their
    /// own bone profile (apex / zone / radius), radiation tap, level
    /// norm, string damping corner and inharmonicity, and their own
    /// level/drive (baked into the row taps as ratios against the raga
    /// bridge's global `phys` gain/drive, which stay the kernel's
    /// scalars). The per-row contact constants (alpha / hcB / the deep
    /// threshold at 2.5 × the row's apex) ride `rowAlpha`/`rowHcB`/
    /// `rowApex` for `BowEngine` to push (`bow_poly_jt_set_row_contact`).
    public static func buildJawariTables(
        rows: [(f: Double, gain: Double, t60: Double)],
        srk: Double, bp: BowParams,
        trackRowIndex: Int? = nil,
        chromatic: [Bool]? = nil) -> JtTables? {
        // No arming switch (2026-08-02): the modal-jawari block IS the
        // taraf, so it builds whenever there are rows to build. The only
        // "off" is an empty row set (every tarab string disabled).
        guard !rows.isEmpty else { return nil }
        let J = Int(bp.v("bow_jt_J", 40.0) + 0.5)
        // bow_jt_zone (2026-07-22, J8z6): the contact lives in ~6 mm
        // around the apex — a narrowed zone concentrates J on the
        // active region (measured closer-to-converged than J16 at
        // 10 mm). Default 0.010 = the pre-J8z6 tables.
        let zoneWR = bp.v("bow_jt_zone", 0.010)
        let radiusR = bp.v("bow_jt_radius", 0.3)
        // bow_jt_evolve is NOT applied here: the harmonic-evolution axis
        // is a LIVE slewed bone offset in the kernel (equivalent to
        // scaling apex — the parabola shifts uniformly), pushed by
        // `BowEngine.setJtEvolve`. Building it into the profile would
        // double-apply it and turn every tilt frame into a table swap
        // (the bone stepping under a wrapped string = the strum).
        let apexR = bp.v("bow_jt_apex", 1.0e-5)
        let kc = bp.v("bow_jt_kc", 1.0e10)
        let alphaR = bp.v("bow_jt_alpha", 1.3)
        // Tarabdaar tone knobs (2026-07-23; defaults = the legacy hardcoded
        // values, so untouched artifacts build byte-identical tables):
        // hcb = contact hysteresis damping, fhf = HF damping corner of the
        // per-mode t60 law, bst = stiffness inharmonicity coefficient.
        let hcBR = bp.v("bow_jt_hcb", 8.0)
        let gain = bp.v("bow_jt_gain", 1.0)
        let drive = bp.v("bow_jt_drive", 1.0)
        let fmax = 18000.0, fHfR = bp.v("bow_jt_fhf", 4000.0)
        let mcap = Int(bp.v("bow_jt_mcap", 64.0) + 0.5)
        let div = max(1, Int(bp.v("bow_jt_div", 1.0) + 0.5))
        let normR = bp.v("bow_jt_norm", 0.0)
        let bstR = bp.v("bow_jt_bst", 2.0e-4)
        // the chromatic bridge's own values (resting = the raga bridge's
        // shipped numbers, see chromaticBridgeDefaults)
        func cv(_ k: String) -> Double { bp.v(k, chromaticBridgeDefaults[k] ?? 0.0) }
        let hasChrom = chromatic?.contains(true) ?? false
        let zoneWC = cv("bow_jtc_zone"), radiusC = cv("bow_jtc_radius")
        let apexC = cv("bow_jtc_apex"), alphaC = cv("bow_jtc_alpha")
        let hcBC = cv("bow_jtc_hcb"), fHfC = cv("bow_jtc_fhf")
        let normC = cv("bow_jtc_norm"), bstC = cv("bow_jtc_bst")
        // level/drive ride the taps as ratios against the kernel's global
        // (raga) phys scalars — a silenced raga bridge silences the
        // ratio's denominator, so the chromatic set goes with it
        let gainMulC = gain > 1e-12 ? cv("bow_jtc_gain") / gain : 0.0
        let driveMulC = drive > 1e-12 ? cv("bow_jtc_drive") / drive : 0.0
        let rW = 2.0e-4
        let mu = Double.pi * rW * rW * 7850.0
        let dt = Double(div) / srk
        let dt4 = dt / 4.0
        var T = JtTables()
        T.J = Int32(J)
        T.hasChromatic = hasChrom
        T.apexRef = apexR
        for (ri, row) in rows.enumerated() {
            let chrom = chromatic.map { $0.indices.contains(ri) && $0[ri] } ?? false
            let zoneW = chrom ? zoneWC : zoneWR
            let radius = chrom ? radiusC : radiusR
            let apex = chrom ? apexC : apexR
            let alpha = chrom ? alphaC : alphaR
            let fHf = chrom ? fHfC : fHfR
            let norm = chrom ? normC : normR
            T.rowChromatic.append(chrom)
            T.rowApex.append(apex)
            T.rowAlpha.append(alpha)
            T.rowHcB.append(chrom ? hcBC : hcBR)
            let f0s = row.f
            T.rowFreqs.append(f0s)
            let L = min(0.30, max(0.08, 0.25 * 296.0 / f0s))
            let fx = min(fmax, 0.42 * srk / Double(div))
            let M = max(16, min(mcap, Int(fx / f0s)))
            let bst = chrom ? bstC : bstR
            var w0 = [Double](repeating: 0, count: M)
            var wd = [Double](repeating: 0, count: M)
            for k in 0..<M {
                let kk = Double(k + 1)
                w0[k] = 2.0 * Double.pi * f0s * kk
                    * (1.0 + bst * kk * kk).squareRoot()
                let fk = w0[k] / (2.0 * Double.pi)
                let t60k = 1.0 / (1.0 / row.t60
                    + (fk / fHf) * (fk / fHf) * (1.0 / row.t60))
                let sg = 6.91 / t60k
                wd[k] = max(w0[k] * w0[k] - sg * sg, 1e-6).squareRoot()
                T.wd.append(wd[k])
                T.ca.append(exp(-sg * dt) * cos(wd[k] * dt))
                T.cb.append(exp(-sg * dt) * sin(wd[k] * dt))
                T.ca4.append(exp(-sg * dt4) * cos(wd[k] * dt4))
                T.cb4.append(exp(-sg * dt4) * sin(wd[k] * dt4))
            }
            var xz = [Double](repeating: 0, count: J)
            let x0 = L - zoneW, x1 = L - 0.0008
            for j in 0..<J {
                xz[j] = x0 + Double(j) * (x1 - x0) / Double(J - 1)
            }
            let wj = xz[1] - xz[0]
            var phi = [Double](repeating: 0, count: M * J)
            let amp2 = (2.0 / L).squareRoot()
            for k in 0..<M {
                for j in 0..<J {
                    phi[k * J + j] = amp2
                        * sin(Double(k + 1) * Double.pi * xz[j] / L)
                }
            }
            let gscale = (dt * dt / 2.0) * wj / mu
            var Gm = [Double](repeating: 0, count: J * J)
            for a in 0..<J {
                for b2 in 0..<J {
                    var s = 0.0
                    for k in 0..<M { s += phi[k * J + a] * phi[k * J + b2] }
                    Gm[a * J + b2] = gscale * s
                }
            }
            T.G.append(contentsOf: Gm)
            T.G4.append(contentsOf: Gm.map { $0 / 16.0 })
            for j in 0..<J {
                T.gd.append(Gm[j * J + j])
                T.gd4.append(Gm[j * J + j] / 16.0)
            }
            let xApex = L - 0.0015
            var bprof = [Double](repeating: 0, count: J)
            for j in 0..<J {
                let d = xz[j] - xApex
                bprof[j] = apex - d * d / (2.0 * radius)
            }
            T.b.append(contentsOf: bprof)
            // The DRIVE tap: the played string's bridge force enters each
            // row at the fitted 0.90 L (|sin(k·π·0.9)| per mode). Roadmap
            // item 2 (docs/sarangi.md) is to drive from the termination.
            let xD = 0.90 * L
            // t60-response normalization (python jt_tables mirror)
            var gout = row.gain * pow(5.0 / max(row.t60, 0.5), norm)
            var gdrv = row.gain
            // the chromatic bridge's own level/drive (raga rows: the
            // exact legacy arithmetic — no multiply)
            if chrom { gout *= gainMulC; gdrv *= driveMulC }
            for k in 0..<M {
                let pd = amp2 * sin(Double(k + 1) * Double.pi * xD / L)
                T.phiD.append(gdrv * pd / mu)
            }
            T.phiU.append(contentsOf: phi)
            T.phiF.append(contentsOf: phi.map { $0 * wj / mu })
            // BRIDGE-FORCE RADIATION unit match (2026-09-02, baked
            // 2026-09-03 — the 0.90 L velocity pickup and `bow_jt_tap`
            // are gone): with T = mu·(L·wd1/π)² the termination force
            // T·∂u/∂x of a unit mode-1 ring maps to the old pickup's
            // velocity amplitude through gout·π/(mu·L·wd1) — so the
            // fitted level law carries over and every mode radiates
            // flat in those units; × wj because the kernel sums force
            // DENSITIES over the zone.
            T.rowForceScale.append(gout * Double.pi * wj / (mu * L * wd[0]))
            // static wrap q0 (fixed-point, 300 iterations — the python
            // builder verbatim)
            var q0 = [Double](repeating: 0, count: M)
            for _ in 0..<300 {
                var u = [Double](repeating: 0, count: J)
                for k in 0..<M {
                    let qk = q0[k]
                    for j in 0..<J { u[j] += phi[k * J + j] * qk }
                }
                var fst = [Double](repeating: 0, count: J)
                for j in 0..<J {
                    let eta = bprof[j] - u[j]
                    fst[j] = eta > 0.0 ? kc * pow(eta, alpha) : 0.0
                }
                for k in 0..<M {
                    var s = 0.0
                    for j in 0..<J { s += phi[k * J + j] * fst[j] * wj }
                    let qn = s / mu / (w0[k] * w0[k])
                    q0[k] = q0[k] + 0.5 * (qn - q0[k])
                }
            }
            T.q0.append(contentsOf: q0)
            T.M.append(Int32(M))
        }
        T.phys = [kc, alphaR, hcBR, 2.5 * apexR, gain, drive, Double(div)]
        T.threads = Int32(bp.v("bow_jt_threads", 0.0).rounded())
        T.async = bp.v("bow_jt_async", 0.0) > 0.5 ? 1 : 0
        // Tarabdaar jt tone LP (2026-07-23): one-pole on the radiated jt sum,
        // at the KERNEL sample rate (the hold stream is written per kernel
        // sample). ≥ 20 kHz = bypass (coefficient 0 → the kernel skips the
        // filter entirely — bit-exact legacy output).
        let lpHz = bp.v("bow_jt_lp", 20000.0)
        T.lpA = lpHz < 19999.0
            ? 1.0 - exp(-2.0 * Double.pi * lpHz / srk) : 0.0
        if let ti = trackRowIndex, rows.indices.contains(ti) {
            T.trackRow = Int32(ti)
            T.trackT60 = rows[ti].t60
            T.trackFhf = bp.v("bow_jt_fhf", 4000.0)
            T.trackBst = bp.v("bow_jt_bst", 2.0e-4)
        }
        return T
    }

    /// GENERIC PURE-PHYSICS BOWED STRING (2026-07-16): the friction
    /// waveguide + a FORMULA MODAL BODY (2026-07-16b, the "synthy" fix) —
    /// K analytic modes: air resonance at bow_body_air_ratio × the open
    /// string, wood plate modes above with constant-per-Hz density +
    /// golden-ratio jitter, POSITIVE admittance residues (passivity =
    /// stability), SIGNED radiation residues (same-sign sums honk). Bridge
    /// mobility is ON (yinf + loop-cap-projected kret; the kernel
    /// force-gates the return). The Swift twin of `gutstring.formula_body`
    /// + `_string_scalars` — keep the arithmetic in LOCKSTEP (decimal
    /// literals; both sides assemble the same scalars, tdirUni included,
    /// since the resync). `tonic` = f0Open AND the body scale.
    ///
    /// The sympathetic strings are NOT built here — see
    /// `buildJawariTables`.
    // ----------------------------------------------------------------- //
    // string-loop law (blocks.web_loop_coeffs — the ONE loop-coefficient
    // law). Deleted 2026-07-24 with the radiating web; RESTORED verbatim
    // 2026-08-01 for the bridge-coupling web below.
    // ----------------------------------------------------------------- //
    static let dampFRef = 110.0            // blocks.DAMP_F_REF (lockstep)

    /// (L, eta, c, s, g, D) of the web string loop at the KERNEL rate.
    static func webLoopCoeffs(f0: Double, t60: Double, sr: Double,
                              inharm: Double, damp: Double)
        -> (L: Int, eta: Double, c: Double, s: Double, g: Double, D: Double) {
        let c = -min(max(inharm, 0.0), 0.6)
        let q = min(0.2499999, 0.25 * min(max(damp, 0.0), 1.0) * dampFRef / f0)
        let s = 0.5 * (1.0 - (1.0 - 4.0 * q).squareRoot())
        let D = sr / f0 - (1.0 - c) / (1.0 + c) - 2.0 * s
        let L = max(2, Int(floor(D - 0.5)))
        let d = D - Double(L)
        let eta = (1.0 - d) / (1.0 + d)
        var g = min(0.99985, pow(10.0, -3.0 * D / (max(t60, 0.05) * sr)))
        if s > 0.0 {
            let w0 = 2.0 * Double.pi * f0 / sr
            let fMag = (1.0 - s) * (1.0 - s) + s * s
                + 2.0 * s * (1.0 - s) * cos(w0)
            g = min(0.99985, min(g / fMag, pow(10.0, -3.0 * D / (32.0 * sr))))
        }
        return (L, eta, c, s, g, D)
    }

    public static func buildOpenString(sr: Double, tonic: Double,
                                       bp: BowParams,
                                       taraf: [(f: Double, gain: Double,
                                                t60: Double)] = [])
        -> BowKernelTables {
        // NO RADIATING WEB VOICES (2026-07-24, the taraf simplification).
        // This builder used to add two families of linear comb strings on
        // the passive wave junction — the FORMULA TARAF (`bow_taraf_*`: the
        // sympathetic steel web, polarization doublets, flat-bridge buzz)
        // and the OPEN MAIN GUT pair (`bow_open_*`) — and the kernel
        // radiated their free ring through a direct tap. Both stay gone AS
        // VOICES: the MODAL-JAWARI block (`bow_jt_*`,
        // `buildJawariTables`) is the instrument's whole RADIATED
        // sympathetic response, modelling the string–bone contact rather
        // than approximating it with a comb + buzz term, and the old
        // `bow_taraf_*` / `bow_open_*` keys are permanently inert.
        var t = BowKernelTables(sr: sr)
        // ---- TARAF BRIDGE-COUPLING web (2026-08-01, the coherence rev's
        // two-way fix). Each enabled tarab row gets ONE linear comb string
        // back on the PASSIVE wave junction — the deleted formula taraf's
        // machinery (`webLoopCoeffs`, verbatim) stripped to the coupling
        // physics: NO buzz terms (jw/jl/jn 0 — the jt block models the
        // bone contact properly), NO direct radiation tap (twt/wout 0 —
        // the only output path is the junction itself, so what a row
        // returns radiates through the BODY with the voice), NO
        // polarization doublets (detune doubling is rejected — one comb
        // per row, exactly the tarab pool). This adds the real TWO-WAY
        // mechanism the one-way jt drive cannot express: the bridge sees
        // the taraf as a load — a note at a kin pitch drains into the row
        // (sympathetic absorption raises the played string's decay), the
        // row stores the energy and returns it through the junction (the
        // bloom), and the exchange is passive by construction (g < 1,
        // zi > 0 — the exact delay-free junction solve that shipped
        // through 2026-07-24). One physical string, two computational
        // devices: the comb carries its bridge load, the jt row its
        // buzz + radiated ring. `bow_cpl_z` 0 (the default) builds
        // nothing — nv 0, passive 0, byte-null, every parity fixture
        // untouched. Coupling defaults are the artifact's FITTED web
        // values (bow_taraf_damp 0.019 / bright 0.80 / inharm 0.1); the
        // fitted Z was 0.014116 — the audition reference for the knob.
        let zC = bp.v("bow_cpl_z", 0.0)
        let cplRows = taraf.filter { $0.gain > 1e-9 }
        if !cplRows.isEmpty, zC > 1e-9 {
            let gMean = cplRows.map(\.gain).reduce(0, +)
                / Double(cplRows.count)
            let t60s = bp.v("bow_cpl_t60", 1.0)
            let inh = bp.v("bow_cpl_inharm", 0.1)
            let dmp = bp.v("bow_cpl_damp", 0.019)
            let fcC = min(1400.0 + bp.v("bow_cpl_bright", 0.8) * 6000.0,
                          0.45 * sr)
            let lpAC = exp(-2.0 * Double.pi * fcC / sr)
            for r in cplRows {
                let t60 = min(max(r.t60, 0.05) * t60s, 8.0)
                let (L, eta, c, sD, g, _) = webLoopCoeffs(
                    f0: r.f, t60: t60, sr: sr, inharm: inh, damp: dmp)
                let c0w = (1.0 - sD) * (1.0 - sD)
                let c1w = 2.0 * sD * (1.0 - sD)
                let c2w = sD * sD
                let p = eta * c
                let ssum = eta + c
                t.L.append(Int32(L))
                t.cs.append(ssum)
                t.cp.append(p)
                t.w0.append(p * c0w)
                t.w1.append(p * c1w + ssum * c0w)
                t.w2.append(p * c2w + ssum * c1w + c0w)
                t.w3.append(ssum * c2w + c1w)
                t.w4.append(c2w)
                t.g.append(g)
                t.lpA.append(lpAC)
                t.wout.append(0.0)         // no direct radiation tap
                t.kap.append(0.0)          // passive junction: no κ drive
                t.alphaw.append(0.0)       // no played string in the web
                let zi = zC * (r.gain / max(gMean, 1e-9))
                t.zi.append(zi)
                t.zdrv.append(2.0 * zi / (1.0 - g))
                t.jw.append(0.0)           // buzz stays in the jt block
                t.jl.append(0.0)
                t.jn.append(0.0)
                t.twt.append(0.0)          // tap weight: silent as a source
                t.chg.append(0.0)          // cold start
            }
        }
        let Z = bp.v("bow_Z", 1.0)
        let dc = exp(-2.0 * Double.pi * 25.0 / sr)     // coupled.DC_BLOCK_HZ
        let GOLD = 0.6180339887498949                  // 1/φ jitter sequence
        let SIGNQ = 0.7548776662466927                 // plastic-number signs
        let K = Int(bp.v("bow_body_modes", 0.0).rounded())
        if K > 0 {
            let fAir = bp.v("bow_body_air_ratio", 1.4) * tonic
                * bp.v("bow_body_scale", 1.0)
            let spacing = bp.v("bow_body_spacing", 0.55)
            let jitter = bp.v("bow_body_jitter", 0.35)
            let q0 = bp.v("bow_body_q", 25.0)
            let y0 = bp.v("bow_body_y", 0.35)
            let r0 = bp.v("bow_body_rad", 1.0)
            for k in 0..<K {
                let f: Double, qq: Double
                if k == 0 {
                    f = fAir
                    qq = bp.v("bow_body_q_air", 12.0)
                } else {
                    let u = (Double(k) * GOLD)
                        .truncatingRemainder(dividingBy: 1.0)
                    f = fAir * (1.75 + spacing * Double(k - 1)
                                + jitter * (u - 0.5))
                    qq = q0 * (0.7 + 0.6 * u)
                }
                if f >= 0.45 * sr { continue }
                let R = exp(-Double.pi * f / (max(qq, 0.5) * sr))
                let th = 2.0 * Double.pi * f / sr
                let zr = Cx(cos(th), -sin(th))
                let zr2 = zr * zr
                let den = Cx(1, 0) - Cx(2.0 * R * cos(th), 0) * zr
                    + Cx(R * R, 0) * zr2
                let n0 = ((Cx(1, 0) - zr2) / den).magnitude
                t.ba1.append(2.0 * R * cos(th))
                t.ba2.append(-(R * R))
                t.bn0.append(1.0 / max(n0, 1e-12))
                t.bA.append(y0 * (0.5 + (Double(k + 1) * GOLD)
                        .truncatingRemainder(dividingBy: 1.0)))
                let sgn: Double = (Double(k + 1) * SIGNQ)
                    .truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1.0 : -1.0
                t.bC.append(r0 * (0.5 + (Double(k + 2) * GOLD)
                        .truncatingRemainder(dividingBy: 1.0)) * sgn)
            }
            // DIFFUSE TAIL (2026-07-16h): the Schroeder-region mode forest
            // above the signature modes — linear spacing + golden jitter,
            // low Q, √n-normalized SIGNED residues (gutstring.formula_body
            // lockstep; the presence-deficit fix)
            let nt = Int(bp.v("bow_body_tail_n", 0.0).rounded())
            if nt > 0 {
                let tLo = bp.v("bow_body_tail_f0", 700.0)
                let tHi = bp.v("bow_body_tail_f1", 5500.0)
                let tQ = bp.v("bow_body_tail_q", 18.0)
                let tY = bp.v("bow_body_tail_y", 0.3)
                let tR = bp.v("bow_body_tail_rad", 1.0)
                let rn = 1.0 / Double(nt).squareRoot()
                for j in 0..<nt {
                    let u = (Double(j) * GOLD)
                        .truncatingRemainder(dividingBy: 1.0)
                    let f = tLo + (tHi - tLo)
                        * (Double(j) + 0.5 + 0.8 * (u - 0.5)) / Double(nt)
                    if f >= 0.45 * sr { continue }
                    let qq = tQ * (0.7 + 0.6 * u)
                    let R = exp(-Double.pi * f / (max(qq, 0.5) * sr))
                    let th = 2.0 * Double.pi * f / sr
                    let zr = Cx(cos(th), -sin(th))
                    let zr2 = zr * zr
                    let den = Cx(1, 0) - Cx(2.0 * R * cos(th), 0) * zr
                        + Cx(R * R, 0) * zr2
                    let n0 = ((Cx(1, 0) - zr2) / den).magnitude
                    t.ba1.append(2.0 * R * cos(th))
                    t.ba2.append(-(R * R))
                    t.bn0.append(1.0 / max(n0, 1e-12))
                    t.bA.append(tY * rn * (0.5 + (Double(j + 1) * GOLD)
                            .truncatingRemainder(dividingBy: 1.0)))
                    let sg: Double = (Double(j + 1) * SIGNQ)
                        .truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1.0 : -1.0
                    t.bC.append(tR * rn * (0.5 + (Double(j + 2) * GOLD)
                            .truncatingRemainder(dividingBy: 1.0)) * sg)
                }
            }
        }
        let yinf = bp.v("bow_yinf", 0.0)
        let bc = brgCoeffs(fB: bp.v("bow_brg_f", 700.0),
                           qB: bp.v("bow_brg_q", 0.55), sr: sr)
        // kret loop cap over the LITERAL 1..8000 Hz grid
        // (gutstring._y_max_formula): bowW·2Z·max|Y·H_brg|·kret ≤ loop_max
        var kret = bp.v("bow_kret", 0.0)
        if kret > 1e-9, !t.ba1.isEmpty || yinf > 1e-9 {
            var ymax = 0.0
            var f = 1.0
            while f < 8000.0 {
                let w = 2.0 * Double.pi * f / sr
                let z1 = Cx(cos(w), -sin(w))
                let z2 = z1 * z1
                var Y = Cx(yinf, 0)
                for i in t.ba1.indices {
                    let den = Cx(1, 0) - z1 * t.ba1[i] - z2 * t.ba2[i]
                    Y = Y + ((Cx(1, 0) - z2) * (t.bA[i] * t.bn0[i])) / den
                }
                let h = Cx(bc.rb0, 0) / (Cx(1, 0) + z1 * bc.ra1 + z2 * bc.ra2)
                let m = Y.magnitude * h.magnitude
                if m > ymax { ymax = m }
                f += 1.0
            }
            let loop = bp.v("bow_w", 1.0) * 2.0 * Z * ymax * kret
            let cap = bp.v("bow_loop_max", 0.5)
            if loop > cap { kret = kret * cap / loop }
        }
        t.scalars = [
            yinf,                                      // body admittance floor
            bp.v("bow_body_c0", 1.0),                  // direct radiation
            dc,
            0.0,                                       // pgain: no voice force
            exp(-2.0 * Double.pi * 12000.0 / sr),      // aP (inert)
            bp.v("bow_w", 1.0),                        // bowW (nBow = 1)
            kret,                                      // bridge return (capped)
            exp(-2.0 * Double.pi * 600.0 / sr),        // retA (retMode-1 inert)
            1.0,                                       // retMode: 2-pole brg
        ]
        t.scalars += [bc.rb0, bc.ra1, bc.ra2]
        t.scalars += [
            bp.v("bow_kdisp", 0.0),                    // needs yinf > 0
            bp.v("bow_width_smp", 0.0),
            bp.v("bow_contacts", 2.0),
            Z, bp.v("bow_Zt", 5.5) * Z, bp.v("bow_mu_s", 0.8),
            bp.v("bow_mu_d", 0.3),
            bp.v("bow_v0", 0.15),
            exp(-2.0 * Double.pi * bp.v("bow_nut_fc", 5000.0) / sr),
            exp(-2.0 * Double.pi * bp.v("bow_br_fc", 6000.0) / sr),
            exp(-1.0 / (bp.v("bow_th_tau", 0.012) * sr)),
            bp.v("bow_th_a", 0.0),
            bp.v("bow_th_drate", 0.0),
            bp.v("bow_th_floor", 0.15),
            bp.v("bow_disp", 0.0),
            1e-3, 0.02,                                // jq/jq2 (jawari thr)
            bp.v("bow_zload", 1.0),
            // The ringing-comb radiation tap belonged to the deleted web:
            // with no web voices there is no free ring to tap, so tdirect
            // and tshape are hard 0 (the kernel then never enters the tap
            // path and tmix is inert — 1.0 keeps the shaped-blend default).
            0.0,                                       // tdirect
            0.0,                                       // tshape
            1.0,                                       // tmix (inert)
            bp.v("bow_noise", 0.0),
            bp.v("bow_tnoise", 0.0),
            bp.v("bow_noise_pow", 1.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_hi", 8590.0) / sr),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_lo", 402.0) / sr),
            bp.v("bow_noise_dir", 0.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_dir_hi", 6000.0) / sr),
            t.L.isEmpty ? 0.0 : 1.0,                   // PASSIVE wave junction:
                                                       // armed only when the
                                                       // coupling web built
                                                       // voices (bow_cpl_z)
            bp.v("bow_gut_g", 1.0),
            bp.v("bow_disp_n", 1.0),
            bp.v("bow_nail_k", 0.0),
            tonic,                                     // f0Open
            bp.v("bow_gut_fc2", 0.0) > 0.0
                ? exp(-2.0 * Double.pi * bp.v("bow_gut_fc2", 0.0) / sr) : 0.0,
            1.0,                                       // driven tap duck: off
                                                       // (the tap is gone)
            bp.v("bow_tors_ratio", 5.2),               // torsional loop
            bp.v("bow_tors_g", 0.85),
            bp.v("bow_tors_c", 0.0),                   // 0 = bit-null
            bp.v("bow_age_a", 0.0),                    // contact aging (0 = bit-null)
            bp.v("bow_age_ms", 1.5),
            bp.v("bow_v0_fpow", 0.0),                  // Cremer corner rounding
            bp.v("bow_v0_fref", 1.0),
            bp.v("bow_hair_hz", 0.0),                  // hair compliance
            bp.v("bow_hair_ref", 1.0),
            bp.v("bow_cr_w", 0.0),                     // continuum contact
            bp.v("bow_cr_ms", 0.0),                    // (0 = bit-null)
            bp.v("bow_jaw_rho", 0.0),                  // jawari collision
            bp.v("bow_jaw_roll", 0.0),                 // rolling contact
            bp.v("bow_jaw_roll_amp", 0.005),
            bp.v("bow_loss_reg", 0.0),                 // register damping
                                                       // (0 = bit-null)
            bp.v("bow_slide_rate", 900.0),             // slide dulling
            bp.v("bow_slide_dull", 0.0),               // (dull 0 = bit-null)
            bp.v("bow_slide_noise", 0.0),              // accel-driven finger
            bp.v("bow_slide_acc", 25000.0),            // noise (0 = bit-null)
        ]
        return t
    }
}
