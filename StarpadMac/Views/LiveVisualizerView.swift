import StarpadCore
import SwiftUI

/// "Live" tab. The Mac no longer has a NoteManager / playing-scale
/// concept (those are iPad-side), so this view surfaces what's reaching
/// the audio engine: MIDI source status, render-time metrics, and live
/// time-series graphs of the **played pitch** and **volume**.
///
/// The pitch + volume traces are read from `AudioEngine.performanceReadout()`,
/// derived at the single MIDI choke point, so they reflect every input
/// path — the USB iPad, the Mac pads, and the simulator. The volume line
/// is the commanded CC11 (Expression).
///
/// The graphs show a fixed **6-second** window and scroll smoothly: a
/// 60 Hz timer appends timestamped samples to a ring buffer, and a
/// `TimelineView(.animation)` redraws every display frame, placing each
/// sample at an x derived from its age — so the trace slides left
/// continuously rather than stepping at the sample rate.
struct LiveVisualizerView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var midi: MIDIEngine

    init(controller: AppController) {
        self.controller = controller
        self.midi = controller.midi
    }

    private struct Sample {
        let t: Double        // timeIntervalSinceReferenceDate
        let pitch: Double?   // Hz, nil when silent
        let vol: Double      // 0…1 (commanded expression)
    }

    @State private var samples: [Sample] = []
    @State private var renderTimeMs: Double = 0
    @State private var maxRenderTimeMs: Double = 0
    @State private var sampleCounter = 0

    /// Visible time span of the graphs, in seconds.
    private let window: Double = 6
    private let sample = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            statusCard
            TimelineView(.animation) { timeline in
                performanceCard(now: timeline.date.timeIntervalSinceReferenceDate)
            }
            Spacer()
            statsRow
        }
        .padding(24)
        .onReceive(sample) { _ in tick() }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIDI INPUT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: midi.sourceCount > 0 ? "cable.connector"
                                                       : "cable.connector.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(midi.sourceCount > 0 ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(midi.sourceCount > 0
                         ? "\(midi.sourceCount) MIDI source(s)"
                         : "No MIDI input")
                        .font(.title3)
                    Text(midi.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func performanceCard(now: Double) -> some View {
        let curPitch = samples.last?.pitch
        let curVol = samples.last?.vol ?? 0
        let pitchPts = samples.map { (t: $0.t, v: $0.pitch.map { log2($0) }) }
        let volPts = samples.map { (t: $0.t, v: Optional($0.vol)) }
        let pRange = pitchAxisRange()
        return VStack(alignment: .leading, spacing: 16) {
            TimeSeriesGraph(
                title: "PITCH",
                readout: curPitch.map { "\(noteName($0)) · \(Int($0.rounded())) Hz" } ?? "—",
                topLabel: hzLabel(pRange.upperBound),
                bottomLabel: hzLabel(pRange.lowerBound),
                points: pitchPts,
                now: now,
                window: window,
                range: pRange,
                color: .cyan,
                fill: false)
            TimeSeriesGraph(
                title: "VOLUME",
                readout: "\(Int((curVol * 100).rounded()))%",
                topLabel: "100%",
                bottomLabel: "0%",
                points: volPts,
                now: now,
                window: window,
                range: 0...1,
                color: .orange,
                fill: true)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            Label(String(format: "render: %.2f / %.2f ms",
                         renderTimeMs, maxRenderTimeMs),
                  systemImage: "waveform")
        }
        .font(.system(.caption))
        .foregroundStyle(.secondary)
    }

    /// Fixed y-bounds for the pitch graph, in log2(Hz): the span of the Fret
    /// Pad scale's degrees around the tonic (plus an octave of headroom each
    /// side for the octave-repeat ghost frets), so the axis is a stable
    /// reference tied to the instrument's compass rather than drifting with
    /// what's played. Falls back to two octaves around the tonic.
    private func pitchAxisRange() -> ClosedRange<Double> {
        let tonicHz = 440.0 * pow(2.0, (Double(controller.pitchPad.tonicMidi) - 69.0) / 12.0)
        let ratios = scaleDegrees(from: controller.pitchPad.scale)
            .map(\.ratio).filter { $0 > 0 }
        if let mn = ratios.min(), let mx = ratios.max(), mx > mn {
            let lo = log2(mn * tonicHz) - 1
            let hi = log2(mx * tonicHz) + 1
            return lo...hi
        }
        return log2(tonicHz / 2)...log2(tonicHz * 2)
    }

    private func tick() {
        let r = controller.audio.performanceReadout()
        let now = Date().timeIntervalSinceReferenceDate
        let pitch: Double? = (r.active && r.pitchHz > 0) ? r.pitchHz : nil
        samples.append(Sample(t: now, pitch: pitch, vol: r.active ? r.expression : 0))
        // Keep a little beyond the window so the line enters cleanly from
        // the left edge (clipped) rather than starting at the first sample.
        let cutoff = now - (window + 0.5)
        if let first = samples.first, first.t < cutoff {
            samples.removeAll { $0.t < cutoff }
        }
        // Render-time readout doesn't need 60 Hz; refresh it ~5×/s.
        sampleCounter += 1
        if sampleCounter % 12 == 0 {
            renderTimeMs = controller.audio.lastRenderTime * 1000
            maxRenderTimeMs = controller.audio.maxRenderTime * 1000
        }
    }

    /// log2(Hz) → "440 Hz" axis label.
    private func hzLabel(_ log2Hz: Double) -> String {
        "\(Int(pow(2.0, log2Hz).rounded())) Hz"
    }

    /// Hz → nearest 12-TET note name with cents offset, e.g. "D4 +12¢".
    private func noteName(_ hz: Double) -> String {
        guard hz > 0 else { return "—" }
        let midi = 69.0 + 12.0 * log2(hz / 440.0)
        let nearest = Int(midi.rounded())
        let cents = Int(((midi - Double(nearest)) * 100).rounded())
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let name = names[((nearest % 12) + 12) % 12]
        let octave = nearest / 12 - 1
        let centsStr = cents == 0 ? "" : (cents > 0 ? " +\(cents)¢" : " \(cents)¢")
        return "\(name)\(octave)\(centsStr)"
    }
}

