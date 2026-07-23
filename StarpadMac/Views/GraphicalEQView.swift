import AppKit
import SarangiKit
import StarpadCore
import SwiftUI

/// Interactive graphical EQ for one FX stage (Violin / Sym / Global). A
/// frequency-response curve over a log-frequency / dB plot with draggable nodes:
///
/// - **click empty space** → add a band there (then drag it),
/// - **drag a node** → frequency (x) + gain (y); ⌘-drag locks frequency,
/// - **scroll over a node** → its Q (or the low-pass resonance),
/// - **right-click a node** → remove,
/// - **double-click a node** → reset its gain to 0,
/// - **type menu** (header) → bell / shelf / cut for the selected node.
///
/// The stage **low-pass** is folded in as the right-edge orange node (drag =
/// cutoff, scroll = resonance); its roll-off is part of the drawn curve. Behind
/// the curve, the live spectrum is drawn twice: **pre-EQ** (faint) and **post-EQ**
/// (bright) — post is derived analytically as `pre + the curve`, so it always
/// matches the response and needs no second audio tap. Every edit pushes
/// coefficients live (`SarangiStore.setEQBand`/`setFilter` → `applySarangiFXFilters`),
/// so dragging is smooth and click-free. The curve is drawn from the SAME
/// `Biquad.forBand`/`stageLowpass` the engine runs, so picture == sound.
struct GraphicalEQView: View {
    let stage: SarangiStore.FXStage
    @ObservedObject var store: SarangiStore
    /// The live-spectrum feed. Observed DIRECTLY (not via `AppController`) — a
    /// nested ObservableObject's `@Published` changes don't propagate through the
    /// parent, so observing the provider is what drives the 30 Hz redraw.
    @ObservedObject var spectrum: SpectrumProvider

    @State private var selectedID: UUID?
    @State private var selectedLP = false
    @State private var hoverID: UUID?
    @State private var hoverLP = false
    @State private var dragID: UUID?
    @State private var dragLP = false
    @State private var dragOffset = CGSize.zero

    private let plotHeight: CGFloat = 184

    private var fx: VoiceFXParams { store.voiceFX(for: stage) }
    private var bands: [EQBand] { fx.eq }
    private func band(_ id: UUID) -> EQBand? { bands.first { $0.id == id } }

    private var providerStage: SpectrumProvider.Stage {
        stage == \FXRack.violinPre ? .violinPre : .global
    }
    private var spectrumFrame: SpectrumFrame? {
        switch providerStage {
        case .violinPre: return spectrum.violinPre
        case .global: return spectrum.global
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            plot
        }
        .onAppear { spectrum.setVisible(providerStage, true) }
        .onDisappear { spectrum.setVisible(providerStage, false) }
    }

    // MARK: Plot

