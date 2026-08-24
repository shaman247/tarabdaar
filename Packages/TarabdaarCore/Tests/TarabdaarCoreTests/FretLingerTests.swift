import XCTest
import SarangiKit
@testable import TarabdaarCore

/// FRET LINGER + Y-DEPTH AUTO-VIBRATO (2026-08-18). The fret as a control
/// surface: a touch that LINGERS without moving decays its expression and
/// grows a vibrato whose ceiling is set by its OUTWARD within-fret y —
/// fretY 0 = the home fret's end toward the pad's centre-line (the dead
/// zone starts there, `bow_avib_dead` of the fret's length), 1 = its
/// outer end (full); VERTICAL movement recharges expression and returns
/// the note to its no-vibrato state. All of it lives in BowControlFilter and
/// engages ONLY for touches that report a fret-band y — which is the
/// contract the first test pins: a y-less touch (keyboard, scripts, the
/// MIDI path) renders bit-identically whatever the linger parameters say,
/// so `TarafRemovalParityTests` and the audition pipeline are untouched.
final class FretLingerTests: XCTestCase {

    private func strings() -> [ResolvedString] {
        Presets.state(.sarangiPilu).resolvedStrings
    }

    private func makeSource(overrides: [String: Double] = [:]) -> StringVoiceSource? {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings(), mapper: src.mapper,
            overrides: overrides) else { return nil }
        src.setEngine(e, crossfadeMs: 0)
        return src
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

