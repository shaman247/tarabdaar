import XCTest
@testable import SarangiKit

/// The sustain-liveness layer (2026-08-01, fitted to clean SWAM Violin 3
/// captures): post-onset settle, OU drift walks (pitch/level/force) and the
/// glide-rate bow lightening in `BowControlFilter`. Filter-level and
/// deterministic — no kernel render.
final class LivenessTests: XCTestCase {

    let srk = 96000.0

    private func bp(_ extra: [String: Double]) -> BowParams {
        // A dyn_p-free affine map keeps the vb law trivial: vb depends only
        // on expr, so any vb motion below is the liveness layer's own.
        var num: [String: Double] = [
            "bow_v_lo": 0.1, "bow_v_hi": 0.3,
            "bow_place_ms": 35.0, "bow_draw_ms": 60.0,
        ]
        for (k, v) in extra { num[k] = v }
        return BowParams(num: num)
    }

    private func run(_ mapper: BowControlMapper, _ filter: inout BowControlFilter,
                     seconds: Double)
        -> (f0: [Double], vb: [Double], fb: [Double]) {
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
        return (f0, vb, fb)
    }

    /// Settle: untouched through the early attack, ~full depth just after
    /// the draw ends, gone a few taus later.
    func testSettleShape() {
        let params = bp(["bow_settle_db": 6.0, "bow_settle_ms": 130.0])
        let clean = bp([:])
        let m1 = BowControlMapper(), m2 = BowControlMapper()
        var f1 = BowControlFilter(bp: params, srk: srk)
        var f2 = BowControlFilter(bp: clean, srk: srk)
        m1.midi(0x90, 69, 100); m2.midi(0x90, 69, 100)
        let a = run(m1, &f1, seconds: 1.6)
        let b = run(m2, &f2, seconds: 1.6)
        func cutDb(_ t: Double) -> Double {
            let i = Int(t * srk)
            return 20.0 * log10(b.vb[i] / a.vb[i])
        }
        // t0 = place + draw = 95 ms
        XCTAssertLessThan(cutDb(0.020), 1.0, "staccato-bite window must stay hot")
        XCTAssertGreaterThan(cutDb(0.100), 5.0, "full settle right after the draw")
        XCTAssertLessThan(cutDb(0.095 + 5 * 0.130), 0.6, "settled out by ~5 tau")
        // monotone decay after the peak
        XCTAssertGreaterThan(cutDb(0.150), cutDb(0.400))
    }

    /// Drift: the sounding pitch wanders with roughly the configured std,
    /// stays bounded, and the walk is deterministic per seed.
    func testDriftBoundedAndDeterministic() {
        let params = bp(["bow_drift_cents": 2.0, "bow_drift_hz": 1.2])
        let m = BowControlMapper()
        m.midi(0x90, 69, 100)
        var f1 = BowControlFilter(bp: params, srk: srk)
        var f2 = BowControlFilter(bp: params, srk: srk)
        let a = run(m, &f1, seconds: 4.0)
        let b = run(m, &f2, seconds: 4.0)
        XCTAssertEqual(a.f0, b.f0, "same seed, same walk")
        var f3 = BowControlFilter(bp: params, srk: srk)
        f3.seedDrift(3)
        let c = run(m, &f3, seconds: 4.0)
        XCTAssertNotEqual(a.f0, c.f0, "seedDrift decorrelates slots")
        // measure the wander over the settled tail (skip the glide-in)
        let tail = Array(a.f0[Int(1.0 * srk)...])
        let ref = tail.reduce(0, +) / Double(tail.count)
        let cents = tail.map { 1200.0 * log2($0 / ref) }
        let std = sqrt(cents.map { $0 * $0 }.reduce(0, +) / Double(cents.count))
        XCTAssertGreaterThan(std, 0.4, "drift must actually move the pitch")
        XCTAssertLessThan(std, 4.0, "and stay near the configured 2 c")
        XCTAssertLessThan(cents.map(abs).max()!, 3.0 * 2.0 + 0.5, "±3σ bound")
    }

