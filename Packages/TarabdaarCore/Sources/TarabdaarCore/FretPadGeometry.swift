import CoreGraphics
import Foundation

// MARK: - Fret Pad geometry
//
// Fixed-height frets store a scale-degree pitch reference and one of five rows.
// Horizontal positions follow log2(ratio); octave copies tile the band.
// Each row and adjacent overlap resolves its own onset snap and drag field. See `docs/fret-pad.md`.

// MARK: - Model

/// Rows count upward from the bottom of the playable band.
public enum FretRow: Int, CaseIterable, Codable, Sendable {
    case bottom = 1, lower = 2, middle = 3, upper = 4, top = 5

    public static let overlap = 0.3
    public static let height = 1.0 / (5 - 4 * overlap)
    public var y: Double { 1 - Self.height / 2 - Double(rawValue - 1) * Self.height * (1 - Self.overlap) }
    public var topY: Double { y - Self.height / 2 }
    public var bottomY: Double { y + Self.height / 2 }
    public static func nearest(toY y: Double) -> Self {
        allCases.min { abs($0.y - y) < abs($1.y - y) } ?? .middle
    }
    static func legacy(_ row: Int) -> Self? {
        guard (1...3).contains(row) else { return nil }
        return Self(rawValue: row * 2 - 1)
    }
}

/// Five exclusive row interiors and four overlaps, ordered bottom to top.
/// An overlap has the union of its two rows' assigned pitches.
public enum FretRegion: Int, CaseIterable, Sendable {
    case bottom = 1, bottomLower, lower, lowerMiddle, middle, middleUpper, upper, upperTop, top

    /// Boundary blends leave the central half of each overlap entirely union-owned.
    public static let transitionHalfWidth = FretRow.overlap * FretRow.height / 4

    public var rows: [FretRow] {
        let lower = (rawValue + 1) / 2
        return rawValue % 2 == 1 ? [FretRow(rawValue: lower)!]
            : [FretRow(rawValue: lower)!, FretRow(rawValue: lower + 1)!]
    }
    public var topY: Double {
        let row = rows[0]
        return rows.count == 2 ? row.topY
            : row.topY + (row == .top ? 0 : FretRow.overlap * FretRow.height)
    }
    public var bottomY: Double {
        let row = rows[0]
        return rows.count == 2 ? rows[1].bottomY
            : row.bottomY - (row == .bottom ? 0 : FretRow.overlap * FretRow.height)
    }
    public static func at(y: Double) -> Self {
        // Geometric membership; sounding pitch blends across this edge.
        if let overlap = allCases.first(where: {
            $0.rows.count == 2 && y >= $0.topY - 1e-12 && y <= $0.bottomY + 1e-12
        }) { return overlap }
        return Self(rawValue: FretRow.nearest(toY: y).rawValue * 2 - 1)!
    }
    public func frets(in placements: [FretPlacement]) -> [FretPlacement] {
        placements.filter { $0.isEnabled && rows.contains($0.row) }
    }

    public static func weights(atY y: Double) -> [Self: Double] {
        for (lower, upper) in zip(allCases, allCases.dropFirst()) {
            let boundary = lower.topY
            guard abs(y - boundary) < transitionHalfWidth else { continue }
            let t = (boundary + transitionHalfWidth - y) / (2 * transitionHalfWidth)
            let blend = t * t * (3 - 2 * t)
            return [lower: 1 - blend, upper: blend]
        }
        return [at(y: y): 1]
    }
}

/// One layout pair: a pitch reference into the scale and a fixed row.
public struct FretSegment: Identifiable, Equatable {
    public let id: UUID
    public var degreeIndex: Int
    public var row: FretRow
    /// Shared vertical size, as a fraction of the playable band's height.
    public static let height = FretRow.height
    public var y: Double { row.y }

    public init(id: UUID = UUID(), degreeIndex: Int, row: FretRow) {
        self.id = id
        self.degreeIndex = degreeIndex
        self.row = row
    }

    public var topY: Double { y - Self.height / 2 }
    public var bottomY: Double { y + Self.height / 2 }
}

