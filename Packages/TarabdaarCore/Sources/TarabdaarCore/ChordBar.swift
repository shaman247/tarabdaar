import CoreGraphics
import Foundation

// MARK: - Chord bar
//
// The **chord bar** fills the dead space BELOW the Fret Pad's playable band:
// the same horizontal layout as the frets, but each fret's column carries a
// **chord label** — a roman numeral for the 3-tone chord rooted on that
// fret's degree, built from the configured scale itself. Tapping a cell
// selects that chord as what the controller strum (Joy-Con L / the accel
// trigger) plays; tapping any cell of the already-selected degree
// deselects it (selection is octave-agnostic  — see
// `ChordSelection` and the Shepard register law below), and with nothing
// selected the strum falls back to the Strings tab's configured strum set
// (default low Sa · low Pa).
//
// Chords are derived, never authored: for each enabled degree the root is
// joined by the scale's own best **third** (any pitch class folding to
// 250–450 ¢ above the root — "close to or between" the just minor 316 ¢ and
// major 386 ¢ thirds, so sparse and microtonal scales still find one) and
// best **fifth** (perfect 650–750 ¢, diminished 550–650 ¢, augmented
// 750–850 ¢), with quality priority **major > minor > diminished >
// augmented** — a full 12-tone scale therefore offers all major chords. A
// missing third or fifth is simply omitted (a pentatonic II is just
// root + fifth); a lone root still gets a cell.
//
// Numerals follow the harmonic convention, not the scale-label vocabulary
// (chord function is a different axis from pitch names, like the concert
// note names): each degree maps to the chromatic table I ♭II II ♭III III IV
// ♯IV V ♭VI VI ♭VII VII by its nearest semitone class, and the accidental is
// DROPPED when the scale holds no other class in the same ordinal family —
// so natural minor reads i ii° III iv v VI VII (not ♭III…), while the
// 12-tone scale keeps ♭II beside II. Case shows quality (major/augmented
// upper, minor/diminished lower, ° and + decorations); a third-less chord
// stays uppercase.
//
// Layout mirrors the frets: one cell column per fret column (frets sharing
// an x, like the keyboard layout's komal-over-shuddha stacks, share a
// column), repeated across the octave ghosts. A column with a single fret
// gets a full-height cell (S and P "cover both rows"); stacked frets split
// the bar vertically in their own top-to-bottom order, so the default
// 12-tone keyboard layout reads as a komal/tivra top row over a shuddha
// bottom row.

// MARK: - Chord derivation

public enum ChordQuality: Equatable, Sendable {
    case major, minor, diminished, augmented
    /// No third to speak of (root + fifth, or a bare root) — rendered
    /// uppercase, undecorated.
    case indeterminate
}

/// One derived chord: the degree it roots on, its display numeral, and its
/// member intervals as exact ratios above the root (ascending, `1.0` first;
/// members live within the octave above the root).
public struct ScaleChord: Equatable, Sendable {
    public let degreeIndex: Int
    public let numeral: String
    public let intervals: [Double]
    public let quality: ChordQuality

    public init(degreeIndex: Int, numeral: String, intervals: [Double],
                quality: ChordQuality) {
        self.degreeIndex = degreeIndex
        self.numeral = numeral
        self.intervals = intervals
        self.quality = quality
    }
}

/// The chromatic numeral table by semitone class (the conventional
/// spelling: flats except the tritone's ♯IV) and each class's ordinal
/// family (0-based I…VII).
private let chromaticNumerals = ["I", "♭II", "II", "♭III", "III", "IV",
                                 "♯IV", "V", "♭VI", "VI", "♭VII", "VII"]
private let ordinalFamily = [0, 1, 1, 2, 2, 3, 3, 4, 5, 5, 6, 6]
private let plainNumerals = ["I", "II", "III", "IV", "V", "VI", "VII"]

/// Just interval targets/windows in cents. The third window spans "close to
/// or between" the just minor (315.6) and major (386.3) thirds; a candidate
/// classifies to whichever it sits nearer.
private let thirdWindow = 250.0...450.0
private let minorThirdCents = 315.64
private let majorThirdCents = 386.31
private let perfectFifthWindow = 650.0...750.0
private let perfectFifthCents = 701.96
private let dimFifthWindow = 550.0..<650.0
private let dimFifthCents = 600.0
private let augFifthWindow = 750.0...850.0   // > 750 in practice (P5 wins ties)
private let augFifthCents = 800.0

