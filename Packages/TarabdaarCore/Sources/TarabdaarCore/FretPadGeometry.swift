import CoreGraphics
import Foundation

// MARK: - Fret Pad geometry
//
// The **Fret Pad** is the sole playing surface: the scale's pitches as
// vertical **frets**, freely positioned (`x` is layout state, 0..1 across the
// base band). The playable pitch is a continuous **field** (`fretFieldLog`):
// each column's pitch resolved by the touch's y, then a log-pitch
// x-interpolation between the two flanking columns. A touch **starting**
// within `snapDistance` px of a fret and inside its vertical extent snaps to
// it; elsewhere it plays the field pitch. Drags are continuous (field plus
// the offset captured at the snap) and never re-snap. The base segments live
// in a central **band**, flanked by read-only octave copies.
//
// Platform-independent (no SwiftUI). See `docs/fret-pad.md`.

// MARK: - Model

/// One fret: `degreeIndex` into the enabled scale degrees (low→high), `x`
/// (0..1 across the base band, free of its pitch), `topY`/`bottomY` (0..1,
/// 0 = top) bounding the onset-snap zone. `id` is per-process.
public struct FretSegment: Identifiable, Equatable {
    public let id: UUID
    public var degreeIndex: Int
    public var x: Double
    public var topY: Double
    public var bottomY: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), degreeIndex: Int, x: Double, topY: Double,
                bottomY: Double, enabled: Bool = true) {
        self.id = id
        self.degreeIndex = degreeIndex
        self.x = min(max(0, x), 1)
        let t = min(max(0, topY), 1)
        let b = min(max(0, bottomY), 1)
        self.topY = min(t, b)
        self.bottomY = max(t, b)
        self.enabled = enabled
    }

    public var height: Double { bottomY - topY }
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

    public init(segments: [FretSegment], ghostExtentOctaves: Double = 0.5,
                droneRatios: [Double] = FretArrangement.defaultDroneRatios) {
        self.segments = segments
        self.ghostExtentOctaves = max(0, min(2, ghostExtentOctaves))
        var r = droneRatios.map { max(0.25, min(4.0, $0)) }
        if r.count != FretArrangement.droneCount { r = FretArrangement.defaultDroneRatios }
        self.droneRatios = r
    }

    /// Band-widths the surface spans: the base band plus the flanks each side.
    public var octaveSpan: Double { 1 + 2 * max(0, ghostExtentOctaves) }

    /// `FretLayoutPreset.equalFreq` ("C Equal Freq"): **pitch-aligned x** —
    /// a fret sits at `log2(ratio)`. Komal/tivra in an upper tier, shuddha in
    /// a lower one, S and P longer; every fret crosses the centre line.
    public static func defaultArrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        var segments: [FretSegment] = []
        for (i, deg) in degrees.enumerated() {
            guard deg.ratio > 0 else { continue }
            // x IS the pitch; `FretSegment.init` clamps a degree outside [1, 2).
            let x = log2(deg.ratio)
            let semis = Int((12.0 * log2(deg.ratio)).rounded())
            let pc = ((semis % 12) + 12) % 12
            // Sized for the half-height band (`Config.fretPadHeightFraction`).
            let band: (top: Double, bottom: Double)
            switch pc {
            case 0:               band = (0.470, 0.912)   // S — the long key
            case 7:               band = (0.510, 0.912)   // P — long
            case 2, 4, 5, 9, 11:  band = (0.540, 0.892)   // shuddha — lower tier
            default:              band = (0.108, 0.460)   // komal/tivra — upper tier
            }
            segments.append(FretSegment(degreeIndex: i, x: x, topY: band.top,
                                        bottomY: band.bottom))
        }
        return FretArrangement(segments: segments)
    }

    /// `FretLayoutPreset.keyboard` ("C Keyboard") — the DEFAULT layout: **7
    /// evenly-spaced svara columns** with komal/tivra **stacked above** their
    /// shuddha partner like black keys over white (the field y-interpolates
    /// inside a column, so sliding up bends r → R).
    public static func keyboardArrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        // Column per svara (pitch class): S | R/r | G/g | m/M | P | D/d | N/n.
        let columnForPC = [0: 0, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3,
                           7: 4, 8: 5, 9: 5, 10: 6, 11: 6]
        var segments: [FretSegment] = []
        for (i, deg) in degrees.enumerated() {
            guard deg.ratio > 0 else { continue }
            let semis = Int((12.0 * log2(deg.ratio)).rounded())
            let pc = ((semis % 12) + 12) % 12
            let x = (Double(columnForPC[pc] ?? 0) + 0.5) / 7.0
            let band: (top: Double, bottom: Double)
            switch pc {
            case 0, 7:            band = (0.324, 0.676)   // S, P — centred
            case 2, 4, 5, 9, 11:  band = (0.588, 0.892)   // shuddha — lower middle
            default:              band = (0.108, 0.412)   // komal/tivra — upper middle
            }
            segments.append(FretSegment(degreeIndex: i, x: x, topY: band.top,
                                        bottomY: band.bottom))
        }
        return FretArrangement(segments: segments)
    }
}

