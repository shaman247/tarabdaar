import SarangiKit
import SwiftUI

extension FretPlacement {
    /// The fret as drawn: the vertical stroke from its top to its bottom,
    /// in band-local points.
    public var linePath: Path {
        var line = Path()
        line.move(to: CGPoint(x: x, y: topY))
        line.addLine(to: CGPoint(x: x, y: bottomY))
        return line
    }
}

/// The Fret Pad's display layers, shared by the Mac tab and the iPad
/// surface. Only the touch layers are forked (NSEvent vs UIKit
/// multitouch); everything drawn is one implementation, so the two
/// screens cannot drift apart. The iPad's chrome is a little larger
/// (thicker corners, bigger labels) — that is what the size parameters
/// are for.
///
/// All of these are DISPLAY ONLY (`allowsHitTesting(false)`): presses are
/// hit-tested in each surface's own touch handler against the same
/// geometry (`chordBarCells`), never through SwiftUI
/// gestures, so they cannot interfere with melody multitouch.

// MARK: - Chord bar

/// The chord bar below the band: one derived triad per fret column.
/// Highlight = the active selection (the Mac's strum chord; on the iPad
/// this pad's own selection, asserted in its outbound frame).
public struct ChordBarVisual: View {
    public let cells: [ChordBarCell]
    public let active: ChordSelection?
    public let edgePad: CGFloat
    public let cornerRadius: CGFloat
    public let fontSize: CGFloat

