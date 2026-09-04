import XCTest
import SarangiKit
@testable import TarabdaarCore

/// TWO-WAY BRIDGE COUPLING (`bow_jt_couple`): the guard that the loop
/// closes without ringing forever.
///
/// The knob's first cut had two leaks, both audible as "the instrument
/// never gets completely silent — it sounds like repeated low-level
/// strumming":
///
/// 1. the return took each row's UN-DC-blocked bridge load, which carries
///    the row's static wrap preload as a constant term, so a resting web
///    parked a DC force on the played strings' bridge and then drove
///    itself with it;
/// 2. a row the quiescence gate put to sleep dropped out of the sum, so
///    the returned force STEPPED to zero — a step on the shared bridge
///    strums the played strings and every other row, which wakes the
///    sleeper: a limit cycle the gate itself sustained.
///
/// Fixed at the cause (DC-blocked pickup; a sleeping row FADES its last
/// value out on the DC blocker's own rate). These tests pin the outcome:
/// a resting web returns nothing, a coupled ring goes fully silent with
/// every row asleep, and the top of the knob's range still decays under
/// the heavy case the range was measured on.
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

    /// A RESTING web must return nothing. Measured with the quiescence gate
    /// DISARMED (the raw-physics escape hatch), so no row can sleep and the
    /// return is the web's own standing state: the un-blocked pickup pushed
    /// the rows' static wrap preload back onto the bridge and self-excited
    /// the whole web from silence (tail RMS 2.6e-1 — a web nobody played).
    /// DC-blocked it is 5.7e-3, all of it the contact micro limit-cycle the
    /// wrap keeps alive, and the DC offset is gone (mean 1.3e-5 → 1.0e-6).
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

    /// A coupled ring must END. At the TOP of the range a 12 s ring after a
    /// bowed Sa falls the same way the uncoupled one does (−87 dBFS at 7 s,
    /// then the gate closes and it truncates), with every row asleep. The
    /// gate-step bug held this at a low strumming floor instead.
    func testCoupledRingGoesFullySilent() throws {
        try skipUnlessSlowTestsEnabled()
        let r = try makeRig()
        r.e.setJtCouple(1.0)
        r.mapper.midi(0xB0, 11, 32)
        r.mapper.midi(0xB0, 1, 71)
        render(r, seconds: 1.0)                 // settle
        r.mapper.midi(0x90, 64, 100)
        render(r, seconds: 0.6)
        r.mapper.midi(0x80, 64, 0)
        let ring = render(r, seconds: 12.0)
        let tail = ring[Int(11.5 * r.sr)...]
        XCTAssertLessThan(Self.db(Self.peak(tail)), -80.0,
                          "the coupled ring never goes silent")
        let probe = r.e.jtGateProbe()
        XCTAssertEqual(r.e.jtGateAsleep(), probe.total,
                       "rows are still awake after a 12 s ring")
    }

    /// The knob's full scale is HALF the measured divergence gain, and the
    /// gain was measured on the HEAVY case — a hard-bowed three-note chord,
    /// where the summed return is far larger than under one note. The
    /// output trim is pulled 60 dB so the safety limiter cannot mask growth.
    func testHeavyChordRingStillDecaysAtTheTop() throws {
        try skipUnlessSlowTestsEnabled()
        let r = try makeRig(["bow_live_trim": 5e-5])
        r.e.setJtCouple(1.0)
        r.mapper.midi(0xB0, 11, 127)
        r.mapper.midi(0xB0, 1, 100)
        render(r, seconds: 1.0)
        r.mapper.midi(0x90, 64, 110)            // Sa
        r.mapper.midi(0x91, 71, 110)            // Pa
        r.mapper.midi(0x92, 76, 110)            // Sa'
        render(r, seconds: 1.0)
        r.mapper.midi(0x80, 64, 0)
        r.mapper.midi(0x81, 71, 0)
        r.mapper.midi(0x82, 76, 0)
        let ring = render(r, seconds: 4.0)
        let early = Self.peak(ring[Int(0.5 * r.sr)..<Int(1.0 * r.sr)])
        let late = Self.peak(ring[Int(3.5 * r.sr)..<Int(4.0 * r.sr)])
        XCTAssertTrue(late.isFinite && early.isFinite, "the loop diverged")
        XCTAssertLessThan(Self.db(late) - Self.db(early), -12.0,
                          "the heavy-case ring is not decaying")
    }
}
