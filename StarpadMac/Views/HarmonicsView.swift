import SarangiKit
import StarpadCore
import SwiftUI

/// "Harmonics" tab (⌘2). A live **harmonic heatmap** of the sarangi voice — the
/// sympathetic strings flaring in and out of resonance as the played pitch
/// slides. X = columns (the bowed **Played** note, then the sympathetic strings
/// grouped by choir, each sorted by ascending pitch); Y = log frequency; each
/// harmonic is a band colored by intensity (dB → heat, relative to a
/// slow-decaying 0 dB reference so quiet stays dark). A sidebar lists the 10
/// loudest harmonics.
///
/// Data comes from `AudioEngine.sarangiBankSnapshot()` (a brief lock-held copy of
/// each comb's one-period delay buffer, whose DFT yields that string's harmonic
/// amplitudes directly) → `BankAnalyzer.analyze` off-lock. Polled at ~30 Hz; each
/// (column, harmonic) magnitude is one-pole-smoothed to quell single-period
/// jitter. Display-only and **pre-FX** (bank energy, before the per-voice FX/body).
struct HarmonicsView: View {
    @ObservedObject var controller: AppController

    // The analysed bank spectrum + per-cell smoothing state.
    @State private var analysis: BankAnalysis? = nil
    @State private var smooth: [Int: Double] = [:]   // key = columnIndex·128 + harmonic
    @State private var smoothColumns = 0
    @State private var peakRef: Double = 1e-5         // slow-decaying 0 dB reference