    public init(cells: [ChordBarCell], active: ChordSelection?,
                edgePad: CGFloat, cornerRadius: CGFloat, fontSize: CGFloat) {
        self.cells = cells
        self.active = active
        self.edgePad = edgePad
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cells) { c in
                // Octave-agnostic: every octave's cell of the degree lights.
                let sel = active?.degree == c.degreeIndex
                let hue = pitchColor(forRatio: c.rootRatio, lightness: 0.78,
                                     chroma: 0.16)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(sel ? hue.opacity(0.55) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(hue.opacity(sel ? 0.95 : 0.4),
                                    lineWidth: sel ? 1.5 : 1)
                    )
                    .overlay(
                        Text(c.numeral)
                            .font(.padSmall(fontSize, weight: .semibold))
                            .foregroundColor(.white.opacity(sel ? 1.0 : 0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    )
                    .frame(width: c.rect.width, height: c.rect.height)
                    .offset(x: edgePad + c.rect.minX, y: edgePad + c.rect.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Band background and pitch grid

public extension GraphicsContext {
    /// Black rows separated by horizontal gridlines, with no enclosing border.
    func fillFretBand(_ band: CGRect) {
        fill(Path(band), with: .color(.black))
        var separators = Path()
        for row in FretRow.allCases.dropLast() {
            let y = band.minY + row.topY * band.height
            separators.move(to: CGPoint(x: band.minX, y: y))
            separators.addLine(to: CGPoint(x: band.maxX, y: y))
        }
        stroke(separators, with: .color(Color(.sRGB, white: 0.10, opacity: 1)), lineWidth: 1)
    }

    /// Scale-pitch guides span the band, including unassigned pitches and octave copies.
    func strokeFretPitchGrid(degrees: [(ratio: Double, label: String)],
                             ghostExtentOctaves: Double, size: CGSize) {
        let extent = max(0, ghostExtentOctaves)
        for degree in degrees where degree.ratio.isFinite && degree.ratio > 0 {
            let pitch = log2(degree.ratio)
            let tonic = abs(pitch - pitch.rounded()) < 1e-9
            let shade = tonic ? 0.13 : 0.10
            let first = Int(ceil(-extent - pitch))
            let last = Int(floor(1 + extent - pitch))
            guard first <= last else { continue }
            for octave in first...last {
                let x = fretPixelX(forBandX: pitch + Double(octave),
                                   ghostExtentOctaves: extent, width: size.width)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                stroke(line, with: .color(Color(.sRGB, white: shade, opacity: 1)), lineWidth: 1)
            }
        }
    }
}

// MARK: - Sounding readout

/// Live Hz / note / cents readout for the active touch. Observes only
/// `SoundingState`, so a glide's ticks re-render this label alone.
public struct SoundingReadout: View {
    /// The two chromes: the Mac toolbar's capsule (which reserves its
    /// width with a placeholder) and the iPad toolbar's fixed column.
    public enum Style {
        case capsule
        case column(width: CGFloat)
    }

    @ObservedObject public var sounding: SoundingState
    public let tonicFractionalMidi: Double
    public let style: Style

    public init(sounding: SoundingState, tonicFractionalMidi: Double,
                style: Style) {
        self.sounding = sounding
        self.tonicFractionalMidi = tonicFractionalMidi
        self.style = style
    }

    public var body: some View {
        let ratio = sounding.ratio
        let text: String = ratio.map {
            Self.text(ratio: $0, tonicFractionalMidi: tonicFractionalMidi,
                      octaveSemis: sounding.octaveSemis)
        } ?? placeholder
        let color: Color = ratio.map {
            pitchColor(forRatio: $0, lightness: 0.85, chroma: 0.18)
        } ?? .clear
        let label = Text(text)
            .font(.padSmall(11).monospacedDigit())
            .foregroundStyle(color)
        switch style {
        case .capsule:
            label
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(Capsule()
                    .fill(Color(white: 0.12).opacity(ratio == nil ? 0 : 1)))
                .opacity(ratio == nil ? 0 : 1)
                .fixedSize()
        case let .column(width):
            label.frame(width: width, alignment: .trailing)
        }
    }

    /// Sized so the capsule holds its place while silent.
    private var placeholder: String {
        if case .capsule = style { return "000.0 Hz" }
        return ""
    }

    /// "261.6 Hz (C4 +0¢)" — the sounding pitch, note name and offset.
    /// `octaveSemis` is onset-captured, so a held note reads true.
    public static func text(ratio: Double, tonicFractionalMidi: Double,
                            octaveSemis: Double) -> String {
        let fractionalMidi = tonicFractionalMidi + octaveSemis
            + 12.0 * log2(ratio)
        let freq = Pitch.hz(fractionalMidi: fractionalMidi)
        let nearest = Int(fractionalMidi.rounded())
        let cents = Int(((fractionalMidi - Double(nearest)) * 100.0).rounded())
        let hz = freq >= 1000 ? String(format: "%.0f", freq)
                              : String(format: "%.1f", freq)
        let centsStr = cents > 0 ? "+\(cents)¢" : "\(cents)¢"
        return "\(hz) Hz (\(Scale.noteName(for: nearest)) \(centsStr))"
    }
}

// MARK: - Recorded stroke context

public extension FretGestureCapture.Context {
    /// Snapshot the geometry + live assist settings for a recorded stroke
    /// (both surfaces record into the same offline-fitting format).
    static func snapshot(placements: [FretPlacement], size: CGSize,
                         snapDistance: CGFloat,
                         ghostExtentOctaves: Double,
                         fieldWarp: Double,
                         assist: FretDragAssist) -> FretGestureCapture.Context {
        FretGestureCapture.Context(
            frets: placements.map {
                .init(id: $0.id, log2Ratio: log2($0.ratio), x: Double($0.x),
                      topY: Double($0.topY), bottomY: Double($0.bottomY),
                      ghost: $0.isGhost, row: $0.row.rawValue)
            },
            snapDistance: Double(snapDistance),
            ghostExtentOctaves: ghostExtentOctaves,
            width: Double(size.width), height: Double(size.height),
            assistParams: ["fieldWarp": fieldWarp,
                           "amount": assist.amount,
                           "slewCap": assist.slewCap,
                           "correctionDecayPx": assist.correctionDecayPx,
                           "speedFloor": assist.speedFloor,
                           "speedCeiling": assist.speedCeiling,
                           "speedTau": assist.speedTau,
                           "settleTau": assist.settleTau,
                           "radiusScale": assist.radiusScale,
                           "turnGain": assist.turnGain,
                           "turnTau": assist.turnTau,
                           "stillRadiusPx": assist.stillRadiusPx,
                           "stopDwellMin": assist.stopDwellMin,
                           "stopDwellRamp": assist.stopDwellRamp])
    }
}
