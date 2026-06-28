import XCTest
@testable import StarpadDSP

/// Tests for the harmonic-resolved tanpura model. The model's defining
/// behavior — each harmonic's envelope peaking at its own time — is
/// asserted directly via per-harmonic Goertzel envelope tracking.
final class TanpuraTests: XCTestCase {
    let fs = 44100.0

    // MARK: - Helpers

    /// Params with every stochastic/coloring feature disabled and FRESH
    /// neutral strings (independent of whatever matched set is currently
    /// baked into the defaults): the model becomes a deterministic LINEAR
    /// system (superposition holds) well below the output limiter's knee.
    func cleanParams() -> TanpuraParams {
        var p = TanpuraParams()
        p.jivaDepth = 0
        p.pitchDriftCents = 0
        p.pluckVariationDB = 0
        p.noiseLevel = 0
        p.crossExcite = 0
        p.bodyDry = 1
        p.tiltDB = 0
        // Low enough that test renders never reach the ±0.85 soft-limiter
        // knee — the linearity these tests assert is the envelope math's.
        p.masterGain = 0.15
        for b in 0..<3 { p.body[b].gain = 0 }
        p.strings = [
            TanpuraStringParams(f0: 196.91, inharmonicity: 0),
            TanpuraStringParams(f0: 262.24, inharmonicity: 0),
            TanpuraStringParams(f0: 262.24, inharmonicity: 0),
            TanpuraStringParams(f0: 131.11, inharmonicity: 0),
        ]
        return p
    }