/// The whole surface: the editable base-band `segments` plus the flank each
/// side (`ghostExtentOctaves`, band-widths) showing read-only octave copies.
public struct FretArrangement: Equatable {
    public var segments: [FretSegment]
    public var ghostExtentOctaves: Double
    /// The drone buttons' DISPLAY pitches (ratios vs the tonic) — labels and
    /// colors only; the Mac derives them from the mapped strings
    /// (`InstrumentState.droneStringIds`) and they ride the iPad sync.
    public var droneRatios: [Double]

    /// The one drone-slot count the geometry, the sync blob, the CC range
    /// (102...) and the Strings tab's slots derive from.
    public static let droneCount = 3

    public static let defaultDroneRatios = [0.5, 3.0 / 4.0, 1.0]

    /// A 2.5-octave surface, including the one-octave base band.
    public static let defaultGhostExtentOctaves = 0.75

    public init(segments: [FretSegment],
                ghostExtentOctaves: Double = FretArrangement.defaultGhostExtentOctaves,
                droneRatios: [Double] = FretArrangement.defaultDroneRatios) {
        var seen = Set<String>()
        self.segments = segments.filter { seen.insert("\($0.degreeIndex):\($0.row.rawValue)").inserted }
        self.ghostExtentOctaves = max(0, min(2, ghostExtentOctaves))
        var r = droneRatios.map { max(0.25, min(4.0, $0)) }
        if r.count != FretArrangement.droneCount { r = FretArrangement.defaultDroneRatios }
        self.droneRatios = r
    }

    /// Assignment is per pitch and row; all octave copies reflect the same pair.
    public mutating func toggle(degreeIndex: Int, row: FretRow) {
        if segments.contains(where: { $0.degreeIndex == degreeIndex && $0.row == row }) {
            segments.removeAll { $0.degreeIndex == degreeIndex && $0.row == row }
        } else { segments.append(FretSegment(degreeIndex: degreeIndex, row: row)) }
    }

    /// Pilu: naturals below, S/g/P/n in the middle, r/M/d above.
    public static func defaultArrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        arrangement(degrees: degrees) { pc in
            switch pc {
            case 0, 7: return [.bottom, .middle]
            case 2, 4, 5, 9, 11: return [.bottom]
            case 3, 10: return [.middle]
            default: return [.top]
            }
        }
    }

    /// Legacy factory alternatives use the outer two rows.
    public static func keyboardArrangement(
        degrees: [(ratio: Double, label: String)], invertedRows: Bool = false) -> FretArrangement {
        arrangement(degrees: degrees) { pc in
            let rows: [FretRow] = [0, 7].contains(pc) ? [.bottom, .top]
                : ([2, 4, 5, 9, 11].contains(pc) ? [.bottom] : [.top])
            return invertedRows ? rows.map { $0 == .bottom ? .top : .bottom } : rows
        }
    }

    static func arrangement(degrees: [(ratio: Double, label: String)],
                            rows: (Int) -> [FretRow]) -> FretArrangement {
        var segments: [FretSegment] = []
        for (i, degree) in degrees.enumerated() {
            guard degree.ratio.isFinite, degree.ratio > 0 else { continue }
            let pc = ((Int((12 * log2(degree.ratio)).rounded()) % 12) + 12) % 12
            segments += rows(pc).map { FretSegment(degreeIndex: i, row: $0) }
        }
        return FretArrangement(segments: segments)
    }

}

// MARK: - Built-in layouts

/// The built-in fret layouts (Layout menu, beside `FretArrangementStore`'s
/// saved ones). All are built from the current scale's degrees.
public enum FretLayoutPreset: String, CaseIterable, Identifiable {
    case pilu
    /// Two outer rows, one fret per pitch.
    case equalFreq
    /// Two outer rows with paired tonic and fifth.
    case keyboard
    /// The keyboard layout with its upper and lower rows exchanged.
    case keyboardSharp

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pilu: return "Pilu"
        case .equalFreq: return "C Equal Freq"
        case .keyboard:  return "C Keyboard"
        case .keyboardSharp: return "C♯ Keyboard"
        }
    }

    public func arrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        switch self {
        case .pilu: return .defaultArrangement(degrees: degrees)
        case .equalFreq:
            return .arrangement(degrees: degrees) {
                [0, 2, 4, 5, 7, 9, 11].contains($0) ? [.bottom] : [.top]
            }
        case .keyboard:  return .keyboardArrangement(degrees: degrees)
        case .keyboardSharp: return .keyboardArrangement(degrees: degrees, invertedRows: true)
        }
    }
}

