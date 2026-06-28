import Foundation
import SwiftUI

// MARK: - Pad constants

/// Log-frequency bounds the pad's width maps onto, shared by every
/// platform so the Mac and iPad surfaces render identically. The base
/// octave is `[0, 1]` (1/1 … 2/1); the pad extends half an octave past
/// each end so the scale's notes appear repeated in the flanking
/// half-octaves (read-only ghosts). The scale itself is only defined
/// over the base octave.
public enum PadConstants {
    public static let xLo: Double = -0.5
    public static let xHi: Double = 1.5
    public static var xSpan: Double { xHi - xLo }
}

// MARK: - Pixel ↔ log-frequency

/// Log-frequency `logX` → pixel x within the logical pad area.
public func padXToPixel(_ logX: Double, width: CGFloat,
                        xLo: Double = PadConstants.xLo,
                        xHi: Double = PadConstants.xHi) -> CGFloat {
    CGFloat((logX - xLo) / (xHi - xLo)) * width
}

/// Pixel x → log-frequency `logX`.
public func padPixelToX(_ px: CGFloat, width: CGFloat,
                        xLo: Double = PadConstants.xLo,
                        xHi: Double = PadConstants.xHi) -> Double {
    xLo + Double(px / width) * (xHi - xLo)
}

// MARK: - Display seeds (base scale points + octave ghosts)

/// One Voronoi seed in the octave-extended pad. A seed is either a
/// base-octave scale point (`octaveShift == 0`) or a ghost repeat of
/// one in the half-octave above/below. `logX = log2(ratio)` is the
/// seed's x-axis position; `ratio` is what it plays (already
/// octave-shifted for ghosts). `id` is stable across re-renders so the
/// sounding-cell highlight survives them, and `sourceID` links a ghost
/// back to the editable base point it derives from.
public struct DisplaySeed: Identifiable, Equatable {
    public let id: String
    public let sourceID: UUID
    public let octaveShift: Int
    public let ratio: Double
    public let y: Double
    public let label: String
    /// The base-octave fraction (`num/den`) of the source point, shown
    /// above the circle while its control point is being dragged.
    public let ratioString: String
    public var logX: Double { log2(ratio) }
    public var isGhost: Bool { octaveShift != 0 }

    public init(id: String, sourceID: UUID, octaveShift: Int, ratio: Double,
                y: Double, label: String, ratioString: String) {
        self.id = id
        self.sourceID = sourceID
        self.octaveShift = octaveShift
        self.ratio = ratio
        self.y = y
        self.label = label
        self.ratioString = ratioString
    }

    /// Deterministic id for the seed derived from base point
    /// `sourceID` at octave `shift`. Stable across renders so the
    /// sounding-cell highlight matches between `pitchAt` and the draw
    /// pass.
    public static func makeID(_ sourceID: UUID, shift: Int) -> String {
        "\(sourceID.uuidString)#\(shift)"
    }
}

/// Each base point (octaveShift 0) may spawn a ghost one octave down
/// and/or up; ghosts that land outside `[xLo, xHi]` are dropped, as are
/// ghosts that coincide (within ~5 cents) with an existing base point —
/// which prevents degenerate duplicate seeds at the octave boundary
/// when a scale lists both 1/1 and 2/1. Ids are stable across renders.
/// Disabled notes are filtered out, so they contribute neither seeds
/// nor ghosts.
public func computeDisplaySeeds(points: [PitchPoint],
                                xLo: Double = PadConstants.xLo,
                                xHi: Double = PadConstants.xHi) -> [DisplaySeed] {
    let base = points.filter(\.enabled)
    var seeds: [DisplaySeed] = []
    seeds.reserveCapacity(base.count * 2)
    for p in base {
        for shift in [-1, 0, 1] {
            let logX = p.xFraction + Double(shift)
            if logX < xLo - 1e-9 || logX > xHi + 1e-9 { continue }
            if shift != 0 {
                let coincides = base.contains {
                    abs($0.xFraction - logX) < 0.004   // ~5 cents
                }
                if coincides { continue }
            }
            seeds.append(DisplaySeed(
                id: DisplaySeed.makeID(p.id, shift: shift),
                sourceID: p.id,
                octaveShift: shift,
                ratio: p.ratio * pow(2.0, Double(shift)),
                y: p.y,
                label: p.displayLabel,
                ratioString: p.ratioString
            ))
        }
    }
    return seeds
}

