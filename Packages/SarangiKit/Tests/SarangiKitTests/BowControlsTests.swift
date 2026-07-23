import XCTest
@testable import SarangiKit

/// GATE B of the live bow port: deterministic control mapping — scripted
/// MIDI/axis events through `BowControlMapper` + `BowControlFilter` must
/// land on the control-law spot values (gate one-pole, meend pitch glide +
/// per-octave cents correction, dyn_p loudness inversion) and EVERY output
/// sample must sit inside the playable bounds (wedge force clamp, velocity
/// and beta ranges). Uses the REAL fitted bow params from the table-parity
/// golden so the wedge/pitch tables are the shipping ones.
final class BowControlsTests: XCTestCase {

    let srk = 96000.0

    private func fittedBP() throws -> BowParams {
        guard let url = Bundle.module.url(forResource: "bow_tables_default",
                                          withExtension: "json",
                                          subdirectory: "Goldens"),
              let obj = try? JSONSerialization.jsonObject(
                  with: Data(contentsOf: url)) as? [String: Any],
              let bpj = obj["bp"] as? [String: Any],
              let bp = BowParams(json: bpj) else {
            throw XCTSkip("bow_tables_default golden not found")
        }
        return bp
    }

    /// Run `seconds` of fill in engine-buffer-sized chunks (512 @96k),
    /// concatenating the outputs.
    private func run(_ mapper: BowControlMapper, _ filter: inout BowControlFilter,
                     seconds: Double)
        -> (f0: [Double], vb: [Double], fb: [Double], beta: [Double], gate: [Double]) {
        let n = Int(seconds * srk)
        var f0 = [Double](repeating: 0, count: n)
        var vb = f0, fb = f0, beta = f0, gate = f0
        let chunk = 512
        var base = 0
        while base < n {
            let m = min(chunk, n - base)
            f0.withUnsafeMutableBufferPointer { a in
                vb.withUnsafeMutableBufferPointer { b in
                    fb.withUnsafeMutableBufferPointer { c in
                        beta.withUnsafeMutableBufferPointer { d in
                            gate.withUnsafeMutableBufferPointer { e in
                                filter.fill(from: mapper, n: m,
                                            f0: a.baseAddress! + base,
                                            vb: b.baseAddress! + base,
                                            fb: c.baseAddress! + base,
                                            beta: d.baseAddress! + base,
                                            gate: e.baseAddress! + base)
                            }
                        }
                    }
                }
            }
            base += m
        }
        return (f0, vb, fb, beta, gate)
    }

    func testGateSofteningAndPitchTarget() throws {
        let bp = try fittedBP()
        let mapper = BowControlMapper()
        var filter = BowControlFilter(bp: bp, srk: srk)

        // silence before any note: gate stays closed
        let idle = run(mapper, &filter, seconds: 0.05)
        XCTAssertEqual(idle.gate.max() ?? 1, 0.0)

        // note on A4: the ~25 ms one-pole reaches 1−e⁻¹ at 25 ms
        mapper.midi(0x90, 69, 100)
        let on = run(mapper, &filter, seconds: 1.0)
        let k25 = Int(0.025 * srk) - 1
        XCTAssertEqual(on.gate[k25], 1.0 - exp(-1.0), accuracy: 0.02)
        XCTAssertGreaterThan(on.gate.last!, 0.999)
        // gate is monotone non-decreasing on a held note
        for i in 1..<200 { XCTAssertGreaterThanOrEqual(on.gate[i], on.gate[i - 1]) }

        // converged pitch = 440 Hz + the calibrated per-octave cents pull
        let corr = bp.pitchCorrection(f0: 440.0)
        let want = 440.0 * pow(2.0, corr / 1200.0)
        XCTAssertEqual(on.f0.last!, want, accuracy: want * 1e-6)

        // legato to A5: meend-limited glide (two 9 Hz one-poles) — monotone,
        // no jump, converged within 0.5 s
        mapper.midi(0x90, 81, 100)
        let up = run(mapper, &filter, seconds: 0.5)
        for i in 1..<up.f0.count {
            XCTAssertGreaterThanOrEqual(up.f0[i], up.f0[i - 1] - 1e-9)
        }
        // a bowed string glides: after 2 ms the pitch has moved < a quartertone
        let early = 1200.0 * log2(up.f0[Int(0.002 * srk)] / on.f0.last!)
        XCTAssertLessThan(early, 50.0)
        let corr5 = bp.pitchCorrection(f0: 880.0)
        let want5 = 880.0 * pow(2.0, corr5 / 1200.0)
        XCTAssertEqual(up.f0.last!, want5, accuracy: want5 * 1e-4)

        // note off: gate closes on the same time constant
        mapper.midi(0x80, 81, 0)
        mapper.midi(0x80, 69, 0)
        let off = run(mapper, &filter, seconds: 0.5)
        XCTAssertLessThan(off.gate.last!, 1e-3)
    }

