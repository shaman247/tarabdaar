import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Realtime budget: full polyphony with every binding moving renders inside the device buffer's wall clock. Serial (phase 2 of tools/test-full.sh) — flakes under CPU contention.
final class RealtimePerformanceTests: XCTestCase {
    override func setUpWithError() throws { try skipUnlessSlowTestsEnabled() }

    /// The twelve-string raga bank meets paced callback and worker deadlines with the chromatic choir.
    func testDualTarafFullBankRealtime() throws {
        try checkFullBank(ragaCount: 12)
    }

    private func checkFullBank(ragaCount: Int) throws {
        let source = StringVoiceSource()
        let defaults = Presets.state(.sarangiPilu).resolvedStrings
        let raga = defaults.filter { !$0.chromatic }
        let chromatic = defaults.filter(\.chromatic)
        let strings = raga+chromatic
        let engine = try XCTUnwrap(StringVoiceSource.buildEngine(tonicHz: 328.9,
            strings: strings, mapper: source.mapper, overrides: ["bow_jt_couple": 1]))
        let rows = engine.jtDualRows.sorted()
        XCTAssertEqual(rows.count, ragaCount)
        source.setEngine(engine, crossfadeMs: 0)
        let frames = Int(Config.preferredOutputBufferFrames), scale = 256/frames
        let count = 900*scale, interval = Double(frames)/48000
        var left = [Float](repeating: 0, count: frames), right = left
        var times = [Double](), before = engine.jtAsyncStats()
        let start = ProcessInfo.processInfo.systemUptime
        for block in 0..<count {
            if block == 100*scale {
                before = engine.jtAsyncStats()
                source.mapper.setAxis(expr: 1, press: 0.8)
                source.mapper.touchOn(1, pitchSemis: 64)
                source.mapper.touchOn(2, pitchSemis: 71)
                source.mapper.touchOn(3, pitchSemis: 76)
            }
            if block >= 100*scale && block < 400*scale && block % (80*scale) == 20*scale {
                for row in rows { engine.pluckTaraf(row: row) }
            }
            if block % (40*scale) == 0 {
                source.setControl("bow_jt_dual_select", Double(block % (200*scale))/Double(200*scale))
            }
            if block == 200*scale { source.setControl("bow_jt_dual_lp", 4000) }
            if block == 500*scale { source.setControl("bow_jt_dual_lp", 20000) }
            if block == 400*scale { for id in 1...3 { source.mapper.touchOff(UInt16(id)) } }
            let now = ProcessInfo.processInfo.systemUptime
            source.renderForTesting(frames: frames, into: &left, &right)
            if block >= 100*scale { times.append(ProcessInfo.processInfo.systemUptime-now) }
            XCTAssertTrue(left.allSatisfy(\.isFinite))
            let remaining = start+Double(block+1)*interval-ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        times.sort()
        let after = engine.jtAsyncStats(), p99 = times[Int(Double(times.count)*0.99)]
        print("DUAL full bank rows", engine.jtRowFreqs.count, "dual rows", rows.map { $0+1 },
            "p99ms", p99*1000, "maxMs", times.last!*1000, "budgetMs", interval*1000,
            "drops", after.drops-before.drops, "flat", after.flat-before.flat,
            "solver", engine.jtDualStats())
        XCTAssertLessThan(p99, interval)
        XCTAssertEqual(after.drops, before.drops)
        XCTAssertEqual(after.flat, before.flat)
        XCTAssertEqual(engine.jtDualStats()[1], 0)
    }

    // MARK: - Rig

    /// Mirrors `AppController`'s routing: `.live` straight to the engine,
    /// `.hybrid` through its scaler, in-place keys pushed onto the running
    /// engine, anything else through a rebuild.
    private final class Rig {
        let src = StringVoiceSource()
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        var overrides: [String: Double] = [:]
        var engine: BowEngine?
        var rebuilds = 0
        private var headroom: [String: Double] = [:]

        init?() {
            guard let e = StringVoiceSource.buildEngine(
                tonicHz: 328.9, strings: strings, mapper: src.mapper) else {
                return nil
            }
            engine = e
            src.setEngine(e, crossfadeMs: 0)
            guard let bp = Presets.bowedStringParams() else { return nil }
            for spec in ParamRegistry.all where spec.apply == .hybrid {
                headroom[spec.key] = bp.num[spec.key] ?? spec.def
            }
        }

        func apply(_ key: String, _ value: Double) {
            guard let spec = ParamRegistry.spec(key) else { return }
            switch spec.apply {
            case .live:
                switch key {
                case "bow_expr":      src.mapper.setAxis(expr: value)
                case "bow_press":     src.mapper.setAxis(press: value)
                case "bow_pos":       src.mapper.setAxis(pos: value)
                case "bow_tilt":      src.mapper.setAxis(tilt: value)
                case "bow_jt_lp":     src.setJtToneLp(hz: value >= 20000 ? 0 : value)
                case "bow_jt_damp":   src.setTarafDamp(value)
                case "bow_tone_tilt": src.setToneTilt(value)
                default: break
                }
            case .hybrid:
                let h = headroom[key] ?? spec.def
                if h > 1e-12, value <= h {
                    // vibrato's scaler IS the vibrato axis, the one
                    // `AudioEngine.setStringVibrato` drives
                    src.mapper.setVibrato(value / h)
                    return
                }
                push(key, value)
            case .rebuild:
                push(key, value)
            }
        }

        private func push(_ key: String, _ value: Double) {
            overrides[key] = value
            if ParamRegistry.appliesInPlace(key) {
                _ = src.applyLiveParams(
                    tonicHz: 328.9, strings: strings, overrides: overrides,
                    needsJawariTables: key.hasPrefix("bow_jt"))
            } else {
                // the slow path: rebuild off-thread, publish with the
                // crossfade — same as `AudioEngine.rebuildStringVoice`
                rebuilds += 1
                if let e = StringVoiceSource.buildEngine(
                    tonicHz: 328.9, strings: strings, mapper: src.mapper,
                    overrides: overrides) {
                    engine = e
                    src.setEngine(e)
                }
            }
        }
    }

    // MARK: - Analysis

    private struct Result {
        var buffers = 0
        var overruns = 0
        var worstMs = 0.0
        var p50Ms = 0.0
        var p99Ms = 0.0
        var budgetMs = 0.0
        var worstStepRatio = 0.0
        var dropouts = 0
        var peak = 0.0
        var rebuilds = 0
    }

    /// Run one scenario; `drive` is called at ~60 Hz and moves what it tests.
    private func perform(seconds: Double, frames: Int,
                         noteOn: [(at: Double, note: UInt8)],
                         noteOff: [(at: Double, note: UInt8)],
                         drive: (Rig, Double) -> Void) throws -> Result {
        guard let rig = Rig() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        let sr = rig.src.modelSR
        var r = Result()
        r.budgetMs = Double(frames) / sr * 1000.0
        rig.src.mapper.setAxis(expr: 40.0 / 127.0)  // expression, as the pads do
        // let the voice settle before the measured window
        for _ in 0..<8 { _ = rig.src.renderForTesting(frames: 4096) }

        let total = Int(seconds * sr)
        var done = 0, nextTilt = 0.0
        var onIdx = 0, offIdx = 0
        var prev = 0.0, prevStep = 0.0
        var steps: [Double] = []
        var window: [Double] = []
        var windowRms: [Double] = []
        var noteHeld = false
        // preallocated: a malloc per buffer would masquerade as jitter
        var bufL = [Float](repeating: 0, count: frames)
        var bufR = [Float](repeating: 0, count: frames)
        var times: [Double] = []

        while done < total {
            let t = Double(done) / sr
            while onIdx < noteOn.count, noteOn[onIdx].at <= t {
                rig.src.mapper.touchOn(UInt16(noteOn[onIdx].note),
                                       pitchSemis: Double(noteOn[onIdx].note))
                noteHeld = true; onIdx += 1
            }
            while offIdx < noteOff.count, noteOff[offIdx].at <= t {
                rig.src.mapper.touchOff(UInt16(noteOff[offIdx].note))
                offIdx += 1
                if offIdx >= noteOff.count { noteHeld = false }
            }
            if t >= nextTilt {
                drive(rig, t)                       // 60 Hz control rate
                nextTilt += 1.0 / 60.0
            }
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            rig.src.renderForTesting(frames: frames, into: &bufL, &bufR)
            let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
            r.buffers += 1
            times.append(ms)
            r.worstMs = max(r.worstMs, ms)
            if ms > r.budgetMs { r.overruns += 1 }
            for i in 0..<frames {
                let v = Double(bufL[i]) + Double(bufR[i])
                r.peak = max(r.peak, abs(v))
                let step = abs(v - prev)
                steps.append(step)
                prevStep = step
                _ = prevStep
                prev = v
                window.append(v)
                if window.count == Int(sr * 0.01) {      // 10 ms
                    let rms = (window.reduce(0) { $0 + $1 * $1 }
                               / Double(window.count)).squareRoot()
                    windowRms.append(rms)
                    window.removeAll(keepingCapacity: true)
                }
            }
            done += frames
        }
        // click metric: worst step against the 99.9th percentile of steps
        // (the signal's own fastest legitimate motion)
        let sorted = steps.sorted()
        let p999 = sorted[min(sorted.count - 1,
                              Int(Double(sorted.count) * 0.999))]
        r.worstStepRatio = p999 > 0 ? (sorted.last! / p999) : 0
        // dropout metric: a 10 ms window below 5% of the median while the
        // note is sounding
        if noteHeld, windowRms.count > 4 {
            let med = windowRms.sorted()[windowRms.count / 2]
            r.dropouts = windowRms.dropFirst(2).dropLast(2)
                .filter { $0 < 0.05 * med }.count
        }
        r.rebuilds = rig.rebuilds
        let ts = times.sorted()
        r.p50Ms = ts[ts.count / 2]
        r.p99Ms = ts[min(ts.count - 1, Int(Double(ts.count) * 0.99))]
        return r
    }

    private func check(_ name: String, _ r: Result,
                       maxStepRatio: Double = 6.0) {
        print(String(format: """
            %@
              %d buffers @ %.2f ms budget
              render p50 %.3f ms (%.0f%%) · p99 %.3f ms (%.0f%%) · max %.3f ms (%.0f%%)
              over budget: %d buffers (%.2f%%)
              peak %.4f · worst step / p99.9 step %.1fx · dropouts %d
            """, name, r.buffers, r.budgetMs,
            r.p50Ms, 100 * r.p50Ms / r.budgetMs,
            r.p99Ms, 100 * r.p99Ms / r.budgetMs,
            r.worstMs, 100 * r.worstMs / r.budgetMs,
            r.overruns, 100 * Double(r.overruns) / Double(max(r.buffers, 1)),
            r.peak, r.worstStepRatio, r.dropouts))
        // p99 is the honest bar: this process runs at NORMAL priority, so
        // isolated maxima include scheduling a realtime thread would not see.
        XCTAssertLessThan(r.p99Ms, r.budgetMs,
                          "\(name): p99 render exceeds the realtime budget")
        XCTAssertEqual(r.dropouts, 0, "\(name): audio dropped out")
        XCTAssertLessThan(r.worstStepRatio, maxStepRatio,
                          "\(name): discontinuity in the output")
        XCTAssertGreaterThan(r.peak, 1e-3, "\(name): no sound was produced")
    }

    // MARK: - Scenarios

    private var frames: Int { Int(Config.preferredOutputBufferFrames) }

    /// Everything at once: several notes sounding while a tilt drives live
    /// axes, in-place physics and the jawari tables together.
    func testPolyphonicWithEverythingMoving() throws {
        let r = try perform(
            seconds: 5.0, frames: frames,
            noteOn: [(0.05, 55), (0.6, 59), (1.2, 62), (1.8, 66)],
            noteOff: [(4.6, 55), (4.7, 59), (4.8, 62), (4.9, 66)]) { rig, t in
            let x = 0.5 - 0.5 * cos(2 * Double.pi * t / 2.5)
            rig.apply("bow_expr", 0.2 + 0.3 * x)            // live
            rig.apply("bow_pos", 0.25 + 0.5 * x)            // live
            rig.apply("bow_mu_s", 0.6 + 0.5 * x)            // scalar
            rig.apply("bow_body_q", 10 + 40 * x)            // body coeffs
            rig.apply("bow_jt_drive", 0.01 + 0.08 * x)      // live (kernel slew)
            rig.apply("bow_jt_apex", (0.6 + 0.8 * x) * 1e-5) // jawari tables
        }
        check("POLYPHONIC + EVERYTHING MOVING", r)
    }

}
