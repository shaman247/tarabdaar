import CoreGraphics
import Foundation

// MARK: - String Pad geometry
//
// The **String Pad** is a third 2D playing surface (StarpadMac tab), a
// box-plot / abacus: discrete vertical **strings** (columns) carrying stacked
// **notes** the user drags and resizes.
//
// A **note** is a single **hexagon** — a rectangular middle (configurable
// centre-y + height) with a fixed-length triangular tip top and bottom — with a
// **name** and a **pitch**. The pitch is **constant throughout the whole
// hexagon**; interpolation happens only in the empty space *between* hexagons
// (inverse-distance, see `polyPitchAt`). A note belongs to a string by its
// `stringIndex`; its pitch is a **scale degree** (+ octave) of the shared Pitch
// Pad scale, and its **name** is sargam (S r R g G m M P d D n N).
//
// **Strings repeat across octaves.** The arrangement holds `stringCount`
// editable base strings (default 7 svaras) and `ghostStringsPerSide` (default 4)
// octave-repeat **ghost** strings on each side — read-only copies continuing the
// ascending svara sequence into the octave below (left) and above (right). So
// the 7 svaras of octave 0 sit in the centre, with the upper svaras of octave −1
// to their left and the lower svaras of octave +1 to their right.
//
// Platform-independent (no SwiftUI), Mac-only. Reuses the Pitch Pad's
// `PitchPadEngine` (MPE), `VoronoiCell`/`DisplaySeed` (to drive `CellFillsView`),
// and `pitchColor`. See `docs/string-pad.md`.

// (Uses the package-internal `floorDiv` from ChordPadGeometry.)

// MARK: - Model

/// One note on a string. `stringIndex` is which base string (column) it's on;
/// `centerY` (0..1, 0 = top) and `height` (0..1) place its hexagon vertically.
/// The pitch is a `degreeIndex` into the enabled Pitch Pad scale degrees
/// (low→high) plus an `octave` offset; the **name** is sargam, derived from the
/// pitch. `id` is per-process (minted on decode), like `PitchPoint.id`.
public struct StringNote: Identifiable, Equatable {
    public let id: UUID
    public var degreeIndex: Int
    public var octave: Int
    public var stringIndex: Int
    public var centerY: Double
    public var height: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), degreeIndex: Int, octave: Int = 0,
                stringIndex: Int, centerY: Double, height: Double,
                enabled: Bool = true) {
        self.id = id
        self.degreeIndex = degreeIndex
        self.octave = octave
        self.stringIndex = stringIndex
        self.centerY = centerY
        self.height = height
        self.enabled = enabled
    }

    public var topY: Double { centerY - height / 2 }
    public var bottomY: Double { centerY + height / 2 }
}

/// The whole surface arrangement: a flat list of `notes` (each tagged with its
/// `stringIndex`), the number of editable base `stringCount`, and how many
/// octave-repeat ghost strings to show on each side (`ghostStringsPerSide`).
public struct StringArrangement: Equatable {
    public var notes: [StringNote]
    public var stringCount: Int
    public var ghostStringsPerSide: Int
    /// iPad-only display tilt for the String Pad surface, in **degrees (0–40)**.
    /// On the iPad the strings render as hexagon lanes filling the *entire*
    /// surface, tilted by this angle (0° = upright columns, larger = leaning
    /// toward the top-left → bottom-right diagonal). The Mac editor always shows
    /// the upright rectangular layout and ignores this. Edited via the String Pad
    /// toolbar's Rotation slider and synced to the iPad with the arrangement.
    public var rotationDegrees: Double

    /// Default iPad tilt for a fresh arrangement / "Reset to Scale".
    public static let defaultRotationDegrees: Double = 30

    public init(notes: [StringNote], stringCount: Int,
                ghostStringsPerSide: Int = 4,
                rotationDegrees: Double = StringArrangement.defaultRotationDegrees) {
        self.notes = notes
        self.stringCount = stringCount
        self.ghostStringsPerSide = ghostStringsPerSide
        self.rotationDegrees = min(40, max(0, rotationDegrees))
    }