    func testDynamicsInversionSpotValues() throws {
        let bp = try fittedBP()
        let vLo = bp.v("bow_v_lo", 0.05), vHi = bp.v("bow_v_hi", 0.35)
        let dynP = bp.v("dyn_p", 0.0)
        try XCTSkipIf(dynP <= 0.1, "fitted artifact has no dyn_p — affine map")
        let vRef = 0.75 * vHi
        let mapper = BowControlMapper()
        var filter = BowControlFilter(bp: bp, srk: srk)
        mapper.midi(0x90, 69, 100)

        // expr = 1 → rel = +5 dB through the calibrated loudness law
        mapper.midi(0xB0, 11, 127)
        _ = run(mapper, &filter, seconds: 0.1)          // settle the lerp
        let loud = run(mapper, &filter, seconds: 0.01)
        let wantLoud = min(max(vRef * pow(10.0, 5.0 / (20.0 * dynP)), vLo),
                           1.3 * vHi)
        XCTAssertEqual(loud.vb.last!, wantLoud, accuracy: 1e-9)

        // quiet but ABOVE the expr lift (bow_expr_lift: below it the bow
        // lifts to true silence — asserted below): CC 28 → expr ~0.22
        mapper.midi(0xB0, 11, 28)
        _ = run(mapper, &filter, seconds: 0.1)
        let quiet = run(mapper, &filter, seconds: 0.01)
        let exprQ = Double(28) / 127.0
        // the loudness law rides [exprLift, 1] (the fade zone below the
        // lift is separate — offline pianissimo bows at the velocity floor)
        let lift = bp.v("bow_expr_lift", 0.0)
        let eDyn = lift > 1e-6 && lift < 1.0
            ? min(max((exprQ - lift) / (1.0 - lift), 0.0), 1.0) : exprQ
        let relQ = -14.0 + 19.0 * eDyn
        var wantQuiet = min(max(vRef * pow(10.0, relQ / (20.0 * dynP)), vLo),
                            1.3 * vHi)
        if lift > 1e-6 { wantQuiet *= min(1.0, exprQ / lift) }
        XCTAssertEqual(quiet.vb.last!, wantQuiet, accuracy: 1e-9)

        // BOW LIFTS TO SILENCE at expr 0 (the 2026-07-11 live fix): both
        // velocity and force fade to 0 — the string is released, not bowed
        // at the velocity floor.
        if lift > 1e-6 {
            mapper.midi(0xB0, 11, 0)
            _ = run(mapper, &filter, seconds: 0.1)
            let off = run(mapper, &filter, seconds: 0.01)
            XCTAssertLessThan(off.vb.last!, 1e-9, "expr 0 must lift the bow")
            XCTAssertLessThan(off.fb.last!, 1e-9, "expr 0 must release force")
        }
    }

