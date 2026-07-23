import XCTest
@testable import SarangiKit

/// Parity tests: feed the SAME input the Python `blocks.py` saw and assert the
/// Swift port reproduces its output. Covers the deterministic blocks (biquads,
/// resonators, bank). Run `python3 app/tools/gen_goldens.py` to refresh goldens.
final class DSPParityTests: XCTestCase {

    struct Golden: Decodable { let input: [Double]; let output: [Double] }

    func load(_ name: String) throws -> Golden {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Goldens") else {
            throw XCTSkip("golden \(name).json not found — run app/tools/gen_goldens.py")
        }
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    func maxAbsError(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count)
        var m = 0.0
        for i in a.indices { m = max(m, abs(a[i] - b[i])) }
        return m
    }

    let sr = 44100.0

    func testPeaking() throws {
        let g = try load("biquad_peaking")
        var bq = Biquad.peaking(f0: 620.0, gainDB: -3.0, q: 5.0, sr: sr)
        let y = g.input.map { bq.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-9)
    }

    func testLowShelf() throws {
        let g = try load("biquad_lowshelf")
        var bq = Biquad.lowShelf(f0: 120.0, gainDB: 8.0, sr: sr, S: 0.7)
        let y = g.input.map { bq.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-9)
    }

    func testResonator() throws {
        let g = try load("resonator")
        var r = Resonator(f0: 300.0, t60: 2.0, sr: sr)
        let y = g.input.map { r.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-6)
    }

    func testComb() throws {
        let g = try load("comb")
        var c = CombString(f0: 300.0, t60: 2.0, sr: sr, bright: 0.5)
        let y = g.input.map { c.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-6)   // feedback comb: tiny float accumulation
    }

    func testCombWebDamp() throws {
        // web form: fractional delay + dispersion allpass + IN-LOOP f² damping
        let g = try load("comb_web_damp")
        var c = CombString(f0: 300.0, t60: 4.0, sr: sr, bright: 0.5,
                           web: true, inharm: 0.11, damp: 0.6)
        let y = g.input.map { c.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-6)
    }

    func testBank() throws {
        let g = try load("bank")
        // 5 strings, gain_scale=0.9, t60_scale=1.1, bright=0.4 (comb bank).
        let strings = [(146.83, 0.8, 2.5), (220.0, 0.6, 1.8), (329.63, 0.7, 3.0),
                       (440.0, 0.5, 2.0), (587.33, 0.4, 1.5)]
        let gScale = 0.9 / Double(strings.count).squareRoot()
        var combs = strings.map { CombString(f0: $0.0, t60: $0.2 * 1.1, sr: sr, bright: 0.4) }
        let rel = strings.map { $0.1 }
        let y = g.input.map { x -> Double in
            var s = 0.0
            for i in combs.indices { s += gScale * rel[i] * combs[i].process(x) }
            return s
        }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-6)
    }

    /// One-pole low-pass parity vs `gutstring.post`'s `bow_rad_lp_ord < 2`
    /// branch — the String's radiation HF rolloff. Python:
    ///   a = exp(-2π·fc/sr); lfilter([1-a], [1, -a], x)
    /// Reference computed at the SHIPPED bow_rad_lp (params/bowed_string.json)
    /// on 48 kHz; input/output are inlined rather than a Goldens file because
    /// this block has no gen_goldens.py entry. Values are %.17g — they
    /// round-trip exactly, so the compare is against lfilter's own doubles.
    func testOnePoleLowpass() {
        let x: [Double] = [
            1, 0.14164367350173893, 0.30639092427910425, 0.47549812564401794,
            0.6214339122861442, 0.70871668029094737, 0.69990192483113367, 0.56809437529907159,
            0.31458054156838067, -0.014800402625510077, -0.32640089655456961, -0.50186616025705677,
            -0.45182966173630579, -0.1821730192902942, 0.17176604742377463, 0.39355488921834908,
            0.32407239216315847, 0.0092448454682802148, -0.28810352133048639, -0.29232942164884523,
            -1.5105536633323383e-16, 0.266105671063747, 0.19262421368051758, -0.11879170118963954,
            -0.23817277224144129, -1.6884715461210069e-16, 0.21377841439020631, 0.055760204011631488,
            -0.18163468105112532, -0.062591314521127206, 0.16285620062940523, 0.036209614025033761,
            -0.15164290582772441, 0.014405417307751703, 0.12761989126450596, -0.075003751672793398,
            -0.068250616673006484, 0.11086247417359101, -0.023988150001865154, -0.076066507902527072,
        ]
        let want: [Double] = [
            0.14554380365382125, 0.14497616387674223, 0.16846908207157218, 0.21315525690530077,
            0.27257768536009641, 0.33605501360408713, 0.38901067701176573, 0.41507519963289352,
            0.40044882485129418, 0.34001187282000922, 0.24301962356175627, 0.1346061132971082,
            0.049254020000068503, 0.015571248433406779, 0.038304433589408951, 0.090008936151397947,
            0.12407542183570845, 0.10736254297543235, 0.049804907760342264, 9.3760975796816071e-06,
            8.0114646744833736e-06, 0.038736876986103258, 0.061134225302764578, 0.03494712158512224,
            -0.0048037866159236289, -0.0041046252399008099, 0.027606901099521255, 0.031704439890767981,
            0.00065425276072223978, -0.0085507476657217963, 0.016396471561844862, 0.019280151678272413,
            -0.0055966402432911866, -0.0026854647064097677, 0.016279672438062474, 0.0029939356824235735,
            -0.0073752674569995263, 0.0098335031953543893, 0.0049109711431706326, -0.0068747991674378188,
        ]
        var bq = Biquad.onePoleLowpass(fc: 1201.607394, sr: 48000.0)
        let y = x.map { bq.process($0) }
        XCTAssertLessThan(maxAbsError(y, want), 1e-9)   // measured 1.4e-17
    }

    func testFIR() throws {
        struct FIRGolden: Decodable { let taps: [Double]; let input: [Double]; let output: [Double] }
        guard let url = Bundle.module.url(forResource: "fir", withExtension: "json", subdirectory: "Goldens") else {
            throw XCTSkip("fir.json not found — run gen_goldens.py")
        }
        let g = try JSONDecoder().decode(FIRGolden.self, from: Data(contentsOf: url))
        var fir = FIRFilter(taps: g.taps)
        let y = g.input.map { fir.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-9)
    }

}
