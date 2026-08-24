import XCTest
import SarangiKit
@testable import TarabdaarCore

/// TARAF QUIESCENCE GATE (`bow_jt_gate`, 2026-08-17 — ALWAYS ON).
///
/// The jawari taraf is a constant-cost simulation — every row ticks its
/// whole mode stack whether ringing or silent, so the idle app burned the
/// full web cost (measured: ~350% CPU across the jt workers with nothing
/// playing). The gate freezes rows whose LOW-MODE ring has rested below a
/// sub-audible floor for ~30 ms with no bridge/drone drive, and wakes
/// them on the first drive that could ring them back up. (Low modes are
/// the meter — the static wrap's high-mode micro limit-cycle never
/// rests, so zone velocity / raw radiated level cannot gate.)
///
/// This is NOT a user parameter: it is baked on at 40 dB below the graze
/// apex via the `bow_jt_gate` bp scalar; a 0 override is the bit-exact
/// raw-physics escape hatch for parity work. 40 (not the original 60)
/// because a PRESSED resting bone (`bow_jt_evolve` toward 0) sustains a
/// steady low-mode limit cycle above the 60 dB floor (stock rig ×3.34,
/// hot-gain rig ×6.6 — sub-audible, but it held the whole web awake at
/// idle). The 2026-08-17 `TarafRemovalParityTests` re-bless carries the
/// 40 dB floor (the quietest rows sleep in its opening silence).
///
/// Guards here:
///  - the DEFAULT build sleeps at idle and wakes on a strike;
///  - the 0 override really disarms (no row ever sleeps);
///  - a strike from sleep keeps the ungated taraf ring (state is
///    frozen, not zeroed — no re-settle strum, no missing sympathetic
///    response on the first note of a phrase).
final class TarafGateTests: XCTestCase {

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

    /// Solo strike; returns the post-release taraf ring RMS.
    private func soloRing(_ src: StringVoiceSource) -> Double {
        src.mapper.midi(0xB0, 11, 32)
        _ = pull(src, seconds: 0.25)
        src.mapper.midi(0x90, 76, 100)
        _ = pull(src, seconds: 0.8)
        src.mapper.midi(0x80, 76, 0)
        _ = pull(src, seconds: 0.8)
        return rms(pull(src, seconds: 1.2)[...])
    }

    /// The shipped default (no override) must sleep the idle web and
    /// wake it on a strike.
    func testDefaultSleepsAtIdleAndWakesOnStrike() throws {
        let src = try makeSource(serial)
        _ = pull(src, seconds: 2.0)
        let asleep = src.jtGateAsleep()
        XCTAssertGreaterThan(asleep, 0,
            "the baked default gate slept no jt row after 2 s of silence")
        src.mapper.midi(0xB0, 11, 64)
        src.mapper.midi(0x90, 76, 100)
        _ = pull(src, seconds: 0.3)
        XCTAssertLessThan(src.jtGateAsleep(), asleep,
            "a strike must wake sleeping rows")
        src.mapper.midi(0x80, 76, 0)
    }

    /// `bow_jt_gate` 0 is the bit-exact escape hatch: no row may ever
    /// sleep under it.
    func testZeroOverrideDisarms() throws {
        var ov = serial; ov["bow_jt_gate"] = 0.0
        let src = try makeSource(ov)
        _ = pull(src, seconds: 3.0)
        XCTAssertEqual(src.jtGateAsleep(), 0,
            "the 0 override must keep the gate fully disarmed")
    }

    /// A live tilt/stick binding streams `bow_jt_evolve` at sensor rate
    /// even at rest, and every applied change MOVES THE BONE — which
    /// mechanically pumps the resting rows' low modes above the gate
    /// floor (measured 2026-08-17: a Joy-Con stick-Y → evolve binding
    /// kept all 19 rows awake at idle, restoring the full ~350% burn).
    /// Guard: resting-stick jitter must not hold the web awake
    /// (BowEngine's cumulative dead-band + the kernel's change-gated
    /// wake), while a material move must still wake it (a row sleeping
    /// through a real bone glide would meet the moved bone as a step).
    func testEvolveJitterSpamDoesNotHoldWebAwake() throws {
        let src = try makeSource(serial)
        var i = 0
        var left = Int(2.5 * 48000)
        while left > 0 {
            let n = min(1024, left)
            _ = src.renderForTesting(frames: n)
            left -= n
            i += 1
            src.setJtEvolve(0.5 + 0.004 * sin(Double(i)))  // resting-stick jitter
        }
        let asleep = src.jtGateAsleep()
        XCTAssertGreaterThan(asleep, 0,
            "evolve jitter spam held the whole web awake")
        src.setJtEvolve(0.95)                    // material bone move
        _ = src.renderForTesting(frames: 480)    // 10 ms — under the hold window
        XCTAssertLessThan(src.jtGateAsleep(), asleep,
            "a material evolve move must wake the web")
    }

    /// The taraf ring of a strike FROM SLEEP (the shipped default) must
    /// match the ungated strike — the frozen rows wake with their static
    /// wrap intact and full sympathetic response.
    func testWokenRingMatchesUngated() throws {
        var ov = serial; ov["bow_jt_gate"] = 0.0
        let off = try makeSource(ov)
        _ = pull(off, seconds: 2.0)
        let offRing = soloRing(off)

        let on = try makeSource(serial)
        _ = pull(on, seconds: 2.0)              // let the web fall asleep
        XCTAssertGreaterThan(on.jtGateAsleep(), 0,
            "rows never slept — the wake comparison would test nothing")
        let onRing = soloRing(on)

        XCTAssertGreaterThan(offRing, 0, "no taraf ring at all — bad rig")
        XCTAssertLessThan(abs(db(onRing) - db(offRing)), 2.0,
            "a strike from sleep must keep the ungated taraf ring")
    }
}