    func testAllOutputsInsidePlayableBounds() throws {
        let bp = try fittedBP()
        try XCTSkipIf(bp.wedge == nil, "fitted artifact has no wedge")
        let vLo = bp.v("bow_v_lo", 0.05), vHi = bp.v("bow_v_hi", 0.35)
        let fCap = bp.v("bow_f_cap", 2.6)
        let pU = bp.v("bow_live_press_under", 0.55)
        let pO = bp.v("bow_live_press_over", 1.25)
        let tiltForce = bp.v("bow_tilt_force", 0.0)
        let mapper = BowControlMapper()
        var filter = BowControlFilter(bp: bp, srk: srk)

        // scripted sweep: notes across 2.5 octaves, axes to their extremes
        let script: [(UInt8, UInt8, UInt8)] = [
            (0x90, 57, 100),                    // A3
            (0xB0, 11, 127), (0xB0, 1, 127),    // loud, heavy
            (0x90, 69, 100), (0x80, 57, 0),
            (0xB0, 74, 0), (0xB0, 2, 127),      // off the bridge, full tilt
            (0x90, 81, 100), (0x80, 69, 0),
            // quiet, light — but ABOVE the expr lift (CC 28 → expr ~0.22 >
            // bow_expr_lift 0.2): below it the bow lifts to true silence,
            // deliberately leaving the playable bounds (tested in the
            // dynamics spot-value test)
            (0xB0, 11, 28), (0xB0, 1, 0),
            (0xB0, 74, 127), (0xB0, 2, 0),      // toward the bridge, dark
            (0x90, 88, 100), (0x80, 81, 0),     // E6 — top of the melody range
        ]
        var all: [(f0: Double, vb: Double, fb: Double, beta: Double, gate: Double)] = []
        for ev in script {
            mapper.midi(ev.0, ev.1, ev.2)
            let seg = run(mapper, &filter, seconds: 0.12)
            for i in stride(from: 0, to: seg.f0.count, by: 7) {
                all.append((seg.f0[i], seg.vb[i], seg.fb[i], seg.beta[i],
                            seg.gate[i]))
            }
        }
        let w = bp.wedge!
        // 2026-07-16 wedge-relative remap: the wedge is the press axis'
        // ENVELOPE (edges deliberately reachable with pressUnder/pressOver
        // overshoot; β extrapolates by the Schelleng laws beyond the
        // measured grid), no longer a clamp. Tilt/register multipliers may
        // push past it; bow_f_cap is the hard guard.
        let tiltMax = exp2(tiltForce * BowControlMapper.tiltMaxDb / 12.0)
        let tiltMin = exp2(tiltForce * BowControlMapper.tiltMinDb / 12.0)
        for s in all {
            XCTAssertTrue(s.f0.isFinite && s.vb.isFinite && s.fb.isFinite
                          && s.beta.isFinite)
            XCTAssertGreaterThanOrEqual(s.vb, vLo - 1e-12)
            XCTAssertLessThanOrEqual(s.vb, 1.3 * vHi + 1e-12)
            XCTAssertGreaterThan(s.beta, 0.02)     // sane bow position
            XCTAssertLessThan(s.beta, 0.30)
            XCTAssertGreaterThanOrEqual(s.gate, 0.0)
            XCTAssertLessThanOrEqual(s.gate, 1.0)
            XCTAssertLessThanOrEqual(s.fb, fCap + 1e-9, "force over hard cap")
            let bg = min(max(s.beta, w.beta[0]), w.beta[w.beta.count - 1])
            let b = w.bounds(f0: s.f0, beta: bg, v: s.vb)
            let r = bg / s.beta
            let lo = b.lo * r * r, hi = max(b.hi * r, b.lo * r * r * 1.05)
            // extreme ponticello + full tilt can push the Schelleng floor
            // past the hard cap — the cap wins (the string may whistle
            // there, which is what extreme ponticello does); negative tilt
            // (hair away) deliberately lightens below the press floor
            XCTAssertGreaterThanOrEqual(s.fb, min(pU * lo * tiltMin, fCap) - 1e-9,
                                        "force under envelope floor @f0 \(s.f0)")
            XCTAssertLessThanOrEqual(s.fb, pO * hi * tiltMax + 1e-9,
                                     "force over envelope ceiling @f0 \(s.f0)")
        }
    }