// MARK: - Soft Voronoi pitch resolution

/// Resolves a cursor/touch position to the ratio that should sound and
/// a per-seed weight map (keyed by `DisplaySeed.id`, summing to 1) used
/// both to blend the pitch and to cross-fade the cell fills.
///
/// Soft Voronoi. For seeds `s, s'`, the signed distance from the cursor
/// to their bisector — positive on `s`'s side — is
/// `h(s,s') = (d_s'² − d_s²) / (2·|s−s'|)`. For each seed,
/// `raw_s = max(0, margin + min_{s'} h(s,s'))` is how far the cursor has
/// penetrated past `s`'s inner-polygon edge along its most-binding
/// bisector; weights are `raw_s` normalized. Inside an inner polygon →
/// weight 1 on one pitch; in a 2-cell margin → two non-zero weights; in
/// a triple junction → three. Continuous everywhere. The played pitch
/// is `2 ^ Σ wₛ·log2(ratioₛ)`.
public func pitchAt(point pt: CGPoint, seeds: [DisplaySeed], size: CGSize,
                    marginPixels: CGFloat,
                    xLo: Double = PadConstants.xLo,
                    xHi: Double = PadConstants.xHi)
    -> (ratio: Double, weights: [String: Double])?
{
    guard !seeds.isEmpty else { return nil }

    var positions: [CGPoint] = []
    var dist2s: [Double] = []
    positions.reserveCapacity(seeds.count)
    dist2s.reserveCapacity(seeds.count)
    for s in seeds {
        let pos = CGPoint(x: padXToPixel(s.logX, width: size.width, xLo: xLo, xHi: xHi),
                          y: CGFloat(s.y) * size.height)
        let dx = Double(pos.x - pt.x)
        let dy = Double(pos.y - pt.y)
        positions.append(pos)
        dist2s.append(dx*dx + dy*dy)
    }

    var nearestIdx = 0
    for i in 1..<seeds.count where dist2s[i] < dist2s[nearestIdx] {
        nearestIdx = i
    }

    let m = Double(marginPixels)
    // Rigid Voronoi (no soft margin) or a lone seed → exact pitch.
    if m <= 0 || seeds.count == 1 {
        return (seeds[nearestIdx].ratio, [seeds[nearestIdx].id: 1.0])
    }

    var raw = [Double](repeating: 0, count: seeds.count)
    var sum = 0.0
    for s in 0..<seeds.count {
        let ps = positions[s]
        let ds2 = dist2s[s]
        var minH = Double.greatestFiniteMagnitude
        for j in 0..<seeds.count where j != s {
            let dx = Double(positions[j].x - ps.x)
            let dy = Double(positions[j].y - ps.y)
            let len = (dx*dx + dy*dy).squareRoot()
            if len == 0 { continue }
            let h = (dist2s[j] - ds2) / (2 * len)
            if h < minH { minH = h }
        }
        let r = max(0, m + minH)
        raw[s] = r
        sum += r
    }
    guard sum > 0 else {
        return (seeds[nearestIdx].ratio, [seeds[nearestIdx].id: 1.0])
    }

    var weights: [String: Double] = [:]
    var logSum = 0.0
    for s in 0..<seeds.count where raw[s] > 0 {
        let w = raw[s] / sum
        weights[seeds[s].id] = w
        logSum += w * seeds[s].logX
    }
    return (pow(2, logSum), weights)
}

// MARK: - Path helper

public extension Path {
    /// A closed polygon path. Empty (a no-op to fill/stroke) for fewer
    /// than 3 vertices.
    init(closedPolygon pts: [CGPoint]) {
        self.init()
        guard pts.count >= 3 else { return }
        move(to: pts[0])
        for v in pts.dropFirst() { addLine(to: v) }
        closeSubpath()
    }
}

// MARK: - Seed / Voronoi memo caches

/// One-entry memo for `computeDisplaySeeds`, keyed on the scale points.
/// The seeds (and their id strings) only change when the scale does, so
/// during a glide both `body` and `pitchAt` reuse the same array.
public final class SeedsCache {
    private var key: [PitchPoint]?
    private var value: [DisplaySeed] = []

    public init() {}

    public func seeds(points: [PitchPoint], _ compute: () -> [DisplaySeed]) -> [DisplaySeed] {
        if points != key {
            key = points
            value = compute()
        }
        return value
    }
}

