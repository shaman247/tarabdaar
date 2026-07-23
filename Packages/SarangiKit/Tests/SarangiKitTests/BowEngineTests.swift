import XCTest
@testable import SarangiKit

/// Live-shaped smoke test of the full bow path: Swift-built tables (the
/// table-parity golden's inputs) → streaming kernel → decimate → radiation
/// FIR → E_lp → reverb, driven by the CONTROL MAPPER like the app (noteOn →
/// sound; silence before). Complements BowTableParityTests (numbers) and
/// BowLiveEndToEndTests (env-gated reference compare) by exercising
/// bow_init/bow_process/decimator/post-chain inside the default suite.
final class BowEngineTests: XCTestCase {

    private func loadConfig() throws -> (BowTuning, BowNetParams, BowParams) {
        guard let url = Bundle.module.url(forResource: "bow_tables_default",
                                          withExtension: "json",
                                          subdirectory: "Goldens"),
              let obj = try? JSONSerialization.jsonObject(
                  with: Data(contentsOf: url)) as? [String: Any],
              let tj = obj["tuning"] as? [String: Any],
              let qj = obj["q"] as? [String: Any],
              let bpj = obj["bp"] as? [String: Any],
              let tonic = (tj["tonic"] as? NSNumber)?.doubleValue,
              let rows = tj["strings"] as? [[Any]],
              let bp = BowParams(json: bpj) else {
            throw XCTSkip("bow_tables_default golden not found")
        }
        let strings = rows.compactMap {
            row -> (f: Double, gain: Double, t60: Double, bright: Bool)? in
            guard row.count >= 4,
                  let f = (row[0] as? NSNumber)?.doubleValue,
                  let g = (row[1] as? NSNumber)?.doubleValue,
                  let t = (row[2] as? NSNumber)?.doubleValue,
                  let b = row[3] as? NSNumber else { return nil }
            return (f, g, t, b.boolValue)
        }
        let cls = (tj["string_class"] as? [Any])?.compactMap { $0 as? String }
        let absIdx = Set(((tj["t60_abs_idx"] as? [Any]) ?? [])
            .compactMap { ($0 as? NSNumber)?.intValue })
        var q = BowNetParams()
        q.merge(json: qj)
        return (BowTuning(tonic: tonic, strings: strings, stringClass: cls,
                          t60AbsIdx: absIdx),
                q, bp)
    }

    func testMapperDrivenRenderMakesSound() throws {
        var (tuning, q, bp) = try loadConfig()
        // live policy (BowSetup.load): start from silence
        bp.num["bow_precharge"] = 0.0
        let sr = 48000.0
        let osf = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        let tables = BowTables.build(sr: sr * Double(osf), tuning: tuning,
                                     q: q, bp: bp, nBow: 1.0)
        let mapper = BowControlMapper()
        let engine = BowEngine(tables: tables, mapper: mapper, bp: bp, sr: sr,
                               rfir: q.rfir48, eLp: q.v("E_lp", 20000.0),
                               reverbRT60: q.v("F_rt60", 1.2),
                               reverbPredelayMs: q.v("F_predelay", 20.0),
                               reverbMix: q.v("F_mix", 0.12),
                               reverbWidth: 0.0)
        engine.outGain = BowEngine.liveLevelTrim

        var l = [Double](repeating: 0, count: 1024)
        var r = [Double](repeating: 0, count: 1024)
        func rms(seconds: Double) -> Double {
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
                    XCTAssertTrue(l[i].isFinite && r[i].isFinite)
                    let s = l[i] + r[i]
                    acc += s * s
                }
                n += m
                left -= m
            }
            return (acc / Double(n)).squareRoot()
        }

        // silence before the first note (no pre-charge live)
        let idle = rms(seconds: 0.25)
        XCTAssertLessThan(idle, 1e-6, "bow engine not silent before note-on")

        // bow a note: sound must appear and sit near the live level target
        // (the trim calibrates the fixture's 0.1; a single mf note lands
        // within an order of magnitude, clip-free)
        mapper.midi(0x90, 69, 100)
        _ = rms(seconds: 0.3)                       // speak/settle
        let t0 = CFAbsoluteTimeGetCurrent()
        let sustain = rms(seconds: 1.0)
        let dt = CFAbsoluteTimeGetCurrent() - t0
        print(String(format: "bow live smoke: sustain rms %.4f, 1 s render " +
                     "in %.2f s (%.1fx realtime, this build config)",
                     sustain, dt, 1.0 / dt))
        // threshold recalibrated 2026-07-16i: the resynced tap DUCK
        // (tdirUni 0.15) lowers the driven-unison taraf tap while
        // bowing — the intended Pa-bloom physics
        XCTAssertGreaterThan(sustain, 0.003, "bowed note made no sound")
        XCTAssertLessThan(sustain, 0.9, "bowed note at clipping level")

        // release: the gate closes and the ring decays well below sustain
        mapper.midi(0x80, 69, 0)
        _ = rms(seconds: 1.5)
        let tail = rms(seconds: 0.5)
        XCTAssertLessThan(tail, sustain * 0.5, "note did not release")
    }
}