    private var plot: some View {
        let response = EQResponse(bands: bands, lpCutoff: fx.filterCutoff,
                                  lpResonance: fx.filterResonance, sr: Config.sampleRate)
        return GeometryReader { proxy in
            let g = EQPlotGeometry(size: proxy.size)
            ZStack(alignment: .topLeading) {
                EQGridCanvas(geo: g)
                EQSpectrumCanvas(geo: g, frame: spectrumFrame,
                                 binFreqs: spectrum.binFreqs, response: response)
                EQCurveCanvas(geo: g, bands: bands, response: response, lpCutoff: fx.filterCutoff,
                              selectedID: selectedID, hoverID: hoverID,
                              selectedLP: selectedLP, hoverLP: hoverLP, stageEnabled: fx.enabled)
                EQMouseCapture(
                    onDown: { pt, _, clicks in onDown(g, pt, clicks: clicks) },
                    onDragged: { pt in onDrag(g, pt) },
                    onUp: { dragID = nil; dragLP = false },
                    onMoved: { pt in onMove(g, pt) },
                    onRight: { pt in onRight(g, pt) },
                    onScroll: { pt, dy in onScroll(g, pt, dy) })
            }
        }
        .frame(height: plotHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.30)))
    }

    // MARK: Header (selected-node readout + type picker + numeric entry)

    private var header: some View {
        HStack(spacing: 6) {
            if let id = selectedID, let b = band(id) {
                Picker("", selection: bandTypeBinding(id)) {
                    ForEach(EQBandType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 104).font(.caption2)
                numField("Hz", bandFreqBinding(id), width: 54)
                if b.type.usesGain { numField("dB", bandGainBinding(id), width: 46) }
                if b.type.usesQ { numField("Q", bandQBinding(id), width: 40) }
                Button { store.removeEQBand(stage, id: id); selectedID = nil } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).font(.caption2).help("Remove band")
            } else if selectedLP {
                Text("Low-pass").font(.caption2).bold().foregroundStyle(.secondary)
                numField("Hz", lpCutoffBinding, width: 54)
                numField("Q", lpResBinding, width: 40)
            } else {
                Text("drag = move · ⌘ locks freq · scroll = Q · click = add · right-click = remove")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Button("Flat") { for b in bands { store.setEQBand(stage, id: b.id) { $0.gainDB = 0 } } }
                .buttonStyle(.borderless).font(.caption2).help("Zero all band gains")
        }
    }

    private func numField(_ unit: String, _ value: Binding<Double>, width: CGFloat) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, formatter: Self.numFmt)
                .textFieldStyle(.roundedBorder).frame(width: width).font(.caption2.monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private static let numFmt: NumberFormatter = {
        let f = NumberFormatter(); f.maximumFractionDigits = 1; f.minimumFractionDigits = 0; return f
    }()

    // MARK: Bindings

    private func bandTypeBinding(_ id: UUID) -> Binding<EQBandType> {
        Binding(get: { self.band(id)?.type ?? .peaking },
                set: { t in self.store.setEQBand(self.stage, id: id) { $0.type = t } })
    }
    private func bandFreqBinding(_ id: UUID) -> Binding<Double> {
        Binding(get: { self.band(id)?.freq ?? 0 },
                set: { v in self.store.setEQBand(self.stage, id: id) { $0.freq = min(20000, max(20, v)) } })
    }
    private func bandGainBinding(_ id: UUID) -> Binding<Double> {
        Binding(get: { self.band(id)?.gainDB ?? 0 },
                set: { v in self.store.setEQBand(self.stage, id: id) { $0.gainDB = min(18, max(-18, v)) } })
    }
    private func bandQBinding(_ id: UUID) -> Binding<Double> {
        Binding(get: { self.band(id)?.q ?? 1 },
                set: { v in self.store.setEQBand(self.stage, id: id) { $0.q = min(8, max(0.3, v)) } })
    }
    private var lpCutoffBinding: Binding<Double> {
        Binding(get: { self.fx.filterCutoff },
                set: { self.store.setFilter(self.stage, cutoff: $0, resonance: self.fx.filterResonance) })
    }
    private var lpResBinding: Binding<Double> {
        Binding(get: { self.fx.filterResonance },
                set: { self.store.setFilter(self.stage, cutoff: self.fx.filterCutoff, resonance: $0) })
    }

    // MARK: Interaction

    private func grab(_ g: EQPlotGeometry, _ pt: CGPoint) -> EQGrab {
        let r: CGFloat = 12
        let lp = CGPoint(x: g.xForFreq(fx.filterCutoff), y: g.lpHandleY)
        if hypot(lp.x - pt.x, lp.y - pt.y) <= r { return .lp }
        var best: (UUID, CGFloat)?
        for b in bands {
            let c = CGPoint(x: g.xForFreq(b.freq), y: g.yForGain(b.gainDB))
            let d = hypot(c.x - pt.x, c.y - pt.y)
            if d <= r + 2, best == nil || d < best!.1 { best = (b.id, d) }
        }
        if let best { return .band(best.0) }
        return .none
    }

    private func onDown(_ g: EQPlotGeometry, _ pt: CGPoint, clicks: Int) {
        switch grab(g, pt) {
        case .lp:
            selectedLP = true; selectedID = nil; dragLP = true; dragID = nil
            dragOffset = CGSize(width: g.xForFreq(fx.filterCutoff) - pt.x, height: 0)
        case .band(let id):
            selectedID = id; selectedLP = false
            if clicks >= 2 { store.setEQBand(stage, id: id) { $0.gainDB = 0 }; return }
            dragID = id; dragLP = false
            if let b = band(id) {
                dragOffset = CGSize(width: g.xForFreq(b.freq) - pt.x, height: g.yForGain(b.gainDB) - pt.y)
            }
        case .none:
            if let id = store.addEQBand(stage, freq: g.freqForX(pt.x), gainDB: g.gainForY(pt.y)) {
                selectedID = id; selectedLP = false; dragID = id; dragLP = false; dragOffset = .zero
            }
        }
    }

    private func onDrag(_ g: EQPlotGeometry, _ pt: CGPoint) {
        if dragLP {
            store.setFilter(stage, cutoff: g.freqForX(pt.x + dragOffset.width), resonance: fx.filterResonance)
            return
        }
        guard let id = dragID else { return }
        let lockFreq = NSEvent.modifierFlags.contains(.command)
        let newFreq = g.freqForX(pt.x + dragOffset.width)
        let newGain = g.gainForY(pt.y + dragOffset.height)
        store.setEQBand(stage, id: id) { b in
            if !lockFreq { b.freq = newFreq }
            b.gainDB = newGain
        }
    }

    private func onMove(_ g: EQPlotGeometry, _ pt: CGPoint) {
        switch grab(g, pt) {
        case .lp: hoverLP = true; hoverID = nil
        case .band(let id): hoverID = id; hoverLP = false
        case .none: hoverID = nil; hoverLP = false
        }
    }

    private func onRight(_ g: EQPlotGeometry, _ pt: CGPoint) {
        if case .band(let id) = grab(g, pt) {
            store.removeEQBand(stage, id: id)
            if selectedID == id { selectedID = nil }
        }
    }

    private func onScroll(_ g: EQPlotGeometry, _ pt: CGPoint, _ deltaY: CGFloat) {
        switch grab(g, pt) {
        case .lp:
            store.setFilter(stage, cutoff: fx.filterCutoff,
                            resonance: min(1, max(0, fx.filterResonance + Double(deltaY) * 0.003)))
            selectedLP = true; selectedID = nil
        case .band(let id):
            guard let b = band(id), b.type.usesQ else { return }
            store.setEQBand(stage, id: id) { $0.q = min(8, max(0.3, b.q * exp(Double(deltaY) * 0.01))) }
            selectedID = id; selectedLP = false
        case .none: break
        }
    }
}

