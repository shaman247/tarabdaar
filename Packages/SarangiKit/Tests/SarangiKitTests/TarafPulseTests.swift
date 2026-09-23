import XCTest
import CBowKernel
@testable import SarangiKit

final class TarafPulseTests: XCTestCase {
    private func engine(threads: Int = 0) throws -> BowEngine {
        var bp = try XCTUnwrap(Presets.bowedStringParams())
        bp.num["bow_jt_threads"] = Double(threads)
        bp.num["bow_jt_async"] = 0
        var t = BowTables.buildOpenString(sr: 96000, tonic: 280.5, bp: bp)
        t.jt = BowTables.buildJawariTables(rows: [(561, 1, 2), (730, 1, 2)], srk: 96000, bp: bp)
        let e = BowEngine(tables: t, mapper: BowControlMapper(), bp: bp, sr: 48000,
                          rfir: [], eLp: 20000, reverbRT60: 1, reverbPredelayMs: 0,
                          reverbMix: 0, reverbWidth: 0, maxPoly: 1)
        e.outGain = 0.0001
        e.setScopeArmed(true)
        return e
    }

    private func render(_ e: BowEngine, frames: Int) -> [Double] {
        var result = [Double]()
        var l = [Double](repeating: 0, count: 128), r = l
        var left = frames
        while left > 0 {
            let n = min(left, l.count)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    e.render(frames: n, outL: lp.baseAddress!, outR: rp.baseAddress!)
                }
            }
            result.append(contentsOf: l.prefix(n))
            left -= n
        }
        return result
    }

    private func rowModes(_ e: BowEngine) -> [Float] {
        var f = [Double](repeating: 0, count: 2), level = f
        var asleep = [UInt8](repeating: 0, count: 2)
        var modes = [Float](repeating: 0, count: 32)
        _ = bow_poly_scope_jt(e.pkernel, 2, &f, &level, &asleep, &modes, 16)
        return modes
    }

    /// A pulse stays on its row, captures settings, and replays identically on workers.
    func testRowLocalCapturedPulseAndWorkerReplay() throws {
        let quiet = try engine(), serial = try engine(), pool = try engine(threads: 2)
        for e in [quiet, serial, pool] { _ = render(e, frames: 24000) }
        serial.setJtEvolutionPulse(amount: 1, attackMs: 5, decayMs: 80)
        pool.setJtEvolutionPulse(amount: 1, attackMs: 5, decayMs: 80)
        serial.setJtPluck(drive: 0.04, decayMs: 12)
        pool.setJtPluck(drive: 0.04, decayMs: 12)
        serial.pluckTaraf(row: 0)
        pool.pluckTaraf(row: 0)
        var a = render(serial, frames: 128), b = render(pool, frames: 128)
        _ = render(quiet, frames: 128)
        serial.setJtEvolutionPulse(amount: 0.1, attackMs: 100, decayMs: 2000)
        serial.setJtPluck(drive: 0.2, decayMs: 100)
        a += render(serial, frames: 48000)
        b += render(pool, frames: 48000)
        _ = render(quiet, frames: 48000)
        XCTAssertEqual(a, b, "active pulse must ignore later settings and worker partition")
        XCTAssertTrue(a.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(a.map(abs).max() ?? 0, 1e-8)
        XCTAssertEqual(Array(rowModes(serial).suffix(16)), Array(rowModes(quiet).suffix(16)),
                       "a row pulse must not move the other row's bone")
        pool.setJtEvolutionPulse(amount: 1, attackMs: 5, decayMs: 80)
        pool.pluckTaraf(row: 0)
        XCTAssertNotEqual(render(pool, frames: 12000), render(serial, frames: 12000),
                          "a repeated onset must retrigger")
    }

    /// Disabling the gesture preserves an actual pluck, including the drone onset path.
    func testDisabledPulseIsByteNullOnPluck() throws {
        let a = try engine(), b = try engine()
        b.setJtEvolutionPulse(amount: 0, attackMs: 100, decayMs: 2000)
        b.setJtPluck(drive: 0, decayMs: 100)
        a.dronePress(row: 0); b.dronePress(row: 0)
        XCTAssertEqual(render(a, frames: 12000), render(b, frames: 12000))
    }
}
