import Foundation

/// One body-resonance band of the tanpura's gourd/plate filter.
public struct TanpuraBodyBand: Codable, Equatable, Sendable {
    /// Center frequency, Hz. 60–2000.
    public var freq: Double
    /// Linear gain of the band's contribution. 0–1.5.
    public var gain: Double
    /// Resonance Q. 0.5–350. The top of the range is deliberately high:
    /// a Q≈300 band at ~300 Hz RINGS for ~0.3 s — the reference has a
    /// real body mode near 307 Hz (rises +5.5…+7.7 dB after EVERY
    /// string's pluck, on no string's partial grid) that a coloration-Q
    /// filter cannot reproduce.
    public var q: Double

    public init(freq: Double, gain: Double, q: Double) {
        self.freq = freq
        self.gain = gain
        self.q = q
    }
}

/// Per-string parameters of the harmonic-resolved tanpura model.
///
/// Each string is synthesized as `TanpuraParams.harmonicCount` individual
/// harmonics. Harmonic k (1-based) gets its amplitude, decay time, and
/// bloom-peak time from smooth laws in k, then per-harmonic trim arrays
/// give fine-grained control over every individual harmonic:
///
///   gain_k  = |sin(π·k·pluckPos)| · k^(−falloff) · 10^(gainTrimDB[k−1]/20)
///   τd_k    = decay · k^(−dampTilt) · decayTrim[k−1]
///   tp_k    = bloomDelay · k^bloomSkew · peakTrim[k−1]   (peak time, s)
///
/// The envelope of each harmonic is `gain_k · (attackLevel·e_a + e_d − e_r)`
/// — a fast attack plus a rise/decay pair whose peak lands at tp_k. This is
/// the tanpura's defining behavior: the string's sound splits into
/// harmonics that peak at different times.
public struct TanpuraStringParams: Codable, Equatable, Sendable {
    /// Fundamental frequency, Hz. 30–1000.
    public var f0: Double
    /// String output level. 0–2.2 (matches the optimizer's search range —
    /// the in-app `set(path:)` clamp must never be tighter than what the
    /// offline-scored winner used, or in-app playback silently diverges).
    public var level: Double
    /// Spectral falloff exponent: gain_k ∝ k^(−falloff). 0–4.
    public var falloff: Double
    /// Pluck position along the string (fraction). Imposes the comb
    /// |sin(πk·pos)| on harmonic gains. 0.02–0.5.
    public var pluckPos: Double
    /// Decay time (seconds to −60 dB-ish; τ of harmonic 1 is decay/6.91·…
    /// — practically: e-fold time τd_1 = decay). 0.2–30.
    public var decay: Double
    /// Decay tilt: τd_k = decay·k^(−dampTilt). 0–2.
    public var dampTilt: Double
    /// Bloom delay: harmonic k's envelope peaks at
    /// tp_k = bloomDelay·k^bloomSkew seconds after the pluck. 0–1.5.
    public var bloomDelay: Double
    /// Bloom skew exponent (how strongly higher harmonics peak later). 0–2.
    public var bloomSkew: Double
    /// Share of an immediate (non-bloomed) attack component. 0–1.
    public var attackLevel: Double
    /// e-fold time of the immediate attack component, seconds. 0.005–0.5.
    public var attackDecay: Double
    /// Stiffness inharmonicity B: f_k = k·f0·√(1+B·k²). 0–0.002.
    public var inharmonicity: Double
    /// Level of the HALF-INTEGER partial bank, dB relative to the main
    /// stack's laws. The jawari bridge's period-2 contact motion puts
    /// audible partials at (k+0.5)·f0 — measured in the reference at
    /// −7…−35 dBpk (e.g. sa·3.5 = 918 Hz, Pa·1.5 = 295 Hz, SA·0.5 =
    /// 65.6 Hz); a purely integer-harmonic model cannot make them. The
    /// bank reuses the string's decay/bloom laws evaluated at h = k+0.5
    /// (no per-harmonic trims), scaled by this. −60 = off. −60…−2.
    public var subLevelDB: Double
    /// Spectral falloff of the sub bank: gain ∝ h^(−subFalloff). Separate
    /// from `falloff` — the reference's half-integer partials die off
    /// faster with k than its integer ones (run-7 residual: Pa·1.5 was
    /// 12 dB short while SA·3.5/6.5 were 11–14 dB in excess under a
    /// shared law). 0–4.
    public var subFalloff: Double
    /// Knee of a smooth 4th-order lowpass in h on the sub bank:
    /// gain ×= 1/(1+(h/subKneeH)⁴). A single power law can't hold the
    /// loud low half-integer partials (sa·3.5 ≈ −7 dBpk) without leaking
    /// excess at h ≳ 8 (run-8 residual: +11 dB at 4 kHz); period-2 bridge
    /// motion mostly affects low partials. 64 ≈ off. 1–64.
    public var subKneeH: Double
    /// Per-harmonic gain trim, dB (index 0 = harmonic 1). −60…+24.
    public var gainTrimDB: [Double]
    /// Per-harmonic multiplier on the bloom peak time tp_k. 0.05–8.
    public var peakTrim: [Double]
    /// Per-harmonic multiplier on the decay time τd_k. 0.05–8.
    public var decayTrim: [Double]

