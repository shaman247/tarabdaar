import XCTest
@testable import SarangiKit

/// The graphical EQ draws its curve from `Biquad.forBand(...).magnitude(...)`, the
/// SAME design the engine runs — so "picture == sound" hinges on these helpers.
/// Also covers the variable-band live update + tolerant decode of old EQ data.
final class VoiceFXTests: XCTestCase {
    let sr = 44100.0

    /// A peaking band's magnitude at its centre frequency is exactly its gain (dB).
    func testPeakingMagnitudeAtCenterEqualsGain() {
        for g in [-12.0, -3, 0, 6, 15] {
            let bq = Biquad.peaking(f0: 1000, gainDB: g, q: 1.2, sr: sr)
            let dB = 20 * log10(bq.magnitude(atHz: 1000, sr: sr))
            XCTAssertEqual(dB, g, accuracy: 1e-6, "peaking gain at f0 (g=\(g))")
        }
    }

    /// `forBand(.peaking)` is identical to `Biquad.peaking` (the curve uses one,
    /// the engine the other — they must match coefficient-for-coefficient).
    func testForBandPeakingMatchesPeaking() {
        let band = EQBand(freq: 800, gainDB: 4, q: 2, type: .peaking)
        let a = Biquad.forBand(band, sr: sr)
        let b = Biquad.peaking(f0: 800, gainDB: 4, q: 2, sr: sr)
        XCTAssertEqual(a.b0, b.b0, accuracy: 1e-12); XCTAssertEqual(a.b1, b.b1, accuracy: 1e-12)
        XCTAssertEqual(a.b2, b.b2, accuracy: 1e-12); XCTAssertEqual(a.a1, b.a1, accuracy: 1e-12)
        XCTAssertEqual(a.a2, b.a2, accuracy: 1e-12)
    }

    /// Each band type produces a sane, finite response (no NaN at the edges).
    func testAllBandTypesFiniteAcrossSpectrum() {
        for t in EQBandType.allCases {
            let bq = Biquad.forBand(EQBand(freq: 2000, gainDB: 6, q: 1, type: t), sr: sr)
            for f in [20.0, 200, 2000, 20000] {
                XCTAssertTrue(bq.magnitude(atHz: f, sr: sr).isFinite, "\(t) at \(f) Hz")
            }
        }
    }

    /// An empty EQ is an exact passthrough; disabled bands are skipped.
    func testChainCountSkipsDisabled() {
        XCTAssertTrue(VoiceFX.makeEQChain([], sr: sr).sections.isEmpty)
        let bands = [EQBand(freq: 100, gainDB: 1, q: 1),
                     EQBand(freq: 500, gainDB: 1, q: 1, enabled: false),
                     EQBand(freq: 4000, gainDB: 1, q: 1)]
        XCTAssertEqual(VoiceFX.makeEQChain(bands, sr: sr).sections.count, 2)
    }

    /// `updateFilters` tracks a band-count change (add then remove) in place.
    func testUpdateFiltersBandCountChange() {
        var p = VoiceFXParams.globalDefault()
        p.eq = [EQBand(freq: 1000, gainDB: 0, q: 1)]
        var fx = VoiceFX(p, sr: sr)
        XCTAssertEqual(fx.eq.sections.count, 1)
        p.eq = VoiceFXParams.flatEQ                  // 3 bands
        fx.updateFilters(p, sr: sr)
        XCTAssertEqual(fx.eq.sections.count, 3)
        p.eq = []                                    // back to none
        fx.updateFilters(p, sr: sr)
        XCTAssertTrue(fx.eq.sections.isEmpty)
    }

    /// Pre-graphical-EQ JSON (only freq/gainDB/q) still decodes — as enabled
    /// `.peaking` bands — so old persisted / `.sarangi` state keeps working.
    func testTolerantDecodeOfLegacyBand() throws {
        let json = #"{"freq":250,"gainDB":3.5,"q":1.0}"#.data(using: .utf8)!
        let band = try JSONDecoder().decode(EQBand.self, from: json)
        XCTAssertEqual(band.freq, 250); XCTAssertEqual(band.gainDB, 3.5, accuracy: 1e-9)
        XCTAssertEqual(band.type, .peaking)
        XCTAssertTrue(band.enabled)
    }

    /// FX-rack JSON with a missing stage still decodes — absent stages default
    /// OFF and the saved stages are preserved (old 4-stage documents also load:
    /// their retired violin/sym keys are simply ignored).
    func testFXRackTolerantDecodeMissingStage() throws {
        var rack = FXRack.makeDefault()
        rack.global.reverbMix = 0.42        // a distinctive saved value
        // Encode, then strip the violinPre key to simulate a partial document.
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rack)) as! [String: Any]
        obj.removeValue(forKey: "violinPre")
        obj["violin"] = ["enabled": true]   // retired 4-stage key — must be ignored
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(FXRack.self, from: stripped)
        XCTAssertFalse(back.violinPre.enabled, "missing violinPre defaults OFF")
        XCTAssertEqual(back.global.reverbMix, 0.42, accuracy: 1e-9, "saved global preserved")
    }

    /// A full new band round-trips through Codable (id/type/enabled preserved).
    func testNewBandRoundTrips() throws {
        let band = EQBand(freq: 3000, gainDB: -6, q: 0.8, type: .highShelf, enabled: false)
        let data = try JSONEncoder().encode(band)
        let back = try JSONDecoder().decode(EQBand.self, from: data)
        XCTAssertEqual(band, back)
    }

    /// The live coefficient swap actually reaches the audio: boosting a band by
    /// +12 dB via `updateFilters` on a running stage raises the output ~4× at that
    /// frequency, proving the `setEQBand → applySarangiFXFilters` path works
    /// without a rebuild (this is what makes dragging click-free).
    func testUpdateFiltersChangesOutputLevel() {
        var p = VoiceFXParams(enabled: true, reverbMix: 0, reverbWidth: 0, reverbRT60: 1,
                              filterCutoff: 18000, filterResonance: 0, eq: [])
        var fx = VoiceFX(p, sr: sr)
        let f = 1000.0
        func rms(after: Int) -> Double {
            var acc = 0.0, count = 0
            for n in 0..<after {
                let x = 0.5 * sin(2 * .pi * f * Double(n) / sr)
                let (l, _) = fx.process(x)
                if n >= after - 4096 { acc += l * l; count += 1 }
            }
            return (acc / Double(count)).squareRoot()
        }
        let flat = rms(after: 16384)
        p.eq = [EQBand(freq: f, gainDB: 12, q: 1.0)]
        fx.updateFilters(p, sr: sr)             // live swap on the running stage
        let boosted = rms(after: 16384)
        let ratio = boosted / max(flat, 1e-12)
        XCTAssertGreaterThan(ratio, 3.0, "‖ +12 dB peak should ≈ 4× the level (got \(ratio))")
        XCTAssertLessThan(ratio, 5.0)
    }
}
