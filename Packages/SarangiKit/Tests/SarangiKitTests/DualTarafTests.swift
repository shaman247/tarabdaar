import XCTest
import CryptoKit
import CBowKernel
@testable import SarangiKit

final class DualTarafTests: XCTestCase {
    private func engine(threads: Int = 0, enabled: Bool = true,
                        frequency: Double = 561, drive: Double = 0.03, cutoff: Double = 20000,
                        both: Bool = false, sav: Bool = false, bloom: Double = 1) throws -> BowEngine {
        var bp = try XCTUnwrap(Presets.bowedStringParams())
        bp.num["bow_jt_threads"] = Double(threads)
        bp.num["bow_jt_async"] = 0
        bp.num["bow_jt_drive"] = drive
        bp.num["bow_jt_dual_lp"] = cutoff
        bp.num["bow_jt_bow_bloom"] = bloom
        bp.num["bow_jt_dual_row"] = enabled ? 1 : 0
        if sav { bp.num["bow_jt_sav"] = 1 }
        var t = BowTables.buildOpenString(sr: 96000, tonic: frequency/2, bp: bp)
        t.jt = BowTables.buildJawariTables(rows: [(frequency, 1, 4), (frequency+1, 1, 4)], srk: 96000, bp: bp)
        if both { t.jt?.dualRows = [0, 1] }
        let e = BowEngine(tables: t, mapper: BowControlMapper(), bp: bp, sr: 48000,
            rfir: [], eLp: 20000, reverbRT60: 1, reverbPredelayMs: 0,
            reverbMix: 0, reverbWidth: 0, maxPoly: 3)
        e.outGain = 0.0001
        e.setScopeArmed(true)
        XCTAssertEqual(e.jtDualRow, enabled ? 0 : -1)
        return e
    }
    @discardableResult
    private func render(_ e: BowEngine, seconds: Double) -> [Double] {
        let frames = Int(seconds*48000)
        var output = [Double](repeating: 0, count: frames), right = [Double](repeating: 0, count: 128)
        output.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for from in stride(from: 0, to: frames, by: 128) {
                    e.render(frames: min(128, frames-from), outL: l.baseAddress!+from, outR: r.baseAddress!)
                }
            }
        }
        return output
    }
    private func energy(_ x: ArraySlice<Double>) -> Double { x.reduce(0) { $0+$1*$1 } / Double(x.count) }

    /// Bow bloom changes the sustained spectrum, preserves unforced plucks, and replays on workers.
    func testBowBloomReleasesHarmonicsWithoutChangingPlucks() throws {
        let plain = try engine(frequency: 328.9, bloom: 0)
        let bloom = try engine(frequency: 328.9)
        let worker = try engine(threads: 2, frequency: 328.9)
        for e in [plain, bloom, worker] { e.setBusBalance(1); render(e, seconds: 0.1) }
        for e in [plain, bloom, worker] { e.pluckTaraf(row: 0) }
        let pluck = render(plain, seconds: 1)
        XCTAssertEqual(pluck, render(bloom, seconds: 1))
        XCTAssertEqual(pluck, render(worker, seconds: 1))
        for e in [plain, bloom, worker] {
            e.mapper.setAxis(expr: 1, press: 0.8)
            e.mapper.touchOn(1, pitchSemis: 69+12*log2(328.9/440))
        }
        let unchanged = render(plain, seconds: 8)
        let evolving = render(bloom, seconds: 8)
        XCTAssertEqual(evolving, render(worker, seconds: 8))
        // Normalized difference energy measures brightness independently of level.
        func brightness(_ x: ArraySlice<Double>) -> Double {
            zip(x.dropFirst(), x).reduce(0) { $0+pow($1.0-$1.1, 2) }
                / max(x.reduce(0) { $0+$1*$1 }, 1e-30)
        }
        let early = evolving[24000..<48000], late = evolving.suffix(48000)
        XCTAssertGreaterThan(energy(late), 1e-18)
        XCTAssertLessThan(brightness(late), brightness(early)*0.6)
        XCTAssertLessThan(brightness(late), brightness(evolving[144000..<192000])*0.6,
                          "harmonic evolution must continue beyond the initial bloom")
        XCTAssertLessThan(brightness(late), brightness(unchanged.suffix(48000))*0.6)
        for e in [plain, bloom, worker] { e.mapper.touchOff(1) }
        let release = render(bloom, seconds: 4)
        XCTAssertEqual(release, render(worker, seconds: 4))
        XCTAssertTrue((evolving+release).allSatisfy(\.isFinite))
        XCTAssertLessThan(energy(release.suffix(24000)), energy(release.prefix(24000))*0.15)
        XCTAssertEqual(bloom.jtDualStats()[1], 0)
        XCTAssertEqual(worker.jtDualStats()[1], 0)
    }

    /// A mixed twelve-row physical bank preserves every row through worker repartition and serial fallback.
    func testTwelveRowWorkerPlanAndResize() throws {
        func bank(_ threads: Int) throws -> BowEngine {
            var bp = try XCTUnwrap(Presets.bowedStringParams())
            bp.num["bow_jt_threads"] = Double(threads); bp.num["bow_jt_async"] = 0
            let frequencies = [164.45, 246.675, 328.9, 370.0125, 394.68, 411.125,
                               438.533333333333, 493.35, 548.166666666667, 584.711111111111, 616.6875, 657.8]
            let rows = (frequencies + [300, 450, 600]).map { ($0, 1.0, 4.0) }
            var t = BowTables.buildOpenString(sr: 96000, tonic: 164.45, bp: bp)
            t.jt = BowTables.buildJawariTables(rows: rows, srk: 96000, bp: bp)
            t.jt?.dualRows = Array(0..<12)
            let e = BowEngine(tables: t, mapper: BowControlMapper(), bp: bp, sr: 48000,
                rfir: [], eLp: 20000, reverbRT60: 1, reverbPredelayMs: 0,
                reverbMix: 0, reverbWidth: 0, maxPoly: 3)
            e.outGain = 0.0001
            return e
        }
        let a = try bank(3), b = try bank(3), serial = try bank(0)
        for e in [a, b, serial] { for row in 0..<12 { e.pluckTaraf(row: row) } }
        let first = render(a, seconds: 0.25), same = render(b, seconds: 0.25)
        let reference = render(serial, seconds: 0.25)
        XCTAssertEqual(first, same)
        let error = zip(first, reference).reduce(0.0) { $0 + pow($1.0-$1.1, 2) }
        XCTAssertLessThan(sqrt(error/max(first.reduce(0) { $0+$1*$1 }, 1e-30)), 1e-10)
        for threads: Int32 in [0, 2, 4] {
            for e in [a, b] {
                bow_poly_jt_set_threads(e.pkernel, threads)
                for row in 0..<12 { e.pluckTaraf(row: row) }
            }
            XCTAssertEqual(render(a, seconds: 0.1), render(b, seconds: 0.1))
            XCTAssertEqual(a.jtDualStats()[1], 0); XCTAssertEqual(b.jtDualStats()[1], 0)
        }
    }

    /// The optional solver survives coupled retriggers and worker replay without invoking Newton.
    func testSAVOptionReplaysAndDecaysWithoutNewton() throws {
        let serial = try engine(both: true, sav: true)
        let workers = try engine(threads: 2, both: true, sav: true)
        let newton = try engine(both: true)
        for e in [serial, workers, newton] { e.setJtCouple(1); e.pluckTaraf(row: 0) }
        let first = render(serial, seconds: 0.2)
        XCTAssertEqual(first, render(workers, seconds: 0.2))
        XCTAssertNotEqual(first, render(newton, seconds: 0.2))
        XCTAssertGreaterThan(newton.jtDualStats()[3], 0)
        for event in 0..<8 {
            for e in [serial, workers] {
                e.setJtDualDisplacement(mm: event.isMultiple(of: 2) ? 0.5 : 1)
                e.pluckTaraf(row: event%2)
            }
            XCTAssertEqual(render(serial, seconds: 0.08), render(workers, seconds: 0.08))
        }
        let tail = render(serial, seconds: 4)
        XCTAssertEqual(tail, render(workers, seconds: 4))
        XCTAssertTrue(tail.allSatisfy(\.isFinite))
        XCTAssertLessThan(energy(tail.suffix(24000)), energy(tail.prefix(24000))*0.15)
        for e in [serial, workers] {
            XCTAssertEqual(e.jtDualStats()[1], 0)
            XCTAssertEqual(e.jtDualStats()[3], 0)
        }
    }

    /// A shared row replays on workers, captures its pluck, and survives a moving-string retrigger.
    func testSharedRowWorkerParityAndRetrigger() throws {
        let a = try engine(frequency: 293.66), b = try engine(threads: 2, frequency: 293.66)
        render(a, seconds: 0.05); render(b, seconds: 0.05)
        a.pluckTaraf(row: 0); b.dronePress(row: 0)
        let pluck = render(a, seconds: 0.1)
        XCTAssertEqual(pluck, render(b, seconds: 0.1))
        let hash = pluck.withUnsafeBytes { SHA256.hash(data: Data($0)) }
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "3a4d6cc2f02d1285a8f5a12b6278fc9af06f2e4dda8fffe5a9ef2df3ddac98b9", "direct-pluck radiation calibration")
        a.setJtDualDisplacement(mm: 0.1)
        XCTAssertEqual(render(a, seconds: 0.1), render(b, seconds: 0.1), "pluck settings are captured")
        a.setJtDualDisplacement(mm: 0.5)
        a.pluckTaraf(row: 0); b.pluckTaraf(row: 0)
        let x = render(a, seconds: 0.4), y = render(b, seconds: 0.4)
        XCTAssertEqual(x, y)
        XCTAssertGreaterThan(energy(x[...]), 1e-14)
        XCTAssertTrue(x.allSatisfy(\.isFinite))
        for e in [a, b] { e.setJtDualDisplacement(mm: 1); e.pluckTaraf(row: 0) }
        let strong = render(a, seconds: 0.4)
        XCTAssertEqual(strong, render(b, seconds: 0.4))
        XCTAssertTrue(strong.allSatisfy(\.isFinite))
        XCTAssertEqual(a.jtDualStats()[1], 0)
        XCTAssertEqual(b.jtDualStats()[1], 0)
    }

    /// Multiple physical rows keep independent pluck state and replay identically on workers.
    func testMultipleRowsAreIndependentAndReplayOnWorkers() throws {
        let serial = try engine(both: true), workers = try engine(threads: 2, both: true)
        XCTAssertEqual(serial.jtDualRows, [0, 1])
        for e in [serial, workers] { e.setJtCouple(0); render(e, seconds: 0.05); e.pluckTaraf(row: 1) }
        XCTAssertEqual(render(serial, seconds: 0.1), render(workers, seconds: 0.1))
        var motion = [Float](repeating: 0, count: 32)
        _ = bow_poly_scope_jt(serial.pkernel, 2, nil, nil, nil, &motion, 16)
        XCTAssertTrue(motion.prefix(16).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(motion.suffix(16).map(abs).max()!, 1e-7)
        for e in [serial, workers] { e.pluckTaraf(row: 0); e.pluckTaraf(row: 1) }
        XCTAssertEqual(render(serial, seconds: 0.2), render(workers, seconds: 0.2))
        XCTAssertEqual(serial.jtDualStats()[1], 0)
        XCTAssertEqual(workers.jtDualStats()[1], 0)
    }

    /// Radiation filtering leaves the coupled mechanical trajectory unchanged, including live sweeps.
    func testRadiationToneDoesNotChangePhysics() throws {
        let raw = try engine(cutoff: 20000), cut = try engine(cutoff: 4000)
        for e in [raw, cut] {
            e.setJtCouple(1)
            e.mapper.setAxis(expr: 1, press: 0.8)
            e.mapper.touchOn(1, pitchSemis: 69+12*log2(561/440))
            e.pluckTaraf(row: 0)
        }
        XCTAssertNotEqual(render(raw, seconds: 0.3), render(cut, seconds: 0.3))
        cut.setJtDualTone(hz: 2000)
        cut.setJtDualSelectivity(1)
        render(raw, seconds: 0.1); render(cut, seconds: 0.1)
        cut.setJtDualTone(hz: 12000)
        cut.setJtDualSelectivity(0.5)
        render(raw, seconds: 0.1); render(cut, seconds: 0.1)
        cut.setJtDualTone(hz: 20000)
        render(raw, seconds: 1); render(cut, seconds: 1)
        // Both row motion and the coupled neighbor must replay exactly.
        func modes(_ e: BowEngine) -> [Float] {
            var values = [Float](repeating: 0, count: 32)
            _ = bow_poly_scope_jt(e.pkernel, 2, nil, nil, nil, &values, 16)
            return values
        }
        let motion = modes(raw)
        XCTAssertTrue(motion.contains { $0 != 0 })
        XCTAssertEqual(motion, modes(cut))
        // Downstream high-pass memories retain roundoff after different audio histories.
        let a = render(raw, seconds: 0.1), b = render(cut, seconds: 0.1)
        let peak = a.map(abs).max()!
        XCTAssertLessThan(zip(a, b).map { abs($0-$1) }.max()!, peak*1e-9)
        XCTAssertEqual(raw.jtDualStats()[1], 0)
        XCTAssertEqual(cut.jtDualStats()[1], 0)
    }

    /// Harmonic cleanup preserves integer partials off the FFT grid, rejects noise and delays bypass exactly.
    func testOvertoneFilterRejectsNoiseWithoutDullingPartials() throws {
        let filter = try XCTUnwrap(bow_tonal_create(561))
        let bypass = try XCTUnwrap(bow_tonal_create(561))
        let resumed = try XCTUnwrap(bow_tonal_create(561))
        defer { bow_tonal_destroy(filter); bow_tonal_destroy(bypass); bow_tonal_destroy(resumed) }
        let rate = 96000.0, latency = 2048, count = 96000
        let frequencies = [561.0, 2805, 5049, 7293, 11220]
        let amplitudes = [0.4, 0.2, 0.1, 0.08, 0.05]
        var clean = [Double](repeating: 0, count: count)
        var input = clean, output = clean, reactivated = clean
        var rng: UInt64 = 84
        for i in 0..<count {
            let t = Double(i)/rate
            clean[i] = zip(frequencies, amplitudes).reduce(0) { $0 + $1.1*sin(2*Double.pi*$1.0*t) }
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            input[i] = clean[i] + 0.15*(Double(rng >> 11)/9007199254740992.0 - 0.5)
            output[i] = bow_tonal_tick(filter, input[i], 4000, 0)
            reactivated[i] = bow_tonal_tick(resumed, input[i], i < 24000 ? 20000 : 4000, 0)
            if i < 24000 { XCTAssertEqual(reactivated[i], i < latency ? 0 : input[i-latency]) }
            XCTAssertEqual(bow_tonal_tick(bypass, input[i], 20000, 1), i < latency ? 0 : input[i-latency])
        }
        let samples = 48000..<(count-latency)
        var before = 0.0, after = 0.0, afterResume = 0.0
        for i in samples {
            before += pow(input[i]-clean[i], 2)
            after += pow(output[i+latency]-clean[i], 2)
            afterResume += pow(reactivated[i+latency]-clean[i], 2)
        }
        XCTAssertLessThan(after/before, 0.25)
        XCTAssertLessThan(afterResume/before, 0.25)
        for frequency in frequencies {
            var reA = 0.0, imA = 0.0, reB = 0.0, imB = 0.0
            for i in samples {
                let phase = 2*Double.pi*frequency*Double(i)/rate
                reA += input[i]*cos(phase); imA += input[i]*sin(phase)
                reB += output[i+latency]*cos(phase); imB += output[i+latency]*sin(phase)
            }
            XCTAssertLessThan(abs(20*log10(hypot(reB, imB)/hypot(reA, imA))), 1)
        }
    }

    /// Equally prominent nonharmonic tones are rejected, and changing row tuning swaps which tone passes.
    func testHarmonicLatticeRejectsProminentInharmonicPeaks() throws {
        for fundamental in [71.0, 140, 293.66, 561, 1200] {
            let harmonic = ceil(5000/fundamental)
            let tunings = [fundamental, fundamental*(harmonic+0.5)/harmonic]
            let filters = try tunings.map { try XCTUnwrap(bow_tonal_create($0)) }
            defer { filters.forEach { bow_tonal_destroy($0) } }
            let frequencies = tunings.map { $0*harmonic }
            let rate = 96000.0
            let delays = filters.map { Int(bow_tonal_latency($0)) }
            var re = [[Double]](repeating: [0, 0], count: 2), im = re
            var samples = 0.0
            for i in 0..<96000 {
                let input = frequencies.reduce(0) { $0 + 0.2*sin(2*Double.pi*$1*Double(i)/rate) }
                for row in filters.indices {
                    let y = bow_tonal_tick(filters[row], input, 4000, 0)
                    if i >= 48000 {
                        for tone in frequencies.indices {
                            let phase = 2*Double.pi*frequencies[tone]*Double(i-delays[row])/rate
                            re[row][tone] += y*cos(phase); im[row][tone] += y*sin(phase)
                        }
                    }
                }
                if i >= 48000 { samples += 1 }
            }
            for row in filters.indices {
                let kept = 2*hypot(re[row][row], im[row][row])/samples
                let rejected = 2*hypot(re[row][1-row], im[row][1-row])/samples
                XCTAssertLessThan(abs(20*log10(kept/0.2)), 1)
                XCTAssertLessThan(20*log10(rejected/kept), -20)
            }
        }
    }

    /// Increasing selectivity reduces high-frequency noise monotonically without changing bypass.
    func testSelectivityRejectsMoreHiss() throws {
        let filters = try (0..<3).map { _ in try XCTUnwrap(bow_tonal_create(561)) }
        defer { filters.forEach { bow_tonal_destroy($0) } }
        var energy = [Double](repeating: 0, count: 3)
        var rng: UInt64 = 84
        var previous = 0.0
        for i in 0..<96000 {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            let noise = Double(rng >> 11)/9007199254740992.0 - 0.5
            let input = noise-previous
            previous = noise
            for index in filters.indices {
                let y = bow_tonal_tick(filters[index], input, 4000, Double(index)/2)
                if i >= 48000 { energy[index] += y*y }
            }
        }
        XCTAssertLessThan(energy[1], energy[0])
        XCTAssertLessThan(energy[2], energy[1])
        XCTAssertLessThan(energy[2], energy[0]*0.7)
    }

    /// Bridge drive wakes the row and the returned force changes another row without sustained growth.
    func testBridgeInputReturnAndDecay() throws {
        for (frequency, drive) in [(561.0, 0.03), (1400.0, 0.3)] {
        let off = try engine(frequency: frequency, drive: drive)
        let on = try engine(frequency: frequency, drive: drive)
        off.setJtCouple(0); on.setJtCouple(1)
        for e in [off, on] {
            render(e, seconds: 0.1)
            e.pluckTaraf(row: 0)
            render(e, seconds: 0.25)
        }
        func neighborMotion(_ e: BowEngine) -> Float {
            var frequencies = [Double](repeating: 0, count: 2), levels = frequencies
            var asleep = [UInt8](repeating: 0, count: 2), modes = [Float](repeating: 0, count: 32)
            _ = bow_poly_scope_jt(e.pkernel, 2, &frequencies, &levels, &asleep, &modes, 16)
            return modes.suffix(16).reduce(0) { $0+$1*$1 }
        }
        if drive == 0.03 {
            XCTAssertGreaterThan(neighborMotion(on), neighborMotion(off)*2+1e-15,
                "plucking the upgraded row must physically charge a different row through the bridge")
        }
        for e in [off, on] {
            e.mapper.setAxis(expr: 0.8, press: 0.7)
            e.mapper.touchOn(1, pitchSemis: 69+12*log2(frequency/440))
            render(e, seconds: 0.15)
            e.pluckTaraf(row: 0)
            render(e, seconds: 0.15)
            e.mapper.touchOff(1)
        }
        let a = render(off, seconds: 4), b = render(on, seconds: 4)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.allSatisfy(\.isFinite))
        XCTAssertLessThan(energy(b.suffix(24000)), energy(b.prefix(24000))*0.15)
        XCTAssertEqual(on.jtDualStats()[1], 0)
        XCTAssertEqual(off.jtDualStats()[1], 0)
        print("DUAL coupling frequency/drive/early/late RMS", frequency, drive,
            sqrt(energy(b.prefix(24000))), sqrt(energy(b.suffix(24000))))
        }
    }
}
