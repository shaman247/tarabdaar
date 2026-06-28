import XCTest
@testable import SarangiKit

/// Measurement harness for the "second peak" / onset-lag problem: render a
/// staccato note through the LIVE path (`renderSample` + `SignalAmpFollower`, as
/// Starpad's AudioEngine does), decompose the output into its components by
/// toggling the mix scalars (dry / bank / jawari / drone), and report when each
/// component's amplitude envelope PEAKS relative to the dry "main voice". A
/// responsive sarangi has the sym components peaking ~with the dry, not after.
///
/// Run: `swift test --filter OnsetLag` (prints a report). WAVs for listening are
/// written to auditions/outputs/.
final class OnsetLagTests: XCTestCase {
    let sr = 44100.0

    // MARK: - Test signal: a bowed staccato proxy

    /// Sawtooth-ish bowed tone (Σ sin(h)/h) with a fast attack + exponential
    /// decay (a short staccato bow stroke), then silence to capture any late
    /// sympathetic bloom.
    func staccato(f0: Double, peak: Double = 0.3,
                  attackMs: Double = 3, decayMs: Double = 22,
                  noteMs: Double = 70, totalMs: Double = 700) -> [Double] {
        let n = Int(totalMs / 1000 * sr)
        let nNote = Int(noteMs / 1000 * sr)
        let atk = Int(attackMs / 1000 * sr)
        let decA = exp(-1.0 / (sr * decayMs / 1000))
        var env = 0.0
        var x = [Double](repeating: 0, count: n)
        let H = 16
        for i in 0..<n {
            // amplitude envelope: linear attack, exp decay, gated off after note
            if i < atk { env = Double(i) / Double(atk) }
            else if i < nNote { env *= decA }
            else { env = 0 }
            if env <= 0 { continue }
            var s = 0.0
            let t = Double(i) / sr
            for h in 1...H { s += sin(2 * Double.pi * Double(h) * f0 * t) / Double(h) }
            x[i] = peak * env * s / 1.5
        }
        return x
    }

    // MARK: - Render the live path with isolated components

    /// Render `input` through a fresh engine, keeping only the named output
    /// component (`dry`/`bank`/`jaw`/`drone`) by zeroing the other mix scalars
    /// (`all` keeps everything). Mirrors AudioEngine's per-sample loop.
    func render(_ input: [Double], _ state: InstrumentState, keep: String,
                bowFollow: Double? = nil) -> [Double] {
        let e = SarangiEngine(params: state.params, strings: state.resolvedStrings,
                              tonic: state.tonicHz, sr: sr, firTaps: state.fir)
        if let bowFollow { e.scalars.symBowFollow = bowFollow }
        if keep != "all" {
            if keep != "dry" { e.scalars.mixDry = 0 }
            if keep != "bank" { e.scalars.mixBank = 0 }
            if keep != "jaw" { e.scalars.mixJaw = 0 }
        }
        e.beginBuffer()
        var follower = SignalAmpFollower(sr: sr)
        var out = [Double](repeating: 0, count: input.count)
        for i in input.indices {
            let amp = follower.process(input[i])
            let (l, r) = e.renderSample(input[i], amp: amp)
            out[i] = 0.5 * (l + r)
        }
        return out
    }

    // MARK: - Envelope + metrics

    func envelope(_ x: [Double], tauMs: Double = 8) -> [Double] {
        let a = exp(-1.0 / (sr * tauMs / 1000))
        var y = 0.0
        var e = [Double](repeating: 0, count: x.count)
        for i in x.indices { y = (1 - a) * abs(x[i]) + a * y; e[i] = y }
        return e
    }

    func argmax(_ x: [Double]) -> Int {
        var bi = 0, bv = -Double.infinity
        for i in x.indices where x[i] > bv { bv = x[i]; bi = i }
        return bi
    }

    func centroidMs(_ x: [Double]) -> Double {
        var s = 0.0, sw = 0.0
        for i in x.indices { s += Double(i) * x[i]; sw += x[i] }
        return sw > 0 ? (s / sw) / sr * 1000 : 0
    }

