import Foundation

public enum BowAxis: String, CaseIterable, Sendable {
    case expression = "expr", position = "pos", pressure = "press"

    public var title: String {
        switch self {
        case .expression: return "Expression"
        case .position: return "Position"
        case .pressure: return "Pressure"
        }
    }
}

public struct BowAxisPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A bounded piecewise-linear bow-axis curve; identity bypasses arithmetic exactly.
public struct BowAxisTransform: Sendable {
    public static let maxPoints = 64
    public static let minSpacing = 0.001
    public static let identity = [BowAxisPoint(x: 0, y: 0), BowAxisPoint(x: 1, y: 1)]
    public let points: [BowAxisPoint]
    private let isIdentity: Bool
    private let isLegacyGrid: Bool

    public init(points: [BowAxisPoint]) {
        self.points = Self.normalize(points)
        isIdentity = self.points.allSatisfy { $0.x == $0.y }
        // Preserve the fitted factory curve and migrated presets bit-for-bit.
        isLegacyGrid = self.points.count == 11 && self.points.enumerated().allSatisfy {
            $0.element.x == Double($0.offset) / 10
        }
    }

    /// Read the bundled factory curve or the fixed-band format in an older preset.
    public init(bp: BowParams, axis: String) {
        self.init(points: (0...10).map { index in
            let x = Double(index) / 10
            let value = bp.v("bow_\(axis)_map_\(index)", x)
            return BowAxisPoint(x: x, y: value.isFinite ? value : x)
        })
    }

    /// Endpoints span the whole input range; duplicate inputs merge and invalid points drop.
    public static func normalize(_ points: [BowAxisPoint]) -> [BowAxisPoint] {
        var out: [BowAxisPoint] = []
        let valid = points.filter { $0.x.isFinite && $0.y.isFinite }
            .map { BowAxisPoint(x: $0.x < minSpacing ? 0 : $0.x > 1 - minSpacing ? 1 : $0.x, y: min(max($0.y, 0), 1)) }
            .enumerated().sorted { $0.element.x == $1.element.x
                ? $0.offset < $1.offset : $0.element.x < $1.element.x }
        for item in valid {
            let p = item.element
            if let last = out.last, p.x - last.x < minSpacing {
                out[out.count - 1].y = p.y
            } else { out.append(p) }
        }
        guard !out.isEmpty else { return identity }
        if out[0].x > 0 { out.insert(BowAxisPoint(x: 0, y: out[0].y), at: 0) }
        if out[out.count - 1].x < 1 { out.append(BowAxisPoint(x: 1, y: out[out.count - 1].y)) }
        if out.count > maxPoints {
            out = Array(out.prefix(maxPoints - 1)) + [out[out.count - 1]]
        }
        return out
    }

    @inline(__always) public func apply(_ input: Double) -> Double {
        let x = input.isFinite ? min(max(input, 0), 1) : 0
        if isIdentity { return x }
        if isLegacyGrid {
            let scaled = x * 10
            let index = min(Int(scaled), 9)
            return points[index].y + (scaled - Double(index)) * (points[index + 1].y - points[index].y)
        }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].x <= x { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        return a.y + (x - a.x) / (b.x - a.x) * (b.y - a.y)
    }
}
