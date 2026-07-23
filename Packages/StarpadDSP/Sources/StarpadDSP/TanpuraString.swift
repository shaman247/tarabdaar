import Foundation

/// One tanpura string, synthesized as `harmonicCount` individual harmonics.
///
/// Each harmonic k runs a rotation oscillator at f_k = k·f0·√(1+B·k²) and a
/// "bloom" amplitude envelope `gain_k · (attackLevel·e_a + e_d − e_r)` built
/// from three one-pole exponential decays. The states are linear, so a pluck
/// simply ADDS velocity into them — overlapping plucks superpose without
/// clicks. The rise pole e_r is solved so the envelope of harmonic k peaks
/// exactly at its configured peak time tp_k; staggered per-harmonic peak
/// times are the tanpura's defining characteristic.
///
/// Not thread-safe: all calls must happen under the owner's lock (or on a
/// single thread in the offline renderer).
final class TanpuraString {
    private let fs: Double
    private let maxH = TanpuraParams.maxHarmonics
    // Partial indexing: [0, maxH) is the integer bank (h = k+1);
    // [maxH, 2·maxH) is the HALF-INTEGER bank (h = (k−maxH)+0.5) — the
    // jawari bridge's period-2 partials, enabled by subLevelDB > −60.
    // Both banks share the string's gain/decay/bloom laws, evaluated at h.
    private let slotCount = 2 * TanpuraParams.maxHarmonics

    // Per-partial state (index 0 = harmonic 1).
    private var oscC = [Double](repeating: 1, count: 2 * TanpuraParams.maxHarmonics)
    private var oscS = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var rotC = [Double](repeating: 1, count: 2 * TanpuraParams.maxHarmonics)
    private var rotS = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var envA = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var envD = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var envR = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var jivaPhase = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var jivaRateScale = [Double](repeating: 1, count: 2 * TanpuraParams.maxHarmonics)
    private var jivaGain = [Double](repeating: 1, count: 2 * TanpuraParams.maxHarmonics)
    // Raw [0,1) per-harmonic randoms (fixed by seed); jivaRateScale is
    // derived from these in apply() so jivaRateSpread can tighten or
    // widen the per-harmonic rate scatter without re-seeding.
    private var jivaRand = [Double](repeating: 0.5, count: 2 * TanpuraParams.maxHarmonics)

    // Per-partial coefficients, recomputed in apply().
    private var freqHz = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var gain = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var kD = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var kR = [Double](repeating: 0, count: 2 * TanpuraParams.maxHarmonics)
    private var envNorm = [Double](repeating: 1, count: 2 * TanpuraParams.maxHarmonics)
    private var kA: Double = 0
    private var activeH = 0
    /// One past the last potentially-active slot: activeH when the sub
    /// bank is off (bit-identical to the pre-sub-bank engine, including
    /// RNG draw order), maxH + activeH when on.
    private var loopEnd = 0

    /// Harmonic number of slot k (integer bank h = k+1, sub bank h = k−maxH+0.5).
    @inline(__always) private func hValue(_ k: Int) -> Double {
        k < maxH ? Double(k + 1) : Double(k - maxH) + 0.5
    }

    // Cached params.
    private var sp: TanpuraStringParams
    private var attackLevel: Double = 0.4
    private var jivaDepth: Double = 0
    private var jivaRate: Double = 0.5
    private var jivaTilt: Double = 0.6
    private var jivaConserve: Double = 0
    private var jivaRateSpread: Double = 1
    private var pitchDriftCents: Double = 0
    private var pitchDriftRate: Double = 0.15
    private var pluckVariationDB: Double = 0
    private var noiseLevel: Double = 0

    // Attack-noise burst (bandpassed white noise with exponential gate).
    private var noiseEnv: Double = 0
    private var kNoise: Double = 0
    private var bpB0: Double = 0, bpA1: Double = 0, bpA2: Double = 0
    private var bpX1: Double = 0, bpX2: Double = 0, bpY1: Double = 0, bpY2: Double = 0

    // Slow life modulation.
    private var driftLP: Double = 0
    private var driftFactor: Double = 1

    private var rng: UInt64

    init(sampleRate: Double, seed: UInt64, params: TanpuraParams, stringParams: TanpuraStringParams) {
        self.fs = sampleRate
        self.rng = seed | 1
        self.sp = stringParams
        // Random initial oscillator phases and jiva phases/rates, fixed by
        // the seed so renders are reproducible. The sub bank draws AFTER
        // the integer bank so the integer bank's phases match pre-sub-bank
        // renders exactly.
        for k in 0..<slotCount {
            let phase = nextUniform() * 2 * Double.pi
            oscC[k] = cos(phase)
            oscS[k] = sin(phase)
            jivaPhase[k] = nextUniform() * 2 * Double.pi
            jivaRand[k] = nextUniform()
            jivaRateScale[k] = 0.5 + jivaRand[k]
        }
        apply(params: params, stringParams: stringParams)
    }

