import Foundation

/// Per-block control input for the violin synth.
public struct ViolinControlFrame: Sendable {
    public var f0: Double          // target pitch, Hz
    public var expr: Double        // 0..1
    public var press: Double       // 0..1
    public var pos: Double         // 0..1
    public var gate: Bool
    public var legato: Bool
    /// Player tilt (dB): 4th control axis — deterministic upper-harmonic
    /// bloom (h >= evolve_hmin, soft ramp), frame-energy renormalized so it
    /// changes timbre, never loudness. Mirrors Python ControlFrame.tilt_db.
    public var tiltDb: Double

    public init(f0: Double, expr: Double, press: Double, pos: Double,
                gate: Bool, legato: Bool = false, tiltDb: Double = 0) {
        self.f0 = f0; self.expr = expr; self.press = press; self.pos = pos
        self.gate = gate; self.legato = legato; self.tiltDb = tiltDb
    }
}

/// Causal streaming violin synthesizer — 1:1 port of Python
/// `violin.model.ViolinSynth`: oscillator bank (coherent phases) + 24-band
/// filtered-noise path + IDLE→ATTACK→SUSTAIN→RELEASE state machine with
/// legato glides. The deterministic harmonic path matches Python at float64
/// (verified by ViolinParityTests); jitter/noise use their own seeded RNG.
///
/// All buffers are preallocated; `process` performs no heap allocation.
public final class ViolinSynth {
    public let model: ViolinModel
    public let block: Int
    public var deterministic: Bool

    let sr: Double

    // note state machine
    enum State { case idle, attack, sustain, release }
    var state: State = .idle
    var wasGate = false
    var phase = 0.0
    var f0Cur = 0.0, f0From = 0.0, f0Target = 0.0
    var glideLeft = 0.0, glideTotal = 0.0
    var dipLeft = 0.0
    var framesSinceOn = 0.0, framesSinceOff = 0.0
    var latencyLeft = 0.0
    var pendingF0: Double? = nil
    var transDelayLeft = 0.0
    var relSlopeNote = -1.0

    // current linear gains (ramp start per block)
    var amp: [Double]              // hMax+1, index 1..hMax
    var namp: [Double]             // nBands

    // per-note templates (filled at noteOn)
    var attGain: [Double]          // (G, Ta)
    var attNoise: [Double]         // (K, Ta)
    var relGain: [Double]          // (G, Tr)
    var haveTemplates = false

    // scratch
    var harmT: [Double]
    var noiseT: [Double]
    var ampT: [Double]
    var nampT: [Double]
    var genv: [Double]
    var nenv: [Double]
    var f0Samp: [Double]
    var phiBuf: [Double]
    var noiseBuf: [Double]
    var bandBuf: [Double]
    var hiBuf: [Double]
    var groupOfH: [Int]
    var noiseCalLin: [Double]

    // noise filters: per band, sections of biquads (from stored SOS)
    var noiseFilters: [[Biquad]]

    // jitter
    var rng: XorShift64
    var gainJit: OnePoleNoise
    var groupJits: [OnePoleNoise]      // independent per-group streams
    var f0Jit: OnePoleNoise
    var fastFM: BandNoise              // block-rate common FM (f0_fast_* keys)
    // AUDIO-RATE corner FM (corner_* keys, committed 2026-07-06): the
    // stick-slip pedestal above the block-rate ceiling. Own RNG stream so
    // the block-rate jitter draw order is untouched (Python seed*7919+101).
    var cornerFM: BandNoise
    var cornerRng: XorShift64
    // played-string polarization beat (vpol_* keys, mechanism 2):
    // DETERMINISTIC per-harmonic envelopes |1+r·e^{iφ_h}|,
    // φ̇_h = 2π·h·f0·(2^(c/1200)−1) — runs in deterministic mode too.
    let vpolR: Double
    let vpolK: Double
    var vpolPhi: [Double]
    /// Taraf→source FM (mechanism 1) live replica — armed post-construction
    /// with the preset strings (like `symp`); nil = off. Modulates the NEXT
    /// block's period by the wash the voice itself excites (one-block
    /// latency; offline uses the frozen params/srcfm bank-bridge track).
    public var srcFM: SourceFMBank?
    var srcfmBuf: [Double]
    var gds: [Double]

