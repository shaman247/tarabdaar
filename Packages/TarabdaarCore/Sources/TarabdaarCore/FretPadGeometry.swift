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
// the visible range. The default arrangement is **pitch-aligned**: a fret's
// x is `log2(ratio)`, so position = frequency and the octave ghosts tile
// continuously — a piano-like ribbon, S and P centered, shuddha (R G m D N)
// hanging lower, komal/tivra (r g M d n) standing higher, and every fret
// crossing the band's centre line.
//
// Platform-independent (no SwiftUI). Reuses `PitchPadEngine` (MPE),
// `VoronoiCell`/`DisplaySeed` (to drive `CellFillsView`), `pitchColor`, and
// the scale-label helpers from `ScaleDegrees.swift`. See `docs/fret-pad.md`.

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
    /// The 3 drone buttons' DISPLAY pitches as ratios vs the played tonic
    /// (2026-07-23; 4 → 3 slots and display-only 2026-07-25). Each button
    /// plucks a sympathetic string mapped in the Strings tab
    /// (`InstrumentState.droneStringIds`); these ratios only drive the
    /// button labels/colors on both surfaces — the Mac derives them from
    /// the mapped strings' sounding pitches and they ride the ordinary
    /// arrangement autosave + iPad sync. Default ,Sa · ,Pa · Sa.
    public var droneRatios: [Double]

    /// The number of drone buttons/slots — the ONE count the geometry, the
    /// sync blob, the CC range (102...102+count-1) and the Strings tab's
    /// drone-string slots all derive from.
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

    /// `FretLayoutPreset.equalFreq` ("C Equal Freq") — the non-default
    /// built-in (the name is historic; `keyboardArrangement` is the
    /// default and what every reset builds, 2026-08-12):
    /// **pitch-aligned x** — a fret sits at
    /// `log2(ratio)` across the base band, so its horizontal position IS its
    /// frequency (log-frequency, the app's pitch space) and the octave ghosts
    /// at `x ± 1` tile the ribbon continuously. Vertically the svaras keep
    /// three tiers, but **every fret now crosses the band's centre line**, so
    /// a horizontal drag down the middle passes through the extent of every
    /// fret and can snap to any of them:
    ///
    /// - **komal/tivra** (r g M d n) — the upper tier (0.108–0.460)
    /// - **shuddha** (R G m D N) — the lower tier (0.540–0.892)
    /// - **P** — lower tier, longer (0.510–0.912)
    /// - **S** — lower tier, longer still (0.470–0.912)
    ///
    /// The ordinary frets are all the **same height** (0.352); S and P sit
    /// with the lower tier but run a little **lower** than it (0.912), and S
    /// reaches **higher** than P — the tonic is the long key. The two tiers
    /// are fully **separated**: the upper ends at 0.460, the lower starts at
    /// 0.540, no shared endpoint anywhere, and S's top (0.470) pokes into
    /// that gap without touching the tier above.
    ///
    /// With a 12-degree scale that reads like a piano keyboard tonic-on-C:
    /// the komal/tivra frets are the black keys, standing higher and sitting
    /// between their neighbours at their own pitch.
    public static func defaultArrangement(
        degrees: [(ratio: Double, label: String)]) -> FretArrangement {
        var segments: [FretSegment] = []
        for (i, deg) in degrees.enumerated() {
            guard deg.ratio > 0 else { continue }
            // x IS the pitch: 0 at the tonic, 1 an octave up (the band's
            // width). `FretSegment.init` clamps a degree outside [1, 2).
            let x = log2(deg.ratio)
            let semis = Int((12.0 * log2(deg.ratio)).rounded())
            let pc = ((semis % 12) + 12) % 12
            // One height (0.352) for the ordinary frets; the two tiers are
            // separated by a clear 0.460–0.540 band (no shared endpoint, so
            // no y belongs to both). S and P join the LOWER tier and are the
            // long keys — a little lower than their neighbours, S higher at
            // the top than P, its tip inside the gap but clear of the tier
            // above. Sized for the half-height surface band
            // (`Config.fretPadHeightFraction`).
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

    /// `FretLayoutPreset.keyboard` ("C Keyboard") — the DEFAULT layout
    /// (again, 2026-08-11 — it was the default until 2026-08-02 too): a
    /// fresh install's starter arrangement on both Mac and iPad, and what
    /// "Reset to Scale" / "Reset to Default" build (2026-08-12). Plays
    /// like a **piano keyboard**: **7 evenly-spaced columns**, one per svara —
    /// `x = (col + 0.5)/7` for S · R/r · G/g · m/M · P · D/d · N/n — so the
    /// naturals are equally spaced like white keys and the komal/tivra frets
    /// **stack above** their shuddha partner in the same column (the black
    /// key over the white one) rather than taking a position of their own.
    /// The pitch field y-interpolates inside a stacked column, so sliding up
    /// the column bends r → R.
    ///
    /// - **S and P** (pc 0, 7): centred (0.324–0.676)
    /// - **shuddha** (R G m D N): lower middle (0.588–0.892)
    /// - **komal/tivra** (r g M d n): upper middle (0.108–0.412)
    ///
    /// The 0.176 gap between a stacked pair is the y-interpolation zone;
    /// the space toward the pad's top/bottom edges is open approach room.
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

/// The **built-in fret layouts**, offered in the Fret Pad's Layout menu
/// beside the player's saved ones (`FretArrangementStore`). Both are built
/// from the CURRENT scale's degrees, so they follow whatever scale is
/// loaded — they differ only in where the frets are put.
public enum FretLayoutPreset: String, CaseIterable, Identifiable {
    /// Pitch-aligned: `x = log2(ratio)`, one fret per degree at its own
    /// frequency, komal/tivra standing higher, S and P the long keys.
    case equalFreq
    /// The default layout (2026-08-11): 7 evenly-spaced svara columns with
    /// the komal/tivra frets stacked above their shuddha partners — white
    /// keys evenly spaced, black keys above them. "Reset to Scale" and
    /// "Reset to Default" build this one.
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
/// is out of range (the scale shrank) — the segment is skipped, not deleted,
/// same rule as the String Pad's `noteRatio`.
public func fretRatio(_ segment: FretSegment,
                      degrees: [(ratio: Double, label: String)]) -> Double? {
    guard segment.degreeIndex >= 0,
          segment.degreeIndex < degrees.count else { return nil }
    return degrees[segment.degreeIndex].ratio
}

// MARK: - Band

/// The playable **band** within the full surface: full width,
/// `Config.fretPadHeightFraction` of the height, vertically centered. The
/// fret arrangement's normalized coordinates span this rect; the space
/// above/below is dead — only the drone buttons (positioned in FULL-surface
/// space, `droneButtonRects`) live there. Shared by both platforms so the
/// Mac tab mirrors the iPad exactly.
public func fretPadBandRect(in size: CGSize) -> CGRect {
    let h = size.height * Config.fretPadHeightFraction
    return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
}

// MARK: - Drone buttons

/// The 3 drone buttons' hit rectangles in the FULL surface's padded touch
/// space (independent of the fret band — the buttons keep the position they
/// had when the surface was all band): a right-edge column around the upper
/// quarter. Shared by both platforms' visual layers and touch hit-tests so
/// they can never disagree. The buttons live INSIDE the playing surface
/// (claimed at touch ONSET only) — a separate side column would make the
/// whole right edge dead space and swallow touches aimed at the rightmost
/// fret.
public func droneButtonRects(size: CGSize) -> [CGRect] {
    let w: CGFloat = 56
    let spacing: CGFloat = 8
    let top: CGFloat = 4
    let x = size.width - w - 2
    // Button size keeps the original 4-slot column's (which ran top →
    // vertical center); the 3-button stack starts half a button pitch
    // lower so its vertical center sits where the 4-button column's did.
    let h = max(20, (size.height * 0.5 - top - 3 * spacing) / 4)
    let y0 = top + (h + spacing) / 2
    return (0..<FretArrangement.droneCount).map { i in
        CGRect(x: x, y: y0 + CGFloat(i) * (h + spacing), width: w, height: h)
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
/// live (octave-shifted) `ratio`, and its `name` — the scale's own label for
/// the degree, with `'`/`,` octave marks on the repeats. Ghost copies get an
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
                                     name: scaleLabel(degree: segment.degreeIndex,
                                                      octave: shift,
                                                      degrees: degrees), x: x,
                                     topY: CGFloat(segment.topY) * size.height,
                                     bottomY: CGFloat(segment.bottomY) * size.height))
        }
    }
    return out
}

