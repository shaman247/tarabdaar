import CoreAudioKit
import QuartzCore
import TarabdaarCore
import SwiftUI
import simd

/// The iPad's playing surface is the Fret Pad (`FretPadViewIOS`, below). Touch
/// position resolves to a pitch via `FretPadGeometry`; `PitchPadEngine` pins a
/// MIDI note and bends, while a 60 Hz loop streams the RAW tilt report
/// (`TiltAxisWire` CCs 16/17/18) — the iPad knows nothing about what the
/// tilts mean; the Mac evaluates its own bindings. Scale + fret editing
/// live on TarabdaarMac and sync here over USB-MIDI SysEx (the iPad is
/// perform-only). The MAP dimension-matrix editor was deleted 2026-07-24
/// along with the iPad's parameter mapping.

// MARK: - Shared pad toolbar (iPad)

/// The common iPad pad toolbar — PANIC, an optional REC toggle, the
/// scale-sync indicator, live tilt meters, the sounding readout, and the
/// (read-only) synced tonic. Shared by the playing surface.
struct PadToolbarIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    /// The shared MIDI engine — drives the USB/Bluetooth transport indicators.
    @ObservedObject var midi: MIDIEngine
    /// When set (Fret Pad), a REC toggle records play strokes for offline
    /// assist fitting (see `FretGestureRecorder`).
    var recorder: FretGestureRecorder? = nil
    /// When set, the persistent STRIKE SCOPE draws beside the tilt panes —
    /// the live accelerometer magnitude on the strike law's 0–127 scale.
    var motion: MotionManager? = nil
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
            // Three tilt squares — the ARM tilts (Mac-calibrated when a
            // calibration is driving, the iPad's own raw attitude
            // otherwise), the WRIST attitude (the Joy-Con's fused
            // pitch/roll/yaw), and the Joy-Con stick. Every axis has one
            // owner, so nothing grays — a square just dims while its
            // source is idle.
            ArmTiltPane(localTilts: noteManager.currentTilt,
                        display: scaleSync.joyConTilt)
            WristTiltPane(tilt: scaleSync.joyConTilt)
            JoyConTiltPane(tilt: scaleSync.joyConTilt)
            if let motion {
                // The onset fade tracks the Mac's blend window
                // (`ctl_strike_window`, relayed over JOYCON_STATE).
                StrikeScopePane(motion: motion,
                                fadeS: scaleSync.joyConTilt.strikeWindowS)
            }
            Spacer(minLength: 12)
            PadSoundingReadout(sounding: engine.sounding,
                               tonicFractionalMidi: engine.tonicFractionalMidi)
            // Tonic is set on the Mac (in Hz) and synced over, so it's
            // read-only here.
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

// MARK: - Sounding readout

/// Compact live Hz / note / cents readout for the active touch, tinted
/// in its OKLCH hue. Observes only `SoundingState`, so the per-tick ratio
/// updates re-render just this label.
private struct PadSoundingReadout: View {
    @ObservedObject var sounding: SoundingState
    let tonicFractionalMidi: Double

    var body: some View {
        let ratio = sounding.ratio
        let text: String = ratio.map { r in
            let fractionalMidi = tonicFractionalMidi + 12.0 * log2(r)
            let freq = 440.0 * pow(2.0, (fractionalMidi - 69.0) / 12.0)
            let nearest = Int(fractionalMidi.rounded())
            let cents = Int(((fractionalMidi - Double(nearest)) * 100.0).rounded())
            let hz = freq >= 1000 ? String(format: "%.0f", freq)
                                  : String(format: "%.1f", freq)
            let centsStr = cents > 0 ? "+\(cents)¢" : "\(cents)¢"
            return "\(hz) Hz (\(Scale.noteName(for: nearest)) \(centsStr))"
        } ?? ""
        let color: Color = ratio.map {
            pitchColor(forRatio: $0, lightness: 0.85, chroma: 0.18)
        } ?? .clear
        return Text(text)
            .font(.padSmall(11).monospacedDigit())
            .foregroundStyle(color)
            .frame(width: 150, alignment: .trailing)
    }
}

// MARK: - Stroke-recording toggle (Fret Pad)

/// REC button for the iPad Fret Pad: records play strokes (raw movements +
/// fret context) to the app's **Documents/FretRecordings/** folder as JSONL —
/// visible in the Files app and Finder's device browser — for fitting the
/// drag-assist parameters to real playing (`tools/fretpad_fit.py`).
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

/// USB + Bluetooth transport indicators for the toolbar. Color carries the
/// state: **green = the transport currently carrying the MIDI** (wired-first,
/// so USB wins whenever the cable is in), **white = connected but idle**,
/// **dim gray = absent**. The antenna doubles as the button that presents
/// the system BLE-MIDI peripheral sheet, so the iPad can advertise itself
/// and the Mac can connect from Audio MIDI Setup → MIDI Studio → Bluetooth.
/// The resulting session is an ordinary CoreMIDI endpoint pair —
/// `MIDIEngine` picks it up automatically and drops it the moment a cable
/// appears. The connection is per-session: iOS stops advertising when the
/// session ends, so re-advertise + reconnect after relaunch.
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

/// `CABTMIDILocalPeripheralViewController` wrapped for SwiftUI — the
/// advertise toggle lives inside; swipe down to dismiss the sheet.
private struct BluetoothMIDIPeripheralSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDILocalPeripheralViewController())
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

// MARK: - Scale-sync indicator

/// Mac→iPad scale-sync status: a green dot once the Mac has pushed a scale,
/// gray until then.
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

/// Dot color for a 3-axis square: the third axis (−1…+1) sweeps
/// purple → cyan → orange as it goes −1 → 0 → +1 (cyan at neutral).
private func thirdAxisColor(_ v: Double) -> Color {
    Color(hue: 0.5 - v * 0.35, saturation: 0.9, brightness: 1.0)
}

/// The ARM tilts — tilt 1 on x, tilt 2 on y (up = positive), tilt 3 as
/// the dot color. While the Mac's arm-calibration solve is driving
/// (`armLive`, round-tripped in `JOYCON_STATE`), the square shows the
/// CALIBRATED axes — sweeping a calibrated range moves the dot edge to
/// edge, matching what the tilt bindings actually receive. Without a
/// calibration (or with the link down) it falls back, dimmed, to the
/// iPad's own raw attitude (`NoteManager.currentTilt`, ±90° full scale)
/// — which is then exactly what the Mac applies uncentered.
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

/// The WRIST attitude — the Joy-Con's fused pitch (x) / roll (y) / yaw
/// (dot color), relayed from the Mac's 9-axis fusion (Joy-Con 2 only).
/// Bright while the fusion streams; parked grey otherwise.
private struct WristTiltPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        TiltSquare(x: tilt.wrist1, y: tilt.wrist2,
                   dotColor: tilt.bodyLive ? thirdAxisColor(tilt.wrist3)
                                           : .gray,
                   lit: tilt.bodyLive)
    }
}

