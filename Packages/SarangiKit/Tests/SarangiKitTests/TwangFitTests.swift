import XCTest
@testable import SarangiKit

/// OFFLINE fitting harness for the `bow_twang` sitar-twang fold — NOT a
/// regression test (guards live in TwangTests). Renders staccato notes on
/// the SHIPPING artifact across a grid of fold shapes and dumps raw
/// float64 mono to $TWANG_FIT_DIR for the Python metric script
/// (harmonic-bloom analysis, compared against sitar1.wav). Run with
///   TWANG_FIT_DIR=<dir> swift test --filter TwangFitTests
/// Skipped otherwise.
final class TwangFitTests: XCTestCase {

    func testDumpTwangGrid() throws {
        guard let dir = ProcessInfo.processInfo.environment["TWANG_FIT_DIR"]
        else { throw XCTSkip("fitting harness — set TWANG_FIT_DIR to run") }
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let sr = 48000.0
        let tonic = 328.9

        // one staccato note (place → strike → release → ring), jt taraf
        // OFF so the metrics see the played string alone
        func render(twang: Double, kneeR: Double, depth: Double,
                    relMs: Double, rollSmp: Double, vel: UInt8,
                    bright: Double = 0, ring: Double = 0,
                    gut: Double = 0, note: UInt8 = 60,
                    seconds: Double = 1.8) -> [Double] {
            let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
            let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                                   tonic: tonic, bp: bp)
            let mapper = BowControlMapper()
            let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                                   sr: sr, rfir: [],
                                   eLp: bp.v("bow_rad_lp", 8000.0),
                                   reverbRT60: bp.v("bow_rev_rt60", 1.0),
                                   reverbPredelayMs: 15.0,
                                   reverbMix: 0.0, reverbWidth: 0.0)
            engine.outGain = bp.v("bow_live_trim", 0.175)
            if twang > 0 {
                engine.setTwang(twang)
                engine.setTwangShape(kneeR: kneeR, depth: depth,
                                     relMs: relMs, rollSmp: rollSmp,
                                     bright: bright, ring: ring, gut: gut)
            }
            var l = [Double](repeating: 0, count: 1024)
            var r = [Double](repeating: 0, count: 1024)
            var out: [Double] = []
            out.reserveCapacity(Int(seconds * sr))
            func run(_ secs: Double) {
                var left = Int(secs * sr)
                while left > 0 {
                    let m = min(1024, left)
                    l.withUnsafeMutableBufferPointer { lb in
                        r.withUnsafeMutableBufferPointer { rb in
                            engine.render(frames: m, outL: lb.baseAddress!,
                                          outR: rb.baseAddress!)
                        }
                    }
                    for i in 0..<m { out.append(0.5 * (l[i] + r[i])) }
                    left -= m
                }
            }
            mapper.setAxis(expr: 0.6, press: 0.562, pos: 0.45)
            mapper.midi(0x90, note, vel)
            run(0.25)
            mapper.midi(0x80, note, 0)
            run(seconds - 0.25)
            return out
        }

        func dump(_ name: String, _ x: [Double]) throws {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            try x.withUnsafeBufferPointer {
                try Data(buffer: $0).write(to: url)
            }
            print("twangfit: wrote \(name) (\(x.count) samples)")
        }

        try dump("base_v100.f64",
                 render(twang: 0, kneeR: 0, depth: 0, relMs: 0,
                        rollSmp: 0, vel: 100))
        // extended-top validation: pitch lock across notes × amounts,
        // all on the BAKED defaults (no shape override)
        for (tag, note) in [("48", UInt8(48)), ("60", UInt8(60)),
                            ("72", UInt8(72))] {
            try dump("v\(tag)_base.f64",
                     render(twang: 0, kneeR: 0, depth: 0, relMs: 0,
                            rollSmp: 0, vel: 100, note: note, seconds: 2.0))
            for (atag, amt) in [("05", 0.5), ("075", 0.75), ("1", 1.0)] {
                try dump("v\(tag)_t\(atag).f64",
                         render(twang: amt, kneeR: 0, depth: 0, relMs: 0,
                                rollSmp: 0, vel: 100, note: note,
                                seconds: 2.0))
            }
        }
        // baked-default validation (no shape override — the shipping map)
        try dump("bake_t1.f64",
                 render(twang: 1, kneeR: 0, depth: 0, relMs: 0,
                        rollSmp: 0, vel: 100, seconds: 3.0))
        try dump("bake_t05.f64",
                 render(twang: 0.5, kneeR: 0, depth: 0, relMs: 0,
                        rollSmp: 0, vel: 100, seconds: 3.0))
        try dump("base_long.f64",
                 render(twang: 0, kneeR: 0, depth: 0, relMs: 0,
                        rollSmp: 0, vel: 100, seconds: 3.0))
        // listening phrase: 3 staccato plucks (the sitar1.wav gesture)
        for (name, tw) in [("phrase_t0", 0.0), ("phrase_t05", 0.5),
                           ("phrase_t075", 0.75), ("phrase_t1", 1.0)] {
            let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
            let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                                   tonic: tonic, bp: bp)
            let mapper = BowControlMapper()
            let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                                   sr: sr, rfir: [],
                                   eLp: bp.v("bow_rad_lp", 8000.0),
                                   reverbRT60: bp.v("bow_rev_rt60", 1.0),
                                   reverbPredelayMs: 15.0,
                                   reverbMix: 0.0, reverbWidth: 0.0)
            engine.outGain = bp.v("bow_live_trim", 0.175)
            if tw > 0 { engine.setTwang(tw) }
            var l = [Double](repeating: 0, count: 1024)
            var r = [Double](repeating: 0, count: 1024)
            var out: [Double] = []
            mapper.setAxis(expr: 0.6, press: 0.562, pos: 0.45)
            func run(_ secs: Double) {
                var left = Int(secs * sr)
                while left > 0 {
                    let m = min(1024, left)
                    l.withUnsafeMutableBufferPointer { lb in
                        r.withUnsafeMutableBufferPointer { rb in
                            engine.render(frames: m, outL: lb.baseAddress!,
                                          outR: rb.baseAddress!)
                        }
                    }
                    for i in 0..<m { out.append(0.5 * (l[i] + r[i])) }
                    left -= m
                }
            }
            for _ in 0..<3 {
                mapper.midi(0x90, 60, 100)
                run(0.25)
                mapper.midi(0x80, 60, 0)
                run(1.15)
            }
            run(0.8)
            try dump("\(name).f64", out)
        }
        // expression consistency at the c3 shape (the mapper is
        // expression-driven; velocity only shapes the bite)
        for (ei, expr) in [0.3, 0.85].enumerated() {
            let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
            let tables = BowTables.buildOpenString(sr: sr * Double(osf),
                                                   tonic: tonic, bp: bp)
            let mapper = BowControlMapper()
            let engine = BowEngine(tables: tables, mapper: mapper, bp: bp,
                                   sr: sr, rfir: [],
                                   eLp: bp.v("bow_rad_lp", 8000.0),
                                   reverbRT60: bp.v("bow_rev_rt60", 1.0),
                                   reverbPredelayMs: 15.0,
                                   reverbMix: 0.0, reverbWidth: 0.0)
            engine.outGain = bp.v("bow_live_trim", 0.175)
            engine.setTwang(1.0)
            engine.setTwangShape(kneeR: 0.7, depth: 0.08, relMs: 40,
                                 rollSmp: 6.0, bright: 2.5, ring: 0.95,
                                 gut: 0.8)
            var l = [Double](repeating: 0, count: 1024)
            var r = [Double](repeating: 0, count: 1024)
            var out: [Double] = []
            mapper.setAxis(expr: expr, press: 0.562, pos: 0.45)
            mapper.midi(0x90, 60, 100)
            var phase = [(0.25, true), (2.75, false)]
            for (secs, noteOffAfter) in phase {
                var left = Int(secs * sr)
                while left > 0 {
                    let m = min(1024, left)
                    l.withUnsafeMutableBufferPointer { lb in
                        r.withUnsafeMutableBufferPointer { rb in
                            engine.render(frames: m, outL: lb.baseAddress!,
                                          outR: rb.baseAddress!)
                        }
                    }
                    for i in 0..<m { out.append(0.5 * (l[i] + r[i])) }
                    left -= m
                }
                if noteOffAfter { mapper.midi(0x80, 60, 0) }
            }
            _ = phase
            try dump("expr\(ei).f64", out)
        }
    }
}
