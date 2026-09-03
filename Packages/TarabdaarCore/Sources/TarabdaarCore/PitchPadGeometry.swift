import Foundation
import SwiftUI

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
}

// MARK: - Voronoi cells

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
