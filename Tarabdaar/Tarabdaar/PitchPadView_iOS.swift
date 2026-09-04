import CoreAudioKit
import QuartzCore
import TarabdaarCore
import SwiftUI
import simd

/// The iPad's playing surface is the Fret Pad (`FretPadViewIOS`). Touches
/// resolve to pitch via `FretPadGeometry` and ride the outbound TLP state with
/// the RAW tilt axes — the iPad evaluates no bindings. Scale + fret editing
/// live on the Mac and sync here over TLP events.

// MARK: - Shared pad toolbar (iPad)

/// The iPad pad toolbar — PANIC, REC, scale-sync, tilt meters, scopes, the
/// sounding readout and the read-only synced tonic.
struct PadToolbarIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    /// Drives the USB/Bluetooth transport indicators.
    @ObservedObject var midi: MIDIEngine
    /// When set, a REC toggle records play strokes (`FretGestureRecorder`).
    var recorder: FretGestureRecorder? = nil
    /// When set, the strike scope draws beside the tilt panes.
    var motion: MotionManager? = nil
    /// When set, the finger-accel scope draws (display-only local instance of
    /// the `FingerAccelTracker` law the Mac's bindings consume).
    var fingerAccel: FingerAccelSampler? = nil
    /// Toggles the raw-motion diagnostic overlay (GYRO button).
    @Binding var showGyro: Bool

    var body: some View {
        HStack(spacing: 14) {
            button("PANIC", color: .red) { engine.panic() }
            if let recorder {
                RecToggleIOS(recorder: recorder)
            }
            button("GYRO", color: showGyro ? .blue : Color.gray.opacity(0.6)) {
                showGyro.toggle()
            }
            ScaleSyncIndicator(scaleSync: scaleSync)
            Spacer(minLength: 12)
            // Tilt squares: ARM, WRIST (Joy-Con fusion), stick.
            ArmTiltPane(localTilts: noteManager.currentTilt,
                        display: scaleSync.joyConTilt)
            WristTiltPane(tilt: scaleSync.joyConTilt)
            JoyConTiltPane(tilt: scaleSync.joyConTilt)
            if let motion {
                // The onset fade tracks the Mac's blend window
                // (`ctl_strike_window`, relayed over JOYCON_STATE).
                ScopeTracePane(width: 150) {
                    ScopeTraces.strike(motion: motion,
                                       fadeS: scaleSync.joyConTilt.strikeWindowS)
                }
            }
            if let fingerAccel {
                ScopeTracePane(width: 150) {
                    ScopeTraces.fingerAccel(history: fingerAccel, motion: motion)
                }
            }
            // The Mac's radiated voice/taraf levels (JOYCON_STATE).
            ScopeTracePane(width: 120) {
                ScopeTraces.volume(history: scaleSync.volumeHistory,
                                   motion: motion)
            }
            Spacer(minLength: 12)
            SoundingReadout(sounding: engine.sounding,
                            tonicFractionalMidi: engine.tonicFractionalMidi,
                            style: .column(width: 150))
            // The playing-range octave shift (Mac dpad, JOYCON_STATE).
            Text("Oct \(engine.octaveShift > 0 ? "+" : "")\(engine.octaveShift)")
                .font(.padCaption2.monospacedDigit())
                .foregroundColor(engine.octaveShift == 0 ? .gray : .orange)
                .fixedSize()
            // Tonic is set on the Mac and synced over — read-only here.
            Text("Tonic \(Scale.noteName(for: engine.tonicMidi))")
                .font(.padCaption2).foregroundColor(.gray)
                .fixedSize()
            TransportIndicatorsIOS(midi: midi)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black)
    }

    private func button(_ title: String, color: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.padCaption).fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(0.7))
                .cornerRadius(6)
        }
    }
}

// MARK: - Stroke-recording toggle (Fret Pad)

/// REC button: records play strokes to **Documents/FretRecordings/** as JSONL
/// (visible in Files / Finder) for `tools/fretpad_fit.py`.
private struct RecToggleIOS: View {
    @ObservedObject var recorder: FretGestureRecorder

    var body: some View {
        Button {
            recorder.setRecording(!recorder.isRecording)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.gray.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(recorder.isRecording ? "REC \(recorder.strokeCount)" : "REC")
                    .font(.padCaption).fontWeight(.bold).monospacedDigit()
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((recorder.isRecording ? Color.red : Color.gray)
                .opacity(recorder.isRecording ? 0.45 : 0.25))
            .cornerRadius(6)
        }
    }
}

// MARK: - Transport indicators + Bluetooth MIDI (BLE-MIDI advertise)

/// USB + Bluetooth indicators: **green** = carrying the link (wired-first),
/// **white** = idle, **dim gray** = absent. The antenna presents the system
/// BLE-MIDI peripheral sheet so the iPad can advertise (the Mac connects from
/// Audio MIDI Setup → Bluetooth); advertising is per-session.
private struct TransportIndicatorsIOS: View {
    @ObservedObject var midi: MIDIEngine
    @State private var showBluetoothSheet = false

