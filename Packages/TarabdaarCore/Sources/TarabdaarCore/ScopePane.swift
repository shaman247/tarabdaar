import SwiftUI

/// The iPad toolbar scopes — the strike envelope, the finger acceleration
/// and the Mac's volume readout — share this container and its drawing
/// grid; only the trace itself is per-pane.
///
/// The rendering discipline they all follow: poll the unpublished history
/// at 30 Hz in a `TimelineView` (never subscribe — these feeds move at
/// sensor rate), read it in the TICK rather than inside the `Canvas`
/// closure (capturing only a class reference lets SwiftUI dedupe the
/// canvas and the trace freezes), and decimate per-bin with a peak-hold
/// rather than a sample stride (a stride aliases and can drop a tap
/// spike).
public struct ScopePane<Data>: View {
    /// The pane's fixed width; the height is `ScopeTrace.paneHeight`.
    public let width: CGFloat
    /// Reads the history — called once per tick, outside the canvas.
    public let sample: () -> Data
    public let draw: (GraphicsContext, CGSize, Data) -> Void

    public init(width: CGFloat, sample: @escaping () -> Data,
                draw: @escaping (GraphicsContext, CGSize, Data) -> Void) {
        self.width = width
        self.sample = sample
        self.draw = draw
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / ScopeTrace.pollHz)) { _ in
            let data = sample()
            Canvas { ctx, size in draw(ctx, size, data) }
                .frame(width: width, height: ScopeTrace.paneHeight)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15)))
        }
    }
}

/// The scope panes' shared grid: the time window, the absolute-time bin
/// layout, the note-active backdrop, the guide lines and the value label.
public enum ScopeTrace {
    /// Visible span, seconds.
    public static let window: TimeInterval = 4.0
    public static let pollHz: Double = 30.0
    public static let paneHeight: CGFloat = 36

    /// One bin per pixel column, anchored to ABSOLUTE time — a moving
    /// origin makes the trace shimmer as it scrolls.
    public struct Bins {
        public let count: Int
        /// Seconds per bin.
        public let duration: Double
        /// Start of the first bin.
        public let t0: Double

        public init(width: CGFloat, endingAt end: Double,
                    window: TimeInterval = ScopeTrace.window) {
            count = max(Int(width), 1)
            duration = window / Double(count)
            t0 = (((end - window) / duration).rounded(.down)) * duration
        }

        /// The bin a sample time falls in, clamped to the grid.
        public func index(of t: Double) -> Int {
            min(count - 1, max(0, Int((t - t0) / duration)))
        }

        /// Mid-time of a bin (what the per-bin timelines are sampled at).
        public func center(_ b: Int) -> Double {
            t0 + (Double(b) + 0.5) * duration
        }

        /// Mid-x of a bin.
        public func x(_ b: Int, width: CGFloat) -> CGFloat {
            (CGFloat(b) + 0.5) / CGFloat(count) * width
        }
    }

    /// Per-bin "a note was sounding" from the surface's note timeline (one
    /// linear walk; the timeline is ordered).
    public static func soundingBins(_ activity: [(t: TimeInterval, active: Int)],
                                    bins: Bins) -> [Bool] {
        var ai = -1        // last activity event with t <= binT
        var out = [Bool](repeating: false, count: bins.count)
        for b in 0..<bins.count {
            let binT = bins.center(b)
            while ai + 1 < activity.count, activity[ai + 1].t <= binT {
                ai += 1
            }
            out[b] = ai >= 0 && activity[ai].active > 0
        }
        return out
    }

    /// The note-active backdrop, run-length filled so phrases read as
    /// blocks rather than per-bin stripes.
    public static func fillActivity(_ ctx: GraphicsContext, size: CGSize,
                                    sounding: [Bool]) {
        let bins = sounding.count
        var b = 0
        while b < bins {
            guard sounding[b] else { b += 1; continue }
            var e = b
            while e + 1 < bins, sounding[e + 1] { e += 1 }
            let x0 = CGFloat(b) / CGFloat(bins) * size.width
            let x1 = CGFloat(e + 1) / CGFloat(bins) * size.width
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0,
                                 height: size.height)),
                     with: .color(.white.opacity(0.12)))
            b = e + 1
        }
    }

    /// Horizontal guide lines, each at a fraction of the height measured
    /// from the BOTTOM — over the backdrop, under the trace.
    public static func guides(_ ctx: GraphicsContext, size: CGSize,
                              _ lines: [(fraction: Double, opacity: Double)]) {
        for l in lines {
            var p = Path()
            let y = size.height * CGFloat(1 - l.fraction)
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(.white.opacity(l.opacity)),
                       lineWidth: 0.5)
        }
    }

    /// The live value, right-aligned at the pane's edge.
    public static func drawValueLabel(_ ctx: GraphicsContext, _ text: Text,
                                      size: CGSize, measureIn box: CGSize,
                                      y: CGFloat? = nil) {
        let resolved = ctx.resolve(text)
        let sz = resolved.measure(in: box)
        ctx.draw(resolved, at: CGPoint(x: size.width - sz.width / 2 - 3,
                                       y: y ?? (sz.height / 2 + 1)))
    }
}