/// The Mac's Joy-Con stick axes (Stick X/Y). Fed by the `JOYCON_STATE`
/// relay (`ScaleSyncReceiver.joyConTilt`), values already 0…1. Bright
/// while deflected.
private struct JoyConTiltPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        TiltSquare(x: tilt.stickX, y: tilt.stickY,
                   dotColor: tilt.stickLive ? .green : .gray,
                   lit: tilt.stickLive)
    }
}

/// Shared 36 pt crosshair square for the tilt panes (values −1…+1,
/// centre = 0, y up).
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

/// PERSISTENT STRIKE SCOPE (2026-08-23): the live accelerometer magnitude
/// run through the SAME log law as the onset strike estimate
/// (`MotionSource.strikeScale01` — velocityMinG…MaxG → the 0–127 wire
/// scale), drawn as a scrolling trace of the last few seconds with the
/// current value printed at the right. Lets the player watch the whole
/// gesture — taps, sustained shakes, aftertouch-style pressure wobble —
/// on exactly the scale their strike numbers speak; the small amber tick
/// on the right edge holds the LAST ONSET's reading
/// (`lastTouchVelocity`), so tap and trace can be compared directly.
/// Polls the non-published 200 Hz `accelHistory3D` at 30 Hz inside a
/// `TimelineView` (the raw-overlay pattern) — it never subscribes, so
/// motion samples don't re-render the toolbar.
private struct StrikeScopePane: View {
    let motion: MotionManager
    /// The white→cyan onset fade duration — the Mac's `ctl_strike_window`
    /// blend window, so the color transition on the trace shows exactly
    /// when a note's Strike bindings have handed over to Acceleration.
    let fadeS: Double

    private static let window: TimeInterval = 4.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            // Read the history HERE, in the timeline content, not inside
            // the Canvas closure: the closure must capture fresh DATA each
            // tick. Capturing only `motion` (an unchanging class ref) lets
            // SwiftUI dedupe the "identical" canvas and stop redrawing —
            // the pane froze after its first frames (2026-08-23 fix; the
            // raw-motion overlay established the pattern).
            let env = motion.strikeHistory
            let strike = motion.lastTouchVelocity
            let activity = motion.noteActivity
            let onsets = motion.noteOnsets
            let fade = max(fadeS, 0.05)
            Canvas { ctx, size in
                Self.draw(ctx, size: size, env: env,
                          lastStrike: strike,
                          activity: activity, onsets: onsets, fadeS: fade)
            }
            .frame(width: 150, height: 36)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15)))
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             env: [(t: TimeInterval, level: Double)],
                             lastStrike: Double,
                             activity: [(t: TimeInterval, active: Int)],
                             onsets: [TimeInterval],
                             fadeS: Double) {
        let w = size.width, h = size.height
        // THE TRACE IS THE ENVELOPE (2026-08-23, evening): only the
        // smoothed control signal the `.strike`/`.acceleration`
        // dimensions actually consume is drawn — the raw magnitude trace
        // was retired (its rectified zero-crossings + the log-floor
        // magnification made smooth playing read as spikes; the envelope
        // IS the truth the bindings see).
        guard let lastT = env.last?.t else { return }
        let bins = max(Int(w), 1)
        let binDur = window / Double(bins)
        // TIME-QUANTIZED BINS (2026-08-23): anchor the bucket grid to
        // ABSOLUTE time, not to the moving `lastT − window` origin — the
        // moving origin re-bucketed the same samples differently on every
        // redraw and the whole trace shimmered ("jiggled") at the poll
        // rate. On the quantized grid a sample stays in one bucket for
        // its lifetime and the trace scrolls by whole bins instead of
        // re-rasterizing. Decimation is per-bin PEAK-HOLD, never a
        // sample stride (stride-2 on the 200 Hz stream aliased ~100 Hz
        // content into two flip-flopping phase states, and a between-
        // samples tap spike could vanish).
        let t0 = (((lastT - window) / binDur).rounded(.down)) * binDur
        var peak = [Double](repeating: -1.0, count: bins)
        var current = 0.0
        for s in env {
            guard s.t >= t0 else { continue }
            current = s.level
            let b = min(bins - 1, max(0, Int((s.t - t0) / binDur)))
            if s.level > peak[b] { peak[b] = s.level }
        }
        // PLAYING-STATE COLOR (2026-08-23): each bin is colored by what
        // the player was doing AT THAT TIME — bright white at a note
        // onset fading to cyan over the BLEND WINDOW (`fadeS` — the
        // Mac's ctl_strike_window, so the color reaching full cyan means
        // the note's Strike bindings have fully handed over to
        // Acceleration), DARK gray while nothing plays. The
        // activity/onset timelines come from the surface's note
        // begin/end reports (`MotionManager.noteBegan/noteEnded`); both
        // are time-ordered, so one linear walk serves all bins.
        var ai = -1        // last activity event with t <= binT
        var oi = -1        // last onset with t <= binT
        var soundingArr = [Bool](repeating: false, count: bins)
        var colorArr = [Color](repeating: .clear, count: bins)
        for b in 0..<bins {
            let binT = t0 + (Double(b) + 0.5) * binDur
            while ai + 1 < activity.count, activity[ai + 1].t <= binT {
                ai += 1
            }
            while oi + 1 < onsets.count, onsets[oi + 1] <= binT { oi += 1 }
            let sounding = ai >= 0 && activity[ai].active > 0
            soundingArr[b] = sounding
            if sounding {
                let age = oi >= 0 ? binT - onsets[oi] : fadeS
                let f = min(max(age / fadeS, 0.0), 1.0)
                colorArr[b] = Color(red: 1 - f, green: 1, blue: 1)
                    .opacity(0.95)
            } else {
                colorArr[b] = Color(white: 0.38).opacity(0.9)
            }
        }
        // NOTE-ACTIVE BACKGROUND (2026-08-23): the frames where a note
        // sounded get a lighter backdrop — run-length filled under the
        // trace, so phrases read as blocks at a glance (and the
        // dark-gray idle trace stays legible against the darker rest).
        var b = 0
        while b < bins {
            guard soundingArr[b] else { b += 1; continue }
            var e = b
            while e + 1 < bins, soundingArr[e + 1] { e += 1 }
            let x0 = CGFloat(b) / CGFloat(bins) * w
            let x1 = CGFloat(e + 1) / CGFloat(bins) * w
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: h)),
                     with: .color(.white.opacity(0.12)))
            b = e + 1
        }
        // Guide lines at thirds of the scale (≈42 / 85) — over the
        // backdrop stripes (same opacity; under them they'd vanish
        // inside phrases), under the trace.
        for f in [1.0 / 3.0, 2.0 / 3.0] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: h * CGFloat(1 - f)))
            p.addLine(to: CGPoint(x: w, y: h * CGFloat(1 - f)))
            ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
        // The envelope, stroked per-pair with the newer bin's color.
        var prevPt: CGPoint? = nil
        for b in 0..<bins where peak[b] >= 0 {
            let pt = CGPoint(x: (CGFloat(b) + 0.5) / CGFloat(bins) * w,
                             y: h - CGFloat(peak[b]) * (h - 2) - 1)
            if let pp = prevPt {
                var seg = Path()
                seg.move(to: pp)
                seg.addLine(to: pt)
                ctx.stroke(seg, with: .color(colorArr[b]), lineWidth: 1.5)
            }
            prevPt = pt
        }
        // Last onset's reading: an amber tick at its height, right edge —
        // the same number the touch indicator printed.
        if lastStrike > 0 {
            var tick = Path()
            let y = h - CGFloat(lastStrike) * (h - 2) - 1
            tick.move(to: CGPoint(x: w - 7, y: y))
            tick.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(tick, with: .color(.orange), lineWidth: 2)
        }
        // Live value, wire scale.
        let label = Text("\(Int((current * 127).rounded()))")
            .font(.padSmall(10).monospacedDigit())
            .foregroundColor(.white.opacity(0.9))
        let resolved = ctx.resolve(label)
        let sz = resolved.measure(in: CGSize(width: 40, height: 16))
        ctx.draw(resolved, at: CGPoint(x: w - sz.width / 2 - 3,
                                       y: sz.height / 2 + 1))
    }
}