// MARK: - Built-in layouts

/// The built-in fret layouts (Layout menu, beside `FretArrangementStore`'s
/// saved ones). Both are built from the current scale's degrees.
public enum FretLayoutPreset: String, CaseIterable, Identifiable {
    /// Pitch-aligned: `x = log2(ratio)`.
    case equalFreq
    /// The default: 7 svara columns, komal/tivra stacked above shuddha.
    case keyboard

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .equalFreq: return "C Equal Freq"
        case .keyboard:  return "C Keyboard"
        }
    }

    public var summary: String {
        switch self {
        case .equalFreq:
            return "Every fret at its own frequency (x = log2 of the ratio); "
                + "komal/tivra above, S and P the long keys."
        case .keyboard:
            return "7 evenly-spaced svara columns, komal/tivra stacked above "
                + "their shuddha partner — a piano keyboard's key spacing."
        }
    }

    public func arrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        switch self {
        case .equalFreq: return .defaultArrangement(degrees: degrees)
        case .keyboard:  return .keyboardArrangement(degrees: degrees)
        }
    }
}

/// The ratio a segment plays in the base octave. `nil` if its `degreeIndex`
/// is out of range (the scale shrank) — the segment is skipped, not deleted.
public func fretRatio(_ segment: FretSegment,
                      degrees: [(ratio: Double, label: String)]) -> Double? {
    guard segment.degreeIndex >= 0,
          segment.degreeIndex < degrees.count else { return nil }
    return degrees[segment.degreeIndex].ratio
}

// MARK: - Band

/// The playable **band**: full width, `Config.fretPadHeightFraction` of the
/// height, centered; above/below is dead except the drone buttons.
public func fretPadBandRect(in size: CGSize) -> CGRect {
    let h = size.height * Config.fretPadHeightFraction
    return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
}

// MARK: - Drone buttons

/// The drone buttons' hit rectangles in FULL-surface touch space (right-edge
/// column, upper quarter), shared by both platforms' visuals and hit-tests.
/// Inside the surface, claimed at onset only, so the right edge stays playable.
public func droneButtonRects(size: CGSize) -> [CGRect] {
    let w: CGFloat = 56
    let spacing: CGFloat = 8
    let top: CGFloat = 4
    let x = size.width - w - 2
    // Height = a quarter of the upper half; the stack of 3 starts half a
    // pitch down so it is centred on the upper quarter.
    let h = max(20, (size.height * 0.5 - top - 3 * spacing) / 4)
    let y0 = top + (h + spacing) / 2
    return (0..<FretArrangement.droneCount).map { i in
        CGRect(x: x, y: y0 + CGFloat(i) * (h + spacing), width: w, height: h)
    }
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
    public let name: String
    public let x: CGFloat
    public let topY: CGFloat
    public let bottomY: CGFloat

    public init(id: String, segmentID: UUID, isGhost: Bool, ratio: Double,
                name: String, x: CGFloat, topY: CGFloat, bottomY: CGFloat) {
        self.id = id; self.segmentID = segmentID; self.isGhost = isGhost
        self.ratio = ratio; self.name = name; self.x = x
        self.topY = topY; self.bottomY = bottomY
    }
}

/// Every enabled segment as a `FretPlacement` per visible octave copy (shift
/// 0 = the editable base fret, ±k = ghosts one band over), in the surface's
/// logical pixel space (pre-`edgePad`).
public func fretPlacements(arrangement: FretArrangement,
                           degrees: [(ratio: Double, label: String)],
                           size: CGSize) -> [FretPlacement] {
    let extent = max(0, arrangement.ghostExtentOctaves)
    let shifts = Int(extent.rounded(.up))
    var out: [FretPlacement] = []
    for segment in arrangement.segments where segment.enabled {
        guard let baseRatio = fretRatio(segment, degrees: degrees) else { continue }
        for shift in -shifts...shifts {
            let x = fretPixelX(forBandX: segment.x + Double(shift),
                               ghostExtentOctaves: extent, width: size.width)
            guard x >= -1, x <= size.width + 1 else { continue }
            let ratio = baseRatio * pow(2.0, Double(shift))
            let id = shift == 0
                ? segment.id.uuidString
                : "\(segment.id.uuidString)#\(shift)"
            out.append(FretPlacement(id: id, segmentID: segment.id,
                                     isGhost: shift != 0, ratio: ratio,
                                     name: scaleLabel(degree: segment.degreeIndex,
                                                      octave: shift,
                                                      degrees: degrees), x: x,
                                     topY: CGFloat(segment.topY) * size.height,
                                     bottomY: CGFloat(segment.bottomY) * size.height))
        }
    }
    return out
}

