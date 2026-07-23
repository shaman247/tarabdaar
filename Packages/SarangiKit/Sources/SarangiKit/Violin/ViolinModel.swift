import Foundation

/// Fitted violin model (params/violin_model.json) — 1:1 port of the Python
/// `src/violin/model.py` ViolinModel: control-grid dB tables for 64 harmonics
/// and 24 noise bands, attack/release templates, legato/jitter/intonation.
/// All evaluation is deterministic and mirrors the Python numerics so the
/// harmonic path is sample-parity-testable (see ViolinParityTests).
public final class ViolinModel {
    public let sr: Double
    public let hMax: Int
    public let fLim: Double
    public let frameRate: Double

    // grid axes
    public let midiAxis: [Double]
    public let exprAxis: [Double]
    public let pressAxis: [Double]
    public let posAxis: [Double]

    // flat tables, row-major, shapes as in Python
    let harmDb: [Double]            // (H, Nm, Ne, Np, Nb)
    let noiseDb: [Double]           // (K, Nm, Ne, Np, Nb)
    public let noiseEdges: [Double] // (K+1,)
    public let noiseCalDb: [Double] // (K,)
    public let noiseSOS: [[Double]] // (K, sections*6) flattened per band

    // templates
    public let attackMidiPts: [Double]
    public let attackPressPts: [Double]
    let attackGain: [Double]        // (Pm, Pp, G, Ta)
    let attackNoise: [Double]       // (Pm, Pp, K, Ta)
    let releaseGain: [Double]       // (Pm, Pp, G, Tr)
    let releaseSlopeDb: [Double]    // (Nm, Np) — full grid
    let attackLatencyMs: [Double]   // (Pm, Pp)
    public let ta: Int              // attack template frames
    public let tr: Int              // release template frames

    public let legato: [String: Double]
    public let glidePts: [(st: Double, ms: Double)]
    public let jitter: [String: Double]
    let intonationCents: [Double]?  // (Nm,)

    public let hGroups: [(lo: Int, hi: Int)]
    public var nBands: Int { noiseEdges.count - 1 }
    public var nGroups: Int { hGroups.count }

    public static let floorDb = -120.0

    public enum LoadError: Error { case badJSON(String) }

