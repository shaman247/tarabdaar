import CoreGraphics
import Foundation

// MARK: - Chord Pad geometry
//
// The **Chord Pad** is a second 2D playing surface (StarpadMac tab), built
// for playing chords rather than designing scales. Where the Pitch Pad lays
// one pitch per Voronoi cell along a log-frequency x-axis, the Chord Pad is a
// fixed **hex grid** whose pitch at each cell is derived from a diatonic
// scale: every column is a stack of diatonic thirds (a chord), and every row
// is a chord tone. The grid reuses the Pitch Pad's MPE emission
// (`PitchPadEngine`, fed a 12-TET `ratio = 2^(semis/12)`), its OKLCH colors
// (`pitchColor`), and its soft-margin glide (the penetration-weight blend
// below mirrors `pitchAt`), so a touch crossing a hex boundary bends between
// the two notes exactly as on the Pitch Pad.
//
// This file is platform-independent (no SwiftUI) and Mac-only in practice —
// no iPad view, no sync. See `docs/chord-pad.md`.

/// How a column's chord tones are tuned. 12-TET for now; `justIntonation`
/// (per-column perfect intervals stacked from the column root) is reserved as
/// the structural seam and not yet implemented.
public enum Temperament {
    case equalTemperament
    // case justIntonation  // future: per-column perfect intervals
}

/// Floor division. Swift's `/` and `%` truncate toward zero
/// (`-3 / 7 == 0`, `-1 % 7 == -1`), which is wrong for negative diatonic
/// `step`s (the rows below the column root). This returns the true floor so
/// `step - floorDiv(step, n) * n` always lands in `0..<n`.
func floorDiv(_ a: Int, _ n: Int) -> Int {
    let q = a / n
    return (a % n != 0 && (a < 0) != (n < 0)) ? q - 1 : q
}

/// Fixed layout constants for the chord grid.
public enum ChordPadLayout {
    /// The grid always has 6 rows.
    public static let rows = 6
    /// Row visual order top→bottom (rows 1…6) → diatonic step offset from the
    /// column's root degree: row1 = +6 (7th), row2 = +4 (5th), row3 = +2
    /// (3rd), row4 = 0 (root), row5 = -2 (3rd below), row6 = -3 (4th below).
    public static let rowStepOffsets = [6, 4, 2, 0, -2, -3]
}

private let sqrt3 = CGFloat(3.0).squareRoot()

// MARK: - Degree extraction

/// The diatonic degrees driving the chord grid, as semitone offsets from the
/// tonic (1/1). Derived from the shared Pitch Pad scale: each enabled
/// `PitchPoint` is mapped to its nearest 12-TET semitone (`round(12·log2 r)`),
/// folded into `0..<12`, de-duplicated, and sorted ascending. A 7-note scale
/// (e.g. D Dorian → `[0,2,3,5,7,9,10]`) yields 7 degrees → 8 columns.
public func chordDegrees(from scale: PitchScale) -> [Int] {
    var seen = Set<Int>()
    var out: [Int] = []
    for p in scale.points where p.enabled {
        let semis = Int((12.0 * log2(p.ratio)).rounded())
        let folded = ((semis % 12) + 12) % 12
        if seen.insert(folded).inserted { out.append(folded) }
    }
    return out.sorted()
}

// MARK: - Scale presets

