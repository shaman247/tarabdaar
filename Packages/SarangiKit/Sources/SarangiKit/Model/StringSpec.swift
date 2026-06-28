import Foundation

/// Which sympathetic-string choir a string belongs to (drives the grouped
/// editor + scale-sync). Mirrors the four choirs `RagaTuning.buildStrings`
/// constructs: a fixed chromatic taraf row, the scale-tuned (diatonic) mid
/// choir, and the low / upper octave repeats.
public enum StringGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case chromatic                    // A — 15 fixed JI-chromatic taraf
    case scale                        // B — diatonic / scale-tuned mid + Sa/Pa
    case lowOctave                    // C — low octave repeats
    case upperOctave                  // D — upper octave repeats

    public var label: String {
        switch self {
        case .chromatic:   return "Chromatic"
        case .scale:       return "Scale-tuned"
        case .lowOctave:   return "Low octave"
        case .upperOctave: return "Upper octave"
        }
    }
    public var detail: String {
        switch self {
        case .chromatic:   return "15 fixed JI-chromatic strings — always present, independent of the scale."
        case .scale:       return "The scale degrees (+ Sa/Pa doublings) — follows the current scale."
        case .lowOctave:   return "Low-octave repeats of the tonic / Pa / vadi."
        case .upperOctave: return "Upper-octave repeats of the first scale degrees."
        }
    }
}

/// An editable / persisted sympathetic string (UI row). Carries a stable id for
/// SwiftUI lists; `resolved` is the DSP-facing value the bank consumes.
public struct StringSpec: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var freq: Double
    public var gain: Double
    public var t60: Double
    public var bright: Bool
    public var enabled: Bool
    public var group: StringGroup

    public init(id: UUID = UUID(), freq: Double, gain: Double, t60: Double,
                bright: Bool, enabled: Bool = true, group: StringGroup = .scale) {
        self.id = id; self.freq = freq; self.gain = gain; self.t60 = t60
        self.bright = bright; self.enabled = enabled; self.group = group
    }

    public init(_ r: ResolvedString, group: StringGroup = .scale) {
        self.init(freq: r.freq, gain: r.gain, t60: r.t60, bright: r.bright,
                  enabled: r.enabled, group: group)
    }

    // Tolerant decode: `group` (and `enabled`) default when absent, so older
    // `.sarangi` documents still load.
    private enum CodingKeys: String, CodingKey { case id, freq, gain, t60, bright, enabled, group }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        freq = try c.decode(Double.self, forKey: .freq)
        gain = try c.decode(Double.self, forKey: .gain)
        t60 = try c.decode(Double.self, forKey: .t60)
        bright = try c.decode(Bool.self, forKey: .bright)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        group = (try? c.decode(StringGroup.self, forKey: .group)) ?? .scale
    }

    public var resolved: ResolvedString {
        ResolvedString(freq: freq, gain: gain, t60: t60, bright: bright, enabled: enabled)
    }

    public var noteName: String {
        let midi = Int((69.0 + 12.0 * log2(freq / 440.0)).rounded())
        return NoteName.name(forMIDI: midi)
    }

    /// Generate the editable, grouped bank for a raga + tonic (manual fallback).
    public static func bank(tonic: Double, intervals: [Int], detune: Bool = true) -> [StringSpec] {
        RagaTuning.buildGroupedSpecs(tonic: tonic, intervals: intervals, detune: detune)
    }

    /// Generate the editable, grouped bank from arbitrary scale-degree ratios
    /// (the Pitch Pad scale). `ratios` are degrees from the tonic in [1, 2).
    public static func bank(tonic: Double, ratios: [Double], detune: Bool = true) -> [StringSpec] {
        RagaTuning.buildGroupedSpecs(tonic: tonic, ratios: ratios, detune: detune)
    }
}
