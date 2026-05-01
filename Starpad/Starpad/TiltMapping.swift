import Foundation

/// An input dimension that can drive a mappable parameter.
///
/// Dimensions 1-3 are **global** (same value for all voices).
/// Dimensions 4-5 are **per-note** (each voice has its own value).
/// Dimensions 6-7 are **global** (slider panels in UI).
enum Dimension: Int, Codable, CaseIterable, Hashable {
    case tilt1          = 0
    case tilt2          = 1
    case tilt3          = 2
    case accelPressure  = 3
    case keyY           = 4
    case slider1        = 5
    case slider2        = 6
    case none           = -1

    var label: String {
        switch self {
        case .tilt1:         return "Tilt 1"
        case .tilt2:         return "Tilt 2"
        case .tilt3:         return "Tilt 3"
        case .accelPressure: return "Pressure"
        case .keyY:          return "Key Y"
        case .slider1:       return "Slider 1"
        case .slider2:       return "Slider 2"
        case .none:          return "None"
        }
    }

    /// Short label for matrix column/row headers.
    var shortLabel: String {
        switch self {
        case .tilt1:         return "T1"
        case .tilt2:         return "T2"
        case .tilt3:         return "T3"
        case .accelPressure: return "Pr"
        case .keyY:          return "Y"
        case .slider1:       return "S1"
        case .slider2:       return "S2"
        case .none:          return "—"
        }
    }

    var isPerNote: Bool { self == .accelPressure || self == .keyY }
    var isTilt: Bool { self == .tilt1 || self == .tilt2 || self == .tilt3 }
    var isSlider: Bool { self == .slider1 || self == .slider2 }

    /// The 7 real dimensions (excludes .none).
    static let real: [Dimension] = [.tilt1, .tilt2, .tilt3, .accelPressure, .keyY, .slider1, .slider2]
}

/// Identifies each mappable parameter.
enum MappableParameter: Int, Codable, CaseIterable, Hashable {
    case velocity         = 0
    case glideSpeed       = 1
    case glideCompression = 2
    case amplitude        = 3
    case vibratoDepth     = 4
    case vibratoRate      = 5
    case vibratoIntensity = 6
    case dragSmoothing    = 7
    case glideCurve       = 8
    case aftertouch       = 9
    case midiCC74         = 10
    case midiCC1          = 11
    case midiCC11         = 12
    case midiCC71         = 13
    case midiCC73         = 14
    case midiCC75         = 15
    case sympatheticVolume     = 16
    case sympatheticWidth      = 17
    case sympatheticSpread     = 18
    case sympatheticConsonance = 19
    case sympatheticDetune     = 20
    case harmonicFalloff       = 21
    case noteAttack            = 22
    case reverbMix             = 23
    case bowForce              = 24
    // Appended — raw values 25..31. Never renumber existing cases; persisted
    // DimensionMapping data is keyed by storageKey, but Codable integer
    // fallback can still reference raw values.
    case stringDecay           = 25
    case symDecay              = 26
    case dampingTilt           = 27
    case inharmonicity         = 28
    case symCoupling           = 29
    case pluckPosition         = 30
    // Expressivity additions (modal count, fundamental emphasis, breath path).
    case partialCount          = 31
    case fundamentalBoost      = 32
    case breathLevel           = 33
    // breathOffset / breathSpread pitch-track the played fundamental — the
    // breath bandpass is centered at `f0 · 2^(offset/12)` with log-frequency
    // bandwidth `spread` semitones. Old raw values kept so persisted
    // bindings still deserialize; semantics have changed.
    case breathOffset          = 34
    case breathSpread          = 35

    static let count = 36

    /// Display order for the mapping panel, grouped by category.
    static let displayOrder: [(group: String, params: [MappableParameter])] = [
        ("MIDI / Volume", [.velocity, .amplitude, .aftertouch, .midiCC74, .midiCC1, .midiCC11, .midiCC71, .midiCC73, .midiCC75]),
        ("Glide", [.glideSpeed, .glideCompression, .glideCurve, .dragSmoothing]),
        ("Vibrato", [.vibratoDepth, .vibratoRate, .vibratoIntensity]),
        ("Sympathetic", [.sympatheticVolume, .sympatheticWidth, .sympatheticSpread, .sympatheticConsonance, .sympatheticDetune, .symDecay, .symCoupling]),
        ("Voice", [.noteAttack, .harmonicFalloff, .fundamentalBoost, .partialCount, .bowForce, .pluckPosition, .stringDecay, .dampingTilt, .inharmonicity, .reverbMix]),
        ("Breath", [.breathLevel, .breathOffset, .breathSpread]),
    ]

