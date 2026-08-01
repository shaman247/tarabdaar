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

    /// The SHIPPING artifact, so the wedge/pitch tables under test are the
    /// ones the app plays. (This used to read the `bp` section out of an
    /// upstream table-export golden — that golden went with the rest of the
    /// vendored parity machinery, 2026-07-24.)
    private func fittedBP() throws -> BowParams {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
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

    /// The ANALYTIC Schelleng envelope — the ONLY force law now that the
    /// measured `BowWedge` table is gone (the pure-physics artifact never
    /// carried one, so this was always the branch that ran). Press spot
    /// values must land exactly on fmin = M·C·v/β², fmax = 2Zv/(β·Δμ),
    /// capped at bow_f_cap.
    func testAnalyticSchellengEnvelope() {
        let bp = BowedStringEngineTests.stringBP()
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
