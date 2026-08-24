import Foundation

/// The r7 tanpura model's live artifact (params/tanpura_live.json,
/// written by scripts/export_tanpura_live.py): string-construction
/// laws per register role, shared bridge geometry, the round-6/7
/// polarization config, the per-note pitch-calibration cents (the
/// static wrap pulls pitch +10..+31 c across the keyboard — measured
/// at the LIVE config by the exporter; REGENERATE after ANY physics
/// or live-config change, the recal law), and the body EQ FIR.
public struct TanpuraParams: Codable, Sendable {
    public struct Role: Codable, Sendable {
        public let name: String
        public let fmax: Double        // role applies for f0 <= fmax
        public let R: Double           // string radius (m)
        public let rho: Double         // material density
        public let refF: Double        // reference f0 of the fitted B
        public let refB: Double        // inharmonicity at refF
        public let apex: Double        // bone protrusion (m)
        public let threadDx: Double    // jiva thread offset (m)
        public let threadH: Double     // jiva thread height (m)
        public let pluck: Double       // total pluck displacement (m)
        public let t600: Double        // fundamental t60 (s)
        // THREAD ELEMENT (round 11): 1-DOF jiva oscillator; nil/0 =
        // legacy rigid bump
        public let thF: Double?
        public let thQ: Double?
        public let thK: Double?
        /// Per-role PHYSICAL overrides (2026-08-20, the sitar's
        /// scale-model role ladder — each register string is a
        /// geometrically scaled copy of the fitted C3 anchor, so its
        /// HF-damping curve, bone curvature, contact stiffness and
        /// transverse polarization radius scale WITH it). nil falls
        /// back to the artifact globals (the tanpura's roles carry
        /// none of these — its build is byte-identical).
        public let t60hf: Double?      // HF-damping t60 reference (s)
        public let fhf: Double?        // HF-damping corner (Hz)
        public let radius: Double?     // bone lengthwise curvature (m)
        public let kc: Double?         // contact stiffness
        public let polRt: Double?      // transverse bone curvature (m)
        /// Contact-zone width (normalized L units). Short strings see a
        /// RELATIVELY wider bridge contact (the bridge does not shrink
        /// with the string), and the modal blur 1/M must stay under the
        /// zone or the under-resolved contact self-oscillates — the
        /// upper rungs carry bench-set widths.
        public let zoneW: Double?
        /// Dynamic modal bandwidth (Hz): mount every mode below it that
        /// the sim can represent — modes past the SIM Nyquist alias
        /// inside the rotation tables and wreck the cascade, so this
        /// replaces the mMin contact floor for ladder roles. Radiation
        /// stays banded at `p.mF` (phiO zeroed above — the same
        /// anti-alias law the bend path applies).
        public let mDyn: Double?
        /// Mode-count ceiling with `mDyn` (the anchor string's count —
        /// the energy budget the varispeed source had).
        public let mCap: Int?
    }
    public struct Pol: Codable, Sendable {
        public let cents: Double       // v/w detune
        public let g: Double           // global mix (FALSIFIED — 0)
        public let thDeg: Double       // pluck angle from vertical
        public let rt: Double          // transverse bone curvature (m)
    }
    public let sr: Double
    /// internal simulation rate (r29-live: 96k — the 48k contact
    /// rate RUNS AWAY at the r29 graze); nil = sr (legacy)
    public let srSim: Double?
    public let J: Int
    public let zoneW: Double
    public let radius: Double          // bone lengthwise curvature (m)
    public let threadW: Double
    public let kc: Double
    public let alpha: Double
    public let hcB: Double
    public let t60hf: Double
    public let fhf: Double
    public let mF: Double              // M = mF / f0 (mode-count law)
    public let mMin: Int
    public let mMax: Int
    public let pluckPos: Double
    public let pol: Pol
    public let roles: [Role]
    public let noteLo: Int
    public let noteHi: Int
    public let pitchCents: [Double]    // per note (noteLo...noteHi)
    public let settleS: Double
    public let gain: Double            // output trim
    public let revMix: Double
    public let revRT60: Double
    public let revPredelayMs: Double
    public let pluckRefF: Double       // high notes plucked gentler:
    public let pluckExp: Double        // amp *= min(1,(refF/f0)^exp)
    public let rampCycles: Double?     // round-13 draw ramp (periods)
    public let bodyFIR: [Double]       // min-phase body/capture EQ taps
    // (2026-08-20: the one-day `tapeRefF`/`srcBodyFIR` varispeed law
    // switches are GONE — the sitar's scale-model similarity now lives
    // entirely in its role ladder's per-role physical overrides above.
    // Varispeed was the prototype, the ladder is the instrument.)
    /// Radiation efficiency PER MODE INDEX for ladder roles (nil for
    /// the tanpura). Scale-model similarity applies to the body too:
    /// each register string is a proportionally smaller instrument, so
    /// its mode k radiates with the anchor instrument's mode-k
    /// weighting — one shared array (|H_anchor(k·f_anchor)|), constant
    /// across the ladder. The measured alternative — one fixed-
    /// frequency body for all strings — deviates from the prototype by
    /// ±12 dB on single harmonics (the anchor body's 392 Hz notch
    /// lands on h3 of EVERY cell). Applied at the readout only, like
    /// `quiet`; `bodyFIR` is then the identity.
    public let radByMode: [Double]?

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(TanpuraParams.self,
                                                from: data)
        else { return nil }
        self = p
    }
}