    var storageKey: String {
        switch self {
        case .velocity:         return "velocity"
        case .glideSpeed:       return "glideSpeed"
        case .glideCompression: return "glideCompression"
        case .amplitude:        return "amplitude"
        case .vibratoDepth:     return "vibratoDepth"
        case .vibratoRate:      return "vibratoRate"
        case .vibratoIntensity: return "vibratoIntensity"
        case .dragSmoothing:    return "dragSmoothing"
        case .glideCurve:       return "glideCurve"
        case .aftertouch:       return "aftertouch"
        case .midiCC74:         return "midiCC74"
        case .midiCC1:          return "midiCC1"
        case .midiCC11:         return "midiCC11"
        case .midiCC71:         return "midiCC71"
        case .midiCC73:         return "midiCC73"
        case .midiCC75:         return "midiCC75"
        case .sympatheticVolume:     return "sympatheticVolume"
        case .sympatheticWidth:      return "sympatheticWidth"
        case .sympatheticSpread:     return "sympatheticSpread"
        case .sympatheticConsonance: return "sympatheticConsonance"
        case .sympatheticDetune:     return "sympatheticDetune"
        case .harmonicFalloff:       return "harmonicFalloff"
        case .noteAttack:            return "noteAttack"
        case .reverbMix:             return "reverbMix"
        case .bowForce:              return "bowForce"
        case .stringDecay:           return "stringDecay"
        case .symDecay:              return "symDecay"
        case .dampingTilt:           return "dampingTilt"
        case .inharmonicity:         return "inharmonicity"
        case .symCoupling:           return "symCoupling"
        case .pluckPosition:         return "pluckPosition"
        case .partialCount:          return "partialCount"
        case .fundamentalBoost:      return "fundamentalBoost"
        case .breathLevel:           return "breathLevel"
        case .breathOffset:          return "breathOffset"
        case .breathSpread:          return "breathSpread"
        }
    }

    var label: String {
        switch self {
        case .velocity:         return "Velocity"
        case .glideSpeed:       return "Glide Speed"
        case .glideCompression: return "Compression"
        case .amplitude:        return "Amplitude"
        case .vibratoDepth:     return "Vib Depth"
        case .vibratoRate:      return "Vib Rate"
        case .vibratoIntensity: return "Vib Intensity"
        case .dragSmoothing:    return "Drag Smooth"
        case .glideCurve:       return "Glide Curve"
        case .aftertouch:       return "Aftertouch"
        case .midiCC74:         return "CC74 Slide"
        case .midiCC1:          return "CC1 Modwheel"
        case .midiCC11:         return "CC11 Expression"
        case .midiCC71:         return "CC71 Resonance"
        case .midiCC73:         return "CC73 Attack"
        case .midiCC75:         return "CC75 Decay"
        case .sympatheticVolume:     return "Symp Vol"
        case .sympatheticWidth:      return "Symp Width"
        case .sympatheticSpread:     return "Symp Spread"
        case .sympatheticConsonance: return "Symp Consonance"
        case .sympatheticDetune:     return "Symp Detune"
        case .harmonicFalloff:       return "Harm Falloff"
        case .noteAttack:            return "Note Attack"
        case .reverbMix:             return "Reverb"
        case .bowForce:              return "Bow Force"
        case .stringDecay:           return "String Decay"
        case .symDecay:              return "Symp Decay"
        case .dampingTilt:           return "Damping Tilt"
        case .inharmonicity:         return "Inharm"
        case .symCoupling:           return "Symp Couple"
        case .pluckPosition:         return "Pluck Pos"
        case .partialCount:          return "Partial Count"
        case .fundamentalBoost:      return "Fund Boost"
        case .breathLevel:           return "Breath"
        case .breathOffset:          return "Breath Offset"
        case .breathSpread:          return "Breath Spread"
        }
    }

