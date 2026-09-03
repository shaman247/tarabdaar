import SwiftUI
import simd

/// The turntable trail: the one renderer behind every 3D motion view on
/// both devices (the Mac's received-attitude and Joy-Con IMU panels, the
/// iPad's GYRO overlays, the calibration sample cloud).
///
/// A trail is projected from a slowly spinning azimuth at a fixed
/// elevation, so depth reads as parallax rather than needing a legend:
/// drift crawls as a snake, sensor noise piles into a fuzz ball, a still
/// stream is almost nothing. Scale is always FIXED in the signal's own
/// units (`maxRadius` = frame edge) — auto-zoom blew sub-degree noise up
/// into a full-frame fuzz ball. Views with a natural zero (acceleration,
/// rates) pass `center: .zero`; attitude views pass nil and ride the
/// trail mean, since the rest pose is arbitrary.
public enum MotionScatter {
    /// Axis colours, x/y/z (pitch/roll/yaw) — also the label colours.
    public static let axisColors: [Color] = [.orange, .green, .cyan]
    /// Turntable rotation, radians per second.
    public static let spin = 0.3
    /// Elevation of the fixed viewpoint, radians.
    public static let elevation = 0.5
    /// Points kept after decimation (a long history draws no better).
    public static let maxPoints = 400

    /// One turntable projection: spin about z at `azimuth`, viewed from
    /// `elevation`, scaled so `maxRadius` reaches the frame edge.
    public struct Projection {
        public let center: SIMD3<Double>
        public let scale: Double
        public let cx: Double
        public let cy: Double
        private let cosA: Double
        private let sinA: Double
        private let cosE: Double
        private let sinE: Double

        public init(center: SIMD3<Double>, maxRadius: Double, size: CGSize,
                    inset: Double, azimuth: Double) {
            self.center = center
            let half = Double(min(size.width, size.height)) / 2 - inset
            scale = half / maxRadius
            cx = Double(size.width) / 2
            cy = Double(size.height) / 2
            cosA = cos(azimuth)
            sinA = sin(azimuth)
            cosE = cos(MotionScatter.elevation)
            sinE = sin(MotionScatter.elevation)
        }

        /// Screen position plus view depth (larger = nearer the viewer).
        public func project(_ p: SIMD3<Double>) -> (x: Double, y: Double,
                                                    depth: Double) {
            let d = p - center
            let rx = d.x * cosA - d.y * sinA
            let ry = d.x * sinA + d.y * cosA
            return (cx + rx * scale,
                    cy - (d.z * cosE - ry * sinE) * scale,
                    ry * cosE + d.z * sinE)
        }

        public func point(_ p: SIMD3<Double>) -> CGPoint {
            let q = project(p)
            return CGPoint(x: q.x, y: q.y)
        }
    }

    /// Stride down to `maxPoints`, always keeping the newest sample (the
    /// current-value dot must sit on the live reading, not on a stride).
    public static func decimated(_ all: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let step = max(1, all.count / maxPoints)
        var pts: [SIMD3<Double>] = []
        pts.reserveCapacity(all.count / step + 1)
        for i in stride(from: 0, to: all.count, by: step) {
            pts.append(all[i])
        }
        if let last = all.last { pts.append(last) }
        return pts
    }

    public static func mean(_ pts: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !pts.isEmpty else { return SIMD3<Double>() }
        var c = SIMD3<Double>()
        for p in pts { c += p }
        return c / Double(pts.count)
    }

    /// The whole trail: faint axis lines through the centre, the age-faded
    /// path, and a dot on the current value.
    ///
    /// - Parameters:
    ///   - points: the full history, oldest first (decimated here).
    ///   - maxRadius: signal units from the centre to the frame edge.
    ///   - center: nil = the decimated trail's mean.
    public static func drawTrail(_ ctx: GraphicsContext, size: CGSize,
                                 points all: [SIMD3<Double>],
                                 maxRadius: Double,
                                 center: SIMD3<Double>? = nil,
                                 axisColors: [Color] = axisColors,
                                 azimuth: Double) {
        guard all.count > 2 else { return }
        let pts = decimated(all)
        let c = center ?? mean(pts)
        let proj = Projection(center: c, maxRadius: maxRadius, size: size,
                              inset: 12, azimuth: azimuth)

        // Axis lines through the centre, for orientation.
        for (i, color) in axisColors.enumerated() {
            var axis = SIMD3<Double>()
            axis[i] = 1
            var path = Path()
            path.move(to: proj.point(c - axis * maxRadius))
            path.addLine(to: proj.point(c + axis * maxRadius))
            ctx.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 0.5)
        }

        // Age-faded trail: the newest segments are the brightest.
        for i in 1..<pts.count {
            var seg = Path()
            seg.move(to: proj.point(pts[i - 1]))
            seg.addLine(to: proj.point(pts[i]))
            let age = Double(i) / Double(pts.count)
            ctx.stroke(seg, with: .color(.white.opacity(0.1 + 0.6 * age)),
                       lineWidth: 1)
        }

        // The current value.
        if let last = pts.last {
            let q = proj.point(last)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.yellow))
        }
    }
}