    /// Total visible columns: the base strings plus the ghost strings on each
    /// side.
    public var totalColumns: Int {
        max(0, stringCount) + 2 * max(0, ghostStringsPerSide)
    }

    /// Where a note sits within its string.
    private enum Pos { case center, bottom, top }

    /// The default arrangement: **7 base strings**, one per svara, named in
    /// sargam. String 1 = **S** (single, tall key centred at y=0.5). Strings with
    /// a vikrit (altered) variant carry two tall keys — the **shuddha/natural** in
    /// the bottom half and the **komal/tivra** in the top half, pulled close to
    /// the middle with a small gap between them: 2 = **R/r**, 3 = **G/g**,
    /// 4 = **m/M**, 6 = **D/d**, 7 = **N/n**; string 5 = **P** (single). Plus 4
    /// octave-repeat ghost strings on each side.
    public static func defaultArrangement(degreeCount: Int) -> StringArrangement {
        let sc = min(7, max(0, degreeCount))
        guard sc > 0 else {
            return StringArrangement(notes: [], stringCount: 0)
        }
        let strings: [[(deg: Int, pos: Pos)]] = [
            [(0, .center)],               // S
            [(2, .bottom), (1, .top)],    // R / r
            [(4, .bottom), (3, .top)],    // G / g
            [(5, .bottom), (6, .top)],    // m / M
            [(7, .center)],               // P
            [(9, .bottom), (8, .top)],    // D / d
            [(11, .bottom), (10, .top)],  // N / n
        ]
        var notes: [StringNote] = []
        for (i, string) in strings.prefix(sc).enumerated() {
            for entry in string where entry.deg < degreeCount {
                switch entry.pos {
                // Tall keys: the rect is only a fraction of the hexagon (tips add
                // the rest), so each `height` becomes a ~2× taller hexagon. The
                // paired top/bottom keys sit close to the middle (centerY 0.34 /
                // 0.66) leaving just a small gap between them around y=0.5.
                case .center:
                    notes.append(StringNote(degreeIndex: entry.deg, stringIndex: i,
                                            centerY: 0.5, height: 0.18))
                case .bottom:
                    notes.append(StringNote(degreeIndex: entry.deg, stringIndex: i,
                                            centerY: 0.66, height: 0.14))
                case .top:
                    notes.append(StringNote(degreeIndex: entry.deg, stringIndex: i,
                                            centerY: 0.34, height: 0.14))
                }
            }
        }
        return StringArrangement(notes: notes, stringCount: sc)
    }
}

// MARK: - Scale-derived pitch + sargam names

/// The Pitch Pad scale's enabled degrees, sorted low→high, as `(ratio, label)`.
public func scaleDegrees(from scale: PitchScale) -> [(ratio: Double, label: String)] {
    scale.points
        .filter(\.enabled)
        .sorted { $0.ratio < $1.ratio }
        .map { (ratio: $0.ratio, label: $0.displayLabel) }
}

/// The ratio a note plays in the base octave: its scale degree's ratio ×
/// `2^octave`. `nil` if the `degreeIndex` is out of range (the scale shrank).
public func noteRatio(_ note: StringNote,
                      degrees: [(ratio: Double, label: String)]) -> Double? {
    guard note.degreeIndex >= 0, note.degreeIndex < degrees.count else { return nil }
    return degrees[note.degreeIndex].ratio * pow(2.0, Double(note.octave))
}

