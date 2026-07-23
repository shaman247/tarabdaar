import XCTest
@testable import SarangiKit

/// v57 live port: the coupled-mode DIRECT taraf-velocity radiation tap
/// (`N_taraf_dir` + 2nd-order `N_taraf_dir_lp`, params-carried — the preset
/// owns it; sarangi_coupled.json must stay tap-free for the bow tables).
/// The tap is OUTPUT-ONLY (outside the bridge loop): out += ½·dirg·LP²(bL+bR)
/// per channel ahead of the radiation FIR/E_lp — the causal twin of
/// coupled.py's zero-phase `dirg·_dir_lp·RH·Vsum·V`.
final class CoupledTapTests: XCTestCase {
    static let sr = 48000.0
    static let n = 48000            // 1 s

    private func makeEngine(_ extra: [String: Double]) -> SarangiEngine {
        var cfg = CoupledConfig()
        cfg.modes = [(210.0, 12.0), (620.0, 7.0), (1450.0, 6.0), (2600.0, 5.0)]
        cfg.resA = [0.5, 1.0, 0.8, 0.7]
        cfg.resC = [0.5, 1.0, -0.8, 0.7]
        cfg.junction = "passive"
        cfg.zTaraf = 0.004
        cfg.zPlayed = 0.0025
        var p = SarangiParams.defaults
        p["B_gain"] = 1.2
        p["B_damp"] = 0.6
        p["F_mix"] = 0.0
        p["mix_drone"] = 0.0
        p["E_lp"] = 20000.0
        p["sym_bow_follow"] = 0.0
        for (k, v) in extra { p[k] = v }
        let strings = [
            ResolvedString(freq: 233.08, gain: 1.0, t60: 1.2, bright: false),
            ResolvedString(freq: 311.13, gain: 1.0, t60: 1.5, bright: false),
            ResolvedString(freq: 466.16, gain: 0.9, t60: 0.8, bright: true),
        ]
        return SarangiEngine(params: p, strings: strings, tonic: 311.13,
                             sr: Self.sr, coupled: cfg)
    }

    /// Deterministic noise burst (0.2 s) — same shape as the coupled golden.
    private func burstInput() -> [Double] {
        var g = SeededGaussian(seed: 11)
        var x = [Double](repeating: 0, count: Self.n)
        let nb = Int(0.2 * Self.sr)
        var mean = 0.0
        for i in 0..<nb { x[i] = 0.1 * g.normal(sigma: 1.0); mean += x[i] }
        mean /= Double(nb)
        for i in 0..<nb { x[i] -= mean }
        return x
    }

    /// dirg = 0 (explicit) must be byte-identical to the tap key being absent
    /// — the pre-port render path is unchanged for every existing preset.
    func testTapOffIsIdentity() {
        let x = burstInput()
        let (l0, r0) = makeEngine([:]).renderOffline(x)
        let (l1, r1) = makeEngine(["N_taraf_dir": 0.0]).renderOffline(x)
        for i in stride(from: 0, to: Self.n, by: 7) {
            XCTAssertEqual(l0[i], l1[i])
            XCTAssertEqual(r0[i], r1[i])
        }
    }

    /// The tap adds energy, equally to L and R (centre-panned mono).
    func testTapAddsCentredRing() {
        let x = burstInput()
        let (l0, r0) = makeEngine([:]).renderOffline(x)
        let (l1, r1) = makeEngine(["N_taraf_dir": 0.02,
                                   "N_taraf_dir_lp": 900.0]).renderOffline(x)
        var dl = 0.0, maxAsym = 0.0
        for i in 0..<Self.n {
            let tl = l1[i] - l0[i]
            let tr = r1[i] - r0[i]
            dl += tl * tl
            maxAsym = max(maxAsym, abs(tl - tr))
        }
        XCTAssertGreaterThan(dl, 0, "tap contributed nothing")
        XCTAssertLessThan(maxAsym, 1e-12, "tap must be centre-panned")
    }

    /// The LP shaping: diff(lp=900) and diff(lp=0/unshaped) are the SAME
    /// signal through the 2×one-pole cascade vs unity, so their spectral
    /// ratio must equal the cascade's digital magnitude |H1(ω)|² bin-exactly
    /// (checked band-averaged, well above the numeric floor).
    func testTapLowpassMagnitude() {
        let x = burstInput()
        let (l0, _) = makeEngine([:]).renderOffline(x)
        let (lA, _) = makeEngine(["N_taraf_dir": 0.02,
                                  "N_taraf_dir_lp": 900.0]).renderOffline(x)
        let (lB, _) = makeEngine(["N_taraf_dir": 0.02,
                                  "N_taraf_dir_lp": 0.0]).renderOffline(x)
        var dA = [Double](repeating: 0, count: Self.n)
        var dB = [Double](repeating: 0, count: Self.n)
        for i in 0..<Self.n {
            dA[i] = lA[i] - l0[i]            // LP-shaped tap component
            dB[i] = lB[i] - l0[i]            // unshaped tap component
        }
        // dA and dB are the SAME signal through the cascade vs unity, so at
        // every frequency |DTFT(dA)/DTFT(dB)| = |H1|² exactly (up to the
        // truncated ring tail past 1 s — allow 0.5 dB).
        let a = exp(-2.0 * Double.pi * 900.0 / Self.sr)
        for f in [300.0, 900.0, 2400.0] {
            let w = 2.0 * Double.pi * f / Self.sr
            let mA = dtftMag(dA, w)
            let mB = dtftMag(dB, w)
            let h1sq = (1 - a) * (1 - a) / (1 - 2 * a * cos(w) + a * a)
            XCTAssertEqual(20 * log10(mA / mB), 20 * log10(h1sq),
                           accuracy: 0.5, "LP magnitude off at \(f) Hz")
        }
    }

    private func dtftMag(_ x: [Double], _ w: Double) -> Double {
        var re = 0.0, im = 0.0
        for i in 0..<x.count {
            re += x[i] * cos(w * Double(i))
            im -= x[i] * sin(w * Double(i))
        }
        return (re * re + im * im).squareRoot()
    }
}