/// The ratio a segment plays in the base octave. `nil` if its `degreeIndex`
/// is out of range (the scale shrank) — the segment is skipped, not deleted.
public func fretRatio(_ segment: FretSegment,
                      degrees: [(ratio: Double, label: String)]) -> Double? {
    guard segment.degreeIndex >= 0,
          segment.degreeIndex < degrees.count else { return nil }
    let ratio = degrees[segment.degreeIndex].ratio
    return ratio.isFinite && ratio > 0 ? ratio : nil
}

// MARK: - Band

/// The playable **band**: full width, `Config.fretPadHeightFraction` of the
/// height, its top at `Config.fretPadBandTopFraction`. The taraf pluck strip
/// sits above it and the optional chord bar below.
public func fretPadBandRect(in size: CGSize) -> CGRect {
    let h = size.height * Config.fretPadHeightFraction
    let y = size.height * Config.fretPadBandTopFraction
    return CGRect(x: 0, y: y, width: size.width, height: h)
}

// MARK: - Band ↔ pixel mapping

/// Pixel x of band coordinate `u` (`u + k` = octave copy `k`); the surface
/// spans `[-extent, 1+extent]` band units across `width`.
public func fretPixelX(forBandX u: Double, ghostExtentOctaves: Double,
                       width: CGFloat) -> CGFloat {
    let extent = max(0, ghostExtentOctaves)
    let span = 1.0 + 2.0 * extent
    return CGFloat((u + extent) / span) * width
}

/// Band coordinate of pixel `x` (inverse of `fretPixelX`).
public func fretBandX(atPixelX x: CGFloat, ghostExtentOctaves: Double,
                      width: CGFloat) -> Double {
    let extent = max(0, ghostExtentOctaves)
    let span = 1.0 + 2.0 * extent
    return Double(x / max(1, width)) * span - extent
}

// MARK: - Placement (per-fret pixel geometry)

/// A fret resolved to pixel space with its octave-shifted `ratio` and scale
/// `name`; ghost copies get an octave suffix on `id`.
public struct FretPlacement: Identifiable {
    public let id: String
    public let segmentID: UUID
    public let isGhost: Bool
    public let ratio: Double
    public let isEnabled: Bool
    public let degreeIndex: Int
    public let logPerPixel: Double
    public let name: String
    public let row: FretRow
    public let x: CGFloat
    public let topY: CGFloat
    public let bottomY: CGFloat

    public init(id: String, segmentID: UUID, isGhost: Bool, ratio: Double,
                name: String, x: CGFloat, topY: CGFloat, bottomY: CGFloat,
                isEnabled: Bool = true, row: FretRow = .middle,
                degreeIndex: Int = 0, logPerPixel: Double = 0) {
        self.id = id; self.segmentID = segmentID; self.isGhost = isGhost
        self.row = row
        self.isEnabled = isEnabled
        self.degreeIndex = degreeIndex
        self.logPerPixel = logPerPixel
        self.ratio = ratio; self.name = name; self.x = x
        self.topY = topY; self.bottomY = bottomY
    }
}

