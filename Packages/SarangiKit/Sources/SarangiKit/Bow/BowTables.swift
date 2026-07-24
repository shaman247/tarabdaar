import Foundation

/// The complete marshaled input set of the C bow kernel — 19 per-voice
/// columns, 5 modal-body arrays and the 52-scalar list, in the exact
/// C-signature order. Swift twin of `bowstring._kernel_setup` (which factors
/// the same values for the one-shot render AND the streaming driver); the
/// table-parity golden (`bow_tables_default.json`) asserts the two builders
/// agree to 1e-12.
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
    public var wd: [Double] = [], phiO: [Double] = [], phiD: [Double] = []
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
    /// One-pole tone-control coefficient on the radiated jt sum
    /// (bow_jt_lp, Hz; ≥ 20 kHz ⇒ 0 = bypass, the byte-exact legacy
    /// path). Applied via bow_jt_set_lp — NOT part of the load ABI.
    public var lpA: Double = 0
    public init() {}
}

/// One voice of the coupled string network before kernel-rate coefficient
/// expansion — the Swift twin of a `coupled.network_strings` row.
struct BowVoice {
    var f: Double
    var t60: Double
    var w: Double
    var bright: Double
    var kappa: Double
    var played: Bool
    var jaw: Double
    var cls: String        // "raga" | "chrom" | "played" (per-class tap/jawari)
    var t60Abs: Bool = false   // measured-absolute decay: no scale, no cap
}

public enum BowTables {

    // ----------------------------------------------------------------- //
    // string-loop law (blocks.web_loop_coeffs — the ONE loop-coefficient
    // law; CombString carries the same math inline for the legacy bank)
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

    // ----------------------------------------------------------------- //
    // voice expansion (coupled.network_strings / expand_choir)
    // ----------------------------------------------------------------- //

    /// Polarization-doublet choir expansion (`coupled.expand_choir`):
    /// golden-ratio hash of the APPEND-TIME index within the choir.
    static func expandChoir(_ strings: [(f: Double, rel: Double, t60: Double)],
                            polSplit: Double, polT60: Double, polGain: Double)
        -> [(f: Double, rel: Double, t60: Double)] {
        var voices: [(f: Double, rel: Double, t60: Double)] = []
        for s in strings {
            voices.append(s)
            if polSplit > 0.01 {
                let frac = (Double(voices.count) * 0.61803398875)
                    .truncatingRemainder(dividingBy: 1.0)
                let split = polSplit * (0.6 + 0.8 * frac)
                voices.append((s.f * pow(2.0, split / 1200.0),
                               s.rel * polGain, s.t60 * polT60))
            }
        }
        return voices
    }

    /// The full string table of the coupled network (taraf choirs with the
    /// exact legacy weights + 3 open-tuned played strings on the same
    /// bridge) — port of `coupled.network_strings`.
    static func networkStrings(tuning: BowTuning, q: BowNetParams) -> [BowVoice] {
        let pol = q.v("B_pol_split", 0.0)
        let polT = q.v("B_pol_t60", 0.65)
        let polG = q.v("B_pol_gain", 0.85)
        var out: [BowVoice] = []
        let scls = tuning.stringClass
        let haveCls = scls != nil && scls!.count == tuning.strings.count
        let choirs: [(gain: Double, sel: Bool)] = [
            (q.v("B_gain", 0.4), false),
            (q.v("B_gain", 0.4) * q.v("B_bright", 0.0), true),
        ]
        for (choirGain, sel) in choirs {
            if abs(choirGain) <= 1e-6 { continue }
            var choir: [(f: Double, rel: Double, t60: Double)] = []
            var ccls: [String] = []
            var cabs: [Bool] = []
            for (i, s) in tuning.strings.enumerated() where s.bright == sel {
                choir.append((s.f, s.gain, s.t60))
                // per-bank jawari class; stale-cache fallback: bright → raga
                ccls.append(haveCls ? scls![i] : (sel ? "raga" : "chrom"))
                cabs.append(tuning.t60AbsIdx.contains(i))
            }
            let voices = expandChoir(choir, polSplit: pol, polT60: polT,
                                     polGain: polG)
            if voices.isEmpty { continue }
            let per = pol > 0.01 ? 2 : 1
            var vcls: [String] = []
            var vabs: [Bool] = []
            for c in ccls { for _ in 0..<per { vcls.append(c) } }
            for a in cabs { for _ in 0..<per { vabs.append(a) } }
            let gLin = choirGain / Double(voices.count).squareRoot()
            let bright = q.v("B_lp", 0.4) * (sel ? 1.0 : 0.6)
            for ((v, c), ab) in zip(zip(voices, vcls), vabs) {
                let jaw = q.v(c == "raga" ? "N_jaw_raga" : "N_jaw_chrom", 0.0)
                out.append(BowVoice(f: v.f, t60: v.t60, w: gLin * v.rel,
                                    bright: bright, kappa: q.v("N_kappa", 1.0),
                                    played: false, jaw: jaw, cls: c,
                                    t60Abs: ab))
            }
        }
        // played strings: Sa, Pa (fifth below Sa's octave), low Sa
        let playedRatios = [1.0, 0.75, 0.5]        // coupled.PLAYED_RATIOS
        let nPlayed = Double(playedRatios.count)
        for r in playedRatios {
            out.append(BowVoice(f: tuning.tonic * r,
                                t60: q.v("N_played_t60", 2.0),
                                w: q.v("N_played_gain", 0.35) / nPlayed.squareRoot(),
                                bright: q.v("N_played_bright", 0.15),
                                kappa: q.v("N_kappa_played", 1.0),
                                played: true,
                                jaw: q.v("N_jaw_played", 0.0), cls: "played"))
        }
        return out
    }