/// Derive the chord for every degree of `degrees` (the enabled scale
/// degrees, ratios in [1, 2) — the same list the fret code consumes).
public func scaleChords(
    degrees: [(ratio: Double, label: String)]) -> [ScaleChord] {
    // Semitone class per degree, and how many DISTINCT classes each ordinal
    // family holds (drives the accidental-dropping rule).
    let classes: [Int] = degrees.map {
        let semis = Int((12.0 * log2(max($0.ratio, 1e-9))).rounded())
        return ((semis % 12) + 12) % 12
    }
    var familyClasses: [Set<Int>] = Array(repeating: [], count: 7)
    for c in classes { familyClasses[ordinalFamily[c]].insert(c) }

    return degrees.indices.map { i in
        let root = degrees[i].ratio
        // Candidate intervals: every OTHER degree folded into the octave
        // above the root.
        var candidates: [(cents: Double, ratio: Double)] = []
        for j in degrees.indices where j != i {
            var r = degrees[j].ratio / root
            if r < 1.0 { r *= 2.0 }
            if r >= 2.0 { r /= 2.0 }
            candidates.append((1200.0 * log2(r), r))
        }
        let thirds = candidates.filter { thirdWindow.contains($0.cents) }
        let minor3 = thirds
            .filter { abs($0.cents - minorThirdCents) <= abs($0.cents - majorThirdCents) }
            .min { abs($0.cents - minorThirdCents) < abs($1.cents - minorThirdCents) }?.ratio
        let major3 = thirds
            .filter { abs($0.cents - majorThirdCents) < abs($0.cents - minorThirdCents) }
            .min { abs($0.cents - majorThirdCents) < abs($1.cents - majorThirdCents) }?.ratio
        let p5 = candidates.filter { perfectFifthWindow.contains($0.cents) }
            .min { abs($0.cents - perfectFifthCents) < abs($1.cents - perfectFifthCents) }?.ratio
        let d5 = candidates.filter { dimFifthWindow.contains($0.cents) }
            .min { abs($0.cents - dimFifthCents) < abs($1.cents - dimFifthCents) }?.ratio
        let a5 = candidates.filter { augFifthWindow.contains($0.cents) && $0.cents > 750.0 }
            .min { abs($0.cents - augFifthCents) < abs($1.cents - augFifthCents) }?.ratio

        // Quality priority: major > minor > diminished > augmented, then
        // the partial fallbacks (fifth alone, third alone, altered fifth
        // alone, bare root).
        let quality: ChordQuality
        var tones: [Double] = [1.0]
        if let t = major3, let f = p5 {
            quality = .major; tones += [t, f]
        } else if let t = minor3, let f = p5 {
            quality = .minor; tones += [t, f]
        } else if let t = minor3, let f = d5 {
            quality = .diminished; tones += [t, f]
        } else if let t = major3, let f = a5 {
            quality = .augmented; tones += [t, f]
        } else if let f = p5 {
            quality = .indeterminate; tones.append(f)
        } else if let t = major3 {
            quality = .major; tones.append(t)
        } else if let t = minor3 {
            quality = .minor; tones.append(t)
        } else if let f = d5 ?? a5 {
            quality = .indeterminate; tones.append(f)
        } else {
            quality = .indeterminate
        }

        // Numeral: chromatic table entry, accidental dropped when the
        // ordinal family holds only this one class; cased by quality.
        let cls = classes[i]
        let family = ordinalFamily[cls]
        var numeral = familyClasses[family].count >= 2
            ? chromaticNumerals[cls] : plainNumerals[family]
        switch quality {
        case .minor:      numeral = numeral.lowercased()
        case .diminished: numeral = numeral.lowercased() + "°"
        case .augmented:  numeral += "+"
        case .major, .indeterminate: break
        }
        return ScaleChord(degreeIndex: i, numeral: numeral,
                          intervals: tones.sorted(), quality: quality)
    }
}

