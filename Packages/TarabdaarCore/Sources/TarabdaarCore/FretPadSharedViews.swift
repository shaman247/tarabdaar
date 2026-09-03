import SwiftUI

/// The Fret Pad's display layers, shared by the Mac tab and the iPad
/// surface. Only the touch layers are forked (NSEvent vs UIKit
/// multitouch); everything drawn is one implementation, so the two
/// screens cannot drift apart. The iPad's chrome is a little larger
/// (thicker corners, bigger labels) — that is what the size parameters
/// are for.
///
/// All of these are DISPLAY ONLY (`allowsHitTesting(false)`): presses are
/// hit-tested in each surface's own touch handler against the same
/// geometry (`droneButtonRects`, `chordBarCells`), never through SwiftUI
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

// MARK: - Drone buttons

/// The drone buttons (`droneButtonRects`), named by the scale
/// (`scaleLabel(forRatio:)`) and tinted by pitch.
public struct DroneButtonsVisual: View {
    public let ratios: [Double]
    /// The scale's degrees — the buttons take their names from it.
    public let degrees: [(ratio: Double, label: String)]
    public let held: Set<Int>
    public let size: CGSize
    public let edgePad: CGFloat
    public let cornerRadius: CGFloat
    public let fontSize: CGFloat

    public init(ratios: [Double],
                degrees: [(ratio: Double, label: String)],
                held: Set<Int>, size: CGSize, edgePad: CGFloat,
                cornerRadius: CGFloat, fontSize: CGFloat) {
        self.ratios = ratios
        self.degrees = degrees
        self.held = held
        self.size = size
        self.edgePad = edgePad
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
    }

    public var body: some View {
        let rects = droneButtonRects(size: size)
        ZStack(alignment: .topLeading) {
            ForEach(rects.indices, id: \.self) { i in
                let ratio = i < ratios.count ? ratios[i] : 1.0
                let hue = pitchColor(forRatio: ratio, lightness: 0.75,
                                     chroma: 0.17)
                let r = rects[i]
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hue.opacity(held.contains(i) ? 0.9 : 0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(hue.opacity(0.8), lineWidth: 1)
                    )
                    .overlay(
                        Text(scaleLabel(forRatio: ratio, degrees: degrees))
                            .font(.padSmall(fontSize, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .frame(width: r.width, height: r.height)
                    .offset(x: edgePad + r.minX, y: edgePad + r.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Band border

public extension GraphicsContext {
    /// The playable band's border against the dead space around it.
    func strokeFretBand(_ band: CGRect) {
        stroke(Path(band), with: .color(.white.opacity(0.12)), lineWidth: 1)
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
        let freq = 440.0 * pow(2.0, (fractionalMidi - 69.0) / 12.0)
        let nearest = Int(fractionalMidi.rounded())
        let cents = Int(((fractionalMidi - Double(nearest)) * 100.0).rounded())
        let hz = freq >= 1000 ? String(format: "%.0f", freq)
                              : String(format: "%.1f", freq)
        let centsStr = cents > 0 ? "+\(cents)¢" : "\(cents)¢"
        return "\(hz) Hz (\(Scale.noteName(for: nearest)) \(centsStr))"
    }
}

// MARK: - Recorded stroke context

public extension FretGestureRecorder.Context {
    /// Snapshot the geometry + live assist settings for a recorded stroke
    /// (both surfaces record into the same offline-fitting format).
    static func snapshot(placements: [FretPlacement], size: CGSize,
                         snapDistance: CGFloat,
                         ghostExtentOctaves: Double,
                         fieldWarp: Double,
                         assist: FretDragAssist) -> FretGestureRecorder.Context {
        FretGestureRecorder.Context(
            frets: placements.map {
                .init(id: $0.id, log2Ratio: log2($0.ratio), x: Double($0.x),
                      topY: Double($0.topY), bottomY: Double($0.bottomY),
                      ghost: $0.isGhost)
            },
            snapDistance: Double(snapDistance),
            ghostExtentOctaves: ghostExtentOctaves,
            width: Double(size.width), height: Double(size.height),
            assistParams: ["fieldWarp": fieldWarp,
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
