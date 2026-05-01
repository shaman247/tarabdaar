import AVFoundation
import Foundation
import QuartzCore

/// Modal-synthesis polyphonic engine.
///
/// Each "string" is a bank of decaying sinusoidal resonators (one per partial),
/// implemented with a coupled-form complex-exponential resonator for numerical
/// stability at high Q. Two classes of banks:
///
/// - **Played banks** (fixed-size pool, indexed by channel): triggered by touch.
///   Excited by a mix of a pluck impulse (optionally passed through a
///   pluck-position comb filter) and continuous low-passed bow noise with an
///   attack envelope. Modes ring on their own Q after `noteOff` until their
///   stored energy falls below a silent-bank threshold or a release-timeout
///   elapses, whichever comes first.
/// - **Sympathetic banks** (flat array, rebuilt when the sympathetic scale
///   changes): always alive, driven each sample by the played audio sum × a
///   per-bank coupling gain (set from the main thread via the existing kernel),
///   plus a tiny broadband-noise term so off-resonance sym strings still
///   respond physically. They ring after the played excitation stops.
///
/// Rendering is two-pass inside the audio callback: played banks sum into a
/// scratch buffer, then sym banks are driven by that buffer. Silent-bank skip
/// avoids the inner mode loop when both state and drive are inaudible.
class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let lock = NSLock()

    @Published var isRunning = false

    // MARK: - Control-rate parameters
    //
    // These are written from the main thread under lock and read on the audio
    // thread (also under lock). All are recomputed into per-bank coefficients
    // when they change — never read per-sample.

    var harmonicFalloff: Double = 2.0
    var bowForce: Double = 0.05
    var stringDecay: Double = 3.0
    var symDecay: Double = 8.0
    var dampingTilt: Double = 0.8
    var inharmonicity: Double = 0.002
    var symCoupling: Double = 0.8
    var pluckPosition: Double = 0.15
    /// Active mode count per bank (1–8). Controls how many partials are
    /// excited/rendered. Fewer partials → more bottle/formant character.
    var partialCount: Int = 6
    /// Multiplier on mode 1's pre-RMS gain. >1 emphasizes the fundamental,
    /// which is what distinguishes a plucked string ("strong fundamental")
    /// from a bell ("equally-weighted partials").
    var fundamentalBoost: Double = 1.0
    /// Amplitude of the pitch-tracking bandpass-filtered noise layer mixed
    /// alongside the modal bank. 0 = purely modal; 0.3+ = breathy/bottle
    /// character.
    var breathLevel: Double = 0.0
    /// Semitone offset of the breath bandpass center from the played pitch.
    /// 0 = centered on the note; negative = below; positive = above.
    var breathOffset: Double = 0
    /// Log-frequency bandwidth of the breath bandpass in semitones. Acts as
    /// the standard-deviation-like "spread" of pitched noise around the
    /// centered pitch. Small = narrow whistle; large = broad pitched-noise
    /// wash.
    var breathSpread: Double = 12
    private(set) var sympatheticDetuneCents: Double = 0

    // MARK: - Constants

    /// Upper bound on partials per bank. The runtime-active count is the
    /// `partialCount` parameter, clamped to this maximum. 8 keeps Nyquist
    /// headroom even at high pitch plus generous inharmonicity.
    private static let playedMaxModes: Int = 8
    private static let symMaxModes: Int = 8
    /// Bow-noise one-pole LPF coefficient (~800 Hz cutoff at 44.1 kHz).
    private static let noiseLPCoef: Double = 0.12
    /// Silent-bank threshold: if total |state| + |drive| are both below this,
    /// skip the per-sample mode loop for that bank.
    private static let silentBankThreshold: Double = 5e-4
    /// Pluck impulse spread — softens the burst over a few samples.
    private static let pluckBurstSamples: Int = 3
    /// Max pluck-comb delay in samples (1024 covers down to ~45 Hz at 0.5 pos).
    private static let pluckCombMax: Int = 1024

    // MARK: - Voice state

    enum VoiceState {
        case idle
        case sounding
        case releasing
    }

    /// One modal bank — either a played string or a sympathetic string.
    ///
    /// Class (reference semantics) so the render loop can mutate shared state
    /// without copy-on-write overhead. All arrays are raw unsafe pointers of
    /// fixed `maxModes` capacity, so the hot loop never pays Swift array
    /// bounds-check or COW costs.
    final class ModalBank {
        let maxModes: Int
        /// Active number of partials (1..maxModes). Modes beyond this have
        /// their inGain zeroed in the coefficient table, so the render loop
        /// can iterate this instead of maxModes to skip dead partials.
        var modeCount: Int = 0
        /// Fundamental frequency (Hz). For sym banks this already includes the
        /// ±detune offset.
        var f0: Double = 0
        /// Note-on velocity normalized 0..1. Scales pluck impulse.
        var velocity: Double = 0
        /// Overall output scalar (set from updateVoiceParams.amplitude for
        /// played banks; 1.0 for sym banks — sym amplitude comes from
        /// coupling gain × sympatheticVolume scaling in NoteManager).
        var outputGain: Double = 1.0

        // Breath bandpass filter state and coefficients (per-bank: each
        // played voice's bandpass is centered on *its* pitch, so coefs are
        // pitch-dependent and live on the bank). Direct-form I biquad:
        // y[n] = B0·x[n] + B2·x[n-2] − A1·y[n-1] − A2·y[n-2]
        var breathB0: Double = 0
        var breathB2: Double = 0
        var breathA1: Double = 0
        var breathA2: Double = 0
        var breathX1: Double = 0
        var breathX2: Double = 0
        var breathY1: Double = 0
        var breathY2: Double = 0

        // Per-mode coefficients (coupled-form resonator):
        //   u' = rCos·u − rSin·v + drive·inGain
        //   v' = rSin·u + rCos·v
        // Output accumulator reads v'.
        let rCosOmega: UnsafeMutablePointer<Double>
        let rSinOmega: UnsafeMutablePointer<Double>
        let inGain: UnsafeMutablePointer<Double>
        let u: UnsafeMutablePointer<Double>
        let v: UnsafeMutablePointer<Double>

        // Excitation envelope (attack-smoothed toward excTarget, 0 on release).
        var excEnv: Double = 0
        var excTarget: Double = 0
        var excAttackCoef: Double = 0.01

        // Per-bank noise source — independent across voices so hiss is
        // uncorrelated in poly mode.
        var noiseRng: UInt32 = 0xA5A5A5A5
        var noiseLP: Double = 0

        // Pluck-impulse burst state + pluck-position comb delay line.
        var pluckSamplesRemaining: Int = 0
        var pluckImpulseAmp: Double = 0
        let pluckCombDelay: UnsafeMutablePointer<Double>
        var pluckCombSize: Int = 0
        var pluckCombWriteIdx: Int = 0

        // Lifecycle (played banks only; sym banks stay .sounding forever).
        var state: VoiceState = .idle

        init(maxModes: Int) {
            self.maxModes = maxModes
            self.rCosOmega = .allocate(capacity: maxModes)
            self.rSinOmega = .allocate(capacity: maxModes)
            self.inGain = .allocate(capacity: maxModes)
            self.u = .allocate(capacity: maxModes)
            self.v = .allocate(capacity: maxModes)
            self.pluckCombDelay = .allocate(capacity: AudioEngine.pluckCombMax)
            self.rCosOmega.initialize(repeating: 0, count: maxModes)
            self.rSinOmega.initialize(repeating: 0, count: maxModes)
            self.inGain.initialize(repeating: 0, count: maxModes)
            self.u.initialize(repeating: 0, count: maxModes)
            self.v.initialize(repeating: 0, count: maxModes)
            self.pluckCombDelay.initialize(repeating: 0, count: AudioEngine.pluckCombMax)
        }

        deinit {
            rCosOmega.deallocate()
            rSinOmega.deallocate()
            inGain.deallocate()
            u.deallocate()
            v.deallocate()
            pluckCombDelay.deallocate()
        }

        /// Zero all modal state (used on fresh noteOn).
        func resetState() {
            u.initialize(repeating: 0, count: maxModes)
            v.initialize(repeating: 0, count: maxModes)
            pluckCombDelay.initialize(repeating: 0, count: AudioEngine.pluckCombMax)
            pluckCombWriteIdx = 0
            excEnv = 0
            noiseLP = 0
            breathX1 = 0; breathX2 = 0
            breathY1 = 0; breathY2 = 0
        }

        /// Sum of |v| across active modes — a cheap proxy for total ringing
        /// energy. Used for silent-bank skip and voice-lifetime decisions.
        func energy() -> Double {
            var e = 0.0
            let n = max(modeCount, 1)
            for m in 0..<n { e += abs(v[m]) }
            return e
        }
    }

    // MARK: - Bank pools

    /// Fixed-size pool of played banks, one per possible MIDI channel slot.
    /// Entries are pre-allocated at init; `state == .idle` marks available.
    private var playedBanks: [ModalBank]

    /// Sympathetic banks, rebuilt when the sympathetic scale changes. Length
    /// is always `2 · enabledSympatheticNoteCount` (two detune directions per
    /// nominal frequency).
    private var symBanks: [ModalBank] = []
    private var symNominalFreqs: [Double] = []
    private var symDetuneDir: [Double] = []
    /// Per-sym-bank drive scalar. Set from the main thread via
    /// `setSympatheticTargetAmps(_:)` — the array comes from the existing
    /// kernel excitation × sympatheticVolume, reinterpreted here as the gain
    /// on the played-audio coupling into each sym bank.
    private var symCouplingGains: [Double] = []

    // MARK: - Profiling

    private(set) var lastRenderTime: Double = 0
    private(set) var maxRenderTime: Double = 0
    private(set) var lastRenderFrames: Int = 0
    private(set) var lastRenderVoiceCount: Int = 0
    private(set) var lockWaitNanos: UInt64 = 0
    private(set) var lockAcquisitions: UInt64 = 0
    private var maxRenderTimeWindowEnd: Double = 0

    func lockAndMeasure() {
        let t0 = CACurrentMediaTime()
        lock.lock()
        let waitNanos = UInt64(max(0, (CACurrentMediaTime() - t0) * 1e9))
        lockWaitNanos &+= waitNanos
        lockAcquisitions &+= 1
    }

    func snapshotLockStats() -> (avgWaitMicros: Double, count: UInt64) {
        let count = lockAcquisitions
        let total = lockWaitNanos
        lockAcquisitions = 0
        lockWaitNanos = 0
        guard count > 0 else { return (0, 0) }
        return (Double(total) / Double(count) / 1000.0, count)
    }

    // MARK: - Snapshots (visualization)

    /// Read-only snapshot of the first sounding or ringing played bank, as
    /// `(f0, amp)`. Amp is normalized ringing energy (sum of |v| across modes).
    func baseVoiceSnapshot() -> (freq: Double, amp: Double)? {
        lock.lock()
        defer { lock.unlock() }
        for ch in 0..<playedBanks.count {
            let bank = playedBanks[ch]
            if bank.state == .idle { continue }
            let e = bank.energy()
            if e > 0.001 {
                return (freq: bank.f0, amp: min(1.0, e))
            }
        }
        return nil
    }

    /// Read-only `(freq, amp)` pair per sympathetic bank. Freq includes the
    /// ±detune offset; amp is bank ringing energy.
    func sympatheticSnapshot() -> [(freq: Double, amp: Double)] {
        lock.lock()
        defer { lock.unlock() }
        var out: [(freq: Double, amp: Double)] = []
        out.reserveCapacity(symBanks.count)
        for i in 0..<symBanks.count {
            let bank = symBanks[i]
            let e = bank.energy()
            out.append((freq: bank.f0, amp: min(1.0, e)))
        }
        return out
    }

    // MARK: - Setup

    private var sourceNode: AVAudioSourceNode!

    init() {
        self.playedBanks = (0..<Config.maxPolyVoices).map { _ in ModalBank(maxModes: Self.playedMaxModes) }
        setupAudio()
    }

    // MARK: - Coefficient computation

    /// Build the per-mode coupled-form resonator coefficients for a bank.
    /// Called whenever f0, stringDecay/symDecay, dampingTilt, harmonicFalloff,
    /// or inharmonicity changes. Not called per sample.
    ///
    /// Mode frequencies follow `f_k = k · f0 · sqrt(1 + B·k²)` (stiffness).
    /// Per-mode decay: `τ_k = decay / k^α` (freq-dependent damping tilt).
    /// Mode amplitude: `g_k ∝ 1/k^falloff`, RMS-normalized across active modes.
    /// Input gain: `inGain_k = sin(ω_k) · g_k` (coupled-form impulse → clean
    /// decaying sinusoid, DC-rejecting).
    ///
    /// Modes above 0.45·sampleRate (from high pitch × inharmonicity × high k)
    /// are zeroed so they can't oscillate.
    private func recomputeBankCoefficients(bank: ModalBank, useSymDecay: Bool) {
        let sampleRate = Config.sampleRate
        let maxSafeFreq = 0.45 * sampleRate
        let rMax = 1.0 - pow(2.0, -20.0)
        let decay = useSymDecay ? symDecay : stringDecay
        let falloff = harmonicFalloff
        let tilt = dampingTilt
        let B = inharmonicity
        let boost = max(1.0, fundamentalBoost)
        // Runtime active partial count (clamped to this bank's capacity).
        let active = max(1, min(bank.maxModes, partialCount))
        bank.modeCount = active

        // Pass 1: RMS-norm denominator across the active partials only.
        // fundamentalBoost multiplies mode 1 BEFORE the sum so the
        // normalization properly tilts energy toward the fundamental —
        // the upper partials shrink instead of the fundamental getting
        // artificially louder in absolute terms.
        var sumSq = 0.0
        for k in 1...active {
            let kd = Double(k)
            let freq = kd * bank.f0 * sqrt(max(0.0, 1.0 + B * kd * kd))
            if freq >= maxSafeFreq { continue }
            var g = 1.0 / pow(kd, falloff)
            if k == 1 { g *= boost }
            sumSq += g * g
        }
        let rmsNorm = sumSq > 0 ? 1.0 / sqrt(sumSq) : 0

        // Pass 2: active modes get live coefficients; modes beyond `active`
        // (up to maxModes) are zeroed and their state is cleared so a later
        // partialCount increase can't resurrect stale resonance.
        for k in 1...active {
            let idx = k - 1
            let kd = Double(k)
            let freq = kd * bank.f0 * sqrt(max(0.0, 1.0 + B * kd * kd))
            if freq >= maxSafeFreq || bank.f0 <= 0 {
                bank.rCosOmega[idx] = 0
                bank.rSinOmega[idx] = 0
                bank.inGain[idx] = 0
                bank.u[idx] = 0
                bank.v[idx] = 0
                continue
            }
            // decay = T60 (−60 dB time). R^(sr·T60) = 10^−3.
            let tauK = decay / pow(kd, tilt)
            let r = min(rMax, pow(10.0, -3.0 / (sampleRate * max(0.01, tauK))))
            let omega = 2.0 * .pi * freq / sampleRate
            let cosO = cos(omega)
            let sinO = sin(omega)
            bank.rCosOmega[idx] = r * cosO
            bank.rSinOmega[idx] = r * sinO
            var g = 1.0 / pow(kd, falloff) * rmsNorm
            if k == 1 { g *= boost }
            bank.inGain[idx] = sinO * g
        }
        if active < bank.maxModes {
            for idx in active..<bank.maxModes {
                bank.rCosOmega[idx] = 0
                bank.rSinOmega[idx] = 0
                bank.inGain[idx] = 0
                bank.u[idx] = 0
                bank.v[idx] = 0
            }
        }
        // Breath bandpass follows the bank's fundamental — recompute here so
        // any f0 update (note-on, glide tick, detune change) refreshes it.
        recomputeBreathCoefs(bank: bank)
    }

    /// Compute the breath bandpass coefficients for a single bank. Centered
    /// on `bank.f0 · 2^(breathOffset/12)`; the log-frequency bandwidth in
    /// semitones (`breathSpread`) converts to an equivalent Q via
    ///   BW_hz = f_c · (2^(spread/24) − 2^(−spread/24)),  Q = f_c / BW_hz
    /// so the perceptual spread stays constant across pitches. Must be
    /// recalled whenever f0, breathOffset, or breathSpread changes.
    private func recomputeBreathCoefs(bank: ModalBank) {
        let sr = Config.sampleRate
        let pitchHz = bank.f0 > 0 ? bank.f0 : 440
        let centerHz = pitchHz * pow(2.0, breathOffset / 12.0)
        let f = max(20.0, min(0.45 * sr, centerHz))
        let half = max(0.15, breathSpread) * 0.5
        let bwHz = f * (pow(2.0, half / 12.0) - pow(2.0, -half / 12.0))
        let q = max(0.2, f / max(0.5, bwHz))
        let w = 2.0 * .pi * f / sr
        let alpha = sin(w) / (2.0 * q)
        let cosW = cos(w)
        let a0 = 1.0 + alpha
        bank.breathB0 = alpha / a0
        bank.breathB2 = -alpha / a0
        bank.breathA1 = -2.0 * cosW / a0
        bank.breathA2 = (1.0 - alpha) / a0
    }

    /// Update the pluck-position comb delay length for a bank based on its
    /// current f0. `P = round(pluckPosition · period_samples)`, clamped to
    /// the delay buffer size.
    private func updatePluckComb(bank: ModalBank) {
        let period = Config.sampleRate / max(1.0, bank.f0)
        let p = Int(pluckPosition * period)
        bank.pluckCombSize = max(0, min(Self.pluckCombMax - 1, p))
    }

    private func setupAudio() {
        let sampleRate = Config.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = ablPointer[0]
            let frames = Int(frameCount)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let renderStart = CACurrentMediaTime()
            for i in 0..<frames { data[i] = 0 }

            self.lock.lock()

            // Scratch buffer for the played-audio sum, reused as sym drive
            // input. Stack-allocated — safe against any hypothetical render
            // reentry and cheaper than holding a resizable `self.` buffer.
            withUnsafeTemporaryAllocation(of: Double.self, capacity: frames) { scratch in
                for i in 0..<frames { scratch[i] = 0 }

                // === Pass 1: played banks → scratch ===
                var activeCount = 0
                for ch in 0..<self.playedBanks.count {
                    let bank = self.playedBanks[ch]
                    if bank.state == .idle { continue }
                    activeCount += 1
                    self.renderPlayedBank(bank: bank, frames: frames, output: scratch.baseAddress!)
                    self.checkPlayedBankLifecycle(channel: ch)
                }

                // Equal-power gain across active played banks, then copy to
                // the real output. Sym drive reads raw scratch (pre-gain) so
                // sym excitation level is invariant to voice count.
                //
                // Plus a symCoupling-dependent compensation so total
                // loudness stays comparable as the player sweeps sym
                // coupling. Linear amplitude ramp:
                //   compensation = 1 + k · (1 − symCoupling)
                // with k = 4 → 1.0× at symCoupling=1 (baseline, unchanged)
                // and 5.0× at symCoupling=0 (+14 dB). Sym output is
                // unaffected because this multiplies only `scratch` after
                // the sym banks have already read it.
                let c = max(0.0, min(1.0, self.symCoupling))
                let symCompensation = 1.0 + 4.0 * (1.0 - c)
                let voiceGain = activeCount > 1 ? 1.0 / sqrt(Double(activeCount)) : 1.0
                let playedGain = voiceGain * symCompensation
                for i in 0..<frames {
                    data[i] = Float(scratch[i] * playedGain)
                }

                // === Pass 2: sym banks driven by scratch ===
                for s in 0..<self.symBanks.count {
                    let bank = self.symBanks[s]
                    let couplingGain = self.symCouplingGains[s]
                    // Silent-bank skip: check block-level energy and drive.
                    // Most sym banks are dark most of the time; this is the
                    // single biggest CPU win in typical play.
                    if bank.energy() < Self.silentBankThreshold &&
                        abs(couplingGain) < Self.silentBankThreshold {
                        continue
                    }
                    self.renderSymBank(bank: bank, couplingGain: couplingGain,
                                       frames: frames, playedSum: scratch.baseAddress!,
                                       output: data)
                }

                self.lastRenderVoiceCount = activeCount
            }

            self.lock.unlock()

            let elapsed = CACurrentMediaTime() - renderStart
            self.lastRenderTime = elapsed
            self.lastRenderFrames = frames
            let now = renderStart + elapsed
            if now > self.maxRenderTimeWindowEnd {
                self.maxRenderTime = elapsed
                self.maxRenderTimeWindowEnd = now + 1.0
            } else if elapsed > self.maxRenderTime {
                self.maxRenderTime = elapsed
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 25
        engine.connect(sourceNode, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isRunning = true
        } catch {
            print("AudioEngine failed to start: \(error)")
        }
    }

    // MARK: - Per-bank render (called from the audio callback under lock)

    /// Render one played bank into `output` (accumulating). Generates the
    /// excitation signal (pluck + bow noise) and runs the mode bank.
    private func renderPlayedBank(bank: ModalBank, frames: Int,
                                  output: UnsafeMutablePointer<Double>) {
        let modeCount = bank.modeCount
        let rC = bank.rCosOmega
        let rS = bank.rSinOmega
        let ig = bank.inGain
        let u = bank.u
        let v = bank.v
        let combDelay = bank.pluckCombDelay
        let combMax = Self.pluckCombMax
        let combSize = bank.pluckCombSize
        let bowGain = self.bowForce
        let gain = bank.outputGain
        // Breath bandpass is per-bank so the center frequency tracks this
        // voice's fundamental pitch.
        let brB0 = bank.breathB0
        let brB2 = bank.breathB2
        let brA1 = bank.breathA1
        let brA2 = bank.breathA2
        let brLevel = self.breathLevel

        for f in 0..<frames {
            // Excitation envelope ramps up to target on noteOn, falls to 0
            // on noteOff.
            bank.excEnv += (bank.excTarget - bank.excEnv) * bank.excAttackCoef

            // Pluck impulse burst — a short rectangular ramp at the start of
            // the note.
            var pluckSample = 0.0
            if bank.pluckSamplesRemaining > 0 {
                pluckSample = bank.pluckImpulseAmp / Double(Self.pluckBurstSamples)
                bank.pluckSamplesRemaining -= 1
            }

            // Pluck-position comb: y = x − x[n−P].
            var combed = pluckSample
            if combSize > 0 {
                let readIdx = (bank.pluckCombWriteIdx - combSize + combMax) % combMax
                combed = pluckSample - combDelay[readIdx]
            }
            combDelay[bank.pluckCombWriteIdx] = pluckSample
            bank.pluckCombWriteIdx = (bank.pluckCombWriteIdx + 1) % combMax

            // Per-sample noise sample, reused for both the bow LPF drive and
            // the breath bandpass (independent filter states; the noise
            // source itself can be shared).
            bank.noiseRng = bank.noiseRng &* 1664525 &+ 1013904223
            let raw = Double(bank.noiseRng) / Double(UInt32.max) * 2.0 - 1.0

            // Bow noise: LCG → one-pole LPF → env-scaled. Drives the modal
            // resonators.
            bank.noiseLP += Self.noiseLPCoef * (raw - bank.noiseLP)
            let bowSample = bank.noiseLP * bowGain * bank.excEnv

            let drive = combed + bowSample

            // Resonator bank (coupled form), active partials only.
            var mix = 0.0
            for m in 0..<modeCount {
                let u0 = rC[m] * u[m] - rS[m] * v[m] + drive * ig[m]
                let v0 = rS[m] * u[m] + rC[m] * v[m]
                u[m] = u0
                v[m] = v0
                mix += v0
            }

            // Breath bandpass (biquad, direct-form I). Runs in parallel to
            // the modal bank and mixes into the same output. This is the
            // unpitched noise component that makes bottles, flutes, and
            // breathy bowed sounds possible — it bypasses the modal array,
            // so a partialCount of 1 + high breathLevel gives a single-
            // resonance pitched glow under a wash of wind.
            if brLevel > 0 {
                let by = brB0 * raw + brB2 * bank.breathX2
                             - brA1 * bank.breathY1 - brA2 * bank.breathY2
                bank.breathX2 = bank.breathX1
                bank.breathX1 = raw
                bank.breathY2 = bank.breathY1
                bank.breathY1 = by
                mix += by * brLevel * bank.excEnv
            }

            output[f] += mix * gain
        }
    }

    /// Render one sympathetic bank. Drive is the played-audio sum × coupling
    /// gain, plus a tiny broadband-noise term scaled by coupling so mistuned
    /// sym strings still respond even when the played spectrum is narrow.
    private func renderSymBank(bank: ModalBank, couplingGain: Double,
                               frames: Int,
                               playedSum: UnsafePointer<Double>,
                               output: UnsafeMutablePointer<Float>) {
        let modeCount = bank.modeCount
        let rC = bank.rCosOmega
        let rS = bank.rSinOmega
        let ig = bank.inGain
        let u = bank.u
        let v = bank.v
        // Broadband-noise term scalar — small enough to be inaudible on its
        // own (no whitened background hiss from the sym bank) but enough to
        // ensure unmatched-partial sym strings still pick up energy.
        let broadbandScalar: Double = 0.005
        let noiseLevel = couplingGain * broadbandScalar
        let gain = bank.outputGain

        for f in 0..<frames {
            bank.noiseRng = bank.noiseRng &* 1664525 &+ 1013904223
            let raw = Double(bank.noiseRng) / Double(UInt32.max) * 2.0 - 1.0
            let drive = playedSum[f] * couplingGain + raw * noiseLevel

            var mix = 0.0
            for m in 0..<modeCount {
                let u0 = rC[m] * u[m] - rS[m] * v[m] + drive * ig[m]
                let v0 = rS[m] * u[m] + rC[m] * v[m]
                u[m] = u0
                v[m] = v0
                mix += v0
            }
            output[f] += Float(mix * gain)
        }
    }

    /// Move a released played bank to `.idle` once its ringing energy falls
    /// below the silent-bank threshold. No wall-clock timeout — long decays
    /// should ring as long as their mode Q dictates. The NoteManager frees
    /// its own channel slot when the release glide completes (independent
    /// of this audio-thread bank state), and `noteOn` will `resetState()`
    /// on re-use, so a long-ringing idle bank doesn't block polyphony.
    private func checkPlayedBankLifecycle(channel: Int) {
        let bank = playedBanks[channel]
        guard bank.state == .releasing else { return }
        if bank.energy() < Self.silentBankThreshold {
            bank.state = .idle
            bank.excEnv = 0
        }
    }

    // MARK: - Frequency helpers

    static func frequency(for midiNote: Int) -> Double {
        440.0 * pow(2.0, Double(midiNote - 69) / 12.0)
    }

    static func frequency(for midiNote: Double) -> Double {
        440.0 * pow(2.0, (midiNote - 69.0) / 12.0)
    }

    // MARK: - Played voice control

    func noteOn(channel: Int, midiNote: Int, velocity: Int) {
        let freq = Self.frequency(for: midiNote)
        let velNorm = Double(velocity) / 127.0
        let amp = velNorm * Config.maxAmplitude

        lock.lock()
        guard channel >= 0, channel < playedBanks.count else { lock.unlock(); return }
        let bank = playedBanks[channel]
        bank.resetState()
        bank.f0 = freq
        bank.velocity = velNorm
        bank.outputGain = 1.0
        bank.excTarget = amp
        // Default attack coef (will be overwritten by first updateVoiceParams).
        bank.excAttackCoef = Config.attackCoefficient
        // Fire the pluck impulse, scaled down as bowForce rises so bowed
        // presets don't get a pluck click competing with the sustain. Linear
        // fade: full pluck at bowForce=0, zero pluck by bowForce=0.2.
        let pluckness = max(0.0, 1.0 - bowForce * 5.0)
        bank.pluckImpulseAmp = velNorm * pluckness
        bank.pluckSamplesRemaining = Self.pluckBurstSamples
        bank.state = .sounding
        recomputeBankCoefficients(bank: bank, useSymDecay: false)
        updatePluckComb(bank: bank)
        lock.unlock()
    }

    func noteOff(channel: Int) {
        lock.lock()
        guard channel >= 0, channel < playedBanks.count else { lock.unlock(); return }
        let bank = playedBanks[channel]
        if bank.state == .sounding {
            bank.state = .releasing
            bank.excTarget = 0
        }
        lock.unlock()
    }

    func setFrequency(channel: Int, frequency: Double) {
        lockAndMeasure()
        if channel >= 0 && channel < playedBanks.count {
            let bank = playedBanks[channel]
            if bank.state != .idle && abs(bank.f0 - frequency) > 0.01 {
                bank.f0 = frequency
                recomputeBankCoefficients(bank: bank, useSymDecay: false)
                updatePluckComb(bank: bank)
            }
        }
        lock.unlock()
    }

    /// Batch setter for the per-tick played-bank parameters.
    /// `amplitude` drives the excitation target (bow drive level × output).
    /// `attackMs` sets the excitation envelope's per-sample smoothing.
    func updateVoiceParams(channel: Int, frequency: Double, amplitude: Double,
                           attackMs: Double) {
        let attackSeconds = max(0.001, attackMs / 1000.0)
        let coef = 1.0 / max(1.0, Config.sampleRate * attackSeconds)
        lockAndMeasure()
        if channel >= 0 && channel < playedBanks.count {
            let bank = playedBanks[channel]
            if bank.state == .sounding {
                if abs(bank.f0 - frequency) > 0.01 {
                    bank.f0 = frequency
                    recomputeBankCoefficients(bank: bank, useSymDecay: false)
                    updatePluckComb(bank: bank)
                }
                bank.excTarget = amplitude
                bank.excAttackCoef = coef
            }
        }
        lock.unlock()
    }

    func setReverbMix(_ percent: Float) {
        reverb.wetDryMix = max(0, min(100, percent))
    }

    /// Stops all played voices (marks releasing, lets modes ring down) and
    /// zeros sym coupling so sym banks also decay out.
    func stopAll() {
        lock.lock()
        for ch in 0..<playedBanks.count {
            let bank = playedBanks[ch]
            if bank.state != .idle {
                bank.state = .releasing
                bank.excTarget = 0
            }
        }
        for i in 0..<symCouplingGains.count { symCouplingGains[i] = 0 }
        lock.unlock()
    }

    // MARK: - Sympathetic configuration

    /// Rebuild the sympathetic-bank array from the provided nominal
    /// frequencies. Each nominal freq spawns two banks (−detune / +detune).
    /// State is reset; amps ramp up from 0 on first drive.
    func configureSympatheticVoices(frequencies: [Double]) {
        lockAndMeasure()
        var newBanks: [ModalBank] = []
        var newNominal: [Double] = []
        var newDir: [Double] = []
        newBanks.reserveCapacity(frequencies.count * 2)
        newNominal.reserveCapacity(frequencies.count * 2)
        newDir.reserveCapacity(frequencies.count * 2)
        for f in frequencies {
            for dir in [-1.0, 1.0] {
                let bank = ModalBank(maxModes: Self.symMaxModes)
                let detuneRatio = pow(2.0, dir * sympatheticDetuneCents / 1200.0)
                bank.f0 = f * detuneRatio
                bank.velocity = 1.0
                bank.outputGain = 1.0
                bank.state = .sounding  // sym banks stay sounding forever
                recomputeBankCoefficients(bank: bank, useSymDecay: true)
                newBanks.append(bank)
                newNominal.append(f)
                newDir.append(dir)
            }
        }
        symBanks = newBanks
        symNominalFreqs = newNominal
        symDetuneDir = newDir
        symCouplingGains = [Double](repeating: 0, count: newBanks.count)
        lock.unlock()
    }

    func setSympatheticDetune(cents: Double) {
        let clamped = max(0, cents)
        lockAndMeasure()
        if abs(clamped - sympatheticDetuneCents) > 0.001 {
            sympatheticDetuneCents = clamped
            for i in 0..<symBanks.count {
                let detuneRatio = pow(2.0, symDetuneDir[i] * clamped / 1200.0)
                symBanks[i].f0 = symNominalFreqs[i] * detuneRatio
                recomputeBankCoefficients(bank: symBanks[i], useSymDecay: true)
            }
        }
        lock.unlock()
    }

    /// Push new per-bank coupling gains — these values drive how strongly
    /// each sym bank absorbs energy from the played-audio sum. Method name
    /// kept for call-site compatibility with the previous (amp-target)
    /// semantics; the array's new consumer is the sym-render drive scalar.
    /// Values are multiplied by the current `symCoupling` so the mappable
    /// parameter scales the whole bus uniformly without a per-sample mult.
    func setSympatheticTargetAmps(_ amps: [Double]) {
        lockAndMeasure()
        if amps.count == symCouplingGains.count {
            let k = symCoupling
            for i in 0..<amps.count {
                symCouplingGains[i] = amps[i] * k
            }
        }
        lock.unlock()
    }

    var sympatheticVoiceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return symBanks.count
    }

    // MARK: - Global parameter setters

    /// Recompute coefficients across all banks. Called by any setter that
    /// changes a global parameter affecting all modes.
    private func recomputeAllBanks() {
        for bank in playedBanks {
            if bank.state != .idle {
                recomputeBankCoefficients(bank: bank, useSymDecay: false)
            }
        }
        for bank in symBanks {
            recomputeBankCoefficients(bank: bank, useSymDecay: true)
        }
    }

    func setHarmonicFalloff(_ value: Double) {
        let clamped = max(0, value)
        lockAndMeasure()
        if abs(clamped - harmonicFalloff) > 0.005 {
            harmonicFalloff = clamped
            recomputeAllBanks()
        }
        lock.unlock()
    }

    func setBowForce(_ level: Double) {
        lockAndMeasure()
        bowForce = max(0, level)
        lock.unlock()
    }

    func setStringDecay(_ seconds: Double) {
        let clamped = max(0.05, seconds)
        lockAndMeasure()
        if abs(clamped - stringDecay) > 0.005 {
            stringDecay = clamped
            for bank in playedBanks where bank.state != .idle {
                recomputeBankCoefficients(bank: bank, useSymDecay: false)
            }
        }
        lock.unlock()
    }

    func setSymDecay(_ seconds: Double) {
        let clamped = max(0.05, seconds)
        lockAndMeasure()
        if abs(clamped - symDecay) > 0.005 {
            symDecay = clamped
            for bank in symBanks {
                recomputeBankCoefficients(bank: bank, useSymDecay: true)
            }
        }
        lock.unlock()
    }

    func setDampingTilt(_ alpha: Double) {
        let clamped = max(0, alpha)
        lockAndMeasure()
        if abs(clamped - dampingTilt) > 0.005 {
            dampingTilt = clamped
            recomputeAllBanks()
        }
        lock.unlock()
    }

    func setInharmonicity(_ B: Double) {
        let clamped = max(0, B)
        lockAndMeasure()
        if abs(clamped - inharmonicity) > 1e-5 {
            inharmonicity = clamped
            recomputeAllBanks()
        }
        lock.unlock()
    }

    func setSymCoupling(_ value: Double) {
        lockAndMeasure()
        symCoupling = max(0, value)
        lock.unlock()
    }

    func setPluckPosition(_ value: Double) {
        let clamped = max(0, min(0.5, value))
        lockAndMeasure()
        if abs(clamped - pluckPosition) > 0.001 {
            pluckPosition = clamped
            for bank in playedBanks where bank.state != .idle {
                updatePluckComb(bank: bank)
            }
        }
        lock.unlock()
    }

    func setPartialCount(_ count: Int) {
        let clamped = max(1, min(Self.playedMaxModes, count))
        lockAndMeasure()
        if clamped != partialCount {
            partialCount = clamped
            recomputeAllBanks()
        }
        lock.unlock()
    }

    func setFundamentalBoost(_ value: Double) {
        let clamped = max(1.0, value)
        lockAndMeasure()
        if abs(clamped - fundamentalBoost) > 0.005 {
            fundamentalBoost = clamped
            recomputeAllBanks()
        }
        lock.unlock()
    }

    func setBreathLevel(_ value: Double) {
        lockAndMeasure()
        breathLevel = max(0, value)
        lock.unlock()
    }

    func setBreathOffset(_ semitones: Double) {
        let clamped = max(-48.0, min(48.0, semitones))
        lockAndMeasure()
        if abs(clamped - breathOffset) > 0.01 {
            breathOffset = clamped
            for bank in playedBanks where bank.state != .idle {
                recomputeBreathCoefs(bank: bank)
            }
        }
        lock.unlock()
    }

    func setBreathSpread(_ semitones: Double) {
        let clamped = max(0.1, semitones)
        lockAndMeasure()
        if abs(clamped - breathSpread) > 0.01 {
            breathSpread = clamped
            for bank in playedBanks where bank.state != .idle {
                recomputeBreathCoefs(bank: bank)
            }
        }
        lock.unlock()
    }

    deinit {
        engine.stop()
    }
}