/// Every segment as a `FretPlacement` per visible octave copy (shift
/// 0 = the editable base fret, ±k = ghosts one band over), in the surface's
/// logical pixel space (pre-`edgePad`).
public func fretPlacements(arrangement: FretArrangement,
                           degrees: [(ratio: Double, label: String)],
                           size: CGSize, includeUnassigned: Bool = false) -> [FretPlacement] {
    let extent = max(0, arrangement.ghostExtentOctaves)
    let shifts = Int(extent.rounded(.up))
    var out: [FretPlacement] = []
    let segments = includeUnassigned ? FretRow.allCases.flatMap { row in
        degrees.indices.map { degree in
            arrangement.segments.first { $0.row == row && $0.degreeIndex == degree }
                ?? FretSegment(degreeIndex: degree, row: row)
        }
    } : arrangement.segments
    for segment in segments {
        guard let baseRatio = fretRatio(segment, degrees: degrees) else { continue }
        for shift in -shifts...shifts {
            let x = fretPixelX(forBandX: log2(baseRatio) + Double(shift),
                               ghostExtentOctaves: extent, width: size.width)
            guard x >= -1, x <= size.width + 1 else { continue }
            let ratio = baseRatio * pow(2.0, Double(shift))
            let id = "\(segment.degreeIndex):\(segment.row.rawValue)#\(shift)"
            out.append(FretPlacement(id: id, segmentID: segment.id,
                                     isGhost: shift != 0, ratio: ratio,
                                     name: scaleLabel(degree: segment.degreeIndex,
                                                      octave: shift,
                                                      degrees: degrees), x: x,
                                     topY: CGFloat(segment.topY) * size.height,
                                     bottomY: CGFloat(segment.bottomY) * size.height,
                                     isEnabled: arrangement.segments.contains {
                                         $0.degreeIndex == segment.degreeIndex && $0.row == segment.row
                                     }, row: segment.row, degreeIndex: segment.degreeIndex,
                                     logPerPixel: (1 + 2 * extent) / max(1, size.width)))
        }
    }
    return out
}

// MARK: - Pitch field

/// Only coincident copies share a column; close microtonal pitches remain distinct.
let fretColumnEps: CGFloat = 1e-9

// MARK: Warp law

/// Maximum logistic gain at warp = 1 (`ctl_fret_warp` full): the plateau
/// around each fret covers most of the gap (center slope ≈ 3.5× linear).
let fretWarpMaxGain = 14.0

/// The fret-warp transfer — a normalized logistic on `t` (0…1):
///   w(t) = (σ(g·(t−½)) − σ(−g/2)) / (σ(g/2) − σ(−g/2)),  g = 14·amount
/// Identity at `amount` 0, w(0)=0 / w(1)=1, symmetric, strictly monotone.
public func fretWarp(_ t: Double, amount: Double) -> Double {
    guard amount > 1e-6 else { return t }
    let g = fretWarpMaxGain * min(amount, 1)
    let s0 = 1.0 / (1.0 + exp(g / 2))            // σ(−g/2)
    let s1 = 1.0 - s0                            // σ(g/2)
    let s = 1.0 / (1.0 + exp(-g * (t - 0.5)))
    return (s - s0) / (s1 - s0)
}

/// Distinct column x's, ascending — frets within `fretColumnEps` share one.
func fretColumnXs(_ placements: [FretPlacement]) -> [CGFloat] {
    var columns: [CGFloat] = []
    for x in placements.map(\.x).sorted()
    where columns.last.map({ x - $0 > fretColumnEps }) ?? true {
        columns.append(x)
    }
    return columns
}

