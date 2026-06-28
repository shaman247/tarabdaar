import XCTest
@testable import SarangiKit

/// Verifies the model's output LEVEL + sym audibility when driven at the level it
/// was fit for, using the real SWAM reference recording `input1.wav` (the dry
/// violin the offline fit used — active-RMS ≈ 0.30). In the app, the raw SWAM
/// drive is ~50× quieter than this, which is why the model (and especially the
/// excitation-driven sympathetic bank) is inaudible without a `driveGain`.
final class DriveLevelTests: XCTestCase {
    /// Minimal 16-bit PCM WAV reader → mono [Double] + sample rate.
    func readWavMono(_ path: String) -> (mono: [Double], sr: Double)? {
        guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 }
        // walk chunks to find fmt + data
        var ch = 2, sr = 44100, bits = 16, dataOff = 0, dataLen = 0, p = 12
        while p + 8 <= d.count {
            let id = String(bytes: d[p..<p+4], encoding: .ascii) ?? ""
            let sz = u32(p+4)
            if id == "fmt " { ch = u16(p+10); sr = u32(p+12); bits = u16(p+22) }
            else if id == "data" { dataOff = p+8; dataLen = sz; break }
            p += 8 + sz + (sz & 1)
        }
        guard bits == 16, dataOff > 0 else { return nil }
        let n = min(dataLen, d.count - dataOff) / 2
        var mono = [Double](); mono.reserveCapacity(n / ch)
        var i = 0
        while i + ch <= n {
            var s = 0.0
            for c in 0..<ch {
                let o = dataOff + (i + c) * 2
                let v = Int16(bitPattern: UInt16(d[o]) | UInt16(d[o+1]) << 8)
                s += Double(v) / 32768.0
            }
            mono.append(s / Double(ch)); i += ch
        }
        return (mono, Double(sr))
    }

    func renderLive(_ input: [Double], _ state: InstrumentState, sr: Double,
                    driveGain: Double, keep: String) -> [Double] {
        let e = SarangiEngine(params: state.params, strings: state.resolvedStrings,
                              tonic: state.tonicHz, sr: sr, firTaps: state.fir)
        if keep != "all" {
            if keep != "main" { e.scalars.mixDry = 0; e.scalars.mixJaw = 0 }
            if keep != "sym" { e.scalars.mixBank = 0 }
        }
        e.beginBuffer()
        var f = SignalAmpFollower(sr: sr)
        var out = [Double](repeating: 0, count: input.count)
        for i in input.indices {
            let x = driveGain * input[i]
            let (l, r) = e.renderSample(x, amp: f.process(x))
            out[i] = 0.5 * (l + r)
        }
        return out
    }

    func stats(_ x: [Double]) -> (peak: Double, rms: Double) {
        let pk = x.map { abs($0) }.max() ?? 0
        let act = x.filter { abs($0) > 0.05 * pk }
        let rms = act.isEmpty ? 0 : (act.reduce(0) { $0 + $1 * $1 } / Double(act.count)).squareRoot()
        return (pk, rms)
    }
    func db(_ x: Double) -> String { x <= 1e-9 ? "-inf" : String(format: "%.1f", 20 * log10(x)) }

    /// Energy in coarse frequency bands (Goertzel-style power at band centres),
    /// to see whether the sym sits BELOW or AT/ABOVE the played note.
    func bandEnergy(_ x: [Double], sr: Double) -> [(String, Double)] {
        let bands: [(String, Double, Double)] = [
            ("<80", 20, 80), ("80-160", 80, 160), ("160-260", 160, 260),
            ("260-420(note)", 260, 420), ("420-800", 420, 800),
            ("800-1.6k", 800, 1600), (">1.6k", 1600, sr/2)]
        // crude band power via summed |DFT| at a few probe freqs per band
        func power(_ f: Double) -> Double {
            let w = 2 * Double.pi * f / sr
            var re = 0.0, im = 0.0
            let n = min(x.count, Int(0.5 * sr))   // 0.5 s window
            let start = max(0, x.count - n)
            for i in 0..<n { let s = x[start + i]; re += s * cos(w * Double(i)); im -= s * sin(w * Double(i)) }
            return (re*re + im*im).squareRoot() / Double(n)
        }
        return bands.map { (name, lo, hi) in
            var p = 0.0; var c = 0
            var f = lo; while f < hi { p += power(f); c += 1; f *= pow(2, 1.0/6) }   // 1/6-oct probes
            return (name, c > 0 ? p / Double(c) : 0)
        }
    }

    func testSymSpectrum() {
        let sr = 44100.0
        let state = Presets.state(.pair1)
        let f0 = state.tonicHz                  // Eb4 ≈ 311 Hz (the played note = tonic)
        // sustained violin-ish tone at the fit drive level (~0.3), 2 s
        let n = Int(2.0 * sr)
        var tone = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            var s = 0.0; for h in 1...12 { s += sin(2*Double.pi*Double(h)*f0*t)/Double(h) }
            let env = min(1.0, t/0.02) * (t < 1.8 ? 1.0 : max(0, (2.0-t)/0.2))
            tone[i] = 0.3 * env * s / 1.6
        }
        print("\n=== Sym spectrum (sustained tonic \(Int(f0)) Hz, deployed gains main 1.0 / sym 12, driveGain 1) ===")
        for (tag, keep) in [("FULL", "all"), ("MAIN", "main"), ("SYM ", "sym")] {
            let out = renderLive(tone, state, sr: sr, driveGain: 1, keep: keep)
            let pk = stats(out).peak
            let bands = bandEnergy(out, sr: sr)
            let mx = bands.map(\.1).max() ?? 1
            let bars = bands.map { "\($0.0):\(String(repeating: "█", count: Int(($0.1/mx)*10)))" }.joined(separator: " ")
            print(String(format: "%@ peak %.3f  | %@", tag, pk, bars))
        }
        // Bank-only (the sym; the drone is removed from the model).
        let e = SarangiEngine(params: state.params, strings: state.resolvedStrings, tonic: f0, sr: sr, firTaps: state.fir)
        e.scalars.mixDry = 0; e.scalars.mixJaw = 0
        e.beginBuffer()
        var f = SignalAmpFollower(sr: sr); var out = [Double](repeating: 0, count: n)
        for i in 0..<n { let (l,r)=e.renderSample(tone[i], amp: f.process(tone[i])); out[i]=0.5*(l+r) }
        let bands = bandEnergy(out, sr: sr); let mx = bands.map(\.1).max() ?? 1
        let bars = bands.map { "\($0.0):\(String(repeating: "█", count: Int(($0.1/mx)*10)))" }.joined(separator: " ")
        print(String(format: "\nbank only (sym) peak %.3f rms %.4f | %@", stats(out).peak, stats(out).rms, bars))
    }

    func testInput1DriveLevel() {
        guard let (raw, sr) = readWavMono("/Users/isha/Desktop/sarangi/input1.wav") else {
            print("input1.wav not found — skipping"); return
        }
        let ref = Array(raw.prefix(Int(7 * sr)))     // first ~7 s, a few notes
        let st = stats(ref)
        let state = Presets.state(.pair1)             // gains default main 1.0 / sym 12 now
        print("\n=== Drive-level / sym-audibility verification ===")
        print(String(format: "input1.wav (fit ref)   peak %.3f  active-RMS %.3f", st.peak, st.rms))
        print(String(format: "in-app raw SWAM ≈ 0.017 peak → ~%.0f× quieter than the fit ref", st.peak / 0.017))

        // Simulate the IN-APP signal: scale the fit ref down to the measured raw-
        // SWAM level, then drive it with the deployed driveGain.
        let inApp = ref.map { $0 * (0.017 / st.peak) }
        func report(_ tag: String, _ x: [Double], dg: Double) {
            let full = stats(renderLive(x, state, sr: sr, driveGain: dg, keep: "all"))
            let main = stats(renderLive(x, state, sr: sr, driveGain: dg, keep: "main"))
            let sym  = stats(renderLive(x, state, sr: sr, driveGain: dg, keep: "sym"))
            print(String(format: "%@ driveGain %2.0f  FULL peak %.3f (%@ dB)  | MAIN rms %.4f (%@)  SYM rms %.4f (%@)  sym/main %.2f (%@ dB)",
                         tag, dg, full.peak, db(full.peak),
                         main.rms, db(main.rms), sym.rms, db(sym.rms),
                         main.rms > 0 ? sym.rms / main.rms : 0, db(main.rms > 0 ? sym.rms / main.rms : 0)))
        }
        print("\nsimulated in-app (raw-SWAM level) at the deployed gains (main 1.0, sym 12):")
        for dg in [1.0, 8.0, 14.0, 24.0] { report("  ", inApp, dg: dg) }
        // sym/main is drive-independent — show it grows with sym_gain (verifies audibility lever)
        print("\nsym/main vs sym_gain (drive-independent) at the fit ref:")
        for sg in [2.5, 12.0, 40.0] {
            let s = SarangiEngine(params: { var p = state.params; p["sym_gain"] = sg; return p }(),
                                  strings: state.resolvedStrings, tonic: state.tonicHz, sr: sr, firTaps: state.fir)
            s.scalars.mixDry = 0; s.scalars.mixJaw = 0; s.beginBuffer()
            var f = SignalAmpFollower(sr: sr); var sym = [Double](repeating: 0, count: ref.count)
            for i in ref.indices { let (l,r)=s.renderSample(ref[i], amp: f.process(ref[i])); sym[i]=0.5*(l+r) }
            let symr = stats(sym).rms
            let m = SarangiEngine(params: state.params, strings: state.resolvedStrings, tonic: state.tonicHz, sr: sr, firTaps: state.fir)
            m.scalars.mixBank = 0; m.beginBuffer()
            var f2 = SignalAmpFollower(sr: sr); var main=[Double](repeating:0,count:ref.count)
            for i in ref.indices { let (l,r)=m.renderSample(ref[i], amp: f2.process(ref[i])); main[i]=0.5*(l+r) }
            let mainr = stats(main).rms
            print(String(format: "  sym_gain %4.1f → sym/main %.3f (%@ dB below main)", sg, symr/mainr, db(symr/mainr)))
        }
        print("")
    }
}
