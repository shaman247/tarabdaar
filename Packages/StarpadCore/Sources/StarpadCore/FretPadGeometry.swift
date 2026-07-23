import CoreGraphics
import Foundation

// MARK: - Fret Pad geometry
//
// The **Fret Pad** is a fourth 2D playing surface (StarpadMac tab): the scale's
// pitches drawn as vertical **line segments** (frets). Unlike the String Pad's
// evenly-spaced columns, a fret's **x-position IS its pitch** — `log2(ratio)`
// mapped across the surface, exactly like the Pitch Pad's x-axis — so the
// surface is a continuous fretless ribbon with visual frets on it.
//
// Playing: a touch that **starts** within `snapDistance` px of a fret *and*
// within the fret's vertical extent snaps to that fret's exact pitch; a touch
// starting above/below the fret (or in open space) plays the raw x-mapped
// pitch — that's how you approach a note from below/above (meend). After the
// onset the drag is always continuous: the ratio follows the cursor x plus the
// constant log-offset captured at the snap, so a snapped onset stays true while
// vibrato/glides move relative to it. Snapping never re-engages mid-drag.
//
// Layout: each enabled scale degree gets one editable base segment in the
// centre octave; the ribbon extends `ghostExtentOctaves` (default 0.5 → a
// 2-octave ribbon, matching the Pitch Pad's half-octave flanks) past the base
// octave on each side, filled with read-only octave-repeat ghost copies
// (clipped to the visible range), sharing the base segment's vertical extent.
// The default arrangement mirrors the String Pad's svara split: S and P
// centered, shuddha (natural) degrees in the lower middle, komal/tivra in the
// upper middle.
//
// Platform-independent (no SwiftUI), Mac-only. Reuses `PitchPadEngine` (MPE),
// `VoronoiCell`/`DisplaySeed` (to drive `CellFillsView`), `pitchColor`, and the
// sargam helpers from `StringPadGeometry`. See `docs/fret-pad.md`.

// MARK: - Model

/// One fret: a vertical line segment whose pitch is a `degreeIndex` into the
/// enabled Pitch Pad scale degrees (low→high). `topY`/`bottomY` (0..1,
/// 0 = top of the pad) bound its vertical extent — the zone where a touch
/// onset snaps to it. Its x-position is derived from the degree's ratio, never
/// stored. `id` is per-process (minted on decode), like `PitchPoint.id`.
public struct FretSegment: Identifiable, Equatable {
    public let id: UUID
    public var degreeIndex: Int
    public var topY: Double
    public var bottomY: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), degreeIndex: Int, topY: Double,
                bottomY: Double, enabled: Bool = true) {
        self.id = id
        self.degreeIndex = degreeIndex
        let t = min(max(0, topY), 1)
        let b = min(max(0, bottomY), 1)
        self.topY = min(t, b)
        self.bottomY = max(t, b)
        self.enabled = enabled
    }

    public var height: Double { bottomY - topY }
}

/// The whole surface: the editable base-octave `segments` plus how far the
/// ribbon extends past the base octave on each side (`ghostExtentOctaves`,
/// fractional — 0.5 = half an octave of flank each side, i.e. a 2-octave
/// ribbon). The flanks show read-only octave-repeat ghost copies (clipped to
/// the visible range), sharing each base segment's vertical extent, faint in
/// edit mode.
public struct FretArrangement: Equatable {
    public var segments: [FretSegment]
    public var ghostExtentOctaves: Double
    /// Tap legato (default on): consecutive taps become one continuous voice
    /// — a tap while the previous note sounds (or within the release grace
    /// window) glides the voice to the new pitch instead of retriggering.
    /// Mono, last-note priority while on. See `FretLegato`.
    public var legato: Bool

    public init(segments: [FretSegment], ghostExtentOctaves: Double = 0.5,
                legato: Bool = true) {
        self.segments = segments
        self.ghostExtentOctaves = max(0, min(2, ghostExtentOctaves))
        self.legato = legato
    }

    /// Octaves the ribbon spans: the base octave plus the flanks each side.
    public var octaveSpan: Double { 1 + 2 * max(0, ghostExtentOctaves) }

    /// The default arrangement, mirroring the String Pad's svara split: one
    /// fret per enabled degree — **S and P** tall and centered, **shuddha**
    /// (natural) degrees in the bottom half, **komal/tivra** in the top half —
    /// so approaches from open space above/below each fret stay available.
    public static func defaultArrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        var segments: [FretSegment] = []
        for (i, deg) in degrees.enumerated() {
            let semis = Int((12.0 * log2(deg.ratio)).rounded())
            let pc = ((semis % 12) + 12) % 12
            // The off-center bands sit close to the middle (centers 0.66 /
            // 0.34, like the String Pad's paired keys), leaving open approach
            // space toward the pad edges.
            let band: (top: Double, bottom: Double)
            switch pc {
            case 0, 7:            band = (0.39, 0.61)     // S, P — centered
            case 2, 4, 5, 9, 11:  band = (0.565, 0.755)   // shuddha — lower middle
            default:              band = (0.245, 0.435)   // komal/tivra — upper middle
            }
            segments.append(FretSegment(degreeIndex: i, topY: band.top,
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

// MARK: - x ↔ pitch mapping

/// log2(ratio) of the pitch at pixel `x`: the ribbon spans
/// `[-extent, 1 + extent]` octaves linearly across `width`.
public func fretLogRatio(atX x: CGFloat, ghostExtentOctaves: Double,
                         width: CGFloat) -> Double {
    let extent = max(0, ghostExtentOctaves)
    let span = 1.0 + 2.0 * extent
    return Double(x / max(1, width)) * span - extent
}

/// Pixel x of `logRatio` (log2 units above the base tonic) on the ribbon.
public func fretX(forLogRatio logRatio: Double, ghostExtentOctaves: Double,
                  width: CGFloat) -> CGFloat {
    let extent = max(0, ghostExtentOctaves)
    let span = 1.0 + 2.0 * extent
    return CGFloat((logRatio + extent) / span) * width
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
/// copy — shift 0 is the editable base fret, ±k are the read-only ghost
/// repeats, clipped to the visible ribbon — in the surface's logical pixel
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
            let logX = log2(baseRatio) + Double(shift)
            let x = fretX(forLogRatio: logX, ghostExtentOctaves: extent,
                          width: size.width)
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

// MARK: - Onset snap

/// The fret a touch **onset** at `pt` snaps to: the nearest fret (in x) within
/// `snapDistance` px whose vertical extent contains `pt.y`. `nil` when the
/// touch is above/below every nearby fret or in open space — the caller plays
/// the raw x-mapped pitch instead (that's the approach path). Only called at
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

/// What a press at `pt` grabs: a segment to move vertically, one of its
/// endpoint handles, or nothing. (Editing operates on base placements only —
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
