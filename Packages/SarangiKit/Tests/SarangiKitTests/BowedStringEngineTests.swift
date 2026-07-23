import XCTest
@testable import SarangiKit

/// Generic pure-physics bowed string, live-shaped smoke: FORMULA tables
/// (BowTables.buildOpenString — analytic modal body + polarization-doublet
/// taraf, no fitted artifacts) → streaming kernel → decimate → formula
/// radiation (butter-2 HP sections + one-pole LP) → dry reverb, driven by
/// the control mapper like the app. No artifact dependency: the
/// BowParams are constructed inline with the seed values (physics constants
/// of gut/horsehair, formula mapping/radiation — mirrors
/// gutstring.default_gut_params + the sarangi physics keys).
final class BowedStringEngineTests: XCTestCase {

    static func stringBP() -> BowParams {
        BowParams(num: [
            // string / friction physics
            "bow_Z": 1.0, "bow_Zt": 7.9, "bow_mu_s": 0.8, "bow_mu_d": 0.3,
            "bow_v0": 0.2, "bow_nut_fc": 5500.0, "bow_br_fc": 6750.0,
            "bow_w": 1.196, "bow_width_smp": 9.0, "bow_contacts": 2.0,
            "bow_th_tau": 0.012, "bow_th_a": 0.17, "bow_th_floor": 0.15,
            "bow_disp": 0.3, "bow_gut_g": 0.998, "bow_disp_n": 2.0,
            "bow_nail_k": 0.0, "bow_gut_fc2": 3500.0,
            "bow_noise": 0.1, "bow_noise_pow": 1.0,
            "bow_noise_hi": 8590.0, "bow_noise_lo": 402.0,
            "bow_noise_dir": 0.12, "bow_noise_dir_hi": 6000.0,
            // topology: bridge mobility ON since the formula body
            "bow_kret": 0.35, "bow_yinf": 0.08, "bow_zload": 1.0, "bow_os": 2,
            // formula modal body (2026-07-16b; mobile since the taraf round)
            "bow_body_modes": 12,
            "bow_body_air_ratio": 0.9, "bow_body_scale": 1.0,
            "bow_body_spacing": 0.55, "bow_body_jitter": 0.35,
            "bow_body_q": 25.0, "bow_body_q_air": 12.0,
            "bow_body_y": 0.9, "bow_body_rad": 1.0, "bow_body_c0": 0.3,
            "bow_brg_f": 700.0, "bow_brg_q": 0.55, "bow_loop_max": 0.5,
            // formula taraf (2026-07-16d)
            "bow_taraf_Z": 0.0033, "bow_taraf_gain": 1.0,
            "bow_taraf_pol_cents": 3.0, "bow_taraf_pol_gain": 0.85,
            "bow_taraf_pol_t60": 1.0, "bow_taraf_inharm": 0.1,
            "bow_taraf_damp": 0.5, "bow_taraf_bright": 0.5,
            "bow_taraf_t60": 1.0, "bow_taraf_t60_cap": 8.0,
            "bow_taraf_dir": 0.5, "bow_taraf_jawari": 0.0,
            // mapping (formulas)
            "bow_v_lo": 0.065, "bow_v_hi": 0.23, "dyn_p": 1.0,
            "bow_expr_lift": 0.2,
            "bow_live_beta_lo": 0.05, "bow_live_beta_hi": 0.24,
            "bow_live_press_under": 0.55, "bow_live_press_over": 1.25,
            "bow_schelleng_c": 0.055, "bow_schelleng_margin": 1.2,
            "bow_f_cap": 4.0,
            // formula radiation
            "bow_rad_hp": 200.0, "bow_rad_hp_ord": 2,
            "bow_rad_lp": 8000.0, "bow_rad_lp_ord": 1,
            // articulation: place-then-draw + aftertouch vibrato
            "bow_place_ms": 35.0, "bow_draw_ms": 60.0,
            "bow_vib_cents": 25.0, "bow_vib_hz": 5.5,
        ])
    }

    /// The 3-row taraf tuning used by the lockstep spot values below.
    static let testTaraf: [(f: Double, gain: Double, t60: Double)] = [
        (261.63, 1.0, 6.0), (392.0, 0.8, 5.0), (523.25, 0.6, 4.0),
    ]