/// One note's kernel tables — the Swift LOCKSTEP twin of
/// `tanpura_model.build_tables` (keep formulas VERBATIM; the parity
/// golden guards it).
public struct TanpuraNoteTables: Sendable {
    public var M: Int
    public var J: Int
    public var ca: [Double], cb: [Double], ca4: [Double], cb4: [Double]
    public var ca2: [Double], cb2: [Double]   // dt/2 (live x2 deep)
    public var cas: [Double], cbs: [Double], wd: [Double]
    public var caw: [Double], cbw: [Double], wdw: [Double]
    public var phi: [Double], phiF: [Double]
    public var b: [Double], g: [Double], g4: [Double]
    public var gd: [Double], gd4: [Double]
    public var phiO: [Double], dq: [Double]
    public var gTh: [Double]           // thread footprint (round 11)
    public var thBase: Double, thH: Double
    public var thF: Double, thQ: Double, thK: Double
    public var deep: Double
    public var dt: Double
    public var pluck: Double
    /// Per-note contact stiffness (2026-08-20, the scale-model role
    /// ladder): a scaled string's contact spring follows the
    /// similarity law, carried per role (`Role.kc`). Legacy roles:
    /// exactly `p.kc`.
    public var kc: Double
    /// Per-note transverse bone curvature (`Role.polRt` — a transverse
    /// length, it scales with the string). Legacy: `p.pol.rt`.
    public var polRt: Double
}

public enum TanpuraTables {
    public static func role(for f0: Double, in p: TanpuraParams)
        -> TanpuraParams.Role {
        for r in p.roles where f0 <= r.fmax { return r }
        return p.roles[p.roles.count - 1]
    }

    /// Build one note's tables. `f0Sounding` is the DESIRED pitch; the
    /// wrap pull correction (pitchCents) is applied here.
    ///
    /// `shaping` (2026-08-05, scale-shaped overtones) adjusts modes 3+
    /// — per-partial retune toward the scale + sustain tilt — BETWEEN
    /// the modal-frequency law and everything derived from it, so the
    /// rotations, the horizontal bank and the kernel's SAV response
    /// tables all see the shaped frequencies consistently. nil (or an
    /// inactive shaping) leaves this function byte-identical to the
    /// upstream lockstep formulas — the parity golden runs it at nil.
    // MARK: - Register calibration (2026-08-15)
    //
    // The fitted jiva geometry (thread top 9.75 μm above the bone apex)
    // puts the REFERENCE register (~65–131 Hz, where the artifact was
    // fitted against real strings) in the sustained-graze regime that
    // makes the jawari: slow laddered cascade, drive-independent speed.
    // Higher slots extrapolate that geometry and fall OUT of the graze —
    // measured buzz share drops from ~15% (104 Hz) to <1% (156/208 Hz),
    // and no pluck level brings it back (below the knee = dead, above =
    // slam: the whole cascade in ~0.2 s). The physical fix is the one a
    // tanpura player uses — adjust the thread per string. Bench-measured
    // thread-top-above-apex targets that reproduce the 104 Hz regime
    // (buzz ~15%, laddered t70s, pitch cost < 1 cent — the upper graze
    // window; the lower window ~4 μm buzzes too but costs −5…−7 cents):
    private static let regCompHz: [Double] = [104, 140, 156, 176, 208, 262]
    private static let regCompH: [Double] = [9.75, 9.15, 8.25, 7.95,
                                             7.80, 6.75]  // μm above apex

