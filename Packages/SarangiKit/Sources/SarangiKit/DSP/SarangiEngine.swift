import Foundation

/// Live (non-structural) scalar parameters the render thread reads every buffer.
/// These are gains/mixes that need no filter redesign (per the plan's param
/// classification). Updated lock-free; the rest are baked into the engine's
/// filter coefficients and changing them rebuilds the engine.
public struct LiveScalars: Sendable {
    public var gin = 1.0, gout = 1.0
    public var mixDry = 0.85, mixBank = 0.5, mixJaw = 1.0
    public var mainGain = 1.0, symGain = 12.0
    public var bGain = 0.4, bBright = 0.8, toBank = 0.3, symBowFollow = 0.7
    public var cDriveMin = 1.5, cDriveMax = 12.0, cAsym = 0.3, cWet = 0.25, cRasp = 0.2, cTop = 0.15
    public var eBody = 1.0
    // Per-voice FX live state (enabled + reverb mix/width per stage). The
    // structural FX (filter/EQ/rt60) bakes into the VoiceFX at rebuild.
    public var violinFXOn = true,  violinReverbMix = 0.25, violinReverbWidth = 0.4
    public var symFXOn = false,    symReverbMix = 0.25,    symReverbWidth = 0.3
    public var globalFXOn = false, globalReverbMix = 0.2,  globalReverbWidth = 0.2

    public init() {}
    public init(_ p: SarangiParams) {
        gin = p.gin; gout = p.gout
        mixDry = p["mix_dry"]; mixBank = p["mix_bank"]; mixJaw = p["mix_jaw"]
        mainGain = p["main_gain"]; symGain = p["sym_gain"]
        bGain = p["B_gain"]; bBright = p["B_bright"]; toBank = p["C_to_bank"]; symBowFollow = p["sym_bow_follow"]
        cDriveMin = p["C_drive_min"]; cDriveMax = p["C_drive_max"]; cAsym = p["C_asym"]
        cWet = p["C_wet"]; cRasp = p["C_rasp"]; cTop = p["C_top"]
        eBody = p["E_body"]
    }

    /// Pull the live FX fields from a rack (the structural fields rebuild the engine).
    public mutating func applyFX(_ fx: FXRack) {
        violinFXOn = fx.violin.enabled; violinReverbMix = fx.violin.reverbMix; violinReverbWidth = fx.violin.reverbWidth
        symFXOn = fx.sym.enabled; symReverbMix = fx.sym.reverbMix; symReverbWidth = fx.sym.reverbWidth
        globalFXOn = fx.global.enabled; globalReverbMix = fx.global.reverbMix; globalReverbWidth = fx.global.reverbWidth
    }
}

/// The full sarangi processor — assembles blocks B/C/D/E/F per `chain.process`,
/// mono-internal and stereo only at block F. The **structural** coefficients
/// (bank, body, jawari/drone/reverb designs) are baked at init from `params` +
/// `strings`; changing a structural param rebuilds the engine (swapped lock-free
/// by the host). `scalars` are live gains/mixes updated every buffer.
///
/// `amp` ∈ [0,1] is the note's amplitude envelope: velocity-driven live, or a
/// signal follower offline (see `SignalAmpFollower`). It drives the jawari
/// drive/sweep/swell — the live replacement for the offline `env/env.max()`
/// normalisation.
public final class SarangiEngine {
    public let sr: Double
    public let tonic: Double

    var bank: ResonatorBank
    // Body color (block E) is split per voice so each gets its own energy-matched
    // ring (colorSupplement's RMS match makes it non-additive — can't share one).
    var bodyViolin: BodyColor
    var bodySym: BodyColor
    var dryFIR: FIRFilter?          // block E body transfer (per-preset), on the dry branch
    var jawari: JawariExciter
    // Starpad-local per-voice FX rack (replaces the single block-F reverb).
    var violinFX: VoiceFX
    var symFX: VoiceFX
    var globalFX: VoiceFX
    public var scalars: LiveScalars

    // Dedicated fast bow-envelope follower for the sym (bank) gate — decoupled
    // from the slower `amp` the jawari/drone use, so the sym can fade tightly
    // with the bow (≈90 ms release) instead of `amp`'s 180 ms.
    private let symEnvAtk: Double
    private let symEnvRel: Double
    private var symEnvState = 0.0

