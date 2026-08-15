import XCTest
@testable import SarangiKit

/// Scale-shaped overtones (2026-08-05): the altered-tanpura transform.
///
///  1. The shaping math: capture window, octave-circular nearest-PC,
///     the flagship harmonic-5 → komal-ga correction, sustain tilt,
///     spread determinism.
///  2. `buildNote` integration: an INACTIVE shaping is byte-identical
///     to the nil path (the lockstep golden's ground stays untouched);
///     an active one retunes exactly the modes the math says, leaves
///     modes 1–2 alone, thins misaligned partials' t60 (`focus`) and
///     cuts their radiated phiO without touching dynamics (`quiet`).
final class TanpuraShapingTests: XCTestCase {

    private func loadParams() throws -> TanpuraParams {
        guard let p = Presets.tanpuraParams() else {
            throw XCTSkip("tanpura_live.json missing from bundle")
        }
        return p
    }

    /// Sa · komal ga · Pa — the raga shape where the physical tanpura's
    /// 5th harmonic (shuddha Ga) clashes hardest.
    private let komalGaRatios = [1.0, 6.0 / 5.0, 3.0 / 2.0]

    // MARK: - The shaping math

    func testHarmonic5PullsToKomalGa() {
        let sh = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                align: 1, focus: 0, spread: 0)
        XCTAssertTrue(sh.isActive)
        // harmonic 5 sounds 5×tonic = shuddha Ga (386.3 c); nearest scale
        // PC is komal ga (315.6 c) — 70.7 c away, inside the 80 c window,
        // so align 1 snaps it exactly onto 6/5 (in some octave)
        let (ratio, _, _) = sh.modeAdjust(fSounding: 550, mode: 5, slotSeed: 1)
        let landed = 550.0 * ratio
        let pc = log2(landed / 110).truncatingRemainder(dividingBy: 1)
        let target = log2(6.0 / 5.0)
        XCTAssertEqual(pc, target, accuracy: 1e-12,
                       "harmonic 5 must land exactly on komal ga at align 1")
        XCTAssertEqual(ratio, pow(2, (315.641 - 386.314) / 1200),
                       accuracy: 1e-4)
        // half align pulls half the distance
        let shHalf = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                    align: 0.5, focus: 0, spread: 0)
        let (rHalf, _, _) = shHalf.modeAdjust(fSounding: 550, mode: 5,
                                              slotSeed: 1)
        XCTAssertEqual(log2(rHalf), log2(ratio) / 2, accuracy: 1e-12)
    }

    func testCaptureWindowLeavesDistantPartialsAlone() {
        // a partial sitting in a wide scale gap (> 160 c from every PC)
        // must not move at all — a partial pull would land it in
        // no-man's-land
        let sh = TanpuraShaping(tonicHz: 100, scaleRatios: [1.0, 3.0 / 2.0],
                                align: 1, focus: 0, spread: 0)
        // 350 c above the tonic: 350 c from Sa, 352 c from Pa
        let f = 100.0 * pow(2, 350.0 / 1200.0)
        let (ratio, _, _) = sh.modeAdjust(fSounding: f, mode: 7, slotSeed: 1)
        XCTAssertEqual(ratio, 1.0, accuracy: 1e-15)
        // and the taper is monotone: 100 c off moves partway, less than
        // an 80 c-off partial's full pull
        let f80 = 100.0 * pow(2, (702.0 - 80.0) / 1200.0)
        let f100 = 100.0 * pow(2, (702.0 - 100.0) / 1200.0)
        let (r80, _, _) = sh.modeAdjust(fSounding: f80, mode: 7, slotSeed: 1)
        let (r100, _, _) = sh.modeAdjust(fSounding: f100, mode: 7, slotSeed: 1)
        let pulled80 = abs(log2(r80)) * 1200
        let pulled100 = abs(log2(r100)) * 1200
        XCTAssertEqual(pulled80, 80, accuracy: 0.1, "window edge = full pull")
        XCTAssertGreaterThan(pulled100, 0)
        XCTAssertLessThan(pulled100, 100 * TanpuraShaping.captureWeight(100)
                          + 0.1)
    }

    func testNearestPCIsOctaveCircular() {
        // a partial just BELOW the octave must see Sa 10 c above it, not
        // 1190 c below
        let sh = TanpuraShaping(tonicHz: 100, scaleRatios: [1.0],
                                align: 1, focus: 0, spread: 0)
        let f = 100.0 * pow(2, 1190.0 / 1200.0)
        let (ratio, _, _) = sh.modeAdjust(fSounding: f, mode: 3, slotSeed: 1)
        XCTAssertEqual(ratio, pow(2, 10.0 / 1200.0), accuracy: 1e-9,
                       "must wrap up 10 c to the octave Sa")
    }

    func testFocusTiltsSustain() {
        let sh = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                align: 0, focus: 1, spread: 0)
        // harmonic 3 IS Pa (2 c stretch aside) — full ring
        let (_, tOn, _) = sh.modeAdjust(fSounding: 330, mode: 3, slotSeed: 1)
        XCTAssertGreaterThan(tOn, 0.99)
        // harmonic 5 at 71 c off (align 0 leaves it there): thinned hard
        // (the 30 c focus σ — exp(−0.5·(70.7/30)²) ≈ 0.06)
        let (_, tOff, _) = sh.modeAdjust(fSounding: 550, mode: 5, slotSeed: 1)
        XCTAssertLessThan(tOff, 0.1)
        XCTAssertGreaterThanOrEqual(tOff, TanpuraShaping.t60Floor)
        // with align 1 the same partial lands ON scale first — full ring
        let shBoth = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                    align: 1, focus: 1, spread: 0)
        let (_, tAligned, _) = shBoth.modeAdjust(fSounding: 550, mode: 5,
                                                 slotSeed: 1)
        XCTAssertGreaterThan(tAligned, 0.99,
                             "retuned-onto-scale partials must keep their ring")
    }

    func testSpreadIsDeterministicAndPerString() {
        let sh = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                align: 1, focus: 0, spread: 1)
        let a = sh.modeAdjust(fSounding: 550, mode: 5, slotSeed: 110_000)
        let b = sh.modeAdjust(fSounding: 550, mode: 5, slotSeed: 110_000)
        XCTAssertEqual(a.ratio, b.ratio, "same seed = same jitter")
        let c = sh.modeAdjust(fSounding: 550, mode: 5, slotSeed: 165_000)
        XCTAssertNotEqual(a.ratio, c.ratio,
                          "different strings must decorrelate")
        // jitter only ever REDUCES the pull, toward the physical string
        let full = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                  align: 1, focus: 0, spread: 0)
            .modeAdjust(fSounding: 550, mode: 5, slotSeed: 110_000).ratio
        XCTAssertLessThanOrEqual(abs(log2(a.ratio)), abs(log2(full)) + 1e-15)
    }

    func testQuietCutsRadiationOnly() {
        let sh = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                align: 0, focus: 0, spread: 0, quiet: 1)
        XCTAssertTrue(sh.isActive, "quiet alone must arm the shaping")
        // harmonic 5 (71 c off): radiation cut hard, dynamics untouched
        let (r5, t5, o5) = sh.modeAdjust(fSounding: 550, mode: 5,
                                         slotSeed: 1)
        XCTAssertEqual(r5, 1.0, "quiet must not retune")
        XCTAssertEqual(t5, 1.0, "quiet must not touch t60")
        XCTAssertLessThan(o5, 0.1)
        XCTAssertGreaterThanOrEqual(o5, 0.0, "a fader, never a phase flip")
        // harmonic 3 (on Pa): radiates freely
        let (_, _, o3) = sh.modeAdjust(fSounding: 330, mode: 3, slotSeed: 1)
        XCTAssertGreaterThan(o3, 0.99)
        // half quiet = half the cut
        let shHalf = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                    align: 0, focus: 0, spread: 0,
                                    quiet: 0.5)
        let (_, _, oHalf) = shHalf.modeAdjust(fSounding: 550, mode: 5,
                                              slotSeed: 1)
        XCTAssertEqual(oHalf, 0.5 * (1.0 + o5), accuracy: 1e-12)
        // retuned-onto-scale partials radiate freely (post-retune law)
        let shBoth = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                    align: 1, focus: 0, spread: 0, quiet: 1)
        let (_, _, oAligned) = shBoth.modeAdjust(fSounding: 550, mode: 5,
                                                 slotSeed: 1)
        XCTAssertGreaterThan(oAligned, 0.99)
    }

    func testInactiveShapingIsIdentity() {
        let sh = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                align: 0, focus: 0, spread: 1)
        XCTAssertFalse(sh.isActive, "spread alone is inert by design")
        let (r, t, o) = sh.modeAdjust(fSounding: 550, mode: 5, slotSeed: 1)
        XCTAssertEqual(r, 1.0)
        XCTAssertEqual(t, 1.0)
        XCTAssertEqual(o, 1.0)
    }

    // MARK: - buildNote integration

    func testBuildNoteInactiveShapingMatchesNilExactly() throws {
        let p = try loadParams()
        let f0 = 110.0
        let base = TanpuraTables.buildNote(f0Sounding: f0, cents: 7.0, p: p)
        let inert = TanpuraShaping(tonicHz: f0, scaleRatios: komalGaRatios,
                                   align: 0, focus: 0, spread: 0)
        let shaped = TanpuraTables.buildNote(f0Sounding: f0, cents: 7.0,
                                             p: p, shaping: inert,
                                             slotSeed: 42)
        XCTAssertEqual(shaped.ca, base.ca)
        XCTAssertEqual(shaped.cb, base.cb)
        XCTAssertEqual(shaped.caw, base.caw)
        XCTAssertEqual(shaped.cbw, base.cbw)
        XCTAssertEqual(shaped.wd, base.wd)
        XCTAssertEqual(shaped.cas, base.cas)
    }

    func testBuildNoteRetunesShapedModesOnly() throws {
        let p = try loadParams()
        let f0 = 110.0
        let cents = 7.0
        let sh = TanpuraShaping(tonicHz: f0, scaleRatios: komalGaRatios,
                                align: 1, focus: 0, spread: 0)
        let base = TanpuraTables.buildNote(f0Sounding: f0, cents: cents, p: p)
        let shaped = TanpuraTables.buildNote(f0Sounding: f0, cents: cents,
                                             p: p, shaping: sh, slotSeed: 42)
        XCTAssertEqual(shaped.M, base.M)
        let dt = base.dt
        // recover each mode's damped angular frequency from its rotation
        func wd(_ t: TanpuraNoteTables, _ i: Int) -> Double {
            atan2(t.cb[i], t.ca[i]) / dt
        }
        // modes 1–2: untouched to the bit
        XCTAssertEqual(shaped.ca[0], base.ca[0])
        XCTAssertEqual(shaped.cb[0], base.cb[0])
        XCTAssertEqual(shaped.ca[1], base.ca[1])
        XCTAssertEqual(shaped.cb[1], base.cb[1])
        // every shaped mode's rotation moved by exactly the ratio the
        // math predicts (measured in the sounding frame)
        let toSounding = pow(2.0, cents / 1200.0)
        var movedCount = 0
        for i in 2..<min(base.M, 40) {
            let fk = wd(base, i) / (2 * Double.pi) * toSounding
            let (ratio, _, _) = sh.modeAdjust(fSounding: fk, mode: i + 1,
                                              slotSeed: 42)
            // wd = sqrt((w0·ratio)² − σ²) ≈ wd_base·ratio for σ ≪ w0
            XCTAssertEqual(wd(shaped, i) / wd(base, i), ratio,
                           accuracy: 1e-6,
                           "mode \(i + 1) retune mismatch")
            if abs(ratio - 1) > 1e-9 { movedCount += 1 }
        }
        XCTAssertGreaterThan(movedCount, 3,
                             "the komal-ga scale must actually move partials (h5, h10, h20 kin…)")
        // the horizontal (detuned) bank follows the same shaped w0
        func wdw(_ t: TanpuraNoteTables, _ i: Int) -> Double {
            atan2(t.cbw[i], t.caw[i]) / dt
        }
        for i in [4, 6] where i < base.M {
            let fk = wd(base, i) / (2 * Double.pi) * toSounding
            let (ratio, _, _) = sh.modeAdjust(fSounding: fk, mode: i + 1,
                                              slotSeed: 42)
            XCTAssertEqual(wdw(shaped, i) / wdw(base, i), ratio,
                           accuracy: 1e-5,
                           "horizontal bank must track the shaped mode \(i + 1)")
        }
    }

    /// End-to-end: a SHAPED engine mounts, settles and renders finite,
    /// ringing audio through the full contact stage (the tables-level
    /// tests can't catch a shaped-w0 / SAV-response inconsistency), and
    /// its output genuinely differs from the physical build.
    func testShapedEngineRendersAndDiffers() throws {
        let p = try loadParams()
        let freqs = [110.0, 132.0, 165.0]   // Sa · komal ga · Pa
        let sh = TanpuraShaping(tonicHz: 110, scaleRatios: komalGaRatios,
                                align: 1, focus: 0.5, spread: 0)
        guard let physical = TanpuraEngine(params: p, frequencies: freqs,
                                           workers: 1),
              let shaped = TanpuraEngine(params: p, frequencies: freqs,
                                         workers: 1, shaping: sh)
        else { return XCTFail("engine build failed") }
        let n = 4096
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        func render(_ e: TanpuraEngine) {
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    e.render(frames: n, outL: lb.baseAddress!,
                             outR: rb.baseAddress!)
                }
            }
        }
        var peaks = [Double]()
        var traces = [[Double]]()
        for e in [physical, shaped] {
            e.pluck(slot: 0, velocity: 100)
            var peak = 0.0
            var trace = [Double]()
            for _ in 0..<Int(1.0 * p.sr / Double(n)) {
                render(e)
                XCTAssertTrue(l.allSatisfy { $0.isFinite },
                              "non-finite shaped output")
                peak = max(peak, l.map { abs($0) }.max() ?? 0)
                trace.append(contentsOf: l)
            }
            peaks.append(peak)
            traces.append(trace)
        }
        XCTAssertGreaterThan(peaks[1], 1e-6, "shaped pluck was silent")
        // same order of loudness (shaping retunes/thins, it must not
        // change the instrument's level class)…
        XCTAssertLessThan(abs(log10(peaks[1] / peaks[0])), 1.0)
        // …but a genuinely different waveform (harmonic 5 moved 71 c)
        let diff = zip(traces[0], traces[1]).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(diff, peaks[0] * 1e-3,
                             "shaping had no audible effect")
    }

    func testBuildNoteQuietScalesPhiOOnly() throws {
        let p = try loadParams()
        let f0 = 110.0
        let sh = TanpuraShaping(tonicHz: f0, scaleRatios: komalGaRatios,
                                align: 0, focus: 0, spread: 0, quiet: 1)
        let base = TanpuraTables.buildNote(f0Sounding: f0, cents: 7.0, p: p)
        let shaped = TanpuraTables.buildNote(f0Sounding: f0, cents: 7.0,
                                             p: p, shaping: sh, slotSeed: 42)
        // dynamics tables bit-identical — quiet is readout-only
        XCTAssertEqual(shaped.ca, base.ca)
        XCTAssertEqual(shaped.cb, base.cb)
        XCTAssertEqual(shaped.caw, base.caw)
        XCTAssertEqual(shaped.wd, base.wd)
        XCTAssertEqual(shaped.dq, base.dq)
        // modes 1–2 radiate untouched
        XCTAssertEqual(shaped.phiO[0], base.phiO[0])
        XCTAssertEqual(shaped.phiO[1], base.phiO[1])
        // every shaped mode's phiO scaled by exactly the predicted cut
        let toSounding = pow(2.0, 7.0 / 1200.0)
        let dt = base.dt
        var cutCount = 0
        for i in 2..<min(base.M, 40) {
            let fk = atan2(base.cb[i], base.ca[i]) / dt
                / (2 * Double.pi) * toSounding
            let (_, _, outMul) = sh.modeAdjust(fSounding: fk, mode: i + 1,
                                               slotSeed: 42)
            // the test's fk comes from wd (≈ w0 up to the damping
            // correction); through the 30 c gaussian that costs ~1e-5
            // on outMul — hence the loose-ish relative tolerance
            XCTAssertEqual(shaped.phiO[i], base.phiO[i] * outMul,
                           accuracy: abs(base.phiO[i]) * 1e-4 + 1e-12,
                           "mode \(i + 1) phiO cut mismatch")
            if outMul < 0.5 { cutCount += 1 }
        }
        XCTAssertGreaterThan(cutCount, 3,
                             "the komal-ga scale must actually quiet partials")
    }

    func testBuildNoteFocusThinsMisalignedT60() throws {
        let p = try loadParams()
        let f0 = 110.0
        let sh = TanpuraShaping(tonicHz: f0, scaleRatios: komalGaRatios,
                                align: 0, focus: 1, spread: 0)
        let base = TanpuraTables.buildNote(f0Sounding: f0, cents: 7.0, p: p)
        let shaped = TanpuraTables.buildNote(f0Sounding: f0, cents: 7.0,
                                             p: p, shaping: sh, slotSeed: 42)
        let dt = base.dt
        // recover σ from the rotation magnitude: |ca+icb| = e^(−σ·dt)
        func sig(_ t: TanpuraNoteTables, _ i: Int) -> Double {
            -log((t.ca[i] * t.ca[i] + t.cb[i] * t.cb[i]).squareRoot()) / dt
        }
        // mode 5 (harmonic 5, 71 c off scale): decays faster
        XCTAssertGreaterThan(sig(shaped, 4), sig(base, 4) * 1.5,
                             "misaligned harmonic 5 must thin under focus")
        // mode 3 (Pa): ring preserved
        XCTAssertEqual(sig(shaped, 2), sig(base, 2),
                       accuracy: sig(base, 2) * 0.02,
                       "on-scale harmonic 3 must keep its ring")
    }
}
