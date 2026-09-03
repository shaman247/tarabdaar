import Foundation

/// Scale-derived helpers shared across the app: the enabled degrees of a
/// `PitchScale`, the ONE pitch-naming path (the scale's own labels), and the
/// scale presets the Fret Pad's scale editor offers.
///
/// 2026-07-24: extracted from `StringPadGeometry.swift` and
/// `ChordPadGeometry.swift` when those were deleted. Both files were
/// geometry for the String Pad and Chord Pad — surfaces removed in the
/// 2026-07-23 simplification — but each still held symbols the surviving
/// Fret Pad depends on, which is why they had lingered.

// MARK: - Scale-derived pitch names
//
// **Pitches are named by the scale, everywhere.** A scale point carries its
// own label (`PitchPoint.displayLabel` — the user's text, or the ratio when
// blank), and every surface that names a pitch — the Fret Pad's fret labels,
// the drone buttons, the Strings tab's degree dropdowns — reads that same
// label through the helpers below. There is no second naming vocabulary:
// the fixed 12-tone sargam table that used to name frets and drones was
// removed 2026-07-25 because it disagreed with the scale editor's own labels
// (the default scale's "2-" showed up as "r" on the pad).

/// The Pitch Pad scale's enabled degrees, sorted low→high, as `(ratio, label)`.
public func scaleDegrees(from scale: PitchScale) -> [(ratio: Double, label: String)] {
    scale.points
        .filter(\.enabled)
        .sorted { $0.ratio < $1.ratio }
        .map { (ratio: $0.ratio, label: $0.displayLabel) }
}

/// A degree label transposed by `octave`: `'` per octave above the scale's
/// base octave, `,` per octave below (the notation the pad has always used
/// for its octave-repeat frets and its low drones).
public func octaveMarked(_ label: String, octave: Int) -> String {
    if octave > 0 { return label + String(repeating: "'", count: octave) }
    if octave < 0 { return label + String(repeating: ",", count: -octave) }
    return label
}

/// The scale's label for degree `index` (into `degrees`, low→high) shifted by
/// `octave`. `"—"` when the index is out of range (the scale shrank under a
/// stale reference — the same skip-don't-delete rule as `fretRatio`).
public func scaleLabel(degree index: Int, octave: Int = 0,
                       degrees: [(ratio: Double, label: String)]) -> String {
    guard degrees.indices.contains(index) else { return "—" }
    return octaveMarked(degrees[index].label, octave: octave)
}

/// The scale's label for an arbitrary `ratio` over the tonic: the degree
/// nearest it in log-pitch, in any octave, with that octave's marks. Used
/// where only a ratio survives (the drone buttons, whose pitches are derived
/// from the mapped tarab strings); prefer the degree-index form above
/// wherever the degree is known, since it can't mis-match.
public func scaleLabel(forRatio ratio: Double,
                       degrees: [(ratio: Double, label: String)]) -> String {
    guard ratio > 0 else { return "—" }
    let l = log2(ratio)
    var best: (label: String, distance: Double)? = nil
    for degree in degrees where degree.ratio > 0 {
        // The octave transposition of this degree that lands closest to
        // `ratio` — so a ratio a hair under the octave names itself from the
        // tonic above rather than from the scale's topmost degree.
        let dl = log2(degree.ratio)
        let octave = (l - dl).rounded()
        let distance = abs(l - dl - octave)
        if best == nil || distance < best!.distance {
            best = (octaveMarked(degree.label, octave: Int(octave)), distance)
        }
    }
    return best?.label ?? "—"
}


/// How a column's chord tones are tuned. 12-TET for now; `justIntonation`
/// (per-column perfect intervals stacked from the column root) is reserved as
/// the structural seam and not yet implemented.
public enum Temperament {
    case equalTemperament
    // case justIntonation  // future: per-column perfect intervals
}

