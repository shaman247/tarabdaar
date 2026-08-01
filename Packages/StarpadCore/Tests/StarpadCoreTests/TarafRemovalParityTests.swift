import XCTest
import CryptoKit
import SarangiKit
@testable import StarpadCore

/// TARAF-WEB REMOVAL PARITY (2026-07-24). The linear sympathetic web was
/// deleted from the String voice; the modal-jawari block is the whole taraf
/// now. The removal is only legitimate if the shipped default reproduces —
/// sample for sample — what the old code produced with the web silenced
/// (`bow_taraf_Z` 0), which is the sound this change was adopted from.
///
/// The reference was captured from the PRE-removal build (commit 19fe7f4,
/// in a worktree) with the web silenced, and is pinned here as a SHA-256 of
/// the rendered samples. To reproduce it:
///
///     git worktree add /tmp/pre 19fe7f4 && cp this file into it
///     cd /tmp/pre/Packages/StarpadCore
///     STARPAD_TARAF_REF=write swift test -c release --filter TarafRemovalParity
///
/// which also drops the raw float32 samples in `<repo>/build/` (gitignored;
/// `STARPAD_TARAF_REF_PATH` overrides). If that file is present a failure
/// reports the worst differing sample; otherwise it reports the hash.
final class TarafRemovalParityTests: XCTestCase {

    private static var writing: Bool {
        ProcessInfo.processInfo.environment["STARPAD_TARAF_REF"] == "write"
    }