    /// THE POINT of the 2026-07-16 remap (reports/press_pos_authority.html):
    /// press/pos must have real, register-uniform authority. The old
    /// absolute-force law was a NO-OP at 247 Hz (wedge floor ×1.6 exceeded
    /// the whole mapped range — press 0 and press 1 rendered identically).
    func testPressPosAuthority() throws {
        let bp = try fittedBP()
        try XCTSkipIf(bp.wedge == nil, "fitted artifact has no wedge")
        let w = bp.wedge!
        let pU = bp.v("bow_live_press_under", 0.55)
        let pO = bp.v("bow_live_press_over", 1.25)
        let betaLo = bp.v("bow_live_beta_lo", 0.04)
        let betaHi = bp.v("bow_live_beta_hi", 0.22)

        func settled(note: UInt8, press: Double, pos: Double)
            -> (f0: Double, vb: Double, fb: Double, beta: Double) {
            let mapper = BowControlMapper()
            var filter = BowControlFilter(bp: bp, srk: srk)
            mapper.midi(0x90, note, 100)
            mapper.setAxis(expr: 0.5, press: press, pos: pos)
            _ = run(mapper, &filter, seconds: 0.6)          // settle glides
            let s = run(mapper, &filter, seconds: 0.01)
            return (s.f0.last!, s.vb.last!, s.fb.last!, s.beta.last!)
        }

        // B3 ≈ 247 Hz — the old law's DEAD register
        for note: UInt8 in [59, 64, 71, 76] {               // B3 E4 B4 E5
            let lo = settled(note: note, press: 0.0, pos: 0.45)
            let hiP = settled(note: note, press: 1.0, pos: 0.45)
            // ≥ 4× force span everywhere (old law: 1.0× at 247/415 Hz)
            XCTAssertGreaterThan(hiP.fb / lo.fb, 4.0,
                                 "press authority collapsed @note \(note)")
            // press 0 reaches UNDER the lock floor, press 1 past the ceiling
            let bnd = w.bounds(f0: lo.f0, beta: lo.beta, v: lo.vb)
            XCTAssertLessThan(lo.fb, bnd.lo * 1.001,
                              "press 0 cannot reach flautando @note \(note)")
            XCTAssertGreaterThan(hiP.fb, bnd.hi * 0.999,
                                 "press 1 cannot reach grit @note \(note)")
            XCTAssertEqual(lo.fb, pU * bnd.lo, accuracy: pU * bnd.lo * 1e-6)
            XCTAssertEqual(hiP.fb, pO * bnd.hi, accuracy: pO * bnd.hi * 1e-6)
        }

        // pos spans the full live β range (ponticello ↔ tasto)
        let pont = settled(note: 64, press: 0.562, pos: 0.0)
        let tasto = settled(note: 64, press: 0.562, pos: 1.0)
        XCTAssertEqual(pont.beta, betaLo, accuracy: 1e-9)
        XCTAssertEqual(tasto.beta, betaHi, accuracy: 1e-9)
        // β beyond the measured grid still gets a HIGHER force floor near
        // the bridge (Schelleng fmin ∝ 1/β²) — the extrapolation is live
        XCTAssertGreaterThan(pont.fb, tasto.fb,
                             "bridge-side force floor must exceed tasto's")
    }

    /// The ANALYTIC Schelleng envelope (wedge == nil — the generic
    /// pure-physics bowed string): press spot values must land exactly on
    /// the formulas fmin = M·C·v/β², fmax = 2Zv/(β·Δμ), capped at bow_f_cap.
    func testAnalyticSchellengEnvelope() {
        let bp = BowedStringEngineTests.stringBP()
        XCTAssertNil(bp.wedge)
        let srk = 96000.0
        let pU = bp.v("bow_live_press_under", 0.55)
        let pO = bp.v("bow_live_press_over", 1.25)
        let fCap = bp.v("bow_f_cap", 2.6)
        let marg = bp.v("bow_schelleng_margin", 1.2)
        let cS = bp.v("bow_schelleng_c", 0.055)
        let Z = bp.v("bow_Z", 1.0)
        let dmu = max(bp.v("bow_mu_s", 0.8) - bp.v("bow_mu_d", 0.3), 1e-3)

        func settled(note: UInt8, press: Double, pos: Double)
            -> (vb: Double, fb: Double, beta: Double) {
            let mapper = BowControlMapper()
            var filter = BowControlFilter(bp: bp, srk: srk)
            mapper.midi(0x90, note, 100)
            mapper.setAxis(expr: 0.5, press: press, pos: pos)
            _ = run(mapper, &filter, seconds: 0.6)
            let s = run(mapper, &filter, seconds: 0.01)
            return (s.vb.last!, s.fb.last!, s.beta.last!)
        }

        for note: UInt8 in [48, 60, 72, 84] {          // C3..C6
            let lo = settled(note: note, press: 0.0, pos: 0.45)
            let hi = settled(note: note, press: 1.0, pos: 0.45)
            let fmin = marg * cS * lo.vb / (lo.beta * lo.beta)
            let fmax = max(2.0 * Z * hi.vb / (hi.beta * dmu), fmin * 1.05)
            XCTAssertEqual(lo.fb, min(pU * fmin, fCap),
                           accuracy: max(1e-9, lo.fb * 1e-6),
                           "press-0 floor wrong @note \(note)")
            XCTAssertEqual(hi.fb, min(pO * fmax, fCap),
                           accuracy: max(1e-9, hi.fb * 1e-6),
                           "press-1 ceiling wrong @note \(note)")
            XCTAssertGreaterThan(hi.fb / lo.fb, 4.0,
                                 "press authority collapsed @note \(note)")
        }
    }