    var body: some View {
        let usbPresent = midi.wiredDestinationCount > 0
        let btPresent = midi.bluetoothDestinationCount > 0
        HStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .font(.padCaption)
                .foregroundColor(color(present: usbPresent, active: usbPresent))
            Button {
                showBluetoothSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.padCaption)
                    .foregroundColor(color(present: btPresent,
                                           active: btPresent && !usbPresent))
            }
        }
        .sheet(isPresented: $showBluetoothSheet) {
            BluetoothMIDIPeripheralSheet()
        }
    }

    private func color(present: Bool, active: Bool) -> Color {
        active ? .green : (present ? .white.opacity(0.7) : .gray.opacity(0.35))
    }
}

/// `CABTMIDILocalPeripheralViewController` wrapped for SwiftUI.
private struct BluetoothMIDIPeripheralSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDILocalPeripheralViewController())
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

// MARK: - Scale-sync indicator

/// Scale-sync status: green once the Mac has pushed a scale.
struct ScaleSyncIndicator: View {
    @ObservedObject var scaleSync: ScaleSyncReceiver

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(scaleSync.syncCount > 0 ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(scaleSync.syncCount > 0 ? "synced" : "no sync")
                .font(.padSmall(9))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Tilt pad

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

/// The WRIST attitude — the Joy-Con's fused pitch / roll / yaw, from the Mac.
private struct WristTiltPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        TiltSquare(x: tilt.wrist1, y: tilt.wrist2,
                   dotColor: tilt.bodyLive ? thirdAxisColor(tilt.wrist3)
                                           : .gray,
                   lit: tilt.bodyLive)
    }
}

/// The Mac's Joy-Con stick axes (`JOYCON_STATE` relay). Bright while deflected.
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

/// One toolbar scope's frame of data: the traces to decimate, the note
/// timeline behind them and how the pane reads them out. Built once per poll
/// by `ScopeTraces.strike` / `.fingerAccel` / `.volume`; `ScopeTracePane`
/// turns it into pixels.
private struct ScopeTraceFrame {
    struct Trace {
        let samples: [(t: TimeInterval, v: Double)]
        /// Peak-hold keeps the largest |v| with its sign (a centred trace)
        /// rather than the largest v.
        let signedPeak: Bool
        /// Empty bins repeat the last value — sparse, change-gated feeds.
        let forwardFill: Bool
        /// Colour of the segment ending in a bin, from the bin's centre time
        /// and whether a note was sounding there.
        let color: (TimeInterval, Bool) -> Color
    }
    struct Label {
        let text: Text
        let box: CGSize
        /// Vertical centre; nil = the top-right corner.
        let y: CGFloat?
    }
    /// Which value the labels read per trace.
    enum Readout {
        /// The newest sample — dense feeds.
        case newestSample
        /// The last bin's held value — sparse, forward-filled feeds.
        case lastBin
    }

    /// Drawn in order: the last trace on top.
    let traces: [Trace]
    let activity: [(t: TimeInterval, active: Int)]
    /// The window scrolls with the clock rather than the newest sample.
    let endsAtNow: Bool
    let guides: [(fraction: Double, opacity: Double)]
    /// Value → fraction of the pane height, bottom to top.
    let y01: (Double) -> Double
    /// A held reading marked by an amber tick at the right edge.
    let tick: Double?
    let readout: Readout
    /// The value labels, from one readout per trace.
    let labels: ([Double]) -> [Label]
}

/// The one toolbar scope view: polls a `ScopeTraceFrame`, decimates each
/// trace per-bin (peak-hold), and draws the note backdrop, the guides, the
/// traces, the tick and the labels over `ScopePane`'s grid.
private struct ScopeTracePane: View {
    let width: CGFloat
    let sample: () -> ScopeTraceFrame

