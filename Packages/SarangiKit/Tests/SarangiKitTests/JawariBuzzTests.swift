import XCTest
@testable import SarangiKit

/// Per-class taraf jawari buzz (the "row+buzz mid" adoption, 2026-07-12):
/// causal twin of blocks._string_jawari_sus applied to the RADIATED force
/// copy only — the junction solve stays linear (zero stability impact),
/// the tap input stays the linear Σy. Depths are EAR-OWNED (N_jaw_raga >
/// N_jaw_chrom per the it22 law); N_jaw_lp low-passes the buzz component.
final class JawariBuzzTests: XCTestCase {
    static let sr = 48000.0
    static let n = 48000

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
        p["B_bright"] = 0.5
        p["B_damp"] = 0.6
        p["F_mix"] = 0.0
        p["mix_drone"] = 0.0
        p["E_lp"] = 20000.0
        for (k, v) in extra { p[k] = v }
        let strings = [
            ResolvedString(freq: 233.08, gain: 1.0, t60: 1.2, bright: false, raga: false),
            ResolvedString(freq: 311.13, gain: 1.0, t60: 1.5, bright: false, raga: true),
            ResolvedString(freq: 466.16, gain: 0.9, t60: 0.8, bright: true, raga: true),
        ]
        return SarangiEngine(params: p, strings: strings, tonic: 311.13,
                             sr: Self.sr, coupled: cfg)
    }

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

    /// keys at 0 must be byte-identical to keys absent (data-gated).
    func testBuzzOffIsIdentity() {
        let x = burstInput()
        let (l0, r0) = makeEngine([:]).renderOffline(x)
        let (l1, r1) = makeEngine(["N_jaw_raga": 0.0, "N_jaw_chrom": 0.0])
            .renderOffline(x)
        for i in stride(from: 0, to: Self.n, by: 7) {
            XCTAssertEqual(l0[i], l1[i])
            XCTAssertEqual(r0[i], r1[i])
        }
    }

    /// Buzz adds energy, and the raga class buzzes MORE than chrom at equal
    /// depth assignment (the it22 law is per-string, not global).
    func testBuzzAddsAndClassSeparates() {
        let x = burstInput()
        let (l0, _) = makeEngine([:]).renderOffline(x)
        let (lr, _) = makeEngine(["N_jaw_raga": 0.4]).renderOffline(x)
        let (lc, _) = makeEngine(["N_jaw_chrom": 0.4]).renderOffline(x)
        func diffE(_ a: [Double]) -> Double {
            var e = 0.0
            for i in 0..<Self.n { let d = a[i] - l0[i]; e += d * d }
            return e
        }
        let er = diffE(lr), ec = diffE(lc)
        XCTAssertGreaterThan(er, 0)
        XCTAssertGreaterThan(ec, 0)
        // 2 of 3 toy strings are raga-class → raga-only buzz moves more
        XCTAssertGreaterThan(er, ec)
    }

    /// N_jaw_lp cuts the buzz's contribution to the top octaves. (The
    /// buzz delta radiates through the modal W — flat ≈c0 above the last
    /// mode, modal-boosted in the mids — so the delta is mid-dominated by
    /// design; the LP property is the MONOTONIC HF reduction, offline
    /// lockstep: python twin measures −7 dB @8-16k on the raw component.)
    func testBuzzLpShapesHF() {
        let x = burstInput()
        let (l0, _) = makeEngine([:]).renderOffline(x)
        let (lu, _) = makeEngine(["N_jaw_raga": 0.6, "N_jaw_chrom": 0.3,
                                  "N_jaw_lp": 0.0]).renderOffline(x)
        let (ls, _) = makeEngine(["N_jaw_raga": 0.6, "N_jaw_chrom": 0.3,
                                  "N_jaw_lp": 4000.0]).renderOffline(x)
        func hfDeltaEnergy(_ a: [Double]) -> Double {
            var e = 0.0
            for f in stride(from: 8500.0, to: 15500.0, by: 500.0) {
                let w = 2.0 * Double.pi * f / Self.sr
                var re = 0.0, im = 0.0
                for i in 0..<Self.n {
                    let d = a[i] - l0[i]
                    re += d * cos(w * Double(i))
                    im -= d * sin(w * Double(i))
                }
                e += re * re + im * im
            }
            return e
        }
        let eu = hfDeltaEnergy(lu)
        let es = hfDeltaEnergy(ls)
        XCTAssertGreaterThan(eu, 0)
        XCTAssertLessThan(es, 0.9 * eu,
                          "LP must monotonically cut the buzz's top octave")
    }
}