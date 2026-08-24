import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Sitar→taraf inject guards (2026-08-19): a foreign voice's block
/// written into the kernel's inject ring must charge the modal-jawari
/// web (the sitar's sympathetic halo), and the zero/empty path must
/// stay silent (the byte-exact half is `TarafRemovalParityTests`;
/// this pins audibility and the gain=0 kill).
final class TarafInjectTests: XCTestCase {

    private func ringRMS(inject: Bool, gain: Double) throws -> Double {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9, strings: strings, mapper: src.mapper,
            overrides: ["bow_jt_async": 0.0, "bow_jt_threads": 0.0]) else {
            throw XCTSkip("bowed_string.json not available")
        }
        src.setEngine(e, crossfadeMs: 0)
        src.mapper.midi(0xB0, 11, 32)
        src.setJtInjectGain(gain)
        // a sitar-like drive: Sa an octave up (kin to the web's rows),
        // at the sitar voice's typical output level, for 0.6 s
        let block = 128
        var mono = [Double](repeating: 0, count: block)
        var y: [Float] = []
        var t = 0.0
        var phase = 0.0
        let w = 2.0 * Double.pi * 657.8 / 48000.0
        while t < 3.0 {
            if inject, t < 0.6 {
                for i in 0..<block {
                    phase += w
                    mono[i] = 0.05 * sin(phase)
                }
                mono.withUnsafeBufferPointer {
                    src.jtInjectWrite($0.baseAddress!, block)
                }
            }
            let (l, _) = src.renderForTesting(frames: block)
            y.append(contentsOf: l[0..<block])
            t += Double(block) / 48000.0
        }
        XCTAssertTrue(y.allSatisfy(\.isFinite))
        // measure while the web is charged and the drive still runs
        let a = Int(0.3 * 48000), b = Int(0.9 * 48000)
        var acc = 0.0
        for i in a..<b { acc += Double(y[i]) * Double(y[i]) }
        return (acc / Double(b - a)).squareRoot()
    }

    func testInjectedDriveRingsTheWeb() throws {
        let rung = try ringRMS(inject: true, gain: 1.0)
        let silent = try ringRMS(inject: false, gain: 1.0)
        print(String(format: "taraf inject ring rms %.6f vs silent %.6f",
                     rung, silent))
        XCTAssertGreaterThan(rung, 1e-5, "injected drive did not ring the web")
        XCTAssertGreaterThan(rung, 20 * max(silent, 1e-9),
                             "injected ring not clearly above the idle floor")
    }

    func testZeroGainKillsTheInject() throws {
        let killed = try ringRMS(inject: true, gain: 0.0)
        let silent = try ringRMS(inject: false, gain: 0.0)
        XCTAssertEqual(killed, silent, accuracy: 1e-9,
                       "gain 0 must be a dead inject (byte-null contract)")
    }

    /// Per-source inject pre-gain (2026-08-21): `st_taraf`/`tp_taraf`
    /// scale at each voice's tap so the sitar and the tanpura share the
    /// one kernel ring independently. The tap must write the mono
    /// mixdown scaled EXACTLY by the gain, and write nothing at 0.
    func testInjectPreGainScalesTheTap() throws {
        guard let p = Presets.tanpuraParams() else {
            throw XCTSkip("tanpura_live.json not available")
        }
        func tapped(gain: Double) -> [Double] {
            let src = TanpuraVoiceSource()
            var got: [Double] = []
            src.setInjectSink { x, n in
                got.append(contentsOf: UnsafeBufferPointer(start: x, count: n))
            }
            src.setInjectGain(gain)
            // tiny grid, sync workers: deterministic + fast to mount
            src.setEngine(TanpuraEngine(params: p, frequencies: [220.0],
                                        workers: 1), crossfadeMs: 0)
            src.currentEngine()?.pluck(slot: 0, velocity: 100, scale: 1.0)
            _ = src.renderForTesting(frames: 2048)
            return got
        }
        let unit = tapped(gain: 1.0)
        let twice = tapped(gain: 2.0)
        let dead = tapped(gain: 0.0)
        XCTAssertTrue(dead.isEmpty, "gain 0 must skip the tap entirely")
        XCTAssertEqual(unit.count, 2048)
        XCTAssertGreaterThan(unit.map(abs).max() ?? 0, 1e-6,
                             "tap silent — the pluck never reached the sink")
        for (a, b) in zip(unit, twice) {
            XCTAssertEqual(b, 2.0 * a, accuracy: 1e-15,
                           "pre-gain must scale the tapped mixdown exactly")
        }
    }
}
