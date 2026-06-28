import Foundation

/// Tuning system used for pitch calculation.
public enum TuningSystem: String, Codable, CaseIterable {
    case equalTemperament = "Equal Temperament"
    case justIntonation = "Just Intonation"
}

/// Encapsulates the active scale (which notes are enabled) and tuning system.
///
/// The keyboard always shows the standard 12-tone piano layout. Disabled notes
/// are grayed out and ignored by hit testing, snapping, and glide waypoints.
/// The tuning system determines how MIDI note numbers map to frequencies.
public struct Scale: Codable, Equatable {

    public var tuning: TuningSystem = .equalTemperament
    public var baseNote: Int = 62              // MIDI note for the JI root (D4)
    public var enabledDegrees: Set<Int> = Set(0...11)  // pitch classes 0-11 (when !specificNoteMode)
    public var startNote: Int = 55             // lowest MIDI note on keyboard (G3)
    public var endNote: Int = 79               // highest MIDI note on keyboard (G5)

    /// When true, `enabledSpecificNotes` (specific MIDI notes) drives
    /// `isEnabled` instead of the pitch-class-based `enabledDegrees`. Used
    /// for the sympathetic-string scale where each "string" is a single
    /// MIDI note, not a pitch class repeated across octaves.
    public var specificNoteMode: Bool = false
    /// Specific MIDI notes that are enabled, used only when `specificNoteMode`.
    public var enabledSpecificNotes: Set<Int> = []

    /// Total number of semitones on the keyboard (inclusive)
    public var noteCount: Int { max(1, endNote - startNote + 1) }

    /// Ensure the JI root is always enabled. In specific-note mode, the
    /// root note itself is pinned on; in pitch-class mode, the whole class.
    public mutating func enforceRootEnabled() {
        guard tuning == .justIntonation else { return }
        if specificNoteMode {
            enabledSpecificNotes.insert(baseNote)
        } else {
            let rootPC = ((baseNote % 12) + 12) % 12
            enabledDegrees.insert(rootPC)
        }
    }

    // MARK: - Just Intonation Ratios

    /// Frequency ratios for just intonation, indexed by pitch class (0-11).
    /// These define the interval from the root for each degree of the chromatic scale.
    public static let justRatios: [Double] = [
        1.0,        // unison
        16.0/15.0,  // minor second
        9.0/8.0,    // major second
        6.0/5.0,    // minor third
        5.0/4.0,    // major third
        4.0/3.0,    // perfect fourth
        45.0/32.0,  // augmented fourth / tritone
        3.0/2.0,    // perfect fifth
        8.0/5.0,    // minor sixth
        5.0/3.0,    // major sixth
        16.0/9.0,   // minor seventh
        15.0/8.0    // major seventh
    ]

    // MARK: - Frequency Calculation

    /// Convert a MIDI note number to frequency using the current tuning system.
    public func frequency(for midiNote: Int) -> Double {
        switch tuning {
        case .equalTemperament:
            return 440.0 * pow(2.0, Double(midiNote - 69) / 12.0)

        case .justIntonation:
            return justFrequency(for: Double(midiNote))
        }
    }

    /// Convert a fractional MIDI note number to frequency (for drag glides).
    public func frequency(for midiNote: Double) -> Double {
        switch tuning {
        case .equalTemperament:
            return 440.0 * pow(2.0, (midiNote - 69.0) / 12.0)

        case .justIntonation:
            return justFrequency(for: midiNote)
        }
    }