// MARK: - Auto-vibrato zone (fret linger)

/// Which end of a fret is its **outer** end — the auto-vibrato zone (the
/// wire's `fretY` runs 0 at the inner end → 1 at the outer end). Frets
/// whose centre sits in the band's upper half open **upward** (top 30%);
/// frets at or below the band's centre-line open **downward**. Shared by
/// both surfaces so the zone marking, the streamed `fretY` and the Mac
/// preview can never disagree.
public func fretOuterEndIsTop(topY: CGFloat, bottomY: CGFloat,
                              bandHeight: CGFloat) -> Bool {
    (topY + bottomY) / 2 < bandHeight / 2
}

/// Fraction of a fret's length, from its INNER (band-centre-side) end,
/// with no auto-vibrato — the surfaces' zone marking. Mirrors the shipped
/// default of `bow_avib_dead` (the Mac's parameter is the live truth; the
/// drawing does not track edits to it).
public let fretVibratoDeadFraction: CGFloat = 0.7

/// The fret's line as a polyline: a straight run over the dead zone, then
/// a **wavy tail** over the outer vibrato zone — the "slight indicator"
/// both surfaces draw (the wave grows toward the tip, echoing the touch
/// ring's wavy vibrato display). Falls back to the plain segment for
/// degenerate extents.
public func fretLinePoints(x: CGFloat, topY: CGFloat, bottomY: CGFloat,
                           bandHeight: CGFloat) -> [CGPoint] {
    let h = bottomY - topY
    guard h > 1 else {
        return [CGPoint(x: x, y: topY), CGPoint(x: x, y: bottomY)]
    }
    let outerIsTop = fretOuterEndIsTop(topY: topY, bottomY: bottomY,
                                       bandHeight: bandHeight)
    let zone = h * (1 - fretVibratoDeadFraction)
    let boundary = outerIsTop ? topY + zone : bottomY - zone
    let amp: CGFloat = 2.0
    let cycles: CGFloat = 2.5
    var pts = [CGPoint(x: x, y: outerIsTop ? bottomY : topY),
               CGPoint(x: x, y: boundary)]
    let steps = 24
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)     // 0 boundary → 1 outer tip
        let y = outerIsTop ? boundary - t * zone : boundary + t * zone
        pts.append(CGPoint(x: x + amp * t * sin(t * cycles * 2 * .pi), y: y))
    }
    return pts
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
