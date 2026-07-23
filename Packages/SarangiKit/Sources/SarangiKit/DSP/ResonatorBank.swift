import Foundation

/// The sympathetic-string (taraf) bank: the comb strings + weights + pans of
/// the v57 coupled network's string web (`coupled.network_strings` lockstep:
/// pol-doublet expansion, per-choir 1/√N in `relOverSqrtN`, `B_gain`/
/// `B_gain·B_bright` applied live). Since the v57-only simplification the
/// bank renders exclusively through the PASSIVE junction passes below —
/// the κ/legacy summing path is gone (git history).
///
/// STARPAD DIVERGENCE: each voice also carries its `StringGroup` choir tag and
/// nominal `freqs` (threaded through the pol expansion) for the Harmonics-tab
/// display — upstream has no groups.
public struct ResonatorBank: Sendable {
    public var strings: [CombString]
    public var relOverSqrtN: [Double]     // rel_gain / √N(choir)
    public var isBright: [Bool]
    /// Starpad: per-voice choir tag (parallel to `strings`, pol doublets share
    /// their parent's group) — drives the Harmonics-tab column grouping.
    public var groups: [StringGroup]
    /// Starpad: per-voice nominal fundamental (spec freq × pol detune).
    public var freqs: [Double]
    public var isRaga: [Bool] = []        // per-class jawari law (raga buzz most)
    // per-string pan POSITION in [-1, 1] (freq rank across the bridge); the
    // live spread scalar turns it into linear complementary gains whose sum
    // is 1 — the L+R sum is bit-identical to the mono bank
    var panPos: [Double] = []

    public init(strings: [CombString] = [], relOverSqrtN: [Double] = [], isBright: [Bool] = [],
                groups: [StringGroup] = [], freqs: [Double] = []) {
        self.strings = strings
        self.relOverSqrtN = relOverSqrtN
        self.isBright = isBright
        self.groups = groups.count == strings.count
            ? groups : [StringGroup](repeating: .scale, count: strings.count)
        self.freqs = freqs.count == strings.count
            ? freqs : [Double](repeating: 0, count: strings.count)
        panPos = [Double](repeating: 0, count: strings.count)
    }

