import XCTest
@testable import SarangiKit

/// End-to-end engine sanity (causal ports → check behaviour/stability rather than
/// Python bit-parity, which the deterministic blocks cover in DSPParityTests).
final class EngineTests: XCTestCase {
    let sr = 48000.0

    /// All FX stages disabled — for exact-passthrough / parity assertions.
    var allFXOff: FXRack {
        var r = FXRack.makeDefault()
        r.violin.enabled = false; r.sym.enabled = false; r.global.enabled = false
        return r
    }

    func makeEngine(fx: FXRack = .makeDefault(), _ mutate: (inout SarangiParams) -> Void = { _ in }) -> SarangiEngine {
        var p = SarangiParams.defaults
        mutate(&p)
        let strings = RagaTuning.buildStrings(tonic: 293.66, intervals: [0, 1, 4, 5, 7, 8, 11])
        return SarangiEngine(params: p, strings: strings, tonic: 293.66, sr: sr, fx: fx)
    }

    func tone(_ f: Double, _ n: Int, amp: Double = 0.2) -> [Double] {
        (0..<n).map { amp * sin(2 * Double.pi * f * Double($0) / sr) }
    }

    /// Dry branch only + all FX off ⇒ the engine passes the violin through exactly.
    func testDryPassthrough() {
        let e = makeEngine(fx: allFXOff) {
            $0["mix_dry"] = 1; $0["mix_bank"] = 0; $0["mix_jaw"] = 0
            $0["main_gain"] = 1                      // unity → exact dry passthrough
            $0["E_body"] = 0; $0["E_low_shelf_db"] = 0
        }
        e.beginBuffer()
        let x = tone(220, 2000)
        var maxErr = 0.0
        for v in x { let (l, r) = e.renderSample(v, amp: 0.5); maxErr = max(maxErr, abs(l - v), abs(r - v)) }
        XCTAssertLessThan(maxErr, 1e-9)
    }

    /// A disabled VoiceFX stage is an exact passthrough (mono → both channels).
    func testVoiceFXBypass() {
        let p = VoiceFXParams(enabled: false, reverbMix: 0.5, reverbWidth: 0.5, reverbRT60: 1.2,
                              filterCutoff: 4000, filterResonance: 0.5, eq: VoiceFXParams.flatEQ)
        var fx = VoiceFX(p, sr: sr)
        var maxErr = 0.0
        for v in tone(330, 1000, amp: 0.5) {
            let (l, r) = fx.process(v)
            maxErr = max(maxErr, abs(l - v), abs(r - v))
        }
        XCTAssertEqual(maxErr, 0, "disabled VoiceFX must be an exact passthrough")
    }

    /// The sympathetic bank rings: energy persists after the excitation stops.
    func testBankRings() {
        let e = makeEngine(fx: allFXOff) {
            $0["mix_dry"] = 0; $0["mix_bank"] = 1; $0["mix_jaw"] = 0
            $0["E_body"] = 0; $0["E_low_shelf_db"] = 0
            $0["B_gain"] = 1.0
        }
        e.beginBuffer()
        var tailEnergy = 0.0
        let exc = tone(293.66, Int(0.2 * sr))
        for v in exc { _ = e.renderSample(v, amp: 1.0) }
        let tailStart = Int(0.05 * sr)
        for n in 0..<Int(0.3 * sr) {
            let (l, _) = e.renderSample(0, amp: 0.0)
            if n > tailStart { tailEnergy += l * l }
        }
        XCTAssertGreaterThan(tailEnergy, 1e-6, "bank should ring after excitation stops")
    }

    /// Violin reverb width decorrelates L/R; width=0 ⇒ mono.
    func testStereoWidth() {
        var wideFX = FXRack.makeDefault(); wideFX.violin.reverbMix = 0.3; wideFX.violin.reverbWidth = 0.6
        wideFX.sym.enabled = false; wideFX.global.enabled = false
        let wide = makeEngine(fx: wideFX)
        wide.beginBuffer()
        var diff = 0.0
        for v in tone(330, 4000) { let (l, r) = wide.renderSample(v, amp: 0.6); diff += abs(l - r) }
        XCTAssertGreaterThan(diff, 1e-3, "width>0 should make L≠R")

        var monoFX = FXRack.makeDefault(); monoFX.violin.reverbMix = 0.3; monoFX.violin.reverbWidth = 0
        monoFX.sym.enabled = false; monoFX.global.enabled = false
        let mono = makeEngine(fx: monoFX)
        mono.beginBuffer()
        var monoDiff = 0.0
        for v in tone(330, 4000) { let (l, r) = mono.renderSample(v, amp: 0.6); monoDiff += abs(l - r) }
        XCTAssertEqual(monoDiff, 0, accuracy: 1e-9, "width=0 should be mono")
    }

    /// Full model (defaults) on noise stays finite and bounded.
    func testStability() {
        let e = makeEngine()
        e.beginBuffer()
        var rng = SeededGaussian(seed: 1)
        var peak = 0.0
        for _ in 0..<Int(sr) {
            let (l, r) = e.renderSample(rng.normal(sigma: 0.2), amp: 0.7)
            XCTAssertTrue(l.isFinite && r.isFinite)
            peak = max(peak, abs(l), abs(r))
        }
        XCTAssertLessThan(peak, 50.0, "output should stay bounded")
    }

    /// All three FX stages enabled stays finite + bounded (no IIR blow-up).
    func testAllFXStable() {
        var fx = FXRack.makeDefault()
        fx.sym.enabled = true; fx.global.enabled = true; fx.global.reverbMix = 0.4
        let e = makeEngine(fx: fx)
        e.beginBuffer()
        var rng = SeededGaussian(seed: 2)
        var peak = 0.0
        for _ in 0..<Int(sr) {
            let (l, r) = e.renderSample(rng.normal(sigma: 0.2), amp: 0.7)
            XCTAssertTrue(l.isFinite && r.isFinite)
            peak = max(peak, abs(l), abs(r))
        }
        XCTAssertLessThan(peak, 50.0, "output should stay bounded with all FX on")
    }

    func testBankCount() {
        let strings = RagaTuning.buildStrings(tonic: 293.66, intervals: [0, 1, 4, 5, 7, 8, 11])
        XCTAssertGreaterThanOrEqual(strings.count, 30)
        XCTAssertLessThanOrEqual(strings.count, 37)
    }
}
