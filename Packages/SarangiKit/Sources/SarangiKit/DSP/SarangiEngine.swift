import Foundation

/// Live (non-structural) scalar parameters the render thread reads every buffer.
/// v57-era set (2026-07-12 simplification): the engine is the PASSIVE coupled
/// network only, so the legacy dry/jawari/sym mixes are gone — what remains
/// are the junction's live gains and the output stages.
///
/// STARPAD DIVERGENCE: also carries the live bits of the per-voice FX rack
/// (`applyFX` — stage enable + reverb mix/width), pushed into the `VoiceFX`
/// stages once per buffer in `beginBuffer`.
public struct LiveScalars: Sendable {
    public var gin = 1.0, gout = 1.0
    public var mixDrone = 0.0
    public var mainGain = 1.0
    public var bGain = 0.4, bBright = 0.8, bSpread = 0.7
    public var fMix = 0.0

    // -- Starpad FX rack (live bits) --
    public var fxPreEnabled = false
    public var fxPreMix = 0.0, fxPreWidth = 0.3
    public var fxGlobalEnabled = false
    public var fxGlobalMix = 0.2, fxGlobalWidth = 0.2

    public init() {}
    public init(_ p: SarangiParams) {
        gin = p.gin; gout = p.gout
        mixDrone = p["mix_drone"]
        mainGain = p["main_gain"]
        bGain = p["B_gain"]; bBright = p["B_bright"]; bSpread = p["B_spread"]
        fMix = p["F_mix"]
    }

    /// Starpad: fold the FX rack's live fields in (enable + reverb mix/width;
    /// the filters/EQ ride `SarangiEngine.setVoiceFXFilters`, RT60 is structural).
    public mutating func applyFX(_ fx: FXRack) {
        fxPreEnabled = fx.violinPre.enabled
        fxPreMix = fx.violinPre.reverbMix; fxPreWidth = fx.violinPre.reverbWidth
        fxGlobalEnabled = fx.global.enabled
        fxGlobalMix = fx.global.reverbMix; fxGlobalWidth = fx.global.reverbWidth
    }
}

/// The sarangi processor — SINCE 2026-07-12 this is ONE instrument, ONE
/// render path: the v57 coupled bridge–body network with the PASSIVE wave
/// junction (`coupled.junction_solve`, parity ≤1e-9 vs the FFT closed form,
/// Goldens/coupled_passive.json). The pre-v57 eras — legacy feedforward
/// chain, κ-loop coupled fallback + CoupledLoopGuard, and the app-side bow
/// mode — were removed in the v57-only simplification (git history has
/// them; the bow instrument lives on OFFLINE and in the upstream repo's
/// SarangiKit/Bow for the bow-render confirm tool).
///
/// Structural coefficients (bank combs, body, drone, reverb, radiation FIR)
/// are baked at init from `params` + `strings`; changing a structural param
/// rebuilds the engine (swapped lock-free by the host). `scalars` are live
/// gains updated every buffer.
///
/// STARPAD DIVERGENCES (marked sections below): `VoiceEQBand` (renamed from
/// upstream `EQBand` — the FX rack owns that name here), the two-stage FX rack
/// (`violinPre` pre-drive + `global` output, Starpad-local), the FX spectrum
/// rings, and the Harmonics-tab bank snapshot (`bankRawSnapshot`).
public final class SarangiEngine {
    public let sr: Double
    public let tonic: Double

    var bank: ResonatorBank
    // USER EQ — applied at the OUTPUT, default FLAT (dehornA = selectable
    // preset, superseded by the fitted W valley).
    var outEQL: BiquadChain
    var outEQR: BiquadChain
    var drone: DroneGen
    var reverb: Reverb
    var radLpL: Biquad?           // fitted E_lp radiation low-pass
    var radLpR: Biquad?
    public var scalars: LiveScalars