// MARK: - Fret Pad (iPad)

/// The iPad Fret Pad — the free-fret surface, the iPad counterpart of the
/// Mac [Fret Pad](../../docs/fret-pad.md) tab. Shown when the Mac pushes
/// `layout == .fretPad`. The segment layout (`FretArrangement`) is its own
/// state (fret positions and snap zones aren't derivable from the scale),
/// synced as a third SysEx message and held by
/// `ScaleSyncReceiver.fretArrangement`. Perform-only — editing stays on the
/// Mac.
///
/// Playing matches the Mac: frets are freely positioned and the pitch is the
/// continuous fret **field** (`fretFieldLog` — exact on a fret, interpolated
/// between them); a touch **starting** within the synced Snap distance of a
/// fret *and* inside its vertical extent snaps to its exact pitch; starting
/// elsewhere approaches the note freely; drags glide continuously (per-touch
/// constant log-offset from a snapped onset — never re-snaps). Fully
/// multitouch: each finger keeps its own snap offset.
struct FretPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    @ObservedObject var midi: MIDIEngine
    let arrangement: FretArrangement
    /// The motion source, for the raw-motion diagnostic overlay.
    var motion: MotionManager? = nil

    /// Records play strokes to Documents/FretRecordings/ for offline fitting
    /// of the drag-assist parameters (toolbar REC toggle).
    @StateObject private var recorder = FretGestureRecorder()
    @State private var showGyro = false

    var body: some View {
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          midi: midi, recorder: recorder, motion: motion,
                          showGyro: $showGyro)
            // The drone buttons live INSIDE the surface (drawn as an
            // overlay, hit-tested in the surface's own touch handler) so
            // the surface keeps its full width — a separate side column
            // made the whole right edge dead space and swallowed touches
            // aimed at the rightmost fret.
            //
            // The surface view spans the whole area below the toolbar; the
            // playable fret band (`fretPadBandRect`) is the centered
            // half-height strip inside it, marked by a hairline border —
            // the space above/below it is dead, except the drone buttons,
            // which keep their full-surface position.
            // Drone buttons hide while a Joy-Con is attached to the Mac
            // (the controller's arrows play the drones) — the `connected`
            // bit rides the `0x05` relay, keeping both surfaces in step.
            FretPadSurfaceIOS(engine: engine, arrangement: arrangement,
                              recorder: recorder,
                              dronesHidden: scaleSync.joyConTilt.connected,
                              linger: scaleSync.linger,
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

/// On-device 3D view of RAW CoreMotion attitude — the sensor's own
/// (pitch, roll, yaw) trail over the last ~8 s, BEFORE the yaw
/// high-pass, the 14-bit quantization and the MIDI wire. Toggled by
/// the toolbar's GYRO button. Purpose: split sensor problems from
/// transmission problems — wobble that shows HERE is the sensor (or
/// CoreMotion's fusion); wobble that only shows on the Mac's Setup
/// scope is the wire or the Mac pipeline. Same turntable projection
/// as the Mac's calibration cloud; the Δ readouts are window
/// peak-to-peak per axis in degrees, directly comparable to the Mac
/// scope's Δ° labels (yaw here is the RAW drifting axis — the wire
/// carries its high-passed form, so yaw drift visible here and absent
/// on the Mac is EXPECTED and correct).
struct RawMotionOverlay: View {
    let motion: MotionManager

    private static let spin = 0.3
    private static let colors: [Color] = [.orange, .green, .cyan]
    private static let names = ["pitch", "roll ", "yaw  "]
    /// Fixed view scale: ±30° of attitude to the frame edge, the same
    /// constant as the Mac's "Received motion (3D)" view — the two
    /// views render motion at identical size, and the zoom no longer
    /// pumps with the trail's extent (auto-zoom also blew sub-degree
    /// noise up into a full-frame fuzz ball; at a fixed scale it reads
    /// as the near-stillness it is, with the Δ° labels carrying the
    /// magnitude). Only the scale is fixed — the view stays CENTRED on
    /// the trail mean, since the rest pose is arbitrary.
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
        guard hist.count > 2 else { return }
        let step = max(1, hist.count / 400)
        var pts: [SIMD3<Double>] = []
        for i in stride(from: 0, to: hist.count, by: step) {
            pts.append(SIMD3(hist[i].p, hist[i].r, hist[i].y))
        }
        if let last = hist.last {
            pts.append(SIMD3(last.p, last.r, last.y))
        }

        var c = SIMD3<Double>()
        for p in pts { c += p }
        c /= Double(pts.count)
        let maxR = viewRadius
        let half = Double(min(size.width, size.height)) / 2 - 12
        let s = half / maxR
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2
        let cosA = cos(azimuth)
        let sinA = sin(azimuth)
        let cosE = cos(0.5)
        let sinE = sin(0.5)

        func project(_ p: SIMD3<Double>) -> CGPoint {
            let d = p - c
            let rx = d.x * cosA - d.y * sinA
            let ry = d.x * sinA + d.y * cosA
            return CGPoint(x: cx + rx * s,
                           y: cy - (d.z * cosE - ry * sinE) * s)
        }

        // Axis lines (pitch/roll/yaw), for orientation.
        for (axis, color) in [(SIMD3<Double>(1, 0, 0), colors[0]),
                              (SIMD3<Double>(0, 1, 0), colors[1]),
                              (SIMD3<Double>(0, 0, 1), colors[2])] {
            var path = Path()
            path.move(to: project(c - axis * maxR))
            path.addLine(to: project(c + axis * maxR))
            ctx.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 0.5)
        }

        // The trail, age-faded: oldest dim, newest bright — drift reads
        // as a crawling snake, noise as a fuzz ball around one point.
        for i in 1..<pts.count {
            var seg = Path()
            seg.move(to: project(pts[i - 1]))
            seg.addLine(to: project(pts[i]))
            let age = Double(i) / Double(pts.count)
            ctx.stroke(seg, with: .color(.white.opacity(0.1 + 0.6 * age)),
                       lineWidth: 1)
        }

        // Current attitude.
        if let last = pts.last {
            let q = project(last)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.yellow))
        }
    }
}

