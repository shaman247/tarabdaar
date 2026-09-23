import Foundation
import CBowKernel

/// The complete marshaled input set of the C bow kernel, in C-signature
/// order: the 5 modal-body arrays and the `bow_scalars_t` scalar block.
public struct BowKernelTables: Sendable {
    public var sr: Double
    // body modal sections
    public var ba1: [Double] = [], ba2: [Double] = [], bn0: [Double] = []
    public var bA: [Double] = [], bC: [Double] = []
    /// The per-sample scalars, one NAMED field each — the `bow_scalars_t`
    /// struct declared in bow_kernel.h, filled by name (no positional
    /// vector, no optional tail).
    public var scalars = bow_scalars_t()
    /// Modal-jawari table block — nil = no taraf (byte-null, never loaded).
    public var jt: JtTables? = nil

    public init(sr: Double) {
        self.sr = sr
    }
}

/// The kernel scalar block is a fixed-layout struct of plain doubles, so it
/// can also be walked as `fieldCount` contiguous doubles — which is how the
/// live-parameter ramp interpolates it (field by field, in declaration
/// order) and how two blocks are compared.
extension bow_scalars_t {
    /// Number of double fields (`sizeof / sizeof(double)`).
    public static let fieldCount =
        MemoryLayout<bow_scalars_t>.size / MemoryLayout<Double>.size

    /// Read the fields as one contiguous double buffer.
    public func withDoubles<R>(
        _ body: (UnsafeBufferPointer<Double>) -> R) -> R {
        withUnsafePointer(to: self) { p in
            p.withMemoryRebound(to: Double.self,
                                capacity: Self.fieldCount) { d in
                body(UnsafeBufferPointer(start: d, count: Self.fieldCount))
            }
        }
    }

    /// Mutate the fields as one contiguous double buffer.
    public mutating func withMutableDoubles<R>(
        _ body: (UnsafeMutableBufferPointer<Double>) -> R) -> R {
        withUnsafeMutablePointer(to: &self) { p in
            p.withMemoryRebound(to: Double.self,
                                capacity: Self.fieldCount) { d in
                body(UnsafeMutableBufferPointer(start: d,
                                                count: Self.fieldCount))
            }
        }
    }

    /// Field-by-field `==` (NOT a byte compare — the doubles compare as
    /// doubles).
    public func equalsFieldwise(_ o: bow_scalars_t) -> Bool {
        withDoubles { a in
            o.withDoubles { b in
                for i in 0..<Self.fieldCount where a[i] != b[i] { return false }
                return true
            }
        }
    }
}

/// Concatenated modal-jawari tables in the C loader's layouts (bow_kernel.h
/// documents them; all dt-dependence is baked here).
public struct JtTables: Sendable {
    /// Physical two-direction rows selected by the application bank plan.
    public var dualRows: [Int] = []
    public var J: Int32 = 0
    public var M: [Int32] = []
    public var ca: [Double] = [], cb: [Double] = []
    public var ca4: [Double] = [], cb4: [Double] = []
    public var wd: [Double] = [], phiD: [Double] = []
    public var phiU: [Double] = [], phiF: [Double] = []
    public var b: [Double] = [], G: [Double] = [], G4: [Double] = []
    public var gd: [Double] = [], gd4: [Double] = []
    public var phys: [Double] = [], q0: [Double] = []
    /// False if any row needed the legacy wrap and must receive the full settle pre-roll.
    public var equilibriumConverged = true
    /// Worker-pool size for the deferred jt post-pass (`bow_jt_threads`;
    /// < 2 = serial; multiple physical rows can expand this base up to
    /// available cores. Workers spawn at build, never on the audio thread).
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
    /// TWO-WAY COUPLING unit match, mu·L·wd1/(gout·π) ÷ Σ gout: the
    /// reciprocal of the force→radiated factor `rowForceScale` and
    /// `rowPinScale` SHARE, so the tick's DC-BLOCKED radiated sum converts
    /// back to the row's physical bridge force in NEWTONS — then divided by
    /// the BANK's total row gain, because the kernel SUMS the rows into one
    /// return and a 34-row document would otherwise present a very different
    /// loop gain from a 6-row one. With the normalization `bow_jt_couple`
    /// means the same loop gain whatever the bank holds. Load-ABI
    /// `cplScale`; a silent row (gout 0) gets 0. Only `bow_jt_couple` reads
    /// it.
    public var rowCplScale: [Double] = []
    public var rowInputGain: [Double] = []
    public var rowOutputGain: [Double] = []
    /// Bank mix levels, outside the physical return; 1 preserves the fitted mix.
    public var rowOutputLevel: [Double] = []
    public var rowCouplingNorm: Double = 1
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