    // player tilt: shared upper-harmonic ramp (mirror of tilt_weights)
    let tiltW: [Double]

    /// Voice↔taraf source coupling — armed post-construction with the
    /// preset's taraf partial list (mirror of Python `synth.symp`); nil = off.
    public var symp: SympatheticWeb?

    /// LIVE-ONLY expression-loudness equalization (see ExprEqualizer). nil =
    /// raw expr (offline contour replay feeds ALREADY-inverted expr — arming
    /// this there would double-invert).
    public var exprEq: ExprEqualizer?

    public init(model: ViolinModel, block: Int = 256, seed: UInt64 = 1,
                deterministic: Bool = false) {
        self.model = model
        self.block = block
        self.deterministic = deterministic
        sr = model.sr
        amp = [Double](repeating: 0, count: model.hMax + 1)
        namp = [Double](repeating: 0, count: model.nBands)
        attGain = [Double](repeating: 0, count: model.nGroups * model.ta)
        attNoise = [Double](repeating: 0, count: model.nBands * model.ta)
        relGain = [Double](repeating: 0, count: model.nGroups * model.tr)
        harmT = [Double](repeating: 0, count: model.hMax)
        noiseT = [Double](repeating: 0, count: model.nBands)
        ampT = [Double](repeating: 0, count: model.hMax)
        nampT = [Double](repeating: 0, count: model.nBands)
        genv = [Double](repeating: 0, count: model.nGroups)
        nenv = [Double](repeating: 0, count: model.nBands)
        f0Samp = [Double](repeating: 0, count: block)
        phiBuf = [Double](repeating: 0, count: block)
        noiseBuf = [Double](repeating: 0, count: block)
        bandBuf = [Double](repeating: 0, count: block)
        hiBuf = [Double](repeating: 0, count: block)
        groupOfH = (0...model.hMax).map { $0 == 0 ? 0 : model.groupOf($0) }
        noiseCalLin = model.noiseCalDb.map { pow(10.0, -$0 / 20.0) }
        noiseFilters = model.noiseSOS.map { flat in
            stride(from: 0, to: flat.count, by: 6).map { i in
                Biquad(b0: flat[i], b1: flat[i + 1], b2: flat[i + 2],
                       a0: flat[i + 3], a1: flat[i + 4], a2: flat[i + 5])
            }
        }
        rng = XorShift64(seed: seed)
        let blockRate = sr / Double(block)
        gainJit = OnePoleNoise(rms: model.jitter["gain_db_rms"] ?? 0,
                               hz: model.jitter["gain_hz"] ?? 4, rate: blockRate)
        // per-group independence — rigidly co-moving partials read reed-like.
        // rms = the measured per-harmonic residual wobble (group_db_rms, the
        // shimmer the loudness contour cannot carry), falling back to the
        // global gain jitter for older models.
        let grpRms = model.jitter["group_db_rms"] ?? model.jitter["gain_db_rms"] ?? 0
        let grpHz = model.jitter["group_hz"] ?? model.jitter["gain_hz"] ?? 4
        groupJits = (0..<model.nGroups).map { _ in
            OnePoleNoise(rms: grpRms, hz: grpHz, rate: blockRate)
        }
        gds = [Double](repeating: 0, count: model.nGroups)
        f0Jit = OnePoleNoise(rms: model.jitter["f0_cents_rms"] ?? 0,
                             hz: model.jitter["f0_hz"] ?? 4, rate: blockRate)
        // fast common FM ("corner jitter"): per-cycle stick-slip period noise.
        // Offline this is a frozen measured-seed track in control_track; live
        // is free-running with the same band/depth (noise path, not parity).
        fastFM = BandNoise(rms: model.jitter["f0_fast_cents_rms"] ?? 0,
                           loHz: model.jitter["f0_fast_hz_lo"] ?? 14,
                           hiHz: model.jitter["f0_fast_hz_hi"] ?? 70,
                           rate: blockRate)
        cornerFM = BandNoise(rms: model.jitter["corner_cents_rms"] ?? 0,
                             loHz: model.jitter["corner_hz_lo"] ?? 60,
                             hiHz: model.jitter["corner_hz_hi"] ?? 260,
                             rate: sr)                    // per SAMPLE
        cornerRng = XorShift64(seed: seed &* 7919 &+ 101)
        vpolR = model.jitter["vpol_r"] ?? 0
        vpolK = pow(2.0, (model.jitter["vpol_cents"] ?? 2.0) / 1200.0) - 1.0
        vpolPhi = [Double](repeating: 0, count: model.hMax)
        srcfmBuf = [Double](repeating: 0, count: block)
        // tilt ramp: 0 below hmin, soft 2-harmonic ramp-in, 1 above — must
        // stay in lockstep with Python tilt_weights (fork = parity break)
        let hmin = Int(model.jitter["evolve_hmin"] ?? 5)
        tiltW = (1...model.hMax).map { h in
            h < hmin ? 0.0 : min(1.0, 0.5 * Double(h - hmin + 1))
        }
    }