    func renderMono(_ params: TanpuraParams, plucks: [(Double, Int, Double)],
                    seconds: Double, seed: UInt64 = 42) -> [Float] {
        let model = TanpuraModel(sampleRate: fs, seed: seed, params: params)
        for (at, string, vel) in plucks {
            model.pluckAt(sample: Int64(at * fs), string: string, velocity: vel)
        }
        let frames = Int(seconds * fs)
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                var o = 0
                while o < frames {
                    let n = min(512, frames - o)
                    model.renderAdd(intoL: lb.baseAddress! + o, intoR: rb.baseAddress! + o, frames: n)
                    o += n
                }
            }
        }
        XCTAssertEqual(model.recoveryCount, 0)
        var m = [Float](repeating: 0, count: frames)
        for f in 0..<frames { m[f] = 0.5 * (l[f] + r[f]) }
        return m
    }

    /// Goertzel power of `x` at frequency `f` over [start, start+dur) sec.
    func goertzel(_ x: [Float], f: Double, start: Double, dur: Double) -> Double {
        let i0 = max(0, Int(start * fs))
        let n = min(x.count - i0, Int(dur * fs))
        guard n > 16 else { return 0 }
        let w = 2 * Double.pi * f / fs
        let c = 2 * cos(w)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in i0..<(i0 + n) {
            s0 = Double(x[i]) + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(n * n)
    }

    /// Envelope of harmonic at `f`: sliding Goertzel windows. Returns
    /// (times, powers).
    func harmonicEnvelope(_ x: [Float], f: Double, winSec: Double = 0.15,
                          hopSec: Double = 0.05) -> ([Double], [Double]) {
        var times: [Double] = []
        var powers: [Double] = []
        var t = 0.0
        let total = Double(x.count) / fs
        while t + winSec < total {
            times.append(t + winSec / 2)
            powers.append(goertzel(x, f: f, start: t, dur: winSec))
            t += hopSec
        }
        return (times, powers)
    }

    func peakTime(_ x: [Float], f: Double) -> Double {
        let (times, powers) = harmonicEnvelope(x, f: f)
        var best = 0
        for i in powers.indices where powers[i] > powers[best] { best = i }
        return times[best]
    }

    // MARK: - Tests

    func testDeterminism() {
        // All stochastic features ON; same seed must be sample-identical.
        let p = TanpuraParams()
        let plucks: [(Double, Int, Double)] = [(0.1, 0, 0.8), (0.5, 1, 0.7), (1.0, 3, 0.9)]
        let a = renderMono(p, plucks: plucks, seconds: 3, seed: 7)
        let b = renderMono(p, plucks: plucks, seconds: 3, seed: 7)
        XCTAssertEqual(a, b)
    }

    func testBoundedUnderExtremeParams() {
        var p = TanpuraParams()
        p.harmonicCount = 32
        p.jivaDepth = 1
        p.jivaRate = 3
        p.pitchDriftCents = 10
        p.pitchDriftRate = 2
        p.pluckVariationDB = 6
        p.noiseLevel = 1
        p.noiseQ = 8
        p.crossExcite = 0.5
        p.crossTolCents = 50
        p.tiltDB = 12
        p.masterGain = 1
        for b in 0..<3 { p.body[b].gain = 1.5; p.body[b].q = 25 }
        for i in 0..<4 {
            p.strings[i].level = 1.5
            p.strings[i].decay = 30
            p.strings[i].dampTilt = 0
            p.strings[i].falloff = 0
            p.strings[i].bloomDelay = 1.5
            p.strings[i].bloomSkew = 2
            p.strings[i].attackLevel = 1
            p.strings[i].inharmonicity = 0.002
        }
        var plucks: [(Double, Int, Double)] = []
        for i in 0..<16 { plucks.append((Double(i) * 0.3, i % 4, 1.5)) }
        let x = renderMono(p, plucks: plucks, seconds: 8)
        var peak: Float = 0
        for v in x {
            XCTAssertTrue(v.isFinite)
            peak = max(peak, abs(v))
        }
        // The output soft limiter caps each channel at ±1.0.
        XCTAssertLessThanOrEqual(peak, 1.01)
        XCTAssertGreaterThan(peak, 0.01)
    }

    func testTuningAccuracy() {
        var p = cleanParams()
        // A flat-spectrum string with strong upper harmonics (the matched
        // C3 defaults) makes the grid ambiguous; pin the law params so the
        // fundamental dominates and only tuning is under test.
        p.strings[3].falloff = 1.5
        p.strings[3].gainTrimDB = TanpuraParams.neutralGainTrims
        let nominal = p.strings[3].f0
        let x = renderMono(p, plucks: [(0, 3, 1.0)], seconds: 3)
        // Fine Goertzel grid around the C3 string's nominal f0.
        var bestF = 0.0, bestP = 0.0
        var f = nominal - 7.0
        while f <= nominal + 7.0 {
            let pw = goertzel(x, f: f, start: 0.5, dur: 2.0)
            if pw > bestP { bestP = pw; bestF = f }
            f += 0.05
        }
        XCTAssertEqual(bestF, nominal, accuracy: nominal * 0.005)
    }

    func testDecayOrdering() {
        // Pin bloom + trims so only the decay law differs between renders.
        var base = cleanParams()
        base.strings[3].bloomDelay = 0.02
        base.strings[3].attackLevel = 0.5
        base.strings[3].gainTrimDB = TanpuraParams.neutralGainTrims
        base.strings[3].peakTrim = TanpuraParams.neutralMulTrims
        base.strings[3].decayTrim = TanpuraParams.neutralMulTrims
        var pShort = base
        pShort.strings[3].decay = 2
        var pLong = base
        pLong.strings[3].decay = 8
        let xs = renderMono(pShort, plucks: [(0, 3, 1.0)], seconds: 2.5)
        let xl = renderMono(pLong, plucks: [(0, 3, 1.0)], seconds: 2.5)
        func rms(_ x: [Float], from: Double, to: Double) -> Double {
            let i0 = Int(from * fs), i1 = min(x.count, Int(to * fs))
            var acc = 0.0
            for i in i0..<i1 { acc += Double(x[i]) * Double(x[i]) }
            return (acc / Double(i1 - i0)).squareRoot()
        }
        XCTAssertGreaterThan(rms(xl, from: 1.5, to: 2.4), rms(xs, from: 1.5, to: 2.4) * 1.5)
    }

    /// THE tanpura property: with bloom enabled, higher harmonics peak
    /// substantially later than the fundamental; with bloom ≈ 0 they peak
    /// together.
    func testStaggeredHarmonicPeaks() {
        var p = cleanParams()
        p.strings[3].attackLevel = 0
        p.strings[3].decay = 8
        p.strings[3].dampTilt = 0.2
        p.strings[3].bloomDelay = 0.35
        p.strings[3].bloomSkew = 1.0
        p.strings[3].falloff = 0.8
        p.strings[3].gainTrimDB = TanpuraParams.neutralGainTrims
        p.strings[3].peakTrim = TanpuraParams.neutralMulTrims
        p.strings[3].decayTrim = TanpuraParams.neutralMulTrims
        let f0 = p.strings[3].f0
        let bloomed = renderMono(p, plucks: [(0, 3, 1.0)], seconds: 5)
        let t1 = peakTime(bloomed, f: f0)
        let t5 = peakTime(bloomed, f: 5 * f0)
        XCTAssertGreaterThan(t5, t1 + 0.8,
                             "harmonic 5 should peak ≫ later (t1=\(t1), t5=\(t5))")

        p.strings[3].bloomDelay = 0.005
        let flat = renderMono(p, plucks: [(0, 3, 1.0)], seconds: 5)
        let ft1 = peakTime(flat, f: f0)
        let ft5 = peakTime(flat, f: 5 * f0)
        XCTAssertLessThan(abs(ft5 - ft1), 0.3,
                          "without bloom, peaks coincide (t1=\(ft1), t5=\(ft5))")
    }

    /// With stochastic features off the model is linear: rendering two
    /// plucks together equals the sum of rendering them separately. This
    /// is what guarantees click-free re-plucks on a ringing string.
    func testPluckSuperposition() {
        let p = cleanParams()
        let a = renderMono(p, plucks: [(0.5, 3, 0.9)], seconds: 4)
        let b = renderMono(p, plucks: [(2.0, 3, 0.7)], seconds: 4)
        let c = renderMono(p, plucks: [(0.5, 3, 0.9), (2.0, 3, 0.7)], seconds: 4)
        var maxErr: Float = 0
        for i in 0..<c.count { maxErr = max(maxErr, abs(c[i] - (a[i] + b[i]))) }
        XCTAssertLessThan(maxErr, 2e-3)
    }

    /// Half-integer sub-bank: off by default (no energy between harmonics);
    /// enabling subLevelDB raises partials at (k+0.5)·f0 without moving the
    /// integer bank.
    func testSubharmonicBank() {
        var p = cleanParams()
        let pl: [(Double, Int, Double)] = [(0.1, 3, 0.9)]  // SA, f0 131.11
        let off = renderMono(p, plucks: pl, seconds: 2.5)
        p.strings[3].subLevelDB = -10
        let on = renderMono(p, plucks: pl, seconds: 2.5)
        let f0 = 131.11
        for kk in [0.5, 1.5, 2.5] {
            let offP = goertzel(off, f: kk * f0, start: 0.2, dur: 1.5)
            let onP = goertzel(on, f: kk * f0, start: 0.2, dur: 1.5)
            XCTAssertGreaterThan(onP, offP * 100,
                                 "sub partial at h\(kk) should appear when enabled")
        }
        // Integer bank unaffected (gains/laws untouched by the sub bank).
        let h1Off = goertzel(off, f: f0, start: 0.2, dur: 1.5)
        let h1On = goertzel(on, f: f0, start: 0.2, dur: 1.5)
        XCTAssertEqual(h1On, h1Off, accuracy: h1Off * 0.05)
    }

    func testSetPath() {
        var p = TanpuraParams()
        XCTAssertTrue(p.set(path: "jivaDepth", value: 0.7))
        XCTAssertEqual(p.jivaDepth, 0.7)
        XCTAssertTrue(p.set(path: "body1.freq", value: 333))
        XCTAssertEqual(p.body[1].freq, 333)
        XCTAssertTrue(p.set(path: "string2.decay", value: 9))
        XCTAssertEqual(p.strings[2].decay, 9)
        XCTAssertTrue(p.set(path: "string1.gainTrimDB13", value: -6))
        XCTAssertEqual(p.strings[1].gainTrimDB[13], -6)
        XCTAssertTrue(p.set(path: "string0.peakTrim4", value: 2.5))
        XCTAssertEqual(p.strings[0].peakTrim[4], 2.5)
        // Clamping.
        XCTAssertTrue(p.set(path: "string0.decay", value: 999))
        XCTAssertEqual(p.strings[0].decay, 30)
        // Unknown paths refused.
        XCTAssertFalse(p.set(path: "nope", value: 1))
        XCTAssertFalse(p.set(path: "string9.decay", value: 1))
        XCTAssertFalse(p.set(path: "string0.gainTrimDB99", value: 1))
    }

    func testSpecDecode() throws {
        let json = """
        {"durationSeconds": 2.5,
         "params": {"jivaDepth": 0.4,
                    "strings": [{"f0": 200, "gainTrimDB": [1, 2, 3]}]},
         "plucks": [{"at": 0.1, "string": 0, "velocity": 0.8}]}
        """
        let spec = try JSONDecoder().decode(TanpuraRenderSpec.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(spec.durationSeconds, 2.5)
        let p = try XCTUnwrap(spec.params)
        XCTAssertEqual(p.jivaDepth, 0.4)
        // Partial strings array padded back to 4 with defaults.
        XCTAssertEqual(p.strings.count, 4)
        XCTAssertEqual(p.strings[0].f0, 200)
        XCTAssertEqual(p.strings[3].f0, TanpuraParams().strings[3].f0)
        // Short trim array padded to maxHarmonics.
        XCTAssertEqual(p.strings[0].gainTrimDB.count, TanpuraParams.maxHarmonics)
        XCTAssertEqual(p.strings[0].gainTrimDB[1], 2)
        XCTAssertEqual(p.strings[0].gainTrimDB[10], 0)
        // Round-trip re-encode → re-decode.
        let enc = try JSONEncoder().encode(p)
        let p2 = try JSONDecoder().decode(TanpuraParams.self, from: enc)
        XCTAssertEqual(p, p2)
    }

    func testRiseTauSolver() {
        // The solved τr must put the envelope peak at the requested time.
        for (tp, tauD) in [(0.05, 2.0), (0.3, 4.0), (1.0, 8.0), (2.0, 3.0)] {
            let tauR = TanpuraString.solveRiseTau(peakTime: tp, tauD: tauD)
            let tStar = log(tauD / tauR) * tauR * tauD / (tauD - tauR)
            let expected = min(max(tp, 0.0005), 0.85 * tauD)
            XCTAssertEqual(tStar, expected, accuracy: max(0.002, expected * 0.02))
        }
    }
}