    // python formula_body reference for shippedBodyBP() at sr 96000 /
    // tonic 261.63 — indices 0..6 signature modes, 7..36 diffuse tail
    static let refBa1: [Double] = [
        1.9998495662399691, 1.9998045907575834, 1.9997133772763511,
        1.9997399351625238, 1.9996477946457971, 1.999506517600524,
        1.9995825233895124, 1.991113424091255, 1.989254402748351,
        1.986306127731749, 1.983664231676005, 1.980372796066635,
        1.9760840966124422, 1.973236697756449, 1.9687955472410106,
        1.9648579808530962, 1.9602131646843939, 1.9544216847217868,
        1.9503300534068921, 1.9445365040402636, 1.9370990530921892,
        1.9332489485487847, 1.9261240488772393, 1.920597170820067,
        1.91357076266496, 1.9048517554618787, 1.899549857560653,
        1.8912308943853575, 1.8841281409977106, 1.8759728211759974,
        1.8661317915610791, 1.859214221142605, 1.84981873432552,
        1.8381221270832517, 1.8318476359624132, 1.8210144080539725,
        1.8123677512602372,
    ]
    static let refBA: [Double] = [
        1.1956590885888003, 0.7871731771776003, 1.4481172657664005,
        1.0396313543552005, 0.6311454429440005, 1.2920895315328007,
        0.8836036201216009, 0.07970333436798614, 0.05247342452784494,
        0.09653234415978863, 0.06930243431964743, 0.042072524479506226,
        0.08613144411144992, 0.05890153427130872, 0.10296045390325241,
        0.07573054406311121, 0.04850063422297, 0.0925595538549137,
        0.0653296440147725, 0.038099734174631285, 0.08215865380657499,
        0.054928743966433775, 0.09898766359837748, 0.07175775375823627,
        0.04452784391809506, 0.08858676355003875, 0.06135685370989755,
        0.10541577334184124, 0.07818586350170004, 0.05095595366155884,
        0.09501487329350253, 0.06778496345336132, 0.04055505361322013,
        0.08461397324516394, 0.05738406340502261, 0.10144298303696618,
        0.0742130731968251,
    ]
    static let refBC: [Double] = [
        -2.072754175415813, -3.81312676312372, 2.7375173508316264,
        1.6619079385395328, -3.402280526247439, -2.3266711139553458,
        4.067043701663253, -0.06726607484196408, -0.12374553300741577,
        0.08883930819498885, 0.053933083382561926, -0.11041254154801362,
        -0.07550631673558669, 0.13198577490103838, 0.09707955008861147,
        -0.062173325276184556, -0.11865278344163624, 0.08374655862920932,
        0.048840333816782405, -0.1053197919822341, -0.07041356716980718,
        0.12689302533525887, 0.09198680052283195, -0.05708057571040503,
        -0.11356003387585673, 0.07865380906342981, 0.1351332672288815,
        -0.10022704241645457, -0.06532081760402765, 0.12180027576947934,
        0.08689405095705242, -0.05198782614462551, -0.10846728431007736,
        0.07356105949765028, 0.13004051766310182, -0.09513429285067505,
        -0.060228068038248296,
    ]

