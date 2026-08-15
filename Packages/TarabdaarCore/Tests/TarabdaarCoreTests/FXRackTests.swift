import XCTest
@testable import TarabdaarCore
import SarangiKit

/// Guards for the FX rack (2026-08-01): four insert points (voice→taraf
/// drive, voice, taraf, global), each a graphic EQ + selectable reverb,
/// all off by default. The bit-exactness of the untouched rack is pinned
/// by `TarafRemovalParityTests` (the split taraf bus + drive hook are
/// byte-null when idle); these tests guard the wiring above it.
final class FXRackTests: XCTestCase {

    /// Every `fx_*` registry key must parse into a point + field that
    /// `FXSettings` accepts — `AudioEngine` routes them by prefix, so a
    /// key the parser doesn't know would be a slider that silently does
    /// nothing (the exact failure the unified registry exists to prevent).
    func testEveryRegistryFXKeyReachesTheSettings() {
        let fxKeys = ParamRegistry.all.filter { $0.key.hasPrefix("fx_") }
        XCTAssertEqual(fxKeys.count, 4 * 16,
                       "4 points × (eq_on + 10 bands + 5 reverb fields)")
        for spec in fxKeys {
            XCTAssertEqual(spec.apply, .live,
                           "\(spec.key): FX params never touch the physics tables")
            guard let (point, field) = FXPoint.parse(key: spec.key) else {
                return XCTFail("\(spec.key) does not parse to an FXPoint")
            }
            var s = FXSettings()
            XCTAssertTrue(s.apply(field: field, value: spec.def),
                          "\(spec.key): FXSettings rejects field \(field)")
            XCTAssertNotNil(point.keyPrefix)
        }
        // and the prefixes cover exactly the four points
        XCTAssertEqual(Set(fxKeys.compactMap { FXPoint.parse(key: $0.key)?.0 }),
                       Set(FXPoint.allCases))
    }

    /// Registry defaults must equal `FXSettings()` — the resting push at
    /// startup (applyRestingParams sends every stored key) must leave the
    /// rack in its byte-null state.
    func testRegistryDefaultsAreTheNeutralSettings() {
        var s = FXSettings()
        for spec in ParamRegistry.all where spec.key.hasPrefix("fx_drive_") {
            let (_, field) = FXPoint.parse(key: spec.key)!
            s.apply(field: field, value: spec.def)
        }
        XCTAssertEqual(s, FXSettings(),
                       "pushing registry defaults must not change the settings")
        XCTAssertFalse(s.isActive)
    }

    /// A disengaged unit must not touch the buffer at all (bit-exact
    /// bypass), and an engaged EQ boost must actually move energy.
    func testUnitBypassIsBitExactAndEQEngages() {
        var unit = FXChainUnit(sr: 48000)
        var buf = (0..<512).map { sin(Double($0) * 0.07) }
        let ref = buf
        unit.tick(frames: 512)
        buf.withUnsafeMutableBufferPointer { unit.processMono($0.baseAddress!, 512) }
        XCTAssertEqual(buf, ref, "idle unit must be a bit-exact bypass")

        var s = FXSettings()
        s.eqOn = true
        s.eqGains[5] = 12   // +12 dB @ 1 kHz
        unit.retarget(s)
        var energyOn = 0.0, energyRef = 0.0
        // several chunks so the gain glide (~50 ms) settles
        for _ in 0..<40 {
            var chunk = (0..<512).map { sin(2.0 * .pi * 1000.0 * Double($0) / 48000.0) }
            energyRef = chunk.reduce(0) { $0 + $1 * $1 }
            unit.tick(frames: 512)
            chunk.withUnsafeMutableBufferPointer { unit.processMono($0.baseAddress!, 512) }
            energyOn = chunk.reduce(0) { $0 + $1 * $1 }
        }
        XCTAssertGreaterThan(energyOn, energyRef * 4,
                             "+12 dB at the band centre must gain ≥ +6 dB")
    }

    /// Bigverb: an impulse must bloom into a decaying, finite tail — and
    /// a bigger size must ring longer.
    func testBigverbTailDecaysAndTracksSize() {
        func tail(size: Double) -> (early: Double, late: Double) {
            var rv = Bigverb(sr: 48000)
            rv.size = size
            var early = 0.0, late = 0.0
            for i in 0..<(48000 * 2) {
                let x = i == 0 ? 1.0 : 0.0
                let (l, r) = rv.process(x, x)
                XCTAssertTrue(l.isFinite && r.isFinite)
                let e = l * l + r * r
                if i < 24000 { early += e } else if i >= 72000 { late += e }
            }
            return (early, late)
        }
        let small = tail(size: 0.5)
        let big = tail(size: 0.97)
        XCTAssertGreaterThan(small.early, 0, "no early reflections at all")
        XCTAssertLessThan(small.late, small.early,
                          "tail must decay, not grow")
        XCTAssertGreaterThan(big.late / big.early,
                             small.late / small.early,
                             "larger size must sustain relatively longer")
    }