    /// Per-voice junction impedance Z_i — the ONE law (`coupled.junction_Z`):
    /// taraf Z_i = N_Z_taraf·(w_i / mean taraf w) so B_gain and the √n choir
    /// normalization cancel; played strings share N_Z_played.
    static func junctionZ(_ voices: [BowVoice], q: BowNetParams) -> [Double] {
        let zT = q.v("N_Z_taraf", 0.0)
        let zP = q.v("N_Z_played", 0.0)
        let wTaraf = voices.filter { !$0.played }.map(\.w)
        let wMean = wTaraf.isEmpty ? 1.0
            : wTaraf.reduce(0, +) / Double(wTaraf.count)
        return voices.map { $0.played ? zP : zT * ($0.w / wMean) }
    }

    // ----------------------------------------------------------------- //
    // kret passivity cap (bowstring._y_max / _brg_coeffs)
    // ----------------------------------------------------------------- //

    /// ONE fallback for the legacy bridge-return corner (the twin of
    /// `bowstring.RET_FC_DEFAULT`): the kret loop-cap projection must guard
    /// the SAME filter the kernel runs, so `yMax` and the retA coefficient
    /// may never default apart.
    static let retFcDefault = 600.0

    /// Bridge-mobility resonant 2-pole (mass on skin compliance), unit DC
    /// gain: rb0 / (1 + ra1 z⁻¹ + ra2 z⁻²) — `bowstring._brg_coeffs`.
    static func brgCoeffs(fB: Double, qB: Double, sr: Double)
        -> (rb0: Double, ra1: Double, ra2: Double) {
        let R = exp(-Double.pi * fB / (max(qB, 0.3) * sr))
        let th = 2.0 * Double.pi * fB / sr
        let ra1 = -2.0 * R * cos(th)
        let ra2 = R * R
        return (1.0 + ra1 + ra2, ra1, ra2)
    }

