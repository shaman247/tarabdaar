import Foundation

/// A raga: semitone intervals from Sa + a default tonic. Ported from raga.RAGAS;
/// the table is open for the user to extend.
public struct Raga: Identifiable, Sendable, Hashable, Codable {
    public let id: Int
    public let name: String
    public let intervals: [Int]
    public let tonicHint: Double
    public init(id: Int, name: String, intervals: [Int], tonicHint: Double) {
        self.id = id; self.name = name; self.intervals = intervals; self.tonicHint = tonicHint
    }
}

/// Raga tuning engine — port of `src/raga.py` (JI ratios, chromatic taraf row,
/// and the 37-string `build_strings` layout). `estimate_tonic` is dropped (it
/// needs a recording); the tonic is set by the user.
public enum RagaTuning {

    /// Just-intonation swara ratios (semitone offset from Sa → ratio).
    public static let jiRatios: [Int: Double] = [
        0: 1.0, 1: 16.0 / 15, 2: 9.0 / 8, 3: 6.0 / 5, 4: 5.0 / 4, 5: 4.0 / 3,
        6: 45.0 / 32, 7: 3.0 / 2, 8: 8.0 / 5, 9: 5.0 / 3, 10: 16.0 / 9, 11: 15.0 / 8,
    ]

    /// 15 fixed JI-chromatic ratios of the main chromatic taraf row.
    public static let chromaticRatios: [Double] = [
        0.625, 0.667, 0.703, 0.75, 0.794, 0.833, 0.889, 0.9375,
        1.0, 1.0667, 1.125, 1.2, 1.25, 1.333, 1.406,
    ]

    public static let ragas: [Raga] = [
        Raga(id: 1, name: "E♭ harmonic minor", intervals: [0, 2, 3, 5, 7, 8, 11], tonicHint: 311.13),
        Raga(id: 2, name: "Bhairav",           intervals: [0, 1, 4, 5, 7, 8, 11], tonicHint: 293.66),
    ]
    public static func raga(id: Int) -> Raga { ragas.first { $0.id == id } ?? ragas[0] }

    public static func swaraHz(tonic: Double, semitone: Int, octave: Int = 0) -> Double {
        tonic * (jiRatios[((semitone % 12) + 12) % 12] ?? 1.0) * pow(2.0, Double(octave))
    }

    public static let taraf_lo = 55.0, taraf_hi = 9000.0

    /// JI swara ratios for a raga's semitone intervals (degrees from Sa).
    public static func ratios(forIntervals intervals: [Int]) -> [Double] {
        intervals.map { jiRatios[(($0 % 12) + 12) % 12] ?? 1.0 }
    }