    /// Largest local maximum AFTER the global peak, as a fraction of the global
    /// peak (the "is there a distinct second peak" measure: 0 = monotonic decay).
    func secondPeakProminence(_ env: [Double]) -> Double {
        let g = argmax(env)
        guard env[g] > 0 else { return 0 }
        var dip = env[g], dipIdx = g
        for i in g..<env.count where env[i] < dip { dip = env[i]; dipIdx = i }
        var pk2 = dip
        for i in dipIdx..<env.count { pk2 = Swift.max(pk2, env[i]) }
        return (pk2 - dip) / env[g]
    }

    /// Coarse ASCII envelope plot (60 bins, peak-normalised to its own max).
    func sparkline(_ env: [Double], bins: Int = 60) -> String {
        let chars = Array(" .:-=+*#%@")
        let peak = env.max() ?? 1
        guard peak > 1e-12 else { return String(repeating: " ", count: bins) }
        let step = env.count / bins
        var s = ""
        for b in 0..<bins {
            var m = 0.0
            for i in (b * step)..<min((b + 1) * step, env.count) { m = Swift.max(m, env[i]) }
            s.append(chars[Int((m / peak) * Double(chars.count - 1))])
        }
        return s
    }

    // MARK: - The report

    func testOnsetLagReport() {
        let state = Presets.state(.pair1)        // E♭ harmonic minor (the deployed default)
        let f0 = state.tonicHz
        let input = staccato(f0: f0)

        // Component breakdown at the free-ring baseline (bowFollow = 0) so the
        // diagnosis isolates the bank's intrinsic ring.
        let dry = render(input, state, keep: "dry", bowFollow: 0)
        let bank = render(input, state, keep: "bank", bowFollow: 0)
        let jaw = render(input, state, keep: "jaw", bowFollow: 0)
        let full = render(input, state, keep: "all", bowFollow: 0)

        let inEnv = envelope(input)
        let dryEnv = envelope(dry)
        let dryPeakMs = Double(argmax(dryEnv)) / sr * 1000

        func peakMs(_ x: [Double]) -> Double { Double(argmax(envelope(x))) / sr * 1000 }

        print("\n=== Sarangi onset-lag report (pair1, staccato @ \(String(format: "%.1f", f0)) Hz) ===")
        print(String(format: "input (base violin)   peak %6.1f ms", Double(argmax(inEnv)) / sr * 1000))
        print(String(format: "dry  (main voice)     peak %6.1f ms   centroid %6.1f ms", dryPeakMs, centroidMs(dryEnv)))
        for (name, sig) in [("bank ", bank), ("jaw  ", jaw)] {
            let env = envelope(sig)
            let lag = peakMs(sig) - dryPeakMs
            let clag = centroidMs(env) - centroidMs(dryEnv)
            print(String(format: "%@ (sym)            peak %6.1f ms   lag %+6.1f ms   centroid-lag %+6.1f ms",
                         name, peakMs(sig), lag, clag))
        }
        let fullEnv = envelope(full)
        let prom = secondPeakProminence(fullEnv)
        print(String(format: "FULL mix              peak %6.1f ms   lag %+6.1f ms   2nd-peak prominence %.3f",
                     peakMs(full), peakMs(full) - dryPeakMs, prom))
        print("(2nd-peak prominence: 0 = single clean decay; higher = a distinct late bloom)")

        // Perceptual grouping: main = bowed note (dry + jawari buzz),
        // sym = sympathetic shimmer (the bank).
        let main = zip(dry, jaw).map(+)
        let symv = bank
        let mainEnv = envelope(main), symEnv = envelope(symv)
        let mainPk = peakMs(main), symPk = peakMs(symv)
        // late-energy: sym energy AFTER the main has decayed below 25% of its peak.
        let mPeak = mainEnv.max() ?? 1
        let mPeakIdx = argmax(mainEnv)
        var endIdx = mainEnv.count - 1
        for i in mPeakIdx..<mainEnv.count where mainEnv[i] < 0.25 * mPeak { endIdx = i; break }
        let symTot = symv.reduce(0) { $0 + $1 * $1 }
        let symLate = symv[endIdx...].reduce(0) { $0 + $1 * $1 }
        print(String(format: "\nMAIN (dry+jaw)        peak %6.1f ms   centroid %6.1f ms", mainPk, centroidMs(mainEnv)))
        print(String(format: "SYM  (bank+drone)     peak %6.1f ms   centroid %6.1f ms   PEAK-LAG %+6.1f ms",
                     symPk, centroidMs(symEnv), symPk - mainPk))
        print(String(format: "sym energy after main falls <25%%:  %.1f%% of sym total  (the perceived late bloom)",
                     symTot > 0 ? 100 * symLate / symTot : 0))
        print("\nenvelope timeline (each row peak-normalised; 0…\(Int(Double(main.count) / sr * 1000)) ms):")
        print("  main  " + sparkline(mainEnv))
        print("  sym   " + sparkline(symEnv))

        // Validate the fix: sweep `sym_bow_follow` and watch the sym after-ring
        // (the late-energy %) collapse while the in-note peak stays put.
        print("\nsym_bow_follow sweep — sym (bank) gated toward the bow envelope:")
        for f in [0.0, 0.3, 0.6, 1.0] {
            let b = render(input, state, keep: "bank", bowFollow: f)
            let be = envelope(b)
            let tot = b.reduce(0) { $0 + $1 * $1 }
            let late = b[endIdx...].reduce(0) { $0 + $1 * $1 }
            print(String(format: "  follow %.1f   peak %5.1f ms   late-energy %4.1f%%   %@",
                         f, Double(argmax(be)) / sr * 1000, tot > 0 ? 100 * late / tot : 0,
                         sparkline(be, bins: 48)))
        }
        print("")

        // WAVs for listening.
        let dir = "/Users/isha/Desktop/starpad/auditions/outputs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writeWav("\(dir)/input.wav", input)
        writeWav("\(dir)/full.wav", full)
        writeWav("\(dir)/dry.wav", dry)
        writeWav("\(dir)/sym.wav", bank)
        print("WAVs → \(dir)/{input,full,dry,sym}.wav")
    }

