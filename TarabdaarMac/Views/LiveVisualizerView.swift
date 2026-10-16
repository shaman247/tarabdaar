import SarangiKit
import TarabdaarCore
import SwiftUI
import Combine

/// "Live" tab: what is reaching the audio engine — link status
/// and live graphs of played pitch, bus levels, strike and finger acceleration.
///
/// The pitch + volume traces are read from `AudioEngine.performanceReadout()`,
/// so they reflect every input path — the iPad over the link and the Mac pads.
/// Volume uses cached audio RMS from the sole meter relay, including released
/// tails, on the shared 60 dB scale.
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
        /// 0…1 on the shared −60…0 dBFS display scale.
        private(set) var volPts: [(t: Double, v: Double?)] = []
        private(set) var latestPitchHz: Double? = nil
        private(set) var latestVol: Double = 0
        private(set) var chromaticPts: [(t: Double, v: Double?)] = []
        private(set) var ragaPts: [(t: Double, v: Double?)] = []
        private(set) var strikePts: [(t: Double, v: Double?)] = []
        private(set) var fingerPts: [(t: Double, v: Double?)] = []
        private var fingerTracker = FingerAccelTracker()
        private var axisKey: (scale: PitchScale, tonicHz: Double)?
        private var axis: ClosedRange<Double> = 0...1

        func append(t: Double, pitchHz: Double?, vol: Double,
                    chromatic: Double, raga: Double, strike: Double,
                    touch: (id: Int, pitchSemis: Double)?, window: Double) {
            let finger = fingerTracker.sample(id: touch?.id,
                                               pitchSemis: touch?.pitchSemis, at: t)
            chromaticPts.append((t, chromatic))
            ragaPts.append((t, raga))
            strikePts.append((t, strike))
            fingerPts.append((t, finger))
            TimeSeries.trim(&chromaticPts, now: t, window: window) { $0.t }
            TimeSeries.trim(&ragaPts, now: t, window: window) { $0.t }
            TimeSeries.trim(&strikePts, now: t, window: window) { $0.t }
            TimeSeries.trim(&fingerPts, now: t, window: window) { $0.t }
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

    /// Visible time span of the graphs, in seconds.
    private let window: Double = 6
    private let sample = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                instrumentCard
                statusCard
                TimelineView(.animation) { timeline in
                    VStack(alignment: .leading, spacing: 24) {
                        motionCard
                        performanceCard(now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .padding(24)
        }
        .onReceive(sample) { _ in tick() }
    }

    private var motionCard: some View {
        let display = controller.joyConDisplay.frame()
        let raw = controller.joyCon.liveTrace.last.map { $0.raw * 2 - SIMD3<Double>(repeating: 1) } ?? .zero
        return HStack(alignment: .top, spacing: 24) {
            WristMotionPane(tilt: display)
            VStack(spacing: 4) {
                Text("stick").font(.padCaption2).foregroundStyle(.secondary)
                JoyConTiltPane(tilt: display)
            }
            VStack(spacing: 4) {
                Text("arm").font(.padCaption2).foregroundStyle(.secondary)
                ArmTiltPane(localTilts: [raw.x, raw.y, raw.z], display: display)
            }
        }
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

    /// The link: which bearer the iPad's frames arrive on (USB or
    /// Bluetooth) and the handshake over it.
    private var statusCard: some View {
        let readout = LinkReadout(midi: midi, status: controller.linkStatus)
        return VStack(alignment: .leading, spacing: 8) {
            Text("LINK")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: readout.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(readout.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(readout.headline)
                        .font(.title3)
                    Text(readout.detail)
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
                readout: "Main \(levelLabel(curVol))",
                topLabel: "0 dBFS",
                bottomLabel: "−60 dBFS",
                points: volPts,
                now: now,
                window: window,
                range: 0...1,
                color: .orange,
                fill: false,
                additionalSeries: [
                    .init(points: traces.chromaticPts, color: .cyan,
                          readout: "Chromatic \(levelLabel(traces.chromaticPts.last?.v ?? 0))"),
                    .init(points: traces.ragaPts, color: .purple,
                          readout: "Raga \(levelLabel(traces.ragaPts.last?.v ?? 0))")
                ])
            HStack(alignment: .top, spacing: 24) {
                TimeSeriesGraph(
                    title: "STRIKE",
                    readout: String(format: "%.0f", (traces.strikePts.last?.v ?? 0) * 127),
                    topLabel: "127", bottomLabel: "0",
                    points: traces.strikePts, now: now, window: window,
                    range: 0...1, color: .yellow, fill: false)
                TimeSeriesGraph(
                    title: "FINGER ACCEL",
                    readout: String(format: "%+.2f", traces.fingerPts.last?.v ?? 0),
                    topLabel: "+1", bottomLabel: "−1",
                    points: traces.fingerPts, now: now, window: window,
                    range: -1...1, color: .green, fill: false,
                    centered: true)
            }
        }
    }

    private func levelLabel(_ value: Double) -> String {
        value > 0 ? String(format: "%.0f dBFS", TLPVolume.db(from01: value)) : "≤ −60 dBFS"
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
        traces.append(t: now, pitchHz: pitch, vol: TLPVolume.level01(linear: r.voiceRMS),
                      chromatic: TLPVolume.level01(linear: r.chromaticRMS),
                      raga: TLPVolume.level01(linear: r.ragaRMS),
                      strike: controller.axes.strikeLevel,
                      touch: controller.currentTouches().last,
                      window: window)
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

    struct Series {
        let points: [(t: Double, v: Double?)]
        let color: Color
        let readout: String
    }
    var additionalSeries: [Series] = []
    var centered = false

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
                        linePath(points: points, w: w, h: h)
                            .stroke(color, style: StrokeStyle(lineWidth: 2,
                                                              lineCap: .round,
                                                              lineJoin: .round))
                        ForEach(additionalSeries.indices, id: \.self) { i in
                            linePath(points: additionalSeries[i].points, w: w, h: h)
                                .stroke(additionalSeries[i].color,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                           lineJoin: .round))
                        }
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
            if !additionalSeries.isEmpty {
                HStack(spacing: 18) {
                    ForEach(additionalSeries.indices, id: \.self) { i in
                        Text(additionalSeries[i].readout)
                            .foregroundStyle(additionalSeries[i].color)
                    }
                }
                .font(.padCaption.monospacedDigit())
            }
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
            let divisions = centered ? 4 : 3
            for i in 0...divisions {
                let yy = h * CGFloat(i) / CGFloat(divisions)
                p.move(to: CGPoint(x: 0, y: yy))
                p.addLine(to: CGPoint(x: w, y: yy))
            }
        }
    }

    /// Screen-space points split into contiguous runs at `nil` gaps.
    private func screenRuns(points: [(t: Double, v: Double?)], w: CGFloat, h: CGFloat) -> [[CGPoint]] {
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

    private func linePath(points: [(t: Double, v: Double?)], w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            for run in screenRuns(points: points, w: w, h: h) {
                p.addSmoothCurve(run)
            }
        }
    }

    /// Filled area under each contiguous run, down to the baseline, with the
    /// same smooth top edge as the line.
    private func areaPath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            for run in screenRuns(points: points, w: w, h: h) where !run.isEmpty {
                p.move(to: CGPoint(x: run[0].x, y: h))
                p.addSmoothCurve(run, moveToStart: false)
                p.addLine(to: CGPoint(x: run[run.count - 1].x, y: h))
                p.closeSubpath()
            }
        }
    }
}