/// The accelerometer half of the raw-motion diagnostic: RAW
/// userAcceleration (g, gravity removed) over the last ~8 s, drawn as
/// the same turntable trail as `RawMotionOverlay` beside it. The
/// centre is FIXED at the origin — acceleration has a natural zero, so
/// taps read as jabs away from the centre and back, and stillness as a
/// dot. Fixed ±0.5 g scale (the top of the strike-velocity range),
/// matching the Mac's "Received acceleration (3D)" view for the same
/// sensor-vs-transmission A/B as the attitude pair.
struct RawAccelOverlay: View {
    let motion: MotionManager

    private static let spin = 0.3
    private static let colors: [Color] = [.orange, .green, .cyan]
    private static let names = ["x", "y", "z"]
    /// Fixed view scale: ±0.5 g to the frame edge, the same constant
    /// as the Mac view.
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
        guard hist.count > 2 else { return }
        let step = max(1, hist.count / 400)
        var pts: [SIMD3<Double>] = []
        for i in stride(from: 0, to: hist.count, by: step) {
            pts.append(SIMD3(hist[i].x, hist[i].y, hist[i].z))
        }
        if let last = hist.last {
            pts.append(SIMD3(last.x, last.y, last.z))
        }

        let maxR = viewRadius
        let half = Double(min(size.width, size.height)) / 2 - 12
        let s = half / maxR
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2
        let cosA = cos(azimuth)
        let sinA = sin(azimuth)
        let cosE = cos(0.5)
        let sinE = sin(0.5)

        func project(_ p: SIMD3<Double>) -> CGPoint {
            let rx = p.x * cosA - p.y * sinA
            let ry = p.x * sinA + p.y * cosA
            return CGPoint(x: cx + rx * s,
                           y: cy - (p.z * cosE - ry * sinE) * s)
        }

        // Axis lines (x/y/z) through the origin, for orientation.
        for (axis, color) in [(SIMD3<Double>(1, 0, 0), colors[0]),
                              (SIMD3<Double>(0, 1, 0), colors[1]),
                              (SIMD3<Double>(0, 0, 1), colors[2])] {
            var path = Path()
            path.move(to: project(-axis * maxR))
            path.addLine(to: project(axis * maxR))
            ctx.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 0.5)
        }

        // Age-faded trail: strikes read as jabs from the origin.
        for i in 1..<pts.count {
            var seg = Path()
            seg.move(to: project(pts[i - 1]))
            seg.addLine(to: project(pts[i]))
            let age = Double(i) / Double(pts.count)
            ctx.stroke(seg, with: .color(.white.opacity(0.1 + 0.6 * age)),
                       lineWidth: 1)
        }

        // Current acceleration.
        if let last = pts.last {
            let q = project(last)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.yellow))
        }
    }
}

/// Visual layer for the drone buttons (rects: the shared
/// `droneButtonRects` in TarabdaarCore) (display only — presses are
/// hit-tested in the surface's UIKit touch handler, never via SwiftUI
/// gestures, so button touches and melody multitouch can't interfere).
private struct DroneButtonsVisualIOS: View {
    let ratios: [Double]
    /// The synced scale's degrees — the buttons are named from the scale
    /// like every other pitch in the app (`scaleLabel(forRatio:)`); the
    /// labels ride the scale blob, so the iPad names them the Mac's way.
    let degrees: [(ratio: Double, label: String)]
    let held: Set<Int>
    let size: CGSize
    let edgePad: CGFloat