/// The lowest and highest pitch *ratios* (relative to the tonic) playable
/// anywhere on the String Pad — every enabled note on every base string,
/// plus its octave-repeat ghost columns (global index `g` runs
/// `-ghost … stringCount-1+ghost`, octave shift `floor(g / stringCount)`).
/// `nil` when there are no playable notes. Used to fix a pitch readout's
/// axis to the pad's compass.
public func stringPadRatioRange(_ arrangement: StringArrangement,
                                degrees: [(ratio: Double, label: String)])
    -> (min: Double, max: Double)? {
    let sc = max(0, arrangement.stringCount)
    guard sc > 0 else { return nil }
    let ghost = max(0, arrangement.ghostStringsPerSide)
    var lo = Double.greatestFiniteMagnitude
    var hi = -Double.greatestFiniteMagnitude
    var found = false
    for g in -ghost...(sc - 1 + ghost) {
        let baseIndex = ((g % sc) + sc) % sc
        let octaveFactor = pow(2.0, (Double(g) / Double(sc)).rounded(.down))
        for note in arrangement.notes
        where note.enabled && note.stringIndex == baseIndex {
            guard let r = noteRatio(note, degrees: degrees) else { continue }
            let ratio = r * octaveFactor
            lo = min(lo, ratio)
            hi = max(hi, ratio)
            found = true
        }
    }
    return found ? (min: lo, max: hi) : nil
}

/// Sargam names for the 12 chromatic pitch classes.
public let sargamNames = ["S", "r", "R", "g", "G", "m", "M", "P", "d", "D", "n", "N"]

/// Sargam name for a semitone offset above the tonic, with `'`/`,` marks for
/// octaves above/below the base octave.
public func sargamName(semitonesAboveTonic semis: Int) -> String {
    let pc = ((semis % 12) + 12) % 12
    let oct = Int(floor(Double(semis) / 12.0))
    var name = sargamNames[pc]
    if oct > 0 { name += String(repeating: "'", count: oct) }
    else if oct < 0 { name += String(repeating: ",", count: -oct) }
    return name
}

/// Sargam name for a ratio (its nearest chromatic semitone).
public func sargamName(forRatio r: Double) -> String {
    sargamName(semitonesAboveTonic: Int((12.0 * log2(r)).rounded()))
}

/// A note's display name (base octave): its pitch mapped to sargam.
public func noteName(_ note: StringNote,
                     degrees: [(ratio: Double, label: String)]) -> String {
    guard let r = noteRatio(note, degrees: degrees) else { return "·" }
    return sargamName(forRatio: r)
}

/// Sargam name of a scale degree (by its ratio), for the editor's note picker.
public func degreeSargam(_ degree: (ratio: Double, label: String)) -> String {
    sargamName(forRatio: degree.ratio)
}

// MARK: - Columns

/// One visible column (string). `baseIndex` is which editable base string it
/// shows; `octaveShift` is 0 for the base strings and ±k for the ghost repeats;
/// `isGhost` is true for the octave-repeat columns (read-only).
public struct StringColumn {
    public let x: CGFloat
    public let baseIndex: Int
    public let octaveShift: Int
    public let isGhost: Bool
    public init(x: CGFloat, baseIndex: Int, octaveShift: Int, isGhost: Bool) {
        self.x = x; self.baseIndex = baseIndex
        self.octaveShift = octaveShift; self.isGhost = isGhost
    }
}

/// The visible columns left→right: `ghostStringsPerSide` octave-repeats, the
/// `stringCount` base strings, then `ghostStringsPerSide` more, evenly spaced
/// across `width`. Global index `g` runs `-ghost … stringCount-1+ghost`; the
/// base string shown is `g mod stringCount` and the octave shift is
/// `floor(g / stringCount)`.
public func stringColumns(_ arrangement: StringArrangement, width: CGFloat)
    -> [StringColumn] {
    let sc = max(0, arrangement.stringCount)
    let ghost = max(0, arrangement.ghostStringsPerSide)
    guard sc > 0 else { return [] }
    let T = sc + 2 * ghost
    var cols: [StringColumn] = []
    cols.reserveCapacity(T)
    for g in -ghost...(sc - 1 + ghost) {
        let slot = g + ghost
        let x = (CGFloat(slot) + 0.5) / CGFloat(T) * width
        let baseIdx = ((g % sc) + sc) % sc
        cols.append(StringColumn(x: x, baseIndex: baseIdx,
                                 octaveShift: floorDiv(g, sc),
                                 isGhost: !(0 <= g && g < sc)))
    }
    return cols
}

