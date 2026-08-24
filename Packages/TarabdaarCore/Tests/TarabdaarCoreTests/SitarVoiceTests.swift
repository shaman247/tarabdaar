import XCTest
@testable import TarabdaarCore
import SarangiKit

/// Sitar voice wiring guards (2026-08-19):
///  - the `st_*` registry group exists, is all-`.live`, and its defaults
///    match the AudioEngine wiring's resting values (the unified apply
///    pushes every live param at startup — a drifted default would
///    silently retrim the voice);
///  - `st_gain`'s default IS the artifact's fitted trim (same convention
///    as `tp_gain`);
///  - the sitar artifact loads and mounts a JI engine (the smoke test —
///    the fit itself lives upstream in scripts/sitar_fit.py).
final class SitarVoiceTests: XCTestCase {

    func testSitarRegistryGroup() {
        let group = ParamRegistry.groups.first { $0.name == "Sitar" }
        XCTAssertNotNil(group, "Sitar group missing from ParamRegistry")
        let keys = Set(group!.params.map(\.key))
        XCTAssertEqual(keys, ["st_gain", "st_pluck_level", "st_rel_t60",
                              "st_pluck_touch", "st_poly",
                              "st_pluck_drive", "st_taraf"])
        for spec in group!.params {
            XCTAssertEqual(spec.apply, .live,
                           "\(spec.key): sitar params all route .live")
        }
        // resting defaults must match AudioEngine's storage
        XCTAssertEqual(ParamRegistry.spec("st_pluck_level")!.def, 1.0)
        XCTAssertEqual(ParamRegistry.spec("st_rel_t60")!.def, 0.15)
        // pluck isolation ships ON for the sitar (fret runs re-pluck at
        // NEW pitches — isolation keeps a previous note's tail at its
        // own pitch instead of retuning history with the glide)
        XCTAssertEqual(ParamRegistry.spec("st_pluck_touch")!.def, 1.0)
        XCTAssertEqual(ParamRegistry.spec("st_poly")!.def, 4.0)
        XCTAssertEqual(ParamRegistry.spec("st_pluck_drive")!.def, 1.0)
        // the taraf coupling ships ON (the halo is the point) at the
        // audition-calibrated drive (2026-08-19: st_taraf 4 puts the
        // post-release halo ~33 dB under the pluck — the reference's
        // sympathetic zone; 1.0 measured ~12 dB too subtle); 0 must
        // remain reachable (byte-null String parity path)
        XCTAssertEqual(ParamRegistry.spec("st_taraf")!.def, 4.0)
        XCTAssertEqual(ParamRegistry.spec("st_taraf")!.lo, 0.0)
        // and st_gain's default IS the artifact's fitted trim
        if let p = Presets.sitarParams() {
            XCTAssertEqual(p.gain, ParamRegistry.spec("st_gain")!.def,
                           accuracy: 1e-12,
                           "st_gain default drifted from sitar_live.json `gain`")
        } else {
            XCTFail("sitar_live.json missing from the SarangiKit bundle")
        }
    }

