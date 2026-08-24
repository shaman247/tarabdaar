import XCTest
@testable import SarangiKit
import CBowKernel

/// Tanpura voice (ported from Sarangi Live 2026-08-04):
///  1. LOCKSTEP: `TanpuraTables.buildNote` vs the upstream python
///     builder's golden (note 57 / 220 Hz at its calibrated cents,
///     bundled as `Goldens/tanpura_live_golden.json`). buildNote was
///     ported VERBATIM — the bar is tight (1e-9 rel) and a drift means
///     the port diverged from the fitted physics.
///  2. CENTS INTERPOLATION: the Tarabdaar divergence — arbitrary-Hz slots
///     take the per-12-TET-note `pitchCents` by log-pitch interpolation;
///     exact notes must reproduce their table entry exactly.
///  3. ENGINE SMOKE: build a small JI slot set from the bundled
///     `tanpura_live.json`, pluck, render — silent before, ringing after
///     (no note-off — the instrument's nature), all finite.
final class TanpuraEngineTests: XCTestCase {

    private func params() throws -> TanpuraParams {
        guard let p = Presets.tanpuraParams() else {
            throw XCTSkip("tanpura_live.json missing from the SarangiKit bundle")
        }
        return p
    }

    func testTablesLockstepGolden() throws {
        let p = try params()
        guard let gu = Bundle.module.url(forResource: "tanpura_live_golden",
                                         withExtension: "json",
                                         subdirectory: "Goldens"),
              let gd = try? Data(contentsOf: gu),
              let g = try? JSONSerialization.jsonObject(with: gd) as? [String: Any]
        else { throw XCTSkip("tanpura_live_golden.json missing from the test bundle") }
        let cents = g["cents"] as! Double
        let t = TanpuraTables.buildNote(f0Sounding: 220.0, cents: cents, p: p)
        func arr(_ k: String) -> [Double] {
            (g[k] as! [Any]).map { ($0 as? Double) ?? Double($0 as! Int) }
        }
        XCTAssertEqual(t.M, Int(g["M"] as! Int))
        XCTAssertEqual(t.J, Int(g["J"] as! Int))
        let pairs: [(String, [Double])] = [
            ("ca", t.ca), ("cb", t.cb), ("ca4", t.ca4), ("cb4", t.cb4),
            ("cas", t.cas), ("cbs", t.cbs), ("wd", t.wd),
            ("caw", t.caw), ("cbw", t.cbw), ("wdw", t.wdw),
            ("Phi", t.phi), ("phiF", t.phiF), ("b", t.b),
            ("G", t.g), ("G4", t.g4), ("gd", t.gd), ("gd4", t.gd4),
            ("phi_o", t.phiO), ("dq", t.dq),
            ("g_th", t.gTh),
        ]
        for (name, mine) in pairs {
            let ref = arr(name)
            XCTAssertEqual(mine.count, ref.count, name)
            // per-element scale floored at 1e-6 of the array max: near-
            // cancelling series entries (dq high-k modes) carry summation-
            // order noise that reads as huge RELATIVE drift while absolute
            // error is ~1e-16. Real builder drift lands orders above this.
            let refMax = ref.reduce(0.0) { max($0, abs($1)) }
            var worst = 0.0
            for i in 0..<min(mine.count, ref.count) {
                let scale = max(abs(ref[i]), 1e-6 * refMax + 1e-30)
                worst = max(worst, abs(mine[i] - ref[i]) / scale)
            }
            XCTAssertLessThan(worst, 1e-9, "\(name) lockstep drift \(worst)")
        }
        XCTAssertEqual(t.deep, g["deep"] as! Double, accuracy: 1e-15)
        XCTAssertEqual(t.dt, g["dt"] as! Double, accuracy: 1e-18)
    }