// MARK: - Pitch field

/// Frets closer than this (px) share one **column** in the pitch field, so a
/// fret nudged a hair off another doesn't create a sliver-thin glide zone.
let fretColumnEps: CGFloat = 0.5

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

/// Inverse of `fretWarp` on [0, 1] (the contour solver).
public func fretWarpInverse(_ w: Double, amount: Double) -> Double {
    guard amount > 1e-6 else { return w }
    let g = fretWarpMaxGain * min(amount, 1)
    let s0 = 1.0 / (1.0 + exp(g / 2))
    let s1 = 1.0 - s0
    let s = min(max(s0 + w * (s1 - s0), 1e-12), 1 - 1e-12)
    return 0.5 + log(s / (1 - s)) / g
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

/// log2 pitch of the fret field at `pt`: each **column** (frets within
/// `fretColumnEps`) resolves its pitch at the touch's y (`fretColumnLog`),
/// and the field interpolates log-pitch between the columns flanking `pt.x`
/// (extrapolating beyond the outermost). Continuous, exact on a fret line.
/// `warp` (`ctl_fret_warp`, 0…1) shapes every blend through `fretWarp`; 0 is
/// exactly linear. `nil` with no frets.
public func fretFieldLog(at pt: CGPoint,
                         placements: [FretPlacement],
                         warp: Double = 0) -> Double? {
    guard !placements.isEmpty else { return nil }
    let columns = fretColumnXs(placements)
    func pitch(atColumn cx: CGFloat) -> Double {
        fretColumnLog(atY: pt.y, columnX: cx, placements: placements, warp: warp)
    }
    guard columns.count >= 2 else { return pitch(atColumn: columns[0]) }
    // The pair the touch's x falls between — or the outermost pair, whose
    // line extrapolates past the edges (t outside 0..1).
    let upper = columns.firstIndex(where: { $0 > pt.x }) ?? columns.count
    let i = min(max(upper - 1, 0), columns.count - 2)
    let (a, b) = (columns[i], columns[i + 1])
    let l = pitch(atColumn: a)
    let r = pitch(atColumn: b)
    let t = Double((pt.x - a) / (b - a))
    let tw = (t >= 0 && t <= 1) ? fretWarp(t, amount: warp) : t
    return l + (r - l) * tw
}

/// A column's log2 pitch at `y`: a fret's pitch inside its extent, a
/// `fretWarp`-shaped blend between stacked frets, clamped beyond the ends.
func fretColumnLog(atY y: CGFloat, columnX cx: CGFloat,
                   placements: [FretPlacement], warp: Double = 0) -> Double {
    var inside: FretPlacement? = nil       // extent contains y, nearest center
    var above: FretPlacement? = nil        // bottomY ≤ y, greatest bottomY
    var below: FretPlacement? = nil        // topY ≥ y, smallest topY
    for p in placements where abs(p.x - cx) <= fretColumnEps {
        if p.topY <= y && y <= p.bottomY {
            if let cur = inside {
                let dCur = abs((cur.topY + cur.bottomY) / 2 - y)
                let dNew = abs((p.topY + p.bottomY) / 2 - y)
                if dNew < dCur { inside = p }
            } else {
                inside = p
            }
        } else if p.bottomY < y {
            if above == nil || p.bottomY > above!.bottomY { above = p }
        } else if below == nil || p.topY < below!.topY {
            below = p
        }
    }
    if let inside { return log2(inside.ratio) }
    switch (above, below) {
    case (let a?, let b?):
        let gap = b.topY - a.bottomY
        guard gap > 1e-6 else { return log2(a.ratio) }
        let t = fretWarp(Double((y - a.bottomY) / gap), amount: warp)
        return log2(a.ratio) + (log2(b.ratio) - log2(a.ratio)) * t
    case (let a?, nil):
        return log2(a.ratio)
    case (nil, let b?):
        return log2(b.ratio)
    case (nil, nil):
        return 0   // unreachable: the column was picked from `placements`
    }
}

// MARK: - Field contours (edit-mode visualization)

/// One iso-pitch contour polyline at log2 pitch `level`; `isBoundary` marks
/// the log-midpoints between adjacent pitches vs the quarter-pitch lines.
public struct FretFieldContour {
    public let level: Double
    public let isBoundary: Bool
    public let points: [CGPoint]

    public init(level: Double, isBoundary: Bool, points: [CGPoint]) {
        self.level = level; self.isBoundary = isBoundary; self.points = points
    }
}

/// Solve the iso-pitch contours exactly: per scanline and column pair the
/// field is `l + (r − l) · fretWarp(t)`, so a crossing sits at
/// `x = a + fretWarpInverse((c−l)/(r−l)) · (b−a)`. Polylines are per (level,
/// region), split where the level leaves the region.
public func fretFieldContours(placements: [FretPlacement], size: CGSize,
                              warp: Double,
                              ySamples: Int = 64) -> [FretFieldContour] {
    let columns = fretColumnXs(placements)
    guard columns.count >= 2, size.height > 0, ySamples >= 2 else { return [] }

    // Distinct sounding log-pitches, ascending.
    var pitches: [Double] = []
    for p in placements.map({ log2($0.ratio) }).sorted()
    where pitches.last.map({ p - $0 > 1e-6 }) ?? true {
        pitches.append(p)
    }
    guard pitches.count >= 2 else { return [] }

    // Contour levels between each adjacent pitch pair.
    var levels: [(level: Double, isBoundary: Bool)] = []
    for i in 0..<(pitches.count - 1) {
        let (lo, hi) = (pitches[i], pitches[i + 1])
        levels.append((lo + 0.25 * (hi - lo), false))
        levels.append(((lo + hi) / 2, true))
        levels.append((lo + 0.75 * (hi - lo), false))
    }

    // Column pitches per scanline, computed once and shared by every level.
    let ys = (0...ySamples).map {
        CGFloat($0) / CGFloat(ySamples) * size.height
    }
    let columnLogs: [[Double]] = ys.map { y in
        columns.map {
            fretColumnLog(atY: y, columnX: $0, placements: placements,
                          warp: warp)
        }
    }

    var out: [FretFieldContour] = []
    // Regions: -1 = left extrapolation, 0..count-2 = pairs, count-1 = right.
    for region in -1...(columns.count - 1) {
        let pair = min(max(region, 0), columns.count - 2)
        let (a, b) = (columns[pair], columns[pair + 1])
        for (level, isBoundary) in levels {
            var run: [CGPoint] = []
            func flush() {
                if run.count >= 2 {
                    out.append(FretFieldContour(level: level,
                                                isBoundary: isBoundary,
                                                points: run))
                }
                run.removeAll(keepingCapacity: true)
            }
            for (yi, y) in ys.enumerated() {
                let l = columnLogs[yi][pair]
                let r = columnLogs[yi][pair + 1]
                guard abs(r - l) > 1e-9 else { flush(); continue }
                let w = (level - l) / (r - l)
                let t: Double
                switch region {
                case -1:                    // left of the first column
                    guard w < 0 else { flush(); continue }
                    t = w                   // linear extrapolation
                case columns.count - 1:     // right of the last column
                    guard w > 1 else { flush(); continue }
                    t = w
                default:
                    guard w >= 0, w <= 1 else { flush(); continue }
                    t = fretWarpInverse(w, amount: warp)
                }
                let x = a + CGFloat(t) * (b - a)
                guard x >= 0, x <= size.width else { flush(); continue }
                run.append(CGPoint(x: x, y: y))
            }
            flush()
        }
    }
    return out
}

// MARK: - Onset snap

/// The fret a touch **onset** at `pt` snaps to: the nearest in x within
/// `snapDistance` px whose extent contains `pt.y`; `nil` = play the field
/// pitch (the approach path). Onset only — drags never re-snap.
public func fretSnap(at pt: CGPoint, placements: [FretPlacement],
                     snapDistance: CGFloat) -> FretPlacement? {
    var best: FretPlacement? = nil
    var bestDx = CGFloat.greatestFiniteMagnitude
    for p in placements {
        guard pt.y >= p.topY, pt.y <= p.bottomY else { continue }
        let dx = abs(pt.x - p.x)
        guard dx <= snapDistance, dx < bestDx else { continue }
        best = p
        bestDx = dx
    }
    return best
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

/// What a press grabs: a segment to move, an endpoint handle, or nothing.
/// Editing operates on base placements only (`!isGhost`).
public enum FretGrab: Equatable {
    case move(UUID)
    case resizeTop(UUID)
    case resizeBottom(UUID)
    case none
}

/// Classify a press: near a fret's top/bottom endpoint moves that endpoint;
/// on the line between them moves the whole segment; otherwise `.none`.
public func fretGrab(at pt: CGPoint, placements: [FretPlacement],
                     handleRadius r: CGFloat) -> FretGrab {
    for p in placements {
        if abs(pt.x - p.x) > r { continue }
        if abs(pt.y - p.topY) <= r { return .resizeTop(p.segmentID) }
        if abs(pt.y - p.bottomY) <= r { return .resizeBottom(p.segmentID) }
        if pt.y > p.topY && pt.y < p.bottomY { return .move(p.segmentID) }
    }
    return .none
}