/// A smoothly-scrolling time-series plot over a fixed `window`-second span.
/// Each `(t, v)` point is placed at x by its age (`now - t`), so redrawing
/// every frame (under `TimelineView(.animation)`) slides the trace left
/// continuously. `nil` values break the line into separate runs (used for
/// the pitch trace, which goes silent between notes).
private struct TimeSeriesGraph: View {
    let title: String
    let readout: String
    let topLabel: String
    let bottomLabel: String
    let points: [(t: Double, v: Double?)]
    let now: Double
    let window: Double
    let range: ClosedRange<Double>
    let color: Color
    let fill: Bool

    private let height: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.25))
                    ZStack {
                        gridPath(w: w, h: h)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                        if fill {
                            areaPath(w: w, h: h)
                                .fill(color.opacity(0.18))
                        }
                        linePath(w: w, h: h)
                            .stroke(color, style: StrokeStyle(lineWidth: 2,
                                                              lineCap: .round,
                                                              lineJoin: .round))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack {
                        Text(topLabel)
                        Spacer()
                        Text(bottomLabel)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
            .frame(height: height)
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        w * CGFloat(1.0 - (now - t) / window)
    }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let n = span > 0 ? (v - range.lowerBound) / span : 0.5
        return h * (1 - CGFloat(min(1, max(0, n))))
    }

    private func gridPath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            for i in 0...3 {
                let yy = h * CGFloat(i) / 3
                p.move(to: CGPoint(x: 0, y: yy))
                p.addLine(to: CGPoint(x: w, y: yy))
            }
        }
    }

    /// Screen-space points split into contiguous runs at `nil` gaps.
    private func screenRuns(w: CGFloat, h: CGFloat) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var cur: [CGPoint] = []
        for pt in points {
            if let v = pt.v {
                cur.append(CGPoint(x: x(pt.t, w), y: y(v, h)))
            } else if !cur.isEmpty {
                runs.append(cur); cur = []
            }
        }
        if !cur.isEmpty { runs.append(cur) }
        return runs
    }

    private func linePath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            for run in screenRuns(w: w, h: h) {
                addSmoothCurve(run, to: &p, moveToStart: true)
            }
        }
    }

    /// Filled area under each contiguous run, down to the baseline, with the
    /// same smooth top edge as the line.
    private func areaPath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            for run in screenRuns(w: w, h: h) where !run.isEmpty {
                p.move(to: CGPoint(x: run[0].x, y: h))
                addSmoothCurve(run, to: &p, moveToStart: false)
                p.addLine(to: CGPoint(x: run[run.count - 1].x, y: h))
                p.closeSubpath()
            }
        }
    }

    /// Append a smooth curve through `pts` using a uniform Catmull-Rom spline
    /// converted to cubic Bézier segments (control points at ±1/6 of the
    /// neighbour span) — rounds off the sample-to-sample stair-steps that
    /// straight segments showed. `moveToStart` begins a new subpath at the
    /// first point; otherwise it lines to it (so an area fill can start at
    /// the baseline).
    private func addSmoothCurve(_ pts: [CGPoint], to p: inout Path, moveToStart: Bool) {
        guard let first = pts.first else { return }
        if moveToStart { p.move(to: first) } else { p.addLine(to: first) }
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
}