    /// Short label for matrix headers.
    var shortLabel: String {
        switch self {
        case .velocity:         return "Vel"
        case .glideSpeed:       return "Gld"
        case .glideCompression: return "Cmp"
        case .amplitude:        return "Amp"
        case .vibratoDepth:     return "VbD"
        case .vibratoRate:      return "VbR"
        case .vibratoIntensity: return "VbI"
        case .dragSmoothing:    return "DrS"
        case .glideCurve:       return "GlC"
        case .aftertouch:       return "AT"
        case .midiCC74:         return "C74"
        case .midiCC1:          return "C1"
        case .midiCC11:         return "C11"
        case .midiCC71:         return "C71"
        case .midiCC73:         return "C73"
        case .midiCC75:         return "C75"
        case .sympatheticVolume:     return "SyV"
        case .sympatheticWidth:      return "SyW"
        case .sympatheticSpread:     return "SyS"
        case .sympatheticConsonance: return "SyC"
        case .sympatheticDetune:     return "SyD"
        case .harmonicFalloff:       return "HF"
        case .noteAttack:            return "Atk"
        case .reverbMix:             return "Rev"
        case .bowForce:              return "Bow"
        case .stringDecay:           return "Dcy"
        case .symDecay:              return "SyDc"
        case .dampingTilt:           return "DTlt"
        case .inharmonicity:         return "Inh"
        case .symCoupling:           return "SyCp"
        case .pluckPosition:         return "PPos"
        case .partialCount:          return "Prts"
        case .fundamentalBoost:      return "Fnd"
        case .breathLevel:           return "Brth"
        case .breathOffset:          return "BrOf"
        case .breathSpread:          return "BrSp"
        }
    }

    var detail: String? {
        switch self {
        case .velocity:         return "MIDI note-on velocity, set once when the note fires"
        case .glideSpeed:       return "How long pitch takes to glide between notes"
        case .glideCompression: return "How quickly queued notes interrupt the current glide"
        case .amplitude:        return "Volume multiplier applied to each note"
        case .vibratoDepth:     return "Max pitch wobble at full vibrato intensity"
        case .vibratoRate:      return "Speed of the vibrato wobble"
        case .vibratoIntensity: return "How much vibrato is applied (default: Key Y, top = max)"
        case .dragSmoothing:    return "How tightly pitch follows your finger during drag"
        case .glideCurve:       return "Shape of the glide: low = linear, high = sharp S-curve"
        case .aftertouch:       return "MIDI channel pressure, continuous per voice"
        case .midiCC74:         return "MPE Slide — mapped to filter cutoff in most synths"
        case .midiCC1:          return nil
        case .midiCC11:         return "Secondary volume/dynamics control"
        case .midiCC71:         return nil
        case .midiCC73:         return nil
        case .midiCC75:         return nil
        case .sympatheticVolume:     return "Overall amplitude of the always-on sympathetic voices"
        case .sympatheticWidth:      return "Gaussian σ in semitones — sharpness of excitation peaks. Small = only near-exact ratios excite; large = broader response"
        case .sympatheticSpread:     return "Scales non-unison interval weights. 0 = only proximity (unison) matters; 1 = default; 2 = harmonic relationships doubly emphasized"
        case .sympatheticConsonance: return "Exponent applied to each non-unison interval's base weight. 0 = all intervals treated equally; 1 = default; higher values increasingly emphasize consonant intervals (fifth/fourth/octave) over dissonant ones"
        case .harmonicFalloff:       return "Exponent controlling how quickly the composite tone's harmonics decay: `amp_k = 1/k^falloff`. 0 = flat (all harmonics equal, buzzy); 1 = saw-like; 2 = quadratic decay (rounded); 4+ approaches pure sine (fundamental dominates)"
        case .noteAttack:            return "Base-voice attack time in milliseconds. Short (5 ms) = percussive/plucked feel; long (200 ms) = bowed/swelled feel that blends better with the sympathetic voices' amplitude ramp"
        case .reverbMix:             return "Wet/dry mix of the reverb bus (0–100%). Higher values place the instrument in a larger virtual room and help the base + sympathetic voices blend into a single acoustic space"
        case .sympatheticDetune:     return "Unison detune between sympathetic-voice pairs, in cents. Each enabled sympathetic note becomes two modal banks tuned at ±detune cents — they beat against each other to produce the natural shimmer of acoustic sympathetic strings. 0 = no beating; 5–10 cents = tasteful chorus"
        case .bowForce:              return "Continuous noise drive into the modal bank (0–0.3). Emulates bow friction. Scales with the excitation envelope so it fades with the note. 0 = pure pluck excitation only"
        case .stringDecay:           return "Played-string T60 in seconds (0.5–8) — time for a mode to fall 60 dB, ≈ audible tail length after release. Per-mode T60 follows T60_k = stringDecay / k^dampingTilt"
        case .symDecay:              return "Sympathetic-string T60 in seconds (2–20). Sym strings typically ring longer than played strings — this is the halo that lingers after you release a note"
        case .dampingTilt:           return "Frequency-dependent damping exponent α (0–2). 0 = all partials decay at the same rate (bell-like). 1 = high partials decay k× faster than fundamental (natural string behavior). 2 = notes start bright and darken sharply into the fundamental"
        case .inharmonicity:         return "Stiffness factor B (0–0.03) — stretches partials away from integer multiples: f_k = k·f₀·√(1+B·k²). 0 = pure harmonics. Small values = piano-like stretch. Larger values (0.01+) = sitar jawari clang"
        case .symCoupling:           return "How strongly played-string audio drives the sympathetic banks (0–1). Scales the kernel-derived coupling gain uniformly. 0 = sym strings silent. 1 = full harmonic bleed"
        case .pluckPosition:         return "Position along the string where the pluck excitation is injected (0–0.5, fraction of fundamental period). Classic string-pluck comb filter emphasizes different partials. 0 = center (fundamental strong); 0.2+ = brighter, sitar-like"
        case .partialCount:          return "Number of active partials per bank (1–8). 1 = a single resonance (bottle/Helmholtz). 3–5 = simple pitched tone. 8 = rich string stack"
        case .fundamentalBoost:      return "Multiplier on mode 1's amplitude before RMS normalization (1–6). 1 = flat RMS spectrum (bell-like). 3+ = strong fundamental dominance (string-like). Has no effect when partialCount = 1"
        case .breathLevel:           return "Amplitude of a pitch-tracking bandpass-filtered noise layer mixed alongside the modal bank (0–0.5). Independent of bowForce — this is the unpitched breath/wind component (flute, bottle, whispered bowing). Scales with excitation envelope"
        case .breathOffset:          return "Breath bandpass center, expressed as a semitone offset from the played pitch (−24 to +24). 0 = centered on the note; −12 = octave below; +12 = octave above. Lets the breath formant sit below/above the pitched resonance"
        case .breathSpread:          return "Breath bandpass bandwidth in semitones (0.3–24) — the log-frequency analog of standard deviation. Small = narrow peaked noise (whistle-like); large = broad pitched-noise wash centered on the pitch"
        }
    }