    // ---- COUPLED bridge–body network ----
    let coupledCfg: CoupledConfig?
    var bodyAdm: BodyAdmittance?
    var wSide: WModalBank?
    // centre radiation of the jawari-buzz DELTA (ΣΔf): the buzz colors the
    // RADIATED force copy only (offline lockstep — the junction solve stays
    // linear), so its centre share needs its own W bank alongside radC
    var wBuzz: WModalBank?
    var playedCombs: [CombString] = []
    var playedW = 0.0
    var radFIRL: FIRFilter?
    var radFIRR: FIRFilter?
    var vBridgePrev = 0.0
    private var pLpA = 0.0
    private var pLpState = 0.0
    // Direct taraf-velocity radiation tap (v57): the taraf bank's own
    // weighted motion reaching the ear past the body's W — string-Q-sharp
    // ring lines the Q≤12 modal radiation cannot carry (coupled.py
    // N_taraf_dir; the passive junction clamps free decay at string poles).
    // Two cascaded one-poles at N_taraf_dir_lp = the causal twin of the
    // offline zero-phase 1/(1+(f/fc)²) radiation-efficiency magnitude.
    private var tarafDir = 0.0
    private var dirLpA = 0.0
    private var dirLp1 = 0.0
    private var dirLp2 = 0.0

    // ---- PASSIVE WAVE JUNCTION ----
    // The live twin of coupled.junction_solve / the C kernel's passive
    // branch: every string loads the bridge with Z_in = Z(1+G)/(1−G) and V
    // is solved DELAY-FREE per sample — V = (Vst + y0·F0)/(1 + y0·ΣZ).
    // Structurally stable (denominator provably ≥ 1): no guard exists.
    // Tables recomputed per buffer from the live bank gains
    // (coupled.junction_Z: Z_i ∝ w_i/mean — B_gain cancels within a choir,
    // exactly the offline law).
    private var passiveOn = false
    private var pBodyY0 = 0.0
    private var pInclude: [Bool] = []
    private var pW: [Double] = []
    private var pZi: [Double] = []
    private var pZdrv: [Double] = []
    private var pPlayedZdrv: [Double] = []
    private var pPlayedS: [Double] = []
    private var pJzsum = 0.0
    private var pSumW = 0.0
    private var pTapW = 0.0
    private var pAlphaW = 0.0

    // per-buffer cache
    private var c_gin = 1.0, c_gout = 1.0
    private var c_mainGain = 1.0
    private var c_mixDrone = 0.0
    private var c_bGain = 0.0, c_bBright = 0.0

    // ---- STARPAD: per-voice FX rack (violinPre pre-drive + global output) ----
    var violinPreFX: VoiceFX
    var globalFX: VoiceFX
    /// Pre-EQ spectrum rings for the FX tab (time-ordered copies leave via
    /// `fxSpectrumRawSnapshot`). `inputRing` doubles as the Harmonics tab's
    /// played-note drive window.
    public static let fxRingLength = 4096
    private var inputRing = [Double](repeating: 0, count: SarangiEngine.fxRingLength)
    private var inputRingIdx = 0
    private var globalRing = [Double](repeating: 0, count: SarangiEngine.fxRingLength)
    private var globalRingIdx = 0

