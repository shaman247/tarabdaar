import Foundation
import SarangiKit

/// The concert-note helper the TarabdaarCore surfaces reach for; the ONE
/// name table is `SarangiKit.NoteName`. Concert names label absolute Hz
/// only — scale degrees are named by the scale's own labels
/// (`ScaleDegrees.swift`).
public enum Scale {
    public static func noteName(for midiNote: Int) -> String {
        NoteName.name(forMIDI: midiNote)
    }
}