    public func reset() {
        state = .idle; wasGate = false
        symp?.reset()
        srcFM?.reset()
        for i in vpolPhi.indices { vpolPhi[i] = 0 }
        for i in srcfmBuf.indices { srcfmBuf[i] = 0 }
        phase = 0; f0Cur = 0; f0From = 0; f0Target = 0
        glideLeft = 0; glideTotal = 0; dipLeft = 0
        framesSinceOn = 0; framesSinceOff = 0; latencyLeft = 0
        pendingF0 = nil; transDelayLeft = 0; relSlopeNote = -1
        for i in 0..<amp.count { amp[i] = 0 }
        for i in 0..<namp.count { namp[i] = 0 }
        haveTemplates = false
        for b in 0..<noiseFilters.count {
            for s in 0..<noiseFilters[b].count { noiseFilters[b][s].reset() }
        }
    }

    // MARK: - state machine (mirrors Python _update_state)

    func updateState(_ c: ViolinControlFrame) {
        let m = model
        if c.gate && !wasGate {
            state = .attack
            let tuned = m.tuned(c.f0)
            f0Cur = tuned; f0Target = tuned
            let midi = ViolinModel.midiOf(c.f0)
            let latency = m.evalTemplates(midi: midi, press: c.press,
                                          attackOut: &attGain, attackNoiseOut: &attNoise,
                                          releaseOut: &relGain)
            haveTemplates = true
            relSlopeNote = m.evalReleaseSlope(midi: midi, press: c.press)
            latencyLeft = latency / 1000.0 * sr
            framesSinceOn = 0
            glideLeft = 0
            dipLeft = 0
        } else if !c.gate && wasGate && (state == .attack || state == .sustain) {
            state = .release
            framesSinceOff = 0
        }
        let f0In = c.gate ? m.tuned(c.f0) : c.f0
        let curTarget = pendingF0 ?? f0Target
        if c.gate && (state == .attack || state == .sustain)
            && abs(f0In - curTarget) > 1e-2 && c.legato {
            pendingF0 = f0In
            transDelayLeft = (m.legato["trans_delay_ms"] ?? 0) / 1000.0 * sr
        } else if c.gate && abs(f0In - curTarget) > 1e-2 && !c.legato {
            f0Cur = f0In; f0Target = f0In
            pendingF0 = nil
        }
        wasGate = c.gate
        if let pending = pendingF0 {
            transDelayLeft -= Double(block)
            if transDelayLeft <= 0 {
                let st = abs(ViolinModel.midiOf(pending) - ViolinModel.midiOf(f0Target))
                let glideMs = m.glideMs(st: st)
                f0From = f0Cur
                f0Target = pending
                glideTotal = max(1.0, glideMs / 1000.0 * sr)
                glideLeft = glideTotal
                dipLeft = (m.legato["dip_ms"] ?? 60) / 1000.0 * sr
                pendingF0 = nil
            }
        }
    }