    var body: some View {
        ScopePane(width: width, sample: sample, draw: Self.draw)
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             frame: ScopeTraceFrame) {
        let w = size.width, h = size.height
        let newest = frame.traces.compactMap { $0.samples.last?.t }.max()
        guard let newest else { return }
        let end = frame.endsAtNow ? ProcessInfo.processInfo.systemUptime
                                  : newest
        let bins = ScopeTrace.Bins(width: w, endingAt: end)
        // Per-bin peak-hold, so brief bursts survive decimation; NaN = empty.
        let held: [[Double]] = frame.traces.map { trace in
            var peak = [Double](repeating: .nan, count: bins.count)
            var seed = Double.nan
            for s in trace.samples {
                guard s.t >= bins.t0 else { seed = s.v; continue }
                let b = bins.index(of: s.t)
                let above = trace.signedPeak ? abs(s.v) > abs(peak[b])
                                             : s.v > peak[b]
                if peak[b].isNaN || above { peak[b] = s.v }
            }
            if trace.forwardFill {
                var fill = seed.isNaN ? 0.0 : seed
                for b in 0..<bins.count {
                    if peak[b].isNaN { peak[b] = fill } else { fill = peak[b] }
                }
            }
            return peak
        }
        let soundingArr = ScopeTrace.soundingBins(frame.activity, bins: bins)
        ScopeTrace.fillActivity(ctx, size: size, sounding: soundingArr)
        ScopeTrace.guides(ctx, size: size, frame.guides)
        func yFor(_ v: Double) -> CGFloat {
            h - CGFloat(frame.y01(v)) * (h - 2) - 1
        }
        // Each trace stroked per-pair with the newer bin's colour.
        for (trace, peak) in zip(frame.traces, held) {
            var prevPt: CGPoint? = nil
            for b in 0..<bins.count where !peak[b].isNaN {
                let pt = CGPoint(x: bins.x(b, width: w), y: yFor(peak[b]))
                if let pp = prevPt {
                    var seg = Path()
                    seg.move(to: pp)
                    seg.addLine(to: pt)
                    let c = trace.color(bins.center(b), soundingArr[b])
                    ctx.stroke(seg, with: .color(c), lineWidth: 1.5)
                }
                prevPt = pt
            }
        }
        if let tick = frame.tick {
            var path = Path()
            let y = yFor(tick)
            path.move(to: CGPoint(x: w - 7, y: y))
            path.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(path, with: .color(.orange), lineWidth: 2)
        }
        let readouts: [Double]
        switch frame.readout {
        case .newestSample:
            readouts = frame.traces.map { $0.samples.last?.v ?? 0 }
        case .lastBin:
            readouts = held.map { $0[bins.count - 1] }
        }
        for label in frame.labels(readouts) {
            ScopeTrace.drawValueLabel(ctx, label.text, size: size,
                                      measureIn: label.box, y: label.y)
        }
    }
}

/// The three toolbar scopes as `ScopeTraceFrame` builders.
private enum ScopeTraces {
    private static let idleGray = Color(white: 0.38).opacity(0.9)

    /// The strike scope: the strike envelope (0–127 wire scale) with the
    /// current value at the right; the amber tick holds the last onset's
    /// reading. Pale yellow at an onset fading down `ScopeColor.level` over
    /// `fadeS` (the Mac's `ctl_strike_window` blend window), dark gray
    /// while nothing plays.
    static func strike(motion: MotionManager, fadeS: Double) -> ScopeTraceFrame {
        let onsets = motion.noteOnsets
        let fade = max(fadeS, 0.05)
        let lastStrike = motion.lastTouchVelocity
        return ScopeTraceFrame(
            traces: [.init(
                samples: motion.strikeHistory.map { (t: $0.t, v: $0.level) },
                signedPeak: false, forwardFill: false,
                color: { binT, sounding in
                    guard sounding else { return idleGray }
                    let age = lastOnset(in: onsets, atOrBefore: binT)
                        .map { binT - $0 } ?? fade
                    let f = min(max(age / fade, 0.0), 1.0)
                    return ScopeColor.level(1 - f).opacity(0.95)
                })],
            activity: motion.noteActivity,
            endsAtNow: false,
            // Guide lines at thirds (≈42 / 85).
            guides: [(1.0 / 3.0, 0.12), (2.0 / 3.0, 0.12)],
            y01: { $0 },
            tick: lastStrike > 0 ? lastStrike : nil,
            readout: .newestSample,
            labels: { v in [wireLabel(v[0], width: 40)] })
    }

    /// The finger-accel scope: the finger's pitch acceleration on the
    /// `.fingerAccel` −1…+1 scale (centerline = rest or constant-rate
    /// meend), from the iPad's own `FingerAccelSampler` instance of the
    /// shared law. Green while a note sounds.
    static func fingerAccel(history: FingerAccelSampler,
                            motion: MotionManager?) -> ScopeTraceFrame {
        ScopeTraceFrame(
            traces: [.init(
                samples: history.history(),
                signedPeak: true, forwardFill: false,
                color: { _, sounding in
                    sounding
                        ? Color(red: 0.55, green: 1.0, blue: 0.55).opacity(0.95)
                        : idleGray
                })],
            activity: motion?.noteActivity ?? [],
            endsAtNow: false,
            // Centerline (rest) bright-ish, ±0.5 guides faint.
            guides: [(0.5, 0.25), (0.25, 0.12), (0.75, 0.12)],
            y01: { ($0 + 1) / 2 },
            tick: nil,
            readout: .newestSample,
            labels: { v in [wireLabel(v[0], width: 44)] })
    }