/// Common selectable scales — the modes plus major/minor variants and
/// pentatonics, and (2026-09-02) the **12-TET chromatic** scale. These are
/// **shared**: a preset loads into the one Pitch Pad `PitchScale`
/// (`PitchPadEngine.loadPreset`), so both the Pitch Pad and the Chord Pad
/// use it. Each preset is defined by its semitone intervals from the tonic
/// and rendered as a just-intonation `PitchScale` (the same 12-tone JI ratio
/// table as `PitchScale.defaultJI`), matching the Pitch Pad's JI design
/// surface; the Chord Pad reads the degrees back as the nearest 12-TET
/// semitones.
///
/// The one exception is `.equalTempered`: the full chromatic scale in equal
/// temperament, for playing alongside instruments tuned to 12-TET. The scale
/// model carries every pitch as a `num/den` rational (JSON on disk, 14-bit
/// integers in the scale-sync blob — `PitchScaleSysEx`), and a tempered
/// semitone is irrational, so each degree ships as the best rational
/// approximation of `2^(k/12)` with both terms under the blob's 16383 bound
/// (`equalTemperedRatios`). The residual is below 0.0001 ¢ — three orders of
/// magnitude under the tonic's own 0.01 ¢ wire resolution and far below
/// anything the string physics or an ear could separate — so the preset IS
/// equal temperament for every purpose in the app, while the wire, the
/// persisted scale and the tarab's degree references stay untouched. It
/// keeps the default scale's sargam labels and keyboard layout, since it is
/// the default's twelve pitches, tempered.
public enum ScalePreset: String, CaseIterable, Identifiable {
    case equalTempered
    case major
    case minor
    case dorian
    case phrygian
    case lydian
    case mixolydian
    case locrian
    case harmonicMinor
    case melodicMinor
    case majorPentatonic
    case minorPentatonic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .equalTempered:   return "12-TET Chromatic"
        case .major:           return "Major"
        case .minor:           return "Minor"
        case .dorian:          return "Dorian"
        case .phrygian:        return "Phrygian"
        case .lydian:          return "Lydian"
        case .mixolydian:      return "Mixolydian"
        case .locrian:         return "Locrian"
        case .harmonicMinor:   return "Harmonic Minor"
        case .melodicMinor:    return "Melodic Minor"
        case .majorPentatonic: return "Major Pentatonic"
        case .minorPentatonic: return "Minor Pentatonic"
        }
    }

    /// Semitone degrees from the tonic (ascending).
    public var intervals: [Int] {
        switch self {
        case .equalTempered:   return Array(0..<12)
        case .major:           return [0, 2, 4, 5, 7, 9, 11]
        case .minor:           return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:          return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:        return [0, 1, 3, 5, 7, 8, 10]
        case .lydian:          return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian:      return [0, 2, 4, 5, 7, 9, 10]
        case .locrian:         return [0, 1, 3, 5, 6, 8, 10]
        case .harmonicMinor:   return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor:    return [0, 2, 3, 5, 7, 9, 11]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        }
    }

    /// The twelve equal-tempered semitones `2^(k/12)`, k = 0…11, as the
    /// best `num/den` approximations with both terms ≤ 16383 (the
    /// scale-sync blob's 14-bit field). Every entry is within 0.0001 ¢ of
    /// the true tempered ratio — `ScalePresetTests` pins both the bound and
    /// the accuracy, so a retyped digit fails loudly.
    public static let equalTemperedRatios: [(num: Int, den: Int)] = [
        (1, 1),          // 0     unison
        (11011, 10393),  // 1     2^(1/12)
        (12273, 10934),  // 2     2^(2/12)
        (10754, 9043),   // 3     2^(3/12)
        (6064, 4813),    // 4     2^(4/12)
        (6793, 5089),    // 5     2^(5/12)
        (11482, 8119),   // 6     2^(6/12)
        (10178, 6793),   // 7     2^(7/12)
        (4813, 3032),    // 8     2^(8/12)
        (9043, 5377),    // 9     2^(9/12)
        (4679, 2626),    // 10    2^(10/12)
        (14900, 7893),   // 11    2^(11/12)
    ]

    /// The preset as a `PitchScale` — each interval mapped to its 12-tone JI
    /// ratio. Degrees alternate between two layout rows and are labeled by
    /// scale-degree number so the Pitch Pad shows a clean keyboard-like row.
    /// `.equalTempered` instead maps each semitone to its tempered ratio and
    /// takes the default scale's sargam labels + white/black keyboard rows.
    public var pitchScale: PitchScale {
        if self == .equalTempered {
            let labels = ["S", "r", "R", "g", "G", "m", "M", "P", "d", "D", "n", "N"]
            let black: Set<Int> = [1, 3, 6, 8, 10]
            let points = Self.equalTemperedRatios.enumerated().map { (k, r) -> PitchPoint in
                PitchPoint(num: r.num, den: r.den,
                           y: black.contains(k) ? 2.0 / 6.0 : 5.0 / 6.0,
                           label: labels[k])
            }
            return PitchScale(points: points)
        }
        // 12-tone JI ratio per semitone (matches `PitchScale.defaultJI`).
        let table: [(Int, Int)] = [
            (1, 1), (16, 15), (9, 8), (6, 5), (5, 4), (4, 3),
            (45, 32), (3, 2), (8, 5), (5, 3), (16, 9), (15, 8),
        ]
        let points = intervals.enumerated().map { (i, semi) -> PitchPoint in
            let (n, d) = table[((semi % 12) + 12) % 12]
            let y = (i % 2 == 0) ? 5.0 / 6.0 : 2.0 / 6.0
            return PitchPoint(num: n, den: d, y: y, label: "\(i + 1)")
        }
        return PitchScale(points: points)
    }
}
