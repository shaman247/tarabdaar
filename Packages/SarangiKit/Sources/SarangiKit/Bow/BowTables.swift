import Foundation

/// The complete marshaled input set of the C bow kernel, in C-signature
/// order: the 5 modal-body arrays and the 52 scalars.
public struct BowKernelTables: Sendable {
    public var sr: Double
    // body modal sections
    public var ba1: [Double] = [], ba2: [Double] = [], bn0: [Double] = []
    public var bA: [Double] = [], bC: [Double] = []
    /// The 52 per-sample scalars, in the order of `bow_poly_init`'s
    /// signature — the layout table in bow_kernel.h.
    public var scalars: [Double] = []
    /// Modal-jawari table block — nil = no taraf (byte-null, never loaded).
    public var jt: JtTables? = nil

    public init(sr: Double) {
        self.sr = sr
    }
}

/// Concatenated modal-jawari tables in the C loader's layouts (bow_kernel.h
/// documents them; all dt-dependence is baked here).
public struct JtTables: Sendable {
    public var J: Int32 = 0
    public var M: [Int32] = []
    public var ca: [Double] = [], cb: [Double] = []
    public var ca4: [Double] = [], cb4: [Double] = []
    public var wd: [Double] = [], phiD: [Double] = []
    /// TERMINATION drive shape, the comb-free sibling of `phiD`: the
    /// bridge force enters through the mode SLOPE at the pin,
    /// ∝ (−1)^k·k, ENERGY-matched per row against the 0.90 L tap
    /// (Σ_k phiDT_k² == Σ_k phiD_k²) so the row keeps its fitted total
    /// drive energy and the slope only redistributes it up the modes.
    /// Load-ABI `phiDT`; blended against `phiD` by `bow_jt_drive_term`.
    public var phiDT: [Double] = []
    public var phiU: [Double] = [], phiF: [Double] = []
    public var b: [Double] = [], G: [Double] = [], G4: [Double] = []
    public var gd: [Double] = [], gd4: [Double] = []
    public var phys: [Double] = [], q0: [Double] = []
    /// Worker-pool size for the deferred jt post-pass (`bow_jt_threads`;
    /// < 2 = serial; workers spawn at engine build, never on the audio
    /// thread).
    public var threads: Int32 = 0
    /// Async one-block-late live mode (`bow_jt_async`): the callback never
    /// waits on the pool.
    public var async: Int32 = 0
    /// Per-row fundamentals (Hz), kernel row order — Swift-side only (drone
    /// pitch → nearest row, `BowEngine.dronePress`).
    public var rowFreqs: [Double] = []
    /// Per-row radiation unit match gout·π·wj/(mu·L·wd1): zone contact
    /// force density → radiated velocity. Load-ABI `radScale`.
    public var rowForceScale: [Double] = []
    /// Per-row unit match for the TERMINATION (pin) force, gout·amp2·wd1:
    /// the linear bridge force T·∂u/∂x|L in the same radiated units, so the
    /// tick adds Σ_k (−1)^k·k·q_k straight into the radiated sample. Load-ABI
    /// `pinScale`, beside `radScale`.
    public var rowPinScale: [Double] = []
    /// One-pole tone-LP coefficient on the radiated jt sum (`bow_jt_lp`;
    /// 0 = bypass). Applied via bow_jt_set_lp — not part of the load ABI.
    public var lpA: Double = 0
    /// MELODY FOLLOWER: the row that live-retunes to the played pitch (-1 =
    /// none) plus the law constants the in-kernel retune re-applies. Armed
    /// via `bow_poly_jt_track_config` — not part of the load ABI (never
    /// arming it is byte-null).
    public var trackRow: Int32 = -1
    public var trackT60: Double = 0
    public var trackFhf: Double = 4000
    public var trackBst: Double = 2.0e-4
    /// TWO BRIDGES: per row, whether it sits on the CHROMATIC bridge
    /// (`bow_jtc_*`) rather than the raga one (`bow_jt_*`), plus the
    /// per-row contact constants the engine pushes through
    /// `bow_poly_jt_set_row_contact` (deep threshold = 2.5 × the row's
    /// apex) and the apex for the per-bridge evolve map. `hasChromatic`
    /// false = the setter is never called (byte-null), one global lift.
    public var rowChromatic: [Bool] = []
    public var rowApex: [Double] = []
    public var rowAlpha: [Double] = []
    public var rowHcB: [Double] = []
    public var hasChromatic: Bool = false
    /// The raga bridge's apex (`bow_jt_apex` at build) — the evolve map's
    /// reference for raga rows (phys[3] / 2.5).
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

    /// Raga-lattice membership: within 1% of a just ratio m/n (m,n <= 6)
    /// of the tonic.
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

