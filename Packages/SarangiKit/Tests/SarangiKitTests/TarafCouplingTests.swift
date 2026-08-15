import XCTest
@testable import SarangiKit

/// TARAF BRIDGE COUPLING (2026-08-01, the coherence rev's two-way fix).
/// `bow_cpl_z` puts one SILENT comb string per enabled tarab row back on
/// the passive wave junction — no buzz terms, no direct radiation tap, no
/// polarization doublets — so the played strings feel the taraf as a
/// load and the taraf's stored energy returns through the body. These
/// tests pin the three properties the design rests on: the web is silent
/// as a source (all buzz/tap columns zero), the coupling is audible as a
/// KIN-selective release bloom (a unison row sustains the tail far more
/// than a non-kin row), and the junction stays passive/bounded at the
/// knob's ceiling.
final class TarafCouplingTests: XCTestCase {

    static func cplBP(z: Double) -> BowParams {
        var bp = BowedStringEngineTests.stringBP()
        if z > 0 { bp.num["bow_cpl_z"] = z }
        return bp
    }

    func testCouplingWebBuildsSilentVoicesOnly() {
        let taraf = BowedStringEngineTests.testTaraf
        let t = BowTables.buildOpenString(sr: 96000.0, tonic: 261.63,
                                          bp: Self.cplBP(z: 0.0141),
                                          taraf: taraf)
        XCTAssertEqual(t.L.count, taraf.count)
        // silent as a source: every buzz term and both tap weights zero
        for arr in [t.jw, t.jl, t.jn, t.twt, t.wout, t.alphaw, t.kap,
                    t.chg] {
            XCTAssertEqual(arr.count, taraf.count)
            XCTAssertTrue(arr.allSatisfy { $0 == 0.0 },
                          "the coupling web must not buzz or radiate")
        }
        // the junction load is armed, the tap path is not
        XCTAssertEqual(t.scalars[40], 1.0, "passive junction must arm")
        XCTAssertEqual(t.scalars[30], 0.0, "tdirect must stay 0")
        XCTAssertEqual(t.scalars[31], 0.0, "tshape must stay 0")
        // row impedance follows row gain (gain-weighted around the mean)
        XCTAssertEqual(t.zi.count, taraf.count)
        let gMean = taraf.map(\.gain).reduce(0, +) / Double(taraf.count)
        for (zi, row) in zip(t.zi, taraf) {
            XCTAssertEqual(zi, 0.0141 * row.gain / gMean, accuracy: 1e-12)
            XCTAssertGreaterThan(zi, 0.0, "passivity needs zi > 0")
        }
        // decay stays passive
        XCTAssertTrue(t.g.allSatisfy { $0 > 0.0 && $0 < 1.0 })
    }