/// Pixel x of base string `index`'s column (octaveShift 0). `nil` if out of
/// range / no strings.
public func baseColumnX(_ index: Int, arrangement: StringArrangement,
                        width: CGFloat) -> CGFloat? {
    let sc = max(0, arrangement.stringCount)
    guard index >= 0, index < sc, sc > 0 else { return nil }
    let ghost = max(0, arrangement.ghostStringsPerSide)
    let T = sc + 2 * ghost
    let slot = index + ghost
    return (CGFloat(slot) + 0.5) / CGFloat(T) * width
}

/// Nearest base string index to a pixel x (clamped to `0..<stringCount`).
public func nearestBaseString(toX px: CGFloat, arrangement: StringArrangement,
                              width: CGFloat) -> Int {
    let sc = max(1, arrangement.stringCount)
    let ghost = max(0, arrangement.ghostStringsPerSide)
    let T = sc + 2 * ghost
    let slot = Int((px / max(1, width) * CGFloat(T)).rounded(.down))
    return max(0, min(sc - 1, slot - ghost))
}

// MARK: - Placement (per-note pixel geometry)

/// A note resolved to pixel space for one frame: its hexagon `rect`, the live
/// (octave-shifted) `ratio`, the sargam `name`, and whether it's a read-only
/// ghost repeat. Built by `stringPlacements`.
public struct StringPlacement: Identifiable {
    /// Stable id string — the `SoundingState.weights` / `VoronoiCell` key.
    /// Ghosts get an octave suffix so they don't collide with the base note.
    public let id: String
    public let noteID: UUID
    public let isGhost: Bool
    public let ratio: Double
    public let name: String
    public let columnX: CGFloat
    public let rect: CGRect
    public let tipUp: CGFloat
    public let tipDown: CGFloat

    public init(id: String, noteID: UUID, isGhost: Bool, ratio: Double,
                name: String, columnX: CGFloat, rect: CGRect,
                tipUp: CGFloat, tipDown: CGFloat) {
        self.id = id; self.noteID = noteID; self.isGhost = isGhost
        self.ratio = ratio; self.name = name; self.columnX = columnX
        self.rect = rect; self.tipUp = tipUp; self.tipDown = tipDown
    }
}

/// Resolve every enabled note to a `StringPlacement` for each visible column —
/// the base strings plus the octave-repeat ghost strings — in the surface's
/// logical pixel space (pre-`edgePad`). A note is a single hexagon whose tip
/// proportions depend on its vertical position — toward the top of the pad the
/// top tip grows (→70%) and the bottom shrinks (→10%), mirrored toward the
/// bottom, balanced 20%/20% in the middle — with constant pitch throughout; the
/// resolver uses the whole hexagon.
public func stringPlacements(arrangement: StringArrangement,
                             degrees: [(ratio: Double, label: String)],
                             size: CGSize, boxWidth: CGFloat) -> [StringPlacement] {
    let sc = max(0, arrangement.stringCount)
    guard sc > 0 else { return [] }
    let H = size.height

    var byString: [Int: [StringNote]] = [:]
    for note in arrangement.notes where note.enabled {
        guard note.stringIndex >= 0, note.stringIndex < sc else { continue }
        byString[note.stringIndex, default: []].append(note)
    }

    var out: [StringPlacement] = []
    for col in stringColumns(arrangement, width: size.width) {
        guard let notes = byString[col.baseIndex] else { continue }
        for note in notes {
            guard let baseR = noteRatio(note, degrees: degrees) else { continue }
            let ratio = baseR * pow(2.0, Double(col.octaveShift))
            let cy = CGFloat(note.centerY) * H
            let halfH = CGFloat(max(0.0, note.height)) / 2 * H
            let rect = CGRect(x: col.x - boxWidth / 2, y: cy - halfH,
                              width: boxWidth, height: halfH * 2)
            // Tip proportions depend on the hexagon's vertical position, on a
            // centered axis v = +1 at the top of the pad … 0 middle … −1 bottom:
            //   top half (v>0):  big top tip (→70%), small bottom (→10%)
            //   bottom half (v<0): small top (→10%), big bottom (→70%)
            //   middle (v≈0): balanced 20% top / 20% bottom.
            // Each side interpolates linearly from 20% at the centre; the
            // rectangular middle is whatever fraction is left.
            let v = max(-1.0, min(1.0, 1.0 - 2.0 * note.centerY))
            let topFrac = v >= 0 ? 0.20 + 0.50 * v : 0.20 + 0.10 * v
            let bottomFrac = v <= 0 ? 0.20 - 0.50 * v : 0.20 - 0.10 * v
            let rectFrac = 1.0 - topFrac - bottomFrac
            let tipUp = CGFloat(topFrac / rectFrac) * rect.height
            let tipDown = CGFloat(bottomFrac / rectFrac) * rect.height
            let id = col.isGhost
                ? "\(note.id.uuidString)#\(col.octaveShift)"
                : note.id.uuidString
            out.append(StringPlacement(id: id, noteID: note.id, isGhost: col.isGhost,
                                       ratio: ratio, name: sargamName(forRatio: ratio),
                                       columnX: col.x, rect: rect,
                                       tipUp: tipUp, tipDown: tipDown))
        }
    }
    return out
}