/// Position along a fret: inner end 0, outer end 1, clamped beyond its
/// extent. Neighboring columns and gaps blend linearly, independent of pitch warp.
public func fretPosition(at pt: CGPoint, placements: [FretPlacement],
                         padHeight: CGFloat) -> Double {
    let columns = fretColumnXs(placements)
    guard !columns.isEmpty, padHeight > 0 else { return 0 }
    func position(on p: FretPlacement, atY y: CGFloat) -> Double {
        let height = p.bottomY - p.topY
        guard height > 0 else { return 0 }
        let t = min(1, max(0, Double((y - p.topY) / height)))
        return (p.topY + p.bottomY) / 2 < padHeight / 2 ? 1 - t : t
    }
    func position(atColumn cx: CGFloat) -> Double {
        let frets = placements.filter { abs($0.x - cx) <= fretColumnEps }
        if let inside = frets.filter({ $0.topY <= pt.y && pt.y <= $0.bottomY })
            .min(by: { abs(($0.topY + $0.bottomY) / 2 - pt.y)
                < abs(($1.topY + $1.bottomY) / 2 - pt.y) }) {
            return position(on: inside, atY: pt.y)
        }
        let above = frets.filter { $0.bottomY < pt.y }.max { $0.bottomY < $1.bottomY }
        let below = frets.filter { $0.topY > pt.y }.min { $0.topY < $1.topY }
        switch (above, below) {
        case (let a?, let b?):
            let t = Double((pt.y - a.bottomY) / (b.topY - a.bottomY))
            let start = position(on: a, atY: a.bottomY)
            return start + (position(on: b, atY: b.topY) - start) * t
        case (let a?, nil): return position(on: a, atY: pt.y)
        case (nil, let b?): return position(on: b, atY: pt.y)
        case (nil, nil): return 0
        }
    }
    guard columns.count > 1 else { return position(atColumn: columns[0]) }
    let upper = columns.firstIndex(where: { $0 > pt.x }) ?? columns.count
    let i = min(max(upper - 1, 0), columns.count - 2)
    let (a, b) = (columns[i], columns[i + 1])
    let t = min(1, max(0, Double((pt.x - a) / (b - a))))
    let start = position(atColumn: a)
    return start + (position(atColumn: b) - start) * t
}

/// The unwarped log-frequency axis also supplies pitch inside an empty row.
private func fretLinearLog(atX x: CGFloat, placements: [FretPlacement]) -> Double? {
    guard let first = placements.first else { return nil }
    var slope = first.logPerPixel
    if slope == 0, let other = placements.first(where: { abs($0.x - first.x) > fretColumnEps }) {
        slope = log2(other.ratio / first.ratio) / Double(other.x - first.x)
    }
    return log2(first.ratio) + Double(x - first.x) * slope
}

/// Each interior and overlap resolves one field from its own (possibly union) fret set.
public func fretRegionFields(atX x: CGFloat, placements: [FretPlacement],
                             warp: Double = 0) -> [FretRegion: Double] {
    guard let linear = fretLinearLog(atX: x, placements: placements) else { return [:] }
    return Dictionary(uniqueKeysWithValues: FretRegion.allCases.map { region in
        let columns = fretPitchColumns(region.frets(in: placements))
        return (region, fretColumnField(atX: x, columns: columns, warp: warp) ?? linear)
    })
}

private func fretColumnField(atX x: CGFloat, columns: [FretPlacement], warp: Double) -> Double? {
    guard let first = columns.first else { return nil }
    guard columns.count >= 2 else { return log2(first.ratio) }
    let upper = columns.firstIndex(where: { $0.x > x }) ?? columns.count
    let i = min(max(upper - 1, 0), columns.count - 2)
    let (a, b) = (columns[i], columns[i + 1])
    let t = Double((x - a.x) / (b.x - a.x))
    let blend = (t >= 0 && t <= 1) ? fretWarp(t, amount: warp) : t
    return log2(a.ratio) + log2(b.ratio / a.ratio) * blend
}

/// Placements retain the band transform, including when some rows are empty.
private func fretNormalizedY(_ y: CGFloat, placements: [FretPlacement]) -> Double? {
    guard let p = placements.first, p.bottomY > p.topY else { return nil }
    let height = Double(p.bottomY - p.topY) / FretRow.height
    let origin = Double(p.topY) - p.row.topY * height
    return (Double(y) - origin) / height
}

public func fretRegion(atY y: CGFloat, placements: [FretPlacement]) -> FretRegion? {
    fretNormalizedY(y, placements: placements).map { .at(y: $0) }
}

public func fretRegionWeights(atY y: CGFloat, placements: [FretPlacement]) -> [FretRegion: Double] {
    fretNormalizedY(y, placements: placements).map { FretRegion.weights(atY: $0) } ?? [:]
}

