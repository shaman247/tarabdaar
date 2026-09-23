import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Rebuild path: the crossfade window fits realtime, and a fresh engine publishes silently (< −80 dBFS after the settle pre-roll). Serial (phase 2).
final class RebuildCostTests: XCTestCase {
    override func setUpWithError() throws { try skipUnlessSlowTestsEnabled() }

    private func piluStrings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    private func build(_ overrides: [String: Double] = [:],
                       mapper: BowControlMapper) -> BowEngine? {
        StringVoiceSource.buildEngine(tonicHz: 328.9,
                                      strings: piluStrings(),
                                      mapper: mapper,
                                      overrides: overrides)
    }

    /// The crossfade renders two engines at once — that window must still fit
    /// the realtime budget with headroom.
    func testCrossfadeCpuFitsRealtime() throws {
        let src = StringVoiceSource()
        let mapper = src.mapper
        guard let a = build(mapper: mapper), let b = build(mapper: mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(a, crossfadeMs: 0)
        mapper.setAxis(expr: 32.0 / 127.0)
        mapper.touchOn(1, pitchSemis: 60)
        // the size the app actually requests from CoreAudio
        let frames = Int(Config.preferredOutputBufferFrames)
        let budgetMs = Double(frames) / 48.0

        _ = src.renderForTesting(frames: 4096)      // warm up
        var single: [Double] = []
        for _ in 0..<40 {
            let t0 = Date()
            _ = src.renderForTesting(frames: frames)
            single.append(-t0.timeIntervalSinceNow * 1000.0)
        }
        // long fade so every measured buffer is inside the 2x window
        src.setEngine(b, crossfadeMs: 5000)
        var dual: [Double] = []
        for _ in 0..<40 {
            let t0 = Date()
            _ = src.renderForTesting(frames: frames)
            dual.append(-t0.timeIntervalSinceNow * 1000.0)
        }
        single.sort(); dual.sort()
        let s = single[single.count / 2], d = dual[dual.count / 2]
        print(String(format: """
            CROSSFADE CPU (%d-frame buffer = %.2f ms of audio)
              one engine    %.3f ms  (%.0f%% of realtime)
              two engines   %.3f ms  (%.0f%% of realtime)
            """,
            frames, budgetMs, s, 100 * s / budgetMs, d, 100 * d / budgetMs))

        XCTAssertLessThan(d, 0.9 * budgetMs,
                          "the crossfade window overruns the realtime budget")
    }

    /// Fresh banks publish below −80 dBFS through the crossfade across tuning and bone offsets.
    func testPublishingAFreshEngineIsSilent() throws {
        func publishPeak(settle: Int) throws -> Double {
            let saved = StringVoiceSource.settleBlocks
            StringVoiceSource.settleBlocks = settle
            defer { StringVoiceSource.settleBlocks = saved }
            let src = StringVoiceSource()
            guard let first = build(mapper: src.mapper),
                  let second = build(["bow_body_q": 26.0],
                                     mapper: src.mapper) else {
                throw XCTSkip("bowed_string.json not available in this bundle")
            }
            // nothing is ever played: whatever we hear is the chime alone
            src.setEngine(first, crossfadeMs: 0)
            _ = src.renderForTesting(frames: 4096)   // let `first` settle
            src.setEngine(second)                    // publish WITH crossfade
            var peak = 0.0
            for _ in 0..<4 {                         // ~340 ms, covers the fade
                let (l, r) = src.renderForTesting(frames: 4096)
                for i in 0..<4096 {
                    peak = max(peak, abs(Double(l[i]) + Double(r[i])))
                }
            }
            return peak
        }
        let long = try publishPeak(settle: 6)        // a longer minimum warmup
        let short = try publishPeak(settle: StringVoiceSource.settleBlocks)
        print(String(format: """
            PUBLISH CHIME (idle, through the crossfade)
              6-block minimum warmup   %.5f  (%.0f dBFS)
              %d-block minimum warmup   %.5f  (%.0f dBFS)
            """,
            long, 20 * log10(max(long, 1e-9)),
            StringVoiceSource.settleBlocks, short,
            20 * log10(max(short, 1e-9))))
        XCTAssertLessThan(20 * log10(max(long, 1e-9)), -80,
                          "the longer minimum warmup publishes above -80 dBFS")
        XCTAssertLessThan(20 * log10(max(short, 1e-9)), -80,
                          "the shipped minimum warmup publishes above -80 dBFS")
        // Tuned banks and moved bones exercise both stationary preparation
        // and the damped fallback. Measure each channel as well as the fold.
        for tonic in [164.45, 328.9, 440.0] {
            var state = Presets.state(.sarangiPilu)
            state.tonicHz = tonic
            for evolve in [0.0, 0.5, 1.0] {
                let engine = try XCTUnwrap(StringVoiceSource.buildEngine(
                    tonicHz: tonic, strings: state.resolvedStrings, mapper: BowControlMapper(),
                    overrides: ["bow_jt_evolve": evolve, "bow_jtc_evolve": evolve]))
                var l = [Double](repeating: 0, count: 4096), r = l
                var peak = 0.0
                for _ in 0..<6 {
                    l.withUnsafeMutableBufferPointer { lp in
                        r.withUnsafeMutableBufferPointer { rp in
                            engine.render(frames: 4096, outL: lp.baseAddress!, outR: rp.baseAddress!)
                        }
                    }
                    for i in l.indices {
                        XCTAssertTrue(l[i].isFinite && r[i].isFinite)
                        peak = max(peak, abs(l[i]), abs(r[i]), abs(l[i]+r[i]))
                    }
                }
                XCTAssertLessThan(peak, 1e-4, "audible publish at \(tonic) Hz, evolve \(evolve)")
            }
        }
    }

    /// Settling consumes no held touch, and a rendered engine cannot be reinitialized.
    func testBuildPreservesHeldTouch() throws {
        let mapper = BowControlMapper()
        mapper.setAxis(expr: 0.5, press: 0.56)
        mapper.touchOn(1, pitchSemis: 64)
        let engine = try XCTUnwrap(build(mapper: mapper))
        XCTAssertNil(engine.settleForPublication())
        var l = [Double](repeating: 0, count: 4096), r = l
        var peak = 0.0
        for _ in 0..<4 {
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    engine.render(frames: 4096, outL: lp.baseAddress!, outR: rp.baseAddress!)
                }
            }
            peak = max(peak, l.map { abs($0) }.max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 1e-3, "the setup render consumed or discarded the held touch")
    }
}
