import XCTest
import SarangiKit
@testable import StarpadCore

/// Mellow-drone rev guards (2026-07-26): a drone tap must be audible,
/// sit in the calibrated level band, and ring FUNDAMENTAL-dominated —
/// the pitched (sine-at-mode-1) drive. The first rev's pure-noise drive
/// rang the row's high modes far above their played-note balance
/// (measured ring H4 ≈ H1 vs the played tap's H4 −29 dB — the reported
/// "harsh, sharp" drones), so H1 dominance is the character pin.
final class DroneExcitationTests: XCTestCase {

    func testDroneTapRingsFundamentalDominated() throws {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: ["bow_jt_async": 0.0, "bow_jt_threads": 0.0]) else {
            throw XCTSkip("bowed_string.json not available")
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 32)
        guard let row = e.droneRow(forExactHz: 328.9) else {
            XCTFail("no Sa row in the jt web"); return
        }
        var y: [Float] = []
        let block = 128
        var t = 0.0
        var pressed = false, released = false
        while t < 4.0 {
            if !pressed, t >= 0.2 { e.dronePress(row: row); pressed = true }
            if !released, t >= 0.5 { e.droneRelease(row: row); released = true }
            let (l, _) = src.renderForTesting(frames: block)
            y.append(contentsOf: l[0..<block])
            t += Double(block) / 48000.0
        }
        XCTAssertTrue(y.allSatisfy(\.isFinite))
        // Free-ring window well after the drive has decayed.
        func band(_ hz: Double) -> Double {
            stride(from: -40.0, through: 40.0, by: 4.0).map { c -> Double in
                let f = hz * pow(2.0, c / 1200.0)
                let a = Int(1.7 * 48000), b = min(y.count, Int(2.7 * 48000))
                let w = 2.0 * Double.pi * f / 48000.0
                let cc = 2.0 * cos(w)
                var s1 = 0.0, s2 = 0.0
                for i in a..<b {
                    let s0 = Double(y[i]) + cc * s1 - s2
                    s2 = s1; s1 = s0
                }
                let n = Double(b - a)
                return (s1 * s1 + s2 * s2 - cc * s1 * s2) / (n * n)
            }.max() ?? 0
        }
        var acc = 0.0
        let a = Int(1.7 * 48000), b = min(y.count, Int(2.7 * 48000))
        for i in a..<b { acc += Double(y[i]) * Double(y[i]) }
        let rms = (acc / Double(b - a)).squareRoot()
        let h1 = band(328.9), h4 = band(4 * 328.9)
        print(String(format: "drone ring rms %.5f h1/h4 %.1f dB",
                     rms, 10.0 * log10(h1 / max(h4, 1e-30))))
        // Calibrated band (level 0.026, the 2026-07-27 loudness-parity
        // round: a drone tap = a fret tap): ~0.012 at the default tarab.
        XCTAssertGreaterThan(rms, 2e-3, "drone tap must be audible")
        XCTAssertLessThan(rms, 5e-2, "drone tap far above calibration")
        XCTAssertGreaterThan(h1, h4 * 10.0,
            "ring must be fundamental-dominated (pitched drive) — "
            + "H4 within 10 dB of H1 is the harsh noise-drive signature")
    }
}