    func testOpenStringTablesShape() {
        let bp = Self.stringBP()
        let t = BowTables.buildOpenString(sr: 96000.0, tonic: 261.63, bp: bp,
                                          taraf: Self.testTaraf)
        XCTAssertEqual(t.scalars.count, 61)
        XCTAssertEqual(t.L.count, 6, "3 taraf rows × polarization doublets")
        XCTAssertEqual(t.ba1.count, 12, "formula body must arm 12 modes")
        XCTAssertEqual(t.scalars[0], 0.08)           // yinf: bridge mobility
        XCTAssertEqual(t.scalars[1], 0.3)            // c0: direct radiation
        XCTAssertEqual(t.scalars[3], 0.0)            // pgain: no voice force
        // kret LOOP-CAP PROJECTED (the mobile body raises max|Y·H_brg|) —
        // python reference from gutstring._string_scalars; tolerance covers
        // numpy pairwise- vs Swift sequential-summation in the ymax scan
        XCTAssertEqual(t.scalars[6], 0.16046955218688852, accuracy: 1e-11)
        XCTAssertEqual(t.scalars[30], 0.5)           // tdirect: taraf tap
        XCTAssertEqual(t.scalars[31], 1.0)           // tshape: body-shaped
        XCTAssertEqual(t.scalars[40], 1.0)           // PASSIVE wave junction
        XCTAssertEqual(t.scalars[44], 261.63)        // f0Open = tonic
        // LOCKSTEP with gutstring.formula_body/formula_taraf (python
        // reference values at sr 96000 / tonic 261.63; regenerate via the
        // one-liner in the doc comment if the recipe changes)
        XCTAssertEqual(t.ba1[0], 1.9984787886291242, accuracy: 1e-14)
        XCTAssertEqual(t.bA[0], 1.0062305898749055, accuracy: 1e-14)
        XCTAssertEqual(t.bC[0], -0.7360679774997898, accuracy: 1e-14)
        XCTAssertEqual(t.ba1[1], 1.998207368724233, accuracy: 1e-14)
        XCTAssertEqual(t.bA[1], 0.6624611797498109, accuracy: 1e-14)
        XCTAssertEqual(t.bC[1], -1.3541019662496847, accuracy: 1e-14)
        XCTAssertEqual(t.ba1[11], 1.9833506105945045, accuracy: 1e-14)
        XCTAssertEqual(t.bC[11], 0.5344418537486337, accuracy: 1e-14)
        XCTAssertEqual(t.L[0], 365)
        XCTAssertEqual(t.g[0], 0.9956404721089352, accuracy: 1e-14)
        XCTAssertEqual(t.wout[0], 0.4082482904638631, accuracy: 1e-14)
        XCTAssertEqual(t.zi[0], 0.00445945945945946, accuracy: 1e-16)
        XCTAssertEqual(t.zdrv[0], 2.045845133184961, accuracy: 1e-13)
        XCTAssertEqual(t.L[1], 364)
        XCTAssertEqual(t.zi[5], 0.0022743243243243247, accuracy: 1e-16)
        // signed radiation residues: both signs present (the honk law)
        XCTAssertTrue(t.bC.contains { $0 > 0 } && t.bC.contains { $0 < 0 })
        // admittance residues + junction impedances all positive (passivity)
        XCTAssertTrue(t.bA.allSatisfy { $0 > 0 })
        XCTAssertTrue(t.zi.allSatisfy { $0 > 0 })
    }

    /// The SHIPPED body configuration (params/bowed_string.json after the
    /// round-9 diffuse-tail fit): 7 signature modes + a 30-mode TAIL. The
    /// seed config above leaves bow_body_tail_n unset, so the tail branch —
    /// 30 of the shipping artifact's 37 modes — is armed only here.
    static func shippedBodyBP() -> BowParams {
        var bp = stringBP()
        for (k, v) in [
            "bow_body_modes": 7.0, "bow_body_air_ratio": 0.605958,
            "bow_body_scale": 0.290366, "bow_body_spacing": 0.332851,
            "bow_body_jitter": 0.10181, "bow_body_q": 29.644858,
            "bow_body_q_air": 21.313376, "bow_body_y": 1.06943,
            "bow_body_rad": 2.815982,
            "bow_body_tail_n": 30.0, "bow_body_tail_f0": 984.330049,
            "bow_body_tail_f1": 6425.883165, "bow_body_tail_q": 20.383183,
            "bow_body_tail_y": 0.390465, "bow_body_tail_rad": 0.50054,
        ] { bp.num[k] = v }
        return bp
    }