    /// Top of the frequency axis (Hz).
    private static let ceilingHz: Double = 8000
    private let sample = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            HarmonicHeatmap(analysis: analysis, ceilingHz: Self.ceilingHz, refMag: peakRef)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            topTenList
                .frame(width: 248)
        }
        .padding(24)
        .onReceive(sample) { _ in updateHarmonics() }
    }

    /// Pull the bank snapshot, run the off-lock DFT, one-pole smooth each
    /// (column, harmonic) magnitude to quell single-period DFT jitter, and track
    /// a slow-decaying 0 dB reference (so quiet stays dark without re-normalising
    /// bright). Columns are stable frame-to-frame unless the bank rebuilds, so we
    /// key smoothing on the column index and reset when the column count changes.
    private func updateHarmonics() {
        guard let snap = controller.audio.sarangiBankSnapshot() else { return }
        let a = BankAnalyzer.analyze(snap, maxHarmonics: 24, freqCeilingHz: Self.ceilingHz)
        if a.columns.count != smoothColumns {
            smooth.removeAll(keepingCapacity: true)
            smoothColumns = a.columns.count
        }
        let alpha = 0.35
        var next: [Int: Double] = [:]; next.reserveCapacity(a.cells.count)
        var cells: [HarmonicCell] = []; cells.reserveCapacity(a.cells.count)
        var frameMax = 0.0
        for c in a.cells {
            let key = c.columnIndex * 128 + c.harmonic
            let v = alpha * c.magnitude + (1 - alpha) * (smooth[key] ?? 0)
            next[key] = v
            if v > frameMax { frameMax = v }
            cells.append(HarmonicCell(columnIndex: c.columnIndex, harmonic: c.harmonic,
                                      freqHz: c.freqHz, magnitude: v))
        }
        smooth = next
        peakRef = max(frameMax, peakRef * 0.992, 1e-5)   // ~3 s half-life decay
        analysis = BankAnalysis(columns: a.columns, cells: cells)
    }

    private var topTenList: some View {
        let cols = analysis?.columns ?? []
        let top = (analysis?.cells ?? [])
            .sorted { $0.magnitude > $1.magnitude }
            .prefix(10)
        return VStack(alignment: .leading, spacing: 6) {
            Text("LOUDEST HARMONICS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if top.isEmpty {
                Text("— nothing ringing —")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(top.enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 6) {
                        Text(HarmonicLabels.column(c.columnIndex, cols))
                            .frame(width: 58, alignment: .leading)
                            .foregroundStyle(HarmonicLabels.tint(c.columnIndex, cols))
                        Text("h\(c.harmonic)")
                            .frame(width: 26, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text("\(Int(c.freqHz.rounded())) Hz")
                            .frame(width: 60, alignment: .trailing)
                        Text(HarmonicLabels.note(c.freqHz))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shared label/tint helpers for the harmonic display (column name, choir color,
/// compact note name). Free of view state so both the heatmap and the list use them.
enum HarmonicLabels {
    static func note(_ hz: Double) -> String {
        guard hz > 0 else { return "—" }
        let midi = Int((69.0 + 12.0 * log2(hz / 440.0)).rounded())
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    static func column(_ idx: Int, _ cols: [ColumnInfo]) -> String {
        guard idx < cols.count else { return "—" }
        if case .played = cols[idx].kind { return "Played" }
        return note(cols[idx].f0)
    }

    static func tint(_ idx: Int, _ cols: [ColumnInfo]) -> Color {
        guard idx < cols.count else { return .secondary }
        return color(cols[idx].kind)
    }

    static func color(_ kind: ColumnKind) -> Color {
        switch kind {
        case .played: return .orange
        case .sympathetic(let g):
            switch g {
            case .chromatic:   return Color(red: 0.55, green: 0.72, blue: 1.0)
            case .scale:       return Color(red: 0.60, green: 1.0,  blue: 0.72)
            case .lowOctave:   return Color(red: 1.0,  green: 0.82, blue: 0.5)
            case .upperOctave: return Color(red: 0.85, green: 0.70, blue: 1.0)
            }
        }
    }

    static func groupName(_ kind: ColumnKind) -> String {
        switch kind {
        case .played: return "Played"
        case .sympathetic(let g): return g.label
        }
    }
}

/// The harmonic heatmap. **X** = columns (the bowed "Played" note, then the
/// sympathetic strings grouped by choir, each sorted by ascending pitch). **Y**
/// = log frequency. Each `HarmonicCell` is a band at its harmonic frequency,
/// colored by intensity (dB → heat, relative to a slow-decaying reference so
/// quiet stays dark). Fills the available space; redraws when `analysis` changes.
private struct HarmonicHeatmap: View {
    let analysis: BankAnalysis?
    let ceilingHz: Double
    let refMag: Double

    private let gutter: CGFloat = 38      // left frequency-label column
    private let labelStrip: CGFloat = 34  // bottom rotated string labels
    private let floorDb: Double = -54
    private let gridFreqs: [Double] = [100, 200, 300, 500, 1000, 2000, 3000, 5000, 8000]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HARMONIC SPECTRUM")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("bank energy · pre-FX")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Canvas { ctx, size in draw(&ctx, size) }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let plotW = max(1, w - gutter)
        let plotH = max(1, h - labelStrip)
        guard let a = analysis, !a.columns.isEmpty else { return }

        // Frequency axis (log): bottom = lowest string, top = ceiling.
        let fMax = ceilingHz
        let symF0s = a.columns.compactMap { col -> Double? in
            if case .sympathetic = col.kind, col.f0 > 0 { return col.f0 }
            return nil
        }
        let fMin = max(30, (symF0s.min() ?? 100) * 0.94)
        let logMin = log2(fMin), logMax = log2(fMax)
        func yFor(_ f: Double) -> CGFloat {
            let t = (log2(max(f, fMin)) - logMin) / (logMax - logMin)
            return plotH * CGFloat(1 - min(1, max(0, t)))
        }

        // Frequency gridlines + labels.
        for f in gridFreqs where f >= fMin && f <= fMax {
            let yy = yFor(f)
            var line = Path()
            line.move(to: CGPoint(x: gutter, y: yy))
            line.addLine(to: CGPoint(x: w, y: yy))
            ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
            let lbl = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
            ctx.draw(Text(lbl).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                     at: CGPoint(x: gutter - 4, y: yy), anchor: .trailing)
        }

        // Columns: separators where the choir changes, group headers + rotated
        // per-string labels, and a faint tint behind the Played column.
        let n = a.columns.count
        let colW = plotW / CGFloat(n)
        func colX(_ i: Int) -> CGFloat { gutter + CGFloat(i) * colW }
        var prevOrder: Int? = nil
        for i in 0..<n {
            let col = a.columns[i]
            let x0 = colX(i)
            let ord = col.kind.order
            let newGroup = (prevOrder == nil) || (prevOrder! != ord)
            if newGroup {
                if prevOrder != nil {
                    var sep = Path()
                    sep.move(to: CGPoint(x: x0, y: 0))
                    sep.addLine(to: CGPoint(x: x0, y: plotH))
                    ctx.stroke(sep, with: .color(.white.opacity(0.13)), lineWidth: 1)
                }
                ctx.draw(Text(HarmonicLabels.groupName(col.kind))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(HarmonicLabels.color(col.kind).opacity(0.85)),
                         at: CGPoint(x: x0 + 3, y: 2), anchor: .topLeading)
            }
            prevOrder = ord
            if case .played = col.kind {
                ctx.fill(Path(CGRect(x: x0, y: 0, width: colW, height: plotH)),
                         with: .color(.orange.opacity(0.05)))
            }
            let label = { () -> String in
                if case .played = col.kind { return "Played" }
                return HarmonicLabels.note(col.f0)
            }()
            let resolved = ctx.resolve(Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(HarmonicLabels.color(col.kind).opacity(0.9)))
            ctx.drawLayer { layer in
                layer.translateBy(x: x0 + colW / 2 + 3, y: plotH + 3)
                layer.rotate(by: .degrees(90))
                layer.draw(resolved, at: .zero, anchor: .leading)
            }
        }

        // Bands. dB relative to `refMag`; below the floor → not drawn (dark bg).
        let bandH: CGFloat = max(2.5, plotH / 140)
        let ref = max(refMag, 1e-9)
        for c in a.cells where c.columnIndex < n {
            let db = 20 * log10(max(c.magnitude, 1e-9) / ref)
            let t = (db - floorDb) / (0 - floorDb)
            if t <= 0 { continue }
            let x0 = colX(c.columnIndex)
            let yy = yFor(c.freqHz)
            let rect = CGRect(x: x0 + 0.5, y: yy - bandH / 2, width: max(1, colW - 1), height: bandH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(heat(min(1, t))))
        }
    }

    /// dB-fraction `t` ∈ [0,1] → heat ramp (dark indigo → magenta → orange →
    /// pale yellow), with opacity rising so near-floor bands fade into the dark.
    private func heat(_ t: Double) -> Color {
        let stops: [(Double, Double, Double, Double)] = [
            (0.0,  20.0 / 255, 12.0 / 255,  60.0 / 255),
            (0.4, 150.0 / 255, 30.0 / 255, 120.0 / 255),
            (0.7, 240.0 / 255, 95.0 / 255,  30.0 / 255),
            (1.0, 255.0 / 255, 235.0 / 255, 170.0 / 255),
        ]
        let tt = min(1, max(0, t))
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where tt >= stops[i].0 && tt <= stops[i + 1].0 {
            lo = stops[i]; hi = stops[i + 1]; break
        }
        let span = hi.0 - lo.0
        let f = span > 0 ? (tt - lo.0) / span : 0
        return Color(red: lo.1 + (hi.1 - lo.1) * f,
                     green: lo.2 + (hi.2 - lo.2) * f,
                     blue: lo.3 + (hi.3 - lo.3) * f)
            .opacity(0.35 + 0.65 * tt)
    }
}
