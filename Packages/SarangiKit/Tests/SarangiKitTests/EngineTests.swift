import XCTest
@testable import SarangiKit

/// End-to-end engine sanity for the v57 PASSIVE coupled network (causal ports →
/// behaviour/stability; Python bit-parity is covered by DSPParityTests +
/// CoupledParityTests). Engines are armed with the bundled fitted artifacts
/// (`sarangi_coupled.json` + the Pilu preset) — the same configuration the app
/// ships.
final class EngineTests: XCTestCase {
    let sr = 44100.0

    /// All FX stages disabled — for exact-passthrough / parity assertions.
    var allFXOff: FXRack {
        var r = FXRack.makeDefault()
        r.violinPre.enabled = false; r.global.enabled = false
        return r
    }

    func makeEngine(fx: FXRack = .makeDefault(), coupled: CoupledConfig? = Presets.coupledConfig(),
                    _ mutate: (inout SarangiParams) -> Void = { _ in }) -> SarangiEngine {
        let state = Presets.state(.sarangiPilu)
        var p = state.params
        mutate(&p)
        return SarangiEngine(params: p, strings: state.resolvedStrings,
                             tonic: state.tonicHz, sr: sr,
                             eqBands: state.resolvedEQ, coupled: coupled,
                             fx: fx, groups: state.resolvedGroups)
    }

    func tone(_ f: Double, _ n: Int, amp: Double = 0.2) -> [Double] {
        (0..<n).map { amp * sin(2 * Double.pi * f * Double($0) / sr) }
    }

    /// The bundled coupled artifact must arm the passive junction — without it
    /// the engine is silent by design.
    func testBundledArtifactArms() throws {
        let cfg = try XCTUnwrap(Presets.coupledConfig(), "sarangi_coupled.json missing from bundle")
        XCTAssertTrue(cfg.passive, "bundled artifact must be N_junction \"passive\"")
        XCTAssertFalse(cfg.rfirTaps(sr: 44100).isEmpty, "44.1 kHz radiation FIR missing")
        XCTAssertFalse(cfg.rfirTaps(sr: 48000).isEmpty, "48 kHz radiation FIR missing")
        XCTAssertTrue(makeEngine().isArmed)
    }

    /// No coupled artifact ⇒ unarmed ⇒ silence (the host surfaces a config error).
    func testUnarmedIsSilent() {
        let e = makeEngine(coupled: nil)
        XCTAssertFalse(e.isArmed)
        e.beginBuffer()
        for v in tone(220, 500) {
            let (l, r) = e.renderSample(v)
            XCTAssertEqual(l, 0); XCTAssertEqual(r, 0)
        }
    }

    /// The Pilu preset loads the EXACT offline string table (39 rows), tagged
    /// into the four Starpad choirs positionally, with the fitted gains.
    func testPiluPresetLoads() {
        let s = Presets.state(.sarangiPilu)
        XCTAssertEqual(s.ragaName, "Pilu")
        XCTAssertEqual(s.tonicHz, 328.9, accuracy: 1e-9)
        XCTAssertEqual(s.strings.count, 39, "exact fitted table, not a regenerated bank")
        XCTAssertEqual(s.strings.filter { $0.group == .chromatic }.count, 15)
        XCTAssertEqual(s.strings.filter { $0.group == .scale }.count, 11)
        XCTAssertEqual(s.strings.filter { $0.group == .lowOctave }.count, 7)
        XCTAssertEqual(s.strings.filter { $0.group == .upperOctave }.count, 6)
        XCTAssertEqual(s.params.gin, 2.6, accuracy: 1e-9)
        XCTAssertEqual(s.params.gout, 0.45, accuracy: 1e-9)
        XCTAssertEqual(s.params["N_taraf_dir"], 0.02, accuracy: 1e-9)
        XCTAssertTrue(s.resolvedEQ.isEmpty, "output EQ seeds flat (v57 law)")
    }

