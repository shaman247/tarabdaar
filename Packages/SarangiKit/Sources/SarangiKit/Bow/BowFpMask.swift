import Foundation

/// LIVE twin of the offline fingerprint mask (`bowstring._apply_fp_mask`) —
/// the per-(midi, harmonic) closed-loop static-timbre owner (mean ~7.5 dB,
/// p90 ~14 dB of authority; without it the live bow is a different
/// instrument from the deliverable).
///
/// The offline mask is a zero-phase harmonic-STFT operation: per frame, bins
/// within ±0.5·f0 of harmonic h·f0 get gain 1 + w·(g_h − 1) with w a raised
/// cosine (1 at the harmonic, 0 at the midpoints — the inter-harmonic taraf
/// bed is untouched). Per the live-twin law (CoupledTapTests precedent) the
/// live form is CAUSAL and MAGNITUDE-MATCHED, excluded from sample-exact
/// goldens: y = x + Σ_h (g_h − 1) · band_h(x), where band_h is a heterodyne
/// band filter that tracks h·f0(t) exactly through glides —
///   u = x · e^{−j·h·φ(t)},  band = 2·Re( LP⁴(u) · e^{+j·h·φ(t)} ),
/// with φ accumulated from the SAME control f0 the kernel bows, and LP⁴ four
/// cascaded complex one-poles at fc = 0.3885·f0 (half-gain at 0.25·f0,
/// matching the raised cosine's half-gain point; midpoint leak ≈ −17 dB,
/// adjacent-harmonic leak ≈ −35 dB).
///
/// Gain law per block (2.7 ms), mirroring `_apply_fp_mask` (the lookup midi
/// diverges only as `holdMidi` documents):
/// the HOLD-STABLE + SNAP-TO-CELL lookup midi (see `holdMidi`), per-h
/// `np.interp` over that h's measured midi knots (h with < 3 cells is
/// inert), the nearest-cell support guard (full within 1.5 st, zero by
/// 3 st), and the 3-frame-MA temporal smoothing as a ~12 ms one-pole slew
/// on the dB.
public struct BowFpMask: Sendable {
    public static let hMax = 16
    static let poles = 4                 // LP⁴ — see leak figures above
    static let fcRatio = 0.3885          // fc / f0 (half-gain at 0.25·f0)
    static let blockLen = 128            // gain/coefficient update stride

    struct HarmRow: Sendable {
        var xs: [Double]                 // measured midis (sorted)
        var ys: [Double]                 // dB at those midis
    }

    let rows: [HarmRow?]                 // [hMax+1]; nil = inert harmonic
    let sr: Double
    let aSlew: Double                    // ~12 ms dB slew (offline 3-frame MA)
    /// Every measured base cell's midi (union over h — the offline snap set
    /// ignores the per-h cell count), sorted.
    let cellMidis: [Double]
    // hold-stable horizons. The offline law counts 512/44.1k STFT frames;
    // these carry the same DURATIONS at the live block rate.
    let medWin: Int                      // trailing median window (~9 frames)
    let runNeed: Int                     // off-cell blocks before a commit test
    let setWin: Int                      // settle-evidence window (~8 frames)
    let slewSt: Double                   // per-block cap of the slow follow

    // ---- render state (no allocation in process) ----
    var phase = 0.0                      // fundamental phase (radians)
    var zRe: [Double], zIm: [Double]     // LP states, [h][pole] flattened
    var dbCur: [Double]                  // slewed per-h dB
    var gm1: [Double]                    // per-h (g − 1), block-constant
    var aLp = 0.0                        // LP coefficient, block-constant
    var active: [Bool]                   // h usable this block
    // hold-stable lookup state
    var hist: [Double]                   // trailing block midis (ring)
    var sortBuf: [Double]                // median scratch (no allocation)
    var histPos = 0, histN = 0
    var mCur = 0.0                       // the held lookup midi
    var runCnt = 0
    var mInit = false

