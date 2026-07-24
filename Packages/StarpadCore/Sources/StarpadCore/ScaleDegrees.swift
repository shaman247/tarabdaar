import Foundation

/// Scale-derived helpers shared across the app: the enabled degrees of a
/// `PitchScale`, sargam naming, and the scale presets the Fret Pad's scale
/// editor offers.
///
/// 2026-07-24: extracted from `StringPadGeometry.swift` and
/// `ChordPadGeometry.swift` when those were deleted. Both files were
/// geometry for the String Pad and Chord Pad — surfaces removed in the
/// 2026-07-23 simplification — but each still held symbols the surviving
/// Fret Pad depends on, which is why they had lingered.

// MARK: - Scale-derived pitch + sargam names

/// The Pitch Pad scale's enabled degrees, sorted low→high, as `(ratio, label)`.
public func scaleDegrees(from scale: PitchScale) -> [(ratio: Double, label: String)] {
    scale.points
        .filter(\.enabled)
        .sorted { $0.ratio < $1.ratio }
        .map { (ratio: $0.ratio, label: $0.displayLabel) }
}

/// Sargam names for the 12 chromatic pitch classes.
public let sargamNames = ["S", "r", "R", "g", "G", "m", "M", "P", "d", "D", "n", "N"]
/// Sargam name for a semitone offset above the tonic, with `'`/`,` marks for
/// octaves above/below the base octave.
public func sargamName(semitonesAboveTonic semis: Int) -> String {
    let pc = ((semis % 12) + 12) % 12
    let oct = Int(floor(Double(semis) / 12.0))
    var name = sargamNames[pc]
    if oct > 0 { name += String(repeating: "'", count: oct) }
    else if oct < 0 { name += String(repeating: ",", count: -oct) }
    return name
}

/// Sargam name for a ratio (its nearest chromatic semitone).
public func sargamName(forRatio r: Double) -> String {
    sargamName(semitonesAboveTonic: Int((12.0 * log2(r)).rounded()))
}


/// How a column's chord tones are tuned. 12-TET for now; `justIntonation`
/// (per-column perfect intervals stacked from the column root) is reserved as
/// the structural seam and not yet implemented.
public enum Temperament {
    case equalTemperament
    // case justIntonation  // future: per-column perfect intervals
}

/// Common selectable scales — the modes plus major/minor variants and
/// pentatonics. These are **shared**: a preset loads into the one Pitch Pad
/// `PitchScale` (`PitchPadEngine.loadPreset`), so both the Pitch Pad and the
/// Chord Pad use it. Each preset is defined by its semitone intervals from
/// the tonic and rendered as a just-intonation `PitchScale` (the same 12-tone
/// JI ratio table as `PitchScale.defaultJI`), matching the Pitch Pad's JI
/// design surface; the Chord Pad reads the degrees back as the nearest 12-TET
/// semitones.
public enum ScalePreset: String, CaseIterable, Identifiable {
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

    /// The preset as a `PitchScale` — each interval mapped to its 12-tone JI
    /// ratio. Degrees alternate between two layout rows and are labeled by
    /// scale-degree number so the Pitch Pad shows a clean keyboard-like row.
    public var pitchScale: PitchScale {
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
