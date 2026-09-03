import SwiftUI

/// How parameter values are written and how their sliders are bounded —
/// one law for every knob row in the app (Parameters, Controls, FX, the
/// Fret Pad toolbar).
public enum ParamFormat {
    /// Compact text for a value: whole numbers for stepped/large values,
    /// scientific notation for tiny non-zero magnitudes (a fitted physics
    /// value can be 1e-5 and "0.000" reads as off), `decimals` otherwise.
    public static func value(_ v: Double, decimals: Int = 2,
                             integer: Bool = false,
                             integerAbove: Double = 100) -> String {
        if integer { return String(format: "%.0f", v.rounded()) }
        if abs(v) < 0.001, v != 0 { return String(format: "%.1e", v) }
        if abs(v) >= integerAbove { return String(format: "%.0f", v.rounded()) }
        return String(format: "%.\(decimals)f", v)
    }

    /// A target's native range widened to include stored endpoints outside
    /// it — a binding keeps whatever value it holds; the slider grows to it
    /// instead of snap-clamping on the first drag.
    public static func sliderBounds(_ base: (Double, Double),
                                    including a: Double,
                                    _ b: Double) -> ClosedRange<Double> {
        min(base.0, a, b)...max(base.1, a, b)
    }
}

/// One knob row: label · slider · value readout. The cosmetics differ per
/// tab (label column widths, fonts, whether the slider is fixed-width), so
/// they are parameters; the shape is shared.
public struct ParamSliderRow: View {
    private let label: String
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let readout: String
    private let spacing: CGFloat
    private let labelFont: Font
    private let labelColor: Color
    private let labelWidth: CGFloat?
    private let labelAlignment: Alignment
    private let sliderWidth: CGFloat?
    private let readoutFont: Font
    private let readoutColor: Color
    private let readoutWidth: CGFloat
    /// Double-clicking the label resets the parameter, where the tab
    /// offers it.
    private let onLabelDoubleTap: (() -> Void)?

    public init(label: String, value: Binding<Double>,
                range: ClosedRange<Double>, readout: String,
                spacing: CGFloat = 8,
                labelFont: Font = .padCaption2,
                labelColor: Color = .secondary,
                labelWidth: CGFloat? = nil,
                labelAlignment: Alignment = .leading,
                sliderWidth: CGFloat? = nil,
                readoutFont: Font = .padCaption,
                readoutColor: Color = .primary,
                readoutWidth: CGFloat,
                onLabelDoubleTap: (() -> Void)? = nil) {
        self.label = label
        self.value = value
        self.range = range
        self.readout = readout
        self.spacing = spacing
        self.labelFont = labelFont
        self.labelColor = labelColor
        self.labelWidth = labelWidth
        self.labelAlignment = labelAlignment
        self.sliderWidth = sliderWidth
        self.readoutFont = readoutFont
        self.readoutColor = readoutColor
        self.readoutWidth = readoutWidth
        self.onLabelDoubleTap = onLabelDoubleTap
    }

    public var body: some View {
        HStack(spacing: spacing) {
            labelView
            sliderView
            Text(readout)
                .font(readoutFont)
                .foregroundStyle(readoutColor)
                .frame(width: readoutWidth, alignment: .trailing)
        }
    }

    @ViewBuilder private var labelView: some View {
        let text = Text(label).font(labelFont)
            .foregroundStyle(labelColor).lineLimit(1)
        if let labelWidth {
            let sized = text.frame(width: labelWidth, alignment: labelAlignment)
            if let onLabelDoubleTap {
                sized.onTapGesture(count: 2, perform: onLabelDoubleTap)
            } else {
                sized
            }
        } else if let onLabelDoubleTap {
            text.onTapGesture(count: 2, perform: onLabelDoubleTap)
        } else {
            text
        }
    }

    @ViewBuilder private var sliderView: some View {
        if let sliderWidth {
            Slider(value: value, in: range).frame(width: sliderWidth)
        } else {
            Slider(value: value, in: range)
        }
    }
}