    /// The volume scope: the Mac's radiated voice and taraf levels on the
    /// wire's 0…1 log scale (−60…0 dBFS, `TLPVolume`; guides = 20 dB) with
    /// the current dB at the right. Samples are unsmoothed RMS, change-gated
    /// on the wire, so bins peak-hold and forward-fill and the window
    /// scrolls with NOW rather than the last (sparse) sample. Voice orange
    /// over taraf cyan while a note sounds.
    static func volume(history: VolumeHistory,
                       motion: MotionManager?) -> ScopeTraceFrame {
        let samples = history.snapshot()
        let voiceColor = Color.orange, tarafColor = Color.cyan
        let voiceIdle = Color(white: 0.55).opacity(0.9)
        let tarafIdle = Color(white: 0.35).opacity(0.9)
        func trace(_ value: @escaping (VolumeHistory.Sample) -> Double,
                   active: Color, idle: Color) -> ScopeTraceFrame.Trace {
            .init(samples: samples.map { (t: $0.t, v: value($0)) },
                  signedPeak: false, forwardFill: true,
                  color: { _, sounding in sounding ? active : idle })
        }
        // Current dB values, voice above taraf; silence prints nothing.
        func label(_ v01: Double, _ color: Color,
                   y: CGFloat) -> ScopeTraceFrame.Label? {
            guard v01 > 0 else { return nil }
            let db = Int(TLPVolume.db(from01: v01).rounded())
            return .init(text: Text("\(db)")
                            .font(.padSmall(9).monospacedDigit())
                            .foregroundColor(color.opacity(0.95)),
                         box: CGSize(width: 40, height: 14), y: y)
        }
        return ScopeTraceFrame(
            traces: [trace({ $0.taraf }, active: tarafColor, idle: tarafIdle),
                     trace({ $0.voice }, active: voiceColor, idle: voiceIdle)],
            activity: motion?.noteActivity ?? [],
            endsAtNow: true,
            // Guide lines at thirds (20 dB steps).
            guides: [(1.0 / 3.0, 0.12), (2.0 / 3.0, 0.12)],
            y01: { $0 },
            tick: nil,
            readout: .lastBin,
            labels: { v in
                [label(v[1], voiceColor, y: 7),
                 label(v[0], tarafColor, y: ScopeTrace.paneHeight - 7)]
                    .compactMap { $0 }
            })
    }

    /// The live value on the wire's ±127 scale.
    private static func wireLabel(_ v: Double, width: CGFloat) -> ScopeTraceFrame.Label {
        .init(text: Text("\(Int((v * 127).rounded()))")
                  .font(.padSmall(10).monospacedDigit())
                  .foregroundColor(.white.opacity(0.9)),
              box: CGSize(width: width, height: 16), y: nil)
    }

    /// The newest onset at or before `t` (the onsets are ordered).
    private static func lastOnset(in onsets: [TimeInterval],
                                  atOrBefore t: TimeInterval) -> TimeInterval? {
        var lo = 0, hi = onsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if onsets[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? onsets[lo - 1] : nil
    }
}

// MARK: - Fret Pad (iPad)

/// The iPad Fret Pad — the counterpart of the Mac [Fret Pad](../../docs/fret-pad.md)
/// tab, perform-only; the `FretArrangement` arrives as a TLP event
/// (`ScaleSyncReceiver.fretArrangement`). Same field / onset snap / continuous
/// drag laws as the Mac, fully multitouch.
struct FretPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    @ObservedObject var midi: MIDIEngine
    let arrangement: FretArrangement
    /// The motion source, for the raw-motion diagnostic overlay.
    var motion: MotionManager? = nil
    /// The display-only finger-accel feed for the toolbar scope.
    var fingerAccel: FingerAccelSampler? = nil

    /// Records play strokes to Documents/FretRecordings/ for offline fitting
    /// of the drag-assist parameters (toolbar REC toggle).
    @StateObject private var recorder = FretGestureRecorder()
    @State private var showGyro = false

    var body: some View {
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          midi: midi, recorder: recorder, motion: motion,
                          fingerAccel: fingerAccel,
                          showGyro: $showGyro)
            // The playable band (`fretPadBandRect`) is the centered half-height
            // strip; the rest is dead except the drone buttons, which hide
            // while a Joy-Con is attached to the Mac (JOYCON_STATE).
            FretPadSurfaceIOS(engine: engine, arrangement: arrangement,
                              fieldWarp: scaleSync.joyConTilt.fieldWarp,
                              recorder: recorder,
                              dronesHidden: scaleSync.joyConTilt.connected,
                              motion: motion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if showGyro, let motion {
                        HStack(alignment: .top, spacing: 10) {
                            RawAccelOverlay(motion: motion)
                            RawMotionOverlay(motion: motion)
                        }
                        .padding(12)
                    }
                }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Raw motion overlay (diagnostic)

/// 3D view of RAW CoreMotion attitude over the last ~8 s, before the yaw
/// high-pass and the wire (GYRO button): wobble HERE is the sensor, wobble
/// only on the Mac's scope is the wire. Δ readouts are window peak-to-peak in
/// degrees; raw yaw drift here is expected.
struct RawMotionOverlay: View {
    let motion: MotionManager