    private func rms(_ x: ArraySlice<Double>) -> Double {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 }
                         / Double(x.count)).squareRoot()
    }

    /// A touch WITHOUT a fret-band y must render bit-identically no matter
    /// how the linger parameters are set — the whole feature keys off the
    /// reported y, so every legacy producer stays on the untouched path.
    func testYLessTouchIsBitIdenticalUnderLingerOverrides() throws {
        func render(_ overrides: [String: Double]) -> [Double] {
            guard let src = makeSource(overrides: overrides) else { return [] }
            src.mapper.setAxis(expr: 0.5)
            src.mapper.touchOn(1, pitchSemis: 60.0, velocity: 0.8)
            return pull(src, 8)
        }
        let base = render([:])
        let armed = render(["bow_linger_decay": 0.3, "bow_linger_floor": 0.0,
                            "bow_avib_cents": 60.0, "bow_avib_grow": 0.3,
                            "bow_avib_dead": 0.0])
        guard !base.isEmpty, base.count == armed.count else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        var maxDiff = 0.0
        for i in 0..<base.count { maxDiff = max(maxDiff, abs(base[i] - armed[i])) }
        XCTAssertEqual(maxDiff, 0.0,
                       "linger params leaked into a y-less touch")
    }

    /// Lingering at the band centre (no vibrato confound) decays the note;
    /// stroking the finger vertically along the fret recharges it.
    func testLingerDecaysAndVerticalMotionRecharges() throws {
        let overrides: [String: Double] = ["bow_linger_decay": 0.5,
                                           "bow_linger_floor": 0.0,
                                           "bow_avib_cents": 0.0]
        func render(wiggleLastBlocks: Int) -> (early: Double, late: Double) {
            guard let src = makeSource(overrides: overrides) else {
                return (0, 0)
            }
            src.mapper.setAxis(expr: 0.5)
            src.mapper.touchOn(1, pitchSemis: 60.0, velocity: 0.8, posY: 0.5)
            _ = pull(src, 4)                       // settle into the stroke
            let early = rms(pull(src, 2).suffix(4096))
            let hold = 34
            for b in 0..<hold {
                if b >= hold - wiggleLastBlocks {
                    // ~93 ms per block; alternating 0.3↔0.7 ≈ 4 band/s —
                    // far above the 0.35 band/s full-drive reference.
                    src.mapper.touchGlide(1, pitchSemis: 60.0,
                                          posY: b % 2 == 0 ? 0.3 : 0.7)
                }
                _ = pull(src, 1)
            }
            let late = rms(pull(src, 1).suffix(4096))
            return (early, late)
        }
        let still = render(wiggleLastBlocks: 0)
        guard still.early > 0 else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // ~3.3 s of stillness against a 0.5 s decay: the note must have
        // eased far down.
        XCTAssertLessThan(still.late, 0.5 * still.early,
                          "lingering did not decay the expression")
        // The same timeline with a vertical stroke over the last ~1 s must
        // come back up — well above where the still note ended.
        let stroked = render(wiggleLastBlocks: 10)
        XCTAssertGreaterThan(stroked.late, 2.0 * still.late,
                             "vertical movement did not recharge the note")
        XCTAssertGreaterThan(stroked.late, 0.4 * stroked.early,
                             "recharge fell short of the base expression")
    }

    /// The auto-vibrato ceiling is FRET-relative and OUTWARD (v5, dead
    /// zone rev 2026-08-20): a touch inside its home fret's inner dead
    /// zone (fretY below `bow_avib_dead`) renders without it, the same
    /// touch near the fret's OUTER end grows it — the two renders
    /// (identical in every other way) must diverge once the depth blooms.
    /// A touch with NO home fret (unsnapped onset: posY but no fretY)
    /// gets none either, even at the band edge.
    func testAutoVibratoDependsOnFretY() throws {
        let overrides: [String: Double] = ["bow_linger_decay": 0.0,
                                           "bow_avib_cents": 40.0,
                                           "bow_avib_grow": 0.5,
                                           "bow_avib_dead": 0.7]
        func render(fretY: Double?) -> [Double] {
            guard let src = makeSource(overrides: overrides) else { return [] }
            src.mapper.setAxis(expr: 0.5)
            // Band y far off-centre on purpose: the ceiling must NOT read
            // from it any more.
            src.mapper.touchOn(1, pitchSemis: 60.0, velocity: 0.8,
                               posY: 0.95, fretY: fretY)
            return pull(src, 12)
        }
        let inner = render(fretY: 0.5)      // inside the 70% dead zone
        let outer = render(fretY: 0.95)     // near the fret's outer end
        let fretless = render(fretY: nil)
        guard !inner.isEmpty, inner.count == outer.count else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // The inner touch sits inside the dead zone: its ceiling is 0, so
        // the two control streams are identical until the outer touch's
        // depth blooms — then the pitch modulation must separate the tails.
        let tailDiff = zip(inner.suffix(8192), outer.suffix(8192))
            .map { abs($0 - $1) }.max() ?? 0
        let level = rms(outer.suffix(8192))
        XCTAssertGreaterThan(tailDiff, 0.1 * level,
                             "outer-end touch grew no audible vibrato")
        // No home fret = no ceiling, identical to the dead-zone render
        // (both evolve depth toward 0) — despite the band-edge posY.
        var fretlessDiff = 0.0
        for i in 0..<inner.count {
            fretlessDiff = max(fretlessDiff, abs(inner[i] - fretless[i]))
        }
        XCTAssertEqual(fretlessDiff, 0.0,
                       "an unsnapped touch grew vibrato from its band y")
    }

    /// The engine exports the evaluated envelopes for the iPad's overlay:
    /// after an outer-end touch rings a while, the display feed carries
    /// the touch's wire id with a bloomed vibrato depth under its ceiling
    /// and a charge that has started to fall.
    func testLingerDisplayExport() throws {
        let overrides: [String: Double] = ["bow_linger_decay": 2.0,
                                           "bow_avib_cents": 40.0,
                                           "bow_avib_grow": 0.3,
                                           "bow_avib_dead": 0.7]
        guard let src = makeSource(overrides: overrides) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.mapper.setAxis(expr: 0.5)
        src.mapper.touchOn(42, pitchSemis: 60.0, velocity: 0.8,
                           posY: 0.5, fretY: 0.9)
        _ = pull(src, 12)                          // ~1.1 s of stillness
        guard let engine = src.currentEngine() else {
            return XCTFail("no engine")
        }
        let entries = engine.lingerDisplay()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, 42)
        let e = entries[0]
        XCTAssertGreaterThan(e.vibCeil, 0.5, "fret-edge ceiling missing")
        XCTAssertGreaterThan(e.vib, 0.3, "depth never bloomed")
        XCTAssertLessThanOrEqual(e.vib, e.vibCeil + 0.01)
        XCTAssertLessThan(e.charge, 0.9, "charge never decayed")
        XCTAssertGreaterThan(e.charge, 0.2, "charge fell implausibly fast")
    }
}