    /// The register-calibration thread-height multiplier for a slot:
    /// interpolates the measured targets in log-frequency (flat at the
    /// fitted geometry below 104 Hz; extended past 262 Hz at the fitted
    /// slope −2.25 μm/oct, floored at 5.5 μm well above the lower-regime
    /// cliff). `comp` blends fitted → full target (0 = exactly 1.0).
    /// The targets were measured at the current artifact's 9.75 μm
    /// fitted height; a regenerated artifact with different thread
    /// geometry scales proportionally but should be re-benched
    /// (`TanpuraCascadeBench`).
    public static func registerCompThreadMul(f0: Double, comp: Double,
                                             p: TanpuraParams) -> Double {
        guard comp > 0, f0 > regCompHz[0] else { return 1.0 }
        let r = role(for: f0, in: p)
        guard r.threadH > 0, p.radius > 0 else { return 1.0 }
        let drop = r.threadDx * r.threadDx / (2.0 * p.radius)
        let hFit = (r.threadH - drop) * 1e6           // μm above apex
        guard hFit > 0 else { return 1.0 }
        let lf = log2(f0)
        var hStar: Double
        if lf >= log2(regCompHz.last!) {
            hStar = max(regCompH.last!
                        - 2.25 * (lf - log2(regCompHz.last!)), 5.5)
        } else {
            var i = 0
            while i + 2 < regCompHz.count, log2(regCompHz[i + 1]) < lf {
                i += 1
            }
            let l0 = log2(regCompHz[i]), l1 = log2(regCompHz[i + 1])
            let t = (lf - l0) / (l1 - l0)
            hStar = regCompH[i] + t * (regCompH[i + 1] - regCompH[i])
        }
        let target = hStar * (hFit / 9.75)
        let h = hFit + comp * (target - hFit)
        return (h * 1e-6 + drop) / r.threadH
    }

    // MARK: - Cascade slowing (2026-08-15, `tp_cascade`)
    //
    // Even register-calibrated, higher slots develop their harmonic
    // cascade faster than the fitted register in wall-clock terms (the
    // contact converts on every graze pass, and passes come at f0).
    // Bench-measured levers that slow it while holding buzziness:
    // raise the thread slightly further toward the fitted height
    // (gentler graze → the instant mid-harmonic jump becomes a
    // ~1 s bloom; measured at 208 Hz: +0.75 μm took h4/h6 onset from
    // 0.14/0.23 s to 1.2/1.3 s) and stretch the ABSOLUTE-frequency HF
    // damping so the top of the cascade rings longer (recovers the
    // brightness the gentler graze costs; ×2 at 208 Hz measured buzz
    // 14.6% ≈ the 104 Hz anchor). Both graded by log2(f0/104) — zero
    // at and below the anchor, whose cascade is the reference.
    // (Probed and rejected: pluck-draw stretch — even 2 periods
    // cancels the note, the free-rotation draw law; drive reduction —
    // falls off the graze knee and kills the buzz before it slows.)

    /// The cascade gap-lift as a threadHMul ADDEND (compose with
    /// `registerCompThreadMul` and clamp the sum at 1.0 — the lift
    /// never pushes past the fitted geometry, where high slots die).
    public static func cascadeThreadLift(f0: Double, cascade: Double,
                                         p: TanpuraParams) -> Double {
        guard cascade > 0, f0 > 104.0 else { return 0.0 }
        let r = role(for: f0, in: p)
        guard r.threadH > 0 else { return 0.0 }
        let dH = cascade * 0.75e-6 * log2(f0 / 104.0)
        return dH / r.threadH
    }