    /// Parse `params/sarangi_bow_fp.json` ("midi_h": dB). Returns nil when
    /// the table is empty/absent (mask = identity — a dev checkout).
    public init?(url: URL, sr: Double) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any], !dict.isEmpty
        else { return nil }
        var cells: [Int: [(Double, Double)]] = [:]
        var midiSet = Set<Double>()
        for (k, v) in dict {
            let parts = k.split(separator: "_")
            guard parts.count == 2, let m = Double(parts[0]),
                  let h = Int(parts[1]), let n = v as? NSNumber
            else { continue }               // 3-part keys = phase cells
            midiSet.insert(m)
            guard h >= 1, h <= Self.hMax else { continue }
            cells[h, default: []].append((m, n.doubleValue))
        }
        guard !cells.isEmpty else { return nil }
        var r: [HarmRow?] = Array(repeating: nil, count: Self.hMax + 1)
        for (h, pts) in cells where pts.count >= 3 {   // offline < 3 ⇒ skip
            let s = pts.sorted { $0.0 < $1.0 }
            r[h] = HarmRow(xs: s.map(\.0), ys: s.map(\.1))
        }
        rows = r
        cellMidis = midiSet.sorted()
        self.sr = sr
        aSlew = exp(-Double(Self.blockLen) / (0.012 * sr))
        // offline frames per live block: the hold horizons are DURATIONS
        let bpf = (512.0 / 44100.0) * sr / Double(Self.blockLen)
        medWin = max(1, Int((9.0 * bpf).rounded()))
        runNeed = max(1, Int((3.0 * bpf).rounded()))
        setWin = max(1, Int((8.0 * bpf).rounded()))
        slewSt = 0.02 / max(bpf, 1e-9)
        hist = [Double](repeating: 0, count: max(medWin, setWin))
        sortBuf = hist
        zRe = [Double](repeating: 0, count: (Self.hMax + 1) * Self.poles)
        zIm = [Double](repeating: 0, count: (Self.hMax + 1) * Self.poles)
        dbCur = [Double](repeating: 0, count: Self.hMax + 1)
        gm1 = [Double](repeating: 0, count: Self.hMax + 1)
        active = [Bool](repeating: false, count: Self.hMax + 1)
    }

    @inline(__always) mutating func pushHist(_ m: Double) {
        hist[histPos] = m
        histPos = (histPos + 1) % hist.count
        if histN < hist.count { histN += 1 }
    }

    /// Population median + std over the `k` most recent block midis (np's
    /// even-length median averages the two middles). Sorts into the fixed
    /// scratch — the render thread allocates nothing.
    mutating func trailStats(_ k: Int) -> (med: Double, sd: Double) {
        let n = max(1, min(k, histN))
        for i in 0..<n {
            var p = histPos - 1 - i
            if p < 0 { p += hist.count }
            sortBuf[i] = hist[p]
        }
        var mean = 0.0
        for i in 0..<n { mean += sortBuf[i] }
        mean /= Double(n)
        var v = 0.0
        for i in 0..<n { let d = sortBuf[i] - mean; v += d * d }
        for i in 1..<n {                      // insertion sort
            let x = sortBuf[i]
            var j = i - 1
            while j >= 0 && sortBuf[j] > x { sortBuf[j + 1] = sortBuf[j]; j -= 1 }
            sortBuf[j + 1] = x
        }
        let med = n % 2 == 1 ? sortBuf[n / 2]
            : 0.5 * (sortBuf[n / 2 - 1] + sortBuf[n / 2])
        return (med, (v / Double(n)).squareRoot())
    }

    /// HOLD-STABLE + SNAP-TO-CELL lookup midi (offline `_apply_fp_mask`,
    /// 2026-07-15): the fingerprint belongs to the STOPPED POSITION and the
    /// hand does not move during a hold, so the LOOKUP pitch follows the
    /// track with hysteresis — it commits only when the pitch stays >0.6 st
    /// away for `runNeed` blocks AND the note has settled (std < 0.3),
    /// otherwise it slow-follows the local median. Without it a semitone of
    /// tail wobble sweeps the cell interpolation across CLIFF neighbors
    /// (h3 rows carry ±15 dB per-note corrections = the pair20 bleed).
    /// LIVE-TWIN differences — there is no future here, and these two are
    /// the complete set, both FORCED by causality:
    ///  1. the settle evidence is the TRAILING window (offline reads the 8
    ///     frames AHEAD), so a new note's cells commit about one settle
    ///     window later than offline;
    ///  2. the slow-follow reference is the trailing median, where offline
    ///     runs a CENTERED 9-frame `median_filter` — same window LENGTH,
    ///     ~half-window (≈4 offline frames) of lag, and the ±`slewSt` cap
    ///     bounds the divergence either way.
    /// The SEED is not a third divergence: offline `cur = med9[0]` under
    /// `mode="nearest"` is identically `midi[0]` (five copies of the first
    /// frame own a 9-tap median for any track), i.e. this `mCur = raw`.
    /// The heterodyne band placement
    /// still rides the raw sounding f0 — only WHICH note's cells apply is
    /// stabilized.
    mutating func holdMidi(_ raw: Double) -> Double {
        pushHist(raw)
        if !mInit {
            mCur = raw
            mInit = true
        } else if abs(raw - mCur) > 0.6 {
            runCnt += 1
            if runCnt >= runNeed {
                // commit only onto a STABLE new note — a ring tail wanders
                // in sustained >0.6 st excursions that are not notes
                let s = trailStats(setWin)
                if s.sd < 0.3 { mCur = s.med }
                runCnt = 0
            }
        } else {
            runCnt = 0
            let med = trailStats(medWin).med
            if abs(med - mCur) < 0.3 {
                mCur += min(max(med - mCur, -slewSt), slewSt)
            }
        }
        // SNAP-TO-CELL: a note sitting on a measured cell takes THAT cell's
        // correction exactly (linear interp bled half of a ±15 dB neighbour
        // across the midpoint); between cells — real glides — interp stands.
        var m = mCur
        if let first = cellMidis.first {
            var near = first
            for c in cellMidis where abs(c - m) < abs(near - m) { near = c }
            if abs(m - near) < 0.25 { m = near }
        }
        return m
    }

    /// The offline gain law at one midi: np.interp (clamped ends) + the
    /// nearest-cell support guard.
    @inline(__always) func targetDb(h: Int, midi: Double) -> Double {
        guard let row = rows[h] else { return 0.0 }
        let xs = row.xs, ys = row.ys
        var db: Double
        if midi <= xs[0] { db = ys[0] } else if midi >= xs[xs.count - 1] {
            db = ys[ys.count - 1]
        } else {
            var i = 0
            while i + 1 < xs.count && xs[i + 1] < midi { i += 1 }
            let t = (midi - xs[i]) / max(xs[i + 1] - xs[i], 1e-12)
            db = ys[i] + t * (ys[i + 1] - ys[i])
        }
        var dist = Double.greatestFiniteMagnitude
        for x in xs { dist = min(dist, abs(midi - x)) }
        let wSup = min(max((3.0 - dist) / 1.5, 0.0), 1.0)
        return db * wSup
    }

    /// Apply in place over one buffer. `f0` = the kernel-rate control track
    /// (the SAME smoothed f0 the kernel bows), sampled with `f0Stride`
    /// (= the oversampling factor) to the engine rate.
    public mutating func process(_ buf: UnsafeMutablePointer<Double>, n: Int,
                                 f0: UnsafePointer<Double>, f0Stride: Int) {
        var i = 0
        while i < n {
            let m = min(Self.blockLen, n - i)
            let f = max(f0[i * f0Stride], 40.0)
            // block-rate gain/coefficient update
            let midi = holdMidi(69.0 + 12.0 * log2(f / 440.0))
            aLp = exp(-2.0 * Double.pi * Self.fcRatio * f / sr)
            var any = false
            for h in 1...Self.hMax {
                let ok = rows[h] != nil && Double(h) * f < 0.45 * sr
                active[h] = ok
                let tgt = ok ? targetDb(h: h, midi: midi) : 0.0
                dbCur[h] = (1.0 - aSlew) * tgt + aSlew * dbCur[h]
                gm1[h] = ok ? pow(10.0, dbCur[h] / 20.0) - 1.0 : 0.0
                if ok && abs(gm1[h]) > 1e-4 { any = true }
            }
            if !any {
                // keep phase/state coherent through inert stretches
                for k in i..<(i + m) {
                    phase += 2.0 * Double.pi * max(f0[k * f0Stride], 40.0) / sr
                    if phase > Double.pi * 2.0 { phase -= Double.pi * 2.0 }
                }
                i += m
                continue
            }
            let oneMinusA = 1.0 - aLp
            for k in i..<(i + m) {
                let x = buf[k]
                phase += 2.0 * Double.pi * max(f0[k * f0Stride], 40.0) / sr
                if phase > Double.pi * 2.0 { phase -= Double.pi * 2.0 }
                let c1 = cos(phase), s1 = sin(phase)
                // iterate e^{-j·h·φ} by complex powering (one sincos/sample)
                var cr = 1.0, ci = 0.0
                var corr = 0.0
                for h in 1...Self.hMax {
                    let nr = cr * c1 + ci * s1     // × e^{-jφ}
                    let ni = ci * c1 - cr * s1
                    cr = nr; ci = ni
                    if !active[h] { continue }
                    let g = gm1[h]
                    // u = x·e^{-jhφ} through 4 cascaded complex one-poles
                    var ur = x * cr, ui = x * ci
                    let base = h * Self.poles
                    for p in 0..<Self.poles {
                        let r = oneMinusA * ur + aLp * zRe[base + p]
                        let im = oneMinusA * ui + aLp * zIm[base + p]
                        zRe[base + p] = r; zIm[base + p] = im
                        ur = r; ui = im
                    }
                    if abs(g) > 1e-4 {
                        // band = 2·Re(LP(u)·e^{+jhφ})
                        corr += g * 2.0 * (ur * cr - ui * (-ci))
                    }
                }
                buf[k] = x + corr
            }
            i += m
        }
    }

    public mutating func reset() {
        phase = 0
        for i in zRe.indices { zRe[i] = 0; zIm[i] = 0 }
        for i in dbCur.indices { dbCur[i] = 0 }
        for i in hist.indices { hist[i] = 0 }
        histPos = 0; histN = 0; runCnt = 0
        mInit = false
    }
}
