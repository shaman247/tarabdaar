import XCTest
import SarangiKit
@testable import TarabdaarCore

/// In-place pushes: a full-range tilt flick at 60 Hz adds no more HF than a fine sweep (no zipper).
final class ZipperTests: XCTestCase {
    override func setUpWithError() throws { try skipUnlessSlowTestsEnabled() }

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    /// Render a held note while sweeping `key` from `lo` to `hi`, pushing a
    /// new value every `stepFrames` samples (the control rate).
    ///
    /// The measured signal starts AFTER the settle, and every metric here
    /// is coarse-vs-fine of the SAME sweep, so the settle only needs the
    /// tone speaking steadily — 4 blocks (~0.34 s, past the ~130 ms
    /// liveness settle), not the 8 the first cut rendered. And the jawari
    /// tables (~4.4 ms per push — the dominant cost of a 64-frame fine
    /// sweep) are rebuilt only for jt keys, the same rule the realtime
    /// rig uses; `testNoOpPushIsBitIdentical` proves a push of unchanged
    /// tables is inert, so skipping them for unrelated keys changes
    /// nothing but the wall clock.
    private func sweep(key: String, lo: Double, hi: Double,
                       stepFrames: Int, seconds: Double) -> [Double]? {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper) else {
            return nil
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.setAxis(expr: 64.0 / 127.0)
        src.mapper.touchOn(1, pitchSemis: 60, velocity: 100.0 / 127.0)
        // settle into a steady tone first
        for _ in 0..<4 { _ = src.renderForTesting(frames: 4096) }

        let total = Int(seconds * src.modelSR)
        var out: [Double] = []
        out.reserveCapacity(total)
        var done = 0
        while done < total {
            let t = Double(done) / Double(total)
            _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                    overrides: [key: lo + t * (hi - lo)],
                                    needsJawariTables: key.hasPrefix("bow_jt"))
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

}