/// One Voronoi cell — the polygon containing every pixel closer to
/// `seed` than to any other seed.
public struct VoronoiCell {
    public let seed: DisplaySeed
    public let polygon: [CGPoint]

    public init(seed: DisplaySeed, polygon: [CGPoint]) {
        self.seed = seed
        self.polygon = polygon
    }
}

/// One-entry memo for `VoronoiSolver.cells`. The solve is `O(N²)` in the
/// seed count plus a polygon allocation per clip, and `body` re-runs on
/// every sounding-fill change while gliding through a soft region — but
/// the cells only change when the seeds, pad size, or margin do. This
/// returns the cached cells whenever those inputs are unchanged. Not an
/// `ObservableObject`: it's mutated during a render and must not itself
/// trigger one.
public final class VoronoiCache {
    private struct Key: Equatable {
        let seeds: [DisplaySeed]
        let width: CGFloat
        let height: CGFloat
        let inset: CGFloat
        let xMin: Double
        let xMax: Double
    }
    private var key: Key?
    private var value: [VoronoiCell] = []

    public init() {}

    public func cells(seeds: [DisplaySeed], width: CGFloat, height: CGFloat,
                      inset: CGFloat, xMin: Double, xMax: Double) -> [VoronoiCell] {
        let k = Key(seeds: seeds, width: width, height: height,
                    inset: inset, xMin: xMin, xMax: xMax)
        if k != key {
            key = k
            value = VoronoiSolver.cells(seeds: seeds, width: width,
                                        height: height, inset: inset,
                                        xMin: xMin, xMax: xMax)
        }
        return value
    }
}

// MARK: - Voronoi solver (Sutherland-Hodgman half-plane clipping per cell)

public enum VoronoiSolver {
    /// Compute cells in pixel space. Each seed lands at
    /// `((logX - xMin)/(xMax - xMin) * width, y * height)`, and each
    /// cell is the half-plane intersection of all "closer to me than to
    /// the other seeds" constraints, clipped to the `[0, W] × [0, H]`
    /// rect. `inset` (pixels) shrinks each per-neighbor bisector
    /// half-plane inward — the rect edges are **not** inset, so the
    /// inner polygons reach the pad walls; the soft margin only exists
    /// between adjacent pitches.
    public static func cells(seeds: [DisplaySeed], width: CGFloat,
                             height: CGFloat, inset: CGFloat = 0,
                             xMin: Double, xMax: Double) -> [VoronoiCell] {
        guard !seeds.isEmpty, width > 0, height > 0, xMax > xMin else { return [] }
        let xSpan = xMax - xMin
        let positions: [CGPoint] = seeds.map {
            CGPoint(x: CGFloat(($0.logX - xMin) / xSpan) * width,
                    y: CGFloat($0.y) * height)
        }
        let rect: [CGPoint] = [
            CGPoint(x: 0,     y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: height),
            CGPoint(x: 0,     y: height),
        ]
        var out: [VoronoiCell] = []
        out.reserveCapacity(seeds.count)
        for i in 0..<seeds.count {
            var poly = rect
            let P = positions[i]
            for j in 0..<seeds.count where j != i {
                let Q = positions[j]
                let nx = Q.x - P.x
                let ny = Q.y - P.y
                if nx == 0 && ny == 0 { continue }
                let lenN = sqrt(nx * nx + ny * ny)
                let cval = nx * (P.x + Q.x) / 2
                         + ny * (P.y + Q.y) / 2
                         - inset * lenN
                poly = clip(polygon: poly, nx: nx, ny: ny, c: cval)
                if poly.isEmpty { break }
            }
            out.append(VoronoiCell(seed: seeds[i], polygon: poly))
        }
        return out
    }

    /// Sutherland-Hodgman clip: keep the part of `polygon` satisfying
    /// `nx*x + ny*y <= c`.
    private static func clip(polygon: [CGPoint], nx: CGFloat, ny: CGFloat,
                             c: CGFloat) -> [CGPoint] {
        guard polygon.count >= 2 else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(polygon.count + 2)
        let n = polygon.count
        for i in 0..<n {
            let S = polygon[(i + n - 1) % n]
            let E = polygon[i]
            let sVal = nx * S.x + ny * S.y - c
            let eVal = nx * E.x + ny * E.y - c
            let sInside = sVal <= 0
            let eInside = eVal <= 0
            if eInside {
                if !sInside {
                    out.append(intersect(S: S, E: E, sVal: sVal, eVal: eVal))
                }
                out.append(E)
            } else if sInside {
                out.append(intersect(S: S, E: E, sVal: sVal, eVal: eVal))
            }
        }
        return out
    }