    // MARK: - Chorus / delay diagnosis

    /// Strongest envelope-autocorrelation peak in [minMs, maxMs] — a discrete
    /// delayed copy (slapback / pre-echo) shows up as a peak at the delay lag.
    func echo(_ env: [Double], minMs: Double = 8, maxMs: Double = 90) -> (lagMs: Double, strength: Double) {
        let mean = env.reduce(0, +) / Double(env.count)
        let e = env.map { $0 - mean }
        let e0 = e.reduce(0) { $0 + $1 * $1 } + 1e-12
        var bestLag = 0, bestV = 0.0
        for lag in Int(minMs / 1000 * sr)...Int(maxMs / 1000 * sr) {
            var s = 0.0
            for i in 0..<(e.count - lag) { s += e[i] * e[i + lag] }
            let v = s / e0
            if v > bestV { bestV = v; bestLag = lag }
        }
        return (Double(bestLag) / sr * 1000, bestV)
    }

    func renderStereo(_ input: [Double], _ state: InstrumentState, _ tweak: (SarangiEngine) -> Void) -> (l: [Double], r: [Double]) {
        let e = SarangiEngine(params: state.params, strings: state.resolvedStrings,
                              tonic: state.tonicHz, sr: sr, firTaps: state.fir, fx: state.fx)
        tweak(e)
        e.beginBuffer()
        var f = SignalAmpFollower(sr: sr)
        var L = [Double](repeating: 0, count: input.count)
        var R = [Double](repeating: 0, count: input.count)
        for i in input.indices {
            let amp = f.process(input[i])
            let (l, r) = e.renderSample(input[i], amp: amp)
            L[i] = l; R[i] = r
        }
        return (L, R)
    }

    /// L/R decorrelation: rms(L−R) / rms(L+R). 0 = mono; higher = wider/chorus-y.
    func decorrelation(_ l: [Double], _ r: [Double]) -> Double {
        var sd = 0.0, ss = 0.0
        for i in l.indices { let d = l[i] - r[i], s = l[i] + r[i]; sd += d * d; ss += s * s }
        return (ss > 0) ? (sd / ss).squareRoot() : 0
    }