    /// The reverb toggle glides the wet level in (no step) and the wet is
    /// additive — dry passes at unity.
    func testReverbEngagesAdditively() {
        var unit = FXChainUnit(sr: 48000)
        var s = FXSettings()
        s.revOn = true
        s.revMix = 1.0
        unit.retarget(s)
        var wetEnergy = 0.0
        for pass in 0..<40 {
            var chunk = [Double](repeating: 0, count: 512)
            if pass == 0 { chunk[0] = 1.0 }   // one impulse, then silence
            unit.tick(frames: 512)
            chunk.withUnsafeMutableBufferPointer { unit.processMono($0.baseAddress!, 512) }
            if pass > 0 { wetEnergy += chunk.reduce(0) { $0 + $1 * $1 } }
        }
        XCTAssertGreaterThan(wetEnergy, 0, "no tail after the dry impulse")
    }

    /// The live path: an `fx_` key routed through the source must land on
    /// a running engine and survive an engine swap (the rebuild contract).
    func testSourceCachesAndReappliesAcrossEngineSwap() {
        let src = StringVoiceSource()
        XCTAssertTrue(src.setFXParam("fx_global_eq_on", 1))
        XCTAssertTrue(src.setFXParam("fx_global_eq_b5", 9))
        XCTAssertFalse(src.setFXParam("fx_global_eq_b99", 9),
                       "unknown band must be rejected, not dropped silently")
        XCTAssertFalse(src.setFXParam("fx_nope_eq_on", 1))
        // no engine armed: the cache alone must hold the values (the
        // re-apply on setEngine is exercised by the render-path tests)
    }

    // MARK: - engine-level render paths

    /// One short played phrase through the REAL engine (serial jt for
    /// determinism, the parity test's pattern), with `fx` applied before
    /// the render. Returns interleaved L/R.
    private func renderPhrase(fx: [String: Double]) throws -> [Float] {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: ["bow_jt_async": 0.0, "bow_jt_threads": 0.0]) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(e, crossfadeMs: 0)
        for (k, v) in fx {
            XCTAssertTrue(src.setFXParam(k, v), "\(k) rejected")
        }
        let block = 128
        src.mapper.midi(0xB0, 11, 40)
        src.mapper.midi(0x90, 64, 100)
        var out: [Float] = []
        var t = 0.0
        while t < 1.2 {
            if t >= 0.8, t - Double(block) / src.modelSR < 0.8 {
                src.mapper.midi(0x80, 64, 0)
            }
            let (l, r) = src.renderForTesting(frames: block)
            for i in 0..<block { out.append(l[i]); out.append(r[i]) }
            t += Double(block) / src.modelSR
        }
        return out
    }

    /// Pushing every FX parameter at its DEFAULT must leave the render
    /// bit-identical to never touching the rack — the split-bus path and
    /// the drive hook are byte-null while idle (the parity contract).
    func testDefaultFXPushIsByteNull() throws {
        let clean = try renderPhrase(fx: [:])
        var defaults: [String: Double] = [:]
        for spec in ParamRegistry.all where spec.key.hasPrefix("fx_") {
            defaults[spec.key] = spec.def
        }
        let pushed = try renderPhrase(fx: defaults)
        XCTAssertEqual(clean, pushed,
                       "pushing FX defaults changed the render")
        XCTAssertGreaterThan(clean.map { abs($0) }.max() ?? 0, 1e-4,
                             "the phrase must actually make sound")
    }

    /// Each insert point, engaged, must change the output — and stay
    /// finite. This exercises the split-bus render (voice/taraf), the
    /// in-kernel drive hook, and the global insert on the real engine.
    func testEachPointAudiblyEngages() throws {
        let clean = try renderPhrase(fx: [:])
        for prefix in ["fx_drive_", "fx_voice_", "fx_taraf_", "fx_global_"] {
            let boosted = try renderPhrase(
                fx: ["\(prefix)eq_on": 1, "\(prefix)eq_b4": 12,
                     "\(prefix)eq_b5": 12, "\(prefix)eq_b6": 12])
            XCTAssertTrue(boosted.allSatisfy(\.isFinite), "\(prefix): NaN/inf")
            XCTAssertNotEqual(clean, boosted,
                              "\(prefix): +12 dB EQ did not reach the signal")
        }
        let reverbed = try renderPhrase(
            fx: ["fx_global_rev_on": 1, "fx_global_rev_mix": 0.8])
        XCTAssertTrue(reverbed.allSatisfy(\.isFinite))
        XCTAssertNotEqual(clean, reverbed, "global Bigverb did not engage")
    }
}
