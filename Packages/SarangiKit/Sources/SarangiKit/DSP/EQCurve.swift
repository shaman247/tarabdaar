import Foundation

/// One control point of an FX-rack EQ curve: a frequency and the gain the
/// curve must pass through there.
public struct EQPoint: Codable, Equatable, Hashable, Sendable {
    public var hz: Double
    public var db: Double
    public init(hz: Double, db: Double) { self.hz = hz; self.db = db }
}

/// One second-order section of a realised EQ curve.
public struct EQSection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case lowShelf, peak, highShelf }
    public var kind: Kind
    public var f0: Double
    /// Peaks only (the shelves run at S = 1, the steepest monotone slope).
    public var q: Double
    public var gainDB: Double

    public init(kind: Kind, f0: Double, q: Double = 0.7071, gainDB: Double) {
        self.kind = kind; self.f0 = f0; self.q = q; self.gainDB = gainDB
    }

    public func biquad(sr: Double) -> Biquad {
        switch kind {
        case .peak:      return Biquad.peaking(f0: f0, gainDB: gainDB, q: q, sr: sr)
        case .lowShelf:  return Biquad.lowShelf(f0: f0, gainDB: gainDB, sr: sr, S: 1.0)
        case .highShelf: return Biquad.highShelf(f0: f0, gainDB: gainDB, sr: sr, S: 1.0)
        }
    }

    public func magnitudeDB(at hz: Double, sr: Double) -> Double {
        EQCurve.magnitudeDB(biquad(sr: sr), at: hz, sr: sr)
    }
}

/// A realised EQ curve: a broadband gain plus a cascade of sections. The
/// identity design (no sections, 0 dB) is the bypass.
public struct EQDesign: Equatable, Sendable {
    public var gainDB: Double = 0
    public var sections: [EQSection] = []

    public init() {}
    public init(gainDB: Double, sections: [EQSection]) {
        self.gainDB = gainDB; self.sections = sections
    }

    public var isIdentity: Bool { sections.isEmpty && gainDB == 0 }

    /// The curve at `amount` of its depth — every dB scaled (0 = bypass).
    public func scaled(by amount: Double) -> EQDesign {
        if amount == 1 { return self }
        if amount <= 0 { return EQDesign() }
        var d = self
        d.gainDB *= amount
        for i in d.sections.indices { d.sections[i].gainDB *= amount }
        return d
    }

    /// The cascade's magnitude response in dB (display, tests).
    public func magnitudeDB(at hz: Double, sr: Double) -> Double {
        sections.reduce(gainDB) { $0 + $1.magnitudeDB(at: hz, sr: sr) }
    }
}

/// THE EQ CURVE: the player sets points, the curve is inferred.
///
/// The target is a monotone cubic through the points in log-frequency
/// (Fritsch–Carlson: no overshoot between points), held flat beyond the
/// outermost point on each side. It is realised as a cascade whose SHAPE
/// follows the points: a peaking section at every point with its bandwidth
/// taken from the spacing to its neighbours, an extra peak every
/// `knotOctaves` inside a wide gap so long spans can bend, a low and a high
/// shelf beyond the ends that carry the held gain, and one broadband gain.
/// The section gains are then FITTED — weighted least squares against the
/// target on a log grid (the points themselves weighted heavily), refined
/// through a few Gauss–Newton passes because a biquad's dB response is
/// only nearly linear in its gain, ridge-regularised so near-coincident
/// points cannot drive the gains apart. The response passes through every
/// point to within a fraction of a dB and holds exactly outside the ends;
/// between points it is the cascade's own smooth shape. What the FX tab
/// draws is this realised response, not the spline.
///
/// `design` runs on the control thread (it allocates); the render thread
/// only ever adopts a finished `EQDesign`.
public enum EQCurve {
    public static let maxPoints = 12
    public static let minHz = 20.0
    public static let maxHz = 20_000.0
    public static let gainLimitDB = 12.0
    /// Two points closer than this (in octaves) merge.
    public static let minSpacingOctaves = 1.0 / 24
    /// Widest gap between sections before a knot is added inside it.
    static let knotOctaves = 2.0
    /// Cascade capacity per channel — `maxPoints`, the knots a 10-octave
    /// span can need, and the two hold shelves.
    public static let maxSections = 20

