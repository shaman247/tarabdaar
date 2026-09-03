import Foundation

/// A raga: semitone intervals from Sa + a default tonic. Seeds the default
/// preset only — the playing scale lives in the Pitch Pad.
public struct Raga: Identifiable, Sendable, Hashable, Codable {
    public let id: Int
    public let name: String
    public let intervals: [Int]
    public let tonicHint: Double
    public init(id: Int, name: String, intervals: [Int], tonicHint: Double) {
        self.id = id; self.name = name; self.intervals = intervals; self.tonicHint = tonicHint
    }
}

/// JI ratios and the sympathetic-bank layouts. The tonic is set by the user.
public enum RagaTuning {

    /// Just-intonation swara ratios (semitone offset from Sa → ratio).
    public static let jiRatios: [Int: Double] = [
        0: 1.0, 1: 16.0 / 15, 2: 9.0 / 8, 3: 6.0 / 5, 4: 5.0 / 4, 5: 4.0 / 3,
        6: 45.0 / 32, 7: 3.0 / 2, 8: 8.0 / 5, 9: 5.0 / 3, 10: 16.0 / 9, 11: 15.0 / 8,
    ]

    public static let ragas: [Raga] = [
        Raga(id: 1, name: "E♭ harmonic minor", intervals: [0, 2, 3, 5, 7, 8, 11], tonicHint: 311.13),
        Raga(id: 2, name: "Bhairav",           intervals: [0, 1, 4, 5, 7, 8, 11], tonicHint: 293.66),
        // Pilu: 9-note mixed scale (both komal and shuddha ga and ni).
        Raga(id: 3, name: "Pilu",              intervals: [0, 2, 3, 4, 5, 7, 9, 10, 11], tonicHint: 328.9),
    ]
    public static func raga(id: Int) -> Raga { ragas.first { $0.id == id } ?? ragas[0] }

    /// The chromatic bridge's pitch grid: the 12 JI ratios by semitone, fixed
    /// whatever the playing scale (only the tonic moves it). Wrapped mod 12.
    public static func chromaticRatio(semitone: Int) -> Double {
        jiRatios[((semitone % 12) + 12) % 12] ?? 1.0
    }

    /// The grid as fraction text — a chromatic row's name when the playing
    /// scale has no degree at that pitch.
    public static let chromaticFractions: [String] = [
        "1/1", "16/15", "9/8", "6/5", "5/4", "4/3",
        "45/32", "3/2", "8/5", "5/3", "16/9", "15/8",
    ]

    /// The chromatic set's layout: 15 consecutive semitones, low Ga (−8) to
    /// tivra Ma (+6), one string each. Gain 0.6 sits above the jawari
    /// selection's `bow_jt_gmin` (0.5) so the set sounds, and under the raga
    /// rows' 0.7–0.95 — the raga sets carry the ring, the chromatic set is
    /// the haze that answers every note. t60 3.0, the crowd value.
    public static func buildChromaticSpecs() -> [StringSpec] {
        (-8...6).map { k -> StringSpec in
            let octave = Int((Double(k) / 12.0).rounded(.down))
            let semitone = k - 12 * octave
            return StringSpec(degree: semitone, octave: octave,
                              gain: 0.6, t60: 3.0, set: .chromatic)
        }
    }

    /// JI swara ratios for a raga's semitone intervals (degrees from Sa).
    public static func ratios(forIntervals intervals: [Int]) -> [Double] {
        intervals.map { jiRatios[(($0 % 12) + 12) % 12] ?? 1.0 }
    }

    /// The raga set's layout as (degree, octave) references into the
    /// centralized scale: one string per degree, emphasized Sa/Pa, a
    /// low-octave choir and 6 upper-octave repeats — every string sounds a
    /// pitch OF the scale. With `B_damp` in-loop f² damping only the
    /// fundamental keeps the listed t60; upper partials decay in fractions
    /// of a second. One string per pitch: a duplicate folds into its
    /// strongest twin (higher gain, then longer t60), and the result is
    /// pitch-sorted.
    public static func buildSpecs(scaleRatios: [Double]) -> [StringSpec] {
        guard !scaleRatios.isEmpty else { return [] }
        let n = scaleRatios.count
        // Pa = the degree nearest 3/2; vadi = the 2nd-highest degree.
        let paIdx = scaleRatios.indices.min {
            abs(scaleRatios[$0] - 1.5) < abs(scaleRatios[$1] - 1.5)
        } ?? 0
        let vadiIdx = n >= 2 ? n - 2 : 0
        let thirdIdx = n > 2 ? 2 : vadiIdx

        // (degree, octave, gain, t60). The crowd (per-degree rows, low
        // choir, upper repeats) rings 2.5–4.5 s so the wash stays coupled
        // to the playing; the three drone anchors (Sa, low Sa, low Pa) ring
        // 7/9/8 s — the instrument's long strings, consonant with
        // everything; `DroneExcitationTests` pins their tap ring.
        var rows: [(Int, Int, Double, Double)] = []
        for d in 0..<n { rows.append((d, 0, 0.85, 3.0)) }          // scale-tuned mid
        rows.append((0, 0, 0.95, 7.0))                             //   Sa doubling (anchor)
        rows.append((paIdx, 0, 0.90, 4.5))                         //   Pa doubling
        for d in [0, paIdx, vadiIdx, thirdIdx] {                   // low choir
            rows.append((d, -1, 0.80, 4.5))
        }
        rows.append((0, -1, 0.95, 9.0))                            //   low Sa (anchor)
        rows.append((paIdx, -1, 0.85, 8.0))                        //   low Pa (anchor)
        rows.append((vadiIdx, -1, 0.75, 4.5))
        for d in 0..<min(6, n) { rows.append((d, 1, 0.70, 2.5)) }  // 6 upper octave

        // fold duplicates (keep strongest) + sort by pitch
        var best: [String: (Int, Int, Double, Double)] = [:]
        for r in rows {
            let key = "\(r.1)/\(r.0)"
            if let w = best[key], (w.2, w.3) >= (r.2, r.3) { continue }
            best[key] = r
        }
        return best.values
            .sorted { a, b in
                let ra = scaleRatios[a.0] * pow(2.0, Double(a.1))
                let rb = scaleRatios[b.0] * pow(2.0, Double(b.1))
                return ra != rb ? ra < rb
                    : (a.1, a.0) < (b.1, b.0)
            }
            .map { StringSpec(degree: $0.0, octave: $0.1, gain: $0.2, t60: $0.3) }
    }

    /// The resolved bank from raga intervals — used by the golden tests.
    public static func buildStrings(tonic: Double, intervals: [Int]) -> [ResolvedString] {
        let scale = ratios(forIntervals: intervals)
        return buildSpecs(scaleRatios: scale)
            .map { $0.resolved(tonic: tonic, scaleRatios: scale) }
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