/// Common selectable scales — the modes plus major/minor variants and
/// pentatonics. These are **shared**: a preset loads into the one Pitch Pad
/// `PitchScale` (`PitchPadEngine.loadPreset`), so both the Pitch Pad and the
/// Chord Pad use it. Each preset is defined by its semitone intervals from
/// the tonic and rendered as a just-intonation `PitchScale` (the same 12-tone
/// JI ratio table as `PitchScale.defaultJI`), matching the Pitch Pad's JI
/// design surface; the Chord Pad reads the degrees back as the nearest 12-TET
/// semitones.
public enum ScalePreset: String, CaseIterable, Identifiable {
    case major
    case minor
    case dorian
    case phrygian
    case lydian
    case mixolydian
    case locrian
    case harmonicMinor
    case melodicMinor
    case majorPentatonic
    case minorPentatonic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .major:           return "Major"
        case .minor:           return "Minor"
        case .dorian:          return "Dorian"
        case .phrygian:        return "Phrygian"
        case .lydian:          return "Lydian"
        case .mixolydian:      return "Mixolydian"
        case .locrian:         return "Locrian"
        case .harmonicMinor:   return "Harmonic Minor"
        case .melodicMinor:    return "Melodic Minor"
        case .majorPentatonic: return "Major Pentatonic"
        case .minorPentatonic: return "Minor Pentatonic"
        }
    }

    /// Semitone degrees from the tonic (ascending).
    public var intervals: [Int] {
        switch self {
        case .major:           return [0, 2, 4, 5, 7, 9, 11]
        case .minor:           return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:          return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:        return [0, 1, 3, 5, 7, 8, 10]
        case .lydian:          return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian:      return [0, 2, 4, 5, 7, 9, 10]
        case .locrian:         return [0, 1, 3, 5, 6, 8, 10]
        case .harmonicMinor:   return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor:    return [0, 2, 3, 5, 7, 9, 11]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        }
    }

    /// The preset as a `PitchScale` — each interval mapped to its 12-tone JI
    /// ratio. Degrees alternate between two layout rows and are labeled by
    /// scale-degree number so the Pitch Pad shows a clean keyboard-like row.
    public var pitchScale: PitchScale {
        // 12-tone JI ratio per semitone (matches `PitchScale.defaultJI`).
        let table: [(Int, Int)] = [
            (1, 1), (16, 15), (9, 8), (6, 5), (5, 4), (4, 3),
            (45, 32), (3, 2), (8, 5), (5, 3), (16, 9), (15, 8),
        ]
        let points = intervals.enumerated().map { (i, semi) -> PitchPoint in
            let (n, d) = table[((semi % 12) + 12) % 12]
            let y = (i % 2 == 0) ? 5.0 / 6.0 : 2.0 / 6.0
            return PitchPoint(num: n, den: d, y: y, label: "\(i + 1)")
        }
        return PitchScale(points: points)
    }
}

// MARK: - Cells

/// One hexagon in the chord grid. `center` is in the surface's logical pixel
/// space (pre-`edgePad`). `semitones` is the offset from the tonic and
/// `ratio = 2^(semitones/12)` is what the engine plays (relative to its
/// `tonicMidi`).
public struct ChordCell: Identifiable {
    public let id: String
    public let col: Int
    public let row: Int
    public let center: CGPoint
    public let semitones: Int
    public let ratio: Double

    public init(id: String, col: Int, row: Int, center: CGPoint,
                semitones: Int, ratio: Double) {
        self.id = id
        self.col = col
        self.row = row
        self.center = center
        self.semitones = semitones
        self.ratio = ratio
    }
}

/// Circumradius (center→vertex) of each hexagon for a lattice spacing `a`.
/// The Voronoi cell of a triangular lattice with nearest-neighbor distance
/// `a` is a regular hexagon with circumradius `a/√3`.
public func chordHexCircumradius(a: CGFloat) -> CGFloat { a / sqrt3 }

/// Geometry for a `cols × rows` chord grid in `size`. Returns the uniform
/// (regular-hex) lattice spacing `a` and `origin`, plus the per-axis `scale`
/// that stretches that grid to **fill** the surface (so the boundary hexes
/// touch all four edges; cells get slightly elongated where the panel's aspect
/// differs from the grid's). Centers lie on the sheared triangular lattice
/// `center(col,row) = origin + (col·a − row·a/2, row·a·√3/2)`, so columns lean
/// **up-right** (the bottom-left→top-right diagonal) while rows stay
/// horizontal. The uniform bounding box is placed at `(0,0)…(bboxW,bboxH)`, so
/// the stretch is just `screen = uniform · scale` (see `chordStretch`).
public func chordGridMetrics(cols: Int, rows: Int = ChordPadLayout.rows,
                             size: CGSize)
    -> (a: CGFloat, origin: CGPoint, scale: CGSize)
{
    guard cols > 0, rows > 0, size.width > 0, size.height > 0 else {
        return (0, .zero, CGSize(width: 1, height: 1))
    }
    // Centers span (cols-1)·a + (rows-1)·a/2 in x and (rows-1)·a·√3/2 in y;
    // add a half-hex (a/2 wide, a/√3 tall) on each side for the boundary hexes.
    let widthUnits = CGFloat(cols - 1) + CGFloat(rows - 1) / 2 + 1
    let heightUnits = CGFloat(rows - 1) * sqrt3 / 2 + 2 / sqrt3
    // Base `a` fits the smaller axis; the stretch below then expands the
    // slacker axis to fill, so distortion is minimized.
    let a = min(size.width / widthUnits, size.height / heightUnits)
    let bboxW = widthUnits * a
    let bboxH = heightUnits * a
    let R = a / sqrt3
    // Origin places the uniform bounding box at (0,0): the leftmost center
    // (col 0, bottom row, after the −row shear) sits a half-hex from the left,
    // the top row a half-hex (R) from the top.
    let origin = CGPoint(x: CGFloat(rows - 1) * a / 2 + a / 2, y: R)
    let scale = CGSize(width: size.width / bboxW, height: size.height / bboxH)
    return (a, origin, scale)
}

