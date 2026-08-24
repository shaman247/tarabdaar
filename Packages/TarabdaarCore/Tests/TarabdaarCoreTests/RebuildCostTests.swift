import XCTest
import SarangiKit
@testable import TarabdaarCore

/// What a `.rebuild` parameter actually costs (2026-07-24). A rebuild
/// constructs a whole fresh `BowEngine` off-thread and swaps it in
/// (`StringVoiceSource.setEngine`), so the price is two separate things:
///
///  1. **CPU/latency** — how long the build takes. It runs on
///     `stringBuildQueue`, never the audio thread, so this is delay before
///     the edit is heard, not a dropout.
///  2. **Continuity** — the new engine starts with ZERO kernel state: the
///     string delay lines, taraf ring, jawari rows and room tail are all
///     empty. A swap under a sounding note re-speaks the note and cuts the
///     tail.
///
/// These tests measure both so the numbers in the docs stay honest, and so
/// a future change that makes rebuilds cheap or continuous fails loudly
/// here instead of going unnoticed.
final class RebuildCostTests: XCTestCase {

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

    // MARK: - 1. Wall-clock

    /// Cost of one rebuild, and how much of it is the taraf/jawari table
    /// construction (which is what makes it expensive).
    func testRebuildWallClock() throws {
        let mapper = BowControlMapper()
        guard build(mapper: mapper) != nil else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // The strings are already in memory in the app (SarangiStore owns
        // them), so loading the preset must NOT be inside the timed region.
        let strings = piluStrings()
        func timedBuild(_ o: [String: Double]) -> Double {
            let t0 = Date()
            _ = StringVoiceSource.buildEngine(tonicHz: 328.9, strings: strings,
                                              mapper: mapper, overrides: o)
            return -t0.timeIntervalSinceNow * 1000.0
        }
        var whole: [Double] = []
        for i in 0..<7 { whole.append(timedBuild(["bow_body_q": 25.0 + Double(i)])) }
        whole.sort()

        // Nearly all of it is the settle pre-roll: rendering and discarding
        // audio so a fresh jt web does not chime on publish. Time a build
        // with the pre-roll disabled to show what the rest costs.
        let saved = StringVoiceSource.settleBlocks
        StringVoiceSource.settleBlocks = 0
        var bare: [Double] = []
        for i in 0..<5 { bare.append(timedBuild(["bow_body_q": 30.0 + Double(i)])) }
        StringVoiceSource.settleBlocks = saved
        bare.sort()

        let med = whole[whole.count / 2]
        let medBare = bare[bare.count / 2]
        print(String(format: """
            REBUILD COST (taraf rows %d, settle %d blocks)
              full build            median %6.1f ms   (min %.1f  max %.1f)
              tables + kernel only  median %6.1f ms
              → settle pre-roll is  %6.1f ms of it (%.0f%%)
            """,
            strings.count, saved, med, whole.first!, whole.last!,
            medBare, med - medBare, 100 * (med - medBare) / med))
        XCTAssertLessThan(med, 2000.0, "rebuild got pathologically slow")
    }

    // MARK: - 2. Continuity

