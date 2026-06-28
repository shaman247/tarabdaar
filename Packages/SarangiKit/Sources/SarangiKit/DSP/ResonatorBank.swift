import Foundation

/// Block B — the sympathetic-string bank. A parallel sum of harmonic-comb
/// strings (`CombString`) split into a **clean** choir (driven by the dry violin
/// `x`) and a **bright** choir (driven by `x + C_to_bank·jaw`, runs over the
/// jawari bridge). Ports `chain.process`' bank section + `blocks.resonator_bank`
/// (now comb-based). Each comb's HF roll-off (`bright`) is set from **`B_lp`**
/// (the gut-string brightness knob): clean choir = `0.6·B_lp`, bright choir =
/// `B_lp` — matching `chain.process`. The per-choir `1/√N` normalisation (N =
/// that choir's count) is baked into `relOverSqrtN`; `B_gain` (clean) and
/// `B_gain·B_bright` (bright) are applied **live** at sum time.
public struct ResonatorBank: Sendable {
    public var strings: [CombString]
    public var relOverSqrtN: [Double]     // rel_gain / √N(choir)
    public var isBright: [Bool]
    /// Choir tag per string, parallel to `strings` (same enabled-filtered order).
    /// Display-only — drives the Live-tab harmonic grouping; `.scale` when the
    /// caller didn't supply groups. Not used by the DSP.
    public var groups: [StringGroup]

    public init(strings: [CombString] = [], relOverSqrtN: [Double] = [],
                isBright: [Bool] = [], groups: [StringGroup] = []) {
        self.strings = strings
        self.relOverSqrtN = relOverSqrtN
        self.isBright = isBright
        self.groups = groups
    }

    /// Build the bank from resolved strings. `t60Scale` (= B_t60_scale) and the
    /// per-choir comb brightness (from `bLp` = B_lp) are baked into the combs.
    /// `specGroups` (optional, parallel to `specs` BEFORE the enabled filter)
    /// carries the choir tag for the harmonic display — defaulted, so existing
    /// callers and golden tests are unaffected.
    public static func build(strings specs: [ResolvedString], groups specGroups: [StringGroup] = [],
                             t60Scale: Double, bLp: Double, sr: Double) -> ResonatorBank {
        // Pair each spec with its group (falling back to .scale) before filtering,
        // so the resulting `groups` array stays index-aligned with `strings`.
        let tagged = specs.enumerated().map { (i, s) -> (ResolvedString, StringGroup) in
            (s, i < specGroups.count ? specGroups[i] : .scale)
        }
        let active = tagged.filter { $0.0.enabled }
        let nClean = max(1, active.filter { !$0.0.bright }.count)
        let nBright = max(1, active.filter { $0.0.bright }.count)
        var combs: [CombString] = []; combs.reserveCapacity(active.count)
        var rel: [Double] = []; rel.reserveCapacity(active.count)
        var bright: [Bool] = []; bright.reserveCapacity(active.count)
        var grp: [StringGroup] = []; grp.reserveCapacity(active.count)
        for (s, g) in active {
            // chain.process: clean choir bright = 0.6·lp, bright (raga) choir = lp
            let combBright = s.bright ? bLp : 0.6 * bLp
            combs.append(CombString(f0: s.freq, t60: s.t60 * t60Scale, sr: sr, bright: combBright))
            rel.append(s.gain / Double(s.bright ? nBright : nClean).squareRoot())
            bright.append(s.bright)
            grp.append(g)
        }
        return ResonatorBank(strings: combs, relOverSqrtN: rel, isBright: bright, groups: grp)
    }

    /// Sum the bank. `gClean = B_gain`, `gBright = B_gain·B_bright` (live).
    public mutating func process(cleanDrive x: Double, brightDrive xb: Double,
                                 gClean: Double, gBright: Double) -> Double {
        var out = 0.0
        for i in strings.indices {
            let b = isBright[i]
            let drive = b ? xb : x
            let g = b ? gBright : gClean
            out += g * relOverSqrtN[i] * strings[i].process(drive)
        }
        return out
    }

    public mutating func reset() { for i in strings.indices { strings[i].reset() } }
    public var count: Int { strings.count }
}

/// A sympathetic string after raga/tonic resolution, ready for the DSP bank.
/// (`bright` runs over the jawari bridge; `enabled` is the UI on/off toggle.)
public struct ResolvedString: Sendable, Hashable {
    public var freq: Double
    public var gain: Double
    public var t60: Double
    public var bright: Bool
    public var enabled: Bool
    public init(freq: Double, gain: Double, t60: Double, bright: Bool, enabled: Bool = true) {
        self.freq = freq; self.gain = gain; self.t60 = t60; self.bright = bright; self.enabled = enabled
    }
}