    // MARK: - per-block render

    /// Render one block into `out` (length >= block). Returns silently-idle flag.
    @discardableResult
    public func process(_ c: ViolinControlFrame, into out: inout [Double]) -> Bool {
        let m = model
        let B = block
        updateState(c)
        for i in 0..<B { out[i] = 0 }
        if state == .idle && !c.gate {
            // keep the srcfm replica decaying through silence (the wash
            // rings on) so re-entry has a physical modulator, not a stale one
            if srcFM != nil && !deterministic {
                srcFM!.fill(&srcfmBuf, from: out, count: B)
            }
            return true
        }

        // control-rate targets
        let f0Nom = state != .release ? f0Target : f0Cur
        let exprEff = exprEq?.equalize(midi: ViolinModel.midiOf(f0Nom),
                                       expr: c.expr, press: c.press,
                                       pos: c.pos) ?? c.expr
        m.evalSurfaces(midi: ViolinModel.midiOf(f0Nom), expr: exprEff,
                       press: c.press, pos: c.pos, harmOut: &harmT, noiseOut: &noiseT)
        let frPerBlock = Double(B) * m.frameRate / sr

        var gd = 0.0, cents = 0.0
        if !deterministic {
            gd = gainJit.step(&rng)
            for g in 0..<gds.count { gds[g] = groupJits[g].step(&rng) }
            cents = f0Jit.step(&rng)
            if fastFM.rms > 0 { cents += fastFM.step(&rng) }
        } else {
            for g in 0..<gds.count { gds[g] = 0 }
        }

        for i in 0..<genv.count { genv[i] = 0 }
        for i in 0..<nenv.count { nenv[i] = 0 }
        var silent = false

        switch state {
        case .attack:
            if latencyLeft > 0 {
                latencyLeft -= Double(B)
                silent = true
            } else {
                let fi = framesSinceOn
                let i0 = Int(fi)
                if i0 >= m.ta - 1 {
                    state = .sustain
                } else {
                    let t = fi - Double(i0)
                    for g in 0..<m.nGroups {
                        genv[g] = (1 - t) * attGain[g * m.ta + i0] + t * attGain[g * m.ta + i0 + 1]
                    }
                    for k in 0..<m.nBands {
                        nenv[k] = (1 - t) * attNoise[k * m.ta + i0] + t * attNoise[k * m.ta + i0 + 1]
                    }
                }
                framesSinceOn += frPerBlock
            }
        case .release:
            if !haveTemplates {
                state = .idle
                silent = true
            } else {
                let T = m.tr
                let sNote = min(max(relSlopeNote, -8.0), -0.2)
                let fi = framesSinceOff
                let i0 = Int(fi)
                var maxG = -1e9
                if i0 >= T - 1 {
                    for g in 0..<m.nGroups {
                        genv[g] = relGain[g * T + T - 1] + sNote * (fi - Double(T - 1))
                        maxG = max(maxG, genv[g])
                    }
                } else {
                    let t = fi - Double(i0)
                    for g in 0..<m.nGroups {
                        genv[g] = (1 - t) * relGain[g * T + i0] + t * relGain[g * T + i0 + 1]
                        maxG = max(maxG, genv[g])
                    }
                }
                var mean = 0.0
                for g in 0..<m.nGroups { mean += genv[g] }
                mean /= Double(m.nGroups)
                for k in 0..<m.nBands { nenv[k] = mean }
                if maxG < -100 {
                    state = .idle
                    silent = true
                }
            }
            framesSinceOff += frPerBlock
        case .idle, .sustain:
            break
        }

        var dipDb = 0.0
        if dipLeft > 0 && (state == .attack || state == .sustain) {
            let dipSamp = max(1.0, (m.legato["dip_ms"] ?? 60) / 1000.0 * sr)
            let x = dipLeft / dipSamp
            dipDb = -(m.legato["dip_db"] ?? 0) * sin(.pi * min(max(1 - x, 0), 1))
            dipLeft -= Double(B)
        }

        // per-harmonic linear targets
        let f0Now = glideLeft <= 0 ? f0Cur : f0Target
        for h in 1...m.hMax {
            if silent {
                ampT[h - 1] = 0
                continue
            }
            let gdb = harmT[h - 1] + genv[groupOfH[h]] + 0.5 * gd
                + gds[groupOfH[h]] + dipDb
            var a = pow(10.0, gdb / 20.0)
            if Double(h) * max(f0Now, f0Target) > 0.45 * sr { a = 0 }
            if Double(h) * max(f0Now, 1.0) > m.fLim { a = 0 }
            ampT[h - 1] = a
        }
        // player tilt: deterministic upper-harmonic bloom, frame-total energy
        // renormalized (zero loudness change) — mirror of _HarmEvolve.apply
        if abs(c.tiltDb) > 1e-6 && !silent {
            var e0 = 0.0
            for h in 0..<m.hMax { e0 += ampT[h] * ampT[h] }
            if e0 >= 1e-18 {
                var e1 = 0.0
                for h in 0..<m.hMax {
                    ampT[h] *= pow(10.0, tiltW[h] * c.tiltDb / 20.0)
                    e1 += ampT[h] * ampT[h]
                }
                let s = (e0 / max(e1, 1e-18)).squareRoot()
                for h in 0..<m.hMax { ampT[h] *= s }
            }
        }
        // voice↔taraf source coupling (deterministic, order matches Python:
        // after ev/tilt, no renorm — energy migrates by design)
        if let web = symp, !silent {
            web.apply(&ampT, f0: f0Now)
        }
        // played-string polarization beat (order matches Python: after symp)
        if vpolR > 1e-4 && !silent {
            let norm = (1.0 + vpolR * vpolR).squareRoot()
            let dphi = 2.0 * Double.pi * vpolK * Double(B) / sr * f0Now
            for h in 0..<m.hMax {
                vpolPhi[h] += dphi * Double(h + 1)
                ampT[h] *= (1.0 + vpolR * vpolR
                            + 2.0 * vpolR * cos(vpolPhi[h])).squareRoot() / norm
            }
        }
        if silent {
            for k in 0..<m.nBands { nampT[k] = 0 }
        } else {
            for k in 0..<m.nBands { nampT[k] = pow(10.0, (noiseT[k] + nenv[k] + dipDb) / 20.0) }
        }

        // f0 for this block (glide + jitter)
        var f0a = f0Cur
        var f0b = f0Cur
        if glideLeft > 0 {
            let u0 = 1 - glideLeft / glideTotal
            let u1 = min(1.0, u0 + Double(B) / glideTotal)
            let s0 = u0 * u0 * (3 - 2 * u0)
            let s1 = u1 * u1 * (3 - 2 * u1)
            let lf = log2(f0From), lt = log2(f0Target)
            f0a = pow(2.0, lf + (lt - lf) * s0)
            f0b = pow(2.0, lf + (lt - lf) * s1)
            glideLeft -= Double(B)
            f0Cur = f0b
        } else {
            f0b = state != .release ? f0Target : f0Cur
            f0Cur = f0b
            f0a = f0b
        }
        let jf = pow(2.0, cents / 1200.0)
        for i in 0..<B {
            f0Samp[i] = (f0a + (f0b - f0a) * Double(i) / Double(B)) * jf
        }
        // per-sample voice FM: audio-rate corner jitter (free-running live;
        // offline replays carry it frozen in the ctl phase → deterministic
        // mode skips, exactly like the block-rate fast FM) + the taraf→
        // source modulator computed from LAST block's output
        let cornerOn = !deterministic && cornerFM.rms > 0
        let srcOn = !deterministic && srcFM != nil
        if cornerOn || srcOn {
            for i in 0..<B {
                var cc = 0.0
                if cornerOn { cc += cornerFM.step(&cornerRng) }
                if srcOn { cc += srcfmBuf[i] }
                f0Samp[i] *= pow(2.0, cc / 1200.0)
            }
        }

        // oscillator bank (coherent phases), phase = running cumsum
        var ph = phase
        let twoPiOverSr = 2.0 * Double.pi / sr
        for i in 0..<B {
            ph += twoPiOverSr * f0Samp[i]
            phiBuf[i] = ph
        }
        phase = ph.truncatingRemainder(dividingBy: 2.0 * Double.pi)
        let invB = 1.0 / Double(B)
        let buzzHMin = 7
        var anyHi = false
        for i in 0..<B { hiBuf[i] = 0 }
        for h in 1...m.hMax {
            let target = ampT[h - 1]
            let start = amp[h]
            if target <= 1e-7 && start <= 1e-7 { amp[h] = target; continue }
            let dh = Double(h)
            if h >= buzzHMin {
                anyHi = true
                for i in 0..<B {
                    let a = start + (target - start) * (Double(i) * invB)
                    hiBuf[i] += a * sin(dh * phiBuf[i])
                }
            } else {
                for i in 0..<B {
                    let a = start + (target - start) * (Double(i) * invB)
                    out[i] += a * sin(dh * phiBuf[i])
                }
            }
            amp[h] = target
        }
        // jawari buzz: sharp once-per-cycle pulse on the upper partials —
        // pitch-locked sidebands, not breath (keep in lockstep with Python)
        let amDepth = m.jitter["am_depth"] ?? 0
        if anyHi {
            if amDepth > 1e-3 {
                for i in 0..<B {
                    let c = 0.5 + 0.5 * cos(phiBuf[i])
                    let pulse = c * c * c * c
                    out[i] += hiBuf[i] * (1.0 + amDepth * 2.0 * (pulse - 0.2734))
                }
            } else {
                for i in 0..<B { out[i] += hiBuf[i] }
            }
        }

        // noise path
        if !deterministic {
            for i in 0..<B { noiseBuf[i] = rng.gaussian() }
            for k in 0..<m.nBands {
                let g0 = namp[k], g1 = nampT[k]
                if g0 < 1e-9 && g1 < 1e-9 { namp[k] = g1; continue }
                for i in 0..<B { bandBuf[i] = noiseBuf[i] }
                for s in 0..<noiseFilters[k].count {
                    for i in 0..<B { bandBuf[i] = noiseFilters[k][s].process(bandBuf[i]) }
                }
                let cal = noiseCalLin[k]
                for i in 0..<B {
                    let g = g0 + (g1 - g0) * (Double(i) * invB)
                    out[i] += g * cal * bandBuf[i]
                }
                namp[k] = g1
            }
        } else {
            for k in 0..<m.nBands { namp[k] = nampT[k] }
        }
        // taraf→source FM replica: ring the modulator bank with this block's
        // output; the result modulates the NEXT block's period (one-block
        // latency — immaterial for a wash that evolves over hundreds of ms)
        if srcFM != nil && !deterministic {
            srcFM!.fill(&srcfmBuf, from: out, count: B)
        }
        return false
    }
}