    public init(params p: SarangiParams, strings: [ResolvedString], tonic: Double, sr: Double,
                eqBands: [VoiceEQBand] = [], coupled: CoupledConfig? = nil,
                fx: FXRack = .makeDefault(), groups: [StringGroup] = []) {
        self.sr = sr
        self.tonic = tonic
        var sc = LiveScalars(p)
        sc.applyFX(fx)
        self.scalars = sc
        self.coupledCfg = coupled
        violinPreFX = VoiceFX(fx.violinPre, sr: sr)
        globalFX = VoiceFX(fx.global, sr: sr)
        if let cfg = coupled {
            bodyAdm = BodyAdmittance(modes: cfg.modes, a: cfg.resA,
                                     c: cfg.resC, yinf: cfg.yinf, c0: cfg.c0,
                                     sr: sr)
            wSide = WModalBank(modes: cfg.modes, c: cfg.resC, c0: cfg.c0,
                               sr: sr)
            if max(p["N_jaw_raga"], p["N_jaw_chrom"]) > 1e-3 {
                wBuzz = WModalBank(modes: cfg.modes, c: cfg.resC, c0: cfg.c0,
                                   sr: sr)
            }
            // 3 open-tuned played strings (web comb at inharm 0 / damp 0 =
            // exact fractional-delay tuning, coupled.PLAYED_RATIOS lockstep)
            playedCombs = CoupledConfig.playedRatios.map {
                CombString(f0: tonic * $0, t60: cfg.playedT60, sr: sr,
                           bright: cfg.playedBright, web: true)
            }
            playedW = cfg.playedGain
                / Double(CoupledConfig.playedRatios.count).squareRoot()
            let rTaps = cfg.rfirTaps(sr: sr)
            if !rTaps.isEmpty {
                radFIRL = FIRFilter(taps: rTaps)
                radFIRR = FIRFilter(taps: rTaps)
            }
            pLpA = exp(-2.0 * Double.pi * min(cfg.pFc, 0.45 * sr) / sr)
            // v57 tap: params-carried (preset), NOT from sarangi_coupled.json
            // — the bow tables read that artifact's N_taraf_dir and must not
            // inherit the coupled-mode ear pick.
            tarafDir = p["N_taraf_dir"]
            let dfc = p["N_taraf_dir_lp"]
            dirLpA = dfc > 0 ? exp(-2.0 * Double.pi * min(dfc, 0.45 * sr) / sr)
                             : 0.0                     // <=0 = unshaped (legacy)
        }
        let eqSections = eqBands.filter(\.enabled).map { $0.biquad(sr: sr) }
        outEQL = BiquadChain(eqSections)
        outEQR = BiquadChain(eqSections)
        bank = ResonatorBank.build(strings: strings, t60Scale: p["B_t60_scale"],
                                   bLp: p["B_lp"], sr: sr,
                                   polSplit: p["B_pol_split"],
                                   polGain: p["B_pol_gain"],
                                   polT60: p["B_pol_t60"],
                                   inharm: p["B_inharm"],
                                   damp: p["B_damp"],
                                   groups: groups)
        // per-class jawari (it22 law; N_jaw_lp = the buzz radiation LP —
        // preset-carried like the tap, ear-owned depths)
        bank.configureJawari(raga: p["N_jaw_raga"], chrom: p["N_jaw_chrom"],
                             lpHz: p["N_jaw_lp"], sr: sr)
        drone = DroneGen(f0: tonic / 4.0, t60: p["D_t60"], level: p["D_level"],
                         nHarm: Int(p["D_nharm"].rounded()),
                         floor: p["D_floor"], sr: sr)
        let eLp = p["E_lp"]
        if eLp > 0, eLp < 0.44 * sr {
            radLpL = Biquad.lowpass(fc: eLp, sr: sr)
            radLpR = Biquad.lowpass(fc: eLp, sr: sr)
        }
        reverb = Reverb(rt60: p["F_rt60"], predelayMs: p["F_predelay"],
                        mix: p["F_mix"], width: p["F_width"], sr: sr)

        // Passive junction arming: the artifact carries N_junction "passive"
        // + the two Z scalars (post-2026-07-09 physics — what every fitted
        // value was fit under).
        if let cfg = coupledCfg, cfg.passive, bodyAdm != nil {
            passiveOn = true
            pBodyY0 = bodyAdm!.y0
            pInclude = [Bool](repeating: false, count: bank.count)
            pW = [Double](repeating: 0, count: bank.count)
            pZi = [Double](repeating: 0, count: bank.count)
            pZdrv = [Double](repeating: 0, count: bank.count)
            pPlayedZdrv = [Double](repeating: 0, count: playedCombs.count)
            pPlayedS = [Double](repeating: 0, count: playedCombs.count)
        }
    }