    public init(f0: Double,
                level: Double = 1.0,
                falloff: Double = 0.8,
                pluckPos: Double = 0.10,
                decay: Double = 4.0,
                dampTilt: Double = 0.6,
                bloomDelay: Double = 0.12,
                bloomSkew: Double = 0.5,
                attackLevel: Double = 0.4,
                attackDecay: Double = 0.04,
                inharmonicity: Double = 0.00002,
                subLevelDB: Double = -60,
                subFalloff: Double = 1.6,
                subKneeH: Double = 64,
                gainTrimDB: [Double] = TanpuraParams.neutralGainTrims,
                peakTrim: [Double] = TanpuraParams.neutralMulTrims,
                decayTrim: [Double] = TanpuraParams.neutralMulTrims) {
        self.f0 = f0
        self.level = level
        self.falloff = falloff
        self.pluckPos = pluckPos
        self.decay = decay
        self.dampTilt = dampTilt
        self.bloomDelay = bloomDelay
        self.bloomSkew = bloomSkew
        self.attackLevel = attackLevel
        self.attackDecay = attackDecay
        self.inharmonicity = inharmonicity
        self.subLevelDB = subLevelDB
        self.subFalloff = subFalloff
        self.subKneeH = subKneeH
        self.gainTrimDB = TanpuraParams.padTrims(gainTrimDB, fill: 0)
        self.peakTrim = TanpuraParams.padTrims(peakTrim, fill: 1)
        self.decayTrim = TanpuraParams.padTrims(decayTrim, fill: 1)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TanpuraStringParams(f0: 130.81)
        f0 = try c.decodeIfPresent(Double.self, forKey: .f0) ?? d.f0
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? d.level
        falloff = try c.decodeIfPresent(Double.self, forKey: .falloff) ?? d.falloff
        pluckPos = try c.decodeIfPresent(Double.self, forKey: .pluckPos) ?? d.pluckPos
        decay = try c.decodeIfPresent(Double.self, forKey: .decay) ?? d.decay
        dampTilt = try c.decodeIfPresent(Double.self, forKey: .dampTilt) ?? d.dampTilt
        bloomDelay = try c.decodeIfPresent(Double.self, forKey: .bloomDelay) ?? d.bloomDelay
        bloomSkew = try c.decodeIfPresent(Double.self, forKey: .bloomSkew) ?? d.bloomSkew
        attackLevel = try c.decodeIfPresent(Double.self, forKey: .attackLevel) ?? d.attackLevel
        attackDecay = try c.decodeIfPresent(Double.self, forKey: .attackDecay) ?? d.attackDecay
        inharmonicity = try c.decodeIfPresent(Double.self, forKey: .inharmonicity) ?? d.inharmonicity
        subLevelDB = try c.decodeIfPresent(Double.self, forKey: .subLevelDB) ?? d.subLevelDB
        subFalloff = try c.decodeIfPresent(Double.self, forKey: .subFalloff) ?? d.subFalloff
        subKneeH = try c.decodeIfPresent(Double.self, forKey: .subKneeH) ?? d.subKneeH
        gainTrimDB = TanpuraParams.padTrims(
            try c.decodeIfPresent([Double].self, forKey: .gainTrimDB) ?? d.gainTrimDB, fill: 0)
        peakTrim = TanpuraParams.padTrims(
            try c.decodeIfPresent([Double].self, forKey: .peakTrim) ?? d.peakTrim, fill: 1)
        decayTrim = TanpuraParams.padTrims(
            try c.decodeIfPresent([Double].self, forKey: .decayTrim) ?? d.decayTrim, fill: 1)
    }
}

