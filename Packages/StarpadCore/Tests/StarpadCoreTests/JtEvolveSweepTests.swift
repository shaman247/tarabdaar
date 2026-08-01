import XCTest
import SarangiKit
@testable import StarpadCore

/// HARMONIC-EVOLUTION guards (2026-07-26). `bow_jt_evolve` is the ONE
/// sanctioned runtime bone move — a kernel-slewed signed lift (~40 ms).
/// The guard: sweeping it full-throw under a ringing taraf must not
/// strum (the failure mode of every stepped bone move, and the reason
/// v1's stage-3 table-reload implementation clicked under a tilt).
final class JtEvolveSweepTests: XCTestCase {

    private static var outDir: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("build/twang")
    }

    private static let base: [String: Double] = [
        "bow_jt_async": 0.0, "bow_jt_threads": 0.0,
        "bow_drone_spread": 0.0,
    ]

    private func makeSource(_ overrides: [String: Double]) throws
        -> (StringVoiceSource, BowEngine, Int) {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        var o = Self.base
        for (k, v) in overrides { o[k] = v }
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: o) else {
            throw XCTSkip("bowed_string.json not available")
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 32)
        guard let row = e.droneRow(forExactHz: 328.9) else {
            throw XCTSkip("no Sa row")
        }
        return (src, e, row)
    }

    private func render(_ overrides: [String: Double]) throws -> [Float] {
        let (src, e, row) = try makeSource(overrides)
        var y: [Float] = []
        let block = 128
        var t = 0.0
        var pressed = false, released = false
        while t < 6.0 {
            if !pressed, t >= 0.2 { e.dronePress(row: row); pressed = true }
            if !released, t >= 0.7 { e.droneRelease(row: row); released = true }
            let (l, _) = src.renderForTesting(frames: block)
            y.append(contentsOf: l[0..<block])
            t += Double(block) / 48000.0
        }
        return y
    }

    /// The live evolve axis must be sweepable under a ringing taraf
    /// without strum clicks: the kernel slews the bone (~40 ms), so a
    /// full-throw tilt sweep may not add broadband transients beyond
    /// what the static ring already carries.
    func testEvolveSweepIsClickFree() throws {
        func run(sweep: Bool) throws -> [Float] {
            let (src, e, row) = try makeSource([:])
            var y: [Float] = []
            let block = 128
            var t = 0.0
            var pressed = false
            while t < 4.0 {
                if !pressed, t >= 0.2 { e.dronePress(row: row); pressed = true }
                if sweep, t >= 1.0 {
                    // full-throw triangle sweep, ~0.5 Hz, updated per block
                    let ph = (t - 1.0) * 0.5
                    let tri = abs(2.0 * (ph - (ph + 0.5).rounded(.down)))
                    e.setJtEvolve(tri)
                }
                let (l, _) = src.renderForTesting(frames: block)
                y.append(contentsOf: l[0..<block])
                t += Double(block) / 48000.0
            }
            return y
        }
        let swept = try run(sweep: true)
        let still = try run(sweep: false)
        XCTAssertTrue(swept.allSatisfy(\.isFinite))
        // per-10ms max sample-to-sample step in the swept window
        func maxStep(_ y: [Float], from: Double, to: Double) -> Double {
            let a = Int(from * 48000), b = min(y.count, Int(to * 48000))
            var m = 0.0
            for i in (a + 1)..<b {
                m = max(m, abs(Double(y[i]) - Double(y[i - 1])))
            }
            return m
        }
        let sweptStep = maxStep(swept, from: 1.0, to: 4.0)
        let stillStep = maxStep(still, from: 1.0, to: 4.0)
        print(String(format: "[sweep] max step swept %.5f still %.5f",
                     sweptStep, stillStep))
        XCTAssertLessThan(sweptStep, stillStep * 3.0 + 1e-4,
            "evolve sweep adds transient steps — the bone is not gliding")
        let data = swept.withUnsafeBufferPointer { Data(buffer: $0) }
        try? FileManager.default.createDirectory(
            at: Self.outDir, withIntermediateDirectories: true)
        try? data.write(to: Self.outDir.appendingPathComponent("sweep.raw"))
    }
}
