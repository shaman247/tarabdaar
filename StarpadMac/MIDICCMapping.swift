import Foundation

/// Enumerates every Mac-side parameter that an incoming MIDI CC can
/// drive. Each case carries its display label and value range — so
/// `VoiceParamsView` and `AppController.applyCC` can both work off a
/// single source of truth. Stored as a string raw value so per-preset
/// CC tables persist cleanly to UserDefaults.
///
/// The played voice is the ported sarangi model + a hosted AU (SWAM Violin).
/// The model's 27 params are edited in the Sarangi tab; the CC mapping here
/// covers the Starpad-owned master post-FX bus (reverb + master filter). Add
/// cases here if the user wants CC-control of more controls later.
enum MappableMacParam: String, CaseIterable, Codable, Identifiable, Hashable {
    // Master FX
    case reverbMix
    case filterCutoff
    case filterResonance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reverbMix:            return "Reverb mix"
        case .filterCutoff:         return "Filter cutoff"
        case .filterResonance:      return "Filter resonance"
        }
    }

    /// CC values (0–127) are remapped linearly into this range.
    var range: ClosedRange<Double> {
        switch self {
        case .reverbMix:            return 0...100
        case .filterCutoff:         return 60...20000
        case .filterResonance:      return 0...0.99
        }
    }
}