    /// The chromatic bridge's resting values (used when no `bow_jtc_*` key
    /// is set). Only the three knobs that genuinely differ per bank exist —
    /// level, level norm and evolution; the contact GEOMETRY is derived from
    /// the raga bridge's `bow_jt_*` values, so at rest both bridges are the
    /// same jawari. The registry's `bow_jtc_*` defaults MUST equal these
    /// (`TarabSetTests`): the artifact never carries the keys.
    public static let chromaticBridgeDefaults: [String: Double] = [
        "bow_jtc_gain": 0.3, "bow_jtc_norm": 0.0, "bow_jtc_evolve": 0.5,
    ]

    /// MODAL-JAWARI tables for the taraf rows. Keep every literal and the
    /// arithmetic order — the render hash depends on it.
    ///
    /// `trackRowIndex` marks the melody FOLLOWER row. Its nominal `f`
    /// should sit LOW: the mode allocation is fixed at build and the
    /// kernel only TRIMS the active count as the pitch rises.
    ///
    /// `chromatic` (index-aligned with `rows`; nil = all raga): flagged rows
    /// share the raga bridge's geometry, damping and contact law and carry
    /// their own level (`bow_jtc_gain`) and t60 normalization
    /// (`bow_jtc_norm`), the level baked into the row taps as a ratio
    /// against the raga bridge's global `phys` gain.
    public static func buildJawariTables(
        rows: [(f: Double, gain: Double, t60: Double)],
        srk: Double, bp: BowParams,
        trackRowIndex: Int? = nil,
        chromatic: [Bool]? = nil) -> JtTables? {
        guard !rows.isEmpty else { return nil }
        let J = Int(bp.v("bow_jt_J", 40.0) + 0.5)
        // contact zone width (m): the J points span [L − zone, L − 0.8 mm]
        let zoneWR = bp.v("bow_jt_zone", 0.010)
        let radiusR = bp.v("bow_jt_radius", 0.3)
        // bow_jt_evolve is NOT baked here: it is a live slewed bone offset
        // in the kernel (a stepped bone under a wrapped string strums)
        let apexR = bp.v("bow_jt_apex", 1.0e-5)
        let kc = bp.v("bow_jt_kc", 1.0e10)
        let alphaR = bp.v("bow_jt_alpha", 1.3)
        // hcb: contact hysteresis damping; fhf: HF corner of the per-mode
        // t60 law; bst: stiffness inharmonicity
        let hcBR = bp.v("bow_jt_hcb", 8.0)
        let gain = bp.v("bow_jt_gain", 1.0)
        let drive = bp.v("bow_jt_drive", 1.0)
        let fmax = 18000.0, fHfR = bp.v("bow_jt_fhf", 4000.0)
        let mcap = Int(bp.v("bow_jt_mcap", 64.0) + 0.5)
        let div = max(1, Int(bp.v("bow_jt_div", 1.0) + 0.5))
        let normR = bp.v("bow_jt_norm", 0.0)
        let bstR = bp.v("bow_jt_bst", 2.0e-4)
        // the chromatic bridge's own values (see chromaticBridgeDefaults);
        // its contact geometry is DERIVED from the raga bridge's
        func cv(_ k: String) -> Double { bp.v(k, chromaticBridgeDefaults[k] ?? 0.0) }
        let hasChrom = chromatic?.contains(true) ?? false
        let normC = cv("bow_jtc_norm")
        // chromatic level as a ratio against the global (raga) phys gain —
        // a silenced raga bridge silences the chromatic set too
        let gainMulC = gain > 1e-12 ? cv("bow_jtc_gain") / gain : 0.0
        let driveMulC = 1.0
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
            let zoneW = zoneWR
            let radius = radiusR
            let apex = apexR
            let alpha = alphaR
            let fHf = fHfR
            let norm = chrom ? normC : normR
            T.rowChromatic.append(chrom)
            T.rowApex.append(apex)
            T.rowAlpha.append(alpha)
            T.rowHcB.append(hcBR)
            let f0s = row.f
            T.rowFreqs.append(f0s)
            let L = min(0.30, max(0.08, 0.25 * 296.0 / f0s))
            let fx = min(fmax, 0.42 * srk / Double(div))
            let M = max(16, min(mcap, Int(fx / f0s)))
            let bst = bstR
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
            // drive tap: the bridge force enters each row at 0.90 L
            let xD = 0.90 * L
            // t60-response level normalization
            var gout = row.gain * pow(5.0 / max(row.t60, 0.5), norm)
            var gdrv = row.gain
            // raga rows stay multiply-free — the render hash depends on it
            if chrom { gout *= gainMulC; gdrv *= driveMulC }
            // TERMINATION drive: a moving bridge pushes mode k through the
            // mode SLOPE at the pin, φ'_k(L) ∝ (−1)^k·k — no comb, and by
            // reciprocity the SAME sign convention as the pin-force
            // radiation term Σ(−1)^k·k·q_k in the tick.
            // NORMALISATION LAW — ENERGY MATCH, not mode-1 match: cTerm is
            // chosen per row so Σ_k phiDT_k² == Σ_k phiD_k² over the row's
            // built modes (the shared gdrv·amp2/mu factors cancel, so
            // cTerm = √(Σ sin²(kπ·0.9) / Σ k²)). Each row keeps the FITTED
            // total drive energy of the 0.90 L tap and the slope weighting
            // only REDISTRIBUTES it: mode 1 falls, the high cluster rises.
            // Matching mode 1 instead (× sin(0.9π)) multiplied every mode
            // above the first by ≈ 1.4·k and rang the web ~17 dB hot.
            var cTerm = 0.0
            do {
                var eTap = 0.0, eSlope = 0.0
                for k in 0..<M {
                    let sD = sin(Double(k + 1) * Double.pi * xD / L)
                    eTap += sD * sD
                    eSlope += Double(k + 1) * Double(k + 1)
                }
                cTerm = eSlope > 0 ? (eTap / eSlope).squareRoot() : 0.0
            }
            for k in 0..<M {
                let pd = amp2 * sin(Double(k + 1) * Double.pi * xD / L)
                T.phiD.append(gdrv * pd / mu)
                let kk = Double(k + 1)
                let sgn = (k & 1) == 0 ? -1.0 : 1.0   // (−1)^k, k 1-based
                T.phiDT.append(gdrv * amp2 * sgn * kk * cTerm / mu)
            }
            T.phiU.append(contentsOf: phi)
            T.phiF.append(contentsOf: phi.map { $0 * wj / mu })
            // radiation unit match: termination force of a unit mode-1 ring
            // → radiated velocity is gout·π/(mu·L·wd1); × wj because the
            // kernel sums force DENSITIES over the zone
            T.rowForceScale.append(gout * Double.pi * wj / (mu * L * wd[0]))
            // TERMINATION (pin) force, always radiated:
            // F_pin = T·amp2·(π/L)·Σ(−1)^k·k·q_k
            // with T = mu·(L·wd1/π)²; through the force→radiated match
            // gout·π/(mu·L·wd1) (the same law without the density spacing
            // wj) it collapses to gout·amp2·wd1 per row.
            T.rowPinScale.append(gout * amp2 * wd[0])
            // static wrap q0 (fixed-point, 300 iterations)
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
        // jt tone LP coefficient at the KERNEL rate; ≥ 20 kHz = 0 = the
        // kernel skips the filter
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

    /// THE PLAYED STRING's kernel tables: the friction waveguide + a FORMULA
    /// MODAL BODY (K analytic modes: air resonance at bow_body_air_ratio ×
    /// the open string, plate modes above with constant-per-Hz density +
    /// golden-ratio jitter, POSITIVE admittance residues for passivity,
    /// SIGNED radiation residues), bridge mobility ON (yinf + loop-capped
    /// kret). `tonic` = f0Open AND the body scale. Keep the arithmetic
    /// order and the decimal literals — the render hash depends on them.
    /// The sympathetic strings are built by `buildJawariTables`.
    public static func buildOpenString(sr: Double, tonic: Double,
                                       bp: BowParams)
        -> BowKernelTables {
        var t = BowKernelTables(sr: sr)
        let Z = bp.v("bow_Z", 1.0)
        let dc = exp(-2.0 * Double.pi * 25.0 / sr)     // 25 Hz DC block
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
            // DIFFUSE TAIL: the Schroeder-region mode forest — linear
            // spacing + golden jitter, low Q, √n-normalized signed residues
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
        // kret loop cap over the LITERAL 1..8000 Hz grid:
        // bowW·2Z·max|Y·H_brg|·kret ≤ loop_max
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
            bp.v("bow_zload", 1.0),
            bp.v("bow_noise", 0.0),
            bp.v("bow_tnoise", 0.0),
            bp.v("bow_noise_pow", 1.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_hi", 8590.0) / sr),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_lo", 402.0) / sr),
            bp.v("bow_noise_dir", 0.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_dir_hi", 6000.0) / sr),
            bp.v("bow_gut_g", 1.0),
            bp.v("bow_disp_n", 1.0),
            bp.v("bow_nail_k", 0.0),
            tonic,                                     // f0Open
            bp.v("bow_gut_fc2", 0.0) > 0.0
                ? exp(-2.0 * Double.pi * bp.v("bow_gut_fc2", 0.0) / sr) : 0.0,
            bp.v("bow_tors_ratio", 5.2),               // torsional loop
            bp.v("bow_tors_g", 0.85),
            bp.v("bow_tors_c", 0.0),                   // 0 = bit-null
            bp.v("bow_v0_fpow", 0.0),                  // Cremer corner rounding
            bp.v("bow_v0_fref", 1.0),
            bp.v("bow_hair_hz", 0.0),                  // hair compliance
            bp.v("bow_hair_ref", 1.0),
            bp.v("bow_loss_reg", 0.0),                 // register damping (0 = bit-null)
            bp.v("bow_slide_rate", 900.0),             // slide dulling
            bp.v("bow_slide_dull", 0.0),               // (dull 0 = bit-null)
            bp.v("bow_slide_noise", 0.0),              // accel-driven finger
            bp.v("bow_slide_acc", 25000.0),            // noise (0 = bit-null)
        ]
        return t
    }
}