/// MECHANISM 1 live replica (taraf→source FM). Offline, the frozen
/// params/srcfm track is the fitted BANK's bridge signal (band-limited
/// 40–1500 Hz, unit rms) frequency-modulating the played string's period.
/// Live we cannot reach across the AU graph per sample, so a lightweight
/// voice-side bank of complex one-pole resonators at the taraf partials
/// (≤1500 Hz) rings from the voice's own output — the same character (the
/// wash the voice excites modulates the voice), slow-rms normalized so the
/// model's `src_fm_cents_rms` keeps its offline meaning.
public struct SourceFMBank {
    var re: [Double], im: [Double]
    let pr: [Double], pi: [Double]       // pole = radius·e^{jθ} per resonator
    let inG: [Double]                    // input gain (1 − radius)
    let depth: Double                    // src_fm_cents_rms
    var meanSq = 2.5e-3                  // slow unit-rms tracker (mean square)
    let trkA: Double
    public init(partials: [(freq: Double, tau: Double)], depth: Double,
                sr: Double) {
        self.depth = depth
        var prv: [Double] = [], piv: [Double] = [], gv: [Double] = []
        for p in partials where p.freq >= 40 && p.freq <= 1500 {
            let r = exp(-1.0 / (max(p.tau, 0.05) * sr))
            let th = 2.0 * Double.pi * p.freq / sr
            prv.append(r * cos(th)); piv.append(r * sin(th))
            gv.append(1.0 - r)
        }
        pr = prv; pi = piv; inG = gv
        re = [Double](repeating: 0, count: prv.count)
        im = [Double](repeating: 0, count: prv.count)
        trkA = exp(-1.0 / (2.0 * sr))    // ~2 s normalizer
    }
    /// Ring the bank with `out`, write per-sample CENTS into `buf`
    /// (clamped ±40 c: the tracker needs a settle guard at note starts).
    public mutating func fill(_ buf: inout [Double], from out: [Double],
                              count: Int) {
        if pr.isEmpty {
            for i in 0..<count { buf[i] = 0 }
            return
        }
        for i in 0..<count {
            let x = out[i]
            var s = 0.0
            for k in 0..<pr.count {
                let r0 = re[k], q0 = im[k]
                re[k] = pr[k] * r0 - pi[k] * q0 + inG[k] * x
                im[k] = pr[k] * q0 + pi[k] * r0
                s += re[k]
            }
            meanSq = trkA * meanSq + (1.0 - trkA) * s * s
            let c = depth * s / max(meanSq.squareRoot(), 1e-3)
            buf[i] = min(40.0, max(-40.0, c))
        }
    }
    public mutating func reset() {
        for i in re.indices { re[i] = 0; im[i] = 0 }
        meanSq = 2.5e-3
    }
}

