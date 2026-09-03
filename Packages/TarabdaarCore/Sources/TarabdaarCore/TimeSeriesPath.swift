import SwiftUI

public extension Path {
    /// Append a smooth curve through `pts` using a uniform Catmull-Rom
    /// spline converted to cubic Bézier segments (control points at ±1/6 of
    /// the neighbour span) — rounds off the sample-to-sample stair-steps a
    /// 60 Hz-sampled glide shows as straight segments. `moveToStart` begins
    /// a new subpath at the first point; otherwise it lines to it (so an
    /// area fill can start at the baseline).
    mutating func addSmoothCurve(_ pts: [CGPoint], moveToStart: Bool = true) {
        guard let first = pts.first else { return }
        if moveToStart { move(to: first) } else { addLine(to: first) }
        if pts.count < 3 {
            for q in pts.dropFirst() { addLine(to: q) }
            return
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}

/// The scrolling time-series graphs (the Live tab's meters, the Scope tab's
/// pitch field) share their ring trim and their screen mapping.
public enum TimeSeries {
    /// Kept beyond the visible window so the trace enters cleanly from the
    /// left edge (clipped) rather than starting at the first sample.
    public static let trailingSlack: Double = 0.5

    /// Drop samples that have scrolled out of the window, in one pass, and
    /// only once the oldest has actually aged out.
    public static func trim<S>(_ samples: inout [S], now: Double,
                               window: Double, t: (S) -> Double) {
        let cutoff = now - (window + trailingSlack)
        if let first = samples.first, t(first) < cutoff {
            samples.removeAll { t($0) < cutoff }
        }
    }

    /// Sample time → x, with `now` at the right edge.
    public static func x(_ time: Double, now: Double, window: Double,
                         minX: CGFloat = 0, width: CGFloat) -> CGFloat {
        minX + width * CGFloat(1.0 - (now - time) / window)
    }

    /// Value → y inside `range`, measured up from `bottom` and clamped.
    /// Graphs that let a trace overshoot slightly widen `clamp`.
    public static func y(_ v: Double, range: ClosedRange<Double>,
                         bottom: CGFloat, height: CGFloat,
                         clamp: ClosedRange<Double> = 0...1) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let n = span > 0 ? (v - range.lowerBound) / span : 0.5
        return bottom - height * CGFloat(min(clamp.upperBound,
                                             max(clamp.lowerBound, n)))
    }
}
