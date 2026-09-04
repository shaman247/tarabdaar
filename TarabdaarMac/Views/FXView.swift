import SwiftUI
import SarangiKit
import TarabdaarCore

/// FX tab (⌘6): the four-insert FX rack. Each point carries an EQ curve
/// (points the player sets, a curve inferred from them) and a selectable
/// reverb (Bigverb / Room), everything off by default. The knobs are
/// ordinary registry parameters (`fx_<point>_*`, all `.live`) driven
/// through the unified `paramValue`/`setParamValue` path — so presets
/// capture them, the Parameters tab lists them, and tilt/composites can
/// bind them; the curve's points go through `AppController.setEQCurve`
/// (presets carry them as their own section). This tab is the curated
/// surface.
struct FXView: View {
    @ObservedObject var controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    /// The four insert points come from the registry's ONE insert
    /// definition (`ParamRegistry.fxPoints`) — the same points the
    /// Parameters tab and the docs render, so their prefixes cannot drift
    /// apart (`FXRackTests` pins them against `SarangiKit.FXPoint`).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ParamRegistry.fxPoints) { point in
                    FXPointPanel(controller: controller, point: point)
                }
            }
            .padding(16)
        }
    }
}

/// One insert point: the EQ curve editor and a reverb block, side by side.
private struct FXPointPanel: View {
    @ObservedObject var controller: AppController
    let point: FXInsertPoint

    private var prefix: String { point.keyPrefix }
    private var title: String { point.name }
    private var sub: String { point.blurb }

    private func bind(_ suffix: String) -> Binding<Double> {
        let key = prefix + suffix
        return Binding(get: { controller.paramValue(key) },
                       set: { controller.setParamValue(key, $0) })
    }

    private func flag(_ suffix: String) -> Binding<Bool> {
        let key = prefix + suffix
        return Binding(get: { controller.paramValue(key) >= 0.5 },
                       set: { controller.setParamValue(key, $0 ? 1 : 0) })
    }

    private var isActive: Bool {
        controller.paramValue(prefix + "eq_on") >= 0.5
            || controller.paramValue(prefix + "rev_on") >= 0.5
    }

