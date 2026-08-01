import XCTest
import SarangiKit
@testable import StarpadCore

/// ZIPPER EVALUATION (2026-07-24). The in-place push writes the kernel's
/// per-sample scalars directly. A tilt updates at ~60 Hz, so a swept
/// parameter lands as a 60 Hz STAIRCASE — the classic cause of zipper
/// noise (each step is a small discontinuity, and a train of them is
/// broadband buzz at the step rate).
///
/// Measured as excess high-frequency energy against the same sweep run at
/// a much finer step rate: if the coarse staircase is audibly rougher, the
/// steps are being heard.
final class ZipperTests: XCTestCase {

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    /// Render a held note while sweeping `key` from `lo` to `hi`, pushing a
    /// new value every `stepFrames` samples (the control rate).
    private func sweep(key: String, lo: Double, hi: Double,
                       stepFrames: Int, seconds: Double) -> [Double]? {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper) else {
            return nil
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 64)
        src.mapper.midi(0x90, 60, 100)
        // settle into a steady tone first
        for _ in 0..<8 { _ = src.renderForTesting(frames: 4096) }

        let total = Int(seconds * src.modelSR)
        var out: [Double] = []
        out.reserveCapacity(total)
        var done = 0
        while done < total {
            let t = Double(done) / Double(total)
            _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                    overrides: [key: lo + t * (hi - lo)])
            let n = min(stepFrames, total - done)
            let (l, r) = src.renderForTesting(frames: n)
            out.append(contentsOf: (0..<n).map { Double(l[$0]) + Double(r[$0]) })
            done += n
        }
        return out
    }

    /// Energy above `fc` via a crude 4th-order one-pole-cascade high-pass —
    /// enough to see broadband step noise without pulling in an FFT.
    private func hfEnergy(_ x: [Double], fc: Double, sr: Double) -> Double {
        let a = exp(-2.0 * Double.pi * fc / sr)
        var lp = [Double](repeating: 0, count: 4)
        var sum = 0.0
        for v in x {
            var s = v
            for i in 0..<4 {
                lp[i] = a * lp[i] + (1 - a) * s
                s -= lp[i]            // cascade of high-passes
            }
            sum += s * s
        }
        return (sum / Double(max(x.count, 1))).squareRoot()
    }

    /// The headline check: a 60 Hz staircase vs a near-continuous sweep of
    /// the same parameter over the same range and duration.
    func testTiltRateSweepDoesNotAddBroadbandNoise() throws {
        let sr = 48000.0
        let tiltStep = Int(sr / 60.0)          // ~800 frames: one tilt update
        let fineStep = 64                      // ~1.3 ms: effectively smooth
        guard let coarse = sweep(key: "bow_mu_s", lo: 0.5, hi: 1.15,
                                 stepFrames: tiltStep, seconds: 2.0),
              let fine = sweep(key: "bow_mu_s", lo: 0.5, hi: 1.15,
                               stepFrames: fineStep, seconds: 2.0) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let n = min(coarse.count, fine.count)
        let hCoarse = hfEnergy(Array(coarse[0..<n]), fc: 9000, sr: sr)
        let hFine = hfEnergy(Array(fine[0..<n]), fc: 9000, sr: sr)
        let db = 20 * log10(max(hCoarse, 1e-15) / max(hFine, 1e-15))

        // Also look for isolated steps: the largest sample-to-sample jump.
        func maxDelta(_ x: [Double]) -> Double {
            var m = 0.0
            for i in 1..<x.count { m = max(m, abs(x[i] - x[i - 1])) }
            return m
        }
        print(String(format: """
            ZIPPER (bow_mu_s swept 0.50 -> 1.15 over 2 s, held note)
              HF energy >9 kHz, 60 Hz steps   %.3e
              HF energy >9 kHz, ~750 Hz steps %.3e
              excess from the staircase       %+.2f dB
              max sample step  coarse %.2e   fine %.2e
            """,
            hCoarse, hFine, db, maxDelta(Array(coarse[0..<n])),
            maxDelta(Array(fine[0..<n]))))

        // A staircase that is genuinely inaudible sits within a dB or so of
        // the smooth sweep. More than 3 dB of excess HF means the steps are
        // being heard and the scalars need chunk-rate smoothing.
        XCTAssertLessThan(db, 3.0,
                          "60 Hz parameter steps add \(db) dB of HF — zipper; "
                          + "smooth the scalar push")
    }

    /// A single large jump — the worst case a UI slider or an audition
    /// script can produce — must not click.
    func testSingleLargeJumpDoesNotClick() throws {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 64)
        src.mapper.midi(0x90, 60, 100)
        for _ in 0..<8 { _ = src.renderForTesting(frames: 4096) }

        func block(_ n: Int) -> [Double] {
            let (l, r) = src.renderForTesting(frames: n)
            return (0..<n).map { Double(l[$0]) + Double(r[$0]) }
        }
        let before = block(4096)
        // the largest legal move on the friction knee
        _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                overrides: ["bow_mu_s": 1.2, "bow_mu_d": 0.1,
                                            "bow_v0": 0.05])
        let after = block(4096)

        var baseline = 0.0
        for i in 1..<before.count {
            baseline = max(baseline, abs(before[i] - before[i - 1]))
        }
        let seam = abs(after[0] - before[before.count - 1])
        print(String(format:
            "SINGLE JUMP: step at seam %.3e, largest step in steady tone %.3e (%.1fx)",
            seam, baseline, seam / max(baseline, 1e-12)))
        XCTAssertLessThan(seam, 3.0 * baseline,
                          "a parameter jump clicks — the seam step is larger "
                          + "than the signal's own sample-to-sample motion")
    }

    /// The real risk: `bow_mu_s` is a friction COEFFICIENT inside a
    /// feedback loop — stepping it changes how the string evolves, not the
    /// current sample, so it cannot click. Parameters that MULTIPLY the
    /// output (drive weight, radiation floor, jawari mix, trim, room mix)
    /// are different: a step in one of those is a step in the signal.
    /// Sweep each and check for excess HF against a fine sweep.
    func testGainLikeParametersDoNotZipperAtTiltRate() throws {
        let sr = 48000.0
        let tiltStep = Int(sr / 60.0)
        let gainLike: [(String, Double, Double)] = [
            ("bow_w", 0.6, 1.8),            // bridge-force weight (pre-radiation)
            ("bow_body_c0", 0.05, 0.8),     // direct radiation floor
            ("bow_jt_gain", 0.05, 1.0),     // jawari-web output mix
            ("bow_live_trim", 0.05, 0.35),  // output trim (Swift-side gain)
            ("bow_rev_mix", 0.0, 0.3),      // room mix (Swift-side)
        ]
        var report = "ZIPPER — GAIN-LIKE PARAMETERS (60 Hz steps vs smooth)\n"
        var offenders: [String] = []
        for (key, lo, hi) in gainLike {
            guard let coarse = sweep(key: key, lo: lo, hi: hi,
                                     stepFrames: tiltStep, seconds: 1.5),
                  let fine = sweep(key: key, lo: lo, hi: hi,
                                   stepFrames: 64, seconds: 1.5) else {
                throw XCTSkip("bowed_string.json not available in this bundle")
            }
            let n = min(coarse.count, fine.count)
            let hc = hfEnergy(Array(coarse[0..<n]), fc: 9000, sr: sr)
            let hf = hfEnergy(Array(fine[0..<n]), fc: 9000, sr: sr)
            let db = 20 * log10(max(hc, 1e-15) / max(hf, 1e-15))
            report += String(format: "  %-16@ %+6.2f dB excess HF\n",
                             key as NSString, db)
            if db > 3.0 { offenders.append("\(key) (\(db) dB)") }
        }
        print(report)
        XCTAssertTrue(offenders.isEmpty,
                      "these zipper at tilt rate and need smoothing: "
                      + "\(offenders)")
    }

    /// WORST CASE: a tilt FLICKED — full parameter range in ~150 ms. At
    /// 60 Hz that is only ~9 updates, so each step is a large fraction of
    /// the range. A slow sweep hides zipper; this is where it shows.
    func testFastFlickDoesNotZipper() throws {
        let sr = 48000.0
        let tiltStep = Int(sr / 60.0)
        let fast = 0.15                       // seconds for the whole range
        let gainLike: [(String, Double, Double)] = [
            ("bow_w", 0.6, 1.8),
            ("bow_body_c0", 0.05, 0.8),
            ("bow_jt_gain", 0.05, 1.0),
            ("bow_live_trim", 0.05, 0.35),
            ("bow_rev_mix", 0.0, 0.3),
            ("bow_mu_s", 0.5, 1.15),
        ]
        var report = "ZIPPER — FAST FLICK (full range in 150 ms)\n"
        var offenders: [String] = []
        for (key, lo, hi) in gainLike {
            guard let coarse = sweep(key: key, lo: lo, hi: hi,
                                     stepFrames: tiltStep, seconds: fast),
                  let fine = sweep(key: key, lo: lo, hi: hi,
                                   stepFrames: 64, seconds: fast) else {
                throw XCTSkip("bowed_string.json not available in this bundle")
            }
            let n = min(coarse.count, fine.count)
            let hc = hfEnergy(Array(coarse[0..<n]), fc: 9000, sr: sr)
            let hf = hfEnergy(Array(fine[0..<n]), fc: 9000, sr: sr)
            let db = 20 * log10(max(hc, 1e-15) / max(hf, 1e-15))
            report += String(format: "  %-16@ %+6.2f dB excess HF\n",
                             key as NSString, db)
            if db > 3.0 { offenders.append("\(key) \(String(format: "%+.1f dB", db))") }
        }
        print(report)
        XCTAssertTrue(offenders.isEmpty,
                      "zipper on a fast flick: \(offenders) — smooth the push")
    }

    /// The one case that MUST click if anything does: an instantaneous
    /// full-range jump on a pure OUTPUT GAIN (`bow_live_trim`, 0.05 -> 0.35
    /// is +17 dB). Unlike the friction coefficients, this multiplies the
    /// signal directly, so the step lands in the waveform. An audition
    /// script or a snapped composite can produce exactly this.
    func testInstantOutputGainJumpIsTheWorstCase() throws {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper,
            overrides: ["bow_live_trim": 0.05]) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 64)
        src.mapper.midi(0x90, 60, 100)
        for _ in 0..<8 { _ = src.renderForTesting(frames: 4096) }
        func block(_ n: Int) -> [Double] {
            let (l, r) = src.renderForTesting(frames: n)
            return (0..<n).map { Double(l[$0]) + Double(r[$0]) }
        }
        let before = block(4096)
        _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                overrides: ["bow_live_trim": 0.35])
        let after = block(4096)

        var baseline = 0.0
        for i in 1..<before.count {
            baseline = max(baseline, abs(before[i] - before[i - 1]))
        }
        let seam = abs(after[0] - before[before.count - 1])
        let ratio = seam / max(baseline, 1e-12)
        print(String(format: """
            INSTANT +17 dB GAIN JUMP (bow_live_trim 0.05 -> 0.35)
              step at the seam            %.3e
              largest step in steady tone %.3e
              ratio                       %.1fx  (>1 = the jump is the
                                          loudest transition in the signal)
            """, seam, baseline, ratio))
        // Documents the behavior rather than gating it: if this ever grows
        // past the signal's own motion, the gain-like scalars need a
        // chunk-rate ramp.
        XCTAssertLessThan(ratio, 3.0,
                          "an instant gain jump clicks — ramp the gain-like "
                          + "scalars at chunk rate")
    }
}
