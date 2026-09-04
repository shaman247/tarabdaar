import Foundation
import CBowKernel

// The body's frequency response, evaluated from the tables the running
// kernel was built with — what the Mac Body tab draws. Display only:
// nothing here touches the render.
extension BowEngine {
    /// The formula body as three transfer magnitudes on one log-frequency
    /// grid, plus the mode list behind them.
    public struct BodyResponse: Sendable {
        /// One body mode as built: centre frequency, Q, and its signed
        /// radiation and (positive) admittance residues.
        public struct Mode: Sendable {
            public var hz: Double
            public var q: Double
            public var rad: Double
            public var adm: Double
        }
        /// Log-spaced grid, Hz.
        public var hz: [Double]
        /// Bridge force → radiated pressure through the modal bank plus the
        /// flat `c0` term, dB (20·log10), at the kernel rate.
        public var radDb: [Double]
        /// `radDb` after the radiation chain at the engine rate — the
        /// radiation LP/HP sections and the bridge hill; what leaves the
        /// instrument before the room. Same length; NaN above sr/2.
        public var chainDb: [Double]
        /// Bridge force → bridge velocity: `yinf` under the DC block plus the
        /// modal admittance, dB. The string's loop side.
        public var admDb: [Double]
        /// `radDb` smoothed over ±⅙ octave — the envelope the ear averages.
        public var radSmoothDb: [Double]
        public var modes: [Mode]
        /// The tuning tonic (Hz) the body was built for.
        public var tonicHz: Double
        /// Bridge return gain after the loop cap.
        public var kret: Double
        /// Ripple statistics of `radDb` over 300–6000 Hz: mean, std, min,
        /// max (dB) and local maxima per octave.
        public var meanDb: Double
        public var stdDb: Double
        public var minDb: Double
        public var maxDb: Double
        public var peaksPerOctave: Double
    }

    /// Evaluate the body from `tables` on `points` log-spaced bins between
    /// `fLo` and `fHi`. Allocates; call from the UI at poll rate only.
    public func bodyResponse(points: Int = 1024, fLo: Double = 40.0,
                             fHi: Double = 20000.0) -> BodyResponse {
        let t = tables
        let s = t.scalars
        let n = max(points, 2)
        let K = t.ba1.count
        var hz = [Double](repeating: 0, count: n)
        var rad = [Double](repeating: 0, count: n)
        var chain = [Double](repeating: 0, count: n)
        var adm = [Double](repeating: 0, count: n)
        // the kernel's 25 Hz DC block ahead of yinf (poly_load_scalars)
        let hpG = 0.5 * (1.0 + s.dcRho)
        for i in 0..<n {
            let f = fLo * pow(fHi / fLo, Double(i) / Double(n - 1))
            hz[i] = f
            let w = 2.0 * Double.pi * f / srk
            let z1 = Cx(cos(w), -sin(w))
            let z2 = z1 * z1
            let num = Cx(1, 0) - z2
            var r = Cx(s.c0, 0)
            let dcH = (Cx(hpG, 0) * (Cx(1, 0) - z1))
                / (Cx(1, 0) - z1 * s.dcRho)
            var y = dcH * s.yinf
            for k in 0..<K {
                let den = Cx(1, 0) - z1 * t.ba1[k] - z2 * t.ba2[k]
                let h = (num * t.bn0[k]) / den
                r = r + h * t.bC[k]
                y = y + h * t.bA[k]
            }
            rad[i] = Self.db(r.magnitude)
            adm[i] = Self.db(y.magnitude)
            if f < 0.5 * sr {
                var m = 1.0
                if let lp = radLp { m *= lp.magnitude(at: f, sr: sr) }
                for sec in radHP { m *= sec.magnitude(at: f, sr: sr) }
                if let h = radHill { m *= h.magnitude(at: f, sr: sr) }
                chain[i] = rad[i] + Self.db(m)
            } else {
                chain[i] = .nan
            }
        }
        // ±⅙-octave box smoothing in dB (bins are log-spaced: a fixed
        // bin half-width)
        let binsPerOct = Double(n - 1) / log2(fHi / fLo)
        let hw = max(1, Int((binsPerOct / 6.0).rounded()))
        var smooth = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - hw), b = min(n - 1, i + hw)
            var acc = 0.0
            for j in a...b { acc += rad[j] }
            smooth[i] = acc / Double(b - a + 1)
        }
        // modes back out of the section coefficients
        var modes: [BodyResponse.Mode] = []
        modes.reserveCapacity(K)
        for k in 0..<K {
            let R = max(-t.ba2[k], 1e-12).squareRoot()
            let c = min(1.0, max(-1.0, t.ba1[k] / (2.0 * R)))
            let th = acos(c)
            let f = th * srk / (2.0 * Double.pi)
            let q = R < 1.0 ? -Double.pi * f / (srk * log(R)) : .infinity
            modes.append(.init(hz: f, q: q, rad: t.bC[k], adm: t.bA[k]))
        }
        // ripple statistics, 300–6000 Hz
        var sum = 0.0, sum2 = 0.0, cnt = 0
        var mn = Double.infinity, mx = -Double.infinity, peaks = 0
        for i in 0..<n where hz[i] >= 300.0 && hz[i] <= 6000.0 {
            let v = rad[i]
            sum += v; sum2 += v * v; cnt += 1
            mn = min(mn, v); mx = max(mx, v)
            if i > 0, i < n - 1, v > rad[i - 1], v > rad[i + 1] { peaks += 1 }
        }
        let mean = cnt > 0 ? sum / Double(cnt) : 0
        let varc = cnt > 0 ? max(sum2 / Double(cnt) - mean * mean, 0) : 0
        return BodyResponse(
            hz: hz, radDb: rad, chainDb: chain, admDb: adm,
            radSmoothDb: smooth, modes: modes, tonicHz: s.f0Open,
            kret: s.kret, meanDb: mean, stdDb: varc.squareRoot(),
            minDb: cnt > 0 ? mn : 0, maxDb: cnt > 0 ? mx : 0,
            peaksPerOctave: Double(peaks) / log2(6000.0 / 300.0))
    }

    private static func db(_ m: Double) -> Double {
        20.0 * log10(max(m, 1e-9))
    }
}
