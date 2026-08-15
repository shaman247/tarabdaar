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
            // Three tilt squares — the iPad's own motion (the ARM
            // sensor), the Joy-Con stick, and the calibrated WRIST body
            // axes. Every axis has one owner now, so nothing grays —
            // the Joy-Con squares just dim while their source is idle.
            TiltBars(tilts: noteManager.currentTilt)
            JoyConTiltPane(tilt: scaleSync.joyConTilt)
            WristTiltPane(tilt: scaleSync.joyConTilt)
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

/// The three raw tilt axes (-1…+1) shown as a single X-Y square:
/// tilt 1 on x, tilt 2 on y (up = positive), and the dot's color sweeping
/// purple → cyan → orange as tilt 3 goes -1 → 0 → +1 (cyan at neutral).
/// Driven by `NoteManager.currentTilt`, which the note manager refreshes
/// from the motion source each tick.
private struct TiltBars: View {
    let tilts: [Double]

    private func tilt(_ i: Int) -> Double {
        max(-1.0, min(1.0, i < tilts.count ? tilts[i] : 0))
    }

    var body: some View {
        let t3 = tilt(2)
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.25))
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: h)
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: w, height: 1)
                Circle()
                    .fill(Color(hue: 0.5 - t3 * 0.35, saturation: 0.9,
                                brightness: 1.0))
                    .frame(width: 7, height: 7)
                    .position(x: (1 + CGFloat(tilt(0))) / 2 * w,
                              y: (1 - CGFloat(tilt(1))) / 2 * h)
            }
        }
        .frame(width: 36, height: 36)
    }
}

/// The Mac's Joy-Con stick axes (Stick X/Y), mirrored beside the iPad's
/// own tilt square. Fed by the display-only `0x05` SysEx relay
/// (`ScaleSyncReceiver.joyConTilt`), values already 0…1. Bright while
/// deflected.
private struct JoyConTiltPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        TiltSquare(x: tilt.stickX, y: tilt.stickY,
                   dotColor: tilt.stickLive ? .green : .gray,
                   lit: tilt.stickLive)
    }
}

/// The calibrated WRIST body axes (wrist ↔ on x, wrist ↕ on y) from the
/// Mac's arm+wrist solve. Bright while the body solve is driving. (The
/// ARM axes need no pane — the iPad's own square IS the arm sensor.)
private struct WristTiltPane: View {
    let tilt: JoyConTiltDisplay

    var body: some View {
        TiltSquare(x: tilt.wrist1, y: tilt.wrist2,
                   dotColor: tilt.bodyLive ? .cyan : .gray,
                   lit: tilt.bodyLive)
    }
}

/// Shared 36 pt crosshair square for the Joy-Con panes (values 0…1,
/// centre = 0.5).
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
                    .position(x: CGFloat(x) * w,
                              y: (1 - CGFloat(y)) * h)
            }
        }
        .frame(width: 36, height: 36)
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
                          midi: midi, recorder: recorder, showGyro: $showGyro)
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
                              dronesHidden: scaleSync.joyConTilt.connected)
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
    @State private var touchInfos: [TouchInfo] = []
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
                        assist.end(touchId: id)
                        engine.noteOff(touchId: id)
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
        } else {
            offset = 0
            onsetLog = fieldLog
            weights = [:]
        }
        snapOffsets[ev.touchId] = offset

        let now = CACurrentMediaTime()
        engine.noteOn(touchId: ev.touchId, ratio: pow(2.0, onsetLog),
                      weights: weights)

        assist.setContext(placements: placements, snapDistance: snapDistance)
        assist.begin(touchId: ev.touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: fieldLog + offset, time: now)
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
                           "turnTau": assist.turnTau])
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
                     weights: out.weights)
        recorder.sample(touchId: ev.touchId, x: pt.x, y: pt.y,
                        u: fieldLog + offset, o: out.log2Pitch, time: now)
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
        assistTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                           repeats: true) { timer in
            let now = CACurrentMediaTime()
            for (id, out) in assist.tick(time: now) {
                engine.glide(touchId: id, ratio: pow(2.0, out.log2Pitch),
                             weights: out.weights)
                recorder.sampleTick(touchId: id, o: out.log2Pitch, time: now)
            }
            if assist.isEmpty { timer.invalidate() }
        }
    }
}