    /// The cascade HF-sustain stretch: multiplies `t60hf` (the
    /// absolute-frequency high-partial damping reference) per slot.
    public static func cascadeHFT60Mul(f0: Double,
                                       cascade: Double) -> Double {
        guard cascade > 0, f0 > 104.0 else { return 1.0 }
        return 1.0 + cascade * log2(f0 / 104.0)
    }

    /// `threadHMul` (2026-08-15, register calibration): scales the jiva
    /// thread's height in the bone profile — the electronic twin of the
    /// player adjusting the cotton thread per string. 1 = the fitted
    /// geometry, byte-identical tables (the lockstep golden runs it
    /// at 1). The thread is baked into `b` (static mode, thF nil), so
    /// a lift DOES shift the settled wrap slightly — the register-
    /// calibration bench measured the pitch cost before this shipped.
    /// `hfT60Mul` (same day, cascade slowing): stretches the t60 law's
    /// HF reference (`t60hf`) for this slot — 1 is bit-exact.
    public static func buildNote(f0Sounding: Double, cents: Double,
                                 p: TanpuraParams,
                                 shaping: TanpuraShaping? = nil,
                                 slotSeed: UInt64 = 0,
                                 threadHMul: Double = 1.0,
                                 hfT60Mul: Double = 1.0) -> TanpuraNoteTables {
        let r = role(for: f0Sounding, in: p)
        let f0 = f0Sounding * pow(2.0, -cents / 1200.0)
        let L = 1.0
        let MU = Double.pi * r.R * r.R * r.rho
        let B = r.refB * (r.refF / f0Sounding) * (r.refF / f0Sounding)
        // Mode count: ladder roles (mDyn set) mount every mode the sim
        // can hold below the dynamic band, capped at the anchor count —
        // NO mMin floor (it would force modes past the sim Nyquist,
        // which alias in the rotations and drain the cascade); legacy
        // roles keep the tanpura law byte-identically.
        let M: Int
        if let mDyn = r.mDyn {
            var m = 0
            let cap = min(r.mCap ?? p.mMax, p.mMax)
            while m < cap {
                let kk = Double(m + 1)
                let fk = f0Sounding * kk
                    * (1.0 + B * kk * kk).squareRoot()
                if fk >= mDyn { break }
                m += 1
            }
            M = max(8, m)
        } else {
            M = max(p.mMin, min(p.mMax, Int(p.mF / f0Sounding)))
        }
        let J = p.J
        let dt = 1.0 / (p.srSim ?? p.sr)
        var w0 = [Double](repeating: 0, count: M)
        var t60 = [Double](repeating: 0, count: M)
        // PITCH-SCALED t60 (2026-08-03, lockstep with export_tanpura_
        // live.note_tables): role t600s are calibrated AT refF;
        // notes above it decay ~(refF/f0)^1.5 (an 880 Hz note is not
        // a 100 s jodi). Reference pitches unchanged.
        // Per-role HF-damping overrides (2026-08-20, the sitar's
        // scale-model ladder): a geometrically scaled string's whole
        // Q(f) curve sits at its own register — nil = the globals
        // (every tanpura role), byte-identical.
        let t600 = r.t600 * pow(min(1.0, r.refF / f0Sounding), 1.5)
        let fhfEff = r.fhf ?? p.fhf
        let t60hfEff = r.t60hf ?? p.t60hf
        for k in 1...M {
            let wk = 2.0 * Double.pi * f0 * Double(k)
                * (1.0 + B * Double(k) * Double(k)).squareRoot()
            w0[k - 1] = wk
            let fk = wk / (2.0 * Double.pi)
            t60[k - 1] = 1.0 / (1.0 / t600
                + (fk / fhfEff) * (fk / fhfEff)
                    * (1.0 / (t60hfEff * hfT60Mul)))
        }
        // per-mode radiated-gain multipliers from `quiet`, applied to
        // phiO below once it exists (nil = all 1 — the common case)
        var shapeOutMul: [Double]? = nil
        if let sh = shaping, sh.isActive, M > 2 {
            // modes 1–2 pin the perceived pitch (and the pitchCents
            // calibration) — shape 3+ only. w0 is at the MOUNT pitch
            // (pre-corrected flat); the scale lives in SOUNDING space,
            // so measure there and apply the ratio back on w0.
            let toSounding = pow(2.0, cents / 1200.0)
            var om = [Double](repeating: 1.0, count: M)
            var omActive = false
            for i in 2..<M {
                let fk = w0[i] / (2.0 * Double.pi) * toSounding
                let (ratio, t60Mul, outMul) = sh.modeAdjust(
                    fSounding: fk, mode: i + 1, slotSeed: slotSeed)
                w0[i] *= ratio
                t60[i] *= t60Mul
                om[i] = outMul
                if outMul != 1.0 { omActive = true }
            }
            if omActive { shapeOutMul = om }
        }
        let sig = t60.map { 6.91 / $0 }
        // contact zone
        var xz = [Double](repeating: 0, count: J)
        let zoneW = r.zoneW ?? p.zoneW
        let boneR = r.radius ?? p.radius
        let x0 = L - zoneW, x1 = L - 0.0008
        for j in 0..<J {
            xz[j] = J == 1 ? x0
                : x0 + (x1 - x0) * Double(j) / Double(J - 1)
        }
        let wj = xz[1] - xz[0]
        var phi = [Double](repeating: 0, count: M * J)
        for k in 0..<M {
            for j in 0..<J {
                phi[k * J + j] = (2.0 / L).squareRoot()
                    * sin(Double(k + 1) * Double.pi * xz[j] / L)
            }
        }
        // G = (dt^2/2) Phi^T Phi wj / MU
        var g = [Double](repeating: 0, count: J * J)
        let cG = dt * dt / 2.0 * wj / MU
        for i in 0..<J {
            for j in 0..<J {
                var acc = 0.0
                for k in 0..<M { acc += phi[k * J + i] * phi[k * J + j] }
                g[i * J + j] = cG * acc
            }
        }
        var gd = [Double](repeating: 0, count: J)
        for j in 0..<J { gd[j] = g[j * J + j] }
        let g4 = g.map { $0 / 16.0 }
        let gd4 = gd.map { $0 / 16.0 }
        // bone profile + jiva thread (round 11: thF > 0 splits the
        // thread into the moving 1-DOF element — LOCKSTEP with
        // tanpura_model.build_tables)
        let xApex = L - 0.0015
        var b = [Double](repeating: 0, count: J)
        for j in 0..<J {
            let d = xz[j] - xApex
            b[j] = r.apex - d * d / (2.0 * boneR)
        }
        let thBase = r.apex - r.threadDx * r.threadDx / (2.0 * boneR)
        var gTh = [Double](repeating: 0, count: J)
        let thF = r.thF ?? 0.0
        if r.threadH > 0 {
            if thF > 0 {
                for j in 0..<J {
                    let z = (xz[j] - (xApex - r.threadDx)) / p.threadW
                    gTh[j] = exp(-0.5 * z * z)
                }
            } else {
                for j in 0..<J {
                    let z = (xz[j] - (xApex - r.threadDx)) / p.threadW
                    b[j] = max(b[j], thBase + r.threadH * threadHMul
                               * exp(-0.5 * z * z))
                }
            }
        }
        var phiO = [Double](repeating: 0, count: M)
        let xO = 0.90 * L
        for k in 0..<M {
            phiO[k] = (2.0 / L).squareRoot()
                * sin(Double(k + 1) * Double.pi * xO / L)
        }
        // `quiet`: cut misaligned partials at the READOUT only — the
        // modes keep their full part in the contact dynamics
        if let om = shapeOutMul {
            for k in 0..<M { phiO[k] *= om[k] }
        }
        // Ladder roles: RADIATE only the `p.mF` band — the modes above
        // it (mounted for the dynamic energy budget) stay silent at the
        // readout instead of aliasing into the output. Same law the
        // bend path applies past Nyquist; readout-only like `quiet`.
        if r.mDyn != nil {
            let toSounding = pow(2.0, cents / 1200.0)
            for k in 0..<M
                where w0[k] / (2.0 * Double.pi) * toSounding > p.mF {
                phiO[k] = 0.0
            }
            // scaled-body radiation: mode k radiates with the anchor
            // instrument's mode-k weighting (see `radByMode`)
            if let rad = p.radByMode, !rad.isEmpty {
                for k in 0..<M {
                    phiO[k] *= rad[min(k, rad.count - 1)]
                }
            }
        }
        // rotations
        func rot(_ dtv: Double, damp: Double? = nil)
            -> ([Double], [Double], [Double]) {
            var ca = [Double](repeating: 0, count: M)
            var cb = [Double](repeating: 0, count: M)
            var wd = [Double](repeating: 0, count: M)
            for k in 0..<M {
                let sg = damp ?? sig[k]
                let wdk = max(w0[k] * w0[k] - sig[k] * sig[k], 1e-6)
                    .squareRoot()
                wd[k] = wdk
                ca[k] = exp(-sg * dtv) * cos(wdk * dtv)
                cb[k] = exp(-sg * dtv) * sin(wdk * dtv)
            }
            return (ca, cb, wd)
        }
        let (ca, cb, wd) = rot(dt)
        let (ca4, cb4, _) = rot(dt / 4.0)
        let (ca2, cb2, _) = rot(dt / 2.0)
        let (cas, cbs, _) = rot(dt, damp: 2000.0)
        // horizontal bank (detuned by pol.cents)
        let dw = pow(2.0, -p.pol.cents / 1200.0)
        var caw = [Double](repeating: 0, count: M)
        var cbw = [Double](repeating: 0, count: M)
        var wdw = [Double](repeating: 0, count: M)
        for k in 0..<M {
            let w0w = w0[k] * dw
            let wdk = max(w0w * w0w - sig[k] * sig[k], 1e-6)
                .squareRoot()
            wdw[k] = wdk
            caw[k] = exp(-sig[k] * dt) * cos(wdk * dt)
            cbw[k] = exp(-sig[k] * dt) * sin(wdk * dt)
        }
        // triangular pluck shape at pluckPos (unit amplitude)
        let ns = 400
        var dq = [Double](repeating: 0, count: M)
        let xsLo = 0.001, xsHi = L - zoneW - 0.005
        let dxs = (xsHi - xsLo) / Double(ns - 1)
        let ctr = p.pluckPos * L
        for i in 0..<ns {
            let x = xsLo + dxs * Double(i)
            var tri = x <= ctr ? x / ctr
                : (L - zoneW - x) / (L - zoneW - ctr)
            tri = max(tri, 0.0)
            // association matches numpy's outer(k, pi*x/L): round
            // pi*x/L ONCE, then scale by k — at k~340 the argument is
            // ~1e3 rad and a different association costs ~1e-9 rel
            let ax = Double.pi * x / L
            for k in 0..<M {
                dq[k] += (2.0 / L).squareRoot()
                    * sin(Double(k + 1) * ax) * tri * dxs
            }
        }
        var phiF = [Double](repeating: 0, count: M * J)
        for i in 0..<(M * J) { phiF[i] = phi[i] * wj / MU }
        return TanpuraNoteTables(
            M: M, J: J, ca: ca, cb: cb, ca4: ca4, cb4: cb4,
            ca2: ca2, cb2: cb2,
            cas: cas, cbs: cbs, wd: wd, caw: caw, cbw: cbw, wdw: wdw,
            phi: phi, phiF: phiF, b: b, g: g, g4: g4, gd: gd, gd4: gd4,
            phiO: phiO, dq: dq,
            gTh: gTh, thBase: thBase,
            thH: thF > 0 ? r.threadH * threadHMul : 0.0,
            thF: thF, thQ: r.thQ ?? 3.0, thK: r.thK ?? 1e4,
            deep: 1.5 * max(r.apex, 1e-6), dt: dt,
            pluck: r.pluck,
            kc: r.kc ?? p.kc,
            polRt: r.polRt ?? p.pol.rt)
    }
}