/// All parameters of the tanpura drone model. Codable — this struct is the
/// single source of truth for the JSON schema shared with the offline
/// renderer (`tanpura-render`) and the Python matching tools.
///
/// The default values below are the MATCHED parameter set fitted to
/// `tanpura.mp3` by tools/tanpura_iterate.py (calibrate → fit-init →
/// CMA-ES). Re-bake with tools/tanpura_bake_defaults.py after a new run.
public struct TanpuraParams: Codable, Equatable, Sendable {
    /// Hard cap on harmonics per string; trim arrays are always this long.
    /// 64 so the upper strings reach the reference's tonal sheen at 6–8 kHz
    /// (C4 needs k≈30, SA's own series k≈61; harmonics above fs·0.45 are
    /// skipped by the engine, so high k on low strings is safe).
    public static let maxHarmonics = 64

    /// Bumped every time a new matched parameter set is baked into the
    /// defaults below. AppController keys its UserDefaults persistence on
    /// this, so a fresh bake isn't shadowed by stale persisted params.
    public static let matchedVersion = 7

    public static var neutralGainTrims: [Double] { [Double](repeating: 0, count: maxHarmonics) }
    public static var neutralMulTrims: [Double] { [Double](repeating: 1, count: maxHarmonics) }

    static func padTrims(_ a: [Double], fill: Double) -> [Double] {
        if a.count == maxHarmonics { return a }
        if a.count > maxHarmonics { return Array(a.prefix(maxHarmonics)) }
        return a + [Double](repeating: fill, count: maxHarmonics - a.count)
    }

