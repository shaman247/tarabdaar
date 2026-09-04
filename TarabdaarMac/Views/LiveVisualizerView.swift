import SarangiKit
import TarabdaarCore
import SwiftUI

/// "Live" tab: what is reaching the audio engine — link status,
/// render-time metrics, and live time-series graphs of the **played
/// pitch** and **volume**.
///
/// The pitch + volume traces are read from `AudioEngine.performanceReadout()`,
/// derived at the single voice-routing choke point, so they reflect every
/// input path — the iPad over the link and the Mac pads. The volume line
/// is the commanded expression.
///
/// The graphs show a fixed **6-second** window and scroll smoothly: a
/// 60 Hz timer appends timestamped samples to an unpublished ring buffer
/// (`TraceBuffer`, a reference the tick mutates without re-evaluating the
/// view), and a `TimelineView(.animation)` polls it every display frame,
/// placing each sample at an x derived from its age — so the trace slides
/// left continuously rather than stepping at the sample rate.
struct LiveVisualizerView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var midi: MIDIEngine

    init(controller: AppController) {
        self.controller = controller
        self.midi = controller.midi
    }

    /// The pitch and volume traces in the graphs' own point form, plus the
    /// pitch axis memoised on the scale and tonic that set it.
    private final class TraceBuffer {
        /// log2(Hz); nil when silent.
        private(set) var pitchPts: [(t: Double, v: Double?)] = []
        /// 0…1 (commanded expression).
        private(set) var volPts: [(t: Double, v: Double?)] = []
        private(set) var latestPitchHz: Double? = nil
        private(set) var latestVol: Double = 0
        private var axisKey: (scale: PitchScale, tonicHz: Double)?
        private var axis: ClosedRange<Double> = 0...1

        func append(t: Double, pitchHz: Double?, vol: Double, window: Double) {
            pitchPts.append((t: t, v: pitchHz.map { log2($0) }))
            volPts.append((t: t, v: vol))
            latestPitchHz = pitchHz
            latestVol = vol
            TimeSeries.trim(&pitchPts, now: t, window: window) { $0.t }
            TimeSeries.trim(&volPts, now: t, window: window) { $0.t }
        }

        func axisRange(scale: PitchScale, tonicHz: Double,
                       compute: () -> ClosedRange<Double>) -> ClosedRange<Double> {
            if let axisKey, axisKey.tonicHz == tonicHz, axisKey.scale == scale {
                return axis
            }
            axis = compute()
            axisKey = (scale, tonicHz)
            return axis
        }
    }

    @State private var traces = TraceBuffer()
    @State private var renderTimeMs: Double = 0
    @State private var maxRenderTimeMs: Double = 0
    @State private var sampleCounter = 0

    /// Visible time span of the graphs, in seconds.
    private let window: Double = 6
    private let sample = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            instrumentCard
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

    /// Which voice the played notes drive (tanpura port): the
    /// String bowed voice or the tanpura (fret note-ons become plucks at
    /// the exact bent pitch; glides/note-offs are ignored — it rings). The
    /// drone buttons' voice is a separate choice on the Strings tab.
    private var instrumentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INSTRUMENT")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            Picker("", selection: $controller.mainInstrument) {
                Text("String (bowed)").tag(AudioEngine.MainInstrument.string)
                Text("Tanpura (plucked)").tag(AudioEngine.MainInstrument.tanpura)
                Text("Sitar (plucked)").tag(AudioEngine.MainInstrument.sitar)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            if controller.mainInstrument == .tanpura {
                Text(controller.audio.isTanpuraArmed
                     ? "Fret notes pluck the tanpura at the nearest scale pitch; strings ring out on their own (no note-off). Its ring drives the Strings-tab taraf sympathetically (tp_taraf)."
                     : "Tanpura is still mounting its strings — silent until the build lands.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
            }
            if controller.mainInstrument == .sitar {
                Text(controller.audio.isSitarArmed
                     ? "Fret notes pluck the sitar at the exact bent pitch; its ring drives the Strings-tab taraf sympathetically (st_taraf)."
                     : "Sitar is still mounting its strings — silent until the build lands.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIDI INPUT")
                .font(.padCaption.weight(.bold))
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
                        .font(.padCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func performanceCard(now: Double) -> some View {
        let curPitch = traces.latestPitchHz
        let curVol = traces.latestVol
        let pitchPts = traces.pitchPts
        let volPts = traces.volPts
        let scale = controller.pitchPad.scale
        let tonicHz = controller.pitchPad.tonicHz
        let pRange = traces.axisRange(scale: scale, tonicHz: tonicHz) {
            pitchAxisRange(scale: scale, tonicHz: tonicHz)
        }
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
        .font(.padCaption)
        .foregroundStyle(.secondary)
    }

    /// Fixed y-bounds for the pitch graph, in log2(Hz): the span of the Fret
    /// Pad scale's degrees around the tonic (plus an octave of headroom each
    /// side for the octave-repeat ghost frets), so the axis is a stable
    /// reference tied to the instrument's compass rather than drifting with
    /// what's played. Falls back to two octaves around the tonic.
    private func pitchAxisRange(scale: PitchScale,
                                tonicHz: Double) -> ClosedRange<Double> {
        let ratios = scaleDegrees(from: scale)
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
        // The buffer keeps a little beyond the window so the line enters
        // cleanly from the left edge (clipped) rather than starting at the
        // first sample.
        traces.append(t: now, pitchHz: pitch, vol: r.active ? r.expression : 0,
                      window: window)
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
        let midi = Pitch.fractionalMidi(hz: hz)
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
                    .font(.padCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout)
                    .font(.system(size: Typography.callout, design: .monospaced).weight(.medium))
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
                    .font(.padSmall(9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
            .frame(height: height)
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        TimeSeries.x(t, now: now, window: window, width: w)
    }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        TimeSeries.y(v, range: range, bottom: h, height: h)
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
                p.addSmoothCurve(run)
            }
        }
    }

    /// Filled area under each contiguous run, down to the baseline, with the
    /// same smooth top edge as the line.
    private func areaPath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            for run in screenRuns(w: w, h: h) where !run.isEmpty {
                p.move(to: CGPoint(x: run[0].x, y: h))
                p.addSmoothCurve(run, moveToStart: false)
                p.addLine(to: CGPoint(x: run[run.count - 1].x, y: h))
                p.closeSubpath()
            }
        }
    }
}