    private static let spin = 0.3
    private static let colors: [Color] = [.orange, .green, .cyan]
    private static let names = ["pitch", "roll ", "yaw  "]
    /// Fixed ±30° scale (the Mac view's constant); centred on the trail mean.
    private static let viewRadius = 30.0 * Double.pi / 180

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let hist = motion.attitudeHistory
            VStack(alignment: .leading, spacing: 3) {
                Canvas { ctx, size in
                    Self.draw(ctx, size: size, hist: hist,
                              azimuth: Date().timeIntervalSinceReferenceDate
                                  * Self.spin)
                }
                .frame(width: 250, height: 190)
                ForEach(0..<3, id: \.self) { a in
                    let vals = hist.map { a == 0 ? $0.p : a == 1 ? $0.r : $0.y }
                    let pp = ((vals.max() ?? 0) - (vals.min() ?? 0)) * 180 / .pi
                    let cur = (vals.last ?? 0) * 180 / .pi
                    Text(String(format: "%@ %+8.3f°  Δ%.3f°",
                                Self.names[a], cur, pp))
                        .font(.padSmall(10).monospacedDigit())
                        .foregroundColor(Self.colors[a])
                }
                Text("raw attitude, pre-wire · last 8 s")
                    .font(.padSmall(9))
                    .foregroundColor(.gray)
            }
            .padding(10)
            .background(Color.black.opacity(0.85))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             hist: [(t: TimeInterval, p: Double, r: Double, y: Double)],
                             azimuth: Double) {
        // Centred on the trail mean — the rest pose is arbitrary.
        MotionScatter.drawTrail(ctx, size: size,
                                points: hist.map { SIMD3($0.p, $0.r, $0.y) },
                                maxRadius: viewRadius, axisColors: colors,
                                azimuth: azimuth)
    }
}

/// Raw userAcceleration (g) over the last ~8 s as the same turntable trail,
/// centred on the origin, fixed ±0.5 g (the Mac view's constant).
struct RawAccelOverlay: View {
    let motion: MotionManager

    private static let spin = 0.3
    private static let colors: [Color] = [.orange, .green, .cyan]
    private static let names = ["x", "y", "z"]
    /// Fixed ±0.5 g to the frame edge (the Mac view's constant).
    private static let viewRadius = 0.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let hist = motion.accelHistory3D
            VStack(alignment: .leading, spacing: 3) {
                Canvas { ctx, size in
                    Self.draw(ctx, size: size, hist: hist,
                              azimuth: Date().timeIntervalSinceReferenceDate
                                  * Self.spin)
                }
                .frame(width: 250, height: 190)
                ForEach(0..<3, id: \.self) { a in
                    let vals = hist.map { a == 0 ? $0.x : a == 1 ? $0.y : $0.z }
                    let pp = (vals.max() ?? 0) - (vals.min() ?? 0)
                    let cur = vals.last ?? 0
                    Text(String(format: "%@ %+8.3f g  Δ%.3f g",
                                Self.names[a], cur, pp))
                        .font(.padSmall(10).monospacedDigit())
                        .foregroundColor(Self.colors[a])
                }
                Text("raw userAcceleration, pre-wire · last 8 s")
                    .font(.padSmall(9))
                    .foregroundColor(.gray)
            }
            .padding(10)
            .background(Color.black.opacity(0.85))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             hist: [(t: TimeInterval, x: Double, y: Double, z: Double)],
                             azimuth: Double) {
        // Origin-centred: acceleration has a natural zero.
        MotionScatter.drawTrail(ctx, size: size,
                                points: hist.map { SIMD3($0.x, $0.y, $0.z) },
                                maxRadius: viewRadius,
                                center: SIMD3<Double>(),
                                axisColors: colors, azimuth: azimuth)
    }
}

/// The surface's layout — the scale degrees, the fret placements and the
/// chord-bar cells — recomputed only when the arrangement, the scale or the
/// surface size changes; a touch or a redraw tick reuses the last one. A
/// class so the surface's body can refresh it without a state write.
private final class FretLayoutMemo {
    typealias Layout = (degrees: [(ratio: Double, label: String)],
                        placements: [FretPlacement],
                        chordCells: [ChordBarCell])
    private var key: (arrangement: FretArrangement, scale: PitchScale,
                      size: CGSize)?
    private var layout: Layout = ([], [], [])