    var unit: String {
        switch self {
        case .glideSpeed:       return "ms/st"
        case .glideCompression: return "ms"
        case .amplitude:        return "x"
        case .vibratoDepth:     return "st"
        case .vibratoRate:      return "Hz"
        case .sympatheticWidth: return "st"
        case .noteAttack:       return "ms"
        case .reverbMix:        return "%"
        case .sympatheticDetune: return "ct"
        case .stringDecay:      return "s"
        case .symDecay:         return "s"
        case .breathOffset:     return "st"
        case .breathSpread:     return "st"
        default:                return ""
        }
    }

    var midiCC: UInt8? {
        switch self {
        case .midiCC74: return 74
        case .midiCC1:  return 1
        case .midiCC11: return 11
        case .midiCC71: return 71
        case .midiCC73: return 73
        case .midiCC75: return 75
        default:        return nil
        }
    }

    var isMIDI: Bool { midiCC != nil || self == .aftertouch }

    /// True if this parameter's value is always used even when no dimension is bound.
    /// MIDI parameters (CCs and aftertouch) are only sent when bound; all others always have an active value.
    var defaultAlwaysActive: Bool { !isMIDI }

    var defaultRange: (Double, Double) {
        switch self {
        case .velocity:         return (1, 127)
        case .glideSpeed:       return (20, 200)
        case .glideCompression: return (15, 40)
        case .amplitude:        return (0.3, 1.5)
        case .vibratoDepth:     return (0, 0.5)
        case .vibratoRate:      return (4, 10)
        case .vibratoIntensity: return (0, 1)
        case .dragSmoothing:    return (0.1, 0.5)
        case .glideCurve:       return (3, 12)
        case .sympatheticVolume: return (0, 1)
        // σ in semitones. Defaults to 0 (see midpointValue override) so fresh
        // installs start with sympathetic excitation effectively off; user
        // raises width when they want the halo.
        case .sympatheticWidth:  return (0, 5)
        // Scales non-unison kernel weights. 1.0 = previous hardcoded default.
        case .sympatheticSpread: return (0, 2)
        // Exponent on non-unison base weights. Wide range (0..10) so the user
        // can push consonant emphasis hard without clipping the parameter.
        case .sympatheticConsonance: return (0, 10)
        // Harmonic decay exponent for the composite tone. Midpoint (~2.5)
        // gives a lightly rounded timbre (between saw and sine).
        case .harmonicFalloff:       return (0, 5)
        // Excitation envelope attack in ms. Widened from the old 5–200 range
        // so long bow-onset presets are reachable. Midpoint ~250 ms gives a
        // slow bow ramp; short values reduce to pure pluck.
        case .noteAttack:            return (5, 500)
        // Reverb wet/dry mix (%). Midpoint 30% is a tasteful default that
        // adds body without washing out the direct signal.
        case .reverbMix:             return (0, 60)
        // Sympathetic unison detune in cents. Defaults to 0 so the detune
        // pair collapses to a single pitch unless the user deliberately
        // wants beating.
        case .sympatheticDetune:     return (0, 15)
        // Continuous noise drive into the modal bank. Replaces the old
        // bowNoise (0–0.15) with wider headroom. Midpoint ~0.15.
        case .bowForce:              return (0, 0.3)
        // Played-string mode decay (seconds). Midpoint ~4 s.
        case .stringDecay:           return (0.5, 8)
        // Sympathetic-string mode T60 (seconds). Defaults to 2 s (see
        // midpointValue override) — a modest halo rather than a long wash.
        case .symDecay:              return (0, 10)
        // Freq-dependent damping exponent. Midpoint 1.0 = natural string
        // (partial k decays k× faster than fundamental).
        case .dampingTilt:           return (0, 2)
        // Stiffness factor B. Wider than piano (~0.01) so sitar's jawari
        // curved-bridge clang is reachable at ~0.015–0.02.
        case .inharmonicity:         return (0, 0.03)
        // Played-audio → sym-bank coupling strength. Midpoint 0.5.
        case .symCoupling:           return (0, 1)
        // Pluck-position comb delay (fraction of fundamental period).
        // Midpoint 0.25 = classic bright pluck.
        case .pluckPosition:         return (0, 0.5)
        // Active partial count. 4.5 midpoint rounds to 4 internally.
        case .partialCount:          return (1, 8)
        // Mode-1 amplitude multiplier pre-RMS-normalize. 1 = flat spectrum.
        case .fundamentalBoost:      return (1, 6)
        // Bandpass-filtered noise amplitude. 0.25 midpoint.
        case .breathLevel:           return (0, 0.5)
        // Breath center offset in semitones from the played pitch. 0 midpoint.
        case .breathOffset:          return (-24, 24)
        // Breath bandwidth in semitones (log-freq spread). Midpoint ~12 st
        // ≈ one octave. Low values give narrow whistle-like peaks, high
        // values give broad pitched noise.
        case .breathSpread:          return (0.3, 24)
        default:                return (0, 127)
        }
    }

