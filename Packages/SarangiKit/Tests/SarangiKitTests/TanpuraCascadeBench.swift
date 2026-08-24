import XCTest
@testable import SarangiKit

/// Register-calibration bench (2026-08-15) — renders single plucks per
/// register/drive/thread-height to raw float64 files for offline
/// analysis of buzz share, cascade ladder times and pitch cost. This is
/// the harness the `TanpuraTables.registerCompThreadMul` targets were
/// measured on — RE-RUN IT (TANPURA_BENCH_LIFT sweep, then
/// TANPURA_BENCH_LAW validation) whenever the artifact's thread/bone
/// geometry regenerates. Not a guard; skipped unless TANPURA_BENCH_DIR
/// is set.
final class TanpuraCascadeBench: XCTestCase {
    func testRenderBenchSet() throws {
        guard let outDir = ProcessInfo.processInfo
            .environment["TANPURA_BENCH_DIR"] else {
            throw XCTSkip("bench disabled (set TANPURA_BENCH_DIR)")
        }
        guard let p = Presets.tanpuraParams() else {
            throw XCTSkip("artifact missing")
        }
        let secs = 8.0
        // (register, threadHMul, drives) probe grid — mul 1 anchors;
        // TANPURA_BENCH_LAW renders the shipped registerComp law instead
        let env = ProcessInfo.processInfo.environment
        // bench-only params variant via Codable round-trip
        func mutatedParams(_ base: TanpuraParams,
                           _ edit: [String: Double]) throws -> TanpuraParams {
            let data = try JSONEncoder().encode(base)
            var obj = try JSONSerialization.jsonObject(with: data)
                as! [String: Any]
            for (k, v) in edit { obj[k] = v }
            let d2 = try JSONSerialization.data(withJSONObject: obj)
            return try JSONDecoder().decode(TanpuraParams.self, from: d2)
        }
        var lawParams: [Double: TanpuraParams] = [:]
        // TANPURA_BENCH_CASC: cascade-speed probes at the comp law —
        // pluck-draw length (rampCycles), HF damping (t60hf), and a
        // jiva-gap offset, each alone. Params varied via Codable
        // round-trip (bench-only).
        if env["TANPURA_BENCH_CASC"] != nil {
            func mutated(_ edit: [String: Double]) throws -> TanpuraParams {
                try mutatedParams(p, edit)
            }
            var cases: [(String, Double, TanpuraParams, Double, Double)] = []
            let combos: [(Double, [(Double, Double, Double)])] = [
                (156.0, [(0.010, 1.5, 0.6), (0.010, 1.5, 0.45),
                         (0.010, 2.0, 0.3)]),
                (208.0, [(0.020, 2.0, 0.7), (0.020, 2.0, 0.5)]),
                (262.0, [(0.020, 2.0, 0.7)]),
            ]
            for (f0, list) in combos {
                let lawMul = TanpuraTables.registerCompThreadMul(
                    f0: f0, comp: 1.0, p: p)
                for (dm, tm, dr) in list {
                    let tag = "g\(Int(dm * 1000))t\(Int(tm * 10))"
                        + "d\(Int(dr * 100))"
                    cases.append((tag, f0,
                                  try mutated(["t60hf": p.t60hf * tm]),
                                  lawMul + dm, dr))
                }
            }
            for (tag, f0, pv, mul, dr) in cases {
                guard let e = TanpuraEngine(params: pv, frequencies: [f0],
                                            workers: 1,
                                            threadHMul: { _ in mul }) else {
                    return XCTFail("build failed \(tag) \(f0)")
                }
                e.pluck(slot: 0, velocity: 100, touch: 1.0, drive: dr)
                let n = Int(secs * p.sr)
                var l = [Double](repeating: 0, count: n)
                var r = [Double](repeating: 0, count: n)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: n, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                let url = URL(fileURLWithPath: outDir)
                    .appendingPathComponent(
                        "casc_f\(Int(f0))_\(tag).f64")
                l.withUnsafeBufferPointer {
                    try? Data(buffer: $0).write(to: url)
                }
            }
            return
        }
        var grid: [(Double, Double, [Double])] = []
        // TANPURA_BENCH_REPLUCK: repeated same-slot plucks at IRREGULAR
        // intervals (touch 1) — per-pluck early-window level spread is
        // the re-pluck volume-consistency metric (periodic grids hide
        // the ghost/fresh phase interference).
        if env["TANPURA_BENCH_REPLUCK"] != nil {
            for f0 in [104.0, 208.0] {
                let mul = TanpuraTables.registerCompThreadMul(
                    f0: f0, comp: 1.0, p: p)
                guard let e = TanpuraEngine(params: p, frequencies: [f0],
                                            workers: 1,
                                            threadHMul: { _ in mul }) else {
                    return XCTFail("build failed at \(f0)")
                }
                // odd, non-period-multiple gaps (seconds)
                let gaps = [0.0, 1.13, 1.41, 1.87, 1.19, 1.63, 1.31]
                var acc = [Double]()
                for g in gaps {
                    let ng = Int(g * p.sr)
                    if ng > 0 {
                        var l = [Double](repeating: 0, count: ng)
                        var r = [Double](repeating: 0, count: ng)
                        l.withUnsafeMutableBufferPointer { lb in
                            r.withUnsafeMutableBufferPointer { rb in
                                e.render(frames: ng, outL: lb.baseAddress!,
                                         outR: rb.baseAddress!)
                            }
                        }
                        acc.append(contentsOf: l)
                    }
                    e.pluck(slot: 0, velocity: 100, touch: 1.0)
                }
                let nTail = Int(3.0 * p.sr)
                var l = [Double](repeating: 0, count: nTail)
                var r = [Double](repeating: 0, count: nTail)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: nTail, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                acc.append(contentsOf: l)
                let url = URL(fileURLWithPath: outDir)
                    .appendingPathComponent("repluck_f\(Int(f0)).f64")
                acc.withUnsafeBufferPointer {
                    try? Data(buffer: $0).write(to: url)
                }
            }
            return
        }
        if env["TANPURA_BENCH_LAW"] != nil {
            // the shipped composition: registerComp + cascade lift
            // (TANPURA_BENCH_CASCADE=0 disables the cascade half)
            let casc = Double(env["TANPURA_BENCH_CASCADE"] ?? "1") ?? 1
            for f0 in [104.0, 140.0, 156.0, 208.0, 262.0, 350.0] {
                let m = min(1.0,
                            TanpuraTables.registerCompThreadMul(
                                f0: f0, comp: 1.0, p: p)
                            + TanpuraTables.cascadeThreadLift(
                                f0: f0, cascade: casc, p: p))
                let pv = casc > 0
                    ? try mutatedParams(p, ["t60hf": p.t60hf
                        * TanpuraTables.cascadeHFT60Mul(f0: f0,
                                                        cascade: casc)])
                    : p
                grid.append((f0, m, [1.0]))
                lawParams[f0] = pv
            }
        } else if env["TANPURA_BENCH_LIFT"] != nil {
            let pts: [(Double, [Double])] = [
                (140.0, [0.94, 0.96, 0.98]),
                (156.0, [0.93, 0.95, 0.97]),
                (176.0, [0.92, 0.94, 0.96]),
                (208.0, [0.92, 0.96]),
                (262.0, [0.88, 0.90, 0.94]),
            ]
            for (f0, muls) in pts {
                for m in muls { grid.append((f0, m, [1.0])) }
            }
        } else {
            for f0 in [78.0, 104.0, 156.0, 208.0] {
                grid.append((f0, 1.0, [1.0, 1.8, 2.8]))
            }
        }
        for (f0, mul, drives) in grid {
            guard let e = TanpuraEngine(params: lawParams[f0] ?? p,
                                        frequencies: [f0],
                                        workers: 1,
                                        threadHMul: { _ in mul }) else {
                return XCTFail("build failed at \(f0)")
            }
            for d in drives {
                // fresh state per render: touch 1 resets to the wrap
                e.pluck(slot: 0, velocity: 100, touch: 1.0, drive: d)
                let n = Int(secs * p.sr)
                var l = [Double](repeating: 0, count: n)
                var r = [Double](repeating: 0, count: n)
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        e.render(frames: n, outL: lb.baseAddress!,
                                 outR: rb.baseAddress!)
                    }
                }
                let mtag = mul == 1.0 ? ""
                    : "_m\(String(format: "%.2f", mul))"
                let url = URL(fileURLWithPath: outDir)
                    .appendingPathComponent(
                        "bench_f\(Int(f0))\(mtag)_d\(String(format: "%.1f", d)).f64")
                l.withUnsafeBufferPointer {
                    try? Data(buffer: $0).write(to: url)
                }
                // let the ring die before the next drive point
                e.release(slot: 0, rate: log(1000.0) / 0.05)
                var tl = [Double](repeating: 0, count: 4096)
                var tr = [Double](repeating: 0, count: 4096)
                for _ in 0..<24 {
                    tl.withUnsafeMutableBufferPointer { lb in
                        tr.withUnsafeMutableBufferPointer { rb in
                            e.render(frames: 4096, outL: lb.baseAddress!,
                                     outR: rb.baseAddress!)
                        }
                    }
                }
            }
        }
    }
}
