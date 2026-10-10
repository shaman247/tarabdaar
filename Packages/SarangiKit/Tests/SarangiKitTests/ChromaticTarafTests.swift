import XCTest
import CBowKernel
@testable import SarangiKit

final class ChromaticTarafTests: XCTestCase {
    /// A clean high-drive glide must not generate isolated contact-radiation spikes.
    func testCleanGlideHasBoundedContactTransients() throws {
        var bp = try XCTUnwrap(Presets.bowedStringParams())
        bp.num["bow_jt_async"] = 0
        bp.num["bow_jt_threads"] = 0
        bp.num["bow_jt_couple"] = 0
        bp.num["bow_jtc_evolve"] = 0
        var t = BowTables.buildOpenString(sr: 96000, tonic: 328.9, bp: bp)
        t.jt = BowTables.buildJawariTables(rows: [(164.45, 1, 5)],
            srk: 96000, bp: bp, chromatic: [true])
        let e = BowEngine(tables: t, mapper: BowControlMapper(), bp: bp, sr: 48000,
            rfir: [], eLp: 20000, reverbRT60: 1, reverbPredelayMs: 0,
            reverbMix: 0, reverbWidth: 0, maxPoly: 1)
        XCTAssertNotNil(e.settleForPublication())
        e.setJtInjectGain(1)
        var phase = 0.0, previous = 0.0, energy = 0.0, largestStep = 0.0
        var count = 0, finite = true
        for block in 0..<2250 {
            var input = [Double](repeating: 0, count: 256)
            for i in input.indices {
                let time = Double(block * 256 + i) / 96000
                let hz = 328.9 * pow(2, min(1, max(0, (time - 1.2) / 4)))
                phase += 2 * Double.pi * hz / 96000
                input[i] = 0.42 * min(1, max(0, (time - 0.2) / 0.1)) * sin(phase)
            }
            input.withUnsafeBufferPointer { e.jtInjectWrite($0.baseAddress!, input.count) }
            let output = chromatic(e, frames: 256)
            for sample in output {
                finite = finite && sample.isFinite
                if block >= 450 && block < 1950 {
                    energy += sample * sample
                    largestStep = max(largestStep, abs(sample - previous))
                    count += 1
                }
                previous = sample
            }
        }
        XCTAssertTrue(finite)
        let rms = sqrt(energy / Double(count))
        XCTAssertGreaterThan(rms, 1e-8)
        XCTAssertLessThan(largestStep / rms, 0.75,
            "a smooth glide generated a contact spike larger than the sustained radiation")
    }

    private func engine(async: Bool) throws -> BowEngine {
        var bp = try XCTUnwrap(Presets.bowedStringParams())
        bp.num["bow_jt_async"] = async ? 1 : 0
        bp.num["bow_jt_threads"] = async ? 2 : 0
        var t = BowTables.buildOpenString(sr: 96000, tonic: 280.5, bp: bp)
        t.jt = BowTables.buildJawariTables(rows: [(561, 1, 2), (730, 1, 2), (280.5, 1, 2)],
            srk: 96000, bp: bp, trackRowIndex: 2, chromatic: [false, true, true])
        t.jt?.dualRows = [0]
        let e = BowEngine(tables: t, mapper: BowControlMapper(), bp: bp, sr: 48000,
            rfir: [], eLp: 20000, reverbRT60: 1, reverbPredelayMs: 0,
            reverbMix: 0, reverbWidth: 0, maxPoly: 1)
        XCTAssertEqual(bow_poly_jt_prepare_initial_state(e.pkernel), 1)
        e.setScopeArmed(true)
        return e
    }

    private func chromatic(_ e: BowEngine, frames: Int) -> [Double] {
        let pitch = [Double](repeating: 561, count: frames)
        let zero = [Double](repeating: 0, count: frames)
        var voice = zero, web = zero, c = zero, r = zero
        bow_poly_process4(e.pkernel, Int32(frames), Int32(frames), pitch, zero, zero,
            pitch, zero, zero, &voice, nil, &web, nil, &c, &r)
        return c
    }

    /// Chromatic plucks and follower controls bypass raga buffering and replay across callback sizes.
    func testCallbackBankIsIndependentOfRagaWorkers() throws {
        let serial = try engine(async: false), async = try engine(async: true)
        let injection = (0..<16384).map { 0.002 * sin(Double($0) * 0.037) }
        for e in [serial, async] {
            bow_poly_jt_inject_gain(e.pkernel, 1)
            bow_poly_jt_inject_write(e.pkernel, injection, Int32(injection.count))
            e.setJtPluck(drive: 0.04, decayMs: 12)
            e.setJtEvolutionPulse(amount: 0.6, attackMs: 5, decayMs: 80)
            e.pluckTaraf(row: 1)
            bow_poly_jt_track_target(e.pkernel, 840)
            e.pluckTaraf(row: 2)
        }
        let first = chromatic(async, frames: 256)
        XCTAssertGreaterThan(first.map(abs).max() ?? 0, 1e-8,
            "chromatic onset must arrive before the raga FIFO is primed")
        var actual = first
        for _ in 0..<63 { actual += chromatic(async, frames: 256) }
        let expected = chromatic(serial, frames: actual.count)
        XCTAssertEqual(actual, expected,
            "worker scheduling and callback sizes must not alter chromatic samples")
        XCTAssertTrue(actual.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(async.scopeRows()[2].f0Hz, 800,
            "the follower must retune in its owning callback bank")
        XCTAssertGreaterThan(async.scopeRows()[1].level, 0,
            "row scope must read the callback bank")
        for e in [serial, async] {
            e.setJtEvolveChromatic(0.7)
            e.setJtDrive(0.06)
            e.setJtDriveNorm(0.8)
            e.setPerformanceGains([1, 0.4, 1])
            e.setJtBody(0.3)
            bow_poly_jt_set_cap(e.pkernel, 0.5, 1)
        }
        XCTAssertEqual(chromatic(serial, frames: 4096), chromatic(async, frames: 4096),
            "live bank controls must reach both serial and asynchronous hosts")
    }
}