    /// Default value when no dimension is bound. Geometric midpoint of
    /// `defaultRange` for most params; a few (listed explicitly) need a
    /// non-midpoint neutral — e.g. sympathetic width/detune default to 0 so
    /// fresh installs have the sympathetic halo silent until the player asks
    /// for it.
    var midpointValue: Double {
        switch self {
        case .sympatheticWidth:  return 0
        case .sympatheticDetune: return 0
        case .symDecay:          return 2
        default:
            let r = defaultRange
            return (r.0 + r.1) / 2.0
        }
    }
}

// MARK: - Binding Model

/// A control point on a dimension-to-parameter transfer curve.
struct ControlPoint: Codable, Equatable {
    var x: Double  // 0..1 normalized input
    var y: Double  // output in parameter's native units
}

/// One dimension's contribution to a parameter, defined by a piecewise-linear transfer curve.
struct DimensionBinding: Codable, Equatable {
    var dimension: Dimension
    var controlPoints: [ControlPoint]  // sorted by x, 2-4 points

    /// Convenience initializer for a simple linear mapping.
    init(dimension: Dimension, rangeMin: Double, rangeMax: Double) {
        self.dimension = dimension
        self.controlPoints = [ControlPoint(x: 0, y: rangeMin), ControlPoint(x: 1, y: rangeMax)]
    }

    /// Backward-compatible access to the first endpoint.
    var rangeMin: Double { controlPoints.first?.y ?? 0 }
    /// Backward-compatible access to the last endpoint.
    var rangeMax: Double { controlPoints.last?.y ?? 0 }

