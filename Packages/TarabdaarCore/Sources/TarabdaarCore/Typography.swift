import CoreGraphics
import SwiftUI

/// The app's small-text scale (2026-07-25 legibility pass).
///
/// SwiftUI's stock small styles are 10–11 pt on macOS and 11–12 pt on iOS,
/// which is too fine for the dense tables this UI is mostly made of — the
/// parameter rows, the tarab string table, the tilt bindings — and for pad
/// labels read at arm's length. Every small style in the UI comes from here,
/// at the platform's own stock size × ``smallScale``, so the bump is one
/// constant rather than a hundred literals.
///
/// Display text (titles, headlines, the Live tab's big readouts) is
/// deliberately NOT scaled: it is already legible, and growing it would
/// reflow the panels.
public enum Typography {
    /// How much larger than stock the small styles run.
    public static let smallScale: CGFloat = 1.2

    /// A stock point size, scaled and rounded to the half point.
    public static func scaled(_ points: CGFloat) -> CGFloat {
        (points * smallScale * 2).rounded() / 2
    }

    /// A fixed layout width sized for stock text, widened to match.
    /// Use for the fixed-width label and value columns in the tables.
    public static func scaledWidth(_ points: CGFloat) -> CGFloat {
        (points * smallScale).rounded()
    }

    #if os(macOS)
    private static let stockCaption: CGFloat = 10
    private static let stockCaption2: CGFloat = 10
    private static let stockSubheadline: CGFloat = 11
    private static let stockCallout: CGFloat = 12
    #else
    private static let stockCaption: CGFloat = 12
    private static let stockCaption2: CGFloat = 11
    private static let stockSubheadline: CGFloat = 15
    private static let stockCallout: CGFloat = 16
    #endif

    /// Scaled point sizes of the platform's small text styles.
    public static let caption = scaled(stockCaption)
    public static let caption2 = scaled(stockCaption2)
    public static let subheadline = scaled(stockSubheadline)
    public static let callout = scaled(stockCallout)
}

public extension Font {
    /// `.caption`, scaled (macOS 10 → 12 pt).
    static let padCaption = Font.system(size: Typography.caption)
    /// `.caption2`, scaled (macOS 10 → 12 pt).
    static let padCaption2 = Font.system(size: Typography.caption2)
    /// `.subheadline`, scaled (macOS 11 → 13 pt).
    static let padSubheadline = Font.system(size: Typography.subheadline)
    /// `.callout`, scaled (macOS 12 → 14.5 pt).
    static let padCallout = Font.system(size: Typography.callout)

    /// An explicit small point size, scaled the same way — for the handful of
    /// places that size text to a drawn shape (pad labels, graph annotations).
    static func padSmall(_ points: CGFloat,
                         weight: Font.Weight = .regular,
                         design: Font.Design = .default) -> Font {
        .system(size: Typography.scaled(points), weight: weight, design: design)
    }
}
