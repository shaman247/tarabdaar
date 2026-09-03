import Foundation

/// The live artifact (tanpura_live.json, written by the offline exporter
/// — the one external procedure). Its pitch-calibration cents are
/// measured at the LIVE config: REGENERATE after ANY physics change.
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
        // 1-DOF jiva thread element; nil/0 = rigid bump baked into b
        public let thF: Double?
        public let thQ: Double?
        public let thK: Double?
        /// Per-role physical overrides for the sitar's scale-model role
        /// ladder (scaled copies of the anchor); nil = the globals.
        public let t60hf: Double?      // HF-damping t60 reference (s)
        public let fhf: Double?        // HF-damping corner (Hz)
        public let radius: Double?     // bone lengthwise curvature (m)
        public let kc: Double?         // contact stiffness
        public let polRt: Double?      // transverse bone curvature (m)
        /// Contact-zone width (L units); the modal blur 1/M must stay
        /// under it or the contact self-oscillates (bench-set per rung).
        public let zoneW: Double?
        /// Dynamic modal bandwidth (Hz): mount every representable mode
        /// below it (no mMin floor — aliased modes wreck the cascade).
        public let mDyn: Double?
        /// Mode-count ceiling with `mDyn` (the anchor's count).
        public let mCap: Int?
    }
    public struct Pol: Codable, Sendable {
        public let cents: Double       // v/w detune
        public let g: Double           // global mix
        public let thDeg: Double       // pluck angle from vertical
        public let rt: Double          // transverse bone curvature (m)
    }
    public let sr: Double
    /// internal simulation rate (96k — the contact runs away at 48k)
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
    public let rampCycles: Double?     // pluck draw ramp (string periods;
                                       // the ladder's 1.0 = STABILITY law)
    public let bodyFIR: [Double]       // min-phase body/capture EQ taps
    /// Radiation efficiency PER MODE INDEX for ladder roles (a scaled
    /// string radiates with the anchor's mode-k weighting); readout-only.
    public let radByMode: [Double]?

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(TanpuraParams.self,
                                                from: data)
        else { return nil }
        self = p
    }
}

/// One note's kernel tables — the Swift twin of the exporter's
/// build_tables (formulas VERBATIM; the parity golden guards it).
public struct TanpuraNoteTables: Sendable {
    public var M: Int
    public var J: Int
    public var ca: [Double], cb: [Double], ca4: [Double], cb4: [Double]
    public var ca2: [Double], cb2: [Double]   // dt/2 rotation
    public var cas: [Double], cbs: [Double], wd: [Double]
    public var caw: [Double], cbw: [Double], wdw: [Double]
    public var phi: [Double], phiF: [Double]
    public var b: [Double], g: [Double], g4: [Double]
    public var gd: [Double], gd4: [Double]
    public var phiO: [Double], dq: [Double]
    public var gTh: [Double]           // thread footprint
    public var thBase: Double, thH: Double
    public var thF: Double, thQ: Double, thK: Double
    public var deep: Double
    public var dt: Double
    public var pluck: Double
    /// Per-note contact stiffness (`Role.kc`; default `p.kc`).
    public var kc: Double
    /// Per-note transverse bone curvature (`Role.polRt`; default `p.pol.rt`).
    public var polRt: Double
}

public enum TanpuraTables {
    public static func role(for f0: Double, in p: TanpuraParams)
        -> TanpuraParams.Role {
        for r in p.roles where f0 <= r.fmax { return r }
        return p.roles[p.roles.count - 1]
    }

    // MARK: - Register calibration
    //
    // Higher slots at the fitted thread geometry (top 9.75 μm above the
    // apex) fall out of the sustained-graze regime that makes the jawari,
    // so each slot targets a bench-set thread-top height (μm) instead:
    private static let regCompHz: [Double] = [104, 140, 156, 176, 208, 262]
    private static let regCompH: [Double] = [9.75, 9.15, 8.25, 7.95,
                                             7.80, 6.75]  // μm above apex

    /// Thread-height multiplier: interpolates the targets in log-frequency
    /// (flat below 104 Hz; −2.25 μm/oct past 262 Hz, floor 5.5 μm); `comp`
    /// blends fitted → target. Re-bench after a thread-geometry change.
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

    // MARK: - Cascade slowing (`tp_cascade`)
    //
    // Higher slots cascade faster in wall-clock terms (conversion per
    // graze pass, at f0); a further thread lift plus an HF-damping
    // stretch slow it, both graded by log2(f0/104) from the anchor.

    /// Cascade thread lift as a threadHMul ADDEND (compose with
    /// `registerCompThreadMul`; clamp the sum at 1.0 — high slots die past it).
    public static func cascadeThreadLift(f0: Double, cascade: Double,
                                         p: TanpuraParams) -> Double {
        guard cascade > 0, f0 > 104.0 else { return 0.0 }
        let r = role(for: f0, in: p)
        guard r.threadH > 0 else { return 0.0 }
        let dH = cascade * 0.75e-6 * log2(f0 / 104.0)
        return dH / r.threadH
    }

    /// Cascade HF-sustain stretch: multiplies `t60hf` per slot.
    public static func cascadeHFT60Mul(f0: Double,
                                       cascade: Double) -> Double {
        guard cascade > 0, f0 > 104.0 else { return 1.0 }
        return 1.0 + cascade * log2(f0 / 104.0)
    }

    /// Build one note's tables at the DESIRED `f0Sounding` (the wrap-pull
    /// `cents` is applied here). `threadHMul` scales the jiva thread height
    /// (baked into `b`, so a lift shifts the wrap slightly); `hfT60Mul`
    /// stretches `t60hf`; 1 = bit-exact for both.
    public static func buildNote(f0Sounding: Double, cents: Double,
                                 p: TanpuraParams,
                                 threadHMul: Double = 1.0,
                                 hfT60Mul: Double = 1.0) -> TanpuraNoteTables {
        let r = role(for: f0Sounding, in: p)
        let f0 = f0Sounding * pow(2.0, -cents / 1200.0)
        let L = 1.0
        let MU = Double.pi * r.R * r.R * r.rho
        let B = r.refB * (r.refF / f0Sounding) * (r.refF / f0Sounding)
        // Mode count: ladder roles (mDyn) mount every representable mode
        // below the band, no mMin floor; tanpura roles use mF/f0.
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
        // t600 is calibrated AT refF; notes above decay ~(refF/f0)^1.5.
        // Per-role HF overrides put a scaled string's Q(f) at its register.
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
        // bone profile + jiva thread (thF > 0: the moving 1-DOF element)
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
        // Ladder roles radiate only the `p.mF` band — modes above it
        // (mounted for the energy budget) stay silent at the readout.
        if r.mDyn != nil {
            let toSounding = pow(2.0, cents / 1200.0)
            for k in 0..<M
                where w0[k] / (2.0 * Double.pi) * toSounding > p.mF {
                phiO[k] = 0.0
            }
            // scaled-body radiation (see `radByMode`)
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
            // round pi*x/L ONCE, then scale by k (the exporter's association)
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