public func fretRegionValue(_ values: [FretRegion: Double], atY y: CGFloat,
                            placements: [FretPlacement]) -> Double? {
    let weights = fretRegionWeights(atY: y, placements: placements)
    guard !weights.isEmpty else { return nil }
    var result = 0.0
    for (region, weight) in weights {
        guard let value = values[region] else { return nil }
        result += value * weight
    }
    return result
}

public func fretFieldLog(at pt: CGPoint, placements: [FretPlacement],
                         warp: Double = 0) -> Double? {
    fretRegionValue(fretRegionFields(atX: pt.x, placements: placements, warp: warp),
                    atY: pt.y, placements: placements)
}

/// Each region snaps within its own fret set before blending at its boundaries.
public func fretOnset(at pt: CGPoint, placements: [FretPlacement],
                      snapDistance: CGFloat, warp: Double = 0)
    -> (pitch: Double, offsets: [FretRegion: Double], logs: [FretRegion: Double], weights: [String: Double])? {
    let fields = fretRegionFields(atX: pt.x, placements: placements, warp: warp)
    let regionWeights = fretRegionWeights(atY: pt.y, placements: placements)
    var logs = fields, offsets: [FretRegion: Double] = [:], weights: [String: Double] = [:]
    for region in FretRegion.allCases {
        guard let raw = fields[region] else { continue }
        let frets = region.frets(in: placements)
        if snapDistance > 0, let hit = frets.filter({ abs($0.x - pt.x) <= snapDistance })
            .min(by: { abs($0.x - pt.x) < abs($1.x - pt.x) }) {
            logs[region] = log2(hit.ratio)
            offsets[region] = log2(hit.ratio) - raw
            if let weight = regionWeights[region] {
                for p in frets where abs(p.x - hit.x) <= fretColumnEps {
                    weights[p.id, default: 0] += weight
                }
            }
        } else { offsets[region] = 0 }
    }
    guard let pitch = fretRegionValue(logs, atY: pt.y, placements: placements) else { return nil }
    return (pitch, offsets, logs, weights)
}

private func fretPitchColumns(_ placements: [FretPlacement]) -> [FretPlacement] {
    var columns: [FretPlacement] = []
    for fret in placements.sorted(by: { $0.x < $1.x })
    where columns.last.map({ fret.x - $0.x > fretColumnEps }) ?? true {
        columns.append(fret)
    }
    return columns
}

// MARK: - Fill cells (sounding highlight)

/// Each fret as a thin-rectangle `VoronoiCell` so `CellFillsView` glows the
/// snapped fret keyed by `engine.sounding.weights`.
public func fretFillCells(_ placements: [FretPlacement],
                          halfWidth: CGFloat = 2.5) -> [VoronoiCell] {
    placements.map { p in
        let seed = DisplaySeed(id: p.id, sourceID: UUID(), octaveShift: 0,
                               ratio: p.ratio, y: 0, label: "", ratioString: "")
        let polygon = [
            CGPoint(x: p.x - halfWidth, y: p.topY),
            CGPoint(x: p.x + halfWidth, y: p.topY),
            CGPoint(x: p.x + halfWidth, y: p.bottomY),
            CGPoint(x: p.x - halfWidth, y: p.bottomY),
        ]
        return VoronoiCell(seed: seed, polygon: polygon)
    }
}

// MARK: - Hit-testing (editing)

/// Clicking an overlap edits the nearer row centre; octave copies edit the base pair.
public func fretAssignment(at pt: CGPoint, placements: [FretPlacement],
                            hitRadius: CGFloat) -> FretPlacement? {
    placements.filter {
        abs(pt.x - $0.x) <= hitRadius && pt.y >= $0.topY && pt.y <= $0.bottomY
    }.min {
        let dy0 = abs(pt.y - ($0.topY + $0.bottomY) / 2)
        let dy1 = abs(pt.y - ($1.topY + $1.bottomY) / 2)
        if abs(dy0 - dy1) > 1e-9 { return dy0 < dy1 }
        let dx0 = abs(pt.x - $0.x), dx1 = abs(pt.x - $1.x)
        if dx0 != dx1 { return dx0 < dx1 }
        return $0.row.rawValue < $1.row.rawValue
    }
}
