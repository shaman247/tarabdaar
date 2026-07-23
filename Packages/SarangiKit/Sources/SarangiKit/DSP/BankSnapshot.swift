import Foundation

// MARK: - Raw snapshot (cheap copies, taken under the host lock)

/// One sympathetic string's live state for the Harmonics-tab display.
/// `buffer` is the comb's one-period delay line (length `period`); its DFT at
/// integer bins gives the per-harmonic amplitudes directly. `outWeight` scales
/// those amplitudes to the string's relative audible contribution
/// (`relOverSqrtN·gChoir` — the passive junction's per-string weight law).
public struct StringRawSnapshot: Sendable {
    public let freq: Double          // effective ringing f0 = sr/period
    public let isBright: Bool
    public let group: StringGroup
    public let outWeight: Double
    public let period: Int           // L
    public let buffer: [Double]      // one-period copy
    public init(freq: Double, isBright: Bool, group: StringGroup,
                outWeight: Double, period: Int, buffer: [Double]) {
        self.freq = freq; self.isBright = isBright; self.group = group
        self.outWeight = outWeight; self.period = period; self.buffer = buffer
    }
}

/// A pure-data snapshot of the sympathetic bank + the recent played-note drive,
/// copied under the host lock so the (heavier) harmonic DFT can run off-lock.
/// `playedF0`/`playedActive` are filled by the host (it owns the MIDI pitch).
public struct BankRawSnapshot: Sendable {
    public let sr: Double
    public let strings: [StringRawSnapshot]
    public let inputRing: [Double]     // recent drive `x`, time-ordered (oldest first)
    public let playedWeight: Double    // mainGain — the played voice's display level
    public var playedF0: Double        // current played pitch (Hz); set by host
    public var playedActive: Bool      // a note is held; set by host
    public init(sr: Double, strings: [StringRawSnapshot], inputRing: [Double],
                playedWeight: Double, playedF0: Double, playedActive: Bool) {
        self.sr = sr; self.strings = strings; self.inputRing = inputRing
        self.playedWeight = playedWeight; self.playedF0 = playedF0; self.playedActive = playedActive
    }
}

// MARK: - Analysis output (display model)

/// Which kind of column a harmonic belongs to. `.played` is the bowed exciter
/// (always the leading column); `.sympathetic` carries the string's choir tag
/// for grouping. Display-only — keeps `.played` out of the persisted enum.
public enum ColumnKind: Sendable, Equatable {
    case played
    case sympathetic(StringGroup)

    /// Left-to-right ordering: Played first, then choirs in `StringGroup` order.
    public var order: Int {
        switch self {
        case .played: return -1
        case .sympathetic(let g): return StringGroup.allCases.firstIndex(of: g) ?? 0
        }
    }
}

/// One column of the harmonic heatmap (a played note or a sympathetic string).
public struct ColumnInfo: Sendable {
    public let kind: ColumnKind
    public let f0: Double             // representative fundamental (0 if idle/played-off)
    public init(kind: ColumnKind, f0: Double) { self.kind = kind; self.f0 = f0 }
}

/// One (column, harmonic) datum: a band at `freqHz` with linear `magnitude`.
public struct HarmonicCell: Sendable {
    public let columnIndex: Int
    public let harmonic: Int         // k ≥ 1
    public let freqHz: Double        // effective pitch (k·sr/L for strings, k·f0 for played)
    public let magnitude: Double     // linear amplitude · weight
    public init(columnIndex: Int, harmonic: Int, freqHz: Double, magnitude: Double) {
        self.columnIndex = columnIndex; self.harmonic = harmonic
        self.freqHz = freqHz; self.magnitude = magnitude
    }
}

/// The analysed harmonic content: stable `columns` (x-axis) + the active `cells`.
public struct BankAnalysis: Sendable {
    public let columns: [ColumnInfo]
    public let cells: [HarmonicCell]
    public init(columns: [ColumnInfo], cells: [HarmonicCell]) {
        self.columns = columns; self.cells = cells
    }
}

// MARK: - Analyzer

/// Turns a `BankRawSnapshot` into per-(column, harmonic) magnitudes for the
/// Live-tab display. Pure / off-thread. Strings use a rectangular one-period DFT
/// of the comb buffer (exact harmonics); the played note uses a Hann-windowed
/// DFT of the input ring at the played pitch's harmonics.
public enum BankAnalyzer {
    /// Below this peak buffer amplitude a string is treated as silent (no DFT).
    static let silenceEps = 1e-5
    /// Cells weaker than this (linear, post-weight) are dropped to bound count.
    static let cellEps = 1e-7

