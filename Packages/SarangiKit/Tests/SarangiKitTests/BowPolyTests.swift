import XCTest
import CBowKernel
@testable import SarangiKit

/// Poly kernel: an eight-note max-force chord stays bounded and releases.
final class BowPolyTests: XCTestCase {

    // ------------------------------------------------------------------ //
    // helpers
    // ------------------------------------------------------------------ //

    private func stringBP(noise: Bool) -> BowParams {
        var num: [String: Double] = [
            "bow_Z": 1.0, "bow_Zt": 7.9, "bow_mu_s": 0.8, "bow_mu_d": 0.3,
            "bow_v0": 0.2, "bow_nut_fc": 5500.0, "bow_br_fc": 6750.0,
            "bow_w": 1.196, "bow_width_smp": 9.0, "bow_contacts": 2.0,
            "bow_th_tau": 0.012, "bow_th_a": 0.17, "bow_th_floor": 0.15,
            "bow_disp": 0.3, "bow_gut_g": 0.998, "bow_disp_n": 2.0,
            "bow_nail_k": 0.0, "bow_gut_fc2": 3500.0,
            "bow_kret": 0.0, "bow_yinf": 0.0, "bow_zload": 1.0, "bow_os": 2,
            "bow_v_lo": 0.065, "bow_v_hi": 0.23, "dyn_p": 1.0,
            "bow_expr_lift": 0.2,
            "bow_live_beta_lo": 0.05, "bow_live_beta_hi": 0.24,
            "bow_live_press_under": 0.55, "bow_live_press_over": 1.25,
            "bow_schelleng_c": 0.055, "bow_schelleng_margin": 1.2,
            "bow_f_cap": 4.0,
            "bow_rad_hp": 200.0, "bow_rad_hp_ord": 2,
            "bow_rad_lp": 8000.0, "bow_rad_lp_ord": 1,
        ]
        if noise {
            num["bow_noise"] = 0.1
            num["bow_noise_dir"] = 0.12
        }
        return BowParams(num: num)
    }

    /// Overlays swept by the rigid-bridge mount checks.
    /// DEFAULT-VALUE LAW : the shipped artifacts null these, and the poly
    /// kernel once shipped a round mounting its strings in the WRONG
    /// friction state because parity had only ever been measured at the
    /// resting value. Any param introduced as "0 = BIT-NULL" belongs in
    /// this sweep.
    private static let nullSweep: [(name: String, over: [String: Double])] = [
        ("bit-null defaults", [:]),
        ("bow_tors_c 0.35", ["bow_tors_c": 0.35]),  // round-10 fitted value
        ("bow_tors_c 0.6", ["bow_tors_c": 0.6]),
    ]

    private typealias Drive = (f0: [Double], vb: [Double], fb: [Double],
                               be: [Double], ga: [Double])

    /// Steady rigid-bridge bow drive. The gate is FULL from sample 0 BY
    /// DESIGN: under a gate ramp the contact starts unloaded, and the
    /// unloaded friction branch re-seeds the aging deficit to ageA on
    /// sample 0 — repairing a wrong mount before it can radiate, which
    /// makes any aging parity assertion a false pass.
    private func rigidDrive(n: Int, f0: Double, vb: Double = 0.2) -> Drive {
        ([Double](repeating: f0, count: n),
         [Double](repeating: vb, count: n),
         [Double](repeating: 1.0, count: n),
         [Double](repeating: 0.12, count: n),
         [Double](repeating: 1.0, count: n))
    }

    private func initPoly(_ nb: Int, tables t: BowKernelTables)
        -> UnsafeMutableRawPointer {
        let s = t.scalars
        return bow_poly_init(
            Int32(nb), t.sr,
            Int32(t.ba1.count), t.ba1, t.ba2, t.bn0, t.bA, t.bC,
            s[0], s[1], s[2],
            s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
            s[12], s[13], s[14],
            s[15], s[16], s[17], s[18], s[19], s[20], s[21],
            s[22], s[23], s[24], s[25],
            s[26], s[27], s[28], s[29],
            s[30], s[31], s[32],
            s[33], s[34], s[35], s[36], s[37],
            s[38], s[39], s[40],
            s[41], s[42], s[43], s[44], s[45], s[46],
            s[47], s[48], s[49], s[50], s[51], s[52], s[53], s[54], s[55],
            s[56], s[57], s[58], s[59], s[60], s[61])!
    }