    /// The rate this point's insert runs at — what the drawn curve is
    /// designed for. The three bus points run at the kernel rate (2× the
    /// engine rate: `bow_os` is pinned to 2), the global point at the
    /// engine rate (`BowEngine.fxRate`).
    private var insertRate: Double {
        let base = controller.audio.stringVoiceSampleRate
        return FXPoint(rawValue: point.index) == .global ? base : 2 * base
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    if isActive {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { resetPoint() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Reset this insert point to defaults (all off, no curve)")
                }
                HStack(alignment: .top, spacing: 24) {
                    eqBlock
                    Divider()
                    reverbBlock
                    Spacer(minLength: 0)
                }
            }
            .padding(6)
        }
    }

    private var eqBlock: some View {
        let on = controller.paramValue(prefix + "eq_on") >= 0.5
        let points = controller.eqCurve(prefix)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("EQ curve", isOn: flag("eq_on"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("amount").font(.caption)
                Slider(value: bind("eq_amount"), in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("Depth of the curve, 0…1 — double-click the label to reset")
                    .disabled(!on)
                Text(String(format: "%.2f", controller.paramValue(prefix + "eq_amount")))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            EQCurveEditor(points: points, amount: controller.paramValue(prefix + "eq_amount"),
                          sampleRate: insertRate, enabled: on) { pts in
                controller.setEQCurve(prefix, pts)
            }
            .opacity(on ? 1 : 0.45)
            Text(points.isEmpty
                 ? "Double-click to add a point — the curve is inferred from the points."
                 : "\(points.count) of \(EQCurve.maxPoints) points · drag to move, double-click a point to remove it")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var reverbBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("Reverb", isOn: flag("rev_on"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Picker("", selection: Binding<Int>(
                    get: { Int(controller.paramValue(prefix + "rev_type").rounded()) },
                    set: { controller.setParamValue(prefix + "rev_type", Double($0)) })) {
                    Text("Bigverb").tag(0)
                    Text("Room").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()
                .help("Bigverb: 8 jittered feedback delay lines — a wide modulated hall. Room: the Freeverb-style tank — tighter, energy-matched.")
            }
            Group {
                fxSlider("mix", "rev_mix", 0...1, "%.2f")
                fxSlider("size", "rev_size", 0...1, "%.2f")
                fxSlider("cutoff", "rev_cut", 500...20000, "%.0f Hz")
            }
            .opacity(controller.paramValue(prefix + "rev_on") >= 0.5 ? 1 : 0.45)
        }
        .frame(width: 300)
    }

    private func fxSlider(_ label: String, _ suffix: String,
                          _ range: ClosedRange<Double>,
                          _ fmt: String) -> some View {
        ParamSliderRow(
            label: label, value: bind(suffix), range: range,
            readout: String(format: fmt, controller.paramValue(prefix + suffix)),
            labelFont: .caption, labelColor: .primary,
            labelWidth: 42, labelAlignment: .trailing,
            readoutFont: .caption.monospacedDigit(), readoutColor: .secondary,
            readoutWidth: 56,
            onLabelDoubleTap: { controller.resetParam(prefix + suffix) })
    }

    private func resetPoint() {
        for spec in ParamRegistry.all where spec.key.hasPrefix(prefix) {
            controller.resetParam(spec.key)
        }
        controller.setEQCurve(prefix, [])
    }
}

/// The EQ curve editor: log-frequency 20 Hz…20 kHz across, ±14 dB up, the
/// REALISED response of the fitted cascade (`EQCurve.design` — what the
/// insert actually does at its rate, scaled by the amount knob) drawn
/// through the points. Drag a point to move it in both axes (it cannot
/// cross its neighbours), double-click empty space to add one, double-click
/// a point to remove it.
private struct EQCurveEditor: View {
    let points: [EQPoint]
    let amount: Double
    let sampleRate: Double
    let enabled: Bool
    let onChange: ([EQPoint]) -> Void

    @State private var dragIndex: Int? = nil
    @State private var dragMissed = false

    private static let dbSpan = 14.0
    private static let lo = log2(EQCurve.minHz)
    private static let hi = log2(EQCurve.maxHz)
    private static let hitRadius = 9.0

    private func x(_ hz: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((log2(hz) - Self.lo) / (Self.hi - Self.lo)) * w
    }
    private func hz(_ x: CGFloat, _ w: CGFloat) -> Double {
        pow(2, Self.lo + Double(min(max(x, 0), w) / w) * (Self.hi - Self.lo))
    }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat {
        CGFloat(0.5 - db / (2 * Self.dbSpan)) * h
    }
    private func db(_ y: CGFloat, _ h: CGFloat) -> Double {
        (0.5 - Double(min(max(y, 0), h) / h)) * 2 * Self.dbSpan
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let design = EQCurve.design(points, sr: sampleRate).scaled(by: amount)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx, size, design)
                }
                if let i = dragIndex, i < points.count {
                    Text(readout(points[i]))
                        .font(.system(size: 9).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        if dragIndex == nil, !dragMissed {
                            if let i = nearest(g.startLocation, w, h) { dragIndex = i }
                            else { dragMissed = true }
                        }
                        guard let i = dragIndex else { return }
                        move(i, to: g.location, w, h)
                    }
                    .onEnded { _ in dragIndex = nil; dragMissed = false })
            .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                guard enabled else { return }
                if let i = nearest(loc, w, h) {
                    var pts = points; pts.remove(at: i); onChange(pts)
                } else if points.count < EQCurve.maxPoints {
                    let p = EQPoint(hz: tidy(hz(loc.x, w)), db: snap(db(loc.y, h)))
                    onChange(points + [p])
                }
            }
        }
        .frame(width: 360, height: 118)
        .help("EQ curve: drag a point, double-click to add one, double-click a point to remove it")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ design: EQDesign) {
        let w = size.width, h = size.height
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                 with: .color(Color.secondary.opacity(0.08)))
        // grid: decades labelled, octaves faint; ±6 dB rules; the 0 dB line
        var grid = Path()
        var f = 20.0
        while f < EQCurve.maxHz {
            let gx = x(f, w)
            grid.move(to: CGPoint(x: gx, y: 0)); grid.addLine(to: CGPoint(x: gx, y: h))
            f *= 2
        }
        for d in [-6.0, 6.0] {
            grid.move(to: CGPoint(x: 0, y: y(d, h))); grid.addLine(to: CGPoint(x: w, y: y(d, h)))
        }
        ctx.stroke(grid, with: .color(Color.secondary.opacity(0.12)), lineWidth: 1)
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: y(0, h))); zero.addLine(to: CGPoint(x: w, y: y(0, h)))
        ctx.stroke(zero, with: .color(Color.secondary.opacity(0.45)), lineWidth: 1)
        for (f, label) in [(100.0, "100"), (1000.0, "1k"), (10_000.0, "10k")] {
            ctx.draw(Text(label).font(.system(size: 8)).foregroundColor(.secondary),
                     at: CGPoint(x: x(f, w) + 2, y: h - 6), anchor: .leading)
        }
        // the realised response
        var curve = Path()
        let n = 128
        for k in 0...n {
            let px = w * CGFloat(k) / CGFloat(n)
            let py = y(design.magnitudeDB(at: hz(px, w), sr: sampleRate), h)
            let pt = CGPoint(x: px, y: min(max(py, 1), h - 1))
            if k == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
        }
        ctx.stroke(curve, with: .color(points.isEmpty ? .secondary : .accentColor),
                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        // the points
        for (i, p) in points.enumerated() {
            let c = CGPoint(x: x(p.hz, w), y: y(p.db * amount, h))
            let r = i == dragIndex ? 5.5 : 4.0
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(.accentColor))
            ctx.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
        }
    }

    private func nearest(_ loc: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Int? {
        var best: (Int, CGFloat)? = nil
        for (i, p) in points.enumerated() {
            let dx = x(p.hz, w) - loc.x, dy = y(p.db * amount, h) - loc.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= Self.hitRadius, best.map({ d < $0.1 }) ?? true { best = (i, d) }
        }
        return best?.0
    }

    /// Move point `i` to a canvas location, snapped, kept between its
    /// neighbours so the point identities never swap under the drag.
    private func move(_ i: Int, to loc: CGPoint, _ w: CGFloat, _ h: CGFloat) {
        guard i < points.count else { return }
        var pts = points
        let gap = pow(2, EQCurve.minSpacingOctaves)
        var f = hz(loc.x, w)
        if i > 0 { f = max(f, pts[i - 1].hz * gap) }
        if i + 1 < pts.count { f = min(f, pts[i + 1].hz / gap) }
        let g = amount > 0.01 ? db(loc.y, h) / amount : db(loc.y, h)
        pts[i] = EQPoint(hz: tidy(f), db: snap(g))
        if pts[i] != points[i] { onChange(pts) }
    }

    /// Gain snapped to 0.25 dB within the curve's range.
    private func snap(_ db: Double) -> Double {
        min(max((db * 4).rounded() / 4, -EQCurve.gainLimitDB), EQCurve.gainLimitDB)
    }

    /// Frequency to three significant figures (a tidy readout, no audible
    /// quantisation).
    private func tidy(_ hz: Double) -> Double {
        let mag = pow(10, floor(log10(hz)) - 2)
        return min(max((hz / mag).rounded() * mag, EQCurve.minHz), EQCurve.maxHz)
    }

    private func readout(_ p: EQPoint) -> String {
        let f = p.hz < 1000 ? String(format: "%.0f Hz", p.hz)
                            : String(format: "%.2f kHz", p.hz / 1000)
        return String(format: "%@  %+.2f dB", f, p.db)
    }
}