    /// The taraf web rings: energy persists after the excitation stops.
    func testBankRings() {
        let e = makeEngine(fx: allFXOff)
        e.beginBuffer()
        for v in tone(328.9, Int(0.3 * sr)) { _ = e.renderSample(v) }
        var tailEnergy = 0.0
        let tailStart = Int(0.05 * sr)
        for n in 0..<Int(0.4 * sr) {
            let (l, _) = e.renderSample(0)
            if n > tailStart { tailEnergy += l * l }
        }
        XCTAssertGreaterThan(tailEnergy, 1e-8, "taraf web should ring after excitation stops")
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

    /// Disabled FX stages leave the render bit-identical to the default rack,
    /// whatever settings they carry — toggling a stage off IS the upstream chain.
    func testDisabledFXIsExactPassthrough() {
        var weird = allFXOff
        weird.violinPre.filterCutoff = 100; weird.violinPre.reverbMix = 0.9
        weird.global.filterCutoff = 200; weird.global.reverbMix = 0.9
        let a = makeEngine(fx: .makeDefault())
        let b = makeEngine(fx: weird)
        a.beginBuffer(); b.beginBuffer()
        for v in tone(261, 4000, amp: 0.3) {
            let (la, ra) = a.renderSample(v)
            let (lb, rb) = b.renderSample(v)
            XCTAssertEqual(la, lb); XCTAssertEqual(ra, rb)
        }
    }

    /// The pre-drive stage sits IN FRONT of the network: a steep low-pass on it
    /// starves the bridge of excitation, so the output carries far less energy
    /// than with the pre-drive OFF.
    func testPreDriveShapesExcitation() {
        func energy(preFX: VoiceFXParams) -> Double {
            var fx = allFXOff
            fx.violinPre = preFX
            let e = makeEngine(fx: fx)
            e.beginBuffer()
            var acc = 0.0
            for v in tone(328.9, Int(0.3 * sr), amp: 0.5) {
                let (l, _) = e.renderSample(v)
                acc += l * l
            }
            return acc
        }
        let off = energy(preFX: .violinPreDefault())              // enabled=false ⇒ raw drive
        let lowpassed = energy(preFX: VoiceFXParams(enabled: true, reverbMix: 0, reverbWidth: 0,
            reverbRT60: 1, filterCutoff: 60, filterResonance: 0, eq: []))   // LP well below the tonic
        XCTAssertGreaterThan(off, 1e-8, "network should sound with the pre-drive OFF")
        XCTAssertLessThan(lowpassed, off * 0.5, "low-passing the pre-drive must starve the network")
    }

    /// Stereo width from the bank's per-string pans (B_spread) decorrelates L/R
    /// without changing the mono sum; spread=0 ⇒ exactly mono. (Low drive so the
    /// softClip backstop stays linear — clipping is per-channel and would break
    /// exact sum invariance.)
    func testStereoSpread() {
        func render(_ spread: Double) -> (diff: Double, sums: [Double], peak: Double) {
            let e = makeEngine(fx: allFXOff) { $0["B_spread"] = spread }
            e.beginBuffer()
            var diff = 0.0
            var peak = 0.0
            var sums: [Double] = []
            for v in tone(328.9, 6000, amp: 0.04) {
                let (l, r) = e.renderSample(v)
                diff += abs(l - r); sums.append(l + r)
                peak = max(peak, abs(l), abs(r))
            }
            return (diff, sums, peak)
        }
        let wide = render(0.9)
        XCTAssertLessThan(wide.peak, 0.9, "probe must stay below the softClip knee")
        XCTAssertGreaterThan(wide.diff, 1e-6, "spread>0 should make L≠R")
        let mono = render(0.0)
        XCTAssertEqual(mono.diff, 0, accuracy: 1e-12, "spread=0 should be mono")
        var sumErr = 0.0
        for i in wide.sums.indices { sumErr = max(sumErr, abs(wide.sums[i] - mono.sums[i])) }
        XCTAssertLessThan(sumErr, 1e-9, "mono sum must be spread-invariant")
    }

    /// Full model (fitted preset) on noise stays finite and bounded — the passive
    /// junction is structurally stable (denominator ≥ 1), no guard needed.
    func testStability() {
        let e = makeEngine()
        e.beginBuffer()
        var rng = SeededGaussian(seed: 1)
        var peak = 0.0
        for _ in 0..<Int(sr) {
            let (l, r) = e.renderSample(rng.normal(sigma: 0.2))
            XCTAssertTrue(l.isFinite && r.isFinite)
            peak = max(peak, abs(l), abs(r))
        }
        XCTAssertLessThan(peak, 50.0, "output should stay bounded")
    }

    /// Both FX stages enabled stays finite + bounded (no IIR blow-up).
    func testAllFXStable() {
        var fx = FXRack.makeDefault()
        fx.violinPre.enabled = true
        fx.global.enabled = true; fx.global.reverbMix = 0.4
        let e = makeEngine(fx: fx)
        e.beginBuffer()
        var rng = SeededGaussian(seed: 2)
        var peak = 0.0
        for _ in 0..<Int(sr) {
            let (l, r) = e.renderSample(rng.normal(sigma: 0.2))
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

    /// Full Harmonics-display path: render audio into the engine, then the bank
    /// snapshot + analyzer must produce columns for every (expanded) string plus
    /// the Played note, and harmonic cells once the web has been excited.
    func testBankSnapshotAndAnalyze() {
        let e = makeEngine(fx: allFXOff)
        e.beginBuffer()
        // Drive at the tonic (a tarab string sits there) so the web rings.
        for v in tone(328.9, 12000, amp: 0.4) { _ = e.renderSample(v) }
        var snap = e.bankRawSnapshot()
        XCTAssertEqual(snap.strings.count, e.bank.count)
        // Host stamps the played pitch (the engine doesn't track MIDI).
        snap.playedF0 = 328.9; snap.playedActive = true

        let a = BankAnalyzer.analyze(snap)
        XCTAssertEqual(a.columns.count, e.bank.count + 1, "Played + one column per string")
        if case .played = a.columns[0].kind {} else { XCTFail("Played column must lead") }
        XCTAssertFalse(a.cells.filter { $0.columnIndex != 0 }.isEmpty,
                       "an excited web should emit sympathetic harmonic cells")
        XCTAssertFalse(a.cells.filter { $0.columnIndex == 0 }.isEmpty,
                       "the played note should emit harmonics from the input ring")
        // Sympathetic columns are non-decreasing in (choir order, pitch).
        let sym = a.columns.dropFirst()
        for (p, q) in zip(sym, sym.dropFirst()) {
            XCTAssertLessThanOrEqual(p.kind.order, q.kind.order)
            if p.kind.order == q.kind.order { XCTAssertLessThanOrEqual(p.f0, q.f0 + 1e-6) }
        }
    }
}