    /// ATTACK BITE (2026-07-17d): a fresh onset at HIGH press briefly
    /// OVER-forces (fb transient above its own settled level) — the fast,
    /// forceful bite that drives the kernel's upper-harmonic multi-slip. An
    /// onset BELOW bow_attack_thresh gets no such transient (legato). The
    /// force cap does NOT clip the transient (bite is a martelé over-press).
    func testAttackBite() {
        var bp = BowedStringEngineTests.stringBP()
        bp.num["bow_place_ms"] = 15.0
        bp.num["bow_draw_ms"] = 40.0
        bp.num["bow_draw_min_ms"] = 8.0
        bp.num["bow_attack_bite"] = 2.0
        bp.num["bow_attack_bite_ms"] = 60.0
        bp.num["bow_attack_thresh"] = 0.5
        bp.num["bow_f_cap"] = 12.0          // headroom so the bite isn't capped

        func trace(press: Double) -> (peak: Double, settled: Double) {
            let mapper = BowControlMapper()
            var filter = BowControlFilter(bp: bp, srk: srk)
            mapper.setAxis(expr: 0.7, press: press, pos: 0.45)
            mapper.midi(0x90, 60, 100)
            let s = run(mapper, &filter, seconds: 0.4)
            // settled = the tail (bite fully decayed); peak = the whole trace
            let settled = Array(s.fb.suffix(Int(0.05 * srk))).max()!
            return (s.fb.max()!, settled)
        }

        let hard = trace(press: 1.0)        // sharp = 1.0
        XCTAssertGreaterThan(hard.peak / hard.settled, 1.6,
                             "high-press onset must over-force (bite)")

        let soft = trace(press: 0.4)        // below thresh → sharp 0
        XCTAssertLessThan(soft.peak / soft.settled, 1.05,
                          "below-threshold onset must NOT bite (legato)")

        // the DRAW LERP is the other half of the law — a force spike on an
        // already-sounding string is a WEAK bite; the FAST velocity onset is
        // what drives the multi-slip. Sampled at 30 ms: past place 15 +
        // drawMin 8, well inside place 15 + draw 40.
        func velocity(press: Double) -> (at30ms: Double, settled: Double) {
            let mapper = BowControlMapper()
            var filter = BowControlFilter(bp: bp, srk: srk)
            mapper.setAxis(expr: 0.7, press: press, pos: 0.45)
            mapper.midi(0x90, 60, 100)
            let s = run(mapper, &filter, seconds: 0.4)
            return (s.vb[Int(0.030 * srk) - 1], s.vb.last!)   // vb[k] is t=(k+1)/srk
        }
        let vSharp = velocity(press: 1.0)
        let vLegato = velocity(press: 0.4)
        XCTAssertEqual(vSharp.settled, vLegato.settled,
                       accuracy: vSharp.settled * 1e-9,
                       "press must not move the settled velocity")
        XCTAssertGreaterThan(vSharp.at30ms, 0.95 * vSharp.settled,
                             "sharp attack must be fully drawn by 30 ms")
        XCTAssertLessThan(vLegato.at30ms, 0.5 * vLegato.settled,
                          "legato attack must still be drawing at 30 ms")

        // BIT-NULL: at bite 0 with the draw floor equal to the draw time the
        // bite keys must not perturb place-then-draw by a single ULP (the
        // sarangi bow artifact carries none of them — control-layer only, no
        // golden regen).
        func fbvb(_ b: BowParams) -> [Double] {
            let mapper = BowControlMapper()
            var filter = BowControlFilter(bp: b, srk: srk)
            mapper.setAxis(expr: 0.7, press: 1.0, pos: 0.45)
            mapper.midi(0x90, 60, 100)
            let s = run(mapper, &filter, seconds: 0.4)
            return s.fb + s.vb
        }
        var bp0 = BowedStringEngineTests.stringBP()
        bp0.num["bow_place_ms"] = 15.0
        bp0.num["bow_draw_ms"] = 40.0
        var bpNull = bp0
        bpNull.num["bow_draw_min_ms"] = 40.0
        bpNull.num["bow_attack_bite"] = 0.0
        bpNull.num["bow_attack_bite_ms"] = 60.0
        bpNull.num["bow_attack_thresh"] = 0.5
        XCTAssertEqual(fbvb(bp0), fbvb(bpNull),
                       "bite keys are not bit-null at bow_attack_bite 0")
    }
}
