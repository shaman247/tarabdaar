import SarangiKit
import TarabdaarCore
import SwiftUI

/// The **Scope** tab (⌘8, 2026-09-01): the performance at a glance.
///
/// One **pitch field** — time along x (a fixed 8 s window scrolling
/// smoothly, the Live tab's law), log-frequency along y with the scale's
/// own degree labels as gridlines — carries three layers:
///
/// - **Touched** pitches (white halo lines): every finger currently down,
///   from the finger registry ABOVE the glide queue (`AppController.
///   currentTouches`) — a parked or queued finger shows here even while
///   the voice sounds somewhere else.
/// - **Sounding** pitches of the MAIN VOICE (magma by level — the shared
///   `ScopeColor.level` ramp, 2026-09-02): one trajectory per physical
///   string — the bowed slots' target pitch and ring envelope, or the
///   plucked instrument's strings at their bent pitch, ringing on after
///   the touch lifts. Held strings draw thick, released ones thin.
/// - **Taraf lanes**: every modal-jawari row as a horizontal line at its
///   pitch whose LUMINANCE is the row's radiated level and whose HUE is
///   its harmonic character (amber = fundamental-heavy … blue = the high
///   jawari cluster: the spectral centroid of the kernel's per-mode
///   modal-energy envelopes — with the flat bridge-force radiation the
///   character as heard — EMA-smoothed so the hue doesn't flicker). The
///   melody follower's lane moves with the played note.
///
/// The per-row taraf panel (level, radiated + modal spectra, brightness)
/// lives on its own **Taraf** tab (⌘9, `TarafScopeView.swift`) since
/// 2026-09-02; both tabs share `ScopeModel`.
///
/// Drawing (2026-09-02 de-jitter): samples at 60 Hz, redraw at display
/// rate; every trace is ONE stroke per contiguous run — a Catmull-Rom
/// spline (pitch lines) or a polyline (lanes) filled with a linear
/// gradient whose stops are the per-sample colours — so neither the
/// colour nor the geometry is quantized into flickering runs.
///
/// Everything reads `AudioEngine.scopeSnapshot()` — the kernel's
/// display-only meters (`bow_poly_scope_*`, armed only while this tab is
/// showing; disarmed = the exact legacy render) plus the mapper's slot
/// targets. Nothing here feeds the physics.
struct ScopeView: View {
    @ObservedObject var controller: AppController
    @StateObject private var model = ScopeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.animation) { timeline in
                VStack(alignment: .leading, spacing: 12) {
                    PitchField(model: model,
                               now: timeline.date.timeIntervalSinceReferenceDate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            legend
        }
        .padding(16)
        .onAppear { model.start(controller: controller) }
        .onDisappear { model.stop() }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            LegendSwatch(colors: [Color.white.opacity(0.45)], label: "touched")
            LegendSwatch(colors: [ScopeColor.level(0), ScopeColor.level(0.5),
                                  ScopeColor.level(1)],
                         label: "sounding (main voice, by level)")
            LegendSwatch(colors: [ScopePalette.taraf(level: 0.2, bright: 0.5),
                                  ScopePalette.taraf(level: 1, bright: 0.5)],
                         label: "taraf row: luminance = level")
            LegendSwatch(colors: [ScopePalette.taraf(level: 1, bright: 0),
                                  ScopePalette.taraf(level: 1, bright: 0.5),
                                  ScopePalette.taraf(level: 1, bright: 1)],
                         label: "hue = character (fundamental → jawari cluster)")
            Spacer()
            Text("\(model.rows.count) rows · \(model.rows.filter(\.asleep).count) asleep")
                .font(.padCaption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LegendSwatch: View {
    let colors: [Color]
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 28, height: 6)
                .clipShape(Capsule())
            Text(label).font(.padCaption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Palette

enum ScopePalette {
    /// Taraf lane colour: HUE by harmonic character (amber → lime →
    /// cyan-blue), LUMINANCE by level (2026-09-02 — was opacity).
    static func taraf(level: Double, bright: Double) -> Color {
        let b = min(1, max(0, bright))
        let l = min(1, max(0, level))
        return Color(hue: 0.08 + 0.50 * b, saturation: 0.85,
                     brightness: 0.18 + 0.82 * l)
    }

    /// Mode-bar colour in the panel spectra (same hue law by mode index).
    static func mode(_ k: Int, of n: Int) -> Color {
        Color(hue: 0.08 + 0.50 * Double(k) / Double(max(1, n - 1)),
              saturation: 0.85, brightness: 0.95)
    }
}

// MARK: - Model

/// The Scope tab's sampler: a 60 Hz main-queue timer polls the audio
/// engine's scope snapshot + the controller's touch registry into a
/// timestamped ring of frames (8.5 s deep), and keeps the latest taraf
/// row table for the panel. Arms the kernel meters on start and disarms
/// them on stop.
@MainActor
final class ScopeModel: ObservableObject {
    struct Touch { let id: Int; let hz: Double }
    struct Frame {
        let t: Double
        let touches: [Touch]
        let voices: [AudioEngine.ScopeSnapshot.Voice]
        /// Per taraf row (kernel order): pitch, 0…1 level, 0…1 brightness.
        let tarafHz: [Float]
        let tarafLevel: [Float]
        let tarafBright: [Float]
    }
    struct Row: Identifiable {
        let id: Int            // kernel row index
        let f0: Double
        let label: String
        let isFollower: Bool
        let isChromatic: Bool
        let asleep: Bool
        let level01: Double
        /// Spectral centroid of the modal energy (p_k² weights) in mode
        /// units (1 = pure fundamental), EMA-smoothed. With the flat
        /// bridge-force radiation this is also the character as heard.
        let centroid: Double
        let bright01: Double
        /// Per-mode modal velocity envelopes |p_k| (energy ∝ p_k²).
        let modes: [Float]
    }
    struct Gridline {
        let log2Hz: Double
        let label: String
        let isTonic: Bool
    }

    /// Visible time span, seconds.
    let window: Double = 8
    static let sampleHz = 60.0
    private(set) var frames: [Frame] = []
    /// Latest taraf rows, pitch-sorted (the panel + the lane labels).
    private(set) var rows: [Row] = []
    /// y-axis bounds, log2(Hz).
    private(set) var axis: ClosedRange<Double> = log2(100)...log2(1600)
    private(set) var gridlines: [Gridline] = []
    /// Scale degrees (ratio + label) for naming pitches.
    private(set) var degrees: [(ratio: Double, label: String)] = []
    private(set) var tonicHz: Double = 261.63

    private weak var controller: AppController?
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    /// Per-row EMA of the centroids (~150 ms) — the raw per-mode envelopes
    /// breathe at the mode beat rates and the hue flickered with them.
    private var centroidEMA: [Double] = []

    func start(controller: AppController) {
        self.controller = controller
        controller.audio.setScopeArmed(true)
        refreshAxis()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / Self.sampleHz,
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        controller?.audio.setScopeArmed(false)
        frames.removeAll()
        centroidEMA.removeAll()
    }

    /// Level in output units (1.0 ≈ 0 dBFS) → 0…1 over the iPad volume
    /// scope's 60 dB (`TLPVolume.floorDb`).
    static func level01(_ linear: Double) -> Double {
        guard linear > 0 else { return 0 }
        return min(1, max(0, 1 + 20 * log10(linear) / 60))
    }

    /// Spectral centroid (mode units, 1-based) of the per-mode velocity
    /// envelopes — energy-weighted (p_k²); 1 when nothing rings.
    static func centroid(_ modes: [Float]) -> Double {
        var num = 0.0, den = 0.0
        for (k, m) in modes.enumerated() {
            let e = Double(m) * Double(m)
            num += Double(k + 1) * e
            den += e
        }
        return den > 0 ? num / den : 1
    }

    /// Centroid → 0…1 on a log scale (mode 1 → 0, mode 4 → 0.5, mode 16 → 1).
    static func bright01(centroid c: Double, modeCount n: Int) -> Double {
        guard c > 1, n > 1 else { return 0 }
        return min(1, max(0, log2(c) / log2(Double(n))))
    }

    private func tick() {
        guard let controller else { return }
        tickCount += 1
        let now = Date().timeIntervalSinceReferenceDate
        let snap = controller.audio.scopeSnapshot()
        let touches = controller.currentTouches().map {
            Touch(id: $0.id, hz: 440.0 * pow(2.0, ($0.pitchSemis - 69.0) / 12.0))
        }
        // Taraf rows: the display quantities + the panel table.
        let n = snap.taraf.count
        if centroidEMA.count != n {
            centroidEMA = [Double](repeating: 1, count: n)
        }
        let alpha = 1 - exp(-1.0 / (Self.sampleHz * 0.15))
        var hz = [Float](); var lv = [Float](); var br = [Float]()
        hz.reserveCapacity(n); lv.reserveCapacity(n); br.reserveCapacity(n)
        var newRows: [Row] = []
        newRows.reserveCapacity(n)
        for (i, r) in snap.taraf.enumerated() {
            let l = Self.level01(r.level)
            let raw = Self.centroid(r.modes)
            // a silent row keeps its last character rather than snapping to 1
            if l > 0 { centroidEMA[i] += alpha * (raw - centroidEMA[i]) }
            let c = centroidEMA[i]
            let b = Self.bright01(centroid: c, modeCount: r.modes.count)
            hz.append(Float(r.f0Hz)); lv.append(Float(l)); br.append(Float(b))
            // chromatic-bridge rows carry a mark: their pitch may not be a
            // scale degree at all (the label is then the nearest one)
            let label = r.isFollower
                ? "follow"
                : scaleLabel(forRatio: r.f0Hz / tonicHz, degrees: degrees)
                    + (r.isChromatic ? "·c" : "")
            newRows.append(Row(id: i, f0: r.f0Hz, label: label,
                               isFollower: r.isFollower,
                               isChromatic: r.isChromatic, asleep: r.asleep,
                               level01: l, centroid: c, bright01: b,
                               modes: r.modes))
        }
        rows = newRows.sorted { $0.f0 < $1.f0 }
        frames.append(Frame(t: now, touches: touches, voices: snap.voices,
                            tarafHz: hz, tarafLevel: lv, tarafBright: br))
        let cutoff = now - (window + 0.5)
        if let first = frames.first, first.t < cutoff {
            frames.removeAll { $0.t < cutoff }
        }
        // The axis follows the scale/tonic (and grows to fit the rows);
        // the scale rarely changes, so re-derive it ~once a second.
        if tickCount % 60 == 0 { refreshAxis() }
    }

    /// y-bounds: the scale's degrees around the tonic plus an octave each
    /// side (the Live tab's law), widened to cover every taraf row and
    /// every current pitch so nothing draws off-field.
    private func refreshAxis() {
        guard let controller else { return }
        tonicHz = controller.pitchPad.tonicHz
        degrees = scaleDegrees(from: controller.pitchPad.scale)
        let ratios = degrees.map(\.ratio).filter { $0 > 0 }
        var lo = log2(tonicHz / 2), hi = log2(tonicHz * 2)
        if let mn = ratios.min(), let mx = ratios.max(), mx > mn {
            lo = log2(mn * tonicHz) - 1
            hi = log2(mx * tonicHz) + 1
        }
        for r in rows where r.f0 > 0 {
            lo = min(lo, log2(r.f0) - 0.15)
            hi = max(hi, log2(r.f0) + 0.15)
        }
        if let f = frames.last {
            for v in f.voices where v.pitchHz > 0 {
                lo = min(lo, log2(v.pitchHz) - 0.1)
                hi = max(hi, log2(v.pitchHz) + 0.1)
            }
        }
        axis = lo...hi
        // Gridlines: every enabled degree in every octave inside the axis,
        // labelled with the scale's own label + octave marks.
        var lines: [Gridline] = []
        let base = log2(tonicHz)
        for oct in -4...4 {
            for d in degrees where d.ratio > 0 {
                let l = base + log2(d.ratio) + Double(oct)
                guard axis.contains(l) else { continue }
                lines.append(Gridline(log2Hz: l,
                                      label: octaveMarked(d.label, octave: oct),
                                      isTonic: abs(d.ratio - 1) < 1e-9))
            }
        }
        gridlines = lines
    }
}

// MARK: - Pitch field

private struct PitchField: View {
    let model: ScopeModel
    let now: Double

    private let leftGutter: CGFloat = 46
    private let rightGutter: CGFloat = 84
    /// A sample gap longer than this breaks a trace (touch lifted and
    /// re-landed under the same id, a string that stopped metering).
    private let gapS = 0.1

    /// One plotted sample of a trace.
    private struct Pt {
        let p: CGPoint
        let color: Color
        let held: Bool
        let t: Double
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let plot = CGRect(x: leftGutter, y: 0,
                              width: max(1, size.width - leftGutter - rightGutter),
                              height: size.height)
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size),
                          cornerRadius: 8),
                     with: .color(Color.black.opacity(0.25)))
            drawGrid(ctx, plot)
            var clipped = ctx
            clipped.clip(to: Path(plot))
            drawTaraf(clipped, plot)
            drawTouches(clipped, plot)
            drawVoices(clipped, plot)
            drawReadouts(ctx, plot)
        }
    }

    private func x(_ t: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + plot.width * CGFloat(1.0 - (now - t) / model.window)
    }

    private func y(hz: Double, _ plot: CGRect) -> CGFloat {
        guard hz > 0 else { return plot.maxY }
        let a = model.axis
        let span = a.upperBound - a.lowerBound
        let n = span > 0 ? (log2(hz) - a.lowerBound) / span : 0.5
        return plot.maxY - plot.height * CGFloat(min(1.05, max(-0.05, n)))
    }

    private func drawGrid(_ ctx: GraphicsContext, _ plot: CGRect) {
        for g in model.gridlines {
            let yy = y(hz: pow(2.0, g.log2Hz), plot)
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: yy))
            p.addLine(to: CGPoint(x: plot.maxX, y: yy))
            ctx.stroke(p, with: .color(Color.white.opacity(g.isTonic ? 0.22 : 0.07)),
                       lineWidth: 1)
            ctx.draw(Text(g.label)
                        .font(.padSmall(9, design: .monospaced))
                        .foregroundColor(g.isTonic ? .white : .secondary),
                     at: CGPoint(x: plot.minX - 6, y: yy), anchor: .trailing)
        }
    }

    // MARK: gradient strokes

    /// Stroke one contiguous run as a single path filled with a linear
    /// gradient whose stops are the samples' own colours — smooth colour
    /// along the trace, no quantized runs to flicker. `smooth` = a
    /// Catmull-Rom spline through the points (pitch traces), else a
    /// polyline (lanes). A lone sample draws as a dot.
    private func strokeRun(_ ctx: GraphicsContext, _ pts: [Pt],
                           width: CGFloat, smooth: Bool) {
        guard let first = pts.first, let last = pts.last else { return }
        if pts.count == 1 {
            ctx.fill(Path(ellipseIn: CGRect(x: first.p.x - width / 2,
                                            y: first.p.y - width / 2,
                                            width: width, height: width)),
                     with: .color(first.color))
            return
        }
        var path = Path()
        if smooth { Self.addSmoothCurve(pts.map(\.p), to: &path) }
        else {
            path.move(to: first.p)
            for q in pts.dropFirst() { path.addLine(to: q.p) }
        }
        let span = max(1, last.p.x - first.p.x)
        let stops = pts.map {
            Gradient.Stop(color: $0.color,
                          location: min(1, max(0, ($0.p.x - first.p.x) / span)))
        }
        ctx.stroke(path,
                   with: .linearGradient(Gradient(stops: stops),
                                         startPoint: CGPoint(x: first.p.x, y: 0),
                                         endPoint: CGPoint(x: last.p.x, y: 0)),
                   style: StrokeStyle(lineWidth: width, lineCap: .round,
                                      lineJoin: .round))
    }

    /// Uniform Catmull-Rom → cubic Bézier (the Live tab's curve): rounds
    /// off the sample-to-sample stair-steps of a 60 Hz-sampled glide.
    private static func addSmoothCurve(_ pts: [CGPoint], to p: inout Path) {
        guard let first = pts.first else { return }
        p.move(to: first)
        if pts.count < 3 {
            for q in pts.dropFirst() { p.addLine(to: q) }
            return
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// Split a time-ordered series into runs at gaps and (optionally) at
    /// held-state changes, and stroke each.
    private func strokeSeries(_ ctx: GraphicsContext, _ pts: [Pt],
                              width: (Bool) -> CGFloat, smooth: Bool,
                              splitOnHeld: Bool) {
        var run: [Pt] = []
        for q in pts {
            if let prev = run.last,
               q.t - prev.t > gapS || (splitOnHeld && q.held != prev.held) {
                strokeRun(ctx, run, width: width(prev.held), smooth: smooth)
                // continuity across a held→released edge: start from prev
                run = (q.t - prev.t > gapS) ? [] : [prev]
            }
            run.append(q)
        }
        if let l = run.last { strokeRun(ctx, run, width: width(l.held), smooth: smooth) }
    }

    // MARK: layers

    /// Taraf lanes: per row, the ringing frames as one gradient polyline
    /// (luminance = level, hue = character); silent frames break the run.
    private func drawTaraf(_ ctx: GraphicsContext, _ plot: CGRect) {
        let frames = model.frames
        guard frames.count > 1 else { return }
        let nRows = frames.last?.tarafHz.count ?? 0
        for r in 0..<nRows {
            var pts: [Pt] = []
            pts.reserveCapacity(frames.count)
            for f in frames where r < f.tarafHz.count {
                let lv = Double(f.tarafLevel[r])
                guard lv > 0 else { continue }
                pts.append(Pt(p: CGPoint(x: x(f.t, plot),
                                         y: y(hz: Double(f.tarafHz[r]), plot)),
                              color: ScopePalette.taraf(level: lv,
                                                        bright: Double(f.tarafBright[r])),
                              held: true, t: f.t))
            }
            strokeSeries(ctx, pts, width: { _ in 3 }, smooth: false,
                         splitOnHeld: false)
            // The resting lane: a faint line at the row's current pitch.
            if let f = frames.last, r < f.tarafHz.count {
                let yy = y(hz: Double(f.tarafHz[r]), plot)
                var p = Path()
                p.move(to: CGPoint(x: plot.minX, y: yy))
                p.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(p, with: .color(Color.orange.opacity(0.10)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
    }

    /// Touched pitches: one white halo spline per touch id.
    private func drawTouches(_ ctx: GraphicsContext, _ plot: CGRect) {
        var series: [Int: [Pt]] = [:]
        let white = Color.white.opacity(0.45)
        for f in model.frames {
            for t in f.touches {
                series[t.id, default: []].append(
                    Pt(p: CGPoint(x: x(f.t, plot), y: y(hz: t.hz, plot)),
                       color: white, held: true, t: f.t))
            }
        }
        for pts in series.values {
            strokeSeries(ctx, pts, width: { _ in 5 }, smooth: true,
                         splitOnHeld: false)
        }
    }

    /// Sounding strings: per string id, a magma-by-level spline; held
    /// segments thick, released (ringing) segments thin.
    private func drawVoices(_ ctx: GraphicsContext, _ plot: CGRect) {
        var series: [Int: [Pt]] = [:]
        for f in model.frames {
            for v in f.voices {
                series[v.id, default: []].append(
                    Pt(p: CGPoint(x: x(f.t, plot), y: y(hz: v.pitchHz, plot)),
                       color: ScopeColor.level(v.level), held: v.held, t: f.t))
            }
        }
        for pts in series.values {
            strokeSeries(ctx, pts, width: { $0 ? 3 : 1.5 }, smooth: true,
                         splitOnHeld: true)
        }
    }

    /// Right-edge readouts: the current sounding strings (dot + label +
    /// Hz) and the current touches (ring), at their pitches.
    private func drawReadouts(_ ctx: GraphicsContext, _ plot: CGRect) {
        guard let f = model.frames.last else { return }
        let edge = plot.maxX
        for t in f.touches {
            let yy = y(hz: t.hz, plot)
            ctx.stroke(Path(ellipseIn: CGRect(x: edge - 5, y: yy - 5, width: 10, height: 10)),
                       with: .color(Color.white.opacity(0.7)), lineWidth: 1.2)
        }
        // Stack labels so close pitches don't overprint: sort by y, nudge.
        let voices = f.voices.sorted { $0.pitchHz > $1.pitchHz }
        var lastY: CGFloat = -100
        for v in voices {
            let yy = y(hz: v.pitchHz, plot)
            ctx.fill(Path(ellipseIn: CGRect(x: edge - 4, y: yy - 4, width: 8, height: 8)),
                     with: .color(ScopeColor.level(v.level)))
            var ly = yy
            if ly - lastY < 12 { ly = lastY + 12 }
            lastY = ly
            let name = scaleLabel(forRatio: v.pitchHz / model.tonicHz,
                                  degrees: model.degrees)
            let text = Text("\(name) \(Int(v.pitchHz.rounded()))")
                .font(.padSmall(9, design: .monospaced))
                .foregroundColor(v.held ? .white : .secondary)
            ctx.draw(text, at: CGPoint(x: edge + 10, y: ly), anchor: .leading)
        }
        // Taraf row labels ride the right gutter too, below the voice
        // readouts' priority: only rows that are ringing get a label.
        let rows = model.rows.filter { $0.level01 > 0.05 }
        var usedY: [CGFloat] = []
        for r in rows {
            let yy = y(hz: r.f0, plot)
            if usedY.contains(where: { abs($0 - yy) < 11 }) { continue }
            usedY.append(yy)
            let text = Text(r.label)
                .font(.padSmall(8, design: .monospaced))
                .foregroundColor(ScopePalette.taraf(level: 1, bright: r.bright01))
            ctx.draw(text, at: CGPoint(x: plot.maxX + rightGutter - 4, y: yy),
                     anchor: .trailing)
        }
    }
}
