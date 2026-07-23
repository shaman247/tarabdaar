import XCTest
@testable import SarangiKit

/// Parity of the Swift PASSIVE coupled bridge–body network vs the numpy
/// closed form (`coupled.render_coupled`, N_junction "passive" — the ONE
/// live render path since the v57 simplification). The delay-free junction
/// solve is exact algebra, so the per-sample Swift loop and the FFT closed
/// form are the same system; we allow float accumulation over the ~1 s
/// render. Regenerate the golden with `python3 app/tools/gen_coupled_golden.py`.
final class CoupledParityTests: XCTestCase {

    struct Golden: Decodable {
        let input: [Double]
        let outL: [Double]
        let outR: [Double]
        let params: [String: Double]
        let strings: [[Double]]
        let tonic: Double
        let sr: Double
    }

    /// PASSIVE wave junction + taraf-velocity tap (v57 live port): the
    /// per-sample delay-free solve is the SAME system as the FFT closed
    /// form (coupled.junction_solve — the C kernel matched it at 4.5e-14),
    /// so the Swift twin must sit at float-accumulation error like the κ
    /// golden. Regenerate with `python3 app/tools/gen_coupled_golden.py`.
    func testPassiveJunctionParity() throws {
        guard let url = Bundle.module.url(forResource: "coupled_passive",
                                          withExtension: "json",
                                          subdirectory: "Goldens") else {
            throw XCTSkip("coupled_passive.json missing — run app/tools/gen_coupled_golden.py")
        }
        let data = try Data(contentsOf: url)
        let g = try JSONDecoder().decode(Golden.self, from: data)
        guard let obj = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let cfgJson = obj["config"] as? [String: Any],
              let cfg = CoupledConfig(json: cfgJson) else {
            return XCTFail("golden config undecodable")
        }
        XCTAssertTrue(cfg.passive, "golden must arm the passive junction")

        var values = g.params
        values["F_mix"] = 0.0
        values["mix_dry"] = 0.0
        values["mix_jaw"] = 0.0
        values["main_gain"] = 1.0
        values["sym_gain"] = 1.0
        values["sym_bow_follow"] = 0.0
        let p = SarangiParams(values: values)
        let strings = g.strings.map {
            ResolvedString(freq: $0[0], gain: $0[1], t60: $0[2],
                           bright: $0[3] > 0.5)
        }
        let engine = SarangiEngine(params: p, strings: strings,
                                   tonic: g.tonic, sr: g.sr,
                                   coupled: cfg)
        let (l, r) = engine.renderOffline(g.input)
        var scale = 0.0
        for v in g.outL { scale = max(scale, abs(v)) }
        var errL = 0.0, errR = 0.0
        for i in g.input.indices {
            errL = max(errL, abs(l[i] - g.outL[i]))
            errR = max(errR, abs(r[i] - g.outR[i]))
        }
        XCTAssertLessThan(errL / scale, 1e-9)
        XCTAssertLessThan(errR / scale, 1e-9)
    }
}