    // Recent post-`gin` drive (`x`), a small circular buffer feeding the Live-tab
    // harmonic display's "Played note" column. Written once per sample; read
    // (copied) under the host lock by `bankRawSnapshot`. DSP-inert.
    private var inputRing: [Double]
    private var inputRingIdx = 0

    // per-buffer cache
    private var c_gin = 1.0, c_gout = 1.0
    private var c_mainGain = 1.0, c_symGain = 1.0
    private var c_mixDry = 0.0, c_mixBank = 0.0, c_mixJaw = 0.0
    private var c_bGain = 0.0, c_bBright = 0.0, c_toBank = 0.0, c_symBowFollow = 0.0

    public init(params p: SarangiParams, strings: [ResolvedString], tonic: Double, sr: Double,
                firTaps: [Double]? = nil, fx: FXRack = .makeDefault(), groups: [StringGroup] = []) {
        self.sr = sr
        self.tonic = tonic
        var s = LiveScalars(p); s.applyFX(fx)
        self.scalars = s
        symEnvAtk = exp(-1.0 / (sr * 0.005))    // 5 ms attack
        symEnvRel = exp(-1.0 / (sr * 0.090))    // 90 ms release
        inputRing = [Double](repeating: 0, count: SarangiEngine.inputRingLength)
        bank = ResonatorBank.build(strings: strings, groups: groups,
                                   t60Scale: p["B_t60_scale"], bLp: p["B_lp"], sr: sr)
        bodyViolin = BodyColor(eModes: p.eModes, eBody: p["E_body"],
                               lowShelfF: p["E_low_shelf_f"], lowShelfDB: p["E_low_shelf_db"], sr: sr)
        bodySym = BodyColor(eModes: p.eModes, eBody: p["E_body"],
                            lowShelfF: p["E_low_shelf_f"], lowShelfDB: p["E_low_shelf_db"], sr: sr)
        if let firTaps, !firTaps.isEmpty { dryFIR = FIRFilter(taps: firTaps) }
        jawari = JawariExciter(tonic: tonic, sr: sr,
                               preHpHz: p["C_pre_hp"], sweepLo: p["C_sweep_lo"], sweepHi: p["C_sweep_hi"],
                               driveMin: p["C_drive_min"], driveMax: p["C_drive_max"], asym: p["C_asym"],
                               wet: p["C_wet"], rasp: p["C_rasp"], top: p["C_top"])
        violinFX = VoiceFX(fx.violin, sr: sr)
        symFX = VoiceFX(fx.sym, sr: sr)
        globalFX = VoiceFX(fx.global, sr: sr)
    }

    /// Push live scalars into the blocks and cache the per-buffer constants.
    /// Call once per render buffer before `renderSample`.
    public func beginBuffer() {
        jawari.driveMin = scalars.cDriveMin; jawari.driveMax = scalars.cDriveMax
        jawari.asym = scalars.cAsym; jawari.wet = scalars.cWet
        jawari.rasp = scalars.cRasp; jawari.top = scalars.cTop
        bodyViolin.wet = scalars.eBody; bodySym.wet = scalars.eBody
        // Live FX: enabled + reverb mix/width per stage (filter/EQ are structural).
        violinFX.enabled = scalars.violinFXOn
        violinFX.reverb.mix = scalars.violinReverbMix; violinFX.reverb.width = scalars.violinReverbWidth
        symFX.enabled = scalars.symFXOn
        symFX.reverb.mix = scalars.symReverbMix; symFX.reverb.width = scalars.symReverbWidth
        globalFX.enabled = scalars.globalFXOn
        globalFX.reverb.mix = scalars.globalReverbMix; globalFX.reverb.width = scalars.globalReverbWidth
        c_gin = scalars.gin; c_gout = scalars.gout
        c_mainGain = scalars.mainGain; c_symGain = scalars.symGain
        c_mixDry = scalars.mixDry; c_mixBank = scalars.mixBank
        c_mixJaw = scalars.mixJaw
        c_bGain = scalars.bGain; c_bBright = scalars.bBright; c_toBank = scalars.toBank
        c_symBowFollow = max(0, min(1, scalars.symBowFollow))
    }