    /// max|Y·H_ret| of the fitted bridge admittance seen through the bow
    /// return filter (`bowstring._y_max`): the passivity guard MUST include
    /// the return filter or it clamps kret 5–10× below the true bound.
    /// Evaluated on the numpy grid it uses — sr 44100, n_pad = 2^⌈log2 44100⌉
    /// = 65536 rfft bins — so the projected kret matches offline exactly.
    static func yMax(q: BowNetParams, retFc: Double?,
                     brg: (f: Double, q: Double)?) -> Double {
        let sr = 44100.0
        let nPad = 65536
        let half = nPad / 2
        let rho = exp(-2.0 * Double.pi * 25.0 / sr)      // coupled.DC_BLOCK_HZ
        let yinf = q.v("N_yinf", 0.08)
        // per-mode constants (coupled.modal_bank_B, modes ≥ 0.45·sr dropped
        // by zeroing — numpy keeps a zero response for them)
        struct Mode { var twoRcos: Double; var R2: Double; var n0inv: Double
                      var a: Double; var live: Bool }
        var modes: [Mode] = []
        for (i, m) in q.modes.enumerated() {
            let f = m[0], mq = m[1]
            if f >= 0.45 * sr {
                modes.append(Mode(twoRcos: 0, R2: 0, n0inv: 0, a: 0, live: false))
                continue
            }
            let R = exp(-Double.pi * f / (max(mq, 0.5) * sr))
            let th = 2.0 * Double.pi * f / sr
            let zr = Cx(cos(th), -sin(th))
            let zr2 = zr * zr
            let den = Cx(1, 0) - Cx(2.0 * R * cos(th), 0) * zr + Cx(R * R, 0) * zr2
            let n0 = ((Cx(1, 0) - zr2) / den).magnitude
            modes.append(Mode(twoRcos: 2.0 * R * cos(th), R2: R * R,
                              n0inv: 1.0 / max(n0, 1e-12),
                              a: i < q.resA.count ? q.resA[i] : 0, live: true))
        }
        var brgC: (rb0: Double, ra1: Double, ra2: Double)? = nil
        if let b = brg { brgC = brgCoeffs(fB: b.f, qB: b.q, sr: sr) }
        let aRet = retFc != nil ? exp(-2.0 * Double.pi * retFc! / sr) : 0.0
        var best = 0.0
        for k in 0...half {
            let omega = 2.0 * Double.pi * Double(k) / Double(nPad)
            let z1 = Cx.expMinusJ(omega)
            let z2 = z1 * z1
            // y_inf branch through the DC blocker
            let hp = (Cx(0.5 * (1.0 + rho), 0) * (Cx(1, 0) - z1))
                / (Cx(1, 0) - z1 * rho)
            var Y = hp * yinf
            for m in modes where m.live {
                let num = Cx(1, 0) - z2
                let den = Cx(1, 0) - z1 * m.twoRcos + z2 * m.R2
                Y = Y + ((num / den) * (m.n0inv * m.a))
            }
            var mag = Y.magnitude
            if let b = brgC {
                let h = Cx(b.rb0, 0) / (Cx(1, 0) + z1 * b.ra1 + z2 * b.ra2)
                mag *= h.magnitude
            } else if aRet > 0 {
                let lp = (Cx(1.0 - aRet, 0) / (Cx(1, 0) - z1 * aRet)).magnitude
                mag *= lp * lp
            }
            if mag > best { best = mag }
        }
        return best
    }

    // ----------------------------------------------------------------- //
    // the builder (bowstring._voice_tables + _body_tables + _kernel_setup)
    // ----------------------------------------------------------------- //