    // MARK: - loading

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.badJSON("top level is not an object")
        }
        try self.init(json: j)
    }

    public init(json j: [String: Any]) throws {
        func num(_ key: String) throws -> Double {
            guard let v = j[key] as? NSNumber else { throw LoadError.badJSON(key) }
            return v.doubleValue
        }
        func doubles(_ v: Any?) throws -> [Double] {
            guard let a = v as? [Any] else { throw LoadError.badJSON("array expected") }
            return a.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        }
        func table(_ key: String) throws -> (shape: [Int], data: [Double]) {
            guard let d = j[key] as? [String: Any],
                  let shape = d["shape"] as? [Int] else { throw LoadError.badJSON(key) }
            return (shape, try doubles(d["data"]))
        }
        sr = try num("sr")
        hMax = Int(try num("h_max"))
        fLim = try num("f_lim")
        frameRate = try num("frame_rate")
        guard let axes = j["axes"] as? [String: Any] else { throw LoadError.badJSON("axes") }
        midiAxis = try doubles(axes["midi"])
        exprAxis = try doubles(axes["expression"])
        pressAxis = try doubles(axes["bow_pressure"])
        posAxis = try doubles(axes["bow_position"])

        let harm = try table("harm_db")
        harmDb = harm.data
        let noise = try table("noise_db")
        noiseDb = noise.data
        noiseEdges = try doubles(j["noise_edges"])
        noiseCalDb = try doubles(j["noise_cal_db"])
        if let sosT = try? table("noise_sos") {
            let per = sosT.shape[1] * sosT.shape[2]     // sections * 6
            noiseSOS = (0..<sosT.shape[0]).map {
                Array(sosT.data[$0 * per..<($0 + 1) * per])
            }
        } else {
            noiseSOS = []
        }

        guard let aax = j["attack_axes"] as? [String: Any] else { throw LoadError.badJSON("attack_axes") }
        attackMidiPts = try doubles(aax["midi"])
        attackPressPts = try doubles(aax["press"])
        let ag = try table("attack_gain")
        attackGain = ag.data
        ta = ag.shape[3]
        attackNoise = try table("attack_noise").data
        let rg = try table("release_gain")
        releaseGain = rg.data
        tr = rg.shape[3]
        releaseSlopeDb = try table("release_slope_db").data
        attackLatencyMs = try table("attack_latency_ms").data

        guard let leg = j["legato"] as? [String: Any] else { throw LoadError.badJSON("legato") }
        var legD: [String: Double] = [:]
        var gp: [(Double, Double)] = []
        for (k, v) in leg {
            if k == "glide_pts", let pts = v as? [[Any]] {
                gp = pts.compactMap { p in
                    guard p.count == 2, let a = p[0] as? NSNumber, let b = p[1] as? NSNumber
                    else { return nil }
                    return (a.doubleValue, b.doubleValue)
                }.sorted { $0.0 < $1.0 }
            } else if let n = v as? NSNumber {
                legD[k] = n.doubleValue
            }
        }
        legato = legD
        glidePts = gp.map { (st: $0.0, ms: $0.1) }
        // jitter carries SCALAR keys plus occasional array-valued fit
        // artifacts (e.g. group_db_rms_groups, numpy-side only) — a whole-
        // dict cast to [String: NSNumber] fails on those, so keep the
        // scalars and skip the rest (Swift reads scalar keys only)
        guard let jit = j["jitter"] as? [String: Any] else { throw LoadError.badJSON("jitter") }
        jitter = jit.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        intonationCents = (j["intonation_cents"] as? [Any]).flatMap { try? doubles($0) }
        if let hg = j["h_groups"] as? [[Int]] {
            hGroups = hg.map { (lo: $0[0], hi: $0[1]) }
        } else {
            hGroups = [(1, 1), (2, 2), (3, 4), (5, 6), (7, 10), (11, 16), (17, 32), (33, 64)]
        }
    }

    // MARK: - interpolation primitives (mirror src/violin/surfaces.py)

    public static func midiOf(_ f0: Double) -> Double {
        69.0 + 12.0 * log2(max(f0, 1.0) / 440.0)
    }

    struct Corner { var idx: [Int]; var w: Double }

    /// `extrap` (nil = legacy clamp): per-axis maximum EXTRAPOLATION distance
    /// in edge-interval units — out-of-range queries continue the edge cells'
    /// linear trend (negative corner weights) instead of saturating; mirrors
    /// surfaces.interp_weights.
    static func interpWeights(_ axes: [[Double]], _ q: [Double],
                              extrap: [Double]? = nil) -> [Corner] {
        var los = [Int](repeating: 0, count: axes.count)
        var ts = [Double](repeating: 0, count: axes.count)
        for (k, a) in axes.enumerated() {
            let ex = extrap?[k] ?? 0.0
            let vc = min(max(q[k], a[0]), a[a.count - 1])
            if a.count == 1 { los[k] = 0; ts[k] = 0; continue }
            var jdx = a.firstIndex(where: { $0 > vc }).map { $0 - 1 } ?? (a.count - 2)
            jdx = max(0, min(jdx, a.count - 2))
            los[k] = jdx
            let src = ex > 0 ? q[k] : vc
            let lo = jdx == 0 ? -ex : 0.0
            let hi = jdx == a.count - 2 ? 1.0 + ex : 1.0
            ts[k] = min(max((src - a[jdx]) / max(a[jdx + 1] - a[jdx], 1e-12), lo), hi)
        }
        var out: [Corner] = []
        let d = axes.count
        for mask in 0..<(1 << d) {
            var idx = [Int](repeating: 0, count: d)
            var w = 1.0
            for k in 0..<d {
                let hi = (mask >> k) & 1
                if axes[k].count == 1 {
                    if hi == 1 { w = 0 }
                    idx[k] = 0
                } else {
                    idx[k] = los[k] + hi
                    w *= hi == 1 ? ts[k] : (1.0 - ts[k])
                }
            }
            if w != 0 { out.append(Corner(idx: idx, w: w)) }
        }
        return out
    }

    // MARK: - evaluation

    /// press/pos extrapolation bounds — mirror of ViolinModel.EXTRAP_PP /
    /// EXTRAP_DB in src/violin/model.py (keep in lockstep)
    public static let extrapPP = 2.0
    public static let extrapDb = 12.0

    /// Sustain surfaces at a control point. Writes hMax harmonic dB values and
    /// nBands noise dB values into the provided buffers. press/pos queries
    /// beyond the capture grid EXTRAPOLATE the edge trend (capped ±extrapDb
    /// vs the edge value); midi/expr stay clamped.
    public func evalSurfaces(midi: Double, expr: Double, press: Double, pos: Double,
                             harmOut: inout [Double], noiseOut: inout [Double]) {
        let inPP = press >= pressAxis[0] && press <= pressAxis[pressAxis.count - 1]
            && pos >= posAxis[0] && pos <= posAxis[posAxis.count - 1]
        if inPP {
            evalSurfacesRaw(midi: midi, expr: expr, press: press, pos: pos,
                            extrap: nil, harmOut: &harmOut, noiseOut: &noiseOut)
            return
        }
        // out-of-range: extrapolated eval, clamped ±extrapDb around the
        // edge-clamped eval (un-measured territory — trend, not data).
        // Allocates two scratch buffers; only runs while the player holds a
        // control beyond the grid (control-rate, tiny) — acceptable.
        evalSurfacesRaw(midi: midi, expr: expr, press: press, pos: pos,
                        extrap: [0, 0, Self.extrapPP, Self.extrapPP],
                        harmOut: &harmOut, noiseOut: &noiseOut)
        var hC = [Double](repeating: 0, count: hMax)
        var nC = [Double](repeating: 0, count: nBands)
        let pc = min(max(press, pressAxis[0]), pressAxis[pressAxis.count - 1])
        let qc = min(max(pos, posAxis[0]), posAxis[posAxis.count - 1])
        evalSurfacesRaw(midi: midi, expr: expr, press: pc, pos: qc,
                        extrap: nil, harmOut: &hC, noiseOut: &nC)
        for h in 0..<hMax {
            harmOut[h] = min(max(harmOut[h], hC[h] - Self.extrapDb),
                             hC[h] + Self.extrapDb)
        }
        for k in 0..<nBands {
            noiseOut[k] = min(max(noiseOut[k], nC[k] - Self.extrapDb),
                              nC[k] + Self.extrapDb)
        }
    }

    func evalSurfacesRaw(midi: Double, expr: Double, press: Double, pos: Double,
                         extrap: [Double]?,
                         harmOut: inout [Double], noiseOut: inout [Double]) {
        let axes = [midiAxis, exprAxis, pressAxis, posAxis]
        let corners = Self.interpWeights(axes, [midi, expr, press, pos],
                                         extrap: extrap)
        let nm = midiAxis.count, ne = exprAxis.count, np_ = pressAxis.count, nb = posAxis.count
        let cellCount = nm * ne * np_ * nb
        var offsets = [Int](repeating: 0, count: corners.count)
        var weights = [Double](repeating: 0, count: corners.count)
        for (i, c) in corners.enumerated() {
            offsets[i] = ((c.idx[0] * ne + c.idx[1]) * np_ + c.idx[2]) * nb + c.idx[3]
            weights[i] = c.w
        }
        for h in 0..<hMax {
            var acc = 0.0, wsum = 0.0
            let base = h * cellCount
            for i in 0..<offsets.count {
                let v = harmDb[base + offsets[i]]
                if v > Self.floorDb + 1 { acc += weights[i] * v; wsum += weights[i] }
            }
            harmOut[h] = wsum > 1e-9 ? acc / wsum : Self.floorDb
        }
        for k in 0..<nBands {
            var acc = 0.0, wsum = 0.0
            let base = k * cellCount
            for i in 0..<offsets.count {
                let v = noiseDb[base + offsets[i]]
                if v > Self.floorDb + 1 { acc += weights[i] * v; wsum += weights[i] }
            }
            noiseOut[k] = wsum > 1e-9 ? acc / wsum : Self.floorDb
        }
    }

    /// Bilinear template mix at (midi, press). Buffers: (G, Ta), (K, Ta), (G, Tr).
    public func evalTemplates(midi: Double, press: Double,
                              attackOut: inout [Double], attackNoiseOut: inout [Double],
                              releaseOut: inout [Double]) -> Double {
        let corners = Self.interpWeights([attackMidiPts, attackPressPts], [midi, press])
        let pp = attackPressPts.count
        let g = nGroups, k = nBands
        for i in 0..<attackOut.count { attackOut[i] = 0 }
        for i in 0..<attackNoiseOut.count { attackNoiseOut[i] = 0 }
        for i in 0..<releaseOut.count { releaseOut[i] = 0 }
        var latency = 0.0
        for c in corners {
            let cell = c.idx[0] * pp + c.idx[1]
            let aBase = cell * g * ta
            for i in 0..<(g * ta) { attackOut[i] += c.w * attackGain[aBase + i] }
            let nBase = cell * k * ta
            for i in 0..<(k * ta) { attackNoiseOut[i] += c.w * attackNoise[nBase + i] }
            let rBase = cell * g * tr
            for i in 0..<(g * tr) { releaseOut[i] += c.w * releaseGain[rBase + i] }
            latency += c.w * attackLatencyMs[cell]
        }
        return latency
    }

    /// dB/frame tail decay, bilinear on the full midi × pressure grid.
    public func evalReleaseSlope(midi: Double, press: Double) -> Double {
        let corners = Self.interpWeights([midiAxis, pressAxis], [midi, press])
        let np_ = pressAxis.count
        var s = 0.0
        for c in corners { s += c.w * releaseSlopeDb[c.idx[0] * np_ + c.idx[1]] }
        return s
    }

    /// SWAM's fitted per-pitch intonation offset applied to a nominal f0.
    public func tuned(_ f0: Double) -> Double {
        guard let cents = intonationCents else { return f0 }
        let m = Self.midiOf(f0)
        let a = midiAxis
        var c: Double
        if m <= a[0] { c = cents[0] } else if m >= a[a.count - 1] { c = cents[cents.count - 1] }
        else {
            var i = a.firstIndex(where: { $0 > m })! - 1
            i = max(0, min(i, a.count - 2))
            let t = (m - a[i]) / max(a[i + 1] - a[i], 1e-12)
            c = cents[i] + (cents[i + 1] - cents[i]) * t
        }
        return f0 * pow(2.0, c / 1200.0)
    }

    /// Legato glide duration for an interval in semitones.
    public func glideMs(st: Double) -> Double {
        if !glidePts.isEmpty {
            let xs = glidePts.map(\.st), ys = glidePts.map(\.ms)
            if st <= xs[0] { return ys[0] }
            if st >= xs[xs.count - 1] { return ys[ys.count - 1] }
            let i = xs.firstIndex(where: { $0 > st })! - 1
            let t = (st - xs[i]) / max(xs[i + 1] - xs[i], 1e-12)
            return ys[i] + (ys[i + 1] - ys[i]) * t
        }
        return (legato["glide_ms_base"] ?? 30) + (legato["glide_ms_per_st"] ?? 0) * st
    }

    public func groupOf(_ h: Int) -> Int {
        for (g, r) in hGroups.enumerated() where h >= r.lo && h <= r.hi { return g }
        return hGroups.count - 1
    }
}