    /// The engine is playable only with the passive coupled artifact
    /// (sarangi_coupled.json, N_junction "passive"). Hosts should
    /// check this at load and surface a configuration error otherwise —
    /// `renderSample` outputs silence when unarmed.
    public var isArmed: Bool { passiveOn }

    /// Push live scalars into the blocks and cache the per-buffer constants.
    /// Call once per render buffer before `renderSample`.
    public func beginBuffer() {
        reverb.mix = scalars.fMix
        c_gin = scalars.gin; c_gout = scalars.gout
        c_mainGain = scalars.mainGain
        c_mixDrone = scalars.mixDrone
        c_bGain = scalars.bGain; c_bBright = scalars.bBright
        // Starpad: push the FX rack's live bits into the stages
        violinPreFX.enabled = scalars.fxPreEnabled
        violinPreFX.reverb.mix = scalars.fxPreMix
        violinPreFX.reverb.width = scalars.fxPreWidth
        globalFX.enabled = scalars.fxGlobalEnabled
        globalFX.reverb.mix = scalars.fxGlobalMix
        globalFX.reverb.width = scalars.fxGlobalWidth
        // Passive-junction impedance tables (coupled.junction_Z): Z_i =
        // N_Z_taraf·(w_i/mean w) with w = choir_gain·rel/√n — mean-normalized
        // so B_gain cancels within a choir. Silent choirs are DROPPED (the
        // offline builder never emits them; a 0-weight string must not enter
        // the mean). zdrv = 2·Z/(1−g) realizes Z(1+G)/(1−G) on the comb.
        if passiveOn, let cfg = coupledCfg {
            let gC = c_bGain
            let gB = c_bGain * c_bBright
            var wsum = 0.0
            var n = 0
            for i in 0..<bank.count {
                let g = bank.isBright[i] ? gB : gC
                pInclude[i] = abs(g) > 1e-6
                pW[i] = g * bank.relOverSqrtN[i]
                if pInclude[i] { wsum += pW[i]; n += 1 }
            }
            let wmean = n > 0 ? wsum / Double(n) : 1.0
            var jz = 0.0
            pSumW = 0.0
            for i in 0..<bank.count where pInclude[i] {
                let zi = cfg.loop * cfg.zTaraf * pW[i] / wmean
                pZi[i] = zi
                pZdrv[i] = 2.0 * zi / bank.strings[i].feedthrough
                jz += zi
                pSumW += pW[i]
            }
            let ziPlayed = cfg.loop * cfg.zPlayed
            for j in playedCombs.indices {
                pPlayedZdrv[j] = 2.0 * ziPlayed / playedCombs[j].feedthrough
            }
            jz += Double(playedCombs.count) * ziPlayed
            pJzsum = jz
            pTapW = n > 0 ? wmean / (cfg.loop * cfg.zTaraf) : 0.0
            pAlphaW = playedW * cfg.alpha
        }
    }

    public func renderSample(_ input: Double) -> (Double, Double) {
        guard passiveOn else { return (0, 0) }
        return renderSamplePassive(input)
    }