    /// Evaluates the transfer curve at a normalized input value (0..1).
    /// Uses Catmull-Rom spline interpolation for smooth curves through control points.
    func evaluate(_ normalized: Double) -> Double {
        let n = max(0, min(1, normalized))
        let pts = controlPoints
        guard pts.count >= 2 else { return pts.first?.y ?? 0 }

        // Find the segment containing n
        var seg = 0
        for i in 1..<pts.count {
            if n <= pts[i].x { seg = i - 1; break }
            seg = i - 1
        }

        let p1 = pts[seg]
        let p2 = pts[seg + 1]
        let dx = p2.x - p1.x
        if dx <= 0 { return p1.y }
        let t = (n - p1.x) / dx

        // With only 2 points, use linear interpolation
        if pts.count == 2 { return p1.y + t * (p2.y - p1.y) }

        // Catmull-Rom: use neighboring points (clamp at boundaries)
        let y0 = seg > 0 ? pts[seg - 1].y : p1.y
        let y1 = p1.y
        let y2 = p2.y
        let y3 = seg + 2 < pts.count ? pts[seg + 2].y : p2.y

        let t2 = t * t
        let t3 = t2 * t
        let result = 0.5 * ((2 * y1) +
                             (-y0 + y2) * t +
                             (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2 +
                             (-y0 + 3 * y1 - 3 * y2 + y3) * t3)
        // Clamp to the range defined by the endpoints (first and last point Y)
        let lo = min(pts.first!.y, pts.last!.y)
        let hi = max(pts.first!.y, pts.last!.y)
        return max(lo, min(hi, result))
    }

    /// Backward-compatible migration from old format.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try container.decode(Dimension.self, forKey: .dimension)
        if let pts = try? container.decode([ControlPoint].self, forKey: .controlPoints) {
            controlPoints = pts
        } else {
            let rMin = try container.decode(Double.self, forKey: .rangeMin)
            let rMax = try container.decode(Double.self, forKey: .rangeMax)
            controlPoints = [ControlPoint(x: 0, y: rMin), ControlPoint(x: 1, y: rMax)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dimension, controlPoints, rangeMin, rangeMax
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimension, forKey: .dimension)
        try container.encode(controlPoints, forKey: .controlPoints)
    }

    mutating func sortPoints() {
        controlPoints.sort { $0.x < $1.x }
    }
}

/// All bindings for a single parameter (many:many support).
struct ParameterMapping: Codable, Equatable {
    var bindings: [DimensionBinding]
    /// Value used when no dimension is bound (or all are at midpoint).
    var defaultValue: Double

    var isEmpty: Bool { bindings.isEmpty }

    func hasBinding(for dim: Dimension) -> Bool {
        bindings.contains { $0.dimension == dim }
    }

    func binding(for dim: Dimension) -> DimensionBinding? {
        bindings.first { $0.dimension == dim }
    }

    mutating func toggleBinding(for dim: Dimension, defaultRange: (Double, Double)) {
        if let idx = bindings.firstIndex(where: { $0.dimension == dim }) {
            bindings.remove(at: idx)
        } else {
            bindings.append(DimensionBinding(dimension: dim, rangeMin: defaultRange.0, rangeMax: defaultRange.1))
        }
    }

    mutating func setBinding(for dim: Dimension, to binding: DimensionBinding) {
        if let idx = bindings.firstIndex(where: { $0.dimension == dim }) {
            bindings[idx] = binding
        }
    }
}

// MARK: - DimensionMapping

/// The complete set of parameter-to-dimension mappings. Persisted via UserDefaults.
struct DimensionMapping: Codable, Equatable {
    var mappings: [String: ParameterMapping]

    // MARK: - Defaults

    static func makeDefault() -> DimensionMapping {
        var m: [String: ParameterMapping] = [:]
        for param in MappableParameter.allCases {
            let range = param.defaultRange
            let dims: [Dimension]
            switch param {
            case .glideSpeed, .glideCompression, .amplitude, .aftertouch:
                dims = [.tilt1]
            case .velocity:
                dims = [.accelPressure]
            case .vibratoIntensity:
                dims = [.keyY]
            default:
                dims = []
            }
            let bindings = dims.map { DimensionBinding(dimension: $0, rangeMin: range.0, rangeMax: range.1) }
            m[param.storageKey] = ParameterMapping(bindings: bindings, defaultValue: param.midpointValue)
        }
        return DimensionMapping(mappings: m)
    }

    // MARK: - Persistence

    private static let storageKey = "starpad_dimensionMapping_v5"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func load() -> DimensionMapping {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           var mapping = try? JSONDecoder().decode(DimensionMapping.self, from: data) {
            let defaults = makeDefault()
            for param in MappableParameter.allCases {
                if var existing = mapping.mappings[param.storageKey] {
                    // Refresh defaultValue from code for any param the user has
                    // not bound — catches changes like resonance midpoint moving
                    // from the geometric midpoint to 0 (opt-in).
                    if existing.bindings.isEmpty {
                        existing.defaultValue = param.midpointValue
                        mapping.mappings[param.storageKey] = existing
                    }
                } else {
                    mapping.mappings[param.storageKey] = defaults.mapping(for: param)
                }
            }
            return mapping
        }
        return makeDefault()
    }

    // MARK: - Lookup