    /// Build the full kernel input set at rate `sr` (the OVERSAMPLED kernel
    /// rate, 96 kHz live). `nBow` = the bow/additive excitation blend
    /// (N_bow; 1.0 live — the additive voice force path is silent).
    public static func build(sr: Double, tuning: BowTuning, q: BowNetParams,
                             bp: BowParams, nBow: Double) -> BowKernelTables {
        var t = BowKernelTables(sr: sr)

        // kret loop cap: with the FITTED body (hot residues) an uncapped
        // bridge return diverges — project kret so bowW·2Z·max|Y·H_ret|·kret
        // stays under bow_loop_max.
        let loopMax = bp.v("bow_loop_max", 0.5)
        let Z = bp.v("bow_Z", 1.0)
        let retMode = bp.v("bow_ret_mode", 1.0)
        let brg = (f: bp.v("bow_brg_f", 700.0), q: bp.v("bow_brg_q", 0.55))
        let ymax = retMode >= 0.5
            ? yMax(q: q, retFc: nil, brg: brg)
            : yMax(q: q, retFc: bp.v("bow_ret_fc", retFcDefault), brg: nil)
        var kret = bp.v("bow_kret", 0.6)
        let bowWEff = bp.v("bow_w", 0.35) * nBow
        if bowWEff > 1e-9 {
            let loop = bowWEff * 2.0 * Z * ymax * kret
            if loop > loopMax { kret = kret * loopMax / loop }
        }

        // ---- per-voice columns (_voice_tables) ----
        let voices = networkStrings(tuning: tuning, q: q)
        let t60s = q.v("B_t60_scale", 1.0)
        let inh = q.v("B_inharm", 0.0)
        let alpha = q.v("N_alpha", 0.6)
        let t60p = q.v("N_t60_played_scale", 1.0)
        // RING CAP (energy discipline, mirrors bowstring._voice_tables): no
        // string rings past ~N_t60_cap seconds — inaudible (~-60 dB) by then.
        // Large default reproduces the previous tables exactly.
        let t60Cap = q.v("N_t60_cap", 1e9)
        let passive = q.isPassive
        let Zs = passive ? junctionZ(voices, q: q)
                         : [Double](repeating: 0, count: voices.count)
        let loop = q.v("N_loop", 1.0)
        let dmp = q.v("B_damp", 0.0) * q.v("N_damp_scale", 1.0)
        for (v, Zi) in zip(voices, Zs) {
            // measured-absolute decay (ring-tuning artifact): the pencil
            // t60 of the real line — no scale, no cap (python 07-15 law)
            let t60 = v.t60Abs ? v.t60
                : min(v.t60 * (v.played ? t60p : t60s), t60Cap)
            let (L, eta, c, s, g, _) = webLoopCoeffs(
                f0: v.f, t60: t60, sr: sr,
                inharm: v.played ? 0.0 : inh, damp: v.played ? 0.0 : dmp)
            let c0 = (1.0 - s) * (1.0 - s)
            let c1 = 2.0 * s * (1.0 - s)
            let c2 = s * s
            let p = eta * c
            let ssum = eta + c
            t.L.append(Int32(L))
            t.cs.append(ssum)
            t.cp.append(p)
            t.w0.append(p * c0)
            t.w1.append(p * c1 + ssum * c0)
            t.w2.append(p * c2 + ssum * c1 + c0)
            t.w3.append(ssum * c2 + c1)
            t.w4.append(c2)
            t.g.append(g)
            let fc = min(1400.0 + v.bright * q.v("N_bright_scale", 1.0) * 6000.0,
                         0.45 * sr)
            t.lpA.append(exp(-2.0 * Double.pi * fc / sr))
            t.wout.append(v.w * (v.played ? 1.0 : q.v("N_taraf_out", 1.0)))
            // frequency-tilted coupling (transfer mobility falls with f)
            let tl = q.v("N_kap_tilt", 0.0)
            let kt = tl > 1e-9 ? pow(500.0 / max(v.f, 80.0), tl) : 1.0
            t.kap.append(v.kappa * q.v("N_loop", 1.0) * min(kt, 4.0))
            if passive {
                // zi = Z_i·N_loop (f_i = y_i + zi·V), zdrv = 2·zi/(1−g)
                // (the −zdrv·V comb drive); alphaw carries w·α — the
                // junction force is UNWEIGHTED at the bridge.
                t.alphaw.append(v.played ? alpha * v.w : 0.0)
                t.zi.append(Zi * loop)
                t.zdrv.append(2.0 * Zi * loop / (1.0 - g))
            } else {
                t.alphaw.append(v.played ? alpha : 0.0)
                t.zi.append(0.0)
                t.zdrv.append(0.0)
            }
            t.jw.append(v.jaw)
            t.jl.append(v.jaw * q.v("N_jaw_loss", 0.0))
            t.jn.append(v.jaw * q.v("N_jaw2", 0.0))
            // per-class DIRECT-TAP weight (the tivra-ma tritone fix): the
            // chromatic row's free decay radiates through the tap ~35 dB
            // louder than through the passive junction. tdir ONLY (bridge
            // force untouched — zero loop-gain impact). 1.0 = null.
            // N_tdir_played (the loud-Pa bloom): a PLAYED string driven at
            // a partial unison reaches a huge steady state (jaw 0 = no
            // jawari loss) and the tap re-radiated it +12-16 dB over the
            // target — the junction already radiates the DRIVEN response;
            // the tap's job is the free ring.
            t.twt.append(v.cls == "chrom" ? q.v("N_tdir_chrom", 1.0)
                         : v.cls == "played" ? q.v("N_tdir_played", 1.0)
                         : 1.0)
        }

        // LATTICE-AFFINITY pre-charge (JI sympathetic transfer with the
        // tonic series). Live loads zero it (BowSetup — start from silence);
        // the parity fixture carries the offline value.
        let chgs = bp.v("bow_precharge", 0.0)
        for v in voices {
            var best = 0.0
            if chgs > 0 {
                for m in 1...6 {
                    for n in 1...6 where
                        abs(Double(m) * v.f / (Double(n) * tuning.tonic) - 1.0) < 0.01 {
                        best = max(best, 1.0 / (Double(m) * Double(n)).squareRoot())
                    }
                }
            }
            t.chg.append(chgs * best)
        }

        // ---- body modal sections (_body_tables) ----
        for (i, m) in q.modes.enumerated() {
            let f = m[0], mq = m[1]
            if f >= 0.45 * sr { continue }
            let R = exp(-Double.pi * f / (max(mq, 0.5) * sr))
            let th = 2.0 * Double.pi * f / sr
            let zr = Cx(cos(th), -sin(th))
            let zr2 = zr * zr
            let den = Cx(1, 0) - Cx(2.0 * R * cos(th), 0) * zr + Cx(R * R, 0) * zr2
            let n0 = ((Cx(1, 0) - zr2) / den).magnitude
            t.ba1.append(2.0 * R * cos(th))
            t.ba2.append(-(R * R))
            t.bn0.append(1.0 / max(n0, 1e-12))
            t.bA.append(i < q.resA.count ? q.resA[i] : 0)
            t.bC.append(i < q.resC.count ? q.resC[i] : 0)
        }
        let dc = exp(-2.0 * Double.pi * 25.0 / sr)     // coupled.DC_BLOCK_HZ

        // ---- 52 scalars, C-signature order (_kernel_setup's _sc) ----
        let aP = exp(-2.0 * Double.pi * min(q.v("N_pfc", 12000.0), 0.45 * sr) / sr)
        t.scalars = [
            q.v("N_yinf", 0.08), q.v("N_c0", 0.15), dc,
            q.v("N_pgain", 1.0) * (1.0 - nBow), aP,
            bowWEff, kret,
            exp(-2.0 * Double.pi * bp.v("bow_ret_fc", retFcDefault) / sr),
            retMode,
        ]
        let bc = brgCoeffs(fB: brg.f, qB: brg.q, sr: sr)
        t.scalars += [bc.rb0, bc.ra1, bc.ra2]
        t.scalars += [
            bp.v("bow_kdisp", 0.0),
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
            q.v("N_jaw_thr", 1e-3),
            q.v("N_jaw2_thr", 0.02),
            bp.v("bow_zload", 0.0),
            q.v("N_taraf_dir", 0.0),
            bp.v("bow_tdir_shape", 0.0),
            bp.v("bow_tdir_mix", 1.0),
            bp.v("bow_noise", 0.0),
            bp.v("bow_tnoise", 0.0),
            bp.v("bow_noise_pow", 1.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_hi", 8590.0) / sr),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_lo", 402.0) / sr),
            bp.v("bow_noise_dir", 0.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_dir_hi", 5000.0) / sr),
            passive ? 1.0 : 0.0,
            // gut-string physics (2026-07-14; all null at defaults)
            bp.v("bow_gut_g", 1.0),
            bp.v("bow_disp_n", 1.0),
            bp.v("bow_nail_k", 0.0),
            tuning.tonic,
            // second termination pole (transmitted-force-only; 0 = off)
            bp.v("bow_gut_fc2", 0.0) > 0.0
                ? exp(-2.0 * Double.pi * bp.v("bow_gut_fc2", 0.0) / sr) : 0.0,
            // driven-unison tap duck depth (1.0 = off; 2026-07-16i resync)
            bp.v("bow_tdir_unison", 1.0),
            // torsional wave loop (2026-07-16j; c 0 = bit-null)
            bp.v("bow_tors_ratio", 5.2),
            bp.v("bow_tors_g", 0.85),
            bp.v("bow_tors_c", 0.0),
            // rate-and-state contact aging (2026-07-17g; a 0 = bit-null)
            bp.v("bow_age_a", 0.0),
            bp.v("bow_age_ms", 1.5),
            // Cremer corner rounding (2026-07-18f; pow 0 = bit-null)
            bp.v("bow_v0_fpow", 0.0),
            bp.v("bow_v0_fref", 1.0),
            // hair compliance (2026-07-19c; hz 0 = bit-null)
            bp.v("bow_hair_hz", 0.0),
            bp.v("bow_hair_ref", 1.0),
            // continuum-release contact (2026-07-19d; both 0 = bit-null)
            bp.v("bow_cr_w", 0.0),
            bp.v("bow_cr_ms", 0.0),
            // jawari collision restitution (2026-07-20; 0 = legacy)
            bp.v("bow_jaw_rho", 0.0),
            // rolling contact (2026-07-20; 0 = legacy)
            bp.v("bow_jaw_roll", 0.0),
            bp.v("bow_jaw_roll_amp", 0.005),
        ]
        return t
    }