/// The note's hexagon outline (rectangular middle + top/bottom tips whose
/// proportions vary with vertical position, per `stringPlacements`) as a closed convex polygon — drawn, filled, **and** used by the
/// resolver (pitch is constant across the whole hexagon, tips included).
public func stringShapePolygon(_ p: StringPlacement) -> [CGPoint] {
    let r = p.rect, cx = p.columnX
    return [
        CGPoint(x: cx,      y: r.minY - p.tipUp),
        CGPoint(x: r.maxX,  y: r.minY),
        CGPoint(x: r.maxX,  y: r.maxY),
        CGPoint(x: cx,      y: r.maxY + p.tipDown),
        CGPoint(x: r.minX,  y: r.maxY),
        CGPoint(x: r.minX,  y: r.minY),
    ]
}

/// Resolver cells: the note **hexagons**, keyed by placement id, with the live
/// ratio. Feed to `polyPitchAt` — pitch is constant inside each hexagon and
/// interpolates (inverse-distance) in the empty space between hexagons.
public func stringResolverCells(_ placements: [StringPlacement])
    -> [(id: String, ratio: Double, polygon: [CGPoint])] {
    placements.map { (id: $0.id, ratio: $0.ratio, polygon: stringShapePolygon($0)) }
}

/// Wrap each note's hexagon as a `VoronoiCell` (stable id, live ratio) so the
/// shared `CellFillsView` draws the live sounding fills keyed by
/// `engine.sounding.weights` — exactly like `chordFillCells`.
public func stringFillCells(_ placements: [StringPlacement]) -> [VoronoiCell] {
    placements.map { p in
        let seed = DisplaySeed(id: p.id, sourceID: UUID(), octaveShift: 0,
                               ratio: p.ratio, y: 0, label: "", ratioString: "")
        return VoronoiCell(seed: seed, polygon: stringShapePolygon(p))
    }
}

// MARK: - Generic polygon soft-margin resolution

