import Foundation

/// Concert note names for ABSOLUTE Hz readouts (the tuning readouts, the
/// tonic picker). Scale degrees are named by the scale's own labels
/// (`ScaleDegrees.swift`); this is the other axis.
public enum Scale {
    /// The 12 chromatic pitch-class names, C first.
    public static let pitchClassNames =
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// "D4"-style name of a MIDI note number (C4 = 60).
    public static func noteName(for midiNote: Int) -> String {
        let pc = ((midiNote % 12) + 12) % 12
        let octave = (midiNote / 12) - 1
        return "\(pitchClassNames[pc])\(octave)"
    }
}