// MARK: - Motion meters

/// Third-axis dot color: purple → cyan → orange over −1 → 0 → +1.
private func thirdAxisColor(_ v: Double) -> Color {
    Color(hue: 0.5 - v * 0.35, saturation: 0.9, brightness: 1.0)
}

/// The ARM tilts (1 on x, 2 on y, 3 as dot color): the Mac's CALIBRATED axes
/// while `armLive`, else the iPad's raw attitude, dimmed.
private struct ArmTiltPane: View {
    let localTilts: [Double]
    let display: JoyConTiltDisplay

    private func local(_ i: Int) -> Double {
        max(-1.0, min(1.0, i < localTilts.count ? localTilts[i] : 0))
    }

    var body: some View {
        let x = display.armLive ? display.arm1 : local(0)
        let y = display.armLive ? display.arm2 : local(1)
        let z = display.armLive ? display.arm3 : local(2)
        TiltSquare(x: x, y: y, dotColor: thirdAxisColor(z),
                   lit: display.armLive)
    }
}

/// The WRIST cluster from the Mac's fusion: three
/// bar triplets — the wrist tilt (fused attitude, or the solved axes once
/// calibrated), its rate (`JoyConWristMotion.rateFullScale`, 360°/s
/// rails) and the gravity-removed acceleration per body axis (±1 g) — and
/// one bar for that acceleration's magnitude on the same 1 g scale.
/// Dim while the fusion is silent.
private struct WristMotionPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        let lit = tilt.bodyLive
        HStack(alignment: .top, spacing: 6) {
            SignalBarGroup(caption: "wrist", color: .cyan, lit: lit,
                           bipolar: [tilt.wrist1, tilt.wrist2, tilt.wrist3])
            SignalBarGroup(caption: "d/dt", color: .yellow, lit: lit,
                           bipolar: [tilt.wristRate1, tilt.wristRate2,
                                     tilt.wristRate3])
            SignalBarGroup(caption: "accel", color: .orange, lit: lit,
                           bipolar: [tilt.accel1, tilt.accel2, tilt.accel3],
                           unipolar: tilt.accelLevel)
        }
    }
}