// MARK: - Selection

/// The active strum chord. OCTAVE-AGNOSTIC  a chord is a
/// pitch-CLASS object — tapping any Sa cell selects the same I chord, all
/// cells of the degree highlight, and the sound is fixed in register by
/// the Shepard construction (`shepardChordNotes`), not by which octave's
/// cell was tapped. `octave` is normalized to 0 at every selection point
/// (both surfaces' toggles) and kept only as the wire's reserved
/// `chordOctave` byte. nil = no chord selected — the strum falls back to
/// the Strings tab's configured set. Performance state, never persisted
/// (like the playing-range octave shift).
public struct ChordSelection: Equatable, Sendable {
    public var degree: Int
    public var octave: Int

    public init(degree: Int, octave: Int) {
        self.degree = degree
        self.octave = octave
    }
}

// MARK: - Shepard register law

/// The chord bar's REGISTER LAW: chords sound CENTERED IN THE OCTAVE BELOW
/// THE TONIC, Shepard-style, regardless of which degree they root on — a
/// VII chord does not sound an octave above a I chord, and the same chord
/// sounds identical from any octave's cell.
///
/// Construction: each chord tone is reduced to its pitch CLASS
/// (`u = fract(log2(root × interval))` ∈ [0, 1)) and realized as its
/// octave copies weighted by a raised-cosine window over log2 frequency,
/// centered at `c = −0.5` (the middle of the octave below the tonic) with
/// a 2-octave support: `W(x) = cos²(π(x − c)/2)` for |x − c| ≤ 1. Copies
/// sit at integer offsets of the class, so exactly two fall inside the
/// support — the main copy in [tonic/2, tonic) and one flank (above for
/// classes below the tritone, two octaves down otherwise) — and because
/// octave spacing shifts the window's phase by π/2, the two weights sum to
/// EXACTLY 1 per tone (cos² + sin²): total chord energy is independent of
/// the root, and as a progression walks up the scale the upper flank fades
/// out while the lower fades in, so the chord's center of gravity stays
/// put (a class at exactly the tritone is a single full-weight copy at the
/// center). Flanks below `threshold` are dropped to save polyphony.
///
/// Weights drive the notes' per-slot expression scale (`exprScale` — the
/// same channel as `ctl_strum_expr`, multiplied with it), so the crossfade
/// is smooth on the bow and a true amplitude weight on the plucked mains.
public func shepardChordNotes(
    rootRatio: Double, intervals: [Double],
    threshold: Double = 0.02) -> [(ratio: Double, weight: Double)] {
    let center = -0.5
    var out: [(ratio: Double, weight: Double)] = []
    for interval in intervals {
        let l = log2(max(rootRatio * interval, 1e-9))
        let u = l - l.rounded(.down)          // class, [0, 1)
        // Main copy: the octave below the tonic.
        let w1 = pow(cos(.pi * ((u - 1) - center) / 2), 2)
        out.append((pow(2.0, u - 1), w1))
        // The one flanking copy inside the window's support.
        let flank = u < 0.5 ? u : u - 2
        let w2 = 1.0 - w1
        if w2 >= threshold { out.append((pow(2.0, flank), w2)) }
    }
    return out.sorted { $0.ratio < $1.ratio }
}

// MARK: - Bar geometry

/// The chord bar's rectangle in the FULL surface's coordinates: the dead
/// strip under the playable band, inset a little from the band and the
/// surface's bottom edge. Shared by both platforms (like
/// `droneButtonRects`) so layout and hit-tests can never disagree.
public func chordBarRect(in size: CGSize) -> CGRect {
    let band = fretPadBandRect(in: size)
    let top = band.maxY + 8
    let bottom = size.height - 6
    return CGRect(x: 0, y: top, width: size.width,
                  height: max(0, bottom - top))
}

/// One tappable chord cell, resolved to FULL-surface pixel coordinates.
public struct ChordBarCell: Identifiable {
    public let id: String
    public let degreeIndex: Int
    public let octaveShift: Int
    public let numeral: String
    /// The chord's root as a ratio over the tonic (the fret's own pitch).
    public let rootRatio: Double
    public let rect: CGRect