    /// PASSIVE WAVE JUNCTION render (the v57 instrument). Per sample,
    /// mirroring coupled.junction_solve and the C kernel's two-pass split:
    ///   F0 = P(x) + drone + Σ S_i + Σ_played (1−g)·w·α·x   (V-independent)
    ///   V  = (Vst + y0·F0)/(1 + y0·ΣZ)                      (delay-free)
    ///   F  = F0 − ΣZ·V;  (V, rad) = body(F)                 (states committed)
    ///   pass 2: every comb at x_i = w·α·x − zdrv_i·V; f_i = y_i + Z_i·V
    ///   L,R = ½(rad ± W(Σ pan·f_i)) + tap → radiation FIR → E_lp → reverb
    /// STARPAD: the `violinPre` FX stage shapes `input` BEFORE the network
    /// (mono, collapsed to mid — off = exact passthrough) and the `global`
    /// stage shapes the output mid/side (off = exact passthrough).
    private func renderSamplePassive(_ rawInput: Double) -> (Double, Double) {
        let cfg = coupledCfg!
        // Starpad: input ring (FX-tab spectrum + Harmonics played column)
        inputRing[inputRingIdx] = rawInput
        inputRingIdx = (inputRingIdx + 1) % SarangiEngine.fxRingLength
        // Starpad: pre-drive FX stage (mono → stereo collapsed to mid)
        var input = rawInput
        if violinPreFX.enabled {
            let (pl, pr) = violinPreFX.process(rawInput)
            input = 0.5 * (pl + pr)
        }
        let x = input * c_gin
        pLpState = (1.0 - pLpA) * x + pLpA * pLpState
        var F0 = cfg.pGain * pLpState
        if c_mixDrone > 1e-6 {
            F0 += 0.5 * c_mixDrone * drone.process(x)
        }
        F0 += bank.passiveState(include: pInclude)
        for j in playedCombs.indices {
            let S = playedCombs[j].passiveStatePart()
            pPlayedS[j] = S
            F0 += S + playedCombs[j].feedthrough * pAlphaW * x
        }
        let vSolve = (bodyAdm!.stateV() + pBodyY0 * F0)
            / (1.0 + pBodyY0 * pJzsum)
        let Fb = F0 - pJzsum * vSolve
        let (v, radC) = bodyAdm!.process(Fb)   // same V by linearity; owns states
        vBridgePrev = v
        let (sideF, sumY, dF) = bank.passiveCommit(V: v, zdrv: pZdrv, zi: pZi,
                                                   include: pInclude,
                                                   spread: scalars.bSpread)
        for j in playedCombs.indices {
            _ = playedCombs[j].passiveCommit(pAlphaW * x - pPlayedZdrv[j] * v,
                                             statePart: pPlayedS[j])
        }
        let side = wSide!.process(sideF)
        // buzz delta radiates centre through the same W (offline:
        // spec = RW·(0.5·(F+ΣΔf) ± 0.5·side'), side' already buzzed)
        let buzzRad = wBuzz != nil ? wBuzz!.process(dF) : 0.0
        var l = 0.5 * (radC + buzzRad + side)
        var r = 0.5 * (radC + buzzRad - side)
        if tarafDir > 1e-9 {
            // direct taraf-velocity tap: Σw·v_i = −(w̄/Z̄)·Σy_i − (Σw)·V
            // (w_i/Z_i is constant by the impedance law) — the offline
            // dirg·LP·Vsum_taraf·V, centre-panned ahead of the radiation FIR
            let tapIn = -(pTapW * sumY + pSumW * v)
            dirLp1 = (1.0 - dirLpA) * tapIn + dirLpA * dirLp1
            dirLp2 = (1.0 - dirLpA) * dirLp1 + dirLpA * dirLp2
            let tap = 0.5 * tarafDir * dirLp2
            l += tap
            r += tap
        }
        if radFIRL != nil {
            l = radFIRL!.process(l)
            r = radFIRR!.process(r)
        }
        if radLpL != nil {
            l = radLpL!.process(l)
            r = radLpR!.process(r)
        }
        let wet = reverb.processMono(l + r)
        var ol = l + 0.5 * wet
        var or_ = r + 0.5 * wet
        if !outEQL.isEmpty {
            ol = outEQL.process(ol)
            or_ = outEQR.process(or_)
        }
        // Starpad: global FX stage (mid/side — off = exact passthrough)
        let mid = 0.5 * (ol + or_)
        globalRing[globalRingIdx] = mid
        globalRingIdx = (globalRingIdx + 1) % SarangiEngine.fxRingLength
        if globalFX.enabled {
            let sdiff = 0.5 * (ol - or_)
            let (gfl, gfr) = globalFX.process(mid)
            ol = gfl + sdiff
            or_ = gfr - sdiff
        }
        let gl = c_gout * c_mainGain
        return (SarangiEngine.softClip(gl * ol), SarangiEngine.softClip(gl * or_))
    }