    /// The physical sympathetic bank: 37 strings in 4 choirs (JI-tuned, detuned),
    /// each tagged with its `StringGroup`. Exact structural port of
    /// `raga.build_strings`, generalised to accept arbitrary scale-degree
    /// `ratios` (the Pitch Pad scale) instead of only raga intervals. With
    /// `detune == false` the per-string Gaussian cents are zero (golden parity);
    /// otherwise a seeded chorus. The spec order + one `rng.normal` per spec are
    /// preserved exactly, so the intervals path is bit-identical to before.
    public static func buildChoirs(tonic: Double, ratios: [Double],
                                   seed: UInt64 = 42, detune: Bool = true) -> [(ResolvedString, StringGroup)] {
        var rng = SeededGaussian(seed: seed)
        // Pa = a scale degree near 3/2 (else the bare fifth); vadi = 2nd-highest.
        let pa = ratios.first { abs($0 - 1.5) < 0.02 } ?? 1.5
        let vadi = ratios.count >= 2 ? ratios[ratios.count - 2] : 1.6

        // (ratio, rel_gain, t60, bright, sigma_cents, group)
        var specs: [(Double, Double, Double, Bool, Double, StringGroup)] = []
        for r in chromaticRatios { specs.append((r, 0.40, 2.5, false, 6.0, .chromatic)) }   // A: 15 chromatic
        for r in ratios { specs.append((r, 0.85, 1.8, true, 3.5, .scale)) }                 // B: scale-tuned mid
        specs.append((1.0, 0.95, 2.6, false, 9.0, .scale))                                  //   Sa doubling
        specs.append((pa, 0.90, 2.6, false, 9.0, .scale))                                   //   Pa doubling
        let lowSet = [1.0, pa, vadi, ratios.count > 2 ? ratios[2] : vadi]                   // C: low choir
        for r in lowSet { specs.append((r * 0.5, 0.80, 3.0, false, 3.5, .lowOctave)) }
        specs.append((0.5, 0.95, 3.5, false, 4.0, .lowOctave))                              //   low Sa
        specs.append((pa * 0.5, 0.85, 3.5, false, 4.0, .lowOctave))                         //   low Pa
        specs.append((vadi * 0.5, 0.75, 3.0, false, 4.0, .lowOctave))
        for r in ratios.prefix(6) { specs.append((r * 2.0, 0.70, 1.2, true, 3.5, .upperOctave)) } // D: 6 upper octave

        var out: [(ResolvedString, StringGroup)] = []
        for (ratio, gain, t60, bright, sigma, group) in specs {
            let cents = detune ? min(12.0, max(-12.0, rng.normal(sigma: sigma))) : 0.0
            let f = tonic * ratio * pow(2.0, cents / 1200.0)
            if f >= taraf_lo, f <= taraf_hi {
                out.append((ResolvedString(freq: (f * 1000).rounded() / 1000, gain: gain, t60: t60, bright: bright), group))
            }
        }
        return out
    }

    /// Back-compat: the DSP-facing bank from raga intervals (untagged). Identical
    /// output to the original `buildStrings` — used by the engine + golden tests.
    public static func buildStrings(tonic: Double, intervals: [Int],
                                    seed: UInt64 = 42, detune: Bool = true) -> [ResolvedString] {
        buildChoirs(tonic: tonic, ratios: ratios(forIntervals: intervals), seed: seed, detune: detune).map(\.0)
    }

    /// Editable, group-tagged bank from raga intervals (manual fallback).
    public static func buildGroupedSpecs(tonic: Double, intervals: [Int],
                                         seed: UInt64 = 42, detune: Bool = true) -> [StringSpec] {
        buildGroupedSpecs(tonic: tonic, ratios: ratios(forIntervals: intervals), seed: seed, detune: detune)
    }

    /// Editable, group-tagged bank from arbitrary scale-degree ratios (Pitch Pad).
    public static func buildGroupedSpecs(tonic: Double, ratios: [Double],
                                         seed: UInt64 = 42, detune: Bool = true) -> [StringSpec] {
        buildChoirs(tonic: tonic, ratios: ratios, seed: seed, detune: detune).map { StringSpec($0.0, group: $0.1) }
    }
}

/// 12-TET note-name ↔ frequency for tonic entry ("Eb4", "D4", "A4"=440).
public enum NoteName {
    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    public static func hz(forMIDI m: Int) -> Double { 440.0 * pow(2.0, Double(m - 69) / 12.0) }

    public static func name(forMIDI m: Int) -> String {
        let n = ((m % 12) + 12) % 12
        return "\(names[n])\(m / 12 - 1)"
    }

    /// Parse "Eb4" / "D#3" / "A4" → Hz. Returns nil if unparseable.
    public static func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first.isLetter else { return nil }
        var idx = t.startIndex
        let letter = String(t[idx]).uppercased()
        idx = t.index(after: idx)
        var semis: Int
        switch letter {
        case "C": semis = 0; case "D": semis = 2; case "E": semis = 4; case "F": semis = 5
        case "G": semis = 7; case "A": semis = 9; case "B": semis = 11
        default: return nil
        }
        while idx < t.endIndex, t[idx] == "#" || t[idx] == "b" || t[idx] == "♭" || t[idx] == "♯" {
            semis += (t[idx] == "#" || t[idx] == "♯") ? 1 : -1
            idx = t.index(after: idx)
        }
        guard let octave = Int(t[idx...]) else { return nil }
        let midi = (octave + 1) * 12 + semis
        return hz(forMIDI: midi)
    }
}