    func resolve(arrangement: FretArrangement, scale: PitchScale,
                 size: CGSize) -> Layout {
        if let key, key.arrangement == arrangement, key.scale == scale,
           key.size == size {
            return layout
        }
        let band = fretPadBandRect(in: size)
        let degrees = scaleDegrees(from: scale)
        layout = (degrees,
                  fretPlacements(arrangement: arrangement, degrees: degrees,
                                 size: band.size),
                  chordBarCells(arrangement: arrangement, degrees: degrees,
                                chords: scaleChords(degrees: degrees),
                                size: size))
        key = (arrangement, scale, size)
        return layout
    }
}

private struct FretPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: FretArrangement
    /// The Mac's live `ctl_fret_warp` (JOYCON_STATE relay) — every onset/move
    /// resolves through it. 0 (linear) while the link is down.
    let fieldWarp: Double
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureRecorder
    /// While a Joy-Con is attached to the Mac its arrows play the drones, so
    /// the on-screen buttons hide (visual + hit-test).
    let dronesHidden: Bool
    /// Source of the per-onset strike estimate (`strikeVelocity01` → the
    /// onset frame's velocity byte → `bow_attack_vel`). nil = flat constant.
    let motion: MotionManager?
    /// The touch pipeline (onset, drag, settle tick, release).
    @State private var player = FretTouchPlayer()
    /// Touches holding a drone button (touchId → button index).
    @State private var droneTouches: [Int: Int] = [:]
    /// Per-touch indicator — a class so the settle timer can feed it.
    @StateObject private var indicators = TouchIndicatorModel()
    /// The fret and chord-bar layout, memoised on what changes it.
    @State private var layout = FretLayoutMemo()

    private let edgePad: CGFloat = 12
    /// Onset-snap half-width in px — the synced `marginPixels`. 0 = fretless.
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // The playable band — the frets' coordinate space.
            let band = fretPadBandRect(in: size)
            let (degrees, placements, chordCells) = layout.resolve(
                arrangement: arrangement, scale: engine.scale, size: size)

            ZStack(alignment: .topLeading) {
                Color.black

                // Always perform mode: fret lines only, ghosts like base frets.
                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    // Band border — the playable strip against the dead space.
                    ctx.strokeFretBand(band)
                    ctx.translateBy(x: band.minX, y: band.minY)
                    for p in placements {
                        let hue = pitchColor(forRatio: p.ratio,
                                             lightness: 0.82, chroma: 0.20)
                        var line = Path()
                        line.move(to: CGPoint(x: p.x, y: p.topY))
                        line.addLine(to: CGPoint(x: p.x, y: p.bottomY))
                        ctx.stroke(line, with: .color(hue), lineWidth: 1.5)
                    }
                }

                // Dynamic layer: live sounding glow (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: fretFillCells(placements), edgePad: edgePad)
                    .offset(x: band.minX, y: band.minY)

                // Per-touch indicator: fingertip-radius ring + size arc.
                TouchIndicatorLayerIOS(model: indicators, edgePad: edgePad)

                // The chord bar (display only; taps hit-tested in `began`).
                ChordBarVisual(cells: chordCells,
                               active: engine.chordSelection,
                               edgePad: edgePad, cornerRadius: 6,
                               fontSize: 14)

                // Drone buttons (display only; hidden with a Joy-Con attached).
                if !dronesHidden {
                    DroneButtonsVisual(ratios: arrangement.droneRatios,
                                       degrees: degrees,
                                       held: Set(droneTouches.values),
                                       size: size, edgePad: edgePad,
                                       cornerRadius: 10, fontSize: 15)
                }

                TouchOverlayView(
                    onTouchBegan: { ev in began(ev, placements: placements,
                                                size: size, band: band,
                                                chordCells: chordCells) },
                    onTouchMoved: { ev in moved(ev, placements: placements,
                                                size: size, band: band) },
                    onTouchEnded: { id in
                        let now = CACurrentMediaTime()
                        // Drone touch: release the button (unless another
                        // finger holds it) and skip the note path.
                        if let d = droneTouches.removeValue(forKey: id) {
                            if !droneTouches.values.contains(d) {
                                engine.setDrone(d, pressed: false)
                            }
                            return
                        }
                        player.end(touchId: id, time: now)
                        indicators.end(id)
                        motion?.noteEnded(id, at: now)   // scope coloring
                    }
                )
                .padding(edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// Onset: snap within the Snap distance of a fret inside its extent, else
    /// play the field pitch. Registers with the drag assist, starts its timer.
    private func began(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect,
                       chordCells: [ChordBarCell]) {
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        // Drone buttons first (onsets only; skipped while hidden).
        if !dronesHidden,
           let d = droneButtonRects(size: size).firstIndex(where: { $0.contains(spt) }) {
            let alreadyHeld = droneTouches.values.contains(d)
            droneTouches[ev.touchId] = d
            if !alreadyHeld { engine.setDrone(d, pressed: true) }
            return
        }
        // Chord bar: a tap toggles the strum chord (selection only, onsets).
        if let cell = chordCells.first(where: { $0.rect.contains(spt) }) {
            engine.toggleChordSelection(
                ChordSelection(degree: cell.degreeIndex,
                               octave: cell.octaveShift))
            return
        }
        // Notes live in the band only — the space above/below is dead.
        guard band.contains(spt) else { return }
        // Band-local coordinates from here on — the frets' space.
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        let now = CACurrentMediaTime()
        // Onset strike velocity from the TRAILING accelerometer window (the
        // impact precedes UIKit's touch delivery, so the onset never waits).
        let vel01 = motion.map { m -> Double in
            let v = m.strikeVelocity01(at: now)
            m.lastTouchVelocity = v
            return v
        }
        bindPlayer()
        guard player.begin(touchId: ev.touchId, at: pt,
                           context: playContext(placements: placements, size: band.size),
                           velocity01: vel01, radiusPt: ev.radius, time: now)
        else { return }   // no frets — nothing to play
        motion?.noteBegan(ev.touchId, at: now)   // strike-scope coloring
        // Every touch is born stopped — the indicator starts amber.
        indicators.begin(ev.touchId, point: spt, stopGate: 1,
                         radiusPt: ev.radius, at: now)
    }

    /// The player's engine, recorder and settle-tick hook (the indicators).
    private func bindPlayer() {
        player.engine = engine
        player.recorder = recorder
        let indicators = self.indicators
        player.onTick = { id, out in indicators.update(id, stopGate: out.stopGate) }
    }

    private func playContext(placements: [FretPlacement],
                             size: CGSize) -> FretTouchPlayer.Context {
        FretTouchPlayer.Context(placements: placements, size: size,
                                snapDistance: snapDistance,
                                ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                warp: fieldWarp)
    }

    /// Drag: the player glides (field pitch + onset offset + the assist's
    /// slewed correction; never a re-snap mid-drag); the indicator follows.
    private func moved(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect) {
        // A finger holding a drone button never glides.
        guard droneTouches[ev.touchId] == nil else { return }
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        guard let out = player.move(touchId: ev.touchId, at: pt,
                                    context: playContext(placements: placements, size: band.size),
                                    radiusPt: ev.radius, time: CACurrentMediaTime())
        else { return }
        indicators.update(ev.touchId, point: spt, stopGate: out.stopGate,
                          radiusPt: ev.radius)
    }
}

