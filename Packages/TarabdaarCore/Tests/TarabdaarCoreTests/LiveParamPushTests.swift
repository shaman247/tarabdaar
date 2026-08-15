import XCTest
import SarangiKit
@testable import TarabdaarCore

/// IN-PLACE PARAMETER PUSH (2026-07-24 stages 1+2). A parameter in
/// `ParamRegistry.inPlaceKeys` is applied to the RUNNING engine — the
/// kernel's 61 per-sample scalars are overwritten and the Swift-side
/// mapping constants re-read — instead of building a new engine.
///
/// Two things must hold, and they pull against each other:
///   1. **Equivalence** — the pushed engine must sound like a rebuilt one.
///   2. **Continuity** — it must not click, and must not disturb a
///      sounding note or a decaying ring.
final class LiveParamPushTests: XCTestCase {

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    private func makeSource() -> (StringVoiceSource, BowEngine)? {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper) else {
            return nil
        }
        src.setEngine(e, crossfadeMs: 0)
        return (src, e)
    }

    private func rms(_ x: ArraySlice<Double>) -> Double {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                         / Double(x.count)).squareRoot()
    }

    private func pull(_ src: StringVoiceSource, _ blocks: Int) -> [Double] {
        var out: [Double] = []
        for _ in 0..<blocks {
            let (l, r) = src.renderForTesting(frames: 4096)
            out.append(contentsOf: (0..<4096).map {
                Double(l[$0]) + Double(r[$0])
            })
        }
        return out
    }

    /// Every key we claim is in-place must ACTUALLY reach the sound — a
    /// typo in `inPlaceKeys` would silently make a parameter inert, which
    /// is worse than a rebuild.
    func testEveryInPlaceKeyAudiblyChangesTheSound() throws {
        var inert: [String] = []
        for key in ParamRegistry.inPlaceKeys.sorted() {
            guard let spec = ParamRegistry.spec(key), spec.apply != .live else {
                continue
            }
            guard let (src, _) = makeSource() else {
                throw XCTSkip("bowed_string.json not available in this bundle")
            }
            src.mapper.midi(0xB0, 11, 64)
            src.mapper.midi(0x90, 60, 100)
            _ = pull(src, 6)                       // settle into steady tone
            let before = pull(src, 2)

            // push a big but in-range change
            let cur = spec.def
            let v = abs(cur - spec.lo) > abs(spec.hi - cur) ? spec.lo : spec.hi
            _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                    overrides: [key: v])
            let after = pull(src, 3)

            let a = rms(before[(before.count - 4096)...])
            let b = rms(after[(after.count - 4096)...])
            // a few keys are deliberately subtle; require only that the
            // waveform moved, not that the level did
            let moved = abs(b - a) > 0.002 * max(a, 1e-9)
                || zip(before.suffix(4096), after.suffix(4096))
                    .contains { abs($0 - $1) > 1e-9 }
            if !moved { inert.append(key) }
        }
        // A key that did not move the sound is only a BUG if a rebuild with
        // the same override would have moved it. Some parameters are gated
        // by another (e.g. `bow_Zt`, the torsional loss, does nothing while
        // `bow_tors_c` = 0 — the shipped default), and those are inert
        // either way. Check the survivors against a real rebuild.
        var broken: [String] = []
        for key in inert {
            guard let spec = ParamRegistry.spec(key) else { continue }
            let cur = spec.def
            let v = abs(cur - spec.lo) > abs(spec.hi - cur) ? spec.lo : spec.hi
            func tail(_ o: [String: Double]) -> [Double] {
                let s = StringVoiceSource()
                guard let e = StringVoiceSource.buildEngine(
                    tonicHz: 328.9, strings: strings(), mapper: s.mapper,
                    overrides: o) else { return [] }
                s.setEngine(e, crossfadeMs: 0)
                s.mapper.midi(0xB0, 11, 64)
                s.mapper.midi(0x90, 60, 100)
                return pull(s, 8)
            }
            let base = tail([:]), probe = tail([key: v])
            guard base.count == probe.count, !base.isEmpty else { continue }
            if zip(base.suffix(4096), probe.suffix(4096))
                .contains(where: { abs($0 - $1) > 1e-9 }) {
                broken.append(key)      // a rebuild hears it, our push does not
            } else {
                print("  (inert in this configuration, rebuild agrees: \(key))")
            }
        }
        XCTAssertTrue(broken.isEmpty,
                      "these inPlaceKeys reach the sound on a REBUILD but "
                      + "not through the live push: \(broken)")
    }

    /// A pushed edit must land on the same sound a rebuild would have
    /// produced. Compares the steady state of (a) push-then-settle against
    /// (b) an engine built with the value baked in from the start.
    ///
    /// SETTLE LENGTH MATTERS (2026-07-24, the taraf-web removal). This used
    /// to render 10 blocks and measure the last 8192 samples, which caught
    /// the bowed tone still on its way to steady state — the two engines
    /// were compared mid-transient. The linear sympathetic web hid that:
    /// its ring was a large, history-insensitive share of the total RMS.
    /// With the web gone the pure string's transient is the whole signal
    /// and the same window read 2.1 dB (2.3 dB on the pre-removal build
    /// with the web merely silenced — i.e. the window, not the change).
    /// Rendering to a genuine steady state instead puts push and rebuild
    /// within 0.1 dB, which is the claim this test exists to make.
    func testPushedValueMatchesARebuiltEngine() throws {
        let key = "bow_mu_s", v = 1.1
        guard let (pushed, _) = makeSource() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        pushed.mapper.midi(0xB0, 11, 64)
        pushed.mapper.midi(0x90, 60, 100)
        _ = pull(pushed, 8)
        _ = pushed.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                   overrides: [key: v])
        let pushedTail = pull(pushed, 30)

        // the control: same note, same value, but BUILT in
        let rebuilt = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: rebuilt.mapper,
            overrides: [key: v]) else { return XCTFail("build failed") }
        rebuilt.setEngine(e, crossfadeMs: 0)
        rebuilt.mapper.midi(0xB0, 11, 64)
        rebuilt.mapper.midi(0x90, 60, 100)
        _ = pull(rebuilt, 8)
        let rebuiltTail = pull(rebuilt, 30)

        let p = rms(pushedTail[(pushedTail.count - 65536)...])
        let r = rms(rebuiltTail[(rebuiltTail.count - 65536)...])
        let db = 20 * log10(max(p, 1e-12) / max(r, 1e-12))
        print(String(format:
            "PUSH vs REBUILD (%@ = %.2f): pushed %.5f, rebuilt %.5f (%+.2f dB)",
            key, v, p, r, db))
        // Same physics, different history — the friction loop is chaotic,
        // so demand agreement in level rather than sample identity. The
        // measured figure is ~0.1 dB; the bar is loose enough to survive a
        // note landing on a slightly different limit cycle.
        XCTAssertLessThan(abs(db), 1.5,
                          "a pushed value settles somewhere a rebuild does not")
    }

    /// The whole point: pushing must not interrupt what is sounding.
    /// Compare against the hard-swap numbers in `RebuildCostTests`
    /// (4.9% of the tail survived a raw engine swap).
    func testPushDoesNotDisturbASoundingNoteOrTheRing() throws {
        guard let (src, _) = makeSource() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.mapper.midi(0xB0, 11, 64)
        src.mapper.midi(0x90, 60, 100)
        _ = pull(src, 8)
        let held = pull(src, 2)
        let heldLevel = rms(held[(held.count - 4096)...])
        let lastBefore = held.last!

        // a sizeable edit, mid-note
        _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                overrides: ["bow_noise": 0.3])
        let after = pull(src, 2)
        let step = abs(after[0] - lastBefore)
        let afterLevel = rms(after[0..<4096])

        // now the ring: release and push during the decay
        src.mapper.midi(0x80, 60, 0)
        let ring = pull(src, 2)
        let ringLevel = rms(ring[(ring.count - 4096)...])
        _ = src.applyLiveParams(tonicHz: 328.9, strings: strings(),
                                overrides: ["bow_noise": 0.05])
        let ringAfter = pull(src, 2)
        let ringKept = rms(ringAfter[0..<4096])

        print(String(format: """
            IN-PLACE PUSH CONTINUITY
              held note: %.5f -> %.5f (%.0f%% kept), step at seam %.2e
              ring:      %.5f -> %.5f (%.0f%% kept)   [hard swap kept 4.9%%]
            """,
            heldLevel, afterLevel, 100 * afterLevel / max(heldLevel, 1e-12),
            step, ringLevel, ringKept,
            100 * ringKept / max(ringLevel, 1e-12)))

        XCTAssertGreaterThan(afterLevel, 0.5 * heldLevel,
                             "the note dropped out on a live push")
        // The ring is pure engine state; an in-place push must leave it be.
        XCTAssertGreaterThan(ringKept, 0.5 * ringLevel,
                             "the ring was disturbed by a live push")
    }

    /// A push that changes NOTHING must be bit-identical. This caught a
    /// real bug: arming the ramp caps `render`'s chunk to 256 frames, and
    /// chunk size sets the control-interpolation grid and the jt block
    /// boundaries — so a no-op push split a 4096-frame offline render and
    /// moved a chaotic friction loop by 41% of peak. The ramp is now armed
    /// only when a ramped quantity actually moved.
    func testNoOpPushIsBitIdentical() throws {
        let strings = self.strings()
        func run(push: Bool) -> [Double] {
            let src = StringVoiceSource()
            guard let e = StringVoiceSource.buildEngine(
                tonicHz: 328.9, strings: strings, mapper: src.mapper) else {
                return []
            }
            src.setEngine(e, crossfadeMs: 0)
            src.mapper.midi(0xB0, 11, 64)
            src.mapper.midi(0x90, 60, 100)
            var out: [Double] = []
            for i in 0..<10 {
                if push, i == 5 {
                    _ = src.applyLiveParams(tonicHz: 328.9, strings: strings,
                                            overrides: [:])
                }
                out.append(contentsOf: pull(src, 1))
            }
            return out
        }
        let a = run(push: false), b = run(push: true)
        guard a.count == b.count, !a.isEmpty else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        var maxDiff = 0.0
        for i in 0..<a.count { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
        print(String(format: "NO-OP PUSH: max deviation %.3e", maxDiff))
        XCTAssertEqual(maxDiff, 0.0,
                       "a push that changes nothing perturbed the sound")
    }
}