    var body: some View {
        let rects = droneButtonRects(size: size)
        ZStack(alignment: .topLeading) {
            ForEach(rects.indices, id: \.self) { i in
                let ratio = i < ratios.count ? ratios[i] : 1.0
                let hue = pitchColor(forRatio: ratio, lightness: 0.75,
                                     chroma: 0.17)
                let r = rects[i]
                RoundedRectangle(cornerRadius: 10)
                    .fill(hue.opacity(held.contains(i) ? 0.9 : 0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(hue.opacity(0.8), lineWidth: 1)
                    )
                    .overlay(
                        Text(scaleLabel(forRatio: ratio, degrees: degrees))
                            .font(.padSmall(15, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .frame(width: r.width, height: r.height)
                    .offset(x: edgePad + r.minX, y: edgePad + r.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FretPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: FretArrangement
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureRecorder
    /// While a Joy-Con is attached to the Mac its arrows play the drones,
    /// so the on-screen buttons hide (visual + hit-test both — the same
    /// rule as the Mac surface) and their area falls through to the band /
    /// dead space.
    let dronesHidden: Bool
    /// The Mac's fret-linger display stream (LINGER_STATE): per-touch
    /// expression charge + auto-vibrato depth/ceiling, keyed by WIRE id —
    /// matched to on-screen touches via `wireIds` and drawn by the
    /// indicator overlay.
    let linger: [LingerTouchDisplay]
    /// Accelerometer source for the per-onset strike-velocity estimate
    /// (2026-08-19 — `MotionSource.strikeVelocity01`; rides the onset
    /// frame's velocity byte, consumed by the Mac's `bow_attack_vel`).
    /// nil (previews) keeps the flat legacy velocity constant.
    let motion: MotionManager?
    @State private var touchInfos: [TouchInfo] = []
    /// touchId → the outbound wire id (the LINGER_STATE key), captured at
    /// onset.
    @State private var wireIds: [Int: UInt16] = [:]
    /// touchId → the home fret's vertical extent (band px), captured at a
    /// snapped onset — the OUTWARD within-fret y (`fretY`: 0 at the end
    /// toward the band's centre-line, 1 at the outer end; `outerIsTop`
    /// from the shared `fretOuterEndIsTop`) is measured against it.
    /// Absent for unsnapped onsets (no home fret, no auto-vibrato).
    @State private var homeExtents:
        [Int: (top: CGFloat, bottom: CGFloat, outerIsTop: Bool)] = [:]
    /// Per-touch constant log2 offset captured at a snapped onset: the drag
    /// plays `2^(fieldLog + offset)`, so the snapped pitch is exact at the
    /// onset point and finger movement glides relative to it. 0 for
    /// unsnapped (approach) touches; cleared on touch end.
    @State private var snapOffsets: [Int: Double] = [:]
    /// Drag assist ("magnetic" intonation at stops/turns — see
    /// `FretDragAssist`), fully per-touch. The timer drives the settle while
    /// fingers rest (no touchesMoved events arrive then).
    @State private var assist = FretDragAssist()
    @State private var assistTimer: Timer? = nil
    /// Touches currently holding a drone button (touchId → button index).
    /// Drone presses are hit-tested HERE, in the surface's own UIKit touch
    /// handler — not via SwiftUI gestures — so the surface keeps its full
    /// width and only the 4 button rectangles are claimed; everything
    /// around/below them plays normally.
    @State private var droneTouches: [Int: Int] = [:]
    /// Per-touch feel indicator (moving/stopped ring + pitch readout) — a
    /// class so the settle-timer closure can feed it without capturing the
    /// view struct.
    @StateObject private var indicators = TouchIndicatorModel()

    private let edgePad: CGFloat = 12
    /// Horizontal onset-snap half-width in px — the synced `marginPixels`
    /// (the Mac Fret Pad's Snap slider). 0 = fretless.
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // The playable band — the frets' coordinate space. Touches
            // outside it are dead (except the drone buttons, hit-tested in
            // full-surface space).
            let band = fretPadBandRect(in: size)
            let degrees = scaleDegrees(from: engine.scale)
            let placements = fretPlacements(arrangement: arrangement,
                                            degrees: degrees, size: band.size)

            ZStack(alignment: .topLeading) {
                Color.black

                // The iPad is always in perform mode: fret lines only — no
                // octave gridlines, labels, or endpoint handles, and the
                // octave-repeat ghosts styled identically to the base frets.
                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    // Band border — the playable strip against the dead space.
                    ctx.stroke(Path(band),
                               with: .color(.white.opacity(0.12)), lineWidth: 1)
                    ctx.translateBy(x: band.minX, y: band.minY)
                    for p in placements {
                        let hue = pitchColor(forRatio: p.ratio,
                                             lightness: 0.82, chroma: 0.20)
                        // Straight over the inner dead zone, a wavy tail
                        // over the outer auto-vibrato zone (shared
                        // `fretLinePoints` — the Mac draws the same).
                        var line = Path()
                        line.addLines(fretLinePoints(x: p.x, topY: p.topY,
                                                     bottomY: p.bottomY,
                                                     bandHeight: band.height))
                        ctx.stroke(line, with: .color(hue), lineWidth: 1.5)
                    }
                }

                // Dynamic layer: live sounding glow (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: fretFillCells(placements), edgePad: edgePad)
                    .offset(x: band.minX, y: band.minY)

                // Per-touch indicator: a ring that warms as the stop
                // detector engages, plus an "original → corrected" pitch
                // readout whenever the sounding pitch differs from the raw
                // field pitch under the finger.
                TouchIndicatorLayerIOS(model: indicators, degrees: degrees,
                                       edgePad: edgePad)

                // Drone buttons (display only — presses are hit-tested in
                // `began` below): right edge, top → vertical center.
                // Hidden while a Joy-Con is attached to the Mac.
                if !dronesHidden {
                    DroneButtonsVisualIOS(ratios: arrangement.droneRatios,
                                          degrees: degrees,
                                          held: Set(droneTouches.values),
                                          size: size, edgePad: edgePad)
                }

                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in began(ev, placements: placements,
                                                size: size, band: band) },
                    onTouchMoved: { ev in moved(ev, placements: placements,
                                                size: size, band: band) },
                    onTouchEnded: { id in
                        let now = CACurrentMediaTime()
                        // Drone touch: release the button (unless another
                        // finger still holds the same one) and skip the
                        // note path entirely.
                        if let d = droneTouches.removeValue(forKey: id) {
                            if !droneTouches.values.contains(d) {
                                engine.setDrone(d, pressed: false)
                            }
                            return
                        }
                        snapOffsets.removeValue(forKey: id)
                        wireIds.removeValue(forKey: id)
                        homeExtents.removeValue(forKey: id)
                        assist.end(touchId: id)
                        indicators.end(id)
                        engine.noteOff(touchId: id)
                        motion?.noteEnded(id, at: now)   // scope coloring
                        recorder.end(touchId: id, time: now)
                        if assist.isEmpty {
                            assistTimer?.invalidate()
                            assistTimer = nil
                        }
                    }
                )
                .padding(edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: linger) { entries in
                // Feed the Mac-evaluated envelopes into the per-touch
                // indicators, matched by wire id.
                guard !wireIds.isEmpty else { return }
                var byWire: [UInt16: LingerTouchDisplay] = [:]
                for e in entries { byWire[e.id] = e }
                for (touchId, wire) in wireIds {
                    guard let e = byWire[wire] else { continue }
                    indicators.setLinger(touchId, charge: e.charge,
                                         vib: e.vib, vibCeil: e.vibCeil)
                }
            }
        }
    }

    /// Onset: snap when within the Snap distance of a fret AND inside its
    /// vertical extent, else play the fret-field pitch (the approach path).
    /// Registers the touch with the drag assist and starts its settle timer.
    private func began(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect) {
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        // Drone buttons first (full-surface coords): a touch starting inside
        // a button rect is a drone press, not a note. (Melody drags that
        // WANDER into a button keep playing — only onsets are claimed.)
        // Skipped while hidden (Joy-Con attached) so the area falls through
        // to the band / dead space like any other point.
        if !dronesHidden,
           let d = droneButtonRects(size: size).firstIndex(where: { $0.contains(spt) }) {
            let alreadyHeld = droneTouches.values.contains(d)
            droneTouches[ev.touchId] = d
            if !alreadyHeld { engine.setDrone(d, pressed: true) }
            return
        }
        // Notes live in the band only — the space above/below is dead.
        guard band.contains(spt) else { return }
        // Band-local coordinates from here on — the frets' space.
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        guard let fieldLog = fretFieldLog(at: pt, placements: placements)
        else { return }   // no frets — nothing to play
        let offset: Double
        let onsetLog: Double
        let weights: [String: Double]
        if snapDistance > 0,
           let hit = fretSnap(at: pt, placements: placements,
                              snapDistance: snapDistance) {
            offset = log2(hit.ratio) - fieldLog
            onsetLog = log2(hit.ratio)
            weights = [hit.id: 1.0]
            homeExtents[ev.touchId] = (hit.topY, hit.bottomY,
                                       fretOuterEndIsTop(topY: hit.topY,
                                                         bottomY: hit.bottomY,
                                                         bandHeight: band.height))
        } else {
            offset = 0
            onsetLog = fieldLog
            weights = [:]
            homeExtents.removeValue(forKey: ev.touchId)
        }
        snapOffsets[ev.touchId] = offset

        let now = CACurrentMediaTime()
        // ONSET STRIKE VELOCITY (2026-08-19): the accelerometer spike of
        // the finger hitting the glass, read from the TRAILING window (the
        // impact precedes UIKit's touch delivery, so the onset never
        // waits). Rides the onset frame's velocity byte; inert on the Mac
        // until `bow_attack_vel` is armed. nil (no motion source) keeps
        // the flat legacy constant.
        let vel01 = motion.map { m -> Double in
            let v = m.strikeVelocity01(at: now)
            m.lastTouchVelocity = v
            return v
        }
        engine.noteOn(touchId: ev.touchId, ratio: pow(2.0, onsetLog),
                      weights: weights,
                      y: min(max(Double(pt.y / band.height), 0), 1),
                      fretY: fretRelativeY(pt, touchId: ev.touchId),
                      velocity01: vel01)
        motion?.noteBegan(ev.touchId, at: now)   // strike-scope coloring
        wireIds[ev.touchId] = engine.wireId(forTouch: ev.touchId)

        assist.setContext(placements: placements, snapDistance: snapDistance)
        assist.begin(touchId: ev.touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: fieldLog + offset, time: now)
        // Every touch is born stopped — the indicator starts amber. The
        // strike estimate rides along as the onset ripple.
        indicators.begin(ev.touchId, point: spt, stopGate: 1,
                         rawLog: fieldLog, playedLog: onsetLog,
                         strikeVel: vel01)
        if recorder.isRecording {
            recorder.begin(touchId: ev.touchId,
                           context: strokeContext(placements: placements,
                                                  size: band.size),
                           offset: offset, x: pt.x, y: pt.y,
                           u: fieldLog + offset, o: onsetLog, time: now)
        }
        startAssistTimerIfNeeded()
    }

    /// Snapshot the geometry + live assist settings for a recorded stroke.
    private func strokeContext(placements: [FretPlacement],
                               size: CGSize) -> FretGestureRecorder.Context {
        FretGestureRecorder.Context(
            frets: placements.map {
                .init(id: $0.id, log2Ratio: log2($0.ratio), x: Double($0.x),
                      topY: Double($0.topY), bottomY: Double($0.bottomY),
                      ghost: $0.isGhost)
            },
            snapDistance: Double(snapDistance),
            ghostExtentOctaves: arrangement.ghostExtentOctaves,
            width: Double(size.width), height: Double(size.height),
            assistParams: ["speedFloor": assist.speedFloor,
                           "speedCeiling": assist.speedCeiling,
                           "speedTau": assist.speedTau,
                           "settleTau": assist.settleTau,
                           "radiusScale": assist.radiusScale,
                           "turnGain": assist.turnGain,
                           "turnTau": assist.turnTau,
                           "stillRadiusPx": assist.stillRadiusPx,
                           "stopDwellMin": assist.stopDwellMin,
                           "stopDwellRamp": assist.stopDwellRamp])
    }

    /// Drag: continuous glide — the fret-field pitch plus this touch's
    /// constant onset offset, then the drag assist's slewed correction on top
    /// (magnetic at stops/turns, transparent while gliding). Never re-snaps
    /// mid-drag; the field and assist are continuous.
    private func moved(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect) {
        // A finger holding a drone button never glides.
        guard droneTouches[ev.touchId] == nil else { return }
        // Only touches that began in the band play (they registered a snap
        // offset at onset); a drag may then wander out — the field clamps.
        guard let offset = snapOffsets[ev.touchId] else { return }
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        guard let fieldLog = fretFieldLog(at: pt, placements: placements)
        else { return }
        assist.setContext(placements: placements, snapDistance: snapDistance)
        let now = CACurrentMediaTime()
        let out = assist.move(touchId: ev.touchId, x: pt.x, y: pt.y,
                              uncorrectedLog: fieldLog + offset, time: now)
        engine.glide(touchId: ev.touchId, ratio: pow(2.0, out.log2Pitch),
                     weights: out.weights,
                     y: min(max(Double(pt.y / band.height), 0), 1),
                     fretY: fretRelativeY(pt, touchId: ev.touchId))
        indicators.update(ev.touchId, point: spt, stopGate: out.stopGate,
                          playedLog: out.log2Pitch, rawLog: fieldLog)
        recorder.sample(touchId: ev.touchId, x: pt.x, y: pt.y,
                        u: fieldLog + offset, o: out.log2Pitch, time: now)
    }

    /// The finger's OUTWARD position within its home fret's vertical
    /// extent (0 = the fret's end toward the band's centre-line, 1 = its
    /// outer end), nil when the touch's onset didn't snap to a fret.
    private func fretRelativeY(_ pt: CGPoint, touchId: Int) -> Double? {
        guard let e = homeExtents[touchId], e.bottom > e.top else { return nil }
        let t = min(max(Double((pt.y - e.top) / (e.bottom - e.top)), 0), 1)
        return e.outerIsTop ? 1 - t : t
    }

    /// 60 Hz settle loop while any touch is down (stops emit no touch
    /// events). Captures only the class objects (never the view struct); the
    /// assist reuses the context set on the last touch event.
    private func startAssistTimerIfNeeded() {
        // The timer self-invalidates when idle (it can't nil this @State),
        // so check validity, not just presence.
        guard assistTimer?.isValid != true else { return }
        let assist = self.assist
        let engine = self.engine
        let recorder = self.recorder
        let indicators = self.indicators
        assistTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                           repeats: true) { timer in
            let now = CACurrentMediaTime()
            for (id, out) in assist.tick(time: now) {
                engine.glide(touchId: id, ratio: pow(2.0, out.log2Pitch),
                             weights: out.weights)
                indicators.update(id, stopGate: out.stopGate,
                                  playedLog: out.log2Pitch)
                recorder.sampleTick(touchId: id, o: out.log2Pitch, time: now)
            }
            if assist.isEmpty { timer.invalidate() }
        }
    }
}

// MARK: - Per-touch indicator overlay

/// Live per-touch state for the indicator overlay: whether the finger is
/// moving or stopped (the assist's dwell gate), the raw field pitch under
/// the finger and the pitch actually sounding. A class (not view `@State`)
/// so the assist's settle-timer closure can feed it without capturing the
/// view struct; no-op updates are skipped so a settled hold stops
/// invalidating the layer.
private final class TouchIndicatorModel: ObservableObject {
    struct Info {
        var point: CGPoint      // padded-content coords (the canvases' space)
        var stopGate: Double    // 0 = moving … 1 = stopped
        var rawLog: Double      // field pitch under the finger (no snap/assist)
        var playedLog: Double   // the pitch actually sounding
        // Mac-evaluated fret-linger envelopes (LINGER_STATE), 0…1.
        // `hasLinger` turns the extra drawing on only once real data
        // arrives (a y-less or link-less touch keeps the plain ring).
        var hasLinger = false
        var charge = 1.0        // expression charge (1 = full)
        var vib = 0.0           // auto-vibrato depth
        var vibCeil = 0.0       // the y-set ceiling the depth grows toward
        // ONSET STRIKE ESTIMATE (2026-08-20): the accelerometer strike
        // velocity 0…1 captured at this touch's onset (the value that rode
        // the wire's velocity byte — `MotionSource.strikeVelocity01`).
        // `hasStrike` false (no motion source) draws nothing, so previews
        // and the keyboard keep the plain ring. Drawn as a decaying
        // impact ripple sized by the estimate PLUS a numeric readout
        // (MIDI-scale 0–127, the sensors.md vocabulary) beside the ring —
        // the tap's own receipt, readable for calibrating one's touch.
        var hasStrike = false
        var strikeVel = 0.0
        var bornAt: TimeInterval = 0   // CACurrentMediaTime at onset
        // Set on release for strike-carrying touches: the info survives as
        // a GHOST — just the fading velocity number — for
        // `strikeGhostDuration`, so a staccato tap's reading doesn't
        // vanish with the finger (the whole point of the number is
        // calibrating one's strike).
        var endedAt: TimeInterval? = nil
    }

    @Published private(set) var infos: [Int: Info] = [:]

    /// How long the onset strike ripple lives.
    static let strikeFlashDuration: TimeInterval = 0.5
    /// How long the velocity number lingers after release (the ghost).
    static let strikeGhostDuration: TimeInterval = 1.0
    /// Redraw pulse driver for the ripple: the canvas only invalidates on
    /// a publish, and a clean staccato touch may never move again after
    /// its onset — so a short ~15 Hz ticker publishes empty changes while
    /// any flash is still decaying, then dies. `.common` mode so touch
    /// tracking doesn't starve it.
    private var flashTimer: Timer?
    private var flashUntil: TimeInterval = 0

    func begin(_ id: Int, point: CGPoint, stopGate: Double,
               rawLog: Double, playedLog: Double,
               strikeVel: Double? = nil) {
        infos[id] = Info(point: point, stopGate: stopGate,
                         rawLog: rawLog, playedLog: playedLog,
                         hasStrike: strikeVel != nil,
                         strikeVel: min(max(strikeVel ?? 0, 0), 1),
                         bornAt: CACurrentMediaTime())
        if strikeVel != nil { armFlashTicker(for: Self.strikeFlashDuration) }
    }

    private func armFlashTicker(for duration: TimeInterval) {
        let now = CACurrentMediaTime()
        flashUntil = max(flashUntil, now + duration)
        guard flashTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = CACurrentMediaTime()
            // Prune expired ghosts (the mutation publishes; live touches
            // are untouched — their endedAt is nil).
            let expired = self.infos.filter {
                ($0.value.endedAt).map {
                    now - $0 >= Self.strikeGhostDuration
                } ?? false
            }
            if expired.isEmpty {
                self.objectWillChange.send()
            } else {
                for id in expired.keys { self.infos.removeValue(forKey: id) }
            }
            if now > self.flashUntil || self.infos.isEmpty {
                timer.invalidate()
                self.flashTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        flashTimer = t
    }

    /// Feed one touch's Mac-evaluated linger state (charge/vib/ceiling).
    /// Publish is epsilon-gated like `update` so the ~20 Hz relay only
    /// invalidates the layer when something visibly moved.
    func setLinger(_ id: Int, charge: Double, vib: Double, vibCeil: Double) {
        guard var info = infos[id], info.endedAt == nil else { return }
        if info.hasLinger,
           abs(info.charge - charge) < 0.01,
           abs(info.vib - vib) < 0.01,
           abs(info.vibCeil - vibCeil) < 0.01 { return }
        info.hasLinger = true
        info.charge = charge
        info.vib = vib
        info.vibCeil = vibCeil
        infos[id] = info
    }

    func update(_ id: Int, point: CGPoint? = nil, stopGate: Double,
                playedLog: Double, rawLog: Double? = nil) {
        guard var info = infos[id], info.endedAt == nil else { return }
        let p = point ?? info.point
        let raw = rawLog ?? info.rawLog
        // ~0.6c / half-px thresholds: a settled hold publishes nothing.
        if abs(info.stopGate - stopGate) < 0.01,
           abs(info.playedLog - playedLog) < 0.0005,
           abs(info.rawLog - raw) < 0.0005,
           abs(p.x - info.point.x) + abs(p.y - info.point.y) < 0.5 { return }
        info.point = p
        info.stopGate = stopGate
        info.rawLog = raw
        info.playedLog = playedLog
        infos[id] = info
    }

    func end(_ id: Int) {
        // A strike-carrying touch leaves its velocity number behind as a
        // fading ghost (readable after a staccato tap); everything else
        // clears immediately, the historic behavior.
        if var info = infos[id], info.hasStrike {
            info.endedAt = CACurrentMediaTime()
            infos[id] = info
            armFlashTicker(for: Self.strikeGhostDuration)
        } else {
            infos.removeValue(forKey: id)
        }
    }
}

/// One ring per touch — cool cyan while gliding, warming to amber as the
/// stop detector engages — plus an "original → corrected" readout above the
/// finger whenever the sounding pitch differs from the raw field pitch
/// (onset snap and/or magnet correction), both named in the scale's own
/// vocabulary with signed cents offsets. At onset a white impact ripple
/// expands from the ring, sized by the accelerometer strike estimate
/// (2026-08-20 — the value that rode the wire's velocity byte into
/// `bow_attack_vel`), so every tap shows the velocity it actually read.
private struct TouchIndicatorLayerIOS: View {
    @ObservedObject var model: TouchIndicatorModel
    let degrees: [(ratio: Double, label: String)]
    let edgePad: CGFloat

    var body: some View {
        Canvas { ctx, size in
            ctx.translateBy(x: edgePad, y: edgePad)
            let now = CACurrentMediaTime()
            for info in model.infos.values {
                draw(info, in: &ctx, size: size, now: now)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ info: TouchIndicatorModel.Info,
                      in ctx: inout GraphicsContext, size: CGSize,
                      now: TimeInterval) {
        // GHOST (released strike touch): only the velocity number remains,
        // fading over the ghost window — a staccato tap's reading stays on
        // screen long enough to actually read.
        if let ended = info.endedAt {
            let alpha = max(0.0, 1.0 - (now - ended)
                            / TouchIndicatorModel.strikeGhostDuration)
            drawStrikeNumber(info, alpha: alpha, in: &ctx, size: size)
            return
        }
        let g = info.stopGate
        // Moving = cool cyan, stopped = warm amber, blended by the gate.
        let color = Color(red: 0.25 + 0.75 * g,
                          green: 0.75 - 0.15 * g,
                          blue: 1.0 - 0.9 * g)
        let radius: CGFloat = 46
        // ONSET STRIKE RIPPLE (2026-08-20): the accelerometer strike
        // estimate as the tap's own receipt — an impact ring that expands
        // from the indicator and fades over ~0.5 s. Reach, brightness and
        // stroke weight all scale with the estimate: a hard tap throws a
        // bright wide wave, a gentle placement barely whispers (a faint
        // ripple at estimate 0 still confirms "estimate read: soft").
        // Redraws between finger events come from the model's flash
        // ticker.
        if info.hasStrike {
            let age = now - info.bornAt
            if age >= 0, age < TouchIndicatorModel.strikeFlashDuration {
                let t = age / TouchIndicatorModel.strikeFlashDuration
                let v = info.strikeVel
                let reach = CGFloat(10 + 40 * v) * CGFloat(t)
                let r = radius + 4 + reach
                let alpha = (1 - t) * (0.12 + 0.6 * v)
                let ripple = Path(ellipseIn: CGRect(x: info.point.x - r,
                                                    y: info.point.y - r,
                                                    width: 2 * r,
                                                    height: 2 * r))
                ctx.stroke(ripple, with: .color(.white.opacity(alpha)),
                           lineWidth: 1.5 + 3.5 * CGFloat(v) * CGFloat(1 - t))
            }
            // The number itself, beside the ring for the note's whole
            // life — the calibration readout.
            drawStrikeNumber(info, alpha: 1.0, in: &ctx, size: size)
        }
        if info.hasLinger {
            // The ONE indicator ring carries both envelopes: it is a
            // gauge for expression (the bright arc from 12 o'clock sweeps
            // the charge — full circle = full expression, shrinking as
            // the note lingers, refilling as the finger strokes the
            // fret), and it turns WAVY with the auto-vibrato — wave
            // height = the CURRENT depth, while the faint full track
            // wobbles at the CEILING amplitude, showing where the spot on
            // the fret will take the waves. A plain smooth circle = full
            // expression, no vibrato.
            ctx.stroke(wavyArc(center: info.point, radius: radius,
                               amplitude: 6 * info.vibCeil, sweep: 1.0),
                       with: .color(color.opacity(0.18)), lineWidth: 3)
            ctx.stroke(wavyArc(center: info.point, radius: radius,
                               amplitude: 6 * info.vib,
                               sweep: max(info.charge, 0.02)),
                       with: .color(color.opacity(0.45 + 0.45 * g)),
                       lineWidth: 3)
        } else {
            let ring = Path(ellipseIn: CGRect(x: info.point.x - radius,
                                              y: info.point.y - radius,
                                              width: 2 * radius,
                                              height: 2 * radius))
            ctx.stroke(ring, with: .color(color.opacity(0.45 + 0.45 * g)),
                       lineWidth: 3)
        }

        let cents = (info.playedLog - info.rawLog) * 1200
        guard abs(cents) >= 1 else { return }
        let text = Text("\(pitchName(info.rawLog)) → \(pitchName(info.playedLog))")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundColor(.white)
        let resolved = ctx.resolve(text)
        let sz = resolved.measure(in: CGSize(width: 320, height: 40))
        let above = info.point.y - radius - 26
        let cy = above > sz.height ? above : info.point.y + radius + 26
        let cx = min(max(info.point.x, sz.width / 2 + 4),
                     size.width - 2 * edgePad - sz.width / 2 - 4)
        let box = CGRect(x: cx - sz.width / 2 - 6, y: cy - sz.height / 2 - 3,
                         width: sz.width + 12, height: sz.height + 6)
        ctx.fill(Path(roundedRect: box, cornerRadius: 6),
                 with: .color(.black.opacity(0.6)))
        ctx.draw(resolved, at: CGPoint(x: cx, y: cy))
    }

    /// The strike estimate as a number — MIDI scale 0–127, the vocabulary
    /// sensors.md's typical-tap table already speaks (soft ~1–30, medium
    /// ~50–80, hard ~100–127; `bow_attack_vel` sees value/127). Sits at
    /// the ring's right, clear of the finger and of the pitch readout
    /// (which lives above/below); `alpha` fades the released ghost.
    private func drawStrikeNumber(_ info: TouchIndicatorModel.Info,
                                  alpha: Double,
                                  in ctx: inout GraphicsContext,
                                  size: CGSize) {
        guard info.hasStrike, alpha > 0.01 else { return }
        let text = Text("\(Int((info.strikeVel * 127).rounded()))")
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundColor(.white.opacity(0.92 * alpha))
        let resolved = ctx.resolve(text)
        let sz = resolved.measure(in: CGSize(width: 80, height: 30))
        let radius: CGFloat = 46
        let rightX = info.point.x + radius + 14 + sz.width / 2
        let cx = min(rightX, size.width - 2 * edgePad - sz.width / 2 - 4)
        let cy = min(max(info.point.y, sz.height / 2 + 4),
                     size.height - 2 * edgePad - sz.height / 2 - 4)
        let box = CGRect(x: cx - sz.width / 2 - 5, y: cy - sz.height / 2 - 2,
                         width: sz.width + 10, height: sz.height + 4)
        ctx.fill(Path(roundedRect: box, cornerRadius: 5),
                 with: .color(.black.opacity(0.55 * alpha)))
        ctx.draw(resolved, at: CGPoint(x: cx, y: cy))
    }

    /// A sinusoidally-modulated arc from 12 o'clock — the indicator ring's
    /// unified glyph: the radius wobbles by `amplitude` (vibrato depth)
    /// over `lobes` cycles per full turn, and `sweep` (0…1 of the circle)
    /// is the expression-charge gauge. Amplitude 0 = a clean arc; sweep 1
    /// closes into a ring. Integer lobes keep the closed ring seamless,
    /// and the track/arc pair stays phase-aligned because both start at
    /// 12 o'clock.
    private func wavyArc(center: CGPoint, radius: CGFloat,
                         amplitude: CGFloat, sweep: Double,
                         lobes: Int = 14) -> Path {
        var p = Path()
        let steps = max(8, Int(96 * sweep))
        for i in 0...steps {
            let f = Double(i) / Double(steps) * sweep
            let t = f * 2 * .pi - .pi / 2
            let r = radius + amplitude * CGFloat(sin(Double(lobes) * f * 2 * .pi))
            let pt = CGPoint(x: center.x + r * CGFloat(cos(t)),
                             y: center.y + r * CGFloat(sin(t)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        if sweep >= 1 { p.closeSubpath() }
        return p
    }

    /// A pitch in the scale's own vocabulary: the nearest degree's label
    /// (any octave, `'`/`,` marks — same rule as the frets) plus its signed
    /// cents offset when meaningfully off it.
    private func pitchName(_ log2Pitch: Double) -> String {
        guard !degrees.isEmpty else {
            return String(format: "%+.0f¢", log2Pitch * 1200)
        }
        let label = scaleLabel(forRatio: pow(2.0, log2Pitch), degrees: degrees)
        var off = Double.infinity
        for d in degrees where d.ratio > 0 {
            let dl = log2(d.ratio)
            let o = log2Pitch - dl - (log2Pitch - dl).rounded()
            if abs(o) < abs(off) { off = o }
        }
        let cents = off * 1200
        return abs(cents) < 1 ? label : label + String(format: "%+.0f¢", cents)
    }
}