    /// LOCKSTEP at the SHIPPING body configuration, tail included
    /// (gutstring.formula_body(json.load("params/bowed_string.json"),
    /// 96000.0, 261.63) — regenerate all three arrays together from that
    /// call if the mode recipe changes).
    func testFormulaBodyShippedLockstep() {
        let bp = Self.shippedBodyBP()
        let t = BowTables.buildOpenString(sr: 96000.0, tonic: 261.63, bp: bp)
        XCTAssertEqual(t.ba1.count, 37,
                       "7 signature modes + 30-mode diffuse tail")
        XCTAssertEqual(t.bA.count, 37)
        XCTAssertEqual(t.bC.count, 37)
        guard t.ba1.count == 37, t.bA.count == 37, t.bC.count == 37 else {
            return
        }
        for k in 0..<37 {
            XCTAssertEqual(t.ba1[k], Self.refBa1[k], accuracy: 1e-14,
                           "mode \(k) pole (frequency/Q jitter)")
            XCTAssertEqual(t.bA[k], Self.refBA[k], accuracy: 1e-14,
                           "mode \(k) admittance residue")
            XCTAssertEqual(t.bC[k], Self.refBC[k], accuracy: 1e-14,
                           "mode \(k) radiation residue (SIGNED)")
        }
        // ba2/bn0 pin R itself (ba1 alone leaves R·cos θ degenerate)
        XCTAssertEqual(t.ba2[7], -0.9954121289887478, accuracy: 1e-14)
        XCTAssertEqual(t.ba2[20], -0.9851167721273336, accuracy: 1e-14)
        XCTAssertEqual(t.ba2[36], -0.9837517695803902, accuracy: 1e-14)
        XCTAssertEqual(t.bn0[7], 0.002294286588694364, accuracy: 1e-14)
        XCTAssertEqual(t.bn0[20], 0.007442656884693629, accuracy: 1e-14)
        XCTAssertEqual(t.bn0[36], 0.008124459312173964, accuracy: 1e-14)
        // tail invariants the literals encode: passive admittance, SIGNED
        // radiation (same-sign sums honk), √n-normalized residues
        let tailA = t.bA[7...], tailC = t.bC[7...]
        XCTAssertTrue(tailA.allSatisfy { $0 > 0 })
        XCTAssertTrue(tailC.contains { $0 > 0 } && tailC.contains { $0 < 0 })
        let rn = 1.0 / 30.0.squareRoot()
        func maxFrac(_ r: ClosedRange<Int>) -> Double {
            r.map { (Double($0) * 0.6180339887498949)
                .truncatingRemainder(dividingBy: 1.0) }.max()!
        }
        XCTAssertEqual(tailA.max()!,
                       0.390465 * rn * (0.5 + maxFrac(1...30)),
                       accuracy: 1e-12, "tail admittance lost √n")
        XCTAssertEqual(tailC.map { abs($0) }.max()!,
                       0.50054 * rn * (0.5 + maxFrac(2...31)),
                       accuracy: 1e-12, "tail radiation lost √n")
    }

    /// PLACE-then-DRAW (2026-07-16b): at a fresh attack the force rides the
    /// gate ramp while velocity holds ~0 (bow set on the string), then
    /// draws in over bow_draw_ms — and vibrato follows aftertouch.
    func testArticulationPhysics() {
        let bp = Self.stringBP()
        let srk = 96000.0
        let mapper = BowControlMapper()
        var filter = BowControlFilter(bp: bp, srk: srk, tonic: 261.63)
        // press BELOW bow_attack_thresh (0.5): a SOFT attack — the
        // velocity-leads-force sharp path (2026-07-18l) legitimately
        // passes velocity during placement when the onset press is high
        mapper.setAxis(expr: 0.6, press: 0.35, pos: 0.45)
        mapper.midi(0x90, 60, 100)

        let n = Int(0.020 * srk)               // 20 ms < bow_place_ms 35
        var f0 = [Double](repeating: 0, count: n)
        var vb = f0, fb = f0, be = f0, ga = f0
        func fillOnce() {
            f0.withUnsafeMutableBufferPointer { a in
                vb.withUnsafeMutableBufferPointer { b in
                    fb.withUnsafeMutableBufferPointer { c in
                        be.withUnsafeMutableBufferPointer { d in
                            ga.withUnsafeMutableBufferPointer { e in
                                filter.fill(from: mapper, n: n,
                                            f0: a.baseAddress!,
                                            vb: b.baseAddress!,
                                            fb: c.baseAddress!,
                                            beta: d.baseAddress!,
                                            gate: e.baseAddress!)
                            }
                        }
                    }
                }
            }
        }
        fillOnce()
        // during placement: force already substantial, velocity ~0
        XCTAssertGreaterThan(fb[n - 1], 0.05, "force must ride the gate ramp")
        XCTAssertLessThan(vb[n - 1], 1e-6, "velocity must wait for the draw")
        // after place+draw: velocity at its mapped level
        for _ in 0..<10 { fillOnce() }        // ~200 ms total
        XCTAssertGreaterThan(vb[n - 1], 0.05, "velocity must arrive post-draw")

        // vibrato OFF without aftertouch: f0 flat once settled
        for _ in 0..<20 { fillOnce() }
        let flat0 = f0[0], flat1 = f0[n - 1]
        XCTAssertEqual(flat0, flat1, accuracy: flat0 * 1e-6,
                       "no vibrato without aftertouch")
        // channel aftertouch → ±bow_vib_cents finger motion
        mapper.midi(0xD0, 127, 0)
        var lo = 1e9, hi = 0.0
        for _ in 0..<12 {                     // ~240 ms ≈ 1.3 vibrato cycles
            fillOnce()
            for x in f0 { lo = min(lo, x); hi = max(hi, x) }
        }
        let spanCents = 1200.0 * log2(hi / lo)
        XCTAssertGreaterThan(spanCents, 30.0, "vibrato depth missing")
        XCTAssertLessThan(spanCents, 60.0, "vibrato depth overshoots")
    }

