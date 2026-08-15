import Foundation

// (`StringGroup` — the chromatic / scale-tuned / low-octave / upper-octave
// choir tag — was deleted 2026-07-25: the 15-string chromatic row was removed
// outright (its 0.40 gain sat below the jawari selection's `bow_jt_gmin`, so
// it never sounded) and the remaining strings are ONE flat pool.)

/// An editable / persisted sympathetic string (UI row). Carries a stable id
/// for SwiftUI lists; `resolved(tonic:ratios:)` is the DSP-facing value the
/// bank consumes.
///
/// SCALE-DEFINED (2026-07-25): the pitch is a **scale degree + octave**, not
/// a free ratio. `degree` indexes `InstrumentState.scaleRatios` — the ONE
/// centralized scale, mirrored from the Pitch Pad — and `octave` shifts it
/// by whole octaves, so a string can only ever sound a pitch of the scale
/// and the whole bank retunes when the scale or the tonic moves. Absolute
/// Hz exists nowhere in the document; it is minted at resolve time only.
/// (The ratio-defined era — free `ratio` per string, and before it absolute
/// `freq` — ended the same day it began; persisted documents were migrated
/// in place, and the fitted-Hz Pilu table, which a degree can't express,
/// was retired with the string-table law itself.)
public struct StringSpec: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// Index into the document's `scaleRatios` (0 = Sa). Clamped at resolve
    /// time, so a row survives the scale shrinking underneath it.
    public var degree: Int
    /// Whole-octave shift (the UI offers −2…+2; generation uses −1/0/+1).
    public var octave: Int
    /// Per-string loudness — the ONE level knob. (A separate `weight`
    /// multiplier existed briefly and was folded in 2026-07-25.)
    public var gain: Double
    public var t60: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), degree: Int, octave: Int = 0,
                gain: Double, t60: Double, enabled: Bool = true) {
        self.id = id; self.degree = degree; self.octave = octave
        self.gain = gain; self.t60 = t60; self.enabled = enabled
    }

    // Tolerant decode: `octave` and `enabled` default when absent; retired
    // keys older documents carry (`ratio`/`freq`/`group`/`weight`/`bright`/
    // `raga`) are simply ignored. `degree` is required — pre-degree
    // documents were migrated in place, not decoded compatibly.
    private enum CodingKeys: String, CodingKey { case id, degree, octave, gain, t60, enabled }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        degree = try c.decode(Int.self, forKey: .degree)
        octave = (try? c.decode(Int.self, forKey: .octave)) ?? 0
        gain = try c.decode(Double.self, forKey: .gain)
        t60 = try c.decode(Double.self, forKey: .t60)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }

    /// The string's frequency ratio vs the tonic, under a scale. The degree
    /// clamps into the scale (an out-of-range row keeps sounding the top
    /// degree rather than going silent or crashing after the scale shrinks).
    public func ratio(in scaleRatios: [Double]) -> Double {
        guard !scaleRatios.isEmpty else { return pow(2.0, Double(octave)) }
        let d = min(max(degree, 0), scaleRatios.count - 1)
        return scaleRatios[d] * pow(2.0, Double(octave))
    }

    /// Absolute Hz is minted here: degree ratio × 2^octave × tonic,
    /// quantized to MILLIHERTZ (the grid the whole pipeline shares — the
    /// drone press path finds its jt row by exact nominal Hz, so resolve
    /// must be deterministic to the bit).
    public func resolved(tonic: Double, scaleRatios: [Double]) -> ResolvedString {
        ResolvedString(freq: (ratio(in: scaleRatios) * tonic * 1000).rounded() / 1000,
                       gain: gain, t60: t60, enabled: enabled)
    }

    public func noteName(tonic: Double, scaleRatios: [Double]) -> String {
        let hz = ratio(in: scaleRatios) * tonic
        let midi = Int((69.0 + 12.0 * log2(hz / 440.0)).rounded())
        return NoteName.name(forMIDI: midi)
    }
}

// (`DroneStringSpec` — the dedicated drone strings' per-slot enable/gain/t60
// — lived here for one day, 2026-07-25. The drone buttons now reference
// ordinary tarab rows by id: `InstrumentState.droneStringIds`.)

/// The MELODY-FOLLOWER sympathetic string (2026-07-25): ONE special string
/// whose pitch is not a scale degree — it live-retunes to the highest note
/// being played (kernel-side, `bow_poly_jt_track_*`), so it always rings in
/// sympathy with the melody. Configured in the Strings tab with the same
/// Gain / t60 / On knobs as any row; it has no degree/octave and cannot be
/// a drone-button target (it has no stable nominal Hz). Default DISABLED —
/// off it adds no jt row and the render is byte-identical
/// (`TarafRemovalParityTests` unchanged).
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
    public init(freq: Double, gain: Double, t60: Double, enabled: Bool = true) {
        self.freq = freq; self.gain = gain; self.t60 = t60
        self.enabled = enabled
    }
}