    /// GENERIC PURE-PHYSICS BOWED STRING (2026-07-16): the friction
    /// waveguide + a FORMULA MODAL BODY (2026-07-16b, the "synthy" fix) +
    /// a FORMULA TARAF (2026-07-16d) — K analytic modes: air resonance at
    /// bow_body_air_ratio × the open string, wood plate modes above with
    /// constant-per-Hz density + golden-ratio jitter, POSITIVE admittance
    /// residues (passivity = stability), SIGNED radiation residues
    /// (same-sign sums honk). Bridge mobility is ON (yinf + loop-cap-
    /// projected kret; the kernel force-gates the return). `taraf` =
    /// sympathetic TUNING rows (the app's string table) on the same bridge
    /// through the PASSIVE wave junction — small coupling impedance (long
    /// ring), golden-ratio polarization doublets, the ringing-comb
    /// radiation tap shaped by the formula body (a passive junction cannot
    /// radiate free decay). The Swift twin of `gutstring.formula_body` +
    /// `formula_taraf` + `_string_scalars` — keep the arithmetic in
    /// LOCKSTEP (decimal literals; both sides assemble the same 52 scalars,
    /// tdirUni included, since the resync). `tonic` = f0Open AND the body
    /// scale.
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
    public static func buildJawariTables(
        rows: [(f: Double, gain: Double, t60: Double)],
        srk: Double, bp: BowParams) -> JtTables? {
        guard bp.v("bow_jtaraf_on", 0.0) > 0.5, !rows.isEmpty else {
            return nil
        }
        let J = Int(bp.v("bow_jt_J", 40.0) + 0.5)
        // bow_jt_zone (2026-07-22, J8z6): the contact lives in ~6 mm
        // around the apex — a narrowed zone concentrates J on the
        // active region (measured closer-to-converged than J16 at
        // 10 mm). Default 0.010 = the pre-J8z6 tables.
        let zoneW = bp.v("bow_jt_zone", 0.010), radius = 0.3
        let apex = bp.v("bow_jt_apex", 1.0e-5)
        let kc = 1.0e10
        let alpha = bp.v("bow_jt_alpha", 1.3)
        // Starpad tone knobs (2026-07-23; defaults = the legacy hardcoded
        // values, so untouched artifacts build byte-identical tables):
        // hcb = contact hysteresis damping, fhf = HF damping corner of the
        // per-mode t60 law, bst = stiffness inharmonicity coefficient.
        let hcB = bp.v("bow_jt_hcb", 8.0)
        let gain = bp.v("bow_jt_gain", 1.0)
        let drive = bp.v("bow_jt_drive", 1.0)
        let fmax = 18000.0, fHf = bp.v("bow_jt_fhf", 4000.0)
        let mcap = Int(bp.v("bow_jt_mcap", 64.0) + 0.5)
        let div = max(1, Int(bp.v("bow_jt_div", 1.0) + 0.5))
        let norm = bp.v("bow_jt_norm", 0.0)
        let rW = 2.0e-4
        let mu = Double.pi * rW * rW * 7850.0
        let dt = Double(div) / srk
        let dt4 = dt / 4.0
        var T = JtTables()
        T.J = Int32(J)
        for row in rows {
            let f0s = row.f
            T.rowFreqs.append(f0s)
            let L = min(0.30, max(0.08, 0.25 * 296.0 / f0s))
            let fx = min(fmax, 0.42 * srk / Double(div))
            let M = max(16, min(mcap, Int(fx / f0s)))
            let bst = bp.v("bow_jt_bst", 2.0e-4)
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
            let xO = 0.90 * L
            var phiO = [Double](repeating: 0, count: M)
            // t60-response normalization (python jt_tables mirror)
            let gout = row.gain * pow(5.0 / max(row.t60, 0.5), norm)
            for k in 0..<M {
                phiO[k] = amp2 * sin(Double(k + 1) * Double.pi * xO / L)
                T.phiO.append(gout * phiO[k])
                T.phiD.append(row.gain * phiO[k] / mu)
            }
            T.phiU.append(contentsOf: phi)
            T.phiF.append(contentsOf: phi.map { $0 * wj / mu })
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
        T.phys = [kc, alpha, hcB, 2.5 * apex, gain, drive, Double(div)]
        T.threads = Int32(bp.v("bow_jt_threads", 0.0).rounded())
        T.async = bp.v("bow_jt_async", 0.0) > 0.5 ? 1 : 0
        // Starpad jt tone LP (2026-07-23): one-pole on the radiated jt sum,
        // at the KERNEL sample rate (the hold stream is written per kernel
        // sample). ≥ 20 kHz = bypass (coefficient 0 → the kernel skips the
        // filter entirely — bit-exact legacy output).
        let lpHz = bp.v("bow_jt_lp", 20000.0)
        T.lpA = lpHz < 19999.0
            ? 1.0 - exp(-2.0 * Double.pi * lpHz / srk) : 0.0
        return T
    }

    public static func buildOpenString(sr: Double, tonic: Double,
                                       bp: BowParams,
                                       taraf: [(f: Double, gain: Double,
                                                t60: Double)] = [])
        -> BowKernelTables {
        var t = BowKernelTables(sr: sr)
        // ---- FORMULA TARAF voices (gutstring.formula_taraf lockstep) ----
        let zT = bp.v("bow_taraf_Z", 0.0)
        if !taraf.isEmpty, zT > 1e-9 {
            let pol = bp.v("bow_taraf_pol_cents", 0.0)
            let polG = bp.v("bow_taraf_pol_gain", 0.85)
            let polT = bp.v("bow_taraf_pol_t60", 1.0)
            var voices: [(f: Double, gain: Double, t60: Double)] = []
            for s in taraf {
                voices.append(s)
                if pol > 0.01 {
                    let frac = (Double(voices.count) * 0.61803398875)
                        .truncatingRemainder(dividingBy: 1.0)
                    let split = pol * (0.6 + 0.8 * frac)
                    voices.append((s.f * pow(2.0, split / 1200.0),
                                   s.gain * polG, s.t60 * polT))
                }
            }
            let gLin = bp.v("bow_taraf_gain", 1.0)
                / Double(voices.count).squareRoot()
            let ws = voices.map { gLin * $0.gain }
            let wMean = ws.reduce(0, +) / Double(ws.count)
            let t60s = bp.v("bow_taraf_t60", 1.0)
            let cap = bp.v("bow_taraf_t60_cap", 8.0)
            let inh = bp.v("bow_taraf_inharm", 0.0)
            let dmp = bp.v("bow_taraf_damp", 0.0)
            let fc = min(1400.0 + bp.v("bow_taraf_bright", 0.5) * 6000.0,
                         0.45 * sr)
            let lpA = exp(-2.0 * Double.pi * fc / sr)
            let jaw = bp.v("bow_taraf_jawari", 0.0)
            for (v, w) in zip(voices, ws) {
                let t60 = min(v.t60 * t60s, cap)
                let (L, eta, c, s, g, _) = webLoopCoeffs(
                    f0: v.f, t60: t60, sr: sr, inharm: inh, damp: dmp)
                let c0 = (1.0 - s) * (1.0 - s)
                let c1 = 2.0 * s * (1.0 - s)
                let c2 = s * s
                let p = eta * c
                let ssum = eta + c
                t.L.append(Int32(L))
                t.cs.append(ssum)
                t.cp.append(p)
                t.w0.append(p * c0)
                t.w1.append(p * c1 + ssum * c0)
                t.w2.append(p * c2 + ssum * c1 + c0)
                t.w3.append(ssum * c2 + c1)
                t.w4.append(c2)
                t.g.append(g)
                t.lpA.append(lpA)
                t.wout.append(w)
                t.kap.append(0.0)          // passive junction: no κ drive
                t.alphaw.append(0.0)       // no played strings in the web
                let zi = zT * (w / wMean)
                t.zi.append(zi)
                t.zdrv.append(2.0 * zi / (1.0 - g))
                t.jw.append(jaw)
                t.jl.append(0.0)
                t.jn.append(0.0)
                t.twt.append(1.0)
                t.chg.append(0.0)          // cold start (live policy)
            }
        }
        // OPEN MAIN GUT STRINGS as sympathetics (2026-07-18l — the real
        // instrument's un-bowed thick-gut strings, mandra Pa (2/3) +
        // mandra Sa (1/2) of the tonic: the LF halo the steel web cannot
        // supply. Lockstep with gutstring.formula_open.
        let zO = bp.v("bow_open_Z", 0.0)
        let gO = bp.v("bow_open_gain", 0.0)
        if zO > 1e-9 && gO > 1e-9 {
            let t60o = bp.v("bow_open_t60", 2.5)
            let dmpO = bp.v("bow_open_damp", 0.85)
            let fcO = min(600.0 + bp.v("bow_open_bright", 0.25) * 4000.0,
                          0.45 * sr)
            let lpAO = exp(-2.0 * Double.pi * fcO / sr)
            let polO = bp.v("bow_open_pol_cents", 2.0)
            var ov: [(f: Double, w: Double)] = []
            for r in [2.0 / 3.0, 0.5] {
                let f = tonic * r
                ov.append((f, 1.0))
                if polO > 0.01 {
                    let frac = (Double(ov.count) * 0.61803398875)
                        .truncatingRemainder(dividingBy: 1.0)
                    ov.append((f * pow(2.0, polO * (0.6 + 0.8 * frac)
                                       / 1200.0), 0.85))
                }
            }
            let gLinO = gO / Double(ov.count).squareRoot()
            for v in ov {
                let w = gLinO * v.w
                let (L, eta, c, s, g, _) = webLoopCoeffs(
                    f0: v.f, t60: t60o, sr: sr, inharm: 0.0, damp: dmpO)
                let c0 = (1.0 - s) * (1.0 - s)
                let c1 = 2.0 * s * (1.0 - s)
                let c2 = s * s
                let p = eta * c
                let ssum = eta + c
                t.L.append(Int32(L))
                t.cs.append(ssum)
                t.cp.append(p)
                t.w0.append(p * c0)
                t.w1.append(p * c1 + ssum * c0)
                t.w2.append(p * c2 + ssum * c1 + c0)
                t.w3.append(ssum * c2 + c1)
                t.w4.append(c2)
                t.g.append(g)
                t.lpA.append(lpAO)
                t.wout.append(w)
                t.kap.append(0.0)
                t.alphaw.append(0.0)
                t.zi.append(zO * v.w)
                t.zdrv.append(2.0 * zO * v.w / (1.0 - g))
                t.jw.append(0.0)               // gut: no jawari
                t.jl.append(0.0)
                t.jn.append(0.0)
                t.twt.append(1.0)
                t.chg.append(0.0)
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
            // ringing-comb radiation tap (a passive junction cannot
            // radiate free decay), shaped by the formula body (tshape 1).
            // bow_taraf_tap_mix < 1 blends the RAW tap — the web's jawari
            // sparkle radiating directly (lockstep with gutstring
            // _string_scalars; 1.0 = legacy/shaped)
            t.L.isEmpty ? 0.0 : bp.v("bow_taraf_dir", 0.0),
            t.L.isEmpty ? 0.0 : 1.0,                   // tshape
            bp.v("bow_taraf_tap_mix", 1.0),            // tmix (1 = shaped)
            bp.v("bow_noise", 0.0),
            bp.v("bow_tnoise", 0.0),
            bp.v("bow_noise_pow", 1.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_hi", 8590.0) / sr),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_lo", 402.0) / sr),
            bp.v("bow_noise_dir", 0.0),
            1.0 - exp(-2.0 * Double.pi * bp.v("bow_noise_dir_hi", 6000.0) / sr),
            t.L.isEmpty ? 0.0 : 1.0,                   // PASSIVE wave junction
            bp.v("bow_gut_g", 1.0),
            bp.v("bow_disp_n", 1.0),
            bp.v("bow_nail_k", 0.0),
            tonic,                                     // f0Open
            bp.v("bow_gut_fc2", 0.0) > 0.0
                ? exp(-2.0 * Double.pi * bp.v("bow_gut_fc2", 0.0) / sr) : 0.0,
            bp.v("bow_taraf_duck", 1.0),               // driven tap duck (1 = off)
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
        ]
        return t
    }
}