    public func renderSample(_ input: Double, amp: Double) -> (Double, Double) {
        let x = input * c_gin
        inputRing[inputRingIdx] = x                          // tap the drive (Live display)
        inputRingIdx = (inputRingIdx + 1) % inputRing.count
        let jaw = jawari.process(x, amp: amp)
        let bankOut = bank.process(cleanDrive: x, brightDrive: x + c_toBank * jaw,
                                   gClean: c_bGain, gBright: c_bGain * c_bBright)
        // Responsiveness: gate the free-ringing comb bank toward a fast bow
        // envelope so it fades WITH the note instead of ringing on its own long
        // t60 (the late "second peak"). The follower attacks in 5 ms (≈1 during
        // the note → no change) and releases in 90 ms (after note-off the sym
        // tail collapses to track the bow). `sym_bow_follow` sets the depth.
        let bowAbs = abs(x)
        let sa = bowAbs > symEnvState ? symEnvAtk : symEnvRel
        symEnvState = (1 - sa) * bowAbs + sa * symEnvState
        let symEnv = min(1.0, symEnvState / 0.1)
        let symGate = (1 - c_symBowFollow) + c_symBowFollow * symEnv
        // The bank is excited by the RAW drive (computed above), so the violin
        // "drives the sym" before any output gain or FX. main = bowed note (dry +
        // jawari buzz); sym = the sympathetic BANK. Each voice gets its OWN body
        // ring + FX stage; the violin FX therefore applies AFTER the violin has
        // driven the sym, before the global stage. (Per-voice FX replaces the
        // single block-F reverb. Starpad-local.)
        // VIOLIN voice (mono): dry (low-shelf) + jawari (body ring) → violin FX.
        let violinSupp = bodyViolin.colorSupplement(c_mainGain * (c_mixJaw * jaw))
        let dryIn = dryFIR != nil ? dryFIR!.process(x) : x
        let dry = bodyViolin.colorDry(dryIn)
        let violin = c_mainGain * c_mixDry * dry + violinSupp
        let (vl, vr) = violinFX.process(violin)
        // SYM voice (mono): bank (body ring) → sym FX.
        let sym = bodySym.colorSupplement(c_symGain * (c_mixBank * bankOut * symGate))
        let (sl, sr) = symFX.process(sym)
        // SUM → GLOBAL stage. Mid/side so global-OFF is an exact passthrough:
        // global FX processes the mono mid, the original side is re-injected dry.
        let L = vl + sl, R = vr + sr
        let m = 0.5 * (L + R), sdiff = 0.5 * (L - R)
        let (gl, gr) = globalFX.process(m)
        return (SarangiEngine.softClip(c_gout * (gl + sdiff)),
                SarangiEngine.softClip(c_gout * (gr - sdiff)))
    }

    public func reset() {
        bank.reset(); bodyViolin.reset(); bodySym.reset(); dryFIR?.reset(); jawari.reset()
        violinFX.reset(); symFX.reset(); globalFX.reset()
        symEnvState = 0
        for i in inputRing.indices { inputRing[i] = 0 }; inputRingIdx = 0
    }

    /// Length of the played-note input ring (~46 ms at 44.1 kHz) — long enough to
    /// resolve harmonics of low played pitches in the windowed DFT.
    static let inputRingLength = 2048

