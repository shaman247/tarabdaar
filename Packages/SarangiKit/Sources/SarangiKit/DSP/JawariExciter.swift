import Foundation

/// Block C — the jawari (bridge buzz): a 4×-oversampled asymmetric `tanh` shaper
/// feeding a downward-sweeping morph-bandpass, the whole thing swelling/fading
/// with the note. Port of `blocks.jawari_exciter`, causalized:
///   • the offline `env/env.max()` normalisation is replaced by the supplied
///     `amp` control (0..1, velocity-driven live / signal-follower offline);
///   • `mean(d²)` → a one-pole DC follower at the **oversampled** rate;
///   • rasp/top RMS-matching → running-RMS one-poles.
/// Band edges are anchored to the preset tonic (f0), as in the offline model.
public struct JawariExciter: Sendable {
    // design (rebuilt when tonic / C_pre_hp / C_sweep_* change → structural)
    var preHP: Biquad
    var bodyHP: Biquad
    var morphBP: [Biquad]            // K=5 (section 1)
    var morphBP2: [Biquad]           // K=5 (section 2 → 4th-order band-pass)
    var logCenters: [Double]
    var fLow: Double, fHigh: Double
    var raspBP: Biquad
    var topHP1: Biquad, topHP2: Biquad
    var os: Oversampler4x
    let dcA: Double                  // DC follower coeff at oversampled rate
    let dcTop: Double                // slow DC mean coeff for the top edge

    // live scalars (read each sample)
    public var driveMin: Double, driveMax: Double, asym: Double
    public var wet: Double, rasp: Double, top: Double

    // state
    var dcShaper: Double = 0
    var topMean: Double = 0
    var rng: UInt64
    var rmsJaw: RunningRMS, rmsRasp: RunningRMS, rmsTop: RunningRMS
    let sr: Double
    static let p = 0.8               // sweep exponent

    public init(tonic f0: Double, sr: Double,
                preHpHz: Double, sweepLo: Double, sweepHi: Double,
                driveMin: Double, driveMax: Double, asym: Double,
                wet: Double, rasp: Double, top: Double,
                seed: UInt64 = 3) {
        self.sr = sr
        self.driveMin = driveMin; self.driveMax = driveMax; self.asym = asym
        self.wet = wet; self.rasp = rasp; self.top = top
        self.rng = seed &+ 0x1234_5678

        preHP = Biquad.highpass(fc: min(preHpHz, 0.45 * sr), sr: sr)
        fLow = sweepLo * f0
        fHigh = min(sweepHi * f0, 0.45 * sr)
        if fHigh <= fLow { fHigh = fLow * 1.5 }
        let K = 5
        var bps: [Biquad] = []; var bps2: [Biquad] = []; var lc: [Double] = []
        let width = 1.6
        for k in 0..<K {
            let c = fLow * pow(fHigh / fLow, Double(k) / Double(K - 1))
            // true 4th-order Butterworth band-pass (matches offline `_bp` =
            // scipy butter(2,'band')); the two sections are distinct, not an RBJ
            // cascade — maximally flat across [c/width, c·width], no centre peak.
            let (s0, s1) = Biquad.butterBandpass(lo: c / width, hi: min(c * width, 0.49 * sr), sr: sr)
            bps.append(s0); bps2.append(s1)
            lc.append(log(c))
        }
        morphBP = bps; morphBP2 = bps2; logCenters = lc
        bodyHP = Biquad.highpass(fc: min(1.8 * f0, 0.45 * sr), sr: sr)
        raspBP = Biquad.bandpass(lo: max(1.5 * f0, 1500.0), hi: min(7000.0, 0.49 * sr), sr: sr)
        topHP1 = Biquad.highpass(fc: min(4500.0, 0.45 * sr), sr: sr)
        topHP2 = Biquad.highpass(fc: min(8000.0, 0.45 * sr), sr: sr)
        os = Oversampler4x()
        dcA = exp(-1.0 / (sr * 4.0 * 0.05))     // 50 ms at the 4× rate
        dcTop = exp(-1.0 / (sr * 0.2))          // slow (200 ms) DC mean for the top edge
        // Long windows so the rasp/top RMS-match approximates the offline model's
        // whole-signal RMS (a short window blows up the match during quiet parts).
        let win = 600.0
        rmsJaw = RunningRMS(tauMs: win, sr: sr)
        rmsRasp = RunningRMS(tauMs: win, sr: sr)
        rmsTop = RunningRMS(tauMs: win, sr: sr)
    }

    mutating func white() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(Int64(bitPattern: rng)) / Double(Int64.max)
    }

    /// `amp` ∈ [0,1] is the note's amplitude envelope (drives drive, sweep, swell).
    public mutating func process(_ x: Double, amp: Double) -> Double {
        let envn = max(0.0, min(1.0, amp))
        let pre = preHP.process(x)

        let drive = driveMin + (driveMax - driveMin) * envn
        var dc = dcShaper
        let a = asym
        let dca = dcA
        let down = os.process(pre) { u in
            let d = tanh(drive * u)
            let d2 = d * d
            dc = (1 - dca) * d2 + dca * dc
            return d + a * (d2 - dc)
        }
        dcShaper = dc

        // downward-sweeping morph-bandpass
        let fc = fLow + (fHigh - fLow) * pow(envn, JawariExciter.p)
        let logfc = log(min(max(fc, exp(logCenters[0])), exp(logCenters[logCenters.count - 1])))
        var i = 0
        while i < logCenters.count - 2, logCenters[i + 1] <= logfc { i += 1 }
        let w = (logfc - logCenters[i]) / (logCenters[i + 1] - logCenters[i])
        var bp = [Double](repeating: 0, count: morphBP.count)
        for k in morphBP.indices { bp[k] = morphBP2[k].process(morphBP[k].process(down)) }
        let swept = (1 - w) * bp[i] + w * bp[i + 1]

        var out = bodyHP.process(swept)
        let jawRMS = rmsJaw.process(out)

        // The offline model RMS-matches rasp/top to the buzz with the
        // **whole-signal** ratio (≈40× for the top edge, since the freq-doubled
        // HF is tiny next to the buzz). The causal running-RMS match needs a cap
        // only to stop a 0/0 blow-up in silence — but the old cap of 4.0 throttled
        // the top edge ~20 dB below the reference (a −23 dB hole at 8–16 kHz).
        // Cap well above the real ratio so sustained play reaches the right level.
        let kRatioCap = 64.0
        if rasp > 0 {
            let rsp = raspBP.process(envn * white())
            let rRMS = rmsRasp.process(rsp)
            let ratio = min(kRatioCap, (jawRMS + 1e-9) / (rRMS + 1e-9))
            out += rasp * rsp * ratio
        }
        if top > 0 {
            let hi = topHP1.process(x)
            let rect = abs(hi)
            topMean = (1 - dcTop) * rect + dcTop * topMean          // slow mean (removes DC, keeps the freq-doubled AC)
            let dbl = topHP2.process(rect - topMean)
            let tRMS = rmsTop.process(dbl)
            let ratio = min(kRatioCap, (jawRMS + 1e-9) / (tRMS + 1e-9))
            out += top * dbl * ratio
        }
        return wet * (out * envn)
    }

    public mutating func reset() {
        preHP.reset(); bodyHP.reset(); raspBP.reset(); topHP1.reset(); topHP2.reset()
        for k in morphBP.indices { morphBP[k].reset(); morphBP2[k].reset() }
        os.reset(); dcShaper = 0; topMean = 0
        rmsJaw.reset(); rmsRasp.reset(); rmsTop.reset()
    }
}