// MARK: - Per-touch indicator overlay

/// Live per-touch indicator state: the stop gate, the RAW FINGERTIP
/// RADIUS (`UITouch.majorRadius`) and the estimated `.touchSize` axis
/// the Mac derives from it. A class so the settle-timer closure can feed
/// it; no-op updates are skipped.
///
/// The pitch-correction readout and the accelerometer strike ripple/number
/// are deliberately NOT here any more — the toolbar's strike and
/// finger-accel scopes are the surviving readouts for those.
private final class TouchIndicatorModel: ObservableObject {
    struct Info {
        var point: CGPoint      // padded-content coords (the canvases' space)
        var stopGate: Double    // 0 = moving … 1 = stopped
        /// `UITouch.majorRadius` in points, as reported (0 = unknown).
        var radiusPt: Double = 0
        /// The `.touchSize` axis for THIS finger, 0…1 — the same mapping
        /// and finger estimator the Mac's bindings run.
        var axis: Double = 0
    }

    @Published private(set) var infos: [Int: Info] = [:]

    /// DISPLAY-ONLY instances of the shared law (the finger-accel scope
    /// pattern: the data's source side draws its own readout, no extra
    /// wire traffic). One per touch — the Mac's control axis follows the
    /// NEWEST touch, but on screen every finger shows its own value.
    private var size: [Int: TouchSizeTracker] = [:]

    /// The estimator needs regular time steps and UIKit only reports a
    /// finger that MOVES, so a ~30 Hz ticker advances every tracker while
    /// anything is down. `.common` mode so touch tracking can't starve it.
    private var ticker: Timer?

    func begin(_ id: Int, point: CGPoint, stopGate: Double,
               radiusPt: Double, at t: TimeInterval) {
        var tr = TouchSizeTracker()
        tr.sample(radiusPt: radiusPt, at: t)     // seeds the clock at 0
        size[id] = tr
        infos[id] = Info(point: point, stopGate: stopGate,
                         radiusPt: radiusPt, axis: tr.value)
        armTicker()
    }

    /// `radiusPt` nil = a settle tick (the finger has not moved, so UIKit
    /// reported no new size); the last radius stands, and the estimator
    /// reads the silence as "no crossing yet".
    func update(_ id: Int, point: CGPoint? = nil, stopGate: Double,
                radiusPt: Double? = nil) {
        guard var info = infos[id] else { return }
        let p = point ?? info.point
        let r = radiusPt ?? info.radiusPt
        // ~half-px / quarter-point thresholds: a settled hold publishes
        // nothing (the ticker publishes the ramp on its own).
        if abs(info.stopGate - stopGate) < 0.01,
           abs(info.radiusPt - r) < 0.25,
           abs(p.x - info.point.x) + abs(p.y - info.point.y) < 0.5 { return }
        info.point = p
        info.stopGate = stopGate
        info.radiusPt = r
        infos[id] = info
    }

