import XCTest
import SarangiKit
@testable import TarabdaarCore

/// TWO-WAY BRIDGE COUPLING (`bow_jt_couple`): the stability guard that the
/// loop closes without ringing forever — a resting web returns nothing, a
/// coupled ring goes fully silent with every row asleep, and the top of the
/// knob's range still decays under the heavy case it was measured on.
final class TarafCoupleTests: XCTestCase {

    private struct Rig {
        let e: BowEngine
        let mapper: BowControlMapper
        let sr: Double
    }

    private func makeRig(_ extra: [String: Double] = [:]) throws -> Rig {
        var over: [String: Double] = ["bow_jt_async": 0.0, "bow_jt_threads": 0.0]
        for (k, v) in extra { over[k] = v }
        let mapper = BowControlMapper()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: mapper,
            overrides: over) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        return Rig(e: e, mapper: mapper, sr: e.sr)
    }

    @discardableResult
    private func render(_ r: Rig, seconds: Double) -> [Double] {
        let block = 256
        var l = [Double](repeating: 0, count: block)
        var rr = [Double](repeating: 0, count: block)
        var out: [Double] = []
        let n = Int(seconds * r.sr)
        var done = 0
        while done < n {
            let k = min(block, n - done)
            l.withUnsafeMutableBufferPointer { lp in
                rr.withUnsafeMutableBufferPointer { rp in
                    r.e.render(frames: k, outL: lp.baseAddress!,
                               outR: rp.baseAddress!)
                }
            }
            out.append(contentsOf: l[0..<k])
            done += k
        }
        return out
    }

    private static func peak(_ x: ArraySlice<Double>) -> Double {
        var m = 0.0
        for v in x where abs(v) > m { m = abs(v) }
        return m
    }
    private static func rms(_ x: ArraySlice<Double>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
    }
    private static func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-30)) }

    /// A resting web returns nothing: measured with the quiescence gate
    /// disarmed, so no row can sleep and the return is the web's own standing
    /// state — a DC term there self-excites the whole web from silence.
    func testRestingWebReturnsNoBridgeLoad() throws {
        try skipUnlessSlowTestsEnabled()
        let r = try makeRig(["bow_jt_gate": 0.0])
        r.e.setJtCouple(1.0)                    // the top of the range
        let out = render(r, seconds: 4.0)       // no note is ever played
        let tail = out[Int(3.0 * r.sr)...]
        let mean = abs(tail.reduce(0, +) / Double(tail.count))
        XCTAssertLessThan(Self.rms(tail), 3e-2,
                          "a resting web is loading the bridge")
        XCTAssertLessThan(mean, 1e-5, "the return carries a DC term")
    }

    /// A coupled ring must END: at the top of the range a bowed Sa's 12 s ring
    /// falls the way the uncoupled one does, with every row asleep.
    func testCoupledRingGoesFullySilent() throws {
        try skipUnlessSlowTestsEnabled()
        let r = try makeRig()
        r.e.setJtCouple(1.0)
        r.mapper.setAxis(expr: 32.0 / 127.0, press: 71.0 / 127.0)
        render(r, seconds: 1.0)                 // settle
        r.mapper.touchOn(1, pitchSemis: 64, velocity: 100.0 / 127.0)
        render(r, seconds: 0.6)
        r.mapper.touchOff(1)
        let ring = render(r, seconds: 12.0)
        let tail = ring[Int(11.5 * r.sr)...]
        XCTAssertLessThan(Self.db(Self.peak(tail)), -80.0,
                          "the coupled ring never goes silent")
        let probe = r.e.jtGateProbe()
        XCTAssertEqual(r.e.jtGateAsleep(), probe.total,
                       "rows are still awake after a 12 s ring")
    }

    /// The heavy case the range was measured on — a hard-bowed three-note
    /// chord, where the summed return is far larger than under one note. The
    /// output trim is pulled down so the safety limiter cannot mask growth.
    func testHeavyChordRingStillDecaysAtTheTop() throws {
        try skipUnlessSlowTestsEnabled()
        let r = try makeRig(["bow_live_trim": 5e-5])
        r.e.setJtCouple(1.0)
        r.mapper.setAxis(expr: 1.0, press: 100.0 / 127.0)
        render(r, seconds: 1.0)
        r.mapper.touchOn(1, pitchSemis: 64, velocity: 110.0 / 127.0)   // Sa
        r.mapper.touchOn(2, pitchSemis: 71, velocity: 110.0 / 127.0)   // Pa
        r.mapper.touchOn(3, pitchSemis: 76, velocity: 110.0 / 127.0)   // Sa'
        render(r, seconds: 1.0)
        r.mapper.touchOff(1)
        r.mapper.touchOff(2)
        r.mapper.touchOff(3)
        let ring = render(r, seconds: 4.0)
        let early = Self.peak(ring[Int(0.5 * r.sr)..<Int(1.0 * r.sr)])
        let late = Self.peak(ring[Int(3.5 * r.sr)..<Int(4.0 * r.sr)])
        XCTAssertTrue(late.isFinite && early.isFinite, "the loop diverged")
        XCTAssertLessThan(Self.db(late) - Self.db(early), -12.0,
                          "the heavy-case ring is not decaying")
    }
}