// MARK: - deterministic RNG + one-pole jitter noise

/// xorshift64* — deterministic, allocation-free RNG for the noise/jitter paths.
public struct XorShift64: Sendable {
    var s: UInt64
    public init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27
        return s &* 0x2545F4914F6CDD1D
    }
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
    /// Box–Muller gaussian.
    public mutating func gaussian() -> Double {
        var u1 = uniform()
        if u1 < 1e-300 { u1 = 1e-300 }
        let u2 = uniform()
        return (-2.0 * Foundation.log(u1)).squareRoot() * cos(2.0 * .pi * u2)
    }
}

/// Deterministic voice↔taraf SOURCE coupling — port of Python
/// `_SympatheticWeb` (ear-approved "sympmax" 2026-07-06). Each near-unison
/// taraf partial is a complex one-pole resonator in the voice harmonic's
/// rotating frame, kept in perpetual transient by pitch micro-motion; its
/// response interferes with the harmonic AT THE SOURCE:
///     r ← r·exp((−1/τ + i·2πδ)·dt) + k·(dt/τ)·a_h,   δ = f_j − h·f0
///     a_h_eff = |a_h + Σ_j r_j|
/// `k` = unison ring level relative to the voice harmonic. Partners outside
/// `winHz` fade out (the far-detuned ring is the bank's job). Deterministic
/// given the control stream — no randomness anywhere.
public final class SympatheticWeb {
    let f: [Double]                 // sorted partial frequencies (Hz)
    let tau: [Double]               // amplitude time constants (s)
    let dt: Double
    let k: Double
    let win: Double
    var stateRe: [UInt64: Double] = [:]
    var stateIm: [UInt64: Double] = [:]

