import XCTest
@testable import SarangiKit
import CBowKernel

/// Tanpura voice: table builder lockstep against the exporter golden, and the engine mounts the JI slot grid and sounds.
final class TanpuraEngineTests: XCTestCase {

    private func params() throws -> TanpuraParams {
        guard let p = Presets.tanpuraParams() else {
            throw XCTSkip("tanpura_live.json missing from the SarangiKit bundle")
        }
        return p
    }

    /// The table builder is in lockstep with the exporter golden.
    func testTablesLockstepGolden() throws {
        let p = try params()
        guard let gu = Bundle.module.url(forResource: "tanpura_live_golden",
                                         withExtension: "json",
                                         subdirectory: "Goldens"),
              let gd = try? Data(contentsOf: gu),
              let g = try? JSONSerialization.jsonObject(with: gd) as? [String: Any]
        else { throw XCTSkip("tanpura_live_golden.json missing from the test bundle") }
        let cents = g["cents"] as! Double
        let t = TanpuraTables.buildNote(f0Sounding: 220.0, cents: cents, p: p)
        func arr(_ k: String) -> [Double] {
            (g[k] as! [Any]).map { ($0 as? Double) ?? Double($0 as! Int) }
        }
        XCTAssertEqual(t.M, Int(g["M"] as! Int))
        XCTAssertEqual(t.J, Int(g["J"] as! Int))
        let pairs: [(String, [Double])] = [
            ("ca", t.ca), ("cb", t.cb), ("ca4", t.ca4), ("cb4", t.cb4),
            ("cas", t.cas), ("cbs", t.cbs), ("wd", t.wd),
            ("caw", t.caw), ("cbw", t.cbw), ("wdw", t.wdw),
            ("Phi", t.phi), ("phiF", t.phiF), ("b", t.b),
            ("G", t.g), ("G4", t.g4), ("gd", t.gd), ("gd4", t.gd4),
            ("phi_o", t.phiO), ("dq", t.dq),
            ("g_th", t.gTh),
        ]
        for (name, mine) in pairs {
            let ref = arr(name)
            XCTAssertEqual(mine.count, ref.count, name)
            // per-element scale floored at 1e-6 of the array max: near-
            // cancelling series entries carry summation-order noise that
            // reads as huge relative drift at ~1e-16 absolute error.
            let refMax = ref.reduce(0.0) { max($0, abs($1)) }
            var worst = 0.0
            for i in 0..<min(mine.count, ref.count) {
                let scale = max(abs(ref[i]), 1e-6 * refMax + 1e-30)
                worst = max(worst, abs(mine[i] - ref[i]) / scale)
            }
            XCTAssertLessThan(worst, 1e-9, "\(name) lockstep drift \(worst)")
        }
        XCTAssertEqual(t.deep, g["deep"] as! Double, accuracy: 1e-15)
        XCTAssertEqual(t.dt, g["dt"] as! Double, accuracy: 1e-18)
    }

    /// The engine mounts an arbitrary JI slot grid, rests silent, and a
    /// plucked string rings on (no note-off — the string's nature).
    func testEngineSmokeJISlots() throws {
        let p = try params()
        // A JI drone set (low Sa · low Pa · Sa at a 220 Hz tonic) — the
        // Tarabdaar mount shape: arbitrary exact Hz, not MIDI notes.
        guard let e = TanpuraEngine(params: p,
                                    frequencies: [110.0, 165.0, 220.0],
                                    workers: 1)   // sync path: deterministic
        else { return XCTFail("engine build failed") }
        XCTAssertEqual(e.slotFrequencies.count, 3)
        // nearest-slot lookup: exact hits and the tolerance gate
        XCTAssertEqual(e.nearestSlot(toHz: 165.0), 1)
        XCTAssertEqual(e.nearestSlot(toHz: 165.2, toleranceCents: 50), 1)
        XCTAssertNil(e.nearestSlot(toHz: 140.0, toleranceCents: 50))
        let n = 4096
        var l = [Double](repeating: 0, count: n)
        var r = [Double](repeating: 0, count: n)
        func render() {
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    e.render(frames: n, outL: lb.baseAddress!,
                             outR: rb.baseAddress!)
                }
            }
        }
        // silence before any pluck
        render()
        let pre = l.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(pre, 1e-9, "silent engine emitted \(pre)")
        e.pluck(slot: 2, velocity: 100)
        var peak = 0.0
        var lastBlockPeak = 0.0
        let blocks = Int(2.0 * p.sr / Double(n))
        for _ in 0..<blocks {
            render()
            lastBlockPeak = l.map { abs($0) }.max() ?? 0
            peak = max(peak, lastBlockPeak)
            XCTAssertTrue(l.allSatisfy { $0.isFinite }, "non-finite output")
        }
        XCTAssertGreaterThan(peak, 1e-6, "pluck was silent")
        XCTAssertGreaterThan(lastBlockPeak, peak * 1e-4,
                             "string stopped ringing — tanpura strings ring")
        XCTAssertEqual(e.activeStrings, 1)
    }
}
