import XCTest
import SarangiKit
@testable import StarpadCore

/// The MELODY-FOLLOWER sympathetic string (2026-07-25): one jt row that
/// live-retunes to the highest played pitch (`bow_poly_jt_track_*`).
/// These tests pin the two things that make it real:
///   1. it RETUNES — after a note tap the row's own ring (drone-excited,
///      so the played string's tail can't mask it) sits at the tapped
///      pitch, and moves when a different note is tapped;
///   2. it stays BOUNDED under abuse — jumping the melody across octaves
///      for seconds neither blows up nor NaNs (the retune rewrites live
///      modal coefficients in place; this guards that).
/// The byte-null half (follower off = the exact shipped render) is what
/// `TarafRemovalParityTests` already proves, since the default is off.
///
/// Measurement note: a jt row's SYMPATHETIC pickup from a held note is
/// deliberately not asserted — with a 6 s t60 the resonance is ~2 cents
/// wide while the grazing bone shifts the ring pitch by row-dependent
/// cents (the known +15 c drone-era property), so tonal pickup level is
/// a sound-design quantity, not a mechanism guarantee. The drone drive
/// is broadband and excites the row wherever it is tuned.
final class FollowerStringTests: XCTestCase {

    /// Serial jt path — deterministic and pool-free.
    private static let overrides: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
    ]

    /// Build the voice with ALL tarab rows disabled, so the jawari web is
    /// exactly the follower row (row 0).
    private func makeSource() throws -> (StringVoiceSource, BowEngine) {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
            .map { ResolvedString(freq: $0.freq, gain: $0.gain,
                                  t60: $0.t60, enabled: false) }
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: Self.overrides,
            follower: (gain: 1.0, t60: 6.0)) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 40)
        return (src, e)
    }

    private func run(_ src: StringVoiceSource, seconds: Double,
                     into out: inout [Float],
                     events: [(Double, () -> Void)]) {
        let block = 128
        var t = 0.0
        var next = 0
        let sorted = events.sorted { $0.0 < $1.0 }
        while t < seconds {
            while next < sorted.count, sorted[next].0 <= t {
                sorted[next].1()
                next += 1
            }
            let (l, _) = src.renderForTesting(frames: block)
            out.append(contentsOf: l[0..<block])
            t += Double(block) / 48000.0
        }
    }

    /// Single-bin spectral energy (Goertzel), normalized per sample².
    private func energy(_ x: [Float], from: Double, to: Double,
                        hz: Double) -> Double {
        let a = max(0, Int(from * 48000)), b = min(x.count, Int(to * 48000))
        guard b > a + 16 else { return 0 }
        let w = 2.0 * Double.pi * hz / 48000.0
        let c = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b {
            let s0 = Double(x[i]) + c * s1 - s2
            s2 = s1; s1 = s0
        }
        let n = Double(b - a)
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n)
    }

    /// Peak band energy within ±40 c of `hz` (the grazing bone shifts a
    /// row's ring by row-dependent cents; the scan absorbs that).
    private func bandPeak(_ x: [Float], from: Double, to: Double,
                          around hz: Double) -> Double {
        stride(from: -40.0, through: 40.0, by: 5.0).map {
            energy(x, from: from, to: to, hz: hz * pow(2.0, $0 / 1200.0))
        }.max() ?? 0
    }

    func testFollowerRetunesToEachPlayedPitch() throws {
        let (src, e) = try makeSource()
        let fA = 440.0 * pow(2.0, (64.0 - 69.0) / 12.0)   // E4 ≈ 329.6 Hz
        let fB = 440.0 * pow(2.0, (70.0 - 69.0) / 12.0)   // B♭4 ≈ 466.2 Hz
        // (a tritone apart — neither pitch is a low-order harmonic of the
        // other, so the fundamental bands discriminate cleanly)
        var y: [Float] = []
        // Tap note A (retunes the row), let the played tail die, then
        // drone-excite the row and measure ITS ring; repeat with note B.
        run(src, seconds: 9.0, into: &y, events: [
            (0.05, { src.mapper.midi(0x90, 64, 100) }),
            (0.35, { src.mapper.midi(0x80, 64, 0) }),
            (1.80, { e.dronePress(row: 0) }),
            (2.30, { e.droneRelease(row: 0) }),
            (4.50, { src.mapper.midi(0x90, 70, 100) }),
            (4.80, { src.mapper.midi(0x80, 70, 0) }),
            (6.30, { e.dronePress(row: 0) }),
            (6.80, { e.droneRelease(row: 0) }),
        ])
        XCTAssertTrue(y.allSatisfy(\.isFinite))
        let aRingA = bandPeak(y, from: 2.6, to: 3.2, around: fA)
        let aRingB = bandPeak(y, from: 2.6, to: 3.2, around: fB)
        let bRingB = bandPeak(y, from: 7.1, to: 7.7, around: fB)
        let bRingA = bandPeak(y, from: 7.1, to: 7.7, around: fA)
        print(String(format: "follower ring after A: @A %.3e @B %.3e · "
                     + "after B: @B %.3e @A %.3e",
                     aRingA, aRingB, bRingB, bRingA))
        XCTAssertGreaterThan(aRingA, 1e-11, "the follower must ring at all")
        XCTAssertGreaterThan(bRingB, 1e-11, "the follower must ring at all")
        // The row's ring lives at the LAST played pitch, both directions.
        XCTAssertGreaterThan(aRingA, 8.0 * aRingB,
            "after note A the follower does not ring at A")
        XCTAssertGreaterThan(bRingB, 8.0 * bRingA,
            "after note B the follower does not ring at B — no retune")
    }

    func testOctaveJumpAbuseStaysBounded() throws {
        let (src, _) = try makeSource()
        // Alternate E3 ↔ E6 every 150 ms for 3 s — every jump swings the
        // active mode count ~4× — then let it ring out.
        var events: [(Double, () -> Void)] = []
        var t = 0.05
        var high = false
        while t < 3.0 {
            let n: UInt8 = high ? 88 : 52
            let at = t
            events.append((at, { src.mapper.midi(0x90, n, 100) }))
            events.append((at + 0.14, { src.mapper.midi(0x80, n, 0) }))
            t += 0.15
            high.toggle()
        }
        var y: [Float] = []
        run(src, seconds: 4.0, into: &y, events: events)
        XCTAssertTrue(y.allSatisfy(\.isFinite), "retune produced NaN/inf")
        let peak = y.map { abs($0) }.max() ?? 0
        print(String(format: "follower abuse peak %.4f", peak))
        XCTAssertGreaterThan(peak, 1e-4, "the phrase must make sound")
        XCTAssertLessThan(peak, 1.5, "retune abuse blew up the web")
    }
}