    public func reset() {
        bank.reset(); outEQL.reset(); outEQR.reset()
        reverb.reset(); drone.reset()
        radLpL?.reset(); radLpR?.reset()
        bodyAdm?.reset(); wSide?.reset(); wBuzz?.reset()
        for i in playedCombs.indices { playedCombs[i].reset() }
        radFIRL?.reset(); radFIRR?.reset()
        vBridgePrev = 0
        pLpState = 0
        dirLp1 = 0
        dirLp2 = 0
        // Starpad: FX stages + spectrum rings
        violinPreFX.reset(); globalFX.reset()
        for i in inputRing.indices { inputRing[i] = 0 }
        for i in globalRing.indices { globalRing[i] = 0 }
        inputRingIdx = 0; globalRingIdx = 0
    }

    /// Soft-clip backstop so pushing the gains / drive can't hard-clip the output
    /// (linear below 0.9, smoothly saturating to ~1.0 above).
    @inline(__always) static func softClip(_ x: Double) -> Double {
        if x > 0.9 { return 0.9 + 0.1 * tanh((x - 0.9) / 0.1) }
        if x < -0.9 { return -0.9 - 0.1 * tanh((-x - 0.9) / 0.1) }
        return x
    }

    /// Offline convenience: process a whole mono buffer. Returns (L, R).
    /// Used by the parity harness and sarangi-render.
    public func renderOffline(_ input: [Double]) -> (l: [Double], r: [Double]) {
        beginBuffer()
        var l = [Double](repeating: 0, count: input.count)
        var r = [Double](repeating: 0, count: input.count)
        for n in input.indices {
            let (lv, rv) = renderSample(input[n])
            l[n] = lv; r[n] = rv
        }
        return (l, r)
    }

    // MARK: - Starpad-local FX rack plumbing

    /// Live filter/EQ coefficient swap for the two FX stages (click-free — see
    /// `VoiceFX.updateFilters`). Call under the host audio lock.
    public func setVoiceFXFilters(_ fx: FXRack) {
        violinPreFX.updateFilters(fx.violinPre, sr: sr)
        globalFX.updateFilters(fx.global, sr: sr)
    }

    /// Time-ordered copies of the pre-EQ FX spectrum rings (FX tab). Call under
    /// the host audio lock (cheap copies; the FFT runs off-lock).
    public func fxSpectrumRawSnapshot() -> FXSpectrumSnapshot {
        FXSpectrumSnapshot(sr: sr,
                           violinPre: ringCopy(inputRing, inputRingIdx),
                           global: ringCopy(globalRing, globalRingIdx))
    }

    private func ringCopy(_ ring: [Double], _ idx: Int) -> [Double] {
        let n = ring.count
        var out = [Double](repeating: 0, count: n)
        for k in 0..<n { out[k] = ring[(idx + k) % n] }
        return out
    }

    // MARK: - Starpad-local Harmonics-tab snapshot

    /// A cheap raw snapshot of the sympathetic bank + the recent drive, taken
    /// under the host lock; the harmonic DFT (`BankAnalyzer`) runs off-lock.
    /// The host fills `playedF0`/`playedActive` (it owns the MIDI pitch).
    public func bankRawSnapshot() -> BankRawSnapshot {
        let gC = scalars.bGain
        let gB = scalars.bGain * scalars.bBright
        var strs: [StringRawSnapshot] = []
        strs.reserveCapacity(bank.count)
        for i in 0..<bank.count {
            let w = (bank.isBright[i] ? gB : gC) * bank.relOverSqrtN[i]
            strs.append(StringRawSnapshot(freq: bank.freqs[i],
                                          isBright: bank.isBright[i],
                                          group: bank.groups[i],
                                          outWeight: abs(w),
                                          period: bank.strings[i].period,
                                          buffer: bank.strings[i].bufferCopy()))
        }
        return BankRawSnapshot(sr: sr, strings: strs,
                               inputRing: ringCopy(inputRing, inputRingIdx),
                               playedWeight: scalars.mainGain,
                               playedF0: 0, playedActive: false)
    }
}