    /// Copy the live bank + input state for the Live-tab harmonic display. Pure
    /// copies (no DFT) so the caller can hold the host lock only briefly, then
    /// analyse off-lock. `playedF0`/`playedActive` are filled by the host (it
    /// owns the MIDI pitch). See `BankAnalyzer.analyze`.
    public func bankRawSnapshot() -> BankRawSnapshot {
        let gClean = c_bGain, gBright = c_bGain * c_bBright
        let sym = c_symGain, mix = c_mixBank
        var strs: [StringRawSnapshot] = []; strs.reserveCapacity(bank.count)
        for i in bank.strings.indices {
            let bright = bank.isBright[i]
            let weight = bank.relOverSqrtN[i] * (bright ? gBright : gClean) * sym * mix
            let L = bank.strings[i].period
            strs.append(StringRawSnapshot(freq: sr / Double(max(1, L)),
                                          isBright: bright,
                                          group: i < bank.groups.count ? bank.groups[i] : .scale,
                                          outWeight: weight,
                                          period: L,
                                          buffer: bank.strings[i].bufferCopy()))
        }
        // Re-order the input ring into time order so the windowed DFT sees a clean
        // run (oldest-first); magnitude is phase-invariant but a contiguous Hann
        // window wants the samples in order.
        var ring = [Double](repeating: 0, count: inputRing.count)
        let n = inputRing.count
        for j in 0..<n { ring[j] = inputRing[(inputRingIdx + j) % n] }
        return BankRawSnapshot(sr: sr, strings: strs, inputRing: ring,
                               playedWeight: c_mainGain * c_mixDry,
                               playedF0: 0, playedActive: false)
    }

    /// Soft-clip backstop so pushing the gains / drive can't hard-clip the output
    /// (linear below 0.9, smoothly saturating to ~1.0 above). The standalone
    /// model had no limiter because it ran at a fixed fitted level; Starpad's
    /// tunable drive/gains need this.
    @inline(__always) static func softClip(_ x: Double) -> Double {
        if x > 0.9 { return 0.9 + 0.1 * tanh((x - 0.9) / 0.1) }
        if x < -0.9 { return -0.9 - 0.1 * tanh((-x - 0.9) / 0.1) }
        return x
    }

    /// Offline convenience: process a whole mono buffer (amp derived from the
    /// signal). Returns interleaved-free (L, R). Used by the parity harness.
    public func renderOffline(_ input: [Double]) -> (l: [Double], r: [Double]) {
        beginBuffer()
        // Offline-faithful amplitude envelope: one-pole release follower on |x|
        // normalised by the take's GLOBAL max — exactly as the Python model's
        // env/env.max() (the live path uses a causal follower instead).
        let a = exp(-1.0 / (sr * 0.25))     // 250 ms release (blocks._envelope)
        var env = 0.0
        var amp = [Double](repeating: 0, count: input.count)
        for n in input.indices { env = (1 - a) * abs(input[n] * scalars.gin) + a * env; amp[n] = env }
        let mx = (amp.max() ?? 1) + 1e-12
        for n in amp.indices { amp[n] = min(1.0, amp[n] / mx) }

        var l = [Double](repeating: 0, count: input.count)
        var r = [Double](repeating: 0, count: input.count)
        for n in input.indices {
            let (lv, rv) = renderSample(input[n], amp: amp[n])
            l[n] = lv; r[n] = rv
        }
        return (l, r)
    }
}

/// Derives a 0..1 amplitude envelope from the audio (against a **fixed
/// reference** level, so a quiet note stays dark instead of re-normalising
/// bright). **Fast-attack / slow-release peak follower:** it snaps up on the
/// note ONSET (attack ≈ a few ms) but fades slowly (release ≈ the old time
/// constant). A *symmetric* slow follower made everything `amp` drives — the
/// jawari swell + drone gate — bloom ~one attack-time AFTER the bowed peak, an
/// audible second peak on staccato. Because attack ≪ release the follower rides
/// the rectified peaks (no per-cycle ripple), so the envelope stays smooth while
/// tracking onsets immediately. Used identically offline and live.
public struct SignalAmpFollower: Sendable {
    var env: Double = 0
    let aAtk: Double, aRel: Double
    public var reference: Double
    public init(sr: Double, attackMs: Double = 5, releaseMs: Double = 180, reference: Double = 0.1) {
        aAtk = exp(-1.0 / (sr * attackMs / 1000.0))
        aRel = exp(-1.0 / (sr * releaseMs / 1000.0))
        self.reference = reference
    }
    public mutating func process(_ x: Double) -> Double {
        let r = abs(x)
        let a = r > env ? aAtk : aRel        // fast when rising, slow when falling
        env = (1 - a) * r + a * env
        return min(1.0, env / (reference + 1e-12))
    }
    public mutating func reset() { env = 0 }
}