    /// Sort by frequency, clamp to the curve's range, merge points closer
    /// than `minSpacingOctaves`, and cap the count.
    public static func normalize(_ points: [EQPoint]) -> [EQPoint] {
        var out: [EQPoint] = []
        for p in points.sorted(by: { $0.hz < $1.hz }) {
            let hz = min(max(p.hz, minHz), maxHz)
            let db = min(max(p.db, -gainLimitDB), gainLimitDB)
            if let last = out.last, log2(hz / last.hz) < minSpacingOctaves {
                out[out.count - 1].db = db      // the later edit wins
                continue
            }
            out.append(EQPoint(hz: hz, db: db))
        }
        if out.count > maxPoints { out.removeLast(out.count - maxPoints) }
        return out
    }

    // MARK: - The target curve

    /// The spline the cascade is fitted to: monotone cubic in log2(f)
    /// through the points, flat beyond the ends.
    public static func target(_ points: [EQPoint], at hz: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if points.count == 1 || hz <= first.hz { return first.db }
        if hz >= last.hz { return last.db }
        let x = points.map { log2($0.hz) }
        let y = points.map(\.db)
        let m = monotoneSlopes(x, y)
        let t = log2(hz)
        var i = 0
        while i + 2 < points.count, x[i + 1] <= t { i += 1 }
        let h = x[i + 1] - x[i]
        let s = (t - x[i]) / h
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2, h11 = s3 - s2
        return h00 * y[i] + h10 * h * m[i] + h01 * y[i + 1] + h11 * h * m[i + 1]
    }

