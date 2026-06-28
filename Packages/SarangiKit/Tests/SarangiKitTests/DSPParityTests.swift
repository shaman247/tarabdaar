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

    func testBodyModes() throws {
        let g = try load("body_modes")
        // Current BODY_MODES (chain.py) — 6 modes, E_body = 1.0. (Exercises the
        // peaking-biquad chain; the live body ring uses these modes as resonators.)
        let modes = BodyMode.defaults.map { ($0.f, $0.gainDB, $0.q) }
        var chain = BiquadChain(modes.map { Biquad.peaking(f0: $0.0, gainDB: $0.1, q: $0.2, sr: sr) })
        let y = g.input.map { chain.process($0) }
        XCTAssertLessThan(maxAbsError(y, g.output), 1e-9)
    }
}