    func end(_ id: Int) {
        size.removeValue(forKey: id)
        infos.removeValue(forKey: id)
        if infos.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func armTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] timer in
            guard let self, !self.infos.isEmpty else {
                timer.invalidate()
                self?.ticker = nil
                return
            }
            let now = CACurrentMediaTime()
            for (id, info) in self.infos {
                guard var tr = self.size[id] else { continue }
                let v = tr.sample(radiusPt: info.radiusPt, at: now)
                self.size[id] = tr
                guard abs(v - info.axis) > 0.002 else { continue }
                var i = info
                i.axis = v
                self.infos[id] = i          // publishes
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }
}

/// One ring per touch, SIZED BY THE RAW FINGERTIP RADIUS (cyan gliding →
/// amber stopped), with the radius in points printed beside it and the
/// **`.touchSize` axis drawn as an arc** just outside the ring — a full
/// circle at 1, nothing at 0 — so the estimated 0…1 value the Mac's
/// bindings actually see is visible while playing.
private struct TouchIndicatorLayerIOS: View {
    @ObservedObject var model: TouchIndicatorModel
    let edgePad: CGFloat

    /// Points → ring radius in px (a ~23 pt fingertip draws the historic
    /// 46 px ring), clamped so an unknown or extreme reading still draws.
    private func ringRadius(_ radiusPt: Double) -> CGFloat {
        CGFloat(min(max(radiusPt * 2.0, 16.0), 120.0))
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.translateBy(x: edgePad, y: edgePad)
            for info in model.infos.values {
                draw(info, in: &ctx, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ info: TouchIndicatorModel.Info,
                      in ctx: inout GraphicsContext, size: CGSize) {
        let g = info.stopGate
        // Moving = cool cyan, stopped = warm amber, blended by the gate.
        let color = Color(red: 0.25 + 0.75 * g,
                          green: 0.75 - 0.15 * g,
                          blue: 1.0 - 0.9 * g)
        let radius = ringRadius(info.radiusPt)
        let ring = Path(ellipseIn: CGRect(x: info.point.x - radius,
                                          y: info.point.y - radius,
                                          width: 2 * radius,
                                          height: 2 * radius))
        ctx.stroke(ring, with: .color(color.opacity(0.45 + 0.45 * g)),
                   lineWidth: 3)
        drawSizeArc(info, radius: radius, in: &ctx)
        drawRadiusNumber(info, radius: radius, in: &ctx, size: size)
    }

    /// The estimated `.touchSize` value as an arc outside the ring,
    /// clockwise from 12 o'clock: 0 draws nothing, 1 closes the circle.
    private func drawSizeArc(_ info: TouchIndicatorModel.Info,
                             radius: CGFloat,
                             in ctx: inout GraphicsContext) {
        let v = min(max(info.axis, 0), 1)
        guard v > 0.005 else { return }
        let r = radius + 7
        var arc = Path()
        arc.addArc(center: info.point, radius: r,
                   startAngle: .degrees(-90),
                   endAngle: .degrees(-90 + 360 * v),
                   clockwise: false)
        ctx.stroke(arc,
                   with: .color(Color(red: 0.72, green: 0.45, blue: 1.0)
                                    .opacity(0.9)),
                   style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }

    /// The raw `majorRadius` in points at the ring's right — the signal
    /// itself, so the `Config.touchSizeLoPt`…`HiPt` window can be judged
    /// by eye.
    private func drawRadiusNumber(_ info: TouchIndicatorModel.Info,
                                  radius: CGFloat,
                                  in ctx: inout GraphicsContext,
                                  size: CGSize) {
        guard info.radiusPt > 0 else { return }
        let text = Text(String(format: "%.1f", info.radiusPt))
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundColor(.white.opacity(0.92))
        let resolved = ctx.resolve(text)
        let sz = resolved.measure(in: CGSize(width: 80, height: 30))
        let rightX = info.point.x + radius + 18 + sz.width / 2
        let cx = min(rightX, size.width - 2 * edgePad - sz.width / 2 - 4)
        let cy = min(max(info.point.y, sz.height / 2 + 4),
                     size.height - 2 * edgePad - sz.height / 2 - 4)
        let box = CGRect(x: cx - sz.width / 2 - 5, y: cy - sz.height / 2 - 2,
                         width: sz.width + 10, height: sz.height + 4)
        ctx.fill(Path(roundedRect: box, cornerRadius: 5),
                 with: .color(.black.opacity(0.55)))
        ctx.draw(resolved, at: CGPoint(x: cx, y: cy))
    }
}
