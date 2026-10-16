import XCTest
import CBowKernel
@testable import SarangiKit

/// Polyphonic stability and free traveling-wave preservation.
final class BowPolyTests: XCTestCase {

    /// Release loss leaves held audio identical, shortens the tail and damps it further on the next onset.
    func testReleasedStringDampingThroughTheEngine() throws {
        func phrase(release: Double, nextNote: Bool) throws -> (held: [Double], tail: Double) {
            var bp = try XCTUnwrap(Presets.bowedStringParams())
            bp.num["bow_release_t60"] = release
            let tables = BowTables.buildOpenString(sr: 96000, tonic: 328.9, bp: bp)
            let m = BowControlMapper()
            let e = BowEngine(tables: tables, mapper: m, bp: bp, sr: 48000,
                              rfir: [], eLp: 8000, reverbRT60: 1,
                              reverbPredelayMs: 0, reverbMix: 0, reverbWidth: 0,
                              maxPoly: 4)
            var l = [Double](repeating: 0, count: 256), r = l
            func block() {
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in
                        e.render(frames: 256, outL: lp.baseAddress!, outR: rp.baseAddress!)
                    }
                }
            }
            m.touchOn(1, pitchSemis: 64)
            var held: [Double] = []
            for _ in 0..<100 { block(); held += l }
            m.touchOff(1)
            var energy = 0.0
            for i in 0..<150 {
                if nextNote && i == 30 { m.touchOn(2, pitchSemis: 67) }
                block()
                if i >= 100 { energy += pow(e.scopeSlots()[0].level, 2) }
            }
            return (held, energy)
        }
        let natural = try phrase(release: 0, nextNote: false)
        let shorter = try phrase(release: 8, nextNote: false)
        let damped = try phrase(release: 8, nextNote: true)
        XCTAssertEqual(shorter.held, natural.held)
        XCTAssertEqual(damped.held, natural.held)
        XCTAssertGreaterThan(shorter.tail, 1e-12)
        XCTAssertLessThan(shorter.tail, natural.tail * 0.8)
        XCTAssertLessThan(damped.tail, shorter.tail * 0.01)
    }

    /// Slipping force satisfies the friction law, opposes motion and stays within its coefficient bounds.
    func testSlippingFrictionConstitutiveLaw() {
        for impedance in [0.1, 0.887, 4.5, 10.0] {
            for normal in [0.00001, 0.02, 0.3, 1.5, 4.0] {
                for (muS, muD) in [(1.2, 0.1), (0.8, 0.3), (0.4, 0.6), (0.6, 0.6)] {
                    for corner in [0.05, 0.075, 0.2, 0.5] {
                        for excess in [1e-10, 1e-6, 0.01, 0.1, 1.0, 100.0] {
                            for direction in [-1.0, 1.0] {
                                let free = direction * muS * normal / (2 * impedance) * (1 + excess)
                                let force = bow_friction_slip_force(free, normal, impedance, muS, muD, corner)
                                let slip = free + force / (2 * impedance)
                                let expected = -direction * normal * (muD + (muS - muD) / (1 + abs(slip) / corner))
                                let bound = normal * max(muS, muD)
                                XCTAssertTrue(force.isFinite)
                                XCTAssertEqual(force, expected, accuracy: bound * 1e-10)
                                XCTAssertLessThanOrEqual(force * slip, bound * 1e-12)
                                XCTAssertLessThanOrEqual(abs(force), bound * (1 + 1e-12))
                            }
                        }
                    }
                }
            }
        }
    }

    /// A free loop without physical losses preserves an audible upper partial across fractional lengths.
    func testFreeStringDoesNotAcquireInterpolationDamping() throws {
        let sr = 96000.0, frames = 256
        for (hz, position, harmonic) in [(329.0, 0.08, 6.0), (329.0, 0.213, 6.0),
                                         (660.0, 0.08, 3.0), (660.0, 0.213, 3.0)] {
            var s = bow_scalars_t()
            s.c0 = 1; s.bowW = 1; s.bowWidth = 8.587479; s.bowCont = 2
            s.Z = 1; s.Zt = 10; s.mu_s = 0.8; s.mu_d = 0.3; s.v0f = 0.1
            s.gutG = 1; s.thFloor = 1; s.dispN = 1; s.dcRho = 0.999
            let state = try XCTUnwrap(bow_poly_init(1, sr, 0, nil, nil, nil, nil, nil, &s))
            defer { bow_poly_free(state) }
            let frequency = [Double](repeating: hz, count: frames)
            let speed = [Double](repeating: 0.1, count: frames)
            let force = [Double](repeating: 0.15, count: frames)
            let beta = [Double](repeating: position, count: frames)
            let zero = [Double](repeating: 0, count: frames)
            var gate = zero, output = zero
            // Two narrow bandpasses isolate the same free-loop partial in both windows.
            let omega = 2 * Double.pi * harmonic * hz / sr
            let alpha = sin(omega) / 40, b = alpha / (1 + alpha)
            let a1 = -2 * cos(omega) / (1 + alpha), a2 = (1 - alpha) / (1 + alpha)
            var z1 = [Double](repeating: 0, count: 2), z2 = z1
            var early = 0.0, late = 0.0, peak = 0.0
            for offset in stride(from: 0, to: 153600, by: frames) {
                for i in 0..<frames { gate[i] = offset + i < 19200 ? 1 : 0 }
                bow_poly_process(state, Int32(frames), Int32(frames), frequency,
                                 speed, force, beta, gate, zero, &output)
                for i in 0..<frames {
                    peak = max(peak, abs(output[i]))
                    var x = output[i]
                    for stage in 0..<2 {
                        let y = b * x + z1[stage]
                        z1[stage] = -a1 * y + z2[stage]
                        z2[stage] = -b * x - a2 * y
                        x = y
                    }
                    let sample = offset + i
                    if (38400..<57600).contains(sample) { early += x * x }
                    if (134400..<153600).contains(sample) { late += x * x }
                }
            }
            XCTAssertGreaterThan(early, 1e-5)
            XCTAssertTrue(peak.isFinite && peak < 2)
            XCTAssertLessThan(abs(10 * log10(late / early)), 1,
                              "Numerical decay replaced the physical loss law at \(hz) Hz / \(position)")
        }
    }

    /// Eight maximum-force notes stay finite, settle in energy and release without an output ceiling.
    func testPolyEightNoteChordSettlesAndReleases() throws {
        guard var bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // Stability must not depend on asynchronous drive blocks dropped under test load.
        bp.num["bow_jt_async"] = 0
        bp.num["bow_jt_threads"] = 0
        let sr = 48000.0
        let tonic = 328.9
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        var tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                               tonic: tonic, bp: bp)
        let taraf = Presets.state(.sarangiPilu).resolvedStrings
            .filter(\.enabled)
            .map { (f: $0.freq, gain: $0.gain, t60: $0.t60) }
        tables.jt = BowTables.buildJawariTables(
            rows: taraf.filter { BowTables.jtSteelRow($0.f, tonic: tonic) },
            srk: sr * Double(osf), bp: bp)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp, sr: sr,
                               rfir: [], eLp: bp.v("bow_rad_lp", 8000.0),
                               reverbRT60: bp.v("bow_rev_rt60", 1.0),
                               reverbPredelayMs: 15.0,
                               reverbMix: bp.v("bow_rev_mix", 0.08),
                               reverbWidth: 0.0, maxPoly: 8)
        engine.outGain = bp.v("bow_live_trim", 0.175)

        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        func run(seconds: Double) -> Double {
            var acc = 0.0
            var n = 0
            var left = Int(seconds * sr)
            while left > 0 {
                let m = min(1024, left)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        engine.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                for i in 0..<m {
                    XCTAssertTrue(l[i].isFinite && r[i].isFinite,
                                  "poly chord render went non-finite")
                    let s = l[i] + r[i]
                    acc += s * s
                }
                n += m
                left -= m
            }
            return (acc / Double(n)).squareRoot()
        }

        mapper.setAxis(expr: 1.0, press: 1.0, pos: 0.5)
        for note in [57, 60, 62, 64, 67, 69, 72, 76] {
            mapper.touchOn(UInt16(note), pitchSemis: Double(note))
        }
        _ = run(seconds: 0.5)                       // speak/settle
        let sustain = run(seconds: 2.5)
        XCTAssertGreaterThan(sustain, 1e-3, "chord made no sound")
        // energy must not still be GROWING at the end of the sustain
        let s2 = run(seconds: 1.0)
        XCTAssertLessThan(s2, sustain * 3.0, "chord energy still growing")

        mapper.touchAllOff()                   // all off
        // the taraf rings on by design — settle well clear of the release
        _ = run(seconds: 7.5)
        let tail = run(seconds: 0.5)
        XCTAssertLessThan(tail, sustain * 0.5, "chord did not release")
    }

}