    /// The shipped jawari block runs ASYNC on a worker pool (`bow_jt_async`
    /// 1, `bow_jt_threads` 8): it is one block late and drops drive blocks
    /// under load, so a render is NOT reproducible sample-for-sample — that
    /// is a scheduling property, not a sound change. Both sides of this
    /// comparison therefore run the SERIAL jt path, which the kernel
    /// documents as bit-exact.
    private static let deterministic: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
    ]

    /// While capturing, the old build is silenced the way the user had it
    /// (coupling Z 0); afterwards there is no knob left to silence.
    private static var referenceOverrides: [String: Double] {
        var o = deterministic
        if writing {
            o["bow_taraf_Z"] = 0.0
            o["bow_open_Z"] = 0.0
        }
        return o
    }

    /// `<repo>/build/` — Tests/StarpadCoreTests → … → Packages → repo root.
    /// `STARPAD_TARAF_REF_PATH` overrides it, so a git worktree checked out
    /// at the pre-removal commit can write into the main repo's build dir.
    private static var refURL: URL {
        if let p = ProcessInfo.processInfo.environment["STARPAD_TARAF_REF_PATH"] {
            return URL(fileURLWithPath: p)
        }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("build/taraf_removal_ref.raw")
    }

    /// A short scripted phrase: two overlapping notes with expression and a
    /// release tail, so the string, the body, the jawari web and the room
    /// all contribute to the comparison.
    private func render() throws -> [Float] {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: Self.referenceOverrides) else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        src.setEngine(e, crossfadeMs: 0)
        let sr = src.modelSR
        let block = 128
        src.mapper.midi(0xB0, 11, 40)              // expression, as the pads do

        var out: [Float] = []
        var t = 0.0
        // (time, status, d1, d2)
        let events: [(Double, UInt8, UInt8, UInt8)] = [
            (0.05, 0x90, 64, 100),                 // note on
            (0.60, 0x91, 71, 90),                  // second voice
            (1.10, 0x80, 64, 0),
            (1.50, 0x81, 71, 0),
        ]
        var next = 0
        while t < 2.5 {
            while next < events.count, events[next].0 <= t {
                let e = events[next]
                src.mapper.midi(e.1, e.2, e.3)
                next += 1
            }
            let (l, r) = src.renderForTesting(frames: block)
            for i in 0..<block { out.append(l[i]); out.append(r[i]) }
            t += Double(block) / sr
        }
        return out
    }

    /// The comparison is only meaningful if the render repeats exactly.
    func testSerialRenderIsReproducible() throws {
        let a = try render(), b = try render()
        XCTAssertEqual(a, b, "the serial jt render is not deterministic — "
                       + "the parity comparison below cannot mean anything")
    }

    /// SHA-256 of the blessed reference render, 240128 float32 samples. The
    /// hash is the checked-in half of the guard: it cannot be re-blessed by
    /// re-running the capture on the current tree, which a raw-file golden
    /// would silently allow. The optional file only supplies diagnostics.
    ///
    /// RE-BLESSED 2026-08-01 (deliberately) for the COHERENCE rev
    /// (a17280cf3ba3d655fba14a675259696430235db2385c94e5e72cab7c6c484625):
    /// the generated bank's CROWD t60s shortened ~×0.6 (the three drone
    /// anchors keep their fitted ring — `RagaTuning.buildSpecs`), and the
    /// stereo seeds moved (`bow_st_spread` 0.7 → 0.2, `bow_rev_width`
    /// 0.6 → 0.8 — this render hashes BOTH channels, so the seed change
    /// is in the hash even though the mono fold-down is invariant). The
    /// new `bow_jt_body` path was verified byte-null at its 0 default
    /// before re-blessing.
    /// RE-BLESSED 2026-07-26 (deliberately) for the NO-DUPLICATES tarab
    /// pool: the generated bank folds the historic Sa/Pa doubling rows —
    /// exact-unison twins since the detune removal — into their strongest
    /// twin (24 → 19 rows for Pilu), so the default web rings those
    /// pitches once instead of twice.
    /// RE-BLESSED 2026-07-25 (deliberately) before that for the
    /// scale-defined tarab (f4c22c0cced56eec94a099bda552d03c0f710ba326
    /// 9b020bc577c14038580f7c): the default bank's pitches moved from the
    /// fitted per-string detunes onto the exact JI grid (the fitted table
    /// cannot be expressed as scale degrees, and was retired with the
    /// string-table law), and the settle pre-roll grew 4 → 5 blocks for
    /// the resulting unison chime. The chromatic-removal and web-removal
    /// steps before it were verified hash-identical under the ORIGINAL
    /// reference
    /// (eac0460aac9194bc899fd3c918278e139b1a474722eb7fe1014eb528417d923c,
    /// captured at commit 19fe7f4 with `bow_taraf_Z` 0 / `bow_open_Z` 0).
    private static let referenceSHA256 =
        "d3dac8159feb247bfcc5d5f26262640d230eaf1368b0ce844403e72d048fd759"

    func testDefaultMatchesTheSilencedWebReference() throws {
        let y = try render()
        XCTAssertGreaterThan(y.map { abs($0) }.max() ?? 0, 1e-4,
                             "the phrase must actually make sound")
        let bytes = y.withUnsafeBufferPointer { Data(buffer: $0) }

        if Self.writing {
            try FileManager.default.createDirectory(
                at: Self.refURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try bytes.write(to: Self.refURL)
            print("[taraf-ref] wrote \(y.count) floats to \(Self.refURL.path)")
            print("[taraf-ref] sha256 \(Self.sha256(bytes))")
            return
        }

        let got = Self.sha256(bytes)
        guard got != Self.referenceSHA256 else { return }

        // Mismatch: say WHERE, if the raw reference is around to say it.
        var detail = "hash \(got) != \(Self.referenceSHA256)"
        if let data = try? Data(contentsOf: Self.refURL) {
            let want = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            if want.count != y.count {
                detail = "render length \(y.count) != reference \(want.count)"
            } else {
                var worst = 0.0, worstIdx = -1
                for i in y.indices where abs(Double(y[i] - want[i])) > worst {
                    worst = abs(Double(y[i] - want[i]))
                    worstIdx = i
                }
                detail = "worst sample delta \(worst) at \(worstIdx) "
                    + "(want \(want[worstIdx]), got \(y[worstIdx]))"
            }
        }
        XCTFail("the String voice no longer reproduces the pre-removal "
                + "web-silenced sound: \(detail)")
    }

    private static func sha256(_ d: Data) -> String {
        var h = SHA256()
        h.update(data: d)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
