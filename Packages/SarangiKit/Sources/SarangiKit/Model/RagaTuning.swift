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

/// Raga tuning engine — port of `src/raga.py` (JI ratios and the
/// `build_strings` layout, minus the chromatic taraf row — removed
/// 2026-07-25). `estimate_tonic` is dropped (it needs a recording); the
/// tonic is set by the user.
public enum RagaTuning {

    /// Just-intonation swara ratios (semitone offset from Sa → ratio).
    public static let jiRatios: [Int: Double] = [
        0: 1.0, 1: 16.0 / 15, 2: 9.0 / 8, 3: 6.0 / 5, 4: 5.0 / 4, 5: 4.0 / 3,
        6: 45.0 / 32, 7: 3.0 / 2, 8: 8.0 / 5, 9: 5.0 / 3, 10: 16.0 / 9, 11: 15.0 / 8,
    ]

    public static let ragas: [Raga] = [
        Raga(id: 1, name: "E♭ harmonic minor", intervals: [0, 2, 3, 5, 7, 8, 11], tonicHint: 311.13),
        Raga(id: 2, name: "Bhairav",           intervals: [0, 1, 4, 5, 7, 8, 11], tonicHint: 293.66),
        // Pilu session (2026-07): 9-note mixed/thumri scale (both komal+shuddha
        // ga AND ni). Sa = 328.9 Hz — the recorded session tonic (E4 − 4c, a
        // semitone below concert F; upstream reports/pilu_pitch_map.md).
        Raga(id: 3, name: "Pilu",              intervals: [0, 2, 3, 4, 5, 7, 9, 10, 11], tonicHint: 328.9),
    ]
    public static func raga(id: Int) -> Raga { ragas.first { $0.id == id } ?? ragas[0] }

    /// The CHROMATIC bridge's pitch grid (2026-09-02): the 12 JI swara
    /// ratios above, indexed by semitone. A chromatic string's `degree`
    /// is a semitone into this grid — fixed, whatever the playing scale
    /// says (the real chromatic set is tuned once and stays; only the
    /// tonic moves it). Wrapped mod 12 so an out-of-range degree still
    /// resolves.
    public static func chromaticRatio(semitone: Int) -> Double {
        jiRatios[((semitone % 12) + 12) % 12] ?? 1.0
    }

    /// The grid as fraction text, by semitone — the chromatic rows' own
    /// name when the playing scale has no degree at that pitch (the
    /// naming rule: a pitch the scale can't label shows its ratio).
    public static let chromaticFractions: [String] = [
        "1/1", "16/15", "9/8", "6/5", "5/4", "4/3",
        "45/32", "3/2", "8/5", "5/3", "16/9", "15/8",
    ]

    /// The CHROMATIC SET's layout (2026-09-02): 15 consecutive semitones
    /// from low Ga (−8) up to tivra Ma (+6) — the historic
    /// `chromaticRatios` row of raga.build_strings (0.625 … 1.406),
    /// re-expressed as (semitone, octave) references into the JI
    /// chromatic grid, one string per semitone, pitch-sorted. Gain 0.6:
    /// above the jawari selection's `bow_jt_gmin` (0.5) so the set
    /// SOUNDS — the deleted 2026-07-25 chromatic choir sat at 0.40 and
    /// never did — and under the raga rows' 0.7–0.95 (on the instrument
    /// the raga sets carry the ring; the chromatic set is the haze that
    /// answers every note). t60 3.0 = the crowd law.
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

    /// The sympathetic-bank LAYOUT in scale-degree space — ONE flat pool:
    /// one string per scale degree, emphasized Sa/Pa, the low-octave choir
    /// and 6 upper-octave repeats. Structural port of `raga.build_strings`,
    /// re-expressed as (degree, octave) references into the centralized
    /// scale (2026-07-25) — every string sounds a pitch OF the scale, so
    /// the whole bank retunes when the scale or the tonic moves. The
    /// seeded ±cents detune chorus died with the free-ratio model (a
    /// degree can't be a few cents off itself), and the 15-string
    /// chromatic row was removed the same day (its 0.40 gain sat below
    /// the jawari selection's `bow_jt_gmin`, so it never sounded).
    /// Gains/t60s come from raga.build_strings — the 2026-07 refit
    /// lengthened the t60s (5/7/9 s); with `B_damp` in-loop f² damping
    /// only the FUNDAMENTAL keeps that ring, upper partials decay in
    /// fractions of a second (sympathetic selectivity by harmonic order).
    ///
    /// NO DUPLICATE PITCHES (2026-07-26): the historic layout doubled
    /// Sa/Pa (exact-unison twin rows since the detune removal). The pool
    /// is one-string-per-pitch now, so each duplicate folds into its
    /// STRONGEST twin (higher gain, then longer t60 — the doubling row's
    /// values, which is where the emphasis lived), and the result is
    /// sorted by pitch. The golden comparison in `ModelTests` applies the
    /// same fold to the fixture.
    public static func buildSpecs(scaleRatios: [Double]) -> [StringSpec] {
        guard !scaleRatios.isEmpty else { return [] }
        let n = scaleRatios.count
        // Pa = the degree nearest 3/2; vadi = the 2nd-highest degree.
        let paIdx = scaleRatios.indices.min {
            abs(scaleRatios[$0] - 1.5) < abs(scaleRatios[$1] - 1.5)
        } ?? 0
        let vadiIdx = n >= 2 ? n - 2 : 0
        let thirdIdx = n > 2 ? 2 : vadiIdx

        // (degree, octave, gain, t60) — the historic list, doublings and
        // all. 2026-08-01 coherence rev: the refit's 5/7 s crowd t60s
        // rang so long after a phrase that the wash decoupled from the
        // playing and read as a pad behind the voice — the CROWD (the
        // per-degree rows, low choir, upper repeats) shortened ~×0.6.
        // The three DRONE ANCHORS the buttons auto-map to (Sa, low Sa,
        // low Pa) keep their fitted 7/9/8 s: on the instrument those ARE
        // the long-ringing strings, they're consonant with everything,
        // and their tap ring is character-pinned by
        // `DroneExcitationTests` (fundamental dominance decays on the
        // row's own t60). The old crowd values are one git show away.
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