/// Build the chord grid. Columns = `degrees.count + 1` (the extra column is
/// the octave tonic). Pitch for `(col,row)`:
///   `step = col + rowStepOffsets[row]`, `n = degrees.count`,
///   `octave = floorDiv(step, n)`, `idx = step - octave·n`,
///   `semitones = degrees[idx] + 12·octave`.
/// Returns `[]` for an empty scale (`n == 0`).
public func chordCells(degrees: [Int],
                       temperament: Temperament = .equalTemperament,
                       a: CGFloat, origin: CGPoint,
                       rows: Int = ChordPadLayout.rows) -> [ChordCell] {
    let n = degrees.count
    guard n > 0, a > 0, rows > 0 else { return [] }
    let cols = n + 1
    var cells: [ChordCell] = []
    cells.reserveCapacity(cols * rows)
    for col in 0..<cols {
        for row in 0..<rows {
            let step = col + ChordPadLayout.rowStepOffsets[row]
            let octave = floorDiv(step, n)
            let idx = step - octave * n
            let semis = degrees[idx] + 12 * octave
            let ratio: Double
            switch temperament {
            case .equalTemperament:
                ratio = pow(2.0, Double(semis) / 12.0)
            }
            let cx = origin.x + CGFloat(col) * a - CGFloat(row) * a / 2
            let cy = origin.y + CGFloat(row) * a * sqrt3 / 2
            cells.append(ChordCell(
                id: "chord-\(col)-\(row)", col: col, row: row,
                center: CGPoint(x: cx, y: cy), semitones: semis, ratio: ratio))
        }
    }
    return cells
}

// MARK: - Hexagon polygons

/// A regular hexagon. `angleOffsetDegrees` rotates the vertices: 30° (the
/// default) gives a **pointy-top** hexagon (a vertex straight up/down) — the
/// Voronoi cell of the chord lattice; 0° gives a **flat-top** hexagon.
public func hexPolygon(center: CGPoint, circumradius R: CGFloat,
                       angleOffsetDegrees: Double = 30) -> [CGPoint] {
    var pts: [CGPoint] = []
    pts.reserveCapacity(6)
    for k in 0..<6 {
        let ang = (Double(k) * 60.0 + angleOffsetDegrees) * .pi / 180.0
        pts.append(CGPoint(x: center.x + R * CGFloat(cos(ang)),
                           y: center.y + R * CGFloat(sin(ang))))
    }
    return pts
}

/// The inner hexagon — same **pointy-top** orientation as the outer cell,
/// with every edge moved inward by `inset` pixels (the soft margin). For a
/// regular hexagon that's a uniform shrink: moving the apothem in by `m`
/// shrinks the circumradius by `m / cos 30°`.
public func innerHexPolygon(center: CGPoint, circumradius R: CGFloat,
                            inset m: CGFloat) -> [CGPoint] {
    let innerR = max(1, R - m / CGFloat(cos(Double.pi / 6.0)))
    return hexPolygon(center: center, circumradius: innerR)
}

// MARK: - Stretch-to-fill