// MARK: - Geometry (log-frequency x · linear-dB y, clamped both ways)

private struct EQPlotGeometry {
    let size: CGSize
    let gutter: CGFloat = 28
    let labelStrip: CGFloat = 14
    let fMin = 20.0, fMax = 20000.0
    let dbMin = -18.0, dbMax = 18.0
    let lpHandleY: CGFloat = 9

    var plotW: CGFloat { max(1, size.width - gutter) }
    var plotH: CGFloat { max(1, size.height - labelStrip) }
    private var logMin: Double { log2(fMin) }
    private var logMax: Double { log2(fMax) }

    func xForFreq(_ f: Double) -> CGFloat {
        let t = (log2(min(max(f, fMin), fMax)) - logMin) / (logMax - logMin)
        return gutter + plotW * CGFloat(t)
    }
    func freqForX(_ x: CGFloat) -> Double {
        let t = Double((x - gutter) / plotW)
        return pow(2, logMin + min(1, max(0, t)) * (logMax - logMin))
    }
    func yForGain(_ db: Double) -> CGFloat {
        let t = (min(max(db, dbMin), dbMax) - dbMin) / (dbMax - dbMin)
        return plotH * CGFloat(1 - t)
    }
    func gainForY(_ y: CGFloat) -> Double {
        let t = 1 - Double(y / plotH)
        return dbMin + min(1, max(0, t)) * (dbMax - dbMin)
    }
}

private enum EQGrab { case lp, band(UUID), none }