    func testSitarArtifactMounts() {
        guard let p = Presets.sitarParams() else {
            XCTFail("sitar_live.json missing"); return
        }
        // v3 (the scale-model role ladder, 2026-08-20): the sitar IS
        // its ladder — register-graded geometrically-scaled copies of
        // the C3 anchor string, each carrying the per-role physical
        // fields (a plain role list here would silently rebuild the
        // rejected earlier voices)
        XCTAssertGreaterThan(p.roles.count, 8, "sitar ladder collapsed")
        XCTAssertGreaterThan(p.roles[0].threadH, 0,
                             "the sitar keeps the anchor's jiva thread")
        for r in p.roles {
            XCTAssertNotNil(r.kc, "ladder role \(r.name) lost its contact law")
            XCTAssertNotNil(r.mDyn, "ladder role \(r.name) lost its modal budget")
            XCTAssertNotNil(r.fhf, "ladder role \(r.name) lost its Q(f) shift")
        }
        // similarity spot-checks: constant B, loss-factor t60, thinner
        // strings up the ladder
        let lo = p.roles.first!, hi = p.roles[6]
        XCTAssertEqual(lo.refB, hi.refB, accuracy: lo.refB * 1e-9,
                       "B must be constant across the ladder")
        let s = hi.refF / lo.refF
        XCTAssertEqual(hi.t600 * s, lo.t600, accuracy: lo.t600 * 0.01,
                       "t60 must scale 1/s (constant loss factor)")
        XCTAssertEqual(hi.R * s, lo.R, accuracy: lo.R * 0.01,
                       "gauge must scale 1/s")
        // a small JI grid mounts and renders finite, non-silent audio
        // after a pluck (2 slots keeps the mount+settle pass fast)
        let engine = TanpuraEngine(params: p,
                                   frequencies: [280.65, 561.3],
                                   workers: 1)   // sync path: deterministic
        XCTAssertNotNil(engine, "sitar engine failed to mount")
        guard let engine else { return }
        engine.pluck(slot: 1, velocity: 100, scale: 1.0)
        var peak = 0.0
        var l = [Double](repeating: 0, count: 512)
        var r = [Double](repeating: 0, count: 512)
        for _ in 0..<94 {   // ~1 s in render-callback-sized blocks
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    engine.render(frames: 512, outL: lb.baseAddress!,
                                  outR: rb.baseAddress!)
                }
            }
            peak = max(peak, l.map(abs).max() ?? 0)
        }
        XCTAssertTrue(peak.isFinite, "sitar render non-finite")
        XCTAssertGreaterThan(peak, 1e-5, "sitar pluck silent")
        XCTAssertLessThan(peak, 2.0, "sitar pluck blowing up")
    }

    /// THE CASCADE GUARD (2026-08-20). The sitar's identity is the
    /// jawari cascade: after a pluck, the h6–h8 cluster must BLOOM
    /// (rise over the first two seconds) and settle within earshot of
    /// the fundamental — the varispeed target cells measure
    /// rise ≈ +5 dB and cluster ≈ −13 dB rel h1 at C4. A build whose
    /// cluster stays flat and buried plays h1+h2 alone: the reported
    /// "ringing telephone" (peak metrics at 0.16 s CANNOT see this —
    /// only the time evolution can, hence this test).
    func testSitarCascadeBlooms() {
        guard let p = Presets.sitarParams() else {
            XCTFail("sitar_live.json missing"); return
        }
        let f0 = 261.62
        guard let engine = TanpuraEngine(params: p, frequencies: [f0],
                                         workers: 1) else {
            XCTFail("sitar engine failed to mount"); return
        }
        engine.pluck(slot: 0, velocity: 100, scale: 1.0)
        let sr = 48000.0
        let total = Int(4.2 * sr)
        var y = [Double](repeating: 0, count: total)
        var r = [Double](repeating: 0, count: 512)
        var done = 0
        y.withUnsafeMutableBufferPointer { yb in
            r.withUnsafeMutableBufferPointer { rb in
                while done < total {
                    let m = min(512, total - done)
                    engine.render(frames: m, outL: yb.baseAddress! + done,
                                  outR: rb.baseAddress!)
                    done += m
                }
            }
        }
        func harmDB(_ k: Int, _ t0: Double) -> Double {
            let a = Int(t0 * sr), n = Int(0.08 * sr)
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let w = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
                let ph = 2.0 * Double.pi * Double(k) * f0 * (Double(a + i) / sr)
                re += y[a + i] * w * cos(ph)
                im -= y[a + i] * w * sin(ph)
            }
            let amp = 2.0 * (re * re + im * im).squareRoot() / Double(n)
            return 20.0 * log10(amp + 1e-12)
        }
        let rise = [6, 7, 8].map { harmDB($0, 2.0) - harmDB($0, 0.1) }
            .reduce(0, +) / 3.0
        let rel = [6, 7, 8].map { harmDB($0, 2.0) }.reduce(0, +) / 3.0
            - harmDB(1, 2.0)
        // loose bounds around the C4 cell targets (+5.4 / −13.3)
        XCTAssertGreaterThan(rise, -2.0,
                             "cascade does not bloom (rise \(rise) dB) — the telephone regression")
        XCTAssertGreaterThan(rel, -20.0,
                             "cascade cluster buried (\(rel) dB rel h1) — the telephone regression")
    }
}
