import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Shared render harness for the parity phrase: ONE phrase, ONE deterministic
/// build, cached baselines. CAUTION: the events, expression, block size and
/// length here feed the PARITY HASH (`TarafRemovalParityTests`) — any edit
/// fails the pinned SHA-256 loudly. That is deliberate: one phrase, one truth.
enum BusPhrase {
    /// Serial jt (the parity tests' rule): the async pool drops drive
    /// blocks under load, so only the serial path repeats exactly.
    static let deterministic: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
    ]

    /// The parity phrase's output plus, when metered, the integrate-and-dump
    /// bus RMS up to 0.9 s (`mid`) and from there to the end (`tail`).
    struct Reading {
        let out: [Float]
        let mid: (voice: Double, taraf: Double)
        let tail: (voice: Double, taraf: Double)
    }

    /// Uncached render. `configure` runs after the engine is published;
    /// `overrides` exists for the reference-capture mode.
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
        src.mapper.setAxis(expr: 40.0 / 127.0)
        var out: [Float] = []
        var t = 0.0
        /// `(at, id, pitch?)` — a non-nil pitch is a touch-on,
        /// nil is the release of that id.
        let events: [(Double, UInt16, Double?)] = [
            (0.05, 1, 64.0),
            (0.60, 2, 71.0),
            (1.10, 1, nil),
            (1.50, 2, nil),
        ]
        var next = 0
        var mid: (voice: Double, taraf: Double) = (0, 0)
        var midTaken = false
        while t < 2.5 {
            while next < events.count, events[next].0 <= t {
                let e = events[next]
                if let pitch = e.2 {
                    src.mapper.touchOn(e.1, pitchSemis: pitch)
                } else {
                    src.mapper.touchOff(e.1)
                }
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
