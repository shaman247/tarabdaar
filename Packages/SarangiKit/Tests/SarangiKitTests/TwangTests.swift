import XCTest
@testable import SarangiKit

/// Guards for the `bow_twang` sitar-twang axis (2026-08-01): the grazing
/// jawari wrap + sitar-morph on the PLAYED strings' bridge termination
/// (`bow_poly_set_twang` / poly_string_return). Fit provenance and the
/// trajectory match against sitar1.wav live in TwangFitTests (the
/// env-gated offline harness).
final class TwangTests: XCTestCase {

    static let sr = 48000.0
    static let tonic = 328.9

    /// One staccato C4 (250 ms stroke + ring) on the shipping artifact,
    /// jt taraf off. `twang < 0` = never touch the twang API at all.
    private func render(twang: Double, expr: Double = 0.6,
                        seconds: Double = 2.0) throws -> [Double] {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let sr = Self.sr
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: Self.tonic, bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: 15.0,
                               reverbMix: 0.0, reverbWidth: 0.0)
        engine.outGain = bp.v("bow_live_trim", 0.175)
        if twang >= 0 { engine.setTwang(twang) }
        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        var out: [Double] = []
        out.reserveCapacity(Int(seconds * sr))
        func run(_ secs: Double) {
            var left = Int(secs * sr)
            while left > 0 {
                let m = min(1024, left)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                for i in 0..<m { out.append(0.5 * (l[i] + r[i])) }
                left -= m
            }
        }
        mapper.setAxis(expr: expr, press: 0.562, pos: 0.45)
        mapper.midi(0x90, 60, 100)
        run(0.25)
        mapper.midi(0x80, 60, 0)
        run(seconds - 0.25)
        return out
    }

    /// Band power around `t` seconds (43 ms Hann window).
    private func band(_ x: [Double], t: Double, lo: Double,
                      hi: Double) -> Double {
        let sr = Self.sr
        let n = 2048
        let c = Int(t * sr)
        guard c + n / 2 < x.count, c >= n / 2 else { return 0 }
        var acc = 0.0
        // Goertzel-free: coarse DFT over the band on a windowed slice
        let seg = (0..<n).map { i in
            x[c - n / 2 + i]
                * (0.5 - 0.5 * cos(2.0 * .pi * Double(i) / Double(n - 1)))
        }
        var f = lo
        let df = sr / Double(n)
        while f < hi {
            let w = 2.0 * .pi * f / sr
            var re = 0.0, im = 0.0
            for (i, s) in seg.enumerated() {
                re += s * cos(w * Double(i))
                im -= s * sin(w * Double(i))
            }
            acc += re * re + im * im
            f += df
        }
        return acc
    }

    /// twang 0 (explicit) is byte-identical to never touching the API —
    /// the parity guarantee behind the default-off registry value.
    func testTwangZeroIsByteNull() throws {
        let a = try render(twang: -1)
        let b = try render(twang: 0)
        XCTAssertEqual(a.count, b.count)
        for i in 0..<a.count where a[i] != b[i] {
            XCTFail("twang 0 diverged from untouched at sample \(i)")
            break
        }
    }

    /// twang 1: the ring keeps a sustained buzz band (2.5–6 kHz) hundreds
    /// of ms after release — the sitar signature the base voice loses
    /// within ~150 ms — stays finite/bounded, and the ring's pitch stays
    /// within a few cents of the base voice's.
    func testTwangOneSustainsBuzzBand() throws {
        let base = try render(twang: 0)
        let tw = try render(twang: 1)
        XCTAssertTrue(tw.allSatisfy(\.isFinite), "twang render not finite")
        let basePeak = base.map(abs).max() ?? 0
        let twPeak = tw.map(abs).max() ?? 0
        XCTAssertLessThan(twPeak, basePeak * 4.0 + 1e-6,
                          "twang blew up the level")
        // buzz-vs-low gap 600 ms into the ring (t = 0.85 s)
        func gap(_ x: [Double]) -> Double {
            let bz = band(x, t: 0.85, lo: 2500, hi: 6000)
            let lo = band(x, t: 0.85, lo: 200, hi: 1200)
            return 10.0 * log10((bz + 1e-24) / (lo + 1e-24))
        }
        let gBase = gap(base), gTw = gap(tw)
        // fitted: base ≈ -85 dB, twang ≈ -11 dB
        XCTAssertLessThan(gBase, -40.0,
                          "base ring unexpectedly buzzy (\(gBase) dB)")
        XCTAssertGreaterThan(gTw, -25.0,
                             "twang ring lost its buzz band (\(gTw) dB)")
        // ring pitch: strongest partial 150-500 Hz of the 0.35-1.2 s ring
        func f0(_ x: [Double]) -> Double {
            let n = Int(0.85 * Self.sr)
            let seg = Array(x[Int(0.35 * Self.sr)..<Int(1.2 * Self.sr)])
            var best = (f: 0.0, p: 0.0)
            var f = 150.0
            while f < 500 {
                let w = 2.0 * .pi * f / Self.sr
                var re = 0.0, im = 0.0
                for (i, s) in seg.enumerated() {
                    re += s * cos(w * Double(i))
                    im -= s * sin(w * Double(i))
                }
                let p = re * re + im * im
                if p > best.p { best = (f, p) }
                f += 0.5
            }
            _ = n
            return best.f
        }
        // The pitch lock (termination phase restore + wrap DC tracker +
        // the fitted selective-residual curve) holds the twanged ring
        // on the BASE ring's pitch to ~±5 c; the residual wanders with
        // the chaotic ring, so the guard allows headroom over typical.
        let cents = 1200.0 * log2(f0(tw) / f0(base))
        XCTAssertLessThan(abs(cents), 8.0,
                          "twang detuned the ring by \(cents) cents")
    }

    /// The twang engages at soft AND hard strokes — the consistency the
    /// parameter exists for (the graze knee rides the string's own
    /// envelope; a fixed knee twangs only at one level).
    func testTwangConsistentAcrossLevels() throws {
        for expr in [0.3, 0.85] {
            let tw = try render(twang: 1, expr: expr)
            let bz = band(tw, t: 0.85, lo: 2500, hi: 6000)
            let lo = band(tw, t: 0.85, lo: 200, hi: 1200)
            let gap = 10.0 * log10((bz + 1e-24) / (lo + 1e-24))
            XCTAssertGreaterThan(gap, -30.0,
                "twang absent at expr \(expr) (gap \(gap) dB)")
        }
    }

    /// Sweeping the amount mid-ring is click-free at the seam: the
    /// kernel slews ~30 ms, so the largest sample step under a live
    /// 0 → 1 jump stays comparable to the signal's own motion.
    func testTwangLiveSweepIsClickFree() throws {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let sr = Self.sr
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: Self.tonic, bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                               sr: sr, rfir: [],
                               eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: 1.0, reverbPredelayMs: 15.0,
                               reverbMix: 0.0, reverbWidth: 0.0)
        engine.outGain = bp.v("bow_live_trim", 0.175)
        var l = [Double](repeating: 0, count: 256)
        var r = [Double](repeating: 0, count: 256)
        var out: [Double] = []
        mapper.setAxis(expr: 0.6, press: 0.562, pos: 0.45)
        mapper.midi(0x90, 60, 100)
        var frames = 0
        while frames < Int(1.2 * sr) {
            if frames == Int(0.5 * sr) { engine.setTwang(1.0) }
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    engine.render(frames: 256, outL: lb.baseAddress!,
                                  outR: rb.baseAddress!)
                }
            }
            out.append(contentsOf: l)
            frames += 256
        }
        // largest step near the switch vs the signal's own steps
        func maxStep(_ a: Int, _ b: Int) -> Double {
            var m = 0.0
            for i in max(1, a)..<min(b, out.count) {
                m = max(m, abs(out[i] - out[i - 1]))
            }
            return m
        }
        let seam = maxStep(Int(0.5 * sr) - 256, Int(0.5 * sr) + 2400)
        let own = maxStep(Int(0.25 * sr), Int(0.5 * sr) - 256)
        XCTAssertLessThan(seam, own * 3.0 + 1e-9,
                          "twang engage clicked (seam \(seam) vs \(own))")
    }
}