    /// Build the bank from resolved strings. `t60Scale` (= B_t60_scale) and the
    /// per-choir comb brightness (from `bLp` = B_lp) are baked into the combs.
    ///
    /// THE WEB (`polSplit` > 0 or `inharm` > 0 — port of the offline
    /// blocks.resonator_bank web path, ear-approved + gradient-fitted
    /// 2026-07-06): every string becomes its TWO transverse polarizations
    /// (second comb detuned sharp by ~polSplit cents, deterministic
    /// golden-ratio spread with the same per-CHOIR append-time indexing as
    /// offline; gain ×polGain, t60 ×polT60), and all combs run in the
    /// fractional-delay web form with stiff-wire `inharm`. Gain-normalized
    /// per choir over the EXPANDED count, exactly like offline.
    public static func build(strings specs: [ResolvedString], t60Scale: Double,
                             bLp: Double, sr: Double,
                             polSplit: Double = 0, polGain: Double = 0.85,
                             polT60: Double = 0.65,
                             inharm: Double = 0, damp: Double = 0,
                             groups specGroups: [StringGroup] = []) -> ResonatorBank {
        let tags = specGroups.count == specs.count
            ? specGroups : [StringGroup](repeating: .scale, count: specs.count)
        let active = Array(zip(specs, tags)).filter { $0.0.enabled }
        let web = polSplit > 0.01 || inharm > 1e-4 || damp > 1e-3
        var voices: [(ResolvedString, Double, Double, Double, StringGroup)] = []
        // (spec, fMul, t60Mul, gainMul, group) — expansion runs PER CHOIR with
        // the offline golden-ratio index (len(voices) at pol-append time within
        // that choir's resonator_bank call)
        var choirCount: [Bool: Int] = [false: 0, true: 0]
        for (s, tag) in active {
            voices.append((s, 1.0, 1.0, 1.0, tag))
            choirCount[s.bright]! += 1
            if polSplit > 0.01 {
                let idx = Double(choirCount[s.bright]!)     // == 2k+1 offline
                let frac = (idx * 0.61803398875).truncatingRemainder(dividingBy: 1.0)
                let split = polSplit * (0.6 + 0.8 * frac)
                voices.append((s, pow(2.0, split / 1200.0), polT60, polGain, tag))
                choirCount[s.bright]! += 1
            }
        }
        let nClean = max(1, voices.filter { !$0.0.bright }.count)
        let nBright = max(1, voices.filter { $0.0.bright }.count)
        var combs: [CombString] = []; combs.reserveCapacity(voices.count)
        var rel: [Double] = []; rel.reserveCapacity(voices.count)
        var bright: [Bool] = []; bright.reserveCapacity(voices.count)
        var grp: [StringGroup] = []; grp.reserveCapacity(voices.count)
        var vFreqs: [Double] = []; vFreqs.reserveCapacity(voices.count)
        var ragaCls: [Bool] = []; ragaCls.reserveCapacity(voices.count)
        for (s, fMul, tMul, gMul, tag) in voices {
            // chain.process: clean choir bright = 0.6·lp, bright (raga) choir = lp
            let combBright = s.bright ? bLp : 0.6 * bLp
            combs.append(CombString(f0: s.freq * fMul, t60: s.t60 * tMul * t60Scale,
                                    sr: sr, bright: combBright,
                                    web: web, inharm: inharm, damp: damp))
            rel.append(s.gain * gMul / Double(s.bright ? nBright : nClean).squareRoot())
            bright.append(s.bright)
            grp.append(tag)
            vFreqs.append(s.freq * fMul)
            ragaCls.append(s.raga)
        }
        var bank = ResonatorBank(strings: combs, relOverSqrtN: rel, isBright: bright,
                                 groups: grp, freqs: vFreqs)
        bank.isRaga = ragaCls
        // pan positions by frequency rank (low left → high right), matching
        // blocks.string_pans (ranks over the EXPANDED voice set)
        let freqs = voices.map { $0.0.freq * $0.1 }
        let ranks = freqs.map { f in freqs.filter { $0 < f }.count }
        let n = max(1, freqs.count - 1)
        for i in bank.panPos.indices {
            bank.panPos[i] = 2.0 * Double(ranks[i]) / Double(n) - 1.0
        }
        return bank
    }

    public mutating func reset() {
        for i in strings.indices { strings[i].reset() }
        for i in passiveS.indices { passiveS[i] = 0 }
        for i in jawEnv.indices { jawEnv[i] = 0; jawRef[i] = 0; jawBuzzLp[i] = 0 }
    }
    public var count: Int { strings.count }

    // MARK: passive wave junction (v57 live port, 2026-07-12)
    // The taraf side of the delay-free bridge solve (coupled.junction_solve):
    // PASS 1 caches each comb's state-only output S_i and returns ΣS_i (the
    // taraf share of F0 — taraf have no source drive); after the engine
    // solves V, PASS 2 commits every comb at x_i = −zdrv_i·V and returns the
    // panned SIDE force Σ(gl−gr)·f_i (f_i = y_i + zi_i·V) plus Σy_i over the
    // strings the impedance law includes (the taraf-velocity tap input).
    var passiveS: [Double] = []

    // per-string CAUSAL jawari state (the live twin of
    // blocks._string_jawari_sus: 80 ms one-pole env; the offline whole-signal
    // p95 reference becomes a slow running peak; one-pole buzz LP = the
    // offline N_jaw_lp exactly). Set up by configureJawari.
    var jawAmt: [Double] = []
    var jawEnv: [Double] = []
    var jawRef: [Double] = []
    var jawBuzzLp: [Double] = []
    var jawEnvA = 0.0
    var jawRefDecay = 1.0
    var jawLpA = 0.0
    var jawOn = false