/// Precomputed biquads for the stage (enabled bands + the low-pass), drawn from
/// the SAME `Biquad.forBand`/`stageLowpass` the engine runs — so the curve is the
/// exact response. `dB(at:)` is the summed magnitude (product of biquads).
private struct EQResponse {
    let biquads: [Biquad]
    let sr: Double
    init(bands: [EQBand], lpCutoff: Double, lpResonance: Double, sr: Double) {
        var bq: [Biquad] = bands.compactMap { $0.enabled ? Biquad.forBand($0, sr: sr) : nil }
        bq.append(Biquad.stageLowpass(cutoff: lpCutoff, resonance: lpResonance, sr: sr))
        biquads = bq; self.sr = sr
    }
    func dB(at f: Double) -> Double {
        var d = 0.0
        for b in biquads { d += 20 * log10(b.magnitude(atHz: f, sr: sr)) }
        return d
    }
}

// MARK: - Layers

private struct EQGridCanvas: View {
    let geo: EQPlotGeometry
    private let dbLines: [Double] = [-18, -12, -6, 0, 6, 12, 18]
    private let freqLines: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        Canvas { ctx, _ in
            let g = geo
            for db in dbLines {
                let y = g.yForGain(db)
                var p = Path(); p.move(to: CGPoint(x: g.gutter, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.20 : 0.06)), lineWidth: 1)
                ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                         at: CGPoint(x: g.gutter - 3, y: y), anchor: .trailing)
            }
            for f in freqLines {
                let x = g.xForFreq(f)
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.plotH))
                ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1)
                let lbl = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                ctx.draw(Text(lbl).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                         at: CGPoint(x: x, y: g.plotH + 2), anchor: .top)
            }
        }
    }
}

/// Live spectrum: pre-EQ (faint fill) + post-EQ (bright fill = pre + the curve).
private struct EQSpectrumCanvas: View {
    let geo: EQPlotGeometry
    let frame: SpectrumFrame?
    let binFreqs: [Double]
    let response: EQResponse
    private let span = 70.0

    var body: some View {
        Canvas { ctx, _ in
            guard let frame, frame.db.count == binFreqs.count, binFreqs.count > 1 else { return }
            let g = geo
            func y(_ relDb: Double) -> CGFloat {
                CGFloat(1 - min(1, max(0, (relDb + span) / span))) * g.plotH
            }
            var pre = Path(), post = Path()
            let x0 = g.xForFreq(binFreqs[0])
            pre.move(to: CGPoint(x: x0, y: g.plotH)); post.move(to: CGPoint(x: x0, y: g.plotH))
            for i in binFreqs.indices {
                let x = g.xForFreq(binFreqs[i])
                pre.addLine(to: CGPoint(x: x, y: y(frame.db[i])))
                post.addLine(to: CGPoint(x: x, y: y(frame.db[i] + response.dB(at: binFreqs[i]))))
            }
            let xN = g.xForFreq(binFreqs[binFreqs.count - 1])
            pre.addLine(to: CGPoint(x: xN, y: g.plotH)); pre.closeSubpath()
            post.addLine(to: CGPoint(x: xN, y: g.plotH)); post.closeSubpath()
            ctx.fill(pre, with: .color(Color(red: 0.55, green: 0.72, blue: 1.0).opacity(0.10)))
            ctx.fill(post, with: .color(Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.22)))
        }
    }
}

/// The composite response curve + per-band faint curves + draggable handles +
/// the low-pass node (right-edge orange diamond with a dashed cutoff guide).
private struct EQCurveCanvas: View {
    let geo: EQPlotGeometry
    let bands: [EQBand]
    let response: EQResponse
    let lpCutoff: Double
    let selectedID: UUID?
    let hoverID: UUID?
    let selectedLP: Bool
    let hoverLP: Bool
    let stageEnabled: Bool