    /// Number of synthesized harmonics per string. 4–32.
    public var harmonicCount: Int = 64
    /// Depth of the per-harmonic slow amplitude undulation ("jiva"). 0–1.
    public var jivaDepth: Double = 0.336
    /// Mean jiva LFO rate, Hz (per-harmonic jitter 0.5–1.5×). 0.05–3.
    public var jivaRate: Double = 2.21
    /// 0 = jiva uniform across harmonics; 1 = concentrated on mid harmonics. 0–1.
    public var jivaTilt: Double = 0.293
    /// Energy conservation of the jiva undulation. At 1, each block's
    /// jiva gains are rescaled so the string's total modulated power
    /// equals its unmodulated power — harmonics swell and fade AGAINST
    /// each other (the real jawari behavior) instead of pumping the
    /// summed envelope ("wah-wah" on an isolated pluck). 0–1.
    public var jivaConserve: Double = 0.966
    /// Width of the per-harmonic jiva-rate scatter around the mean rate.
    /// 1 = the original 0.5–1.5× spread; 0 = every harmonic shares one
    /// rate, concentrating the modulation at a single frequency. Real
    /// tanpura isolated-pluck jiva is a TIGHT ~2 Hz pulsation, not the
    /// broadband 1.5–7 Hz smear independent random rates produce. 0–1.5.
    public var jivaRateSpread: Double = 0.176
    /// Per-string slow random pitch drift amplitude, cents. 0–10.
    public var pitchDriftCents: Double = 13.67
    /// Pitch-drift lowpass rate, Hz. 0.01–2.
    public var pitchDriftRate: Double = 0.625
    /// Random per-harmonic gain jitter applied to each individual pluck, dB. 0–6.
    public var pluckVariationDB: Double = 4.201
    /// Pluck attack-noise ("chik") level. 0–1.
    public var noiseLevel: Double = 0.771
    /// Attack-noise e-fold decay, seconds. 0.002–0.1.
    public var noiseDecay: Double = 0.0113
    /// Attack-noise bandpass center, Hz. 300–8000.
    public var noiseFreq: Double = 909.9
    /// Attack-noise bandpass Q. 0.3–8.
    public var noiseQ: Double = 1.283
    /// Sympathetic cross-excitation: pluck energy leaked into coincident
    /// harmonics of the other strings. 0–0.5.
    public var crossExcite: Double = 0.341
    /// Frequency tolerance for harmonic coincidence, cents. 1–50.
    public var crossTolCents: Double = 12.0
    /// Stereo spread of the four strings. 0–1.
    public var panSpread: Double = 0.4
    /// Dry (unfiltered) share of the body output mix. 0–1.
    public var bodyDry: Double = 0.763
    /// First-order high-shelf tilt at 1.5 kHz, dB. −12…12.
    public var tiltDB: Double = -8.65
    /// Output gain. 0–1.
    public var masterGain: Double = 0.0937
    /// Room (small Schroeder reverb after body/shelf, before the limiter)
    /// wet level, dB. The reference recording's room broadens every
    /// partial line, fills inter-harmonic cells, and smears decays —
    /// run-9's diffuse residual plateau (~6.8 dB specres vs a ~2.5 dB
    /// floor) was unfixable by string params alone. −60 = off. −60…−6.
    public var roomWetDB: Double = -5.45
    /// Room RT60-ish decay, seconds. 0.15–2.5.
    public var roomDecayS: Double = 2.295
    /// Room high-frequency damping inside the comb feedback. 0–1.
    public var roomDamp: Double = 0.896
    /// Room predelay, ms. 0–40.
    public var roomPredelayMs: Double = 1.7
    /// Body resonances (gourd ~110 Hz, plate ~215 Hz, mid formant ~900 Hz).
    public var body: [TanpuraBodyBand] = [
        TanpuraBodyBand(freq: 135.0, gain: 1.256, q: 13.49),
        TanpuraBodyBand(freq: 422.7, gain: 0.96, q: 1.28),
        TanpuraBodyBand(freq: 812.9, gain: 0.009, q: 224.97),
    ]
    /// The four strings: Pa (G3), sa (C4), sa (C4), SA (C3) by default.
    public var strings: [TanpuraStringParams] = [
        TanpuraStringParams(
            f0: 196.91, level: 1.052, falloff: 1.098,
            pluckPos: 0.08, decay: 3.247, dampTilt: 0.199,
            bloomDelay: 0.781, bloomSkew: 0.1,
            attackLevel: 0.944, attackDecay: 0.0205,
            inharmonicity: 0.000003, subLevelDB: -18.78, subFalloff: 0.379, subKneeH: 55.94,
            gainTrimDB: [9.45, -9.83, -12.9, 2.51, -6.54, 1.56, 2.23, 3.01, -1.6, 1.77, 2.32, 5.6, 3.97, 17.78, 13.94, 0.2, -11.87, -1.22, -6.17, -12.46, -15.58, -6.99, -1.21, 7.41, 17.99, -8.0, -8.0, -0.08, -6.52, 1.52, -8.72, 2.07, -17.56, -15.47, -16.87, -6.07, -3.66, -3.39, -6.88, -15.54, -15.68, -10.67, -14.53, -10.84, -15.95, -4.89, -7.01, -10.99],
            peakTrim: [1.136, 1.062, 0.982, 1.444, 0.763, 0.742, 1.292, 0.722, 0.765, 1.14, 0.736, 1.442, 0.916, 0.532, 1.853, 1.344, 0.743, 0.721, 1.604, 0.687, 0.985, 0.735, 1.206, 1.916, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            decayTrim: [0.634, 1.0, 3.0, 0.3, 0.49, 1.647, 1.818, 2.145, 1.952, 1.0, 1.524, 2.84, 2.858, 1.313, 0.3, 0.469, 3.0, 3.0, 0.3, 1.781, 1.0, 1.152, 1.037, 0.3, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
        TanpuraStringParams(
            f0: 262.28, level: 1.305, falloff: 2.071,
            pluckPos: 0.1, decay: 2.134, dampTilt: 0.29,
            bloomDelay: 0.202, bloomSkew: 0.067,
            attackLevel: 0.466, attackDecay: 0.0135,
            inharmonicity: 0.000002, subLevelDB: -6.25, subFalloff: 0.356, subKneeH: 43.22,
            gainTrimDB: [1.46, -11.34, -30.0, 13.98, 2.63, 10.62, 0.37, 12.25, -3.65, 15.76, -5.46, -2.88, -11.81, -9.97, -30.0, -9.84, -3.15, 2.14, -30.0, -30.0, -30.0, 7.8, -5.3, -5.44, -1.25, 11.03, -5.61, -8.0, 4.96, -8.0, 3.57, 18.0, 6.05, 12.46, 7.62, 6.85, 6.59, 9.91, 1.91, 1.91, 1.91, 12.89, 1.91, 16.35, 1.91, 1.91, 1.91, 1.91],
            peakTrim: [0.967, 1.429, 1.0, 1.158, 0.445, 0.649, 1.122, 1.559, 1.002, 1.182, 0.741, 1.695, 1.057, 0.645, 1.0, 1.44, 1.4, 0.546, 1.0, 1.0, 1.0, 1.321, 1.159, 0.724, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            decayTrim: [1.0, 1.0, 1.0, 0.391, 1.05, 3.0, 1.0, 0.409, 0.368, 2.087, 3.0, 0.3, 2.927, 2.68, 1.0, 0.695, 0.368, 1.319, 1.0, 1.0, 1.0, 0.652, 1.031, 2.033, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
        TanpuraStringParams(
            f0: 262.19, level: 1.305, falloff: 2.071,
            pluckPos: 0.1, decay: 2.134, dampTilt: 0.29,
            bloomDelay: 0.202, bloomSkew: 0.067,
            attackLevel: 0.466, attackDecay: 0.0135,
            inharmonicity: 0.000002, subLevelDB: -6.25, subFalloff: 0.356, subKneeH: 43.22,
            gainTrimDB: [1.46, -11.34, -30.0, 13.98, 2.63, 10.62, 0.37, 12.25, -3.65, 15.76, -5.46, -2.88, -11.81, -9.97, -30.0, -9.84, -3.15, 2.14, -30.0, -30.0, -30.0, 7.8, -5.3, -5.44, -1.25, 11.03, -5.61, -8.0, 4.96, -8.0, 3.57, 18.0, 6.05, 12.46, 7.62, 6.85, 6.59, 9.91, 1.91, 1.91, 1.91, 12.89, 1.91, 16.35, 1.91, 1.91, 1.91, 1.91],
            peakTrim: [0.967, 1.429, 1.0, 1.158, 0.445, 0.649, 1.122, 1.559, 1.002, 1.182, 0.741, 1.695, 1.057, 0.645, 1.0, 1.44, 1.4, 0.546, 1.0, 1.0, 1.0, 1.321, 1.159, 0.724, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            decayTrim: [1.0, 1.0, 1.0, 0.391, 1.05, 3.0, 1.0, 0.409, 0.368, 2.087, 3.0, 0.3, 2.927, 2.68, 1.0, 0.695, 0.368, 1.319, 1.0, 1.0, 1.0, 0.652, 1.031, 2.033, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
        TanpuraStringParams(
            f0: 131.11, level: 1.88, falloff: 1.025,
            pluckPos: 0.04, decay: 0.851, dampTilt: 0.106,
            bloomDelay: 0.618, bloomSkew: 0.063,
            attackLevel: 0.977, attackDecay: 0.0093,
            inharmonicity: 0.00001, subLevelDB: -11.04, subFalloff: 1.367, subKneeH: 60.29,
            gainTrimDB: [0.29, -0.41, -11.74, -8.98, -10.82, -0.6, 11.35, 13.8, 3.89, 5.3, -0.28, 7.84, 2.48, -0.5, -1.19, 5.56, 15.96, -9.77, -4.38, -3.48, 1.82, -4.59, 9.03, 12.93, 18.0, 6.14, 11.24, 2.85, -8.18, -12.97, -8.3, -6.94, 1.9, -10.59, 5.07, -9.04, -9.86, -16.03, -14.39, -9.89, -9.89, -10.01, -0.22, -0.24, 12.49, -3.52, -1.61, 2.64],
            peakTrim: [1.014, 0.847, 1.311, 1.011, 1.191, 0.628, 1.699, 1.585, 0.975, 1.533, 0.593, 0.641, 0.514, 0.3, 1.203, 1.529, 1.431, 0.877, 1.404, 1.541, 0.606, 0.864, 1.559, 1.266, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            decayTrim: [1.641, 1.0, 1.696, 0.3, 0.3, 1.0, 0.3, 1.0, 1.0, 1.0, 3.0, 3.0, 3.0, 3.0, 1.0, 1.0, 1.0, 2.377, 1.0, 3.0, 3.0, 3.0, 0.3, 1.392, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TanpuraParams()
        harmonicCount = try c.decodeIfPresent(Int.self, forKey: .harmonicCount) ?? d.harmonicCount
        jivaDepth = try c.decodeIfPresent(Double.self, forKey: .jivaDepth) ?? d.jivaDepth
        jivaRate = try c.decodeIfPresent(Double.self, forKey: .jivaRate) ?? d.jivaRate
        jivaTilt = try c.decodeIfPresent(Double.self, forKey: .jivaTilt) ?? d.jivaTilt
        jivaConserve = try c.decodeIfPresent(Double.self, forKey: .jivaConserve) ?? d.jivaConserve
        jivaRateSpread = try c.decodeIfPresent(Double.self, forKey: .jivaRateSpread) ?? d.jivaRateSpread
        pitchDriftCents = try c.decodeIfPresent(Double.self, forKey: .pitchDriftCents) ?? d.pitchDriftCents
        pitchDriftRate = try c.decodeIfPresent(Double.self, forKey: .pitchDriftRate) ?? d.pitchDriftRate
        pluckVariationDB = try c.decodeIfPresent(Double.self, forKey: .pluckVariationDB) ?? d.pluckVariationDB
        noiseLevel = try c.decodeIfPresent(Double.self, forKey: .noiseLevel) ?? d.noiseLevel
        noiseDecay = try c.decodeIfPresent(Double.self, forKey: .noiseDecay) ?? d.noiseDecay
        noiseFreq = try c.decodeIfPresent(Double.self, forKey: .noiseFreq) ?? d.noiseFreq
        noiseQ = try c.decodeIfPresent(Double.self, forKey: .noiseQ) ?? d.noiseQ
        crossExcite = try c.decodeIfPresent(Double.self, forKey: .crossExcite) ?? d.crossExcite
        crossTolCents = try c.decodeIfPresent(Double.self, forKey: .crossTolCents) ?? d.crossTolCents
        panSpread = try c.decodeIfPresent(Double.self, forKey: .panSpread) ?? d.panSpread
        bodyDry = try c.decodeIfPresent(Double.self, forKey: .bodyDry) ?? d.bodyDry
        tiltDB = try c.decodeIfPresent(Double.self, forKey: .tiltDB) ?? d.tiltDB
        masterGain = try c.decodeIfPresent(Double.self, forKey: .masterGain) ?? d.masterGain
        roomWetDB = try c.decodeIfPresent(Double.self, forKey: .roomWetDB) ?? d.roomWetDB
        roomDecayS = try c.decodeIfPresent(Double.self, forKey: .roomDecayS) ?? d.roomDecayS
        roomDamp = try c.decodeIfPresent(Double.self, forKey: .roomDamp) ?? d.roomDamp
        roomPredelayMs = try c.decodeIfPresent(Double.self, forKey: .roomPredelayMs) ?? d.roomPredelayMs
        var bodyIn = try c.decodeIfPresent([TanpuraBodyBand].self, forKey: .body) ?? d.body
        while bodyIn.count < 3 { bodyIn.append(d.body[bodyIn.count]) }
        body = Array(bodyIn.prefix(3))
        var stringsIn = try c.decodeIfPresent([TanpuraStringParams].self, forKey: .strings) ?? d.strings
        while stringsIn.count < 4 { stringsIn.append(d.strings[stringsIn.count]) }
        strings = Array(stringsIn.prefix(4))
        harmonicCount = max(4, min(TanpuraParams.maxHarmonics, harmonicCount))
    }

    // MARK: - Path-based access

    /// Set a parameter by string path. Used by the audition `voiceParam`
    /// route (`tanpura.<path>`) and shared with the optimizer tooling.
    /// Paths: global field names (`"jivaDepth"`), `"bodyN.freq|gain|q"`,
    /// `"stringN.<field>"`, and per-harmonic `"stringN.gainTrimDB<k>"` /
    /// `"stringN.peakTrim<k>"` / `"stringN.decayTrim<k>"` with k = 0-based
    /// harmonic index. Values are clamped to safe ranges. Returns false
    /// for unknown paths.
    @discardableResult
    public mutating func set(path: String, value: Double) -> Bool {
        func cl(_ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, value)) }

        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 1 {
            switch path {
            case "harmonicCount": harmonicCount = Int(cl(4, Double(TanpuraParams.maxHarmonics)))
            case "jivaDepth": jivaDepth = cl(0, 1)
            case "jivaRate": jivaRate = cl(0.05, 3)
            case "jivaTilt": jivaTilt = cl(0, 1)
            case "jivaConserve": jivaConserve = cl(0, 1)
            case "jivaRateSpread": jivaRateSpread = cl(0, 1.5)
            case "pitchDriftCents": pitchDriftCents = cl(0, 10)
            case "pitchDriftRate": pitchDriftRate = cl(0.01, 2)
            case "pluckVariationDB": pluckVariationDB = cl(0, 6)
            case "noiseLevel": noiseLevel = cl(0, 1)
            case "noiseDecay": noiseDecay = cl(0.002, 0.1)
            case "noiseFreq": noiseFreq = cl(300, 8000)
            case "noiseQ": noiseQ = cl(0.3, 8)
            case "crossExcite": crossExcite = cl(0, 0.5)
            case "crossTolCents": crossTolCents = cl(1, 50)
            case "panSpread": panSpread = cl(0, 1)
            case "bodyDry": bodyDry = cl(0, 1)
            case "tiltDB": tiltDB = cl(-12, 12)
            case "masterGain": masterGain = cl(0, 1)
            case "roomWetDB": roomWetDB = cl(-60, -3)
            case "roomDecayS": roomDecayS = cl(0.15, 2.5)
            case "roomDamp": roomDamp = cl(0, 1)
            case "roomPredelayMs": roomPredelayMs = cl(0, 40)
            default: return false
            }
            return true
        }

        let head = parts[0], field = parts[1]
        if head.hasPrefix("body"), let i = Int(head.dropFirst(4)), body.indices.contains(i) {
            switch field {
            case "freq": body[i].freq = cl(60, 2000)
            case "gain": body[i].gain = cl(0, 1.5)
            case "q": body[i].q = cl(0.5, 350)
            default: return false
            }
            return true
        }
        if head.hasPrefix("string"), let i = Int(head.dropFirst(6)), strings.indices.contains(i) {
            // Per-harmonic trims: field name with trailing 0-based index.
            for (prefix, fill) in [("gainTrimDB", 0.0), ("peakTrim", 1.0), ("decayTrim", 1.0)] {
                if field.hasPrefix(prefix), field.count > prefix.count,
                   let k = Int(field.dropFirst(prefix.count)),
                   (0..<TanpuraParams.maxHarmonics).contains(k) {
                    _ = fill
                    switch prefix {
                    case "gainTrimDB": strings[i].gainTrimDB[k] = cl(-60, 24)
                    case "peakTrim": strings[i].peakTrim[k] = cl(0.05, 8)
                    default: strings[i].decayTrim[k] = cl(0.05, 8)
                    }
                    return true
                }
            }
            switch field {
            case "f0": strings[i].f0 = cl(30, 1000)
            case "level": strings[i].level = cl(0, 2.2)
            case "falloff": strings[i].falloff = cl(0, 4)
            case "pluckPos": strings[i].pluckPos = cl(0.02, 0.5)
            case "decay": strings[i].decay = cl(0.2, 30)
            case "dampTilt": strings[i].dampTilt = cl(0, 2)
            case "bloomDelay": strings[i].bloomDelay = cl(0, 1.5)
            case "bloomSkew": strings[i].bloomSkew = cl(0, 2)
            case "attackLevel": strings[i].attackLevel = cl(0, 1)
            case "attackDecay": strings[i].attackDecay = cl(0.005, 0.5)
            case "inharmonicity": strings[i].inharmonicity = cl(0, 0.002)
            case "subLevelDB": strings[i].subLevelDB = cl(-60, -2)
            case "subFalloff": strings[i].subFalloff = cl(0, 4)
            case "subKneeH": strings[i].subKneeH = cl(1, 64)
            default: return false
            }
            return true
        }
        return false
    }
}

// MARK: - Offline render spec

/// One scheduled pluck in an offline render spec.
public struct TanpuraPluckEvent: Codable, Equatable, Sendable {
    /// Seconds from render start.
    public var at: Double
    /// String index 0–3.
    public var string: Int
    /// Pluck velocity 0–1.
    public var velocity: Double

    public init(at: Double, string: Int, velocity: Double) {
        self.at = at
        self.string = string
        self.velocity = velocity
    }
}

/// Input JSON for the `tanpura-render` executable.
public struct TanpuraRenderSpec: Codable, Sendable {
    public var sampleRate: Double?
    public var durationSeconds: Double
    public var seed: UInt64?
    public var params: TanpuraParams?
    public var plucks: [TanpuraPluckEvent]
    /// Output WAV path (may be overridden by `-o` for a single spec).
    public var out: String?

    public init(sampleRate: Double? = nil, durationSeconds: Double,
                seed: UInt64? = nil, params: TanpuraParams? = nil,
                plucks: [TanpuraPluckEvent], out: String? = nil) {
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.seed = seed
        self.params = params
        self.plucks = plucks
        self.out = out
    }
}
