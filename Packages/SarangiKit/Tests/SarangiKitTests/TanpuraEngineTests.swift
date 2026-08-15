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
}
