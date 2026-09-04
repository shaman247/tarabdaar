import XCTest
import CryptoKit
import SarangiKit
@testable import TarabdaarCore

/// RENDER PARITY: the SHA-256 of one rendered phrase pins the whole shipped
/// String-voice signal path — kernel, table builders, taraf, levels. Any
/// unblessed change to the sound fails here; bless it on purpose or fix it.
final class TarafRemovalParityTests: XCTestCase {
    override func setUpWithError() throws { try skipUnlessSlowTestsEnabled() }

    private static var writing: Bool {
        ProcessInfo.processInfo.environment["TARABDAAR_TARAF_REF"] == "write"
    }

    /// The shipped jawari block runs async on a worker pool and drops drive
    /// blocks under load, so only the serial jt path repeats sample for sample.
    private static let deterministic: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
    ]

    /// Reference capture only: the pre-removal worktree silences the web.
    private static var referenceOverrides: [String: Double] {
        var o = deterministic
        if writing {
            o["bow_taraf_Z"] = 0.0
            o["bow_open_Z"] = 0.0
        }
        return o
    }

    /// `<repo>/build/` — Tests/TarabdaarCoreTests → … → Packages → repo root.
    /// `TARABDAAR_TARAF_REF_PATH` overrides it, so a git worktree checked out
    /// at the pre-removal commit can write into the main repo's build dir.
    private static var refURL: URL {
        if let p = ProcessInfo.processInfo.environment["TARABDAAR_TARAF_REF_PATH"] {
            return URL(fileURLWithPath: p)
        }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("build/taraf_removal_ref.raw")
    }

    /// The phrase lives in `BusPhrase`: two overlapping notes with expression
    /// and a release tail, so string, body, jawari web and room all contribute.
    private func render() throws -> [Float] {
        if Self.writing {
            return try BusPhrase.render(
                meter: false, overrides: Self.referenceOverrides).out
        }
        return try BusPhrase.neutral(metered: false).out
    }

    /// The comparison is only meaningful if the render repeats exactly, so the
    /// one fresh render is checked against the cached baseline.
    func testSerialRenderIsReproducible() throws {
        let fresh = try BusPhrase.render(meter: false).out
        let cached = try BusPhrase.neutral(metered: false).out
        XCTAssertEqual(fresh, cached,
                       "the serial jt render is not deterministic — the "
                       + "parity comparison below (and every cached "
                       + "BusPhrase baseline) cannot mean anything")
    }
    /// The blessed render's SHA-256. Re-bless DELIBERATELY when the shipped
    /// sound changes (write mode: `TARABDAAR_TARAF_REF=write`) and say why in
    /// the commit.
    private static let referenceSHA256 =
        "9dc7c1cd3311cfee65cf4e1efc19d43984fd8780d900bbd6f3a71210a7f922d9"

    /// The shipped signal path still renders the blessed phrase.
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