    var body: some View {
        Canvas { ctx, _ in
            let g = geo
            let sr = Config.sampleRate
            let accent = stageEnabled ? Color.accentColor : Color.gray
            let steps = max(1, Int(g.plotW))

            // Composite curve.
            var curve = Path()
            for i in 0...steps {
                let x = g.gutter + CGFloat(i)
                let pt = CGPoint(x: x, y: g.yForGain(response.dB(at: g.freqForX(x))))
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
            }
            ctx.stroke(curve, with: .color(accent.opacity(0.9)), lineWidth: 2)

            // Per-band faint curves (only when few, to avoid clutter).
            if bands.count <= 6 {
                for b in bands where b.enabled {
                    let bq = Biquad.forBand(b, sr: sr)
                    var p = Path()
                    for i in 0...steps {
                        let x = g.gutter + CGFloat(i)
                        let pt = CGPoint(x: x, y: g.yForGain(20 * log10(bq.magnitude(atHz: g.freqForX(x), sr: sr))))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(accent.opacity(0.16)), lineWidth: 1)
                }
            }

            // Band handles.
            for b in bands {
                let c = CGPoint(x: g.xForFreq(b.freq), y: g.yForGain(b.gainDB))
                let sel = b.id == selectedID
                let rr: CGFloat = sel ? 6 : 5
                let dot = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
                ctx.fill(dot, with: .color(b.enabled ? accent : .gray))
                ctx.stroke(dot, with: .color(.white.opacity(sel ? 0.95 : (b.id == hoverID ? 0.7 : 0.4))),
                           lineWidth: sel ? 2 : 1)
            }

            // Low-pass node: dashed cutoff guide + orange diamond near the top.
            let lpX = g.xForFreq(lpCutoff)
            var guideLine = Path(); guideLine.move(to: CGPoint(x: lpX, y: 0)); guideLine.addLine(to: CGPoint(x: lpX, y: g.plotH))
            ctx.stroke(guideLine, with: .color(.white.opacity(selectedLP || hoverLP ? 0.4 : 0.14)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let lpC = CGPoint(x: lpX, y: g.lpHandleY), dr: CGFloat = 5
            let diamond = Path { p in
                p.move(to: CGPoint(x: lpC.x, y: lpC.y - dr)); p.addLine(to: CGPoint(x: lpC.x + dr, y: lpC.y))
                p.addLine(to: CGPoint(x: lpC.x, y: lpC.y + dr)); p.addLine(to: CGPoint(x: lpC.x - dr, y: lpC.y)); p.closeSubpath()
            }
            ctx.fill(diamond, with: .color(.orange.opacity(0.9)))
            ctx.stroke(diamond, with: .color(.white.opacity(selectedLP ? 0.95 : (hoverLP ? 0.7 : 0.4))),
                       lineWidth: selectedLP ? 2 : 1)
        }
    }
}

// MARK: - Mouse capture (full-resolution; adds scroll-wheel + click-count)

private struct EQMouseCapture: NSViewRepresentable {
    let onDown: (CGPoint, Bool, Int) -> Void
    let onDragged: (CGPoint) -> Void
    let onUp: () -> Void
    let onMoved: (CGPoint) -> Void
    let onRight: (CGPoint) -> Void
    let onScroll: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> Capture { let v = Capture(); apply(v); return v }
    func updateNSView(_ v: Capture, context: Context) { apply(v) }
    private func apply(_ v: Capture) {
        v.onDown = onDown; v.onDragged = onDragged; v.onUp = onUp
        v.onMoved = onMoved; v.onRight = onRight; v.onScroll = onScroll
    }

    final class Capture: NSView {
        var onDown: ((CGPoint, Bool, Int) -> Void)?
        var onDragged: ((CGPoint) -> Void)?
        var onUp: (() -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onRight: ((CGPoint) -> Void)?
        var onScroll: ((CGPoint, CGFloat) -> Void)?
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t); tracking = t
        }
        override func mouseDown(with e: NSEvent) {
            onDown?(convert(e.locationInWindow, from: nil), e.modifierFlags.contains(.shift), e.clickCount)
        }
        override func mouseDragged(with e: NSEvent) { onDragged?(convert(e.locationInWindow, from: nil)) }
        override func mouseUp(with e: NSEvent) { onUp?() }
        override func mouseMoved(with e: NSEvent) { onMoved?(convert(e.locationInWindow, from: nil)) }
        override func rightMouseDown(with e: NSEvent) { onRight?(convert(e.locationInWindow, from: nil)) }
        override func scrollWheel(with e: NSEvent) { onScroll?(convert(e.locationInWindow, from: nil), e.scrollingDeltaY) }
    }
}
