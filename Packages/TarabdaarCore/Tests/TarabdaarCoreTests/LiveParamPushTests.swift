import XCTest
import SarangiKit
@testable import TarabdaarCore

/// In-place parameter push: a pushed value renders like a rebuilt engine, and a no-op push is bit-identical.
final class LiveParamPushTests: XCTestCase {
    override func setUpWithError() throws { try skipUnlessSlowTestsEnabled() }

    /// Serial jt (the parity rule): the async pool drops drive blocks under
    /// load, so only the serial path repeats exactly.
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

    /// A pushed edit lands on the same sound a rebuild would have produced:
    /// the steady state of push-then-settle against an engine built with the
    /// value baked in. Both sides must reach a genuine steady state — compared
    /// mid-transient the two legitimately differ.
    func testPushedValueMatchesARebuiltEngine() throws {
        let key = "bow_mu_s", v = 1.1
        guard let (pushed, _) = makeSource() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        pushed.mapper.setAxis(expr: 64.0 / 127.0)
        pushed.mapper.touchOn(1, pitchSemis: 60, velocity: 100.0 / 127.0)
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
        rebuilt.mapper.setAxis(expr: 64.0 / 127.0)
        rebuilt.mapper.touchOn(1, pitchSemis: 60, velocity: 100.0 / 127.0)
        _ = pull(rebuilt, 8)
        let rebuiltTail = pull(rebuilt, 30)

        let p = rms(pushedTail[(pushedTail.count - 65536)...])
        let r = rms(rebuiltTail[(rebuiltTail.count - 65536)...])
        let db = 20 * log10(max(p, 1e-12) / max(r, 1e-12))
        print(String(format:
            "PUSH vs REBUILD (%@ = %.2f): pushed %.5f, rebuilt %.5f (%+.2f dB)",
            key, v, p, r, db))
        // Same physics, different history — the friction loop is chaotic, so
        // demand agreement in level rather than sample identity.
        XCTAssertLessThan(abs(db), 1.5,
                          "a pushed value settles somewhere a rebuild does not")
    }

    /// A push that changes NOTHING must be bit-identical: arming the ramp caps
    /// the render chunk, and chunk size sets the control grid and the jt block
    /// boundaries, so a no-op push could move a chaotic friction loop.
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
            src.mapper.setAxis(expr: 64.0 / 127.0)
            src.mapper.touchOn(1, pitchSemis: 60, velocity: 100.0 / 127.0)
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
