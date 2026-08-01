import XCTest
import CBowKernel
@testable import SarangiKit

/// POLYPHONIC bow instrument (2026-07-16): every held note is its own gut
/// string on the SAME bridge (bow_kernel_poly.c + the slot-table mapper).
///
/// Bars:
///  * mapper slot allocation is physical (chords = fresh strings, single
///    lines re-bow the same string = the mono meend law, note-off rings);
///  * the poly kernel's bridge sum is exact — on the rigid-bridge generic
///    string (V ≡ 0, zero coupling) a two-note render must equal the sum of
///    the two single-note renders bit-close (same code path both sides);
///  * a single note through the poly path is the SAME instrument as the
///    mono kernel (band-level compare — sample nulls are meaningless across
///    the chaotic friction loop, and the poly junction folds the string
///    loading delay-free where mono uses Vprev), swept OFF the bit-null
///    default of every "0 = BIT-NULL" kernel param and through BOTH string
///    mount paths (init and slot steal);
///  * an 8-note max-force chord on the full sarangi config stays BOUNDED
///    (the delay-free loading is the structural-stability claim) and
///    releases.
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
    /// DEFAULT-VALUE LAW (2026-07-17h): the shipped artifacts null both of
    /// these, and the poly kernel shipped a round mounting its strings in
    /// the WRONG friction state (full static grip instead of fresh contact)
    /// because parity had only ever been measured at `bow_age_a` 0. Any
    /// param introduced as "0 = BIT-NULL" belongs in this sweep.
    private static let nullSweep: [(name: String, over: [String: Double])] = [
        ("bit-null defaults", [:]),
        ("bow_age_a 0.5", ["bow_age_a": 0.5]),      // measured operating point
        ("bow_age_a 1.0", ["bow_age_a": 1.0]),
        ("bow_tors_c 0.35", ["bow_tors_c": 0.35]),  // round-10 fitted value
        ("age 0.5 + tors 0.35", ["bow_age_a": 0.5, "bow_tors_c": 0.35]),
        // continuum-release contact (2026-07-19d, hand-ported to poly)
        ("bow_cr_w 0.15", ["bow_cr_w": 0.15]),
        ("cr_w .15 + cr_ms .06 + age .5",
         ["bow_cr_w": 0.15, "bow_cr_ms": 0.06, "bow_age_a": 0.5]),
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
            Int32(t.L.count), t.L,
            t.cs, t.cp, t.w0, t.w1, t.w2, t.w3, t.w4, t.g, t.lpA, t.wout,
            t.kap, t.alphaw, t.jw, t.jl, t.jn, t.chg, t.zdrv, t.zi, t.twt,
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
            s[56], s[57], s[58], s[59], s[60])!
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

    func testMapperPolyAllocation() {
        let m = BowControlMapper()
        m.setSlotLimit(8)
        var snap = BowControlMapper.PolySnapshot(count: 8)

        func gated() -> [Int] {
            m.snapshotPoly(into: &snap)
            return snap.slots.indices.filter { snap.slots[$0].gate > 0 }
        }

        // chord: overlapping notes mount fresh strings on distinct slots
        m.midi(0x90, 60, 100)
        let g1 = gated()
        XCTAssertEqual(g1.count, 1)
        let slotC = g1[0]
        let serialC = snap.slots[slotC].serial
        m.midi(0x90, 64, 100)
        let g2 = gated()
        XCTAssertEqual(g2.count, 2, "overlapping note must take a new slot")
        let slotE = g2.first { $0 != slotC }!
        XCTAssertEqual(snap.slots[slotC].serial, serialC,
                       "held string must not be remounted by a chord note")
        let f0C = snap.slots[slotC].f0Target
        let f0E = snap.slots[slotE].f0Target
        XCTAssertEqual(f0C, 261.63, accuracy: 0.5)
        XCTAssertEqual(f0E, 329.63, accuracy: 0.5)

        // note-off releases only its slot (string keeps ringing there)
        m.midi(0x80, 60, 0)
        let g3 = gated()
        XCTAssertEqual(g3, [slotE])
        m.snapshotPoly(into: &snap)
        XCTAssertEqual(snap.slots[slotC].f0Target, f0C, accuracy: 0.5,
                       "released slot must keep its pitch (ring)")

        // single line: nothing gated → re-bow the most recent string at the
        // new pitch WITHOUT remounting (the mono meend glide)
        m.midi(0x80, 64, 0)
        let serialE = snap.slots[slotE].serial
        m.midi(0x90, 67, 100)
        let g4 = gated()
        XCTAssertEqual(g4, [slotE], "single line must stay on the last string")
        XCTAssertEqual(snap.slots[slotE].serial, serialE,
                       "single-line note change must glide, not remount")
        XCTAssertEqual(snap.slots[slotE].f0Target, 392.0, accuracy: 0.5)

        // re-bow of a note still ringing on a released slot reuses it
        m.midi(0x80, 67, 0)
        m.midi(0x90, 67, 100)        // hold G…
        m.midi(0x90, 60, 100)        // …chord C: C had slot 'slotC' ringing
        m.snapshotPoly(into: &snap)
        XCTAssertGreaterThan(snap.slots[slotC].gate, 0,
                             "same-note re-bow must land on its ringing slot")
        XCTAssertEqual(snap.slots[slotC].serial, serialC,
                       "same-note re-bow must not remount the string")

        // all-off
        m.midi(0xB0, 123, 0)
        XCTAssertTrue(gated().isEmpty)
    }

    func testMapperStealsOldestWhenFull() {
        let m = BowControlMapper()
        m.setSlotLimit(2)
        var snap = BowControlMapper.PolySnapshot(count: 2)
        m.midi(0x90, 60, 100)
        m.midi(0x90, 64, 100)
        m.snapshotPoly(into: &snap)
        let slot60 = snap.slots.indices.first {
            abs(snap.slots[$0].f0Target - 261.63) < 1.0 }!
        let s60 = snap.slots[slot60].serial
        m.midi(0x90, 67, 100)        // full: steals the oldest (60)
        m.snapshotPoly(into: &snap)
        XCTAssertEqual(snap.slots[slot60].f0Target, 392.0, accuracy: 0.5)
        XCTAssertNotEqual(snap.slots[slot60].serial, s60,
                          "a stolen slot mounts a fresh string")
        XCTAssertEqual(snap.slots.filter { $0.gate > 0 }.count, 2)
    }

    /// The mono facade (slotLimit 1) must reproduce the legacy held-stack:
    /// overlapping legato glides (no remount) and release falls BACK to the
    /// still-held note.
    func testMapperMonoFacadeBackGlide() {
        let m = BowControlMapper()
        m.setSlotLimit(1)
        m.midi(0x90, 60, 100)
        var snap = BowControlMapper.PolySnapshot(count: 1)
        m.snapshotPoly(into: &snap)
        let serial0 = snap.slots[0].serial
        m.midi(0x90, 64, 100)        // legato on the only string
        m.snapshotPoly(into: &snap)
        XCTAssertEqual(snap.slots[0].f0Target, 329.63, accuracy: 0.5)
        XCTAssertEqual(snap.slots[0].serial, serial0,
                       "effective-mono legato must glide, not remount")
        m.midi(0x80, 64, 0)          // back to the held 60
        m.snapshotPoly(into: &snap)
        XCTAssertEqual(snap.slots[0].f0Target, 261.63, accuracy: 0.5)
        XCTAssertGreaterThan(snap.slots[0].gate, 0,
                             "release with a held predecessor stays gated")
        m.midi(0x80, 60, 0)
        m.snapshotPoly(into: &snap)
        XCTAssertEqual(snap.slots[0].gate, 0)
    }

    // ------------------------------------------------------------------ //
    // poly kernel physics
    // ------------------------------------------------------------------ //

    /// Rigid bridge (generic string, V ≡ 0, deterministic): two strings on
    /// the shared bridge do not couple, so poly(A+B) must equal
    /// poly(A) + poly(B) — the bridge sum and the silent-string skip are
    /// exact. Same code path on both sides (no cross-compilation chaos).
    func testPolySuperpositionOnRigidBridge() {
        let bp = stringBP(noise: false)
        let srk = 96000.0
        let t = BowTables.buildOpenString(sr: srk, tonic: 261.63, bp: bp)
        let n = 48000                      // 0.5 s at the kernel rate
        let notes = [261.63, 392.0]

        func render(_ drive: [Bool]) -> [Double] {
            let pk = initPoly(2, tables: t)
            defer { bow_poly_free(pk) }
            var f0 = [Double](repeating: 0, count: 2 * n)
            var vb = f0, fb = f0, be = f0, ga = f0
            for b in 0..<2 {
                for i in 0..<n {
                    let o = b * n + i
                    f0[o] = notes[b]
                    vb[o] = 0.2
                    be[o] = 0.12
                    if drive[b] {
                        fb[o] = 1.0
                        ga[o] = min(Double(i) / (0.02 * srk), 1.0)
                    }
                }
            }
            let xv = [Double](repeating: 0, count: n)
            var out = [Double](repeating: 0, count: n)
            out.withUnsafeMutableBufferPointer { ob in
                bow_poly_process(pk, Int32(n), Int32(n), f0, vb, fb, be, ga,
                                 xv, ob.baseAddress!)
            }
            return out
        }

        let both = render([true, true])
        let onlyA = render([true, false])
        let onlyB = render([false, true])
        var maxErr = 0.0
        var scale = 0.0
        for i in 0..<n {
            maxErr = max(maxErr, abs(both[i] - (onlyA[i] + onlyB[i])))
            scale = max(scale, abs(both[i]))
        }
        XCTAssertGreaterThan(scale, 1e-3, "superposition render was silent")
        XCTAssertLessThan(maxErr, 1e-12 * max(scale, 1.0),
                          "rigid-bridge superposition broken (maxErr \(maxErr))")
    }

    /// One string through the poly kernel is the SAME instrument as the
    /// mono kernel. On the rigid bridge the poly changes are inert, so the
    /// only difference is compilation — early samples must null near
    /// bit-level, and the chaotic divergence beyond must not move energy.
    ///
    /// The SLOT-STEAL mount path (`bow_poly_reset_string`, taken by
    /// BowEngine on every serial bump) must land in the same fresh-contact
    /// state as a first allocation: a slot bowed on other controls, then
    /// remounted, must render exactly what a virgin slot renders. A bare
    /// memset lands the aging deficit at 0 (full static grip) instead of
    /// ageA, which only the unloaded friction branch would ever correct —
    /// so this is asserted with a gate that never releases. (The reference
    /// used to be the MONO kernel, which existed only for upstream
    /// byte-parity and was deleted 2026-07-24; poly-vs-poly states the same
    /// property more directly.)
    func testPolyRemountedStringMatchesFreshSlot() {
        let srk = 96000.0
        let n = 48000
        for (name, over) in Self.nullSweep {
            var bp = stringBP(noise: false)
            for (k, v) in over { bp.num[k] = v }
            let t = BowTables.buildOpenString(sr: srk, tonic: 261.63, bp: bp)
            // prelude ages the contact well away from its mount value
            let prelude = rigidDrive(n: 24000, f0: 174.61, vb: 0.35)
            let d = rigidDrive(n: n, f0: 261.63)
            assertRenderParity(
                polySlot0Render(tables: t, nb: 4, prelude: prelude, d),
                polySlot0Render(tables: t, nb: 4, d),
                "slot-steal mount / \(name)")
        }
    }

    /// Driven from the SHIPPING artifact + the fitted tarab, so this is the
    /// instrument the app actually plays under a maximum-force chord. (It
    /// used to be configured from the coupled network's table-export golden,
    /// which went with the vendored machinery, 2026-07-24.)
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

    /// Live-shaped poly smoke on the generic string: a held triad sounds all
    /// three fundamentals (each on its own string), then rings out.
    func testPolyTriadOnGenericString() {
        let bp = stringBP(noise: true)
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: 261.63, bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp, sr: sr,
                               rfir: [], eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: 0.6, reverbPredelayMs: 10.0,
                               reverbMix: 0.0, reverbWidth: 0.0, maxPoly: 4)
        engine.outGain = 0.05

        var mono = [Double]()
        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        func run(seconds: Double) {
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
                    XCTAssertTrue(l[i].isFinite)
                    mono.append(l[i] + r[i])
                }
                left -= m
            }
        }

        run(seconds: 0.2)
        let idle = (mono.reduce(0) { $0 + $1 * $1 } / Double(mono.count))
            .squareRoot()
        XCTAssertLessThan(idle, 1e-6, "poly string not silent before notes")

        mapper.setAxis(expr: 0.6, press: 0.55, pos: 0.45)
        mapper.midi(0x90, 60, 100)
        mapper.midi(0x90, 64, 100)
        mapper.midi(0x90, 67, 100)
        run(seconds: 2.0)

        // all three fundamentals present in the settled second. The friction
        // loop pulls the sounding pitch a few cents off nominal (that is
        // what the calibrated pitch correction exists for; this bp carries
        // none) — scan ±25 cents so the 1 Hz Goertzel bin lands on it.
        let a = mono.count - Int(sr)
        let floorDB = goertzelDB(mono, from: a, to: mono.count, sr: sr,
                                 f: 233.0)          // off-grid reference
        for f in [261.63, 329.63, 392.0] {
            var db = -300.0
            for c in stride(from: -25.0, through: 25.0, by: 5.0) {
                db = max(db, goertzelDB(mono, from: a, to: mono.count,
                                        sr: sr, f: f * pow(2.0, c / 1200.0)))
            }
            XCTAssertGreaterThan(db, floorDB + 10.0,
                                 "triad note at \(f) Hz missing (\(db) dB vs floor \(floorDB))")
        }

        // release: all strings ring out
        let susStart = mono.count - Int(sr)
        let sustain = (mono[susStart...].reduce(0) { $0 + $1 * $1 }
            / Double(Int(sr))).squareRoot()
        mapper.midi(0xB0, 123, 0)
        run(seconds: 2.0)
        let tailStart = mono.count - Int(0.5 * sr)
        let tail = (mono[tailStart...].reduce(0) { $0 + $1 * $1 }
            / Double(mono.count - tailStart)).squareRoot()
        XCTAssertLessThan(tail, sustain * 0.5, "poly triad did not release")
    }
}