/// A caption over a stack of `SignalBar`s: bipolar rows (−1…+1, centre
/// tick) and an optional unipolar row (0…1, left-anchored) beneath them.
private struct SignalBarGroup: View {
    let caption: String
    let color: Color
    let lit: Bool
    let bipolar: [Double]
    var unipolar: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.padCaption2)
                .foregroundColor(lit ? color : .gray)
                .fixedSize()
            ForEach(bipolar.indices, id: \.self) { i in
                SignalBar(value: bipolar[i], bipolar: true,
                          color: color, lit: lit)
            }
            if let unipolar {
                SignalBar(value: unipolar, bipolar: false,
                          color: color, lit: lit)
            }
        }
    }
}

/// One 40 × 5 pt horizontal bar. Bipolar: the fill grows from the centre
/// tick toward either end (value −1…+1). Unipolar: from the left (0…1).
private struct SignalBar: View {
    let value: Double
    let bipolar: Bool
    let color: Color
    let lit: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let v = CGFloat(max(-1.0, min(1.0, value)))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(lit ? 0.25 : 0.15))
                if bipolar {
                    Rectangle()
                        .fill(lit ? color : Color.gray)
                        .frame(width: abs(v) * w / 2, height: h)
                        .offset(x: v >= 0 ? w / 2 : w / 2 + v * w / 2)
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 1, height: h)
                        .offset(x: w / 2 - 0.5)
                } else {
                    Rectangle()
                        .fill(lit ? color : Color.gray)
                        .frame(width: max(0, v) * w, height: h)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(width: 40, height: 5)
    }
}

/// The Mac's Joy-Con stick axes. Bright while connected.
private struct JoyConTiltPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        TiltSquare(x: tilt.stickX, y: tilt.stickY,
                   dotColor: tilt.stickLive ? .green : .gray,
                   lit: tilt.stickLive)
    }
}

/// Shared 36 pt crosshair square (values −1…+1, centre = 0, y up).
private struct TiltSquare: View {
    let x: Double
    let y: Double
    let dotColor: Color
    let lit: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(lit ? 0.25 : 0.15))
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: h)
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: w, height: 1)
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .position(x: (1 + CGFloat(x)) / 2 * w,
                              y: (1 - CGFloat(y)) / 2 * h)
            }
        }
        .frame(width: 36, height: 36)
    }
}