    // MARK: - RNG (xorshift64*, deterministic)

    private func nextUniform() -> Double {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let v = rng &* 0x2545F4914F6CDD1D
        return Double(v >> 11) * (1.0 / 9007199254740992.0)  // [0, 1)
    }

    /// Uniform in [-1, 1).
    private func nextBipolar() -> Double { nextUniform() * 2 - 1 }

    // MARK: - Configuration

    /// Recompute every per-harmonic coefficient from the params. Cheap
    /// enough to call on any param change (~tens of µs).
    func apply(params p: TanpuraParams, stringParams s: TanpuraStringParams) {
        sp = s
        attackLevel = s.attackLevel
        jivaDepth = p.jivaDepth
        jivaRate = p.jivaRate
        jivaTilt = p.jivaTilt
        jivaConserve = p.jivaConserve
        jivaRateSpread = p.jivaRateSpread
        // Per-harmonic rate scatter around 1.0, width = spread. spread 1
        // reproduces the original 0.5–1.5× scatter; spread 0 makes every
        // harmonic share one rate, concentrating the modulation at a
        // single frequency (the reference's isolated-pluck jiva is a
        // TIGHT ~2 Hz peak, not the broadband 1.5–7 Hz smear that
        // independent random rates produce — the "wah-wah").
        for k in 0..<slotCount {
            jivaRateScale[k] = 1.0 + jivaRateSpread * (jivaRand[k] - 0.5)
        }
        pitchDriftCents = p.pitchDriftCents
        pitchDriftRate = p.pitchDriftRate
        pluckVariationDB = p.pluckVariationDB
        noiseLevel = p.noiseLevel

        activeH = max(4, min(maxH, p.harmonicCount))
        let subOn = s.subLevelDB > -59.9
        loopEnd = subOn ? maxH + activeH : activeH
        let subScale = subOn ? pow(10, s.subLevelDB / 20) : 0.0
        kA = exp(-1.0 / (fs * max(0.002, s.attackDecay)))
        kNoise = exp(-1.0 / (fs * max(0.001, p.noiseDecay)))

        for k in 0..<slotCount {
            let isSub = k >= maxH
            let h = hValue(k)
            let f = h * s.f0 * (1 + s.inharmonicity * h * h).squareRoot()
            freqHz[k] = f
            let dead = isSub ? (!subOn || k - maxH >= activeH) : k >= activeH
            if dead || f > 0.45 * fs {
                gain[k] = 0
                kD[k] = 0
                kR[k] = 0
                envNorm[k] = 0
                continue
            }
            // Amplitude law: pluck-position comb × spectral falloff × trim.
            // The comb is floored — a finger-width pluck never produces an
            // exact node zero, and a hard zero couldn't be revived by trims.
            // Sub-bank partials take the same laws at h = k+0.5, scaled by
            // subLevelDB instead of the per-harmonic trim.
            let comb = max(0.05, abs(sin(Double.pi * h * s.pluckPos)))
            let fall = pow(h, -(isSub ? s.subFalloff : s.falloff))
            // Sub bank: subLevelDB scale + smooth knee lowpass in h (the
            // period-2 partials concentrate at low h).
            let trim = isSub
                ? subScale / (1.0 + pow(h / max(1.0, s.subKneeH), 4))
                : pow(10, s.gainTrimDB[k] / 20)
            gain[k] = comb * fall * trim

            // Decay and peak-time laws (per-harmonic trims on the main bank).
            let dTrim = isSub ? 1.0 : s.decayTrim[k]
            let pTrim = isSub ? 1.0 : s.peakTrim[k]
            let tauD = max(0.02, s.decay * pow(h, -s.dampTilt) * dTrim)
            var tp = s.bloomDelay * pow(h, s.bloomSkew) * pTrim
            tp = min(max(tp, 0.0005), 0.8 * tauD)
            let tauR = TanpuraString.solveRiseTau(peakTime: tp, tauD: tauD)
            kD[k] = exp(-1.0 / (fs * tauD))
            kR[k] = exp(-1.0 / (fs * tauR))
            // Normalize so a velocity-v pluck peaks the bloom pair at ~v.
            let peakVal = exp(-tp / tauD) - exp(-tp / tauR)
            envNorm[k] = peakVal > 1e-9 ? 1.0 / peakVal : 0
        }

        // Attack-noise bandpass (RBJ constant-peak-gain).
        let w0 = 2 * Double.pi * min(p.noiseFreq, 0.45 * fs) / fs
        let alpha = sin(w0) / (2 * max(0.3, p.noiseQ))
        let a0 = 1 + alpha
        bpB0 = alpha / a0
        bpA1 = (-2 * cos(w0)) / a0
        bpA2 = (1 - alpha) / a0

        updateRotation()
    }