    public static func analyze(_ snap: BankRawSnapshot,
                               maxHarmonics: Int = 24,
                               freqCeilingHz: Double = 8000) -> BankAnalysis {
        let sr = snap.sr
        var columns: [ColumnInfo] = []
        var cells: [HarmonicCell] = []

        // Build the column list first (stable x-axis): Played leads, then strings
        // sorted by choir then ascending pitch. Remember each string's column idx.
        columns.append(ColumnInfo(kind: .played,
                                   f0: snap.playedActive ? snap.playedF0 : 0))
        let playedCol = 0

        let order = snap.strings.indices.sorted { a, b in
            let ka = ColumnKind.sympathetic(snap.strings[a].group).order
            let kb = ColumnKind.sympathetic(snap.strings[b].group).order
            if ka != kb { return ka < kb }
            return snap.strings[a].freq < snap.strings[b].freq
        }
        var colOfString = [Int](repeating: 0, count: snap.strings.count)
        for s in order {
            colOfString[s] = columns.count
            columns.append(ColumnInfo(kind: .sympathetic(snap.strings[s].group),
                                      f0: snap.strings[s].freq))
        }

        // Played note: windowed DFT of the input ring at k·playedF0.
        if snap.playedActive, snap.playedF0 > 0 {
            playedCells(into: &cells, ring: snap.inputRing, sr: sr,
                        f0: snap.playedF0, weight: snap.playedWeight,
                        column: playedCol, maxHarmonics: maxHarmonics, ceiling: freqCeilingHz)
        }

        // Sympathetic strings: rectangular one-period DFT of each comb buffer.
        for s in snap.strings.indices {
            let str = snap.strings[s]
            let L = str.period
            guard L >= 2, str.buffer.count >= L else { continue }
            var peak = 0.0
            for n in 0..<L { let a = abs(str.buffer[n]); if a > peak { peak = a } }
            if peak < silenceEps { continue }            // idle → no bands

            let kMax = min(maxHarmonics,
                           Int(floor(freqCeilingHz * Double(L) / sr)),
                           L / 2)
            guard kMax >= 1 else { continue }
            let col = colOfString[s]
            let twoOverL = 2.0 / Double(L)
            for k in 1...kMax {
                var re = 0.0, im = 0.0
                let w = 2.0 * Double.pi * Double(k) / Double(L)
                for n in 0..<L {
                    let ph = w * Double(n)
                    re += str.buffer[n] * cos(ph)
                    im -= str.buffer[n] * sin(ph)
                }
                let mag = twoOverL * (re * re + im * im).squareRoot() * str.outWeight
                if mag < cellEps { continue }
                cells.append(HarmonicCell(columnIndex: col, harmonic: k,
                                          freqHz: Double(k) * sr / Double(L), magnitude: mag))
            }
        }

        return BankAnalysis(columns: columns, cells: cells)
    }

    /// Hann-windowed DFT of the input ring at k·f0 for the played-note column.
    private static func playedCells(into cells: inout [HarmonicCell],
                                    ring: [Double], sr: Double, f0: Double, weight: Double,
                                    column: Int, maxHarmonics: Int, ceiling: Double) {
        let N = ring.count
        guard N >= 16, f0 > 0 else { return }
        // Hann window + its sum (for amplitude normalisation).
        var win = [Double](repeating: 0, count: N)
        var winSum = 0.0
        for n in 0..<N {
            let wv = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(n) / Double(N - 1))
            win[n] = wv; winSum += wv
        }
        guard winSum > 0 else { return }
        let norm = 2.0 / winSum
        let kMax = min(maxHarmonics, Int(floor(ceiling / f0)))
        guard kMax >= 1 else { return }
        for k in 1...kMax {
            let fk = Double(k) * f0
            let w = 2.0 * Double.pi * fk / sr
            var re = 0.0, im = 0.0
            for n in 0..<N {
                let ph = w * Double(n)
                let s = win[n] * ring[n]
                re += s * cos(ph)
                im -= s * sin(ph)
            }
            let mag = norm * (re * re + im * im).squareRoot() * weight
            if mag < cellEps { continue }
            cells.append(HarmonicCell(columnIndex: column, harmonic: k, freqHz: fk, magnitude: mag))
        }
    }
}