    func testChorusDelayDiagnosis() {
        let state = Presets.state(.pair1)
        let f0 = state.tonicHz
        let input = staccato(f0: f0)

        print("\n=== Chorus/delay diagnosis (pair1, staccato @ \(String(format: "%.1f", f0)) Hz) ===")

        // 1. Body FIR tap analysis — is it clean min-phase, or does it have a
        //    pre/post-echo (energy away from the main spike = a doubled copy)?
        if let fir = state.fir, !fir.isEmpty {
            let pk = argmax(fir.map { abs($0) })
            let tot = fir.reduce(0) { $0 + $1 * $1 } + 1e-12
            let win = Int(0.003 * sr)
            let near = fir[max(0, pk - win)..<min(fir.count, pk + win)].reduce(0) { $0 + $1 * $1 }
            print(String(format: "body FIR: %d taps, peak @ %.1f ms, %.0f%% energy within ±3 ms of peak (low %% = smeared/echoey)",
                         fir.count, Double(pk) / sr * 1000, 100 * near / tot))
        }

        // 2. Toggle each reverb / stereo suspect — measure decorrelation (chorus)
        //    + mono envelope, and write STEREO WAVs to A/B by ear.
        // The per-voice FX rack replaced the single block-F reverb; these
        // diagnostic variants now poke the violin-stage reverb live scalars.
        let variants: [(String, InstrumentState, (SarangiEngine) -> Void)] = [
            ("full (as shipped)    ", state,  { _ in }),
            ("violin reverb OFF    ", state,  { $0.scalars.violinFXOn = false }),
            ("violin mix 0.25→0.10 ", state,  { $0.scalars.violinReverbMix = 0.10 }),
            ("violin mix 0.25→0.50 ", state,  { $0.scalars.violinReverbMix = 0.50 }),
            ("violin width = 0     ", state,  { $0.scalars.violinReverbWidth = 0 }),
            ("drier + narrow combo ", state,  { $0.scalars.violinReverbMix = 0.12; $0.scalars.violinReverbWidth = 0.2 }),
        ]
        print("\nvariant                 L/R-decorr   2nd-peak   mono envelope (0…\(Int(Double(input.count) / sr * 1000)) ms)")
        let dir = "/Users/isha/Desktop/starpad/auditions/outputs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, st, tweak) in variants {
            let (l, r) = renderStereo(input, st, tweak)
            let env = envelope(zip(l, r).map { 0.5 * ($0 + $1) })
            let dec = decorrelation(l, r)
            let prom = secondPeakProminence(env)
            print(String(format: "%@  %.3f        %.3f      %@", name, dec, prom, sparkline(env, bins: 40)))
            let fname = name.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "→", with: "-")
                .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "=", with: "")
            writeWavStereo("\(dir)/diag_\(fname).wav", l, r)
        }
        print("(L/R-decorr: 0 = mono, higher = wider/chorus-y. The reverb adds a ~56 ms-late wash + the width.)")
        print("STEREO WAVs → \(dir)/diag_*.wav\n")
    }

    /// 16-bit stereo WAV (shared gain so L/R balance is preserved for A/B).
    func writeWavStereo(_ path: String, _ l: [Double], _ r: [Double]) {
        let peak = max(l.map { abs($0) }.max() ?? 1, r.map { abs($0) }.max() ?? 1)
        let g = peak > 1e-9 ? 0.9 / peak : 1
        var inter = [Int16](repeating: 0, count: l.count * 2)
        for i in l.indices {
            inter[2 * i] = Int16(max(-32767, min(32767, (l[i] * g * 32767).rounded())))
            inter[2 * i + 1] = Int16(max(-32767, min(32767, (r[i] * g * 32767).rounded())))
        }
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let bytes = inter.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
        u32(Int(sr)); u32(Int(sr) * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        inter.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - WAV (16-bit mono, peak-normalised for listening)

    func writeWav(_ path: String, _ x: [Double]) {
        let peak = x.map { abs($0) }.max() ?? 1
        let g = peak > 1e-9 ? 0.9 / peak : 1
        var samples = [Int16](repeating: 0, count: x.count)
        for i in x.indices { samples[i] = Int16(max(-32767, min(32767, (x[i] * g * 32767).rounded()))) }
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(Int(sr)); u32(Int(sr) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: URL(fileURLWithPath: path))
    }
}