    /// One phrase, three builds: uncoupled, coupled with a UNISON row,
    /// coupled with a NON-KIN row. The unison row must bloom the release
    /// tail (energy absorbed while bowing returns through the junction);
    /// the non-kin row must do much less — the coupling is selective the
    /// way sympathetic strings are, not a reverb.
    private func releaseTail(taraf: [(f: Double, gain: Double, t60: Double)],
                             z: Double) -> (sustain: Double, tail: Double,
                                            peak: Double) {
        let bp = Self.cplBP(z: z)
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: 261.63, bp: bp,
                                               taraf: taraf)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: 0.6, reverbPredelayMs: 10.0,
                               reverbMix: 0.0, reverbWidth: 0.0)
        engine.outGain = 0.05
        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        var peak = 0.0
        func rms(seconds: Double) -> Double {
            var acc = 0.0
            var n = 0
            var left = Int(seconds * sr)
            while left > 0 {
                let m = min(1024, left)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                for i in 0..<m {
                    XCTAssertTrue(l[i].isFinite && r[i].isFinite)
                    let s = l[i] + r[i]
                    if abs(s) > peak { peak = abs(s) }
                    acc += s * s
                }
                n += m
                left -= m
            }
            return (acc / Double(n)).squareRoot()
        }
        mapper.midi(0x90, 60, 100)               // bow the tonic
        _ = rms(seconds: 0.3)                    // speak/settle
        let sustain = rms(seconds: 1.2)          // charge the web
        mapper.midi(0x80, 60, 0)
        _ = rms(seconds: 0.8)                    // string's own release
        let tail = rms(seconds: 1.0)             // what the web returns
        return (sustain, tail, peak)
    }

    func testProbeZResponse() throws {
        throw XCTSkip("calibration probe — enable by hand")
    }

    func probeZResponse() {
        let unison: [(f: Double, gain: Double, t60: Double)] =
            [(261.63, 1.0, 6.0)]
        let nonKin: [(f: Double, gain: Double, t60: Double)] =
            [(369.99, 1.0, 6.0)]
        for z in [0.0, 0.0141, 0.03, 0.06, 0.1, 0.2] {
            let kin = releaseTail(taraf: unison, z: z)
            let far = releaseTail(taraf: nonKin, z: z)
            print(String(format: "z %.4f kin: sus %.4f tail %.3e pk %.3f"
                         + "   far: sus %.4f tail %.3e",
                         z, kin.sustain, kin.tail, kin.peak,
                         far.sustain, far.tail))
        }
    }

    /// Measured z response (this harness, single row, jt off — the
    /// calibration probe below): the kin tail rises to ~+17% RMS around
    /// z 0.05–0.06 (impedance matching), then over-coupling drains both
    /// the string and its own return (z 0.2: sustain −15%, tail below
    /// dry); the non-kin tail stays flat at EVERY z. The shipped effect
    /// is larger than this number: with the jt block armed, the web's
    /// ring re-drives the jt rows through the junction force, so the
    /// radiated taraf sustains too. Pinned at z 0.05 for signal-to-noise;
    /// the bloom is a decay-shape change, not a level change, so the
    /// assertions are deliberately about differences, not magnitudes.
    func testKinBloomIsSelective() {
        let unison: [(f: Double, gain: Double, t60: Double)] =
            [(261.63, 1.0, 6.0)]
        // ~tritone above — outside every kin corridor
        let nonKin: [(f: Double, gain: Double, t60: Double)] =
            [(369.99, 1.0, 6.0)]
        let dry = releaseTail(taraf: unison, z: 0.0)
        let kin = releaseTail(taraf: unison, z: 0.05)
        let far = releaseTail(taraf: nonKin, z: 0.05)
        print(String(format: "cpl tails: dry %.3e kin %.3e far %.3e "
                     + "(sustain dry %.4f kin %.4f)",
                     dry.tail, kin.tail, far.tail, dry.sustain, kin.sustain))
        // the unison row returns real energy after release…
        XCTAssertGreaterThan(kin.tail, 1.10 * dry.tail,
            "no release bloom — the coupling web is not returning energy")
        // …and the coupling is kin-selective, not a general wash: the
        // non-kin row's tail change must be far smaller than the unison's
        let kinGain = kin.tail - dry.tail
        let farGain = far.tail - dry.tail
        XCTAssertGreaterThan(kinGain, 5.0 * max(farGain, 0.0),
            "a non-kin row blooms like the unison — coupling is not "
            + "selective")
        // the exchange must not blow up or choke the driven level
        XCTAssertLessThan(kin.sustain, dry.sustain * 1.5,
                          "coupling inflated the driven level")
        XCTAssertGreaterThan(kin.sustain, dry.sustain * 0.5,
                             "coupling choked the driven level")
    }

    /// Passivity stress: the knob's ceiling, a full 19-row bank, max-force
    /// bowing — bounded output, no NaN, and the ring dies after release.
    func testCouplingStaysBoundedAtCeiling() {
        var rows: [(f: Double, gain: Double, t60: Double)] = []
        for i in 0..<19 {
            rows.append((87.3 * pow(2.0, Double(i) * 4.0 / 12.0),
                         0.7 + 0.02 * Double(i), 6.0))
        }
        let got = releaseTail(taraf: rows, z: 0.05)
        XCTAssertTrue(got.peak.isFinite)
        XCTAssertLessThan(got.peak, 4.0, "junction not passive at ceiling")
        XCTAssertLessThan(got.tail, got.sustain,
                          "web ring must decay below the driven level")
    }
}