    /// Chromatic bank defaults; the artifact omits these keys, so the
    /// registry and builder share these values. Legacy `bow_jt_*` geometry
    /// belongs to the chromatic model; physical raga rows use DualTaraf.
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
    /// `chromatic` identifies the bank of each row. Bank levels scale each
    /// row against a fixed output reference, so neither bank controls the
    /// other's radiation or gain ramp. nil retains the unbanked fixture law.
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
        let ragaGain = bp.v("bow_jt_gain", 1.0)
        let drive = bp.v("bow_jt_drive", 1.0)
        let fmax = 18000.0, fHfR = bp.v("bow_jt_fhf", 4000.0)
        let mcap = Int(bp.v("bow_jt_mcap", 64.0) + 0.5)
        let div = max(1, Int(bp.v("bow_jt_div", 1.0) + 0.5))
        let normR = bp.v("bow_jt_norm", 0.0)
        let bstR = bp.v("bow_jt_bst", 2.0e-4)
        // Chromatic defaults; legacy bow_jt_* geometry belongs to its model.
        func cv(_ k: String) -> Double { bp.v(k, chromaticBridgeDefaults[k] ?? 0.0) }
        let hasChrom = chromatic?.contains(true) ?? false
        let normC = cv("bow_jtc_norm")
        // Keep the shipped 0.3 carrier constant for banked tables. Moving
        // either bank only slews its row radiation, including through zero;
        // a moving shared carrier would pump the other bank during the ramp.
        // The unbanked builder remains available for legacy kernel fixtures.
        let gain = chromatic == nil ? ragaGain : 0.3
        let gainMulR = chromatic == nil ? 1.0 : ragaGain / gain
        let gainMulC = cv("bow_jtc_gain") / max(gain, 1e-12)
        let driveMulC = 1.0
        let rW = 2.0e-4
        let mu = Double.pi * rW * rW * 7850.0
        let dt = Double(div) / srk
        let dt4 = dt / 4.0
        var T = JtTables()
        // BANK NORMALIZATION for the two-way coupling return: the kernel
        // sums every row's load into ONE force, so the loop gain scales with
        // how many rows the document holds and how loud they are. Σ gout
        // over the bank divides it back out, so `bow_jt_couple` means one
        // fixed loop gain regardless of the bank.
        var goutSum = 0.0
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
            // the row's modes, HF-rolled damping (t60hf = t60) and rotations
            let w0 = ModalString.modeFrequencies(f0: f0s, count: M, inharmonicity: bst)
            let sig = ModalString.damping(w0: w0, t60: row.t60, fHf: fHf, t60hf: row.t60)
            let rot = ModalString.rotation(w0: w0, sigma: sig, dt: dt)
            let rot4 = ModalString.rotation(w0: w0, sigma: sig, dt: dt4)
            let wd = rot.wd
            T.wd.append(contentsOf: wd)
            T.ca.append(contentsOf: rot.ca)
            T.cb.append(contentsOf: rot.cb)
            T.ca4.append(contentsOf: rot4.ca)
            T.cb4.append(contentsOf: rot4.cb)
            var xz = [Double](repeating: 0, count: J)
            let x0 = L - zoneW, x1 = L - 0.0008
            for j in 0..<J {
                xz[j] = x0 + Double(j) * (x1 - x0) / Double(J - 1)
            }
            let wj = xz[1] - xz[0]
            var phi = [Double](repeating: 0, count: M * J)
            let amp2 = (2.0 / L).squareRoot()      // the shapes' unit norm
            for k in 0..<M {
                for j in 0..<J {
                    phi[k * J + j] = ModalString.shape(mode: k, at: xz[j], length: L)
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
            let gout = row.gain * pow(5.0 / max(row.t60, 0.5), norm)
            var gdrv = row.gain
            // Bank levels are radiation-only. Keeping them out of these
            // coefficients preserves bridge feedback through every gain ramp.
            T.rowOutputLevel.append(chrom ? gainMulC : gainMulR)
            if chrom { gdrv *= driveMulC }
            T.rowInputGain.append(gdrv)
            T.rowOutputGain.append(gout)
            for k in 0..<M {
                let pd = ModalString.shape(mode: k, at: xD, length: L)
                T.phiD.append(gdrv * pd / mu)
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
            // TWO-WAY COUPLING: undo the shared force→radiated factor
            // gout·π/(mu·L·wd1) so the kernel's summed radiated force reads
            // back in newtons. The BANK normalization (÷ Σ gout) is applied
            // after the loop.
            goutSum += gout
            T.rowCplScale.append(gout > 1e-12
                                 ? mu * L * wd[0] / (gout * Double.pi)
                                 : 0.0)
            // Solve the force equilibrium with a checked residual. The old
            // recurrence can oscillate indefinitely for low rows; it remains
            // only a fallback for configurations the Newton solve cannot handle.
            let solved = JawariEquilibrium.solve(phi: phi,
                force: phi.map { $0 * wj / mu }, omega: w0,
                bone: bprof, stiffness: kc, alpha: alpha)
            var q0 = solved ?? [Double](repeating: 0, count: M)
            if solved == nil {
                T.equilibriumConverged = false
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
            }
            T.q0.append(contentsOf: q0)
            T.M.append(Int32(M))
        }
        if goutSum > 1e-12 {
            T.rowCouplingNorm = 1 / goutSum
            for i in T.rowCplScale.indices { T.rowCplScale[i] /= goutSum }
        }
        T.phys = [kc, alphaR, hcBR, 2.5 * apexR, gain, drive, Double(div)]
        T.threads = Int32(bp.v("bow_jt_threads", 0.0).rounded())
        T.async = bp.v("bow_jt_async", 0.0) > 0.5 ? 1 : 0
        // jt tone LP coefficient at the KERNEL rate; ≥ 20 kHz = 0 = the
        // kernel skips the filter
        let lpHz = bp.v("bow_jt_lp", 20000.0)
        T.lpA = lpHz < 19999.0
            ? OnePole.coefficient(hz: lpHz, sr: srk) : 0.0
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
        let dc = OnePole.pole(hz: 25.0, sr: sr)          // 25 Hz DC block
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
            // spacing + golden jitter, low Q, √n-normalized residues. The
            // RADIATION residues are GAUSSIAN (sign and magnitude) from a
            // seeded generator: in the diffuse regime a mode's shape at the
            // bridge and at the listener are independent normal variates,
            // so the radiated sum has Rayleigh statistics — deep nulls and
            // a log-normal ripple — rather than the even scallop a bounded
            // residue law gives. The admittance residues stay positive and
            // bounded (passivity; the loop cap and wolf behaviour are those
            // of a lightly loaded bridge). `bow_body_tail_seed` picks the
            // instrument.
            let nt = Int(bp.v("bow_body_tail_n", 0.0).rounded())
            if nt > 0 {
                let tLo = bp.v("bow_body_tail_f0", 700.0)
                let tHi = bp.v("bow_body_tail_f1", 5500.0)
                let tQ = bp.v("bow_body_tail_q", 18.0)
                let tY = bp.v("bow_body_tail_y", 0.3)
                let tR = bp.v("bow_body_tail_rad", 1.0)
                let rn = 1.0 / Double(nt).squareRoot()
                var gauss = SeededGaussian(
                    seed: UInt64(max(1, Int(bp.v("bow_body_tail_seed", 1.0).rounded()))))
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
                    t.bC.append(tR * rn * gauss.next())
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
        // Filled BY NAME — the kernel struct is the layout, there is no
        // positional vector to keep in lockstep any more.
        var s = bow_scalars_t()
        s.yinf = yinf                                  // body admittance floor
        s.c0 = bp.v("bow_body_c0", 1.0)                // direct radiation
        s.dcRho = dc
        s.pgain = 0.0                                  // no voice force
        s.pA = OnePole.pole(hz: 12000.0, sr: sr)         // inert at pgain 0
        s.bowW = bp.v("bow_w", 1.0)                    // bowW (nBow = 1)
        s.kret = kret                                  // bridge return (capped)
        s.retA = OnePole.pole(hz: 600.0, sr: sr)         // retA (retMode-1 inert)
        s.retMode = 1.0                                // 2-pole bridge
        s.rb0 = bc.rb0
        s.ra1 = bc.ra1
        s.ra2 = bc.ra2
        s.kdisp = bp.v("bow_kdisp", 0.0)               // needs yinf > 0
        s.bowWidth = bp.v("bow_width_smp", 0.0)
        s.bowCont = bp.v("bow_contacts", 2.0)
        s.Z = Z
        s.Zt = bp.v("bow_Zt", 5.5) * Z
        s.mu_s = bp.v("bow_mu_s", 0.8)
        s.mu_d = bp.v("bow_mu_d", 0.3)
        s.v0f = bp.v("bow_v0", 0.15)
        s.nutA = OnePole.pole(hz: bp.v("bow_nut_fc", 5000.0), sr: sr)
        s.brA = OnePole.pole(hz: bp.v("bow_br_fc", 6000.0), sr: sr)
        s.thLeak = OnePole.pole(tau: bp.v("bow_th_tau", 0.012), sr: sr)
        s.thA = bp.v("bow_th_a", 0.0)
        s.thD = bp.v("bow_th_drate", 0.0)
        s.thFloor = bp.v("bow_th_floor", 0.15)
        s.bowDisp = bp.v("bow_disp", 0.0)
        s.zload = bp.v("bow_zload", 1.0)
        s.nA = bp.v("bow_noise", 0.0)
        s.nT = bp.v("bow_tnoise", 0.0)
        s.nPow = bp.v("bow_noise_pow", 1.0)
        s.nzHi = OnePole.coefficient(hz: bp.v("bow_noise_hi", 8590.0), sr: sr)
        s.nzLo = OnePole.coefficient(hz: bp.v("bow_noise_lo", 402.0), sr: sr)
        s.nDir = bp.v("bow_noise_dir", 0.0)
        s.nzHiD = OnePole.coefficient(hz: bp.v("bow_noise_dir_hi", 6000.0), sr: sr)
        s.gutG = bp.v("bow_gut_g", 1.0)
        s.dispN = bp.v("bow_disp_n", 1.0)
        s.nailK = bp.v("bow_nail_k", 0.0)
        s.f0Open = tonic
        s.gutA2 = bp.v("bow_gut_fc2", 0.0) > 0.0
            ? OnePole.pole(hz: bp.v("bow_gut_fc2", 0.0), sr: sr) : 0.0
        s.torsRatio = bp.v("bow_tors_ratio", 5.2)      // torsional loop
        s.torsG = bp.v("bow_tors_g", 0.85)
        s.torsC = bp.v("bow_tors_c", 0.0)              // 0 = bit-null
        s.v0Pow = bp.v("bow_v0_fpow", 0.0)             // Cremer corner rounding
        s.v0Ref = bp.v("bow_v0_fref", 1.0)
        s.hairHz = bp.v("bow_hair_hz", 0.0)            // hair compliance
        s.hairRef = bp.v("bow_hair_ref", 1.0)
        s.lossReg = bp.v("bow_loss_reg", 0.0)          // register damping
        s.slideRate = bp.v("bow_slide_rate", 900.0)    // slide dulling
        s.slideDull = bp.v("bow_slide_dull", 0.0)      // (dull 0 = bit-null)
        s.slideNoise = bp.v("bow_slide_noise", 0.0)    // accel-driven finger
        s.slideAcc = bp.v("bow_slide_acc", 25000.0)    // noise (0 = bit-null)
        t.scalars = s
        return t
    }
}

/// Deterministic unit-normal stream (xorshift64 + Box–Muller) for the
/// body tail's radiation residues: the same seed builds the same body on
/// every machine, so the render hash pins it.
struct SeededGaussian {
    private var x: UInt64
    private var spare: Double? = nil

    init(seed: UInt64) {
        // scramble so seeds 1, 2, 3 … start far apart
        x = (seed &* 0x9E3779B97F4A7C15) | 1
        for _ in 0..<4 { _ = uniform() }
    }

    private mutating func uniform() -> Double {
        x = XorShift64.step(x)
        // (0, 1]: 53 random bits, never exactly 0 (log-safe)
        return (Double(x >> 11) + 1.0) / 9007199254740993.0
    }

    mutating func next() -> Double {
        if let s = spare { spare = nil; return s }
        let u1 = uniform(), u2 = uniform()
        let r = (-2.0 * log(u1)).squareRoot()
        let th = 2.0 * Double.pi * u2
        spare = r * sin(th)
        return r * cos(th)
    }
}