    /// Fritsch–Carlson tangents: the interpolant never overshoots a point.
    private static func monotoneSlopes(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = x.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                m[i] = d[i - 1] * d[i] <= 0 ? 0 : 0.5 * (d[i - 1] + d[i])
            }
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let r = a * a + b * b
            if r > 9 {
                let t = 3 / r.squareRoot()
                m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
            }
        }
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        return m
    }

    // MARK: - The realisation

    /// Fit a cascade to the curve through `points` for a filter running at
    /// `sr`. Empty points → the identity design.
    public static func design(_ points: [EQPoint], sr: Double) -> EQDesign {
        let pts = normalize(points)
        guard let first = pts.first, let last = pts.last else { return EQDesign() }
        if pts.count == 1 { return EQDesign(gainDB: first.db, sections: []) }
        let fmax = 0.45 * sr
        let sections = layout(pts, fmax: fmax)

        // the fit grid: log-spaced over the audible band plus the points
        var grid = (0..<96).map { minHz * pow(min(maxHz, fmax) / minHz, Double($0) / 95) }
        grid += pts.map(\.hz)
        grid.sort()
        let pointHz = Set(pts.map(\.hz))
        let tgt = grid.map { target(pts, at: $0) }
        // the points bind hardest; the held regions beyond the ends next
        let wgt = grid.map {
            pointHz.contains($0) ? 16.0 : ($0 < first.hz || $0 > last.hz ? 3.0 : 1.0)
        }

        // unknowns: [broadband gain, section gains…]
        let m = sections.count + 1
        var g = [Double](repeating: 0, count: m)
        g[0] = 0.5 * (first.db + last.db)
        for k in sections.indices { g[k + 1] = sections[k].gainDB }
        var M = [Double](repeating: 0, count: grid.count * m)
        var ata = [Double](repeating: 0, count: m * m)
        var atb = [Double](repeating: 0, count: m)
        let lambda = 0.05
        for _ in 0..<4 {
            // sensitivity per dB of each section at its current gain
            for (r, hz) in grid.enumerated() {
                M[r * m] = 1
                for k in sections.indices {
                    let gk = abs(g[k + 1]) > 0.5 ? g[k + 1] : 1.0
                    var s = sections[k]; s.gainDB = gk
                    M[r * m + k + 1] = s.magnitudeDB(at: hz, sr: sr) / gk
                }
            }
            // weighted normal equations with a ridge on the sections
            for i in 0..<m {
                atb[i] = 0
                for j in 0..<m { ata[i * m + j] = i == j && i > 0 ? lambda : 0 }
            }
            for r in grid.indices {
                let w = wgt[r]
                for i in 0..<m {
                    let mi = M[r * m + i] * w
                    atb[i] += mi * tgt[r]
                    for j in 0..<m { ata[i * m + j] += mi * M[r * m + j] }
                }
            }
            guard let x = solve(ata, atb, m) else { break }
            g = x
        }
        var out = sections
        for k in out.indices {
            out[k].gainDB = min(max(g[k + 1], -4 * gainLimitDB), 4 * gainLimitDB)
        }
        return EQDesign(gainDB: g[0], sections: out)
    }

    /// The cascade's shape for a point set: the two hold shelves, a peak
    /// per point and a knot every `knotOctaves` inside a wide gap, each
    /// peak's bandwidth the mean spacing to its neighbours.
    static func layout(_ pts: [EQPoint], fmax: Double) -> [EQSection] {
        var knots: [(hz: Double, db: Double)] = [(pts[0].hz, pts[0].db)]
        var stride = knotOctaves
        // widen the knot stride until the cascade fits its capacity
        while true {
            knots = [(pts[0].hz, pts[0].db)]
            for i in 0..<(pts.count - 1) {
                let w = log2(pts[i + 1].hz / pts[i].hz)
                let n = Int((w / stride).rounded(.up))
                if n > 1 {
                    for j in 1..<n {
                        let hz = pts[i].hz * pow(2, w * Double(j) / Double(n))
                        knots.append((hz, target(pts, at: hz)))
                    }
                }
                knots.append((pts[i + 1].hz, pts[i + 1].db))
            }
            if knots.count + 2 <= maxSections { break }
            stride *= 1.5
        }
        var secs: [EQSection] = []
        secs.append(EQSection(kind: .lowShelf,
                              f0: min(pts[0].hz * pow(2, 0.8), fmax),
                              gainDB: pts[0].db))
        for i in knots.indices {
            let wl = i > 0 ? log2(knots[i].hz / knots[i - 1].hz) : nil
            let wr = i + 1 < knots.count ? log2(knots[i + 1].hz / knots[i].hz) : nil
            var bw: Double
            switch (wl, wr) {
            case let (l?, r?): bw = 0.5 * (l + r)
            case let (l?, nil): bw = l
            case let (nil, r?): bw = r
            default: bw = 1
            }
            bw = min(max(bw, 1.0 / 8), 4)
            let f0 = min(knots[i].hz, fmax)
            secs.append(EQSection(kind: .peak, f0: f0,
                                  q: peakQ(bandwidthOctaves: bw), gainDB: knots[i].db))
        }
        secs.append(EQSection(kind: .highShelf,
                              f0: min(pts[pts.count - 1].hz * pow(2, -0.8), fmax),
                              gainDB: pts[pts.count - 1].db))
        return secs
    }

    /// RBJ: 1/Q = 2·sinh(ln2/2 · BW) for a bandwidth in octaves.
    static func peakQ(bandwidthOctaves bw: Double) -> Double {
        1.0 / (2.0 * sinh(0.5 * log(2.0) * bw))
    }

    /// Gaussian elimination with partial pivoting on the m×m normal matrix.
    private static func solve(_ a: [Double], _ b: [Double], _ m: Int) -> [Double]? {
        var A = a, B = b
        for c in 0..<m {
            var p = c
            for r in (c + 1)..<max(m, c + 1) where abs(A[r * m + c]) > abs(A[p * m + c]) { p = r }
            if abs(A[p * m + c]) < 1e-12 { return nil }
            if p != c {
                for j in 0..<m { A.swapAt(c * m + j, p * m + j) }
                B.swapAt(c, p)
            }
            for r in (c + 1)..<max(m, c + 1) {
                let f = A[r * m + c] / A[c * m + c]
                if f == 0 { continue }
                for j in c..<m { A[r * m + j] -= f * A[c * m + j] }
                B[r] -= f * B[c]
            }
        }
        var x = [Double](repeating: 0, count: m)
        for r in stride(from: m - 1, through: 0, by: -1) {
            var s = B[r]
            for j in (r + 1)..<max(m, r + 1) { s -= A[r * m + j] * x[j] }
            x[r] = s / A[r * m + r]
        }
        return x
    }

    /// |H| in dB of one section at `hz`.
    static func magnitudeDB(_ s: Biquad, at hz: Double, sr: Double) -> Double {
        let w = 2.0 * Double.pi * hz / sr
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = s.b0 + s.b1 * c1 + s.b2 * c2, ni = -(s.b1 * s1 + s.b2 * s2)
        let dr = 1.0 + s.a1 * c1 + s.a2 * c2, di = -(s.a1 * s1 + s.a2 * s2)
        let p = (nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30)
        return 10 * log10(max(p, 1e-30))
    }
}