    public init(id: String, degreeIndex: Int, octaveShift: Int,
                numeral: String, rootRatio: Double, rect: CGRect) {
        self.id = id
        self.degreeIndex = degreeIndex
        self.octaveShift = octaveShift
        self.numeral = numeral
        self.rootRatio = rootRatio
        self.rect = rect
    }
}

/// Resolve the chord bar's cells for the current arrangement: one column
/// per fret column (same x within `fretColumnEps`, octave ghosts included),
/// horizontal extent to the midpoints toward the neighbouring columns, and
/// the column's frets splitting the bar vertically in their own band order
/// (a lone fret — S, P — takes the full height).
public func chordBarCells(arrangement: FretArrangement,
                          degrees: [(ratio: Double, label: String)],
                          chords: [ScaleChord],
                          size: CGSize) -> [ChordBarCell] {
    let bar = chordBarRect(in: size)
    guard bar.height >= 14, !chords.isEmpty else { return [] }
    let extent = max(0, arrangement.ghostExtentOctaves)
    let shifts = Int(extent.rounded(.up))

    struct Entry {
        let x: CGFloat
        let centerY: Double     // fret's band-space centre, for stacking order
        let degreeIndex: Int
        let shift: Int
    }
    var entries: [Entry] = []
    for segment in arrangement.segments where segment.enabled {
        guard segment.degreeIndex >= 0,
              segment.degreeIndex < degrees.count,
              segment.degreeIndex < chords.count else { continue }
        for shift in -shifts...shifts {
            let x = fretPixelX(forBandX: segment.x + Double(shift),
                               ghostExtentOctaves: extent, width: size.width)
            guard x >= -1, x <= size.width + 1 else { continue }
            entries.append(Entry(x: x,
                                 centerY: (segment.topY + segment.bottomY) / 2,
                                 degreeIndex: segment.degreeIndex,
                                 shift: shift))
        }
    }
    guard !entries.isEmpty else { return [] }

    // Group into columns (same x within eps), ascending.
    entries.sort { $0.x < $1.x }
    var columns: [[Entry]] = []
    for e in entries {
        if let lastX = columns.last?.first?.x, e.x - lastX <= fretColumnEps {
            columns[columns.count - 1].append(e)
        } else {
            columns.append([e])
        }
    }

    // Horizontal cell edges: midpoints between adjacent columns; the
    // outermost columns extend by half their neighbour gap (clamped to the
    // surface).
    let xs = columns.map { $0.first!.x }
    func leftEdge(_ i: Int) -> CGFloat {
        if i > 0 { return (xs[i - 1] + xs[i]) / 2 }
        let gap = xs.count > 1 ? xs[1] - xs[0] : bar.width
        return max(0, xs[0] - gap / 2)
    }
    func rightEdge(_ i: Int) -> CGFloat {
        if i < xs.count - 1 { return (xs[i] + xs[i + 1]) / 2 }
        let gap = xs.count > 1 ? xs[xs.count - 1] - xs[xs.count - 2] : bar.width
        return min(size.width, xs[xs.count - 1] + gap / 2)
    }

    var out: [ChordBarCell] = []
    for (ci, var column) in columns.enumerated() {
        // Stacked frets split the bar top-to-bottom in their band order.
        column.sort { $0.centerY < $1.centerY }
        let n = CGFloat(column.count)
        let (x0, x1) = (leftEdge(ci), rightEdge(ci))
        for (row, e) in column.enumerated() {
            let sliceH = bar.height / n
            let y0 = bar.minY + CGFloat(row) * sliceH
            let rect = CGRect(x: x0 + 1, y: y0 + 1,
                              width: max(0, x1 - x0 - 2),
                              height: max(0, sliceH - 2))
            let chord = chords[e.degreeIndex]
            out.append(ChordBarCell(
                id: "chord:\(e.degreeIndex)#\(e.shift)@\(ci).\(row)",
                degreeIndex: e.degreeIndex,
                octaveShift: e.shift,
                numeral: chord.numeral,
                rootRatio: degrees[e.degreeIndex].ratio * pow(2.0, Double(e.shift)),
                rect: rect))
        }
    }
    return out
}