    /// Just intonation frequency for a (possibly fractional) MIDI note.
    /// Interpolates between adjacent JI ratios for fractional values.
    private func justFrequency(for midiNote: Double) -> Double {
        // Base frequency of the root note (in 12-TET, as the reference)
        let baseFreq = 440.0 * pow(2.0, Double(baseNote - 69) / 12.0)

        let offset = midiNote - Double(baseNote)
        let octave = floor(offset / 12.0)
        let degree = offset - octave * 12.0  // 0.0 to <12.0

        let lowerDegree = Int(floor(degree))
        let frac = degree - Double(lowerDegree)

        let lowerIndex = ((lowerDegree % 12) + 12) % 12
        let upperIndex = ((lowerDegree + 1) % 12 + 12) % 12

        let lowerRatio = Self.justRatios[lowerIndex]
        var upperRatio = Self.justRatios[upperIndex]

        // If upper wraps around the octave, multiply by 2
        if upperIndex <= lowerIndex {
            upperRatio *= 2.0
        }

        // Interpolate in log space for smooth pitch
        let logLower = log2(lowerRatio)
        let logUpper = log2(upperRatio)
        let logRatio = logLower + frac * (logUpper - logLower)

        return baseFreq * pow(2.0, octave + logRatio)
    }

    // MARK: - Scale Queries

    /// Whether a MIDI note is enabled in the current scale.
    public func isEnabled(_ midiNote: Int) -> Bool {
        if specificNoteMode {
            return enabledSpecificNotes.contains(midiNote)
        }
        let pc = ((midiNote % 12) + 12) % 12
        return enabledDegrees.contains(pc)
    }

    /// Standard piano black key pattern (visual layout, not scale-dependent).
    public static func isBlackKey(_ midiNote: Int) -> Bool {
        let pc = ((midiNote % 12) + 12) % 12
        return [1, 3, 6, 8, 10].contains(pc)
    }

    /// Note name for display (always uses standard 12-tone naming).
    public static func noteName(for midiNote: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pc = ((midiNote % 12) + 12) % 12
        let octave = (midiNote / 12) - 1
        return "\(names[pc])\(octave)"
    }

    /// All enabled MIDI notes in the keyboard range.
    public func enabledNotesInRange() -> [Int] {
        (0..<noteCount).compactMap { i in
            let midi = startNote + i
            return isEnabled(midi) ? midi : nil
        }
    }

    /// White keys in the keyboard range (for layout, regardless of enabled state).
    public func whiteNotesInRange() -> [Int] {
        (0..<noteCount).compactMap { i in
            let midi = startNote + i
            return Self.isBlackKey(midi) ? nil : midi
        }
    }

    /// Nearest enabled note to a fractional semitone value.
    /// If `whiteOnly`, restricts to non-black-key enabled notes.
    public func nearestEnabledNote(to semitone: Double, whiteOnly: Bool = false) -> Int {
        let rounded = Int(round(semitone))
        for offset in 0...12 {
            for candidate in [rounded + offset, rounded - offset] {
                if isEnabled(candidate) {
                    if whiteOnly && Self.isBlackKey(candidate) { continue }
                    return candidate
                }
            }
        }
        return rounded  // fallback
    }

    // MARK: - Persistence

    private static let playingStorageKey = "starpad_scale"
    private static let sympatheticStorageKey = "starpad_sympathetic_scale"

    public func save() {
        save(key: Self.playingStorageKey)
    }

    public func saveSympathetic() {
        save(key: Self.sympatheticStorageKey)
    }

    private func save(key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func load() -> Scale {
        guard let data = UserDefaults.standard.data(forKey: playingStorageKey),
              let scale = try? JSONDecoder().decode(Scale.self, from: data)
        else { return Scale() }
        return scale
    }

    /// Load the sympathetic-string scale. On first run (no saved data) this
    /// seeds from the playing scale but switches to specific-note mode so
    /// the user gets per-MIDI-note control from the start.
    public static func loadSympathetic() -> Scale {
        if let data = UserDefaults.standard.data(forKey: sympatheticStorageKey),
           let scale = try? JSONDecoder().decode(Scale.self, from: data) {
            return scale
        }
        var s = load()
        // Capture the pitch-class-derived notes BEFORE flipping the mode,
        // otherwise enabledNotesInRange() would use the empty specific set.
        let inherited = Set(s.enabledNotesInRange())
        s.specificNoteMode = true
        s.enabledSpecificNotes = inherited
        return s
    }

    /// Reset to defaults
    public static var `default`: Scale { Scale() }
}
