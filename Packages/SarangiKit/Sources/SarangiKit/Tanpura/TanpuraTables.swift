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
    public static func buildNote(f0Sounding: Double, cents: Double,
                                 p: TanpuraParams,
                                 shaping: TanpuraShaping? = nil,
                                 slotSeed: UInt64 = 0) -> TanpuraNoteTables {
        let r = role(for: f0Sounding, in: p)
        let f0 = f0Sounding * pow(2.0, -cents / 1200.0)
        let L = 1.0
        let MU = Double.pi * r.R * r.R * r.rho
        let B = r.refB * (r.refF / f0Sounding) * (r.refF / f0Sounding)
        let M = max(p.mMin, min(p.mMax, Int(p.mF / f0Sounding)))
        let J = p.J
        let dt = 1.0 / (p.srSim ?? p.sr)
        var w0 = [Double](repeating: 0, count: M)
        var t60 = [Double](repeating: 0, count: M)
        // PITCH-SCALED t60 (2026-08-03, lockstep with export_tanpura_
        // live.note_tables): role t600s are calibrated AT refF;
        // notes above it decay ~(refF/f0)^1.5 (an 880 Hz note is not
        // a 100 s jodi). Reference pitches unchanged.
        let t600 = r.t600 * pow(min(1.0, r.refF / f0Sounding), 1.5)
        for k in 1...M {
            let wk = 2.0 * Double.pi * f0 * Double(k)
                * (1.0 + B * Double(k) * Double(k)).squareRoot()
            w0[k - 1] = wk
            let fk = wk / (2.0 * Double.pi)
            t60[k - 1] = 1.0 / (1.0 / t600
                + (fk / p.fhf) * (fk / p.fhf) * (1.0 / p.t60hf))
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
        let x0 = L - p.zoneW, x1 = L - 0.0008
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
            b[j] = r.apex - d * d / (2.0 * p.radius)
        }
        let thBase = r.apex - r.threadDx * r.threadDx / (2.0 * p.radius)
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
                    b[j] = max(b[j], thBase + r.threadH
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
        let xsLo = 0.001, xsHi = L - p.zoneW - 0.005
        let dxs = (xsHi - xsLo) / Double(ns - 1)
        let ctr = p.pluckPos * L
        for i in 0..<ns {
            let x = xsLo + dxs * Double(i)
            var tri = x <= ctr ? x / ctr
                : (L - p.zoneW - x) / (L - p.zoneW - ctr)
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
            thH: thF > 0 ? r.threadH : 0.0,
            thF: thF, thQ: r.thQ ?? 3.0, thK: r.thK ?? 1e4,
            deep: 1.5 * max(r.apex, 1e-6), dt: dt,
            pluck: r.pluck)
    }
}