    public init(partials: [(freq: Double, tau: Double)], dt: Double,
                k: Double, winHz: Double) {
        let sorted = partials.sorted { $0.freq < $1.freq }
        f = sorted.map { $0.freq }
        tau = sorted.map { max($0.tau, 0.2) }
        self.dt = dt
        self.k = k
        self.win = winHz
    }

    /// Modulate the per-harmonic amp targets in place (ampT[h-1], h = 1...).
    public func apply(_ ampT: inout [Double], f0: Double) {
        guard f0 > 0, k > 1e-4 else { return }
        var alive = Set<UInt64>()
        for h in 1...ampT.count {
            let fh = Double(h) * f0
            if fh > 9000 { break }
            let aH = ampT[h - 1]
            // partial range within ±win of fh (f is sorted)
            var j0 = f.startIndex, j1 = f.endIndex
            j0 = lowerBound(fh - win)
            j1 = lowerBound(fh + win)
            if j0 >= j1 { continue }
            var totRe = 0.0, totIm = 0.0
            for j in j0..<j1 {
                let key = UInt64(h) << 32 | UInt64(j)
                alive.insert(key)
                let delta = f[j] - fh
                let decay = exp(-dt / tau[j])
                let ang = 2.0 * Double.pi * delta * dt
                let zr = decay * cos(ang), zi = decay * sin(ang)
                let rr = stateRe[key] ?? 0, ri = stateIm[key] ?? 0
                let nr = rr * zr - ri * zi + k * (dt / tau[j]) * aH
                let ni = rr * zi + ri * zr
                stateRe[key] = nr
                stateIm[key] = ni
                totRe += nr
                totIm += ni
            }
            if aH > 1e-9 {
                let re = aH + totRe
                ampT[h - 1] = (re * re + totIm * totIm).squareRoot()
            }
        }
        // partners that left the window: fast fade (bank owns that ring)
        for key in stateRe.keys where !alive.contains(key) {
            let rr = stateRe[key]! * 0.7, ri = stateIm[key]! * 0.7
            if rr * rr + ri * ri < 1e-20 {
                stateRe.removeValue(forKey: key)
                stateIm.removeValue(forKey: key)
            } else {
                stateRe[key] = rr
                stateIm[key] = ri
            }
        }
    }