    private static func intersect(S: CGPoint, E: CGPoint,
                                  sVal: CGFloat, eVal: CGFloat) -> CGPoint {
        let denom = sVal - eVal
        guard denom != 0 else { return S }
        let t = sVal / denom
        return CGPoint(x: S.x + t * (E.x - S.x),
                       y: S.y + t * (E.y - S.y))
    }
}

// MARK: - OKLCH hue mapping

/// Map a frequency ratio (1..2 spans one octave) to a perceptually
/// uniform hue using OKLCH. The hue wraps at the octave so `1/1` and
/// `2/1` both land on red, the tritone (~√2) on cyan. `lightness` is the
/// OKLab L axis (0…1); `chroma` is the radius from neutral (values above
/// ~0.2 drift out of sRGB gamut at some hues — clamped on conversion).
public func pitchColor(forRatio ratio: Double,
                       lightness L: Double,
                       chroma C: Double) -> Color {
    let phase = (log2(ratio).truncatingRemainder(dividingBy: 1.0) + 1.0)
        .truncatingRemainder(dividingBy: 1.0)
    let hueDegrees = phase * 360.0
    return oklchToColor(L: L, C: C, hueDegrees: hueDegrees)
}

/// Convert OKLCH (L, C, h in degrees) → SwiftUI `Color` via Oklab,
/// linear sRGB, and the standard sRGB transfer function (Björn
/// Ottosson, 2020). Out-of-gamut RGB is clamped to [0, 1] before gamma.
public func oklchToColor(L: Double, C: Double, hueDegrees: Double) -> Color {
    let h = hueDegrees * .pi / 180.0
    let a = C * cos(h)
    let b = C * sin(h)

    let lPrime = L + 0.3963377774 * a + 0.2158037573 * b
    let mPrime = L - 0.1055613458 * a - 0.0638541728 * b
    let sPrime = L - 0.0894841775 * a - 1.2914855480 * b
    let lLin = lPrime * lPrime * lPrime
    let mLin = mPrime * mPrime * mPrime
    let sLin = sPrime * sPrime * sPrime

    let rLin =  4.0767416621 * lLin - 3.3077115913 * mLin + 0.2309699292 * sLin
    let gLin = -1.2684380046 * lLin + 2.6097574011 * mLin - 0.3413193965 * sLin
    let bLin = -0.0041960863 * lLin - 0.7034186147 * mLin + 1.7076147010 * sLin

    return Color(
        red:   srgbEncode(rLin),
        green: srgbEncode(gLin),
        blue:  srgbEncode(bLin)
    )
}

private func srgbEncode(_ linear: Double) -> Double {
    let x = min(max(0, linear), 1)
    return x <= 0.0031308
        ? 12.92 * x
        : 1.055 * pow(x, 1.0 / 2.4) - 0.055
}

// MARK: - Cell fills (dynamic layer)

/// Draws the sounding cell fills — the only part of the pad that changes
/// while gliding. It observes just `SoundingState`, so a per-tick weight
/// change re-renders this overlay alone, not the static Canvas / discs /
/// toolbar. The `cells` come from the surface's memoized Voronoi (stable
/// during a glide); fills draw over the static borders.
public struct CellFillsView: View {
    @ObservedObject var sounding: SoundingState
    let cells: [VoronoiCell]
    let edgePad: CGFloat

    public init(sounding: SoundingState, cells: [VoronoiCell], edgePad: CGFloat) {
        self.sounding = sounding
        self.cells = cells
        self.edgePad = edgePad
    }

    public var body: some View {
        Canvas { ctx, _ in
            ctx.translateBy(x: edgePad, y: edgePad)
            for cell in cells {
                let weight = sounding.weights[cell.seed.id] ?? 0
                guard weight > 0, cell.polygon.count >= 3 else { continue }
                let path = Path(closedPolygon: cell.polygon)
                let hue = pitchColor(forRatio: cell.seed.ratio,
                                     lightness: 0.82, chroma: 0.20)
                ctx.fill(path, with: .color(hue.opacity(weight)))
                ctx.stroke(path, with: .color(hue), lineWidth: 2 + CGFloat(weight))
            }
        }
    }
}
