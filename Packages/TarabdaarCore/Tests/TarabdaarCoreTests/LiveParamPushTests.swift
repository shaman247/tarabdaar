import XCTest
import SarangiKit
@testable import TarabdaarCore

/// In-place parameter push: a pushed value renders like a rebuilt engine, and a no-op push is bit-identical.
final class LiveParamPushTests: XCTestCase {
    override func setUpWithError() throws { try skipUnlessSlowTestsEnabled() }

    /// Serial jt (the parity tests' rule): the async dispatcher + worker
    /// pool are for realtime headroom, not offline pulls — faster-than-
    /// realtime rendering underruns the web ring constantly, exercising
    /// the offline-pull fallback against the dispatcher, and the async
    /// path drops drive blocks under load so nothing repeats exactly
    /// anyway. Every buildEngine in this suite takes these.
    private static let deterministic: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
    ]

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    private func makeSource() -> (StringVoiceSource, BowEngine)? {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper,
            overrides: Self.deterministic) else {
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

    /// A pushed edit must land on the same sound a rebuild would have
    /// produced. Compares the steady state of (a) push-then-settle against
    /// (b) an engine built with the value baked in from the start.
    ///
    /// SETTLE LENGTH MATTERS (the taraf-web removal). This used
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
            overrides: Self.deterministic.merging([key: v]) { _, b in b })
        else { return XCTFail("build failed") }
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
                tonicHz: 328.9, strings: strings, mapper: src.mapper,
                overrides: Self.deterministic) else {
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