    /// Bake the per-class jawari depths (it22 law: raga > chrom > played=0)
    /// + the buzz radiation LP. Call once at engine build (structural).
    public mutating func configureJawari(raga: Double, chrom: Double,
                                         lpHz: Double, sr: Double) {
        jawOn = max(raga, chrom) > 1e-3
        guard jawOn else { return }
        jawAmt = isRaga.map { $0 ? raga : chrom }
        jawEnv = [Double](repeating: 0, count: strings.count)
        jawRef = [Double](repeating: 0, count: strings.count)
        jawBuzzLp = [Double](repeating: 0, count: strings.count)
        jawEnvA = exp(-1.0 / (0.080 * sr))
        jawRefDecay = exp(-1.0 / (1.5 * sr))
        jawLpA = lpHz > 0 ? exp(-2.0 * Double.pi * min(lpHz, 0.45 * sr) / sr) : 0.0
    }

    /// PASS 1. `include[i]` = the string participates in the junction
    /// (its choir gain is non-zero — offline drops silent choirs entirely).
    public mutating func passiveState(include: [Bool]) -> Double {
        if passiveS.count != strings.count {
            passiveS = [Double](repeating: 0, count: strings.count)
        }
        var sum = 0.0
        for i in strings.indices where include[i] {
            let s = strings[i].passiveStatePart()
            passiveS[i] = s
            sum += s
        }
        return sum
    }

    /// PASS 2 at the solved bridge velocity. When jawari is configured the
    /// per-string force is waveshaped ON THE RADIATED COPY only (the string
    /// commit and the tap stay linear — offline lockstep: the junction solve
    /// never sees the buzz). Returns the panned side force (buzzed), the
    /// LINEAR Σy (tap input), and the buzz delta ΣΔf (radiated via W by the
    /// engine's centre buzz bank).
    public mutating func passiveCommit(V: Double, zdrv: [Double], zi: [Double],
                                       include: [Bool], spread: Double)
        -> (side: Double, sumY: Double, dF: Double) {
        var side = 0.0
        var sumY = 0.0
        var dF = 0.0
        for i in strings.indices where include[i] {
            let x = -zdrv[i] * V
            let y = strings[i].passiveCommit(x, statePart: passiveS[i])
            var f = y + zi[i] * V
            sumY += y
            if jawOn, jawAmt[i] > 1e-3 {
                // causal _string_jawari_sus twin (per-sample)
                let env = (1.0 - jawEnvA) * abs(f) + jawEnvA * jawEnv[i]
                jawEnv[i] = env
                let ref = max(env, jawRef[i] * jawRefDecay)
                jawRef[i] = ref
                if ref > 1e-9 {
                    let op = 0.7 * env + 1e-6 * ref
                    let z = f / op
                    var buzz = tanh(z + 0.35 * z * z) * op
                    if jawLpA > 0 {
                        jawBuzzLp[i] = (1.0 - jawLpA) * buzz + jawLpA * jawBuzzLp[i]
                        buzz = jawBuzzLp[i]
                    }
                    let mix = jawAmt[i] * env / (env + 0.02 * ref)
                    let fb = (1.0 - mix) * f + mix * buzz
                    dF += fb - f
                    f = fb
                }
            }
            side += panPos[i] * spread * f
        }
        return (side, sumY, dF)
    }
}

/// A sympathetic string after raga/tonic resolution, ready for the DSP bank.
/// (`bright` runs over the jawari bridge; `enabled` is the UI on/off toggle.)
public struct ResolvedString: Sendable, Hashable {
    public var freq: Double
    public var gain: Double
    public var t60: Double
    public var bright: Bool
    public var enabled: Bool
    /// String CLASS (2026-07-07g law): raga-tuned taraf buzz most, the
    /// chromatic row stays cleaner. NOT the `bright` flag (that marks the
    /// jawari-BRIDGE choirs; choir C + doublings are raga with bright=false).
    public var raga: Bool
    public init(freq: Double, gain: Double, t60: Double, bright: Bool,
                enabled: Bool = true, raga: Bool = false) {
        self.freq = freq; self.gain = gain; self.t60 = t60; self.bright = bright
        self.enabled = enabled; self.raga = raga
    }
}