    /// The honest continuity test: render the SAME held note two ways —
    /// (a) one engine straight through, (b) an identical engine swapped for
    /// a freshly-built one halfway — and compare the second halves.
    /// Deterministic builds make (a) the exact control for (b).
    func testSwapUnderASoundingNoteIsDiscontinuous() throws {
        let mapper = BowControlMapper()
        guard let control = build(mapper: mapper),
              let swapped = build(mapper: mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        mapper.midi(0xB0, 11, 32)          // the Mac pads' flat expression
        mapper.midi(0x90, 60, 100)         // note on, held throughout

        let n = 4096
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        func render(_ e: BowEngine, blocks: Int) -> [Double] {
            var out: [Double] = []
            for _ in 0..<blocks {
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: n, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                out.append(contentsOf: (0..<n).map { l[$0] + r[$0] })
            }
            return out
        }
        func rms(_ x: ArraySlice<Double>) -> Double {
            x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                             / Double(x.count)).squareRoot()
        }

        // Both engines render the same first ~0.85 s (identical builds,
        // identical mapper) — that is the "before the edit" audio.
        let head = render(control, blocks: 10)
        _ = render(swapped, blocks: 10)
        XCTAssertGreaterThan(rms(head[(head.count - 4096)...]), 1e-4,
                             "note never spoke — fixture is broken")

        // (a) keep going on the same engine; (b) swap in a fresh build.
        let contTail = render(control, blocks: 10)
        guard let fresh = build(mapper: mapper) else {
            return XCTFail("rebuild failed")
        }
        let swapTail = render(fresh, blocks: 10)

        // Sample-level step at the seam: last sample before vs first after.
        let lastBefore = head.last!
        let stepControl = abs(contTail[0] - lastBefore)
        let stepSwap = abs(swapTail[0] - lastBefore)

        // Envelope: how the fresh engine's first moments compare to the
        // steady tone it replaced.
        let steady = rms(contTail[0..<2048])
        let swapFirst = rms(swapTail[0..<2048])
        // How long until the swapped render matches the continuous one.
        var convergedMs = Double(swapTail.count) / 48.0
        for b in stride(from: 0, to: swapTail.count - 2048, by: 2048) {
            let a = rms(contTail[b..<(b + 2048)])
            let s = rms(swapTail[b..<(b + 2048)])
            if abs(s - a) <= 0.1 * max(a, 1e-12) {
                convergedMs = Double(b) / 48.0
                break
            }
        }
        print(String(format: """
            SWAP SEAM (note held across the rebuild)
              steady RMS before          %.5f
              first 43 ms after swap     %.5f  (%.0f%% of steady)
              sample step at seam        %.2e   (same engine: %.2e)
              back within 10%% of steady  %.0f ms
            """,
            steady, swapFirst, 100 * swapFirst / max(steady, 1e-12),
            stepSwap, stepControl, convergedMs))

        // A HELD note survives a swap well: the mapper's note state carries,
        // and a bowed string re-establishes Helmholtz motion within a few
        // periods, so the level is back almost immediately. The seam is a
        // step, not a dropout.
        XCTAssertGreaterThan(rms(swapTail[(swapTail.count - 4096)...]),
                             0.5 * steady,
                             "held note did not recover after the swap")
        XCTAssertGreaterThan(stepSwap, stepControl,
                             "swap is now sample-continuous — state carries "
                             + "across engines, so this premise is stale")
    }

    /// The case a rebuild really damages: the RING. After note-off the
    /// signal IS the sympathetic strings + room tail — pure engine state,
    /// with nothing driving it. A fresh engine has none of it.
    func testSwapDuringTheRingKillsTheTail() throws {
        let mapper = BowControlMapper()
        guard let control = build(mapper: mapper),
              let swapped = build(mapper: mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        mapper.midi(0xB0, 11, 32)
        mapper.midi(0x90, 60, 100)

        let n = 4096
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        func render(_ e: BowEngine, blocks: Int) -> [Double] {
            var out: [Double] = []
            for _ in 0..<blocks {
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: n, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                out.append(contentsOf: (0..<n).map { l[$0] + r[$0] })
            }
            return out
        }
        func rms(_ x: ArraySlice<Double>) -> Double {
            x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                             / Double(x.count)).squareRoot()
        }

        // bow the note on both identical engines, then release
        _ = render(control, blocks: 10)
        _ = render(swapped, blocks: 10)
        mapper.midi(0x80, 60, 0)
        // a moment of ring on both
        let ringA = render(control, blocks: 2)
        _ = render(swapped, blocks: 2)
        let ringLevel = rms(ringA[(ringA.count - 4096)...])

        // (a) let it ring on;  (b) swap in a fresh engine mid-ring
        let contRing = render(control, blocks: 6)
        guard let fresh = build(mapper: mapper) else {
            return XCTFail("rebuild failed")
        }
        let swapRing = render(fresh, blocks: 6)

        let contLevel = rms(contRing[0..<4096])
        let swapLevel = rms(swapRing[0..<4096])
        print(String(format: """
            SWAP DURING RING (rebuild after note-off)
              ring level at swap point   %.5f
              continues ringing          %.5f
              after a rebuild            %.5f  (%.1f%% of the tail)
            """,
            ringLevel, contLevel, swapLevel,
            100 * swapLevel / max(contLevel, 1e-12)))

        // The tail is engine state, so a raw engine swap silences it. THIS
        // is the artifact `StringVoiceSource`'s crossfade exists to hide
        // (see `testCrossfadePreservesTheRing`).
        XCTAssertLessThan(swapLevel, 0.25 * contLevel,
                          "the ring now survives a raw engine swap — state "
                          + "carries across engines, so this premise is stale")
    }