    func mapping(for param: MappableParameter) -> ParameterMapping {
        mappings[param.storageKey] ?? ParameterMapping(bindings: [], defaultValue: param.midpointValue)
    }

    func isConnected(_ param: MappableParameter, _ dim: Dimension) -> Bool {
        mapping(for: param).hasBinding(for: dim)
    }

    mutating func toggleBinding(for param: MappableParameter, dimension dim: Dimension) {
        var m = mapping(for: param)
        m.toggleBinding(for: dim, defaultRange: param.defaultRange)
        mappings[param.storageKey] = m
    }

    mutating func setBinding(for param: MappableParameter, dimension dim: Dimension, to binding: DimensionBinding) {
        var m = mapping(for: param)
        m.setBinding(for: dim, to: binding)
        mappings[param.storageKey] = m
    }

    /// All dimensions connected to a given parameter.
    func dimensions(for param: MappableParameter) -> [Dimension] {
        mapping(for: param).bindings.map(\.dimension)
    }

    /// All parameters connected to a given dimension.
    func parameters(for dim: Dimension) -> [MappableParameter] {
        MappableParameter.allCases.filter { isConnected($0, dim) }
    }
}

// MARK: - Sound Presets

/// A named sound-design preset — a set of per-parameter default values applied
/// to `DimensionMapping.mappings[...].defaultValue`. Presets only touch the
/// synth-timbre parameters (modal + sympathetic + reverb); glide, vibrato,
/// MIDI, and calibration-related params are left alone so the player keeps
/// their performance ergonomics.
enum SoundPreset: String, CaseIterable {
    case sarangi
    case sitar
    case dulcimer
    case bowed
    case random

    var label: String {
        switch self {
        case .sarangi:  return "Sarangi"
        case .sitar:    return "Sitar"
        case .dulcimer: return "Dulcimer"
        case .bowed:    return "Bowed Pad"
        case .random:   return "Random"
        }
    }

    /// Parameters presets are allowed to touch. Every non-random preset must
    /// supply a value for each (missing keys fall back to midpoint).
    static let affectedParams: [MappableParameter] = [
        .harmonicFalloff, .noteAttack, .bowForce, .pluckPosition,
        .stringDecay, .dampingTilt, .inharmonicity, .reverbMix,
        .sympatheticVolume, .symCoupling, .symDecay,
        .sympatheticWidth, .sympatheticSpread, .sympatheticConsonance,
        .sympatheticDetune,
        .partialCount, .fundamentalBoost,
        .breathLevel, .breathOffset, .breathSpread,
    ]

    /// Return the fixed defaults for a named preset. `.random` is handled
    /// separately (see `randomValues()`).
    func values() -> [MappableParameter: Double] {
        switch self {
        case .sarangi:
            return [
                .harmonicFalloff: 1.8, .noteAttack: 150, .bowForce: 0.18,
                .pluckPosition: 0, .stringDecay: 3.5, .dampingTilt: 0.9,
                .inharmonicity: 0.001, .reverbMix: 40,
                .sympatheticVolume: 0.6, .symCoupling: 0.7, .symDecay: 10,
                .sympatheticWidth: 2.5, .sympatheticSpread: 1.0,
                .sympatheticConsonance: 2.5, .sympatheticDetune: 7,
                .partialCount: 8, .fundamentalBoost: 2.5,
                .breathLevel: 0.08, .breathOffset: 0, .breathSpread: 5,
            ]
        case .sitar:
            return [
                .harmonicFalloff: 1.2, .noteAttack: 15, .bowForce: 0,
                .pluckPosition: 0.22, .stringDecay: 5, .dampingTilt: 0.4,
                .inharmonicity: 0.015, .reverbMix: 30,
                .sympatheticVolume: 0.8, .symCoupling: 0.9, .symDecay: 14,
                .sympatheticWidth: 1.2, .sympatheticSpread: 1.2,
                .sympatheticConsonance: 4.0, .sympatheticDetune: 4,
                .partialCount: 8, .fundamentalBoost: 2.0,
                .breathLevel: 0, .breathOffset: 0, .breathSpread: 12,
            ]
        case .dulcimer:
            return [
                .harmonicFalloff: 2.2, .noteAttack: 8, .bowForce: 0,
                .pluckPosition: 0.15, .stringDecay: 2, .dampingTilt: 1.2,
                .inharmonicity: 0.003, .reverbMix: 25,
                .sympatheticVolume: 0.3, .symCoupling: 0.4, .symDecay: 5,
                .sympatheticWidth: 1.8, .sympatheticSpread: 1.0,
                .sympatheticConsonance: 2.0, .sympatheticDetune: 10,
                .partialCount: 6, .fundamentalBoost: 3.0,
                .breathLevel: 0, .breathOffset: 0, .breathSpread: 12,
            ]
        case .bowed:
            return [
                .harmonicFalloff: 2.8, .noteAttack: 350, .bowForce: 0.25,
                .pluckPosition: 0, .stringDecay: 6, .dampingTilt: 0.3,
                .inharmonicity: 0, .reverbMix: 55,
                .sympatheticVolume: 0.7, .symCoupling: 0.6, .symDecay: 18,
                .sympatheticWidth: 3.5, .sympatheticSpread: 1.5,
                .sympatheticConsonance: 0.5, .sympatheticDetune: 5,
                .partialCount: 8, .fundamentalBoost: 2.0,
                .breathLevel: 0.12, .breathOffset: -7, .breathSpread: 8,
            ]
        case .random:
            return randomValues()
        }
    }