    /// Solve the rise time constant so (e^{-t/τd} − e^{-t/τr}) peaks at
    /// `peakTime`. The peak of the pair lands at ln(τd/τr)·τrτd/(τd−τr),
    /// monotonic in τr — bisection in ρ = τr/τd.
    static func solveRiseTau(peakTime: Double, tauD: Double) -> Double {
        let target = min(max(peakTime / tauD, 1e-5), 0.85)
        var lo = 1e-6, hi = 0.999
        for _ in 0..<48 {
            let mid = 0.5 * (lo + hi)
            // t*/τd for ρ = mid: ρ·ln(1/ρ)/(1−ρ)
            let t = mid * log(1 / mid) / (1 - mid)
            if t < target { lo = mid } else { hi = mid }
        }
        return max(0.0003, tauD * 0.5 * (lo + hi))
    }

    private func updateRotation() {
        for k in 0..<loopEnd where gain[k] > 0 {
            let w = 2 * Double.pi * freqHz[k] * driftFactor / fs
            rotC[k] = cos(w)
            rotS[k] = sin(w)
        }
    }

    /// Cheap live retune — recompute only the frequency-dependent state
    /// (partial frequencies + rotation coefficients) for a new fundamental,
    /// leaving the (f0-independent) gain / decay / bloom laws untouched. Safe
    /// to call at control rate for a continuous glide; the full `apply` (with
    /// its per-harmonic rise-time bisection) is far too heavy for that. The
    /// linear oscillator states keep ringing, so the pitch slides continuously.
    func setF0(_ f0: Double) {
        guard f0 > 0 else { return }
        sp.f0 = f0
        for k in 0..<loopEnd where gain[k] > 0 {
            let h = hValue(k)
            freqHz[k] = h * f0 * (1 + sp.inharmonicity * h * h).squareRoot()
        }
        updateRotation()
    }

    // MARK: - Excitation

    /// Pluck the string. Envelope states are linear, so this superposes
    /// cleanly on whatever is already ringing. Each pluck gets its own
    /// random per-harmonic gain jitter (pluckVariationDB) so successive
    /// plucks aren't clones.
    func pluck(velocity: Double) {
        let v = max(0, min(1.5, velocity))
        for k in 0..<loopEnd where gain[k] > 0 {
            let jit = pluckVariationDB > 0
                ? pow(10, pluckVariationDB * nextBipolar() / 20)
                : 1.0
            let add = v * jit
            envA[k] += add
            envD[k] += add * envNorm[k]
            envR[k] += add * envNorm[k]
        }
        noiseEnv += v
    }

    /// Sympathetic excitation of one harmonic (cross-string coupling):
    /// adds only into the bloom pair, no attack component, no noise.
    func exciteHarmonic(_ k: Int, amount: Double) {
        guard k >= 0, k < activeH, gain[k] > 0 else { return }
        envD[k] += amount * envNorm[k]
        envR[k] += amount * envNorm[k]
    }

    var harmonicFrequencies: [Double] { Array(freqHz.prefix(activeH)) }

    // MARK: - Block-rate modulation

