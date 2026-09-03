import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Shared render harness for the parity-phrase suites
/// (TarafRemovalParityTests, BusMeterTests, TarafCapTests): ONE parity
/// phrase, ONE deterministic build, and — the point (2026-08-31) —
/// CACHED neutral baselines. CAUTION: the phrase and build here feed
/// the PARITY HASH (`TarafRemovalParityTests`) — any edit to the
/// events, expression, block size or length fails the pinned SHA-256
/// loudly. That is deliberate: one phrase, one truth. Every suite used
/// to re-render the identical untouched phrase per test at ~11 s a
/// render (the deterministic serial-jt path runs ~4–5× slower than
/// realtime; that is physics, not debug overhead — `-c release`
/// measured identical). The neutral renders are deterministic by
/// construction (serial jt is the parity rule), so computing each once
/// per process is exact, not approximate.
enum BusPhrase {
    /// Serial jt (the parity tests' rule): the async pool drops drive
    /// blocks under load, so only the serial path repeats exactly.
    static let deterministic: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
    ]

    /// The parity phrase: two overlapping notes with a release tail, so
    /// the voice bus, the jt bus and the room all carry signal. The
    /// meter is integrate-and-dump, so two readings come back: `mid` =
    /// the exact RMS of everything up to 0.9 s (both notes sounding),
    /// `tail` = 0.9 s → end (releases + the sympathetic ring).
    struct Reading {
        let out: [Float]
        let mid: (voice: Double, taraf: Double)
        let tail: (voice: Double, taraf: Double)
    }

    /// Uncached render. `configure` runs after the engine is published —
    /// the place to arm the balance / comp / cap setters. `overrides`
    /// exists for TarafRemovalParityTests' reference-capture mode (the
    /// pre-removal worktree silences the web at build); every normal
    /// caller keeps the deterministic default.
    static func render(meter: Bool,
                       overrides: [String: Double] = deterministic,
                       configure: (StringVoiceSource) -> Void = { _ in })
        throws -> Reading {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: overrides) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setBusMeter(meter)
        src.setEngine(e, crossfadeMs: 0)
        configure(src)
        let sr = src.modelSR
        let block = 128
        src.mapper.midi(0xB0, 11, 40)
        var out: [Float] = []
        var t = 0.0
        let events: [(Double, UInt8, UInt8, UInt8)] = [
            (0.05, 0x90, 64, 100),
            (0.60, 0x91, 71, 90),
            (1.10, 0x80, 64, 0),
            (1.50, 0x81, 71, 0),
        ]
        var next = 0
        var mid: (voice: Double, taraf: Double) = (0, 0)
        var midTaken = false
        while t < 2.5 {
            while next < events.count, events[next].0 <= t {
                let e = events[next]
                src.mapper.midi(e.1, e.2, e.3)
                next += 1
            }
            let (l, r) = src.renderForTesting(frames: block)
            for i in 0..<block { out.append(l[i]); out.append(r[i]) }
            t += Double(block) / sr
            if !midTaken, t >= 0.9 {
                mid = src.busLevels()      // dump: RMS of 0 … 0.9 s
                midTaken = true
            }
        }
        return Reading(out: out, mid: mid, tail: src.busLevels())
    }

    // The cached baselines — rendered at most once per test process.
    // nil = the artifact is missing from the bundle; callers throw
    // XCTSkip via neutral(metered:).
    private static let neutralMetered: Reading? = try? render(meter: true)
    private static let neutralUnmetered: Reading? = try? render(meter: false)

    /// The untouched phrase (no setters pushed), cached.
    static func neutral(metered: Bool) throws -> Reading {
        guard let r = metered ? neutralMetered : neutralUnmetered else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        return r
    }
}