    /// Render `d` on slot 0 of an `nb`-slot poly kernel. With `prelude`, the
    /// slot is first bowed on OTHER controls and then remounted through
    /// `bow_poly_reset_string` (the slot-steal path BowEngine takes on a
    /// serial bump) — the returned samples are the post-remount render only.
    /// On the rigid bridge (yinf 0 ⇒ V ≡ 0, nv 0, K 0, noise off) no shared
    /// bridge/body/noise state reaches the output, so the prelude leaves the
    /// comparison exact.
    private func polySlot0Render(tables t: BowKernelTables, nb: Int,
                                 prelude: Drive? = nil, _ d: Drive) -> [Double] {
        let pk = initPoly(nb, tables: t)
        defer { bow_poly_free(pk) }

        func run(_ c: Drive) -> [Double] {
            let n = c.f0.count
            var f0 = [Double](repeating: 0, count: nb * n)
            var vb = f0, fb = f0, be = f0, ga = f0
            for i in 0..<n {
                f0[i] = c.f0[i]; vb[i] = c.vb[i]; fb[i] = c.fb[i]
                be[i] = c.be[i]; ga[i] = c.ga[i]
            }
            let xv = [Double](repeating: 0, count: n)
            var out = [Double](repeating: 0, count: n)
            out.withUnsafeMutableBufferPointer { ob in
                bow_poly_process(pk, Int32(n), Int32(n), f0, vb, fb, be, ga,
                                 xv, ob.baseAddress!)
            }
            return out
        }

        if let p = prelude {
            _ = run(p)
            bow_poly_reset_string(pk, 0)
        }
        return run(d)
    }

    private func assertRenderParity(_ poly: [Double], _ mono: [Double],
                                    _ label: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        // rad = c0 * bridge FORCE, so a rigid bridge still radiates — but a
        // c0 of 0 renders silence and scores a false 0.0 parity everywhere.
        let peak = mono.reduce(0.0) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 1e-6, "\(label): probe rendered silence",
                             file: file, line: line)
        var head = 0.0
        for i in 0..<min(2048, poly.count) {
            head = max(head, abs(poly[i] - mono[i]))
        }
        XCTAssertLessThan(head, 1e-9,
                          "\(label): early divergence (head \(head))",
                          file: file, line: line)
        func rms(_ x: [Double]) -> Double {
            (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
        }
        let dDB = 20.0 * log10(rms(poly) / max(rms(mono), 1e-30))
        XCTAssertEqual(dDB, 0.0, accuracy: 0.2,
                       "\(label): level drift \(dDB) dB",
                       file: file, line: line)
    }

    private func goertzelDB(_ x: [Double], from: Int, to: Int,
                            sr: Double, f: Double) -> Double {
        let n = to - from
        let w = 2.0 * Double.pi * f / sr
        let c = 2.0 * cos(w)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in from..<to {
            s0 = x[i] + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        let p = s1 * s1 + s2 * s2 - c * s1 * s2
        return 10.0 * log10(max(p / Double(n * n), 1e-30))
    }

    // ------------------------------------------------------------------ //
    // mapper slot allocation
    // ------------------------------------------------------------------ //

    // ------------------------------------------------------------------ //
    // poly kernel physics
    // ------------------------------------------------------------------ //

    /// Driven from the SHIPPING artifact + the fitted tarab, so this is the
    /// instrument the app actually plays under a maximum-force chord.
    func testPolyEightNoteChordStaysBoundedAndReleases() throws {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let sr = 48000.0
        let tonic = 328.9
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonic, bp: bp)
        let taraf = Presets.state(.sarangiPilu).resolvedStrings
            .filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        tables.jt = BowTables.buildJawariTables(
            rows: taraf.filter { BowTables.jtSteelRow($0.f, tonic: tonic) },
            srk: sr * Double(osf), bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp, sr: sr,
                               rfir: [], eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: 15.0,
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: 0.0, maxPoly: 8)
        engine.outGain = bp.v("bow_live_trim", 0.175)

        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        var peak = 0.0
        func run(seconds: Double) -> Double {
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
                    XCTAssertTrue(l[i].isFinite && r[i].isFinite,
                                  "poly chord render went non-finite")
                    let s = l[i] + r[i]
                    acc += s * s
                    peak = max(peak, abs(s))
                }
                n += m
                left -= m
            }
            return (acc / Double(n)).squareRoot()
        }

        mapper.setAxis(expr: 1.0, press: 1.0, pos: 0.5)
        for note in [57, 60, 62, 64, 67, 69, 72, 76] {
            mapper.midi(0x90, UInt8(note), 100)
        }
        _ = run(seconds: 0.5)                       // speak/settle
        let sustain = run(seconds: 2.5)
        XCTAssertGreaterThan(sustain, 1e-3, "chord made no sound")
        XCTAssertLessThan(peak, 5.0,
                          "8-note max-force chord unbounded (peak \(peak))")
        // energy must not still be GROWING at the end of the sustain
        let s2 = run(seconds: 1.0)
        XCTAssertLessThan(s2, sustain * 3.0, "chord energy still growing")

        mapper.midi(0xB0, 123, 0)                   // all off
        _ = run(seconds: 2.5)
        let tail = run(seconds: 0.5)
        XCTAssertLessThan(tail, sustain * 0.5, "chord did not release")
    }

}