    func testCentsInterpolation() throws {
        let p = try params()
        // Every calibrated 12-TET note reproduces its table entry exactly.
        for (i, c) in p.pitchCents.enumerated() {
            let note = p.noteLo + i
            let f0 = 440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)
            XCTAssertEqual(TanpuraEngine.centsCorrection(forHz: f0, params: p),
                           c, accuracy: 1e-9, "note \(note)")
        }
        // A quarter-tone between two notes lands between their entries.
        let f0 = 440.0 * pow(2.0, (57.5 - 69.0) / 12.0)
        let lo = p.pitchCents[57 - p.noteLo]
        let hi = p.pitchCents[58 - p.noteLo]
        let mid = TanpuraEngine.centsCorrection(forHz: f0, params: p)
        XCTAssertEqual(mid, (lo + hi) / 2, accuracy: 1e-9)
        // Beyond the calibrated ends: clamped, never extrapolated.
        XCTAssertEqual(TanpuraEngine.centsCorrection(forHz: 20.0, params: p),
                       p.pitchCents.first!, accuracy: 1e-12)
        XCTAssertEqual(TanpuraEngine.centsCorrection(forHz: 4000.0, params: p),
                       p.pitchCents.last!, accuracy: 1e-12)
    }

    func testEngineSmokeJISlots() throws {
        let p = try params()
        // A JI drone set (low Sa · low Pa · Sa at a 220 Hz tonic) — the
        // Tarabdaar mount shape: arbitrary exact Hz, not MIDI notes.
        guard let e = TanpuraEngine(params: p,
                                    frequencies: [110.0, 165.0, 220.0],
                                    workers: 1)   // sync path: deterministic
        else { return XCTFail("engine build failed") }
        XCTAssertEqual(e.slotFrequencies.count, 3)
        // nearest-slot lookup: exact hits and the tolerance gate
        XCTAssertEqual(e.nearestSlot(toHz: 165.0), 1)
        XCTAssertEqual(e.nearestSlot(toHz: 165.2, toleranceCents: 50), 1)
        XCTAssertNil(e.nearestSlot(toHz: 140.0, toleranceCents: 50))
        let n = 4096
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        func render() {
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    e.render(frames: n, outL: lb.baseAddress!,
                             outR: rb.baseAddress!)
                }
            }
        }
        // silence before any pluck
        render()
        let pre = l.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(pre, 1e-9, "silent engine emitted \(pre)")
        // pluck Sa, render 2 s: non-silent, finite, still ringing at the
        // end (no note-off — the string's nature)
        e.pluck(slot: 2, velocity: 100)
        var peak = 0.0
        var lastBlockPeak = 0.0
        let blocks = Int(2.0 * p.sr / Double(n))
        for _ in 0..<blocks {
            render()
            lastBlockPeak = l.map { abs($0) }.max() ?? 0
            peak = max(peak, lastBlockPeak)
            XCTAssertTrue(l.allSatisfy { $0.isFinite }, "non-finite output")
        }
        XCTAssertGreaterThan(peak, 1e-6, "pluck was silent")
        XCTAssertGreaterThan(lastBlockPeak, peak * 1e-4,
                             "string stopped ringing — tanpura strings ring")
        XCTAssertEqual(e.activeStrings, 1)
    }

    /// Dominant pitch by autocorrelation peak over [loHz, hiHz].
    private func estimateF0(_ x: [Double], sr: Double,
                            loHz: Double, hiHz: Double) -> Double {
        let lagLo = max(1, Int(sr / hiHz)), lagHi = Int(sr / loHz)
        var best = lagLo
        var bestV = -Double.infinity
        for lag in lagLo...lagHi {
            var a = 0.0
            for i in 0..<(x.count - lag) { a += x[i] * x[i + lag] }
            if a > bestV { bestV = a; best = lag }
        }
        return sr / Double(best)
    }

    /// Main-instrument bend + release (2026-08-05): a ringing string
    /// live-retunes with the fret glide, note-off decays it MUCH faster
    /// than the natural ring, and a re-pluck restores both.
    func testBendAndRelease() throws {
        let p = try params()
        guard let e = TanpuraEngine(params: p, frequencies: [110.0, 165.0],
                                    workers: 1)   // sync path: deterministic
        else { return XCTFail("engine build failed") }
        let n = 4096
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        func render(seconds: Double) -> [Double] {
            var all: [Double] = []
            for _ in 0..<Int((seconds * p.sr / Double(n)).rounded(.up)) {
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: n, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                all.append(contentsOf: l)
            }
            return all
        }
        // pluck at the mounted pitch: dominant f0 ~ 110 Hz
        e.pluck(slot: 0, velocity: 100)
        var x = render(seconds: 1.0)
        var tail = Array(x.suffix(Int(p.sr / 2)))
        let f0 = estimateF0(tail, sr: p.sr, loHz: 70, hiHz: 250)
        XCTAssertEqual(f0, 110.0, accuracy: 110.0 * 0.04,
                       "unbent pitch off: \(f0)")
        // bend the RINGING string up a just fifth: it retunes in place
        e.bend(slot: 0, ratio: 1.5)
        x = render(seconds: 1.0)
        tail = Array(x.suffix(Int(p.sr / 2)))
        let fBent = estimateF0(tail, sr: p.sr, loHz: 70, hiHz: 250)
        XCTAssertEqual(fBent, 165.0, accuracy: 165.0 * 0.04,
                       "bent pitch off: \(fBent)")
        XCTAssertTrue(x.allSatisfy { $0.isFinite })
        // note-off: fast release — decay far beyond the natural ring
        let preRelease = tail.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(preRelease, 1e-6, "string died before release")
        // (the render window outlasts the room tail — revRT60 1 s at
        // mix 0.08 floors a shorter window ~25 dB above the string)
        e.release(slot: 0, rate: log(1000.0) / 0.15)   // t60 = 150 ms
        x = render(seconds: 1.6)
        let post = Array(x.suffix(n)).map { abs($0) }.max() ?? 0
        XCTAssertLessThan(post, preRelease * 0.02,
                          "release barely decayed: \(post) vs \(preRelease)")
        // a re-pluck clears the release AND the bend (rings at 110 again)
        e.pluck(slot: 0, velocity: 100)
        x = render(seconds: 1.0)
        tail = Array(x.suffix(Int(p.sr / 2)))
        let fBack = estimateF0(tail, sr: p.sr, loHz: 70, hiHz: 250)
        XCTAssertEqual(fBack, 110.0, accuracy: 110.0 * 0.04,
                       "re-pluck did not restore the mount pitch: \(fBack)")
        let back = tail.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(back, preRelease * 0.2,
                             "re-pluck after release stayed quiet")
    }

    /// Register calibration law (2026-08-15, `tp_jiva_comp`): fitted
    /// geometry below 104 Hz and at comp 0 (exactly 1.0 — byte-null),
    /// the measured 156 Hz node, monotone non-increasing thread height
    /// across the register with a floor above the lower-regime cliff,
    /// and linear comp blending.
    func testRegisterCompLaw() throws {
        let p = try params()
        XCTAssertEqual(TanpuraTables.registerCompThreadMul(
            f0: 300, comp: 0, p: p), 1.0)
        XCTAssertEqual(TanpuraTables.registerCompThreadMul(
            f0: 104, comp: 1, p: p), 1.0)
        XCTAssertEqual(TanpuraTables.registerCompThreadMul(
            f0: 80, comp: 1, p: p), 1.0)
        // measured node: 156 Hz targets the thread top 8.25 μm above
        // the apex → mul (8.25 + 20.25)/30 at the fitted geometry
        XCTAssertEqual(TanpuraTables.registerCompThreadMul(
            f0: 156, comp: 1, p: p), 0.95, accuracy: 1e-6)
        var prev = 1.0
        var f = 104.0
        while f < 900 {
            let m = TanpuraTables.registerCompThreadMul(f0: f, comp: 1,
                                                        p: p)
            XCTAssertLessThanOrEqual(m, prev + 1e-12,
                                     "law not monotone at \(f)")
            XCTAssertGreaterThan(m, 0.75, "law under the floor at \(f)")
            prev = m
            f *= 1.03
        }
        let full = TanpuraTables.registerCompThreadMul(f0: 208, comp: 1,
                                                       p: p)
        let half = TanpuraTables.registerCompThreadMul(f0: 208, comp: 0.5,
                                                       p: p)
        XCTAssertEqual(half, (1.0 + full) / 2.0, accuracy: 1e-9)

        // cascade slowing (tp_cascade): zero at/below the anchor and at
        // cascade 0; the measured 208 Hz values (+0.75 μm thread lift =
        // +0.025 mul at the fitted 30 μm thread, HF t60 ×2); monotone
        // with pitch
        XCTAssertEqual(TanpuraTables.cascadeThreadLift(
            f0: 104, cascade: 1, p: p), 0.0)
        XCTAssertEqual(TanpuraTables.cascadeThreadLift(
            f0: 300, cascade: 0, p: p), 0.0)
        XCTAssertEqual(TanpuraTables.cascadeHFT60Mul(f0: 104, cascade: 1),
                       1.0)
        XCTAssertEqual(TanpuraTables.cascadeThreadLift(
            f0: 208, cascade: 1, p: p), 0.025, accuracy: 1e-6)
        XCTAssertEqual(TanpuraTables.cascadeHFT60Mul(f0: 208, cascade: 1),
                       2.0, accuracy: 1e-9)
        XCTAssertGreaterThan(TanpuraTables.cascadeThreadLift(
            f0: 262, cascade: 1, p: p),
                             TanpuraTables.cascadeThreadLift(
            f0: 208, cascade: 1, p: p))
    }

    /// Pluck touch + pluck drive (2026-08-15) — the consistency and
    /// character knobs:
    ///  - touch 1 (string-bank rework): the previous note migrates to
    ///    a history clone and keeps ringing (FULL simulation) through
    ///    the re-pluck — the post-re-pluck window carries tail + fresh
    ///    attack, clearly outweighing a fresh attack alone; with
    ///    polyphony 0 the history goes to the split ghost instead
    ///    (low partials restarted → head level near the fresh pluck);
    ///    the pile-up stays finite and decays. At touch 0 (legacy)
    ///    the pluck rides the ring and the phase alignment makes
    ///    re-plucks differ audibly (the measured 5× buzz / +7 dB
    ///    accumulation variance).
    ///  - drive 1 is BIT-EXACT with the fitted pluck; drive ≠ 1 changes
    ///    the contact engagement at compensated output level — high
    ///    drive must render BRIGHTER (spectral-slope proxy) and low
    ///    drive darker, while the ring level stays in the fitted
    ///    ballpark (the 1/drive gain ride).
    func testPluckTouchAndDrive() throws {
        let p = try params()
        let n = 4096
        func make() throws -> TanpuraEngine {
            guard let e = TanpuraEngine(params: p, frequencies: [110.0],
                                        workers: 1)  // sync: deterministic
            else { throw XCTSkip("engine build failed") }
            return e
        }
        func render(_ e: TanpuraEngine, blocks: Int) -> [Double] {
            var acc = [Double]()
            var l = [Double](repeating: 0, count: n)
            var r = [Double](repeating: 0, count: n)
            for _ in 0..<blocks {
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: n, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                acc.append(contentsOf: l)
            }
            return acc
        }
        func rms(_ x: ArraySlice<Double>) -> Double {
            sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(max(x.count, 1)))
        }
        func relDiff(_ a: [Double], _ b: [Double]) -> Double {
            let d = zip(a, b).map(-)
            return rms(d[...]) / max(rms(a[...]), 1e-12)
        }
        let ringBlocks = 16   // ~1.37 s between plucks
        let winBlocks = 12    // ~1 s comparison window after each pluck

        // touch 1, default bank: the previous note keeps ringing as a
        // REAL history string through the re-pluck — the head of the
        // post-re-pluck window (tail + fresh attack) clearly outweighs
        // a fresh attack alone
        let eT = try make()
        eT.pluck(slot: 0, velocity: 100, touch: 1.0)
        _ = render(eT, blocks: ringBlocks)
        eT.pluck(slot: 0, velocity: 100, touch: 1.0)
        let after = render(eT, blocks: winBlocks)
        let eF = try make()
        eF.pluck(slot: 0, velocity: 100, touch: 1.0)
        let fresh = render(eF, blocks: winBlocks)
        let head = Int(0.3 * p.sr)
        let carry = rms(after[..<head]) / max(rms(fresh[..<head]), 1e-12)
        XCTAssertGreaterThan(carry, 1.2,
                             "previous note truncated at re-pluck "
                             + "(carry \(carry))")
        XCTAssertLessThan(carry, 4.5, "re-pluck head blew up (\(carry))")
        // pile a third pluck on and let it ring: history strings stay
        // finite and the pile-up decays
        _ = render(eT, blocks: ringBlocks - winBlocks)
        eT.pluck(slot: 0, velocity: 100, touch: 1.0)
        let tail = render(eT, blocks: winBlocks * 4)
        XCTAssertTrue(tail.allSatisfy { $0.isFinite })
        let tHead = rms(tail[..<(tail.count / 4)])
        let tTail = rms(tail[(3 * tail.count / 4)...])
        XCTAssertLessThan(tTail, tHead,
                          "string-bank pile-up not decaying "
                          + "(\(tTail) vs \(tHead))")

        // polyphony 0: no history strings — the old ring goes to the
        // SPLIT ghost (low partials restarted by the fresh pluck), so
        // the re-pluck head sits closer to a fresh attack than the
        // full history string does
        let eZ = try make()
        eZ.setPolyphony(0)
        eZ.pluck(slot: 0, velocity: 100, touch: 1.0)
        _ = render(eZ, blocks: ringBlocks)
        eZ.pluck(slot: 0, velocity: 100, touch: 1.0)
        let afterZ = render(eZ, blocks: winBlocks)
        let carryZ = rms(afterZ[..<head])
            / max(rms(fresh[..<head]), 1e-12)
        XCTAssertLessThan(carryZ, carry,
                          "poly-0 split ghost should carry less than a "
                          + "full history string (\(carryZ) vs \(carry))")
        XCTAssertGreaterThan(carryZ, 0.6,
                             "poly-0 re-pluck collapsed (\(carryZ))")

        // touch 0 (legacy): the same schedule differs pluck-to-pluck
        // (the phase lottery — byte-identical to the pre-ghost path)
        let eL = try make()
        eL.pluck(slot: 0, velocity: 100)
        _ = render(eL, blocks: ringBlocks)
        eL.pluck(slot: 0, velocity: 100)
        let l2 = render(eL, blocks: winBlocks)
        _ = render(eL, blocks: ringBlocks - winBlocks)
        eL.pluck(slot: 0, velocity: 100)
        let l3 = render(eL, blocks: winBlocks)
        let legacyDiff = relDiff(l2, l3)
        XCTAssertGreaterThan(legacyDiff, 0.15,
                             "legacy re-plucks should vary "
                             + "(\(legacyDiff))")

        // drive 1 = the fitted pluck, bit-exact
        let eA = try make()
        eA.pluck(slot: 0, velocity: 100)
        let ref = render(eA, blocks: winBlocks)
        let eB = try make()
        eB.pluck(slot: 0, velocity: 100, drive: 1.0)
        let one = render(eB, blocks: winBlocks)
        XCTAssertEqual(relDiff(ref, one), 0.0,
                       "drive 1 must be bit-exact with the default")

        // drive up/down: brighter/darker at compensated level.
        // brightness proxy: first-difference RMS over RMS (spectral
        // slope) on the second half of the window (the developed ring).
        func bright(_ x: [Double]) -> Double {
            let h = Array(x[(x.count / 2)...])
            var d = [Double](repeating: 0, count: h.count - 1)
            for i in 1..<h.count { d[i - 1] = h[i] - h[i - 1] }
            return rms(d[...]) / max(rms(h[...]), 1e-12)
        }
        func ringRMS(_ x: [Double]) -> Double { rms(x[(x.count / 2)...]) }
        let eHi = try make()
        eHi.pluck(slot: 0, velocity: 100, drive: 2.8)
        let hi = render(eHi, blocks: winBlocks)
        let eLo = try make()
        eLo.pluck(slot: 0, velocity: 100, drive: 0.35)
        let lo = render(eLo, blocks: winBlocks)
        XCTAssertTrue(hi.allSatisfy { $0.isFinite })
        XCTAssertTrue(lo.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(bright(hi), bright(ref),
                             "high drive should brighten the ring")
        XCTAssertLessThan(bright(lo), bright(ref),
                          "low drive should darken the ring")
        for (name, x) in [("high", hi), ("low", lo)] {
            let r = ringRMS(x) / max(ringRMS(ref), 1e-12)
            XCTAssertGreaterThan(r, 0.35,
                                 "\(name)-drive ring level fell out of the "
                                 + "compensated ballpark (\(r))")
            XCTAssertLessThan(r, 2.8,
                              "\(name)-drive ring level blew past the "
                              + "compensated ballpark (\(r))")
        }
    }
}
