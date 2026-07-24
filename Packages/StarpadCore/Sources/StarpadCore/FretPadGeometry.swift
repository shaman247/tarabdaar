import CoreGraphics
import Foundation

// MARK: - Fret Pad geometry
//
// The **Fret Pad** is the sole 2D playing surface: the scale's pitches drawn
// as vertical **line segments** (frets) that are **freely positioned** — a
// fret's `x` is its own layout state (0..1 across the base band), not derived
// from its pitch. The playable pitch surface is a continuous **field**
// interpolated from the frets: between the two **closest fret columns
// horizontally** — each column's pitch resolved by the touch's y (exact
// inside a fret, y-blended between stacked variants like r/R), then a
// linear log-pitch x-interpolation between the flanking columns
// (`fretFieldLog`).
//
// Playing: a touch that **starts** within `snapDistance` px of a fret *and*
// within the fret's vertical extent snaps to that fret's exact pitch; a touch
// starting elsewhere plays the field pitch — that's how you approach a note
// from open space (meend). After the onset the drag is always continuous:
// the pitch follows the field at the cursor plus the constant log-offset
// captured at the snap, so a snapped onset stays true while vibrato/glides
// move relative to it. Snapping never re-engages mid-drag.
//
// Layout: the editable base segments live in a central **band**; the surface
// extends `ghostExtentOctaves` band-widths past it on each side (default
// 0.5 → the flanks show half a band each), tiled with read-only copies of the
// whole base layout playing an octave down (left) / up (right), clipped to
// the visible range. The default arrangement mirrors the String Pad: 7
// evenly-spaced columns — S and P centered, shuddha (R G m D N) along the
// bottom band, komal/tivra (r g M d n) along the top.
//
// Platform-independent (no SwiftUI). Reuses `PitchPadEngine` (MPE),
// `VoronoiCell`/`DisplaySeed` (to drive `CellFillsView`), `pitchColor`, and
// the sargam helpers from `ScaleDegrees.swift`. See `docs/fret-pad.md`.

// MARK: - Model

/// One fret: a vertical line segment whose pitch is a `degreeIndex` into the
/// enabled Pitch Pad scale degrees (low→high). `x` (0..1 across the base
/// band) positions it horizontally — **free**, unrelated to its pitch.
/// `topY`/`bottomY` (0..1, 0 = top of the pad) bound its vertical extent —
/// the zone where a touch onset snaps to it. `id` is per-process (minted on
/// decode), like `PitchPoint.id`.
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

/// The whole surface: the editable base-band `segments` plus how far the
/// surface extends past the base band on each side (`ghostExtentOctaves`,
/// fractional band-widths — 0.5 = half a band of flank each side). The
/// flanks show read-only octave-repeat copies of the whole base layout
/// (clipped to the visible range), faint in edit mode.
public struct FretArrangement: Equatable {
    public var segments: [FretSegment]
    public var ghostExtentOctaves: Double
    /// Tap legato (default on): consecutive taps become one continuous voice
    /// — a tap while the previous note sounds (or within the release grace
    /// window) glides the voice to the new pitch instead of retriggering.
    /// Mono, last-note priority while on. See `FretLegato`.
    public var legato: Bool
    /// The 4 drone buttons' pitches as ratios vs the tonic (2026-07-23):
    /// press-to-sound jawari-taraf drones along the surface's right edge,
    /// played with the free hand. Each maps to an EXISTING taraf row at
    /// press time (pitch-class first, then nearest octave —
    /// `BowEngine.droneRow`). Default ,Sa · ,Ma · ,Pa · Sa (an octave
    /// below the tonic octave).
    public var droneRatios: [Double]

    public static let defaultDroneRatios = [0.5, 2.0 / 3.0, 3.0 / 4.0, 1.0]