    /// Advance slow modulation (pitch drift random walk + per-harmonic jiva
    /// undulation) by one block — deterministic, block-rate.
    func tickModulation(blockFrames: Int) {
        let dt = Double(blockFrames) / fs

        if pitchDriftCents > 0 {
            let a = 1 - exp(-2 * Double.pi * pitchDriftRate * dt)
            driftLP += a * (nextBipolar() - driftLP)
            let newFactor = pow(2, pitchDriftCents * driftLP / 1200)
            if abs(newFactor - driftFactor) > 1e-7 {
                driftFactor = newFactor
                updateRotation()
            }
        } else if driftFactor != 1 {
            driftFactor = 1
            updateRotation()
        }

        if jivaDepth > 0 {
            for k in 0..<loopEnd where gain[k] > 0 {
                jivaPhase[k] += 2 * Double.pi * jivaRate * jivaRateScale[k] * dt
                if jivaPhase[k] > 2 * Double.pi { jivaPhase[k] -= 2 * Double.pi }
                // Mid-harmonic weighting: jivaTilt = 0 → uniform, 1 → bell
                // centered near harmonic 6 (where real tanpura jiva lives).
                let h = hValue(k)
                let bell = exp(-((h - 6) / 5) * ((h - 6) / 5))
                let w = (1 - jivaTilt) + jivaTilt * bell
                jivaGain[k] = 1 + jivaDepth * w * sin(jivaPhase[k])
            }
            // Energy conservation: rescale so the modulated total power
            // matches the unmodulated one — harmonics then swell and fade
            // AGAINST each other (real jawari energy redistribution)
            // instead of pumping the summed envelope ("wah-wah" on an
            // isolated pluck). Weighted by each partial's LIVE amplitude
            // (gain × current envelope state): static gains alone
            // normalize the wrong sum after a pluck, when a few bloomed
            // harmonics carry nearly all the output power.
            if jivaConserve > 0 {
                var s2 = 0.0
                var b2 = 0.0
                for k in 0..<loopEnd where gain[k] > 0 {
                    let amp = gain[k] * (attackLevel * envA[k] + envD[k] - envR[k])
                    let a2 = amp * amp
                    s2 += a2 * jivaGain[k] * jivaGain[k]
                    b2 += a2
                }
                if s2 > 1e-12, b2 > 1e-12 {
                    let scale = pow(b2 / s2, 0.5 * jivaConserve)
                    for k in 0..<loopEnd where gain[k] > 0 {
                        jivaGain[k] *= scale
                    }
                }
            }
        } else {
            for k in 0..<loopEnd { jivaGain[k] = 1 }
        }

        // Keep rotation oscillators on the unit circle (drift from finite
        // precision is slow; one renormalization per block is plenty).
        for k in 0..<loopEnd where gain[k] > 0 {
            let mag2 = oscC[k] * oscC[k] + oscS[k] * oscS[k]
            if mag2 > 0 {
                let inv = 1.0 / mag2.squareRoot()
                oscC[k] *= inv
                oscS[k] *= inv
            } else {
                oscC[k] = 1
                oscS[k] = 0
            }
        }
    }

    // MARK: - Render

    /// Accumulate `frames` mono samples into `mono` (caller zeroes).
    /// Harmonic-outer loops keep all per-harmonic state in registers.
    func renderAdd(mono: UnsafeMutablePointer<Double>, frames: Int) {
        let aL = attackLevel
        for k in 0..<loopEnd {
            let g = gain[k] * jivaGain[k]
            if g == 0 { continue }
            var c = oscC[k], s = oscS[k]
            var eA = envA[k], eD = envD[k], eR = envR[k]
            let rc = rotC[k], rs = rotS[k]
            let dA = kA, dD = kD[k], dR = kR[k]
            for f in 0..<frames {
                let c2 = c * rc - s * rs
                let s2 = c * rs + s * rc
                c = c2; s = s2
                eA *= dA; eD *= dD; eR *= dR
                mono[f] += g * (aL * eA + eD - eR) * s2
            }
            oscC[k] = c; oscS[k] = s
            envA[k] = eA; envD[k] = eD; envR[k] = eR
        }

        // Attack-noise burst.
        if noiseEnv > 1e-6, noiseLevel > 0 {
            var nE = noiseEnv
            var x1 = bpX1, x2 = bpX2, y1 = bpY1, y2 = bpY2
            for f in 0..<frames {
                let w = nextBipolar() * nE
                let y = bpB0 * (w - x2) - bpA1 * y1 - bpA2 * y2
                x2 = x1; x1 = w
                y2 = y1; y1 = y
                mono[f] += noiseLevel * y
                nE *= kNoise
            }
            noiseEnv = nE
            bpX1 = x1; bpX2 = x2; bpY1 = y1; bpY2 = y2
        }

        let scaled = sp.level
        if scaled != 1 {
            for f in 0..<frames { mono[f] *= scaled }
        }
    }

    /// Silence the string instantly (envelopes + noise); oscillator phases
    /// and modulation state are kept so the drone stays deterministic.
    func clearState() {
        for k in 0..<slotCount {
            envA[k] = 0; envD[k] = 0; envR[k] = 0
            jivaGain[k] = 1
        }
        noiseEnv = 0
        bpX1 = 0; bpX2 = 0; bpY1 = 0; bpY2 = 0
        driftLP = 0
    }

    /// True if every envelope/noise/filter state is finite.
    var isFinite: Bool {
        for k in 0..<loopEnd {
            if !envD[k].isFinite || !envR[k].isFinite || !envA[k].isFinite { return false }
            if !oscC[k].isFinite || !oscS[k].isFinite { return false }
        }
        return noiseEnv.isFinite && bpY1.isFinite && bpY2.isFinite
    }
}