    // MARK: - 3. The two fixes

    /// The crossfade: a rebuild during the ring must no longer silence it.
    /// Renders through `StringVoiceSource`'s real callback path.
    func testCrossfadePreservesTheRing() throws {
        let src = StringVoiceSource()
        let mapper = src.mapper
        guard let first = build(mapper: mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(first, crossfadeMs: 0)
        mapper.midi(0xB0, 11, 32)
        mapper.midi(0x90, 60, 100)

        func pull(_ blocks: Int) -> [Double] {
            var out: [Double] = []
            for _ in 0..<blocks {
                let (l, r) = src.renderForTesting(frames: 4096)
                out.append(contentsOf: (0..<4096).map {
                    Double(l[$0]) + Double(r[$0])
                })
            }
            return out
        }
        func rms(_ x: ArraySlice<Double>) -> Double {
            x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                             / Double(x.count)).squareRoot()
        }

        _ = pull(10)                       // bow the note
        mapper.midi(0x80, 60, 0)           // release
        let ring = pull(2)
        let ringLevel = rms(ring[(ring.count - 4096)...])

        // rebuild mid-ring, WITH the crossfade
        guard let fresh = build(["bow_body_q": 26.0], mapper: mapper) else {
            return XCTFail("rebuild failed")
        }
        src.setEngine(fresh)
        let after = pull(6)
        let justAfter = rms(after[0..<4096])

        print(String(format: """
            CROSSFADED REBUILD DURING RING
              ring level at rebuild   %.5f
              first 85 ms after       %.5f  (%.0f%% — was 4.9%% with a hard swap)
            """,
            ringLevel, justAfter, 100 * justAfter / max(ringLevel, 1e-12)))

        XCTAssertGreaterThan(justAfter, 0.4 * ringLevel,
                             "crossfade is not preserving the ring")
    }

    /// The crossfade renders two engines at once. Confirm that window
    /// still fits the realtime budget with headroom.
    func testCrossfadeCpuFitsRealtime() throws {
        let src = StringVoiceSource()
        let mapper = src.mapper
        guard let a = build(mapper: mapper), let b = build(mapper: mapper) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(a, crossfadeMs: 0)
        mapper.midi(0xB0, 11, 32)
        mapper.midi(0x90, 60, 100)
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

    /// Publishing a freshly built engine must be SILENT. Historically this
    /// was a relative A/B (short pre-roll vs the old 6-block one) because
    /// the chime asymptoted at ~-50 dBFS and no affordable pre-roll could
    /// do better. The DAMPED SETTLE (2026-08-18) killed the chime at the
    /// cause — the taraf is choked while the discarded blocks render, so
    /// the q0 relax dies inside them and the anchors' 7-9 s tails never
    /// ride out — which makes an ABSOLUTE bar meaningful for the first
    /// time: publish peak (both engines idling through the crossfade) at
    /// or below -80 dBFS. Measured at the bake: -102 dBFS with 5 settle
    /// blocks, -110 with 6 (noise floor; the old relative 2 dB tolerance
    /// became a meaningless ratio of two near-zeros and was retired).
    func testShortPreRollIsNoLouderOnPublishThanTheOldLongOne() throws {
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
        let long = try publishPeak(settle: 6)        // the pre-2026-07-24 value
        let short = try publishPeak(settle: StringVoiceSource.settleBlocks)
        print(String(format: """
            PUBLISH CHIME (idle, through the crossfade)
              6-block pre-roll (old)   %.5f  (%.0f dBFS)
              %d-block pre-roll (now)   %.5f  (%.0f dBFS)
            """,
            long, 20 * log10(max(long, 1e-9)),
            StringVoiceSource.settleBlocks, short,
            20 * log10(max(short, 1e-9))))
        XCTAssertLessThan(20 * log10(max(long, 1e-9)), -80,
                          "even the LONG pre-roll publishes audibly — the "
                          + "damped settle is not choking the chime")
        XCTAssertLessThan(20 * log10(max(short, 1e-9)), -80,
                          "the shipped pre-roll publishes above -80 dBFS — "
                          + "the damped settle is not choking the chime "
                          + "(or settleBlocks fell below what the choke needs)")
    }
}