    public init(segments: [FretSegment], ghostExtentOctaves: Double = 0.5,
                legato: Bool = true,
                droneRatios: [Double] = FretArrangement.defaultDroneRatios) {
        self.segments = segments
        self.ghostExtentOctaves = max(0, min(2, ghostExtentOctaves))
        self.legato = legato
        var r = droneRatios.map { max(0.25, min(4.0, $0)) }
        if r.count != 4 { r = FretArrangement.defaultDroneRatios }
        self.droneRatios = r
    }

    /// Band-widths the surface spans: the base band plus the flanks each side.
    public var octaveSpan: Double { 1 + 2 * max(0, ghostExtentOctaves) }

    /// The default arrangement, mirroring the String Pad: **7 evenly-spaced
    /// columns** — S · R/r · G/g · m/M · P · D/d · N/n. **S and P** centered,
    /// **shuddha** (natural) degrees along the bottom band, **komal/tivra**
    /// along the top — so approaches from open space above/below each fret
    /// stay available.
    public static func defaultArrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        // Column per svara (pitch class): S | R/r | G/g | m/M | P | D/d | N/n.
        let columnForPC = [0: 0, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3,
                           7: 4, 8: 5, 9: 5, 10: 6, 11: 6]
        var segments: [FretSegment] = []
        for (i, deg) in degrees.enumerated() {
            let semis = Int((12.0 * log2(deg.ratio)).rounded())
            let pc = ((semis % 12) + 12) % 12
            let x = (Double(columnForPC[pc] ?? 0) + 0.5) / 7.0
            // The off-center bands sit close to the middle (centers 0.66 /
            // 0.34, like the String Pad's paired keys), leaving open approach
            // space toward the pad edges.
            let band: (top: Double, bottom: Double)
            switch pc {
            case 0, 7:            band = (0.39, 0.61)     // S, P — centered
            case 2, 4, 5, 9, 11:  band = (0.565, 0.755)   // shuddha — lower middle
            default:              band = (0.245, 0.435)   // komal/tivra — upper middle
            }
            segments.append(FretSegment(degreeIndex: i, x: x, topY: band.top,
                                        bottomY: band.bottom))
        }
        return FretArrangement(segments: segments)
    }
}

/// The ratio a segment plays in the base octave. `nil` if its `degreeIndex`
/// is out of range (the scale shrank) — the segment is skipped, not deleted,
/// same rule as the String Pad's `noteRatio`.
public func fretRatio(_ segment: FretSegment,
                      degrees: [(ratio: Double, label: String)]) -> Double? {
    guard segment.degreeIndex >= 0,
          segment.degreeIndex < degrees.count else { return nil }
    return degrees[segment.degreeIndex].ratio
}

// MARK: - Drone buttons

/// The 4 drone buttons' hit rectangles in the surface's padded touch space:
/// a right-edge column from the top down to the vertical center. Shared by
/// both platforms' visual layers and touch hit-tests so they can never
/// disagree. The buttons live INSIDE the playing surface (claimed at touch
/// ONSET only) — a separate side column would make the whole right edge
/// dead space and swallow touches aimed at the rightmost fret.
public func droneButtonRects(size: CGSize) -> [CGRect] {
    let w: CGFloat = 56
    let spacing: CGFloat = 8
    let top: CGFloat = 4
    let x = size.width - w - 2
    let h = max(20, (size.height * 0.5 - top - 3 * spacing) / 4)
    return (0..<4).map { i in
        CGRect(x: x, y: top + CGFloat(i) * (h + spacing), width: w, height: h)
    }
}

// MARK: - Band ↔ pixel mapping

/// Pixel x of band coordinate `u` (0..1 spans the base band; `u + k` is the
/// same position in octave copy `k`). The surface spans `[-extent, 1+extent]`
/// band units linearly across `width`.
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

/// A fret resolved to pixel space for one frame: its `x`, vertical extent, the
/// live (octave-shifted) `ratio`, and the sargam `name`. Ghost copies get an
/// octave suffix on `id` so they don't collide with the base fret.
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