    /// Draw a value uniformly from each affected parameter's default range.
    /// `sympatheticDetune` gets a bias toward the low half so most randoms
    /// don't collapse into heavy beating.
    static func randomValues() -> [MappableParameter: Double] {
        var v: [MappableParameter: Double] = [:]
        for p in affectedParams {
            let r = p.defaultRange
            var x = Double.random(in: r.0...r.1)
            if p == .sympatheticDetune { x = Double.random(in: r.0...(r.1 * 0.6)) }
            v[p] = x
        }
        return v
    }

    private func randomValues() -> [MappableParameter: Double] {
        Self.randomValues()
    }
}

/// Corner presets for the three-way blend triangle in the main UI. Each
/// vertex is a pure archetype; tap positions inside the triangle produce a
/// barycentric blend of these three dicts.
enum SoundBlendVertex: String, CaseIterable {
    case pluck
    case bow
    case noise

    var label: String {
        switch self {
        case .pluck: return "PLUCK"
        case .bow:   return "BOW"
        case .noise: return "NOISE"
        }
    }

    func values() -> [MappableParameter: Double] {
        switch self {
        case .pluck:
            // String-like pluck: rich partials, strong fundamental dominance,
            // quick damping of upper partials, no breath layer.
            return [
                .harmonicFalloff: 1.8, .noteAttack: 8, .bowForce: 0,
                .pluckPosition: 0.18, .stringDecay: 2.5, .dampingTilt: 1.2,
                .inharmonicity: 0.005, .reverbMix: 25,
                .sympatheticVolume: 0.5, .symCoupling: 0.6, .symDecay: 5,
                .sympatheticWidth: 1.5, .sympatheticSpread: 1.0,
                .sympatheticConsonance: 2.0, .sympatheticDetune: 6,
                .partialCount: 8, .fundamentalBoost: 3.0,
                .breathLevel: 0, .breathOffset: 0, .breathSpread: 12,
            ]
        case .bow:
            // Sustained, warm, harmonically-tight. Slight bow friction breath.
            return [
                .harmonicFalloff: 2.2, .noteAttack: 180, .bowForce: 0.2,
                .pluckPosition: 0, .stringDecay: 4.5, .dampingTilt: 0.7,
                .inharmonicity: 0.001, .reverbMix: 45,
                .sympatheticVolume: 0.65, .symCoupling: 0.7, .symDecay: 10,
                .sympatheticWidth: 2.5, .sympatheticSpread: 1.2,
                .sympatheticConsonance: 2.0, .sympatheticDetune: 7,
                .partialCount: 6, .fundamentalBoost: 2.0,
                .breathLevel: 0.06, .breathOffset: 0, .breathSpread: 6,
            ]
        case .noise:
            // Bottle-blow: single wide-bandwidth resonance, strong breath,
            // short mode decay. Modal bank contributes only a subtle pitched
            // glow; the breath bandpass is the dominant source.
            return [
                .harmonicFalloff: 1.0, .noteAttack: 40, .bowForce: 0.25,
                .pluckPosition: 0, .stringDecay: 0.4, .dampingTilt: 0.3,
                .inharmonicity: 0, .reverbMix: 35,
                .sympatheticVolume: 0.2, .symCoupling: 0.3, .symDecay: 2,
                .sympatheticWidth: 3.5, .sympatheticSpread: 0.5,
                .sympatheticConsonance: 0.3, .sympatheticDetune: 8,
                .partialCount: 1, .fundamentalBoost: 1.0,
                .breathLevel: 0.35, .breathOffset: 0, .breathSpread: 18,
            ]
        }
    }
}
