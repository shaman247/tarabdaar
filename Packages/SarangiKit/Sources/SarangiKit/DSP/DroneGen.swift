import Foundation

/// Block D — the sustained low drone (port of `blocks.drone_gen`, reinstated
/// 2026-07-06: the offline reference renders keep the drone, and without it
/// the live app is ~4.5 dB shy below 250 Hz vs pair3_new).
///
/// A high-Q resonator bank at drone_f (= tonic/4) and its first harmonics,
/// excited by activity-gated noise: env-follow the input (1.5 s release),
/// gate the noise by `floor + (1-floor)·env`, resonate, and level the output
/// at `level · rms(x)`. The offline form normalizes by the take's GLOBAL
/// env-max and output RMS; this causal form substitutes slow running
/// trackers (peak ~3 s decay, RMS ~2 s) — same steady-state behavior, a
/// short fade-in at cold start.
public struct DroneGen: Sendable {
    var resos: [Resonator]
    let gains: [Double]
    let level: Double
    let floorAmt: Double
    let envA: Double
    var envState = 0.0
    let peakDecay: Double
    var envPeak = 1e-9
    let rmsA: Double
    var rmsX = 0.0
    var rmsOut = 0.0
    var rmsCorr = 0.0          // bias correction: running mean = acc/(1-a^n),
                               // exact from sample 1 (no cold-start fade)
    var rng: XorShift64

    public init(f0: Double, t60: Double, level: Double, nHarm: Int,
                floor floorAmt: Double, sr: Double, seed: UInt64 = 7) {
        var r: [Resonator] = []
        var g: [Double] = []
        for h in 1...max(1, nHarm) {
            r.append(Resonator(f0: f0 * Double(h), t60: t60, sr: sr))
            g.append(1.0 / Double(h))
        }
        resos = r
        gains = g
        self.level = level
        self.floorAmt = min(max(floorAmt, 0.0), 1.0)
        envA = exp(-1.0 / (sr * 1.5))            // blocks._envelope rel 1500 ms
        // long trackers: the offline form normalizes by GLOBAL max/RMS —
        // short running stats made the drone follow loudness dips the offline
        // drone ignores (measured −1.4 dB band deficit at 3 s/2 s)
        peakDecay = exp(-1.0 / (sr * 10.0))
        rmsA = exp(-1.0 / (sr * 8.0))
        rng = XorShift64(seed: seed)
    }

    public mutating func process(_ x: Double) -> Double {
        guard level > 1e-6 else { return 0 }
        let ax = abs(x)
        envState = (1 - envA) * ax + envA * envState
        envPeak = max(envState, envPeak * peakDecay)
        let env = floorAmt + (1 - floorAmt) * envState / (envPeak + 1e-12)
        let exc = env * rng.gaussian() * 0.5
        var raw = 0.0
        for i in resos.indices { raw += gains[i] * resos[i].process(exc) }
        rmsX = rmsA * rmsX + (1 - rmsA) * x * x
        rmsOut = rmsA * rmsOut + (1 - rmsA) * raw * raw
        rmsCorr = rmsA * rmsCorr + (1 - rmsA)
        let c = max(rmsCorr, 1e-6)
        return level * (rmsX / c).squareRoot() * raw
            / ((rmsOut / c).squareRoot() + 1e-9)
    }

    public mutating func reset() {
        for i in resos.indices { resos[i].reset() }
        envState = 0; envPeak = 1e-9; rmsX = 0; rmsOut = 0; rmsCorr = 0
    }
}
