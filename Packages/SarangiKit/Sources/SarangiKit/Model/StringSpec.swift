import Foundation

/// Which bridge a sympathetic string sits on. As on the instrument: the
/// CHROMATIC set (~15 strings through the main bridge, tuned by semitone) and
/// the RAGA set (side bridges, tuned to the raga). Each bridge has its own
/// jawari: raga rows ride the `bow_jt_*` contact law, chromatic rows the
/// `bow_jtc_*` one. Persisted as a string; absent decodes as `.raga`.
public enum TarabSet: String, Codable, Sendable, Hashable, CaseIterable {
    case raga, chromatic
}

/// An editable / persisted sympathetic string (UI row). Stable id for
/// SwiftUI lists; `resolved(tonic:scaleRatios:)` is the DSP-facing value.
///
/// The pitch is a **scale degree + octave**: a raga string's `degree`
/// indexes `InstrumentState.scaleRatios` (the one centralized scale), so it
/// can only sound a pitch of the scale and retunes with the scale or tonic.
/// A chromatic string's `degree` is a semitone (0…11) into the fixed JI grid
/// (`RagaTuning.chromaticRatio`): a tonic move retunes it, a scale edit does
/// not. No ratio or Hz exists in the document — Hz is minted at resolve time.
public struct StringSpec: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// Index into the document's `scaleRatios` (0 = Sa). Clamped at resolve
    /// time, so a row survives the scale shrinking underneath it.
    public var degree: Int
    /// Whole-octave shift (the UI offers −2…+2; generation uses −1/0/+1).
    public var octave: Int
    /// Per-string loudness — the one level knob.
    public var gain: Double
    public var t60: Double
    public var enabled: Bool
    /// The bridge this string sits on — see `TarabSet`.
    public var set: TarabSet

    public init(id: UUID = UUID(), degree: Int, octave: Int = 0,
                gain: Double, t60: Double, enabled: Bool = true,
                set: TarabSet = .raga) {
        self.id = id; self.degree = degree; self.octave = octave
        self.gain = gain; self.t60 = t60; self.enabled = enabled
        self.set = set
    }

    // Tolerant decode: `octave`, `enabled` and `set` default when absent;
    // retired keys (`ratio`/`freq`/`group`/`weight`/`bright`/`raga`) decode
    // away ignored; `degree` is required.
    private enum CodingKeys: String, CodingKey { case id, degree, octave, gain, t60, enabled, set }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        degree = try c.decode(Int.self, forKey: .degree)
        octave = (try? c.decode(Int.self, forKey: .octave)) ?? 0
        gain = try c.decode(Double.self, forKey: .gain)
        t60 = try c.decode(Double.self, forKey: .t60)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        set = (try? c.decode(TarabSet.self, forKey: .set)) ?? .raga
    }

    /// Frequency ratio vs the tonic under a scale. A raga degree clamps into
    /// the scale (a row survives the scale shrinking by sounding the top
    /// degree); a chromatic degree reads the fixed JI grid (mod 12) and
    /// ignores the scale.
    public func ratio(in scaleRatios: [Double]) -> Double {
        if set == .chromatic {
            return RagaTuning.chromaticRatio(semitone: degree)
                * pow(2.0, Double(octave))
        }
        guard !scaleRatios.isEmpty else { return pow(2.0, Double(octave)) }
        let d = min(max(degree, 0), scaleRatios.count - 1)
        return scaleRatios[d] * pow(2.0, Double(octave))
    }

    /// Absolute Hz is minted here: ratio × tonic, quantized to millihertz —
    /// the drone press path finds its jt row by exact nominal Hz, so this
    /// must be deterministic to the bit.
    public func resolved(tonic: Double, scaleRatios: [Double]) -> ResolvedString {
        ResolvedString(freq: (ratio(in: scaleRatios) * tonic * 1000).rounded() / 1000,
                       gain: gain, t60: t60, enabled: enabled,
                       chromatic: set == .chromatic)
    }

    public func noteName(tonic: Double, scaleRatios: [Double]) -> String {
        let hz = ratio(in: scaleRatios) * tonic
        let midi = Int((69.0 + 12.0 * log2(hz / 440.0)).rounded())
        return NoteName.name(forMIDI: midi)
    }
}

/// The melody-follower sympathetic string: one special string whose pitch
/// live-retunes kernel-side (`bow_poly_jt_track_*`) to the highest note
/// being played. Same Gain / t60 / On knobs as any row; no degree/octave,
/// and it cannot be a drone-button target (no stable nominal Hz). Default
/// disabled = no jt row, byte-null.
public struct FollowerSpec: Codable, Sendable, Hashable {
    public var gain: Double
    public var t60: Double
    public var enabled: Bool
    public init(gain: Double = 0.9, t60: Double = 5.0, enabled: Bool = false) {
        self.gain = gain; self.t60 = t60; self.enabled = enabled
    }
}

/// A sympathetic string after scale/tonic resolution — what the String
/// voice's taraf builder consumes.
public struct ResolvedString: Sendable, Hashable {
    public var freq: Double
    public var gain: Double
    public var t60: Double
    /// The Strings tab's per-row on/off toggle.
    public var enabled: Bool
    /// On the chromatic bridge: the jawari builder bakes this row with the
    /// `bow_jtc_*` contact law instead of `bow_jt_*`.
    public var chromatic: Bool
    public init(freq: Double, gain: Double, t60: Double, enabled: Bool = true,
                chromatic: Bool = false) {
        self.freq = freq; self.gain = gain; self.t60 = t60
        self.enabled = enabled; self.chromatic = chromatic
    }
}