/// The chord lattice has a fixed aspect ratio, so to fill a differently-shaped
/// panel the grid is stretched independently in X and Y. Geometry is built in
/// uniform (regular-hex) space and these map points to/from the stretched
/// screen space: drawing stretches, hit-testing un-stretches (so the
/// soft-margin pitch math in `chordPitchAt` stays exact on regular hexes).
public func chordStretch(_ p: CGPoint, by s: CGSize) -> CGPoint {
    CGPoint(x: p.x * s.width, y: p.y * s.height)
}

public func chordStretch(_ pts: [CGPoint], by s: CGSize) -> [CGPoint] {
    pts.map { CGPoint(x: $0.x * s.width, y: $0.y * s.height) }
}

public func chordUnstretch(_ p: CGPoint, by s: CGSize) -> CGPoint {
    CGPoint(x: s.width != 0 ? p.x / s.width : p.x,
            y: s.height != 0 ? p.y / s.height : p.y)
}

// MARK: - Soft-margin pitch resolution

/// Resolve a touch position to the ratio that should sound plus a per-cell
/// weight map (keyed by `ChordCell.id`, summing to 1) used both to bend the
/// pitch and to cross-fade the cell fills. This mirrors
/// `PitchPadGeometry.pitchAt` exactly, but over explicit hex centers with a
/// per-cell pitch instead of log-x seeds: for cells `s, s'`,
/// `h(s,s') = (d_s'² − d_s²)/(2|s−s'|)`, `raw_s = max(0, margin + min_s' h)`,
/// weights are `raw_s` normalized, and the played ratio is `2^Σ w·log2(rₛ)`.
/// Inside an inner hexagon → weight 1 on one cell; in a 2-cell strip → two;
/// at a triple junction → three. Continuous everywhere.
public func chordPitchAt(point pt: CGPoint, cells: [ChordCell],
                         marginPixels m: CGFloat)
    -> (ratio: Double, weights: [String: Double])?
{
    let n = cells.count
    guard n > 0 else { return nil }

    var dist2 = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let dx = Double(cells[i].center.x - pt.x)
        let dy = Double(cells[i].center.y - pt.y)
        dist2[i] = dx * dx + dy * dy
    }

    var nearest = 0
    for i in 1..<n where dist2[i] < dist2[nearest] { nearest = i }

    let margin = Double(m)
    if margin <= 0 || n == 1 {
        return (cells[nearest].ratio, [cells[nearest].id: 1.0])
    }

    var raw = [Double](repeating: 0, count: n)
    var sum = 0.0
    for s in 0..<n {
        let ps = cells[s].center
        let ds2 = dist2[s]
        var minH = Double.greatestFiniteMagnitude
        for j in 0..<n where j != s {
            let dx = Double(cells[j].center.x - ps.x)
            let dy = Double(cells[j].center.y - ps.y)
            let len = (dx * dx + dy * dy).squareRoot()
            if len == 0 { continue }
            let h = (dist2[j] - ds2) / (2 * len)
            if h < minH { minH = h }
        }
        let r = max(0, margin + minH)
        raw[s] = r
        sum += r
    }
    guard sum > 0 else {
        return (cells[nearest].ratio, [cells[nearest].id: 1.0])
    }

    var weights: [String: Double] = [:]
    var logSum = 0.0
    for s in 0..<n where raw[s] > 0 {
        let w = raw[s] / sum
        weights[cells[s].id] = w
        logSum += w * log2(cells[s].ratio)
    }
    return (pow(2, logSum), weights)
}

// MARK: - CellFillsView bridge

/// Wrap each hex cell as a `VoronoiCell` (inner-hexagon polygon, the cell's
/// pitch ratio, the cell's stable id) so the shared `CellFillsView` can draw
/// the live sounding fills — keyed by `engine.sounding.weights`, colored by
/// the cell ratio — with no Chord-Pad-specific fill view.
public func chordFillCells(_ cells: [ChordCell], circumradius R: CGFloat,
                           inset m: CGFloat, scale: CGSize) -> [VoronoiCell] {
    cells.map { c in
        let seed = DisplaySeed(id: c.id, sourceID: UUID(), octaveShift: 0,
                               ratio: c.ratio, y: 0, label: "", ratioString: "")
        let poly = chordStretch(innerHexPolygon(center: c.center, circumradius: R,
                                                inset: m), by: scale)
        return VoronoiCell(seed: seed, polygon: poly)
    }
}
