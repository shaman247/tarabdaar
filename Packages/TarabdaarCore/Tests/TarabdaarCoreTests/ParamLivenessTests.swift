import XCTest
import SarangiKit
@testable import TarabdaarCore

/// WHICH PARAMETERS COULD BE LIVE (2026-07-24 analysis).
///
/// A rebuild exists because `bow_[poly_]init` swallows the whole table set
/// at once. But the tables are not equally deep: `BowKernelTables` is a
/// pile of per-voice/body coefficient ARRAYS plus a flat 61-element
/// `scalars` vector of per-sample kernel constants. A parameter that only
/// moves `scalars` needs no tables at all — the kernel stores those in
/// plain fields it reads every sample, so a setter could write them in
/// place with no state reset, no pre-roll and no crossfade.
///
/// Rather than reading the builder and guessing, this classifies each
/// registry parameter EMPIRICALLY: perturb it, rebuild the tables, and see
/// what actually moved.
final class ParamLivenessTests: XCTestCase {

    private enum Tier: String {
        case scalarOnly   = "scalar"      // only `scalars` moved
        case coefficients = "coeffs"      // arrays moved, sizes unchanged
        case structural   = "structural"  // array SIZES changed
        case engineSide   = "no-tables"   // tables identical: read by BowEngine /
                                          // BowControlMapper, or the probe clamped
    }

    private func tables(_ bp: BowParams, taraf: [(f: Double, gain: Double, t60: Double)])
        -> BowKernelTables {
        var t = BowTables.buildOpenString(sr: 96000, tonic: 328.9, bp: bp)
        t.jt = BowTables.buildJawariTables(rows: taraf, srk: 96000, bp: bp)
        return t
    }

    func testClassifyEveryParameter() throws {
        guard let artifact = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // (no jt arming to set since 2026-08-02 — the taraf always builds)
        let base = artifact
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        let taraf = strings.filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        let ref = tables(base, taraf: taraf)

        func sizes(_ t: BowKernelTables) -> [Int] {
            [t.L.count, t.cs.count, t.w0.count, t.g.count, t.lpA.count,
             t.wout.count, t.kap.count, t.alphaw.count, t.jw.count,
             t.jl.count, t.jn.count, t.zdrv.count, t.zi.count, t.twt.count,
             t.ba1.count, t.ba2.count, t.bn0.count, t.bA.count, t.bC.count,
             t.scalars.count, t.jt?.M.count ?? 0, t.jt?.b.count ?? 0]
        }
        func arraysEqual(_ a: BowKernelTables, _ b: BowKernelTables) -> Bool {
            a.L == b.L && a.cs == b.cs && a.cp == b.cp && a.w0 == b.w0
                && a.w1 == b.w1 && a.w2 == b.w2 && a.w3 == b.w3
                && a.w4 == b.w4 && a.g == b.g && a.lpA == b.lpA
                && a.wout == b.wout && a.kap == b.kap
                && a.alphaw == b.alphaw && a.jw == b.jw && a.jl == b.jl
                && a.jn == b.jn && a.chg == b.chg && a.zdrv == b.zdrv
                && a.zi == b.zi && a.twt == b.twt
                && a.ba1 == b.ba1 && a.ba2 == b.ba2 && a.bn0 == b.bn0
                && a.bA == b.bA && a.bC == b.bC
                && a.jt?.b == b.jt?.b && a.jt?.G == b.jt?.G
                && a.jt?.ca == b.jt?.ca && a.jt?.phys == b.jt?.phys
        }

        var tiers: [Tier: [String]] = [:]
        for spec in ParamRegistry.all where spec.apply != .live {
            var probe = base
            let cur = probe.num[spec.key] ?? spec.def
            // a nudge that is meaningful but stays in the authored range
            var v = cur + max(abs(cur) * 0.2, (spec.hi - spec.lo) * 0.1)
            if v > spec.hi { v = max(spec.lo, cur - (spec.hi - spec.lo) * 0.1) }
            if let step = spec.step { v = (v / step).rounded() * step }
            guard abs(v - cur) > 1e-12 else { continue }
            probe.num[spec.key] = v
            let t = tables(probe, taraf: taraf)

            let tier: Tier
            if sizes(t) != sizes(ref) {
                tier = .structural
            } else if !arraysEqual(t, ref) {
                tier = .coefficients
            } else if t.scalars != ref.scalars {
                tier = .scalarOnly
            } else {
                tier = .engineSide
            }
            tiers[tier, default: []].append(spec.key)
        }

        var report = "PARAMETER LIVENESS (what a change actually moves)\n"
        let order: [(Tier, String)] = [
            (.scalarOnly, "only the 61 kernel scalars -> a setter makes these live NOW"),
            (.engineSide, "no table movement -> read by BowEngine/BowControlMapper (live via Swift setters), OR the probe was clamped (e.g. bow_kret hits the loop-gain cap) — confirm per key"),
            (.coefficients, "coefficient arrays, SAME sizes -> live if the kernel can reload arrays in place"),
            (.structural, "array SIZES change -> genuine rebuild"),
        ]
        var counted = 0
        for (tier, note) in order {
            let keys = (tiers[tier] ?? []).sorted()
            counted += keys.count
            report += "\n  \(tier.rawValue.uppercased()) (\(keys.count)) — \(note)\n"
            for k in keys { report += "      \(k)\n" }
        }
        report += "\n  total classified: \(counted) of "
            + "\(ParamRegistry.all.filter { $0.apply != .live }.count) non-live params\n"
        print(report)

        // The point of the exercise: the majority must be reachable without
        // touching table SIZES, or "make tilt-mapped params live" is not a
        // realistic goal.
        let reachable = (tiers[.scalarOnly]?.count ?? 0)
            + (tiers[.engineSide]?.count ?? 0)
            + (tiers[.coefficients]?.count ?? 0)
        XCTAssertGreaterThan(reachable, tiers[.structural]?.count ?? 0)
    }
}