    private func lowerBound(_ v: Double) -> Int {
        var lo = 0, hi = f.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if f[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public func reset() {
        stateRe.removeAll()
        stateIm.removeAll()
    }
}

/// Band-limited Gaussian noise: difference of two one-pole low-passes over
/// ONE shared draw (lo..hi Hz band), analytically normalized to unit rms
/// before the `rms` scale. Live mirror of Python `_fast_f0_stream` — the
/// offline stream is a frozen per-recording track (seed 71, empirical
/// normalization); live is free-running with the same band and depth.
public struct BandNoise {
    public let rms: Double
    let aLo, gLo, aHi, gHi: Double
    let norm: Double
    var yLo = 0.0, yHi = 0.0
    public init(rms: Double, loHz: Double, hiHz: Double, rate: Double) {
        self.rms = rms
        aLo = exp(-2.0 * Double.pi * max(loHz, 1e-3) / rate)
        aHi = exp(-2.0 * Double.pi * max(hiHz, 1e-3) / rate)
        gLo = max(1e-12, 1 - aLo * aLo).squareRoot()
        gHi = max(1e-12, 1 - aHi * aHi).squareRoot()
        // Var(yHi - yLo) = 2 - 2*Cov; Cov of two unit-variance one-poles fed
        // by the same white stream = gHi*gLo / (1 - aHi*aLo)
        let v = 2.0 - 2.0 * gHi * gLo / (1.0 - aHi * aLo)
        norm = 1.0 / max(v, 1e-12).squareRoot()
    }
    public mutating func step(_ rng: inout XorShift64) -> Double {
        let e = rng.gaussian()
        yLo = aLo * yLo + gLo * e
        yHi = aHi * yHi + gHi * e
        return (yHi - yLo) * norm * rms
    }
}

/// Gaussian noise through a one-pole low-pass: `rms` at bandwidth `hz`.
public struct OnePoleNoise {
    let rms: Double
    let a: Double
    let g: Double
    var y = 0.0
    public init(rms: Double, hz: Double, rate: Double) {
        self.rms = rms
        a = exp(-2.0 * Double.pi * max(hz, 1e-3) / rate)
        g = max(1e-12, 1 - a * a).squareRoot()
    }
    public mutating func step(_ rng: inout XorShift64) -> Double {
        y = a * y + g * rng.gaussian()
        return y * rms
    }
}
