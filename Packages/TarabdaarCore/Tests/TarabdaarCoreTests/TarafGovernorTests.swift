import XCTest
import SarangiKit
@testable import TarabdaarCore

/// TARAF CHARGE GOVERNOR (`bow_jt_gov`, 2026-08-15).
///
/// The user report this parameterizes: some taraf notes randomly ring
/// very loudly with buzz — most commonly Pa and high Sa, after playing
/// or gliding through several other notes. Measured (TarafVarianceBench):
/// the long-t60 anchor rows accumulate a whole phrase (+8…+12 dB of
/// extra ring on the next kin note), re-excitation phases make it a
/// lottery, and at high expression the pile-up crosses the contact knee
/// into the loud-buzz regime. The governor sheds bridge drive into any
/// row already ringing above the graze band, per row, kernel-side.
///
/// Guards here:
///  - gov 0 (the default, and the startup resting push) is byte-null;
///  - a solo strike at the pads' resting expression is untouched at
///    gov 1 (the single-strike sound is the calibration anchor);
///  - the phrase pile-up on high Sa at hot expression is capped, both
///    via the build-time bp arming (`string.bow_jt_gov` route) and the
///    live setter path (registry → AudioEngine → source → engine).
final class TarafGovernorTests: XCTestCase {

    private let serial: [String: Double] = ["bow_jt_async": 0,
                                            "bow_jt_threads": 0]

    private func makeSource(_ overrides: [String: Double]) throws
        -> StringVoiceSource {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9,
            strings: Presets.state(.sarangiPilu).resolvedStrings,
            mapper: src.mapper, overrides: overrides)
        else { throw XCTSkip("bowed_string.json not available") }
        src.setEngine(e, crossfadeMs: 0)
        return src
    }

    private func pull(_ src: StringVoiceSource, seconds: Double) -> [Double] {
        var out: [Double] = []
        var left = Int(seconds * 48000.0)
        while left > 0 {
            let n = min(4096, left)
            let (l, r) = src.renderForTesting(frames: n)
            for i in 0..<n { out.append(Double(l[i]) + Double(r[i])) }
            left -= n
        }
        return out
    }

    private func rms(_ x: ArraySlice<Double>) -> Double {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                         / Double(x.count)).squareRoot()
    }

    private func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

    /// Phrase (Sa Re Ga ma) then the target strike; returns the
    /// target's post-release taraf ring RMS (0.8–2.0 s after lift).
    private func phraseRing(_ src: StringVoiceSource, cc: UInt8,
                            target: UInt8,
                            arm: ((StringVoiceSource) -> Void)? = nil)
        -> Double {
        src.mapper.midi(0xB0, 11, cc)
        _ = pull(src, seconds: 0.25)
        arm?(src)
        for n: UInt8 in [64, 66, 68, 69] {
            src.mapper.midi(0x90, n, 100)
            _ = pull(src, seconds: 0.45)
            src.mapper.midi(0x80, n, 0)
            _ = pull(src, seconds: 0.06)
        }
        _ = pull(src, seconds: 0.2)
        src.mapper.midi(0x90, target, 100)
        _ = pull(src, seconds: 0.8)
        src.mapper.midi(0x80, target, 0)
        _ = pull(src, seconds: 0.8)
        let tail = pull(src, seconds: 1.2)
        return rms(tail[...])
    }

    /// gov 0 must be byte-null: an explicit 0 override plus a live
    /// setter push of 0 renders bit-identically to the untouched build
    /// (serial jt is reproducible).
    func testGovZeroIsByteNull() throws {
        let a = try makeSource(serial)
        var ov = serial; ov["bow_jt_gov"] = 0.0
        let b = try makeSource(ov)
        b.setJtGov(0.0)      // the startup resting push
        for src in [a, b] {
            src.mapper.midi(0xB0, 11, 64)
            src.mapper.midi(0x90, 76, 100)
        }
        let xa = pull(a, seconds: 1.0)
        let xb = pull(b, seconds: 1.0)
        XCTAssertEqual(xa, xb, "bow_jt_gov 0 must be byte-null")
    }

    /// At gov 1 a solo kin strike at the resting expression (CC11 32)
    /// keeps its taraf ring — the governor only sheds ABOVE the graze
    /// band, and a single strike from silence should live below it.
    func testSoloStrikeSurvivesFullGovernor() throws {
        func soloRing(_ ov: [String: Double]) throws -> Double {
            let src = try makeSource(ov)
            src.mapper.midi(0xB0, 11, 32)
            _ = pull(src, seconds: 0.25)
            src.mapper.midi(0x90, 76, 100)
            _ = pull(src, seconds: 0.8)
            src.mapper.midi(0x80, 76, 0)
            _ = pull(src, seconds: 0.8)
            return rms(pull(src, seconds: 1.2)[...])
        }
        let off = try soloRing(serial)
        var ov = serial; ov["bow_jt_gov"] = 1.0
        let on = try soloRing(ov)
        XCTAssertGreaterThan(off, 0, "no taraf ring at all — bad rig")
        XCTAssertLessThan(abs(db(on) - db(off)), 2.0,
            "gov 1 must leave a resting-level solo strike essentially"
            + " untouched (calibrate bow_jt_gov_ref, not this test)")
    }

    /// The measured complaint: phrase → high Sa at hot expression piles
    /// up in the anchors. gov 1 must cap the ring — via the bp build
    /// arming AND via the live setter path.
    func testPhrasePileupIsCapped() throws {
        let off = try phraseRing(makeSource(serial), cc: 124, target: 76)
        var ov = serial; ov["bow_jt_gov"] = 1.0
        let armed = try phraseRing(makeSource(ov), cc: 124, target: 76)
        let live = try phraseRing(makeSource(serial), cc: 124, target: 76,
                                  arm: { $0.setJtGov(1.0) })
        XCTAssertGreaterThan(off, 0, "no ring at all — bad rig")
        XCTAssertLessThan(db(armed), db(off) - 3.0,
            "build-armed governor failed to cap the phrase pile-up")
        XCTAssertLessThan(db(live), db(off) - 3.0,
            "live-pushed governor failed to cap the phrase pile-up"
            + " (registry → source → engine path)")
    }
}