    /// IN-APP COST VERIFICATION (2026-07-21b, the dark/scratchy/clicky
    /// report): per-block render timing through the REAL engine path at
    /// the app's own configuration (the shipped pilu table's lattice
    /// rows, 256-frame blocks) — jt off vs armed. Release-only.
    func testModalJawariRenderSpeed() throws {
        #if DEBUG
        throw XCTSkip("speed is meaningful in release builds only (swift test -c release)")
        #endif
        let root = FileManager.default.currentDirectoryPath + "/.."
        let tablePath = root + "/params/sarangi_strings_pilu.json"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: tablePath),
                          "pilu table not present")
        let data = try Data(contentsOf: URL(fileURLWithPath: tablePath))
        let obj = try JSONSerialization.jsonObject(with: data)
        var rows: [(f: Double, gain: Double, t60: Double)] = []
        var tonic = 261.63
        if let d = obj as? [String: Any] {
            tonic = (d["tonic"] as? Double) ?? tonic
            if let ss = d["strings"] as? [[String: Any]] {
                for s in ss {
                    let f = (s["freq"] as? Double) ?? (s["f"] as? Double) ?? 0
                    rows.append((f, (s["gain"] as? Double) ?? 1.0,
                                 (s["t60"] as? Double) ?? 5.0))
                }
            } else if let ss = d["strings"] as? [[Double]] {
                for s in ss where s.count >= 1 {
                    rows.append((s[0], s.count > 1 ? s[1] : 1.0,
                                 s.count > 2 ? s[2] : 5.0))
                }
            }
        }
        XCTAssertFalse(rows.isEmpty, "no rows parsed from the pilu table")
        let sr = 48000.0
        func measure(_ cfg: [String: Double]?) -> (mean: Double, p95: Double,
                                                   max: Double, njt: Int,
                                                   drops: Double,
                                                   flat: Double) {
            var bp = Self.stringBP()
            if let cfg = cfg {
                for (k, v) in cfg { bp.num[k] = v }
            }
            let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
            var tables = BowTables.buildOpenString(
                sr: sr * Double(osf), tonic: tonic, bp: bp, taraf: rows)
            var jtRows = rows.filter {
                BowTables.jtSteelRow($0.f, tonic: tonic)
            }
            let jtMax = Int(bp.v("bow_jt_max", 0.0) + 0.5)
            if jtMax > 0, jtRows.count > jtMax {
                jtRows.sort { $0.gain != $1.gain ? $0.gain > $1.gain
                                                 : $0.f < $1.f }
                jtRows = Array(jtRows.prefix(jtMax))
            }
            tables.jt = BowTables.buildJawariTables(
                rows: jtRows, srk: sr * Double(osf), bp: bp)
            let mapper = BowControlMapper()
            let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                                   sr: sr, rfir: [],
                                   eLp: bp.v("bow_rad_lp", 8000.0),
                                   reverbRT60: 1.0, reverbPredelayMs: 15.0,
                                   reverbMix: 0.08, reverbWidth: 0.0,
                                   maxPoly: 8)
            engine.outGain = 0.1
            mapper.midi(0x90, 62, 96)
            var l = [Double](repeating: 0, count: 256)
            var r = [Double](repeating: 0, count: 256)
            var times: [Double] = []
            let blocks = Int(3.0 * sr / 256.0)
            let blockS = 256.0 / sr
            // PACE at the audio clock (real playback cadence): the
            // async dispatcher's budget IS the block period — an
            // unpaced loop renders ~12x realtime and starves it by
            // construction (measured: 464 drops), which is the
            // degradation path, not the operating point.
            for _ in 0..<blocks {
                let t0 = DispatchTime.now().uptimeNanoseconds
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: 256, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                let el = Double(DispatchTime.now().uptimeNanoseconds
                                - t0) * 1e-9
                times.append(el)
                if blockS - el > 0 {
                    Thread.sleep(forTimeInterval: blockS - el)
                }
            }
            let rts = times.map { $0 / blockS }.sorted()
            let mean = rts.reduce(0, +) / Double(rts.count)
            let p95 = rts[Int(0.95 * Double(rts.count - 1))]
            let ast = engine.jtAsyncStats()
            return (mean, p95, rts.last ?? 0,
                    cfg != nil ? tables.jt?.M.count ?? 0 : 0,
                    ast.drops, ast.flat)
        }
        // the SHIPPING config (the artifact's staged keys — J8z6
        // since 2026-07-22: div1/alpha1.3/J8/zone6mm/M64/all-rows,
        // measured CLOSER to the converged web than J16 at 10 mm and
        // cheaper — through the persistent 8-worker pool) plus
        // context rungs: the retired 2026-07-21 live trim and the
        // pool-less serial cost.
        let trim: [String: Double] = [
            "bow_jtaraf_on": 1.0, "bow_jt_div": 2.0, "bow_jt_alpha": 1.5,
            "bow_jt_J": 16.0, "bow_jt_mcap": 40.0, "bow_jt_max": 8.0,
            "bow_jt_gain": 0.3, "bow_jt_drive": 0.03]
        let ratified: [String: Double] = [
            "bow_jtaraf_on": 1.0, "bow_jt_div": 1.0, "bow_jt_alpha": 1.3,
            "bow_jt_J": 8.0, "bow_jt_zone": 0.006,
            "bow_jt_mcap": 64.0, "bow_jt_max": 0.0,
            "bow_jt_gain": 0.3, "bow_jt_drive": 0.03]
        let shipping = ratified.merging(["bow_jt_threads": 8.0,
                                         "bow_jt_async": 1.0]) { $1 }
        let off = measure(nil)
        let on = measure(trim)
        let rat = measure(ratified)
        let ship = measure(shipping)
        print(String(format: "STRING ENGINE RT (256-frame blocks): " +
                     "off mean %.3fx p95 %.3fx max %.3fx | " +
                     "trim jt(%d str) mean %.3fx p95 %.3fx max %.3fx | " +
                     "ratified-serial jt(%d str) mean %.3fx p95 %.3fx " +
                     "max %.3fx | SHIPPING ratified+pool8+ASYNC " +
                     "mean %.3fx p95 %.3fx max %.3fx " +
                     "(drops %.0f, flat %.0f smp)",
                     off.mean, off.p95, off.max,
                     on.njt, on.mean, on.p95, on.max,
                     rat.njt, rat.mean, rat.p95, rat.max,
                     ship.mean, ship.p95, ship.max,
                     ship.drops, ship.flat))
        // the CALLBACK cost of the shipping config (async: the jt web
        // runs off-thread; the callback records + mixes only)
        XCTAssertLessThan(ship.p95, 0.3,
            "SHIPPING jt config too slow for the audio thread (p95)")
        // and the dispatcher must KEEP UP on an idle machine: no
        // dropped drive blocks; flat-fill only the pipeline's initial
        // fill (~one block) plus scheduling slop
        XCTAssertEqual(ship.drops, 0.0,
            "async jt dispatcher dropped drive blocks on idle machine")
        XCTAssertLessThan(ship.flat, 24000.0,
            "async jt web starved far beyond the pipeline fill")
    }

    /// MODAL-JAWARI live block (2026-07-21): jt-armed engine renders
    /// finite and audibly differs from the jt-off twin under identical
    /// MIDI (the DEFAULT-VALUE LAW sweep — bow_jtaraf_on ships 0, so
    /// this test runs the block ON); jt-off must stay byte-identical
    /// in behavior to a params set with no jt keys at all.
    func testModalJawariLiveBlock() {
        let sr = 48000.0
        func render(_ bp: BowParams, taraf: [(f: Double, gain: Double,
                                              t60: Double)]) -> [Double] {
            let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
            var tables = BowTables.buildOpenString(
                sr: sr * Double(osf), tonic: 261.63, bp: bp, taraf: taraf)
            let jtRows = taraf.filter {
                BowTables.jtSteelRow($0.f, tonic: 261.63)
            }
            tables.jt = BowTables.buildJawariTables(
                rows: jtRows, srk: sr * Double(osf), bp: bp)
            let mapper = BowControlMapper()
            let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                                   sr: sr, rfir: [],
                                   eLp: bp.v("bow_rad_lp", 8000.0),
                                   reverbRT60: 0.6, reverbPredelayMs: 10.0,
                                   reverbMix: 0.0, reverbWidth: 0.0)
            engine.outGain = 0.05
            mapper.midi(0x90, 60, 100)
            var l = [Double](repeating: 0, count: 1024)
            var r = [Double](repeating: 0, count: 1024)
            var out: [Double] = []
            var left = Int(1.2 * sr)
            while left > 0 {
                let m = min(1024, left)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                out.append(contentsOf: l[0..<m])
                left -= m
            }
            return out
        }
        let taraf = Self.testTaraf
        var on = Self.stringBP()
        on.num["bow_jtaraf_on"] = 1.0
        on.num["bow_jt_div"] = 2.0
        on.num["bow_jt_alpha"] = 1.5
        on.num["bow_jt_J"] = 20.0
        on.num["bow_jt_mcap"] = 48.0
        on.num["bow_jt_gain"] = 0.3
        on.num["bow_jt_drive"] = 0.03
        let yOn = render(on, taraf: taraf)
        XCTAssertTrue(yOn.allSatisfy(\.isFinite), "jt-armed render not finite")
        let off = Self.stringBP()
        let yOff = render(off, taraf: taraf)
        var diff = 0.0, ref = 0.0
        for i in 0..<min(yOn.count, yOff.count) {
            diff += (yOn[i] - yOff[i]) * (yOn[i] - yOff[i])
            ref += yOff[i] * yOff[i]
        }
        XCTAssertGreaterThan(diff, 1e-12 * max(ref, 1e-12),
                             "jt block armed but output identical")
    }

    func testMapperDrivenStringMakesSound() {
        let bp = Self.stringBP()
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: 261.63, bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp, sr: sr,
                               rfir: [], eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: 0.6, reverbPredelayMs: 10.0,
                               reverbMix: 0.0, reverbWidth: 0.0)
        engine.outGain = 0.05

        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
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
                    acc += s * s
                }
                n += m
                left -= m
            }
            return (acc / Double(n)).squareRoot()
        }

        // silence before the first note
        let idle = rms(seconds: 0.25)
        XCTAssertLessThan(idle, 1e-6, "string not silent before note-on")

        // bow a note
        mapper.midi(0x90, 60, 100)
        _ = rms(seconds: 0.3)                        // speak/settle
        let sustain = rms(seconds: 1.0)
        XCTAssertGreaterThan(sustain, 0.003, "bowed string made no sound")
        XCTAssertLessThan(sustain, 0.9, "bowed string at clipping level")

        // press authority must be alive through the ANALYTIC envelope:
        // full press is audibly (levels/timbre) different from none —
        // assert the mapped force ratio directly via the filter
        var filter = BowControlFilter(bp: bp, srk: sr * Double(osf),
                                      tonic: 261.63)
        func settledFb(press: Double) -> Double {
            let m2 = BowControlMapper()
            m2.midi(0x90, 60, 100)
            m2.setAxis(expr: 0.5, press: press, pos: 0.45)
            let n = 4096
            var a = [Double](repeating: 0, count: n)
            var b = a, c = a, d = a, e = a
            for _ in 0..<12 {
                a.withUnsafeMutableBufferPointer { pa in
                    b.withUnsafeMutableBufferPointer { pb in
                        c.withUnsafeMutableBufferPointer { pc in
                            d.withUnsafeMutableBufferPointer { pd in
                                e.withUnsafeMutableBufferPointer { pe in
                                    filter.fill(from: m2, n: n,
                                                f0: pa.baseAddress!,
                                                vb: pb.baseAddress!,
                                                fb: pc.baseAddress!,
                                                beta: pd.baseAddress!,
                                                gate: pe.baseAddress!)
                                }
                            }
                        }
                    }
                }
            }
            return c[n - 1]
        }
        let fbLo = settledFb(press: 0.0)
        filter.reset()
        let fbHi = settledFb(press: 1.0)
        XCTAssertGreaterThan(fbHi / max(fbLo, 1e-9), 4.0,
                             "press authority collapsed on the analytic envelope")

        // release decays
        mapper.midi(0x80, 60, 0)
        _ = rms(seconds: 1.0)
        let tail = rms(seconds: 0.5)
        XCTAssertLessThan(tail, sustain * 0.5, "string note did not release")
    }
}