    /// Glide dip: a legato pitch step dips the bow; a drifting held note
    /// does not.
    func testGlideDipFiresOnGlideOnly() {
        let params = bp(["bow_glide_dip_db": 5.0, "bow_glide_dip_rate": 900.0,
                         "bow_drift_cents": 0.6, "bow_drift_hz": 1.2])
        let m = BowControlMapper()
        m.midi(0x90, 69, 100)
        var f = BowControlFilter(bp: params, srk: srk)
        let held = run(m, &f, seconds: 2.0)
        let vbHold = held.vb[Int(1.9 * srk)]
        // held note (drift only): no audible dip
        let holdMin = held.vb[Int(1.0 * srk)...].min()!
        XCTAssertGreaterThan(20 * log10(holdMin / vbHold), -0.8)
        // legato step of 3 semitones: the dip engages while the pitch moves
        m.midi(0x90, 72, 100)
        let step = run(m, &f, seconds: 0.6)
        let dipDb = 20 * log10(step.vb.min()! / vbHold)
        XCTAssertLessThan(dipDb, -2.5, "legato transition must lighten the bow")
        // and recovers once the glide lands
        let endDb = 20 * log10(step.vb.last! / vbHold)
        XCTAssertGreaterThan(endDb, -1.0)
    }

    /// All keys absent → the layer is inert: bit-identical to a build that
    /// has never heard of it (the golden/parity contract).
    func testAbsentKeysAreBitNull() {
        let m1 = BowControlMapper(), m2 = BowControlMapper()
        var f1 = BowControlFilter(bp: bp([:]), srk: srk)
        var f2 = BowControlFilter(bp: bp(["bow_settle_db": 0.0,
                                          "bow_drift_cents": 0.0,
                                          "bow_glide_dip_db": 0.0]), srk: srk)
        m1.midi(0x90, 69, 100); m2.midi(0x90, 69, 100)
        let a = run(m1, &f1, seconds: 0.5)
        let b = run(m2, &f2, seconds: 0.5)
        XCTAssertEqual(a.vb, b.vb)
        XCTAssertEqual(a.f0, b.f0)
        XCTAssertEqual(a.fb, b.fb)
    }

    /// SETTLE EXEMPTION (2026-08-19, `bow_settle_sharp`): a SHARP attack
    /// keeps its level — depth × (1 − settleSharp·sharpness) — while a
    /// gentle attack keeps the fitted ease-down. 0 = bit-null.
    func testSettleSharpExemption() {
        func trace(press: Double, extra: [String: Double]) -> [Double] {
            let m = BowControlMapper()
            m.setAxis(press: press)
            m.midi(0x90, 69, 100)
            var f = BowControlFilter(bp: bp(extra), srk: srk)
            return run(m, &f, seconds: 0.8).vb
        }
        let settle: [String: Double] = ["bow_settle_db": 6.0,
                                        "bow_settle_ms": 130.0]
        let exempt = settle.merging(["bow_settle_sharp": 1.0]) { $1 }
        // Full-sharp attack (press 1 over the default 0.5 threshold =
        // sharpness 1): the exemption cancels the settle EXACTLY —
        // bit-identical to a settle-free build.
        XCTAssertEqual(trace(press: 1.0, extra: exempt),
                       trace(press: 1.0, extra: [:]),
                       "a full-sharp attack must keep its level")
        // Gentle attack (press below the threshold = sharpness 0): the
        // fitted settle runs untouched.
        XCTAssertEqual(trace(press: 0.4, extra: exempt),
                       trace(press: 0.4, extra: settle),
                       "a gentle attack must keep the fitted settle")
        XCTAssertNotEqual(trace(press: 0.4, extra: exempt),
                          trace(press: 0.4, extra: [:]),
                          "the settle must still act on gentle attacks")
        // 0 = bit-null against the absent key.
        XCTAssertEqual(trace(press: 1.0,
                             extra: settle.merging(["bow_settle_sharp": 0.0]) { $1 }),
                       trace(press: 1.0, extra: settle),
                       "bow_settle_sharp 0 must equal the absent key")
    }

    /// reset() rewinds the RNG: a panic-then-replay produces the same take.
    func testResetReproducible() {
        let params = bp(["bow_drift_cents": 2.0, "bow_settle_db": 6.0,
                         "bow_glide_dip_db": 5.0])
        let m = BowControlMapper()
        m.midi(0x90, 69, 100)
        var f = BowControlFilter(bp: params, srk: srk)
        f.seedDrift(2)
        let a = run(m, &f, seconds: 1.0)
        f.reset()
        let b = run(m, &f, seconds: 1.0)
        XCTAssertEqual(a.f0, b.f0)
        XCTAssertEqual(a.vb, b.vb)
    }
}