/// Resolve every enabled segment to a `FretPlacement` per visible octave
/// copy — shift 0 is the editable base fret in the central band, ±k are the
/// read-only ghost repeats of the whole layout one band over (an octave
/// down/up), clipped to the visible surface — in the surface's logical pixel
/// space (pre-`edgePad`).
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
                                     name: sargamName(forRatio: ratio), x: x,
                                     topY: CGFloat(segment.topY) * size.height,
                                     bottomY: CGFloat(segment.bottomY) * size.height))
        }
    }
    return out
}

// MARK: - Pitch field

/// Frets closer together than this (px) count as one **column** for the
/// pitch field — stacked variants (r over R) share a column, and a fret
/// nudged a hair off another doesn't create a sliver-thin glide zone.
let fretColumnEps: CGFloat = 0.5

/// log2 pitch of the fret field at `pt` — the simplest model that respects
/// the layout: **interpolate between the closest fret columns horizontally**.
///
///   1. A **column** = the frets sharing an x (within `fretColumnEps`).
///      Its pitch at the touch's y (`fretColumnLog`): **inside** a fret's
///      vertical extent → exactly that fret's pitch; **between** two stacked
///      frets → a linear y-interpolation across the gap (so between r and R
///      you get the blend); **above/below** the column's frets → clamped to
///      the nearest one.
///   2. The field at `pt` = the linear log-pitch x-interpolation between the
///      nearest column at-or-left of `pt.x` and the nearest column right of
///      it. Beyond the outermost columns the line through the outermost
///      PAIR extrapolates (the edges keep the local slope instead of going
///      flat); with a single column its pitch holds everywhere.
///
/// Continuous everywhere: crossing a column, both sides agree on the
/// column's own pitch; within a column, the y-interpolation is continuous;
/// and only the two flanking columns ever matter, so pitch always moves
/// TOWARD the neighbor you're dragging at — never toward the layout's mean
/// (the failure of the earlier global inverse-distance blends). Exactly a
/// fret's pitch on the fret line (inside its extent). `nil` with no frets.
public func fretFieldLog(at pt: CGPoint,
                         placements: [FretPlacement]) -> Double? {
    guard !placements.isEmpty else { return nil }
    // Distinct column x's, ascending (frets within `fretColumnEps` share one).
    var columns: [CGFloat] = []
    for x in placements.map(\.x).sorted()
    where columns.last.map({ x - $0 > fretColumnEps }) ?? true {
        columns.append(x)
    }
    func pitch(atColumn cx: CGFloat) -> Double {
        fretColumnLog(atY: pt.y, columnX: cx, placements: placements)
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
    return l + (r - l) * t
}

/// A column's log2 pitch at height `y`: exactly a member fret's pitch inside
/// its vertical extent (overlapping extents: nearest center wins), a linear
/// y-interpolation across the gap between two stacked frets, and clamped to
/// the nearest fret beyond the column's ends. Continuous in `y`.
func fretColumnLog(atY y: CGFloat, columnX cx: CGFloat,
                   placements: [FretPlacement]) -> Double {
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
        let t = Double((y - a.bottomY) / gap)
        return log2(a.ratio) + (log2(b.ratio) - log2(a.ratio)) * t
    case (let a?, nil):
        return log2(a.ratio)
    case (nil, let b?):
        return log2(b.ratio)
    case (nil, nil):
        return 0   // unreachable: the column was picked from `placements`
    }
}

// MARK: - Onset snap

/// The fret a touch **onset** at `pt` snaps to: the nearest fret (in x) within
/// `snapDistance` px whose vertical extent contains `pt.y`. `nil` when the
/// touch is above/below every nearby fret or in open space — the caller plays
/// the field pitch instead (that's the approach path). Only called at
/// onset; drags never re-snap.
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

/// Wrap each fret as a thin-rectangle `VoronoiCell` (stable id, live ratio) so
/// the shared `CellFillsView` glows the snapped fret keyed by
/// `engine.sounding.weights` — same mechanism as the String Pad's hexagons.
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

/// What a press at `pt` grabs: a segment to move, one of its endpoint
/// handles, or nothing. (Editing operates on base placements only —
/// pass `placements` filtered to `!isGhost`.)
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