/// Resolve a cursor/touch position to the ratio that should sound plus a
/// per-cell weight map (keyed by cell id) used both to bend the pitch and to
/// cross-fade the fills. **Generic over arbitrary 2D polygons** and
/// **continuous everywhere — no discontinuities, no dead zones**:
///
///   • **Inside** a polygon → exactly that polygon's pitch (a flat fixed zone).
///   • **Anywhere outside** → an **inverse-distance blend** of the polygons by
///     distance to each: `w_s = 1 / d_s^power` (normalised), played ratio
///     `= 2 ^ Σ wₛ·log2(ratioₛ)`. Nearer polygons dominate; the influence falls
///     off smoothly with distance and never cuts off, so empty space between
///     polygons interpolates continuously (no nearest-snap, no margin band).
///
/// As the point approaches a polygon, `d_s → 0` so `w_s → ∞` and the blend → that
/// polygon's pitch, matching the inside value — so the surface is continuous at
/// every boundary. `power` controls locality (higher = nearest dominates more
/// sharply). Layout-agnostic — works for any polygons.
public func polyPitchAt(point pt: CGPoint,
                        cells: [(id: String, ratio: Double, polygon: [CGPoint])],
                        power: Double = 3)
    -> (ratio: Double, weights: [String: Double])?
{
    let n = cells.count
    guard n > 0 else { return nil }

    var dist = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let sd = signedDistanceToPolygon(pt, cells[i].polygon)   // + inside, − outside
        dist[i] = sd > 0 ? 0 : Double(-sd)
    }

    if let inside = (0..<n).first(where: { dist[$0] <= 1e-6 }) {
        return (cells[inside].ratio, [cells[inside].id: 1.0])
    }

    let p = max(0.5, power)
    var w = [Double](repeating: 0, count: n)
    var sum = 0.0
    for i in 0..<n {
        let wi = 1.0 / pow(dist[i], p)
        w[i] = wi
        sum += wi
    }
    guard sum.isFinite, sum > 0 else {
        let nearest = (0..<n).min(by: { dist[$0] < dist[$1] }) ?? 0
        return (cells[nearest].ratio, [cells[nearest].id: 1.0])
    }

    var weights: [String: Double] = [:]
    var logSum = 0.0
    for i in 0..<n {
        let wt = w[i] / sum
        logSum += wt * log2(cells[i].ratio)          // pitch uses every weight
        if wt > 0.02 { weights[cells[i].id] = wt }    // only meaningful fills show
    }
    return (pow(2, logSum), weights)
}

/// Signed distance from `p` to polygon `poly`: `+`(distance to nearest edge)
/// inside, `−`(distance) outside.
func signedDistanceToPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> CGFloat {
    guard poly.count >= 3 else { return -.greatestFiniteMagnitude }
    var minD = CGFloat.greatestFiniteMagnitude
    for i in 0..<poly.count {
        let a = poly[i]
        let b = poly[(i + 1) % poly.count]
        minD = min(minD, distancePointToSegment(p, a, b))
    }
    return pointInPolygon(p, poly) ? minD : -minD
}

/// Even-odd ray-cast point-in-polygon test.
func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) {
            let t = (p.y - a.y) / (b.y - a.y)
            if p.x < a.x + t * (b.x - a.x) { inside.toggle() }
        }
        j = i
    }
    return inside
}

/// Distance from point `p` to segment `a–b`.
func distancePointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
    t = max(0, min(1, t))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: - Hit-testing (editing)

/// What a press at `pt` grabs: a note to move, one of its resize edges, or
/// nothing. (Editing operates on base placements only — pass `placements`
/// filtered to `!isGhost`.)
public enum StringGrab: Equatable {
    case move(UUID)
    case resizeTop(UUID)
    case resizeBottom(UUID)
    case none
}

/// Classify a press: a grab near a note's top/bottom rectangle edge resizes it;
/// inside the hexagon moves it; otherwise `.none`.
public func stringGrab(at pt: CGPoint, placements: [StringPlacement],
                       handleRadius r: CGFloat) -> StringGrab {
    for p in placements {
        if abs(pt.x - p.columnX) > p.rect.width / 2 + r { continue }
        if abs(pt.y - p.rect.minY) <= r { return .resizeTop(p.noteID) }
        if abs(pt.y - p.rect.maxY) <= r { return .resizeBottom(p.noteID) }
        if pointInPolygon(pt, stringShapePolygon(p)) { return .move(p.noteID) }
    }
    return .none
}
