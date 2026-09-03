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
                StrikeScopePane(motion: motion,
                                fadeS: scaleSync.joyConTilt.strikeWindowS)
            }
            if let fingerAccel {
                FingerAccelScopePane(history: fingerAccel, motion: motion)
            }
            // The Mac's radiated voice/taraf levels (JOYCON_STATE).
            VolumeScopePane(history: scaleSync.volumeHistory,
                            motion: motion)
            Spacer(minLength: 12)
            PadSoundingReadout(sounding: engine.sounding,
                               tonicFractionalMidi: engine.tonicFractionalMidi)
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

// MARK: - Sounding readout

/// Live Hz / note / cents readout for the active touch. Observes only
/// `SoundingState`, so per-tick updates re-render just this label.
private struct PadSoundingReadout: View {
    @ObservedObject var sounding: SoundingState
    let tonicFractionalMidi: Double

    var body: some View {
        let ratio = sounding.ratio
        let text: String = ratio.map { r in
            // octaveSemis is onset-captured, so a held note reads true.
            let fractionalMidi = tonicFractionalMidi + sounding.octaveSemis
                + 12.0 * log2(r)
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

/// The strike scope: the strike envelope (0–127 wire scale) as a scrolling
/// trace with the current value at the right; the amber tick holds the last
/// onset's reading. Polls the unpublished history at 30 Hz in a
/// `TimelineView` — never subscribes.
private struct StrikeScopePane: View {
    let motion: MotionManager
    /// The onset color fade — the Mac's `ctl_strike_window` blend window.
    let fadeS: Double

    private static let window: TimeInterval = 4.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            // Read the history HERE, not inside the Canvas closure: capturing
            // only the class ref lets SwiftUI dedupe the canvas and it freezes.
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
        // Only the envelope (the control signal the bindings see) is drawn.
        guard let lastT = env.last?.t else { return }
        let bins = max(Int(w), 1)
        let binDur = window / Double(bins)
        // Bins anchor to ABSOLUTE time (a moving origin makes the trace
        // shimmer); decimation is per-bin peak-hold, never a sample stride
        // (a stride aliases and can drop a tap spike).
        let t0 = (((lastT - window) / binDur).rounded(.down)) * binDur
        var peak = [Double](repeating: -1.0, count: bins)
        var current = 0.0
        for s in env {
            guard s.t >= t0 else { continue }
            current = s.level
            let b = min(bins - 1, max(0, Int((s.t - t0) / binDur)))
            if s.level > peak[b] { peak[b] = s.level }
        }
        // Color per bin: pale yellow at onset fading down `ScopeColor.level`
        // over `fadeS`, dark gray while nothing plays (one linear walk).
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
                colorArr[b] = ScopeColor.level(1 - f).opacity(0.95)
            } else {
                colorArr[b] = Color(white: 0.38).opacity(0.9)
            }
        }
        // Note-active backdrop, run-length filled, so phrases read as blocks.
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
        // Guide lines at thirds (≈42 / 85) — over the backdrop, under the trace.
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
        // Last onset's reading: an amber tick at its height, right edge.
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

/// The finger-accel scope: the finger's pitch acceleration on the
/// `.fingerAccel` −1…+1 scale (centerline = rest or constant-rate meend),
/// from the iPad's own `FingerAccelSampler` instance of the shared law. Same
/// rendering discipline as the strike scope.
private struct FingerAccelScopePane: View {
    let history: FingerAccelSampler
    let motion: MotionManager?

    private static let window: TimeInterval = 4.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let env = history.history()
            let activity = motion?.noteActivity ?? []
            Canvas { ctx, size in
                Self.draw(ctx, size: size, env: env, activity: activity)
            }
            .frame(width: 150, height: 36)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15)))
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             env: [(t: TimeInterval, v: Double)],
                             activity: [(t: TimeInterval, active: Int)]) {
        let w = size.width, h = size.height
        guard let lastT = env.last?.t else { return }
        let bins = max(Int(w), 1)
        let binDur = window / Double(bins)
        // Absolute-time bins + per-bin signed peak-hold (max |v| keeps its
        // sign) so brief bursts survive decimation.
        let t0 = (((lastT - window) / binDur).rounded(.down)) * binDur
        var peak = [Double](repeating: .nan, count: bins)
        var current = 0.0
        for s in env {
            guard s.t >= t0 else { continue }
            current = s.v
            let b = min(bins - 1, max(0, Int((s.t - t0) / binDur)))
            if peak[b].isNaN || abs(s.v) > abs(peak[b]) { peak[b] = s.v }
        }
        // Note-active backdrop, run-length filled.
        var ai = -1
        var soundingArr = [Bool](repeating: false, count: bins)
        for b in 0..<bins {
            let binT = t0 + (Double(b) + 0.5) * binDur
            while ai + 1 < activity.count, activity[ai + 1].t <= binT {
                ai += 1
            }
            soundingArr[b] = ai >= 0 && activity[ai].active > 0
        }
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
        // Centerline (rest) bright-ish, ±0.5 guides faint.
        for (f, op) in [(0.5, 0.25), (0.25, 0.12), (0.75, 0.12)] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: h * CGFloat(f)))
            p.addLine(to: CGPoint(x: w, y: h * CGFloat(f)))
            ctx.stroke(p, with: .color(.white.opacity(op)), lineWidth: 0.5)
        }
        // The trace: −1…+1 → bottom…top, colored by playing state.
        func yFor(_ v: Double) -> CGFloat {
            h / 2 - CGFloat(v) * (h / 2 - 1)
        }
        var prevPt: CGPoint? = nil
        for b in 0..<bins where !peak[b].isNaN {
            let pt = CGPoint(x: (CGFloat(b) + 0.5) / CGFloat(bins) * w,
                             y: yFor(peak[b]))
            if let pp = prevPt {
                var seg = Path()
                seg.move(to: pp)
                seg.addLine(to: pt)
                let c: Color = soundingArr[b]
                    ? Color(red: 0.55, green: 1.0, blue: 0.55).opacity(0.95)
                    : Color(white: 0.38).opacity(0.9)
                ctx.stroke(seg, with: .color(c), lineWidth: 1.5)
            }
            prevPt = pt
        }
        // Live value on the wire-style ±127 scale, signed.
        let label = Text("\(Int((current * 127).rounded()))")
            .font(.padSmall(10).monospacedDigit())
            .foregroundColor(.white.opacity(0.9))
        let resolved = ctx.resolve(label)
        let sz = resolved.measure(in: CGSize(width: 44, height: 16))
        ctx.draw(resolved, at: CGPoint(x: w - sz.width / 2 - 3,
                                       y: sz.height / 2 + 1))
    }
}

/// The volume scope: the Mac's radiated voice and taraf levels on the wire's
/// 0…1 log scale (−60…0 dBFS, `TLPVolume`; guides = 20 dB) with the current
/// dB at the right. Samples are unsmoothed RMS, change-gated on the wire, so
/// bins peak-hold and forward-fill. Voice orange, taraf cyan while a note
/// sounds. Polls `ScaleSyncReceiver.volumeHistory` at 30 Hz in a `TimelineView`.
private struct VolumeScopePane: View {
    let history: VolumeHistory
    /// The surface's note timeline (same clock as the samples); nil = none.
    let motion: MotionManager?

    private static let window: TimeInterval = 4.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let samples = history.snapshot()
            let activity = motion?.noteActivity ?? []
            Canvas { ctx, size in
                Self.draw(ctx, size: size, samples: samples,
                          activity: activity)
            }
            .frame(width: 120, height: 36)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15)))
        }
    }

    private static let voiceColor = Color.orange
    private static let tarafColor = Color.cyan
    private static let voiceIdle = Color(white: 0.55).opacity(0.9)
    private static let tarafIdle = Color(white: 0.35).opacity(0.9)

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             samples: [VolumeHistory.Sample],
                             activity: [(t: TimeInterval, active: Int)]) {
        let w = size.width, h = size.height
        guard !samples.isEmpty else { return }
        // The trace scrolls with NOW, not the last (sparse) sample.
        let now = ProcessInfo.processInfo.systemUptime
        let bins = max(Int(w), 1)
        let binDur = window / Double(bins)
        // Absolute-time bins with peak-hold; empty bins forward-fill.
        let t0 = (((now - window) / binDur).rounded(.down)) * binDur
        var voicePk = [Double](repeating: -1.0, count: bins)
        var tarafPk = [Double](repeating: -1.0, count: bins)
        var seedV = 0.0, seedT = 0.0
        for s in samples {
            guard s.t >= t0 else { seedV = s.voice; seedT = s.taraf; continue }
            let b = min(bins - 1, max(0, Int((s.t - t0) / binDur)))
            if s.voice > voicePk[b] { voicePk[b] = s.voice }
            if s.taraf > tarafPk[b] { tarafPk[b] = s.taraf }
        }
        var vFill = seedV, tFill = seedT
        for b in 0..<bins {
            if voicePk[b] < 0 { voicePk[b] = vFill } else { vFill = voicePk[b] }
            if tarafPk[b] < 0 { tarafPk[b] = tFill } else { tFill = tarafPk[b] }
        }
        // Per-bin note activity (the timeline is ordered).
        var ai = -1
        var soundingArr = [Bool](repeating: false, count: bins)
        for b in 0..<bins {
            let binT = t0 + (Double(b) + 0.5) * binDur
            while ai + 1 < activity.count, activity[ai + 1].t <= binT {
                ai += 1
            }
            soundingArr[b] = ai >= 0 && activity[ai].active > 0
        }
        // Note-active backdrop, run-length filled.
        var run = 0
        while run < bins {
            guard soundingArr[run] else { run += 1; continue }
            var e = run
            while e + 1 < bins, soundingArr[e + 1] { e += 1 }
            let x0 = CGFloat(run) / CGFloat(bins) * w
            let x1 = CGFloat(e + 1) / CGFloat(bins) * w
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: h)),
                     with: .color(.white.opacity(0.12)))
            run = e + 1
        }
        // Guide lines at thirds (20 dB steps).
        for f in [1.0 / 3.0, 2.0 / 3.0] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: h * CGFloat(1 - f)))
            p.addLine(to: CGPoint(x: w, y: h * CGFloat(1 - f)))
            ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
        // Traces: colored while a note sounds, gray otherwise. Taraf under.
        func stroke(_ values: [Double], active: Color, idle: Color) {
            var prevPt: CGPoint? = nil
            for b in 0..<bins {
                let pt = CGPoint(x: (CGFloat(b) + 0.5) / CGFloat(bins) * w,
                                 y: h - CGFloat(values[b]) * (h - 2) - 1)
                if let pp = prevPt {
                    var seg = Path()
                    seg.move(to: pp)
                    seg.addLine(to: pt)
                    ctx.stroke(seg,
                               with: .color(soundingArr[b] ? active : idle),
                               lineWidth: 1.5)
                }
                prevPt = pt
            }
        }
        stroke(tarafPk, active: tarafColor, idle: tarafIdle)
        stroke(voicePk, active: voiceColor, idle: voiceIdle)
        // Current dB values, voice above taraf; silence prints nothing.
        func label(_ v01: Double, _ color: Color, y: CGFloat) {
            guard v01 > 0 else { return }
            let db = Int(((v01 - 1.0) * 60.0).rounded())
            let text = Text("\(db)")
                .font(.padSmall(9).monospacedDigit())
                .foregroundColor(color.opacity(0.95))
            let resolved = ctx.resolve(text)
            let sz = resolved.measure(in: CGSize(width: 40, height: 14))
            ctx.draw(resolved, at: CGPoint(x: w - sz.width / 2 - 3, y: y))
        }
        label(voicePk[bins - 1], voiceColor, y: 7)
        label(tarafPk[bins - 1], tarafColor, y: h - 7)
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

        // Age-faded trail: drift reads as a snake, noise as a fuzz ball.
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

/// The chord bar below the band: one derived triad per fret column
/// (`chordBarCells`, shared with the Mac). Highlight = THIS pad's own
/// selection, asserted in its outbound frame. Display only; taps are
/// hit-tested in the surface's UIKit touch handler.
private struct ChordBarVisualIOS: View {
    let cells: [ChordBarCell]
    let active: ChordSelection?
    let edgePad: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cells) { c in
                // Octave-agnostic: every octave's cell of the degree lights.
                let sel = active?.degree == c.degreeIndex
                let hue = pitchColor(forRatio: c.rootRatio, lightness: 0.78,
                                     chroma: 0.16)
                RoundedRectangle(cornerRadius: 6)
                    .fill(sel ? hue.opacity(0.55) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(hue.opacity(sel ? 0.95 : 0.4),
                                    lineWidth: sel ? 1.5 : 1)
                    )
                    .overlay(
                        Text(c.numeral)
                            .font(.padSmall(14, weight: .semibold))
                            .foregroundColor(.white.opacity(sel ? 1.0 : 0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    )
                    .frame(width: c.rect.width, height: c.rect.height)
                    .offset(x: edgePad + c.rect.minX, y: edgePad + c.rect.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Drone buttons (the shared `droneButtonRects`), display only — presses are
/// hit-tested in the surface's UIKit touch handler, never via SwiftUI
/// gestures, so they can't interfere with melody multitouch.
private struct DroneButtonsVisualIOS: View {
    let ratios: [Double]
    /// The synced scale's degrees — buttons are named by the scale
    /// (`scaleLabel(forRatio:)`).
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
    @State private var touchInfos: [TouchInfo] = []
    /// Per-touch log2 offset captured at a snapped onset (0 if unsnapped).
    @State private var snapOffsets: [Int: Double] = [:]
    /// Drag assist; the timer drives the settle while fingers rest.
    @State private var assist = FretDragAssist()
    @State private var assistTimer: Timer? = nil
    /// Touches holding a drone button (touchId → button index).
    @State private var droneTouches: [Int: Int] = [:]
    /// Per-touch indicator — a class so the settle timer can feed it.
    @StateObject private var indicators = TouchIndicatorModel()

    private let edgePad: CGFloat = 12
    /// Onset-snap half-width in px — the synced `marginPixels`. 0 = fretless.
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // The playable band — the frets' coordinate space.
            let band = fretPadBandRect(in: size)
            let degrees = scaleDegrees(from: engine.scale)
            let placements = fretPlacements(arrangement: arrangement,
                                            degrees: degrees, size: band.size)
            let chordCells = chordBarCells(arrangement: arrangement,
                                           degrees: degrees,
                                           chords: scaleChords(degrees: degrees),
                                           size: size)

            ZStack(alignment: .topLeading) {
                Color.black

                // Always perform mode: fret lines only, ghosts like base frets.
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

                // Per-touch indicator: stop-detector ring + pitch readouts.
                TouchIndicatorLayerIOS(model: indicators, degrees: degrees,
                                       edgePad: edgePad)

                // The chord bar (display only; taps hit-tested in `began`).
                ChordBarVisualIOS(cells: chordCells,
                                  active: engine.chordSelection,
                                  edgePad: edgePad)

                // Drone buttons (display only; hidden with a Joy-Con attached).
                if !dronesHidden {
                    DroneButtonsVisualIOS(ratios: arrangement.droneRatios,
                                          degrees: degrees,
                                          held: Set(droneTouches.values),
                                          size: size, edgePad: edgePad)
                }

                TouchOverlayView(
                    touches: $touchInfos,
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
                        snapOffsets.removeValue(forKey: id)
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
        guard let fieldLog = fretFieldLog(at: pt, placements: placements,
                                          warp: fieldWarp)
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
        // Onset strike velocity from the TRAILING accelerometer window (the
        // impact precedes UIKit's touch delivery, so the onset never waits).
        let vel01 = motion.map { m -> Double in
            let v = m.strikeVelocity01(at: now)
            m.lastTouchVelocity = v
            return v
        }
        engine.noteOn(touchId: ev.touchId, ratio: pow(2.0, onsetLog),
                      weights: weights,
                      velocity01: vel01)
        motion?.noteBegan(ev.touchId, at: now)   // strike-scope coloring

        assist.setContext(placements: placements, snapDistance: snapDistance)
        assist.begin(touchId: ev.touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: fieldLog + offset, time: now)
        // Every touch is born stopped — the indicator starts amber.
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
            assistParams: ["fieldWarp": fieldWarp,
                           "speedFloor": assist.speedFloor,
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

    /// Drag: the field pitch plus this touch's onset offset, then the drag
    /// assist's slewed correction. Never re-snaps mid-drag.
    private func moved(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect) {
        // A finger holding a drone button never glides.
        guard droneTouches[ev.touchId] == nil else { return }
        // Only touches that began in the band play; a drag may wander out.
        guard let offset = snapOffsets[ev.touchId] else { return }
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        guard let fieldLog = fretFieldLog(at: pt, placements: placements,
                                          warp: fieldWarp)
        else { return }
        assist.setContext(placements: placements, snapDistance: snapDistance)
        let now = CACurrentMediaTime()
        let out = assist.move(touchId: ev.touchId, x: pt.x, y: pt.y,
                              uncorrectedLog: fieldLog + offset, time: now)
        engine.glide(touchId: ev.touchId, ratio: pow(2.0, out.log2Pitch),
                     weights: out.weights)
        indicators.update(ev.touchId, point: spt, stopGate: out.stopGate,
                          playedLog: out.log2Pitch, rawLog: fieldLog)
        recorder.sample(touchId: ev.touchId, x: pt.x, y: pt.y,
                        u: fieldLog + offset, o: out.log2Pitch, time: now)
    }

    /// 60 Hz settle loop while any touch is down. Captures only the class
    /// objects (never the view struct).
    private func startAssistTimerIfNeeded() {
        // The timer self-invalidates when idle (it can't nil this @State).
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

/// Live per-touch indicator state (stop gate, raw and sounding pitch). A
/// class so the settle-timer closure can feed it; no-op updates are skipped.
private final class TouchIndicatorModel: ObservableObject {
    struct Info {
        var point: CGPoint      // padded-content coords (the canvases' space)
        var stopGate: Double    // 0 = moving … 1 = stopped
        var rawLog: Double      // field pitch under the finger (no snap/assist)
        var playedLog: Double   // the pitch actually sounding
        // The strike estimate 0…1 captured at onset; `hasStrike` false draws
        // nothing. Drawn as a ripple plus a 0–127 readout beside the ring.
        var hasStrike = false
        var strikeVel = 0.0
        var bornAt: TimeInterval = 0   // CACurrentMediaTime at onset
        // Set on release: the info survives as a fading GHOST number.
        var endedAt: TimeInterval? = nil
    }

    @Published private(set) var infos: [Int: Info] = [:]

    /// How long the onset strike ripple lives.
    static let strikeFlashDuration: TimeInterval = 0.5
    /// How long the velocity number lingers after release (the ghost).
    static let strikeGhostDuration: TimeInterval = 1.0
    /// Redraw driver: the canvas only invalidates on a publish and a staccato
    /// touch may never move, so a ~15 Hz ticker publishes while a flash
    /// decays. `.common` mode so touch tracking doesn't starve it.
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
            // Prune expired ghosts (the mutation publishes).
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
        // A strike-carrying touch leaves its number as a fading ghost;
        // everything else clears immediately.
        if var info = infos[id], info.hasStrike {
            info.endedAt = CACurrentMediaTime()
            infos[id] = info
            armFlashTicker(for: Self.strikeGhostDuration)
        } else {
            infos.removeValue(forKey: id)
        }
    }
}

/// One ring per touch (cyan gliding → amber stopped), an "original →
/// corrected" readout when the sounding pitch differs from the raw field
/// pitch, and an onset ripple sized by the strike estimate.
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
        // Ghost (released strike touch): only the number remains, fading.
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
        // Onset strike ripple: expands and fades over ~0.5 s; reach,
        // brightness and weight scale with the estimate.
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
            // The number itself, beside the ring for the note's life.
            drawStrikeNumber(info, alpha: 1.0, in: &ctx, size: size)
        }
        let ring = Path(ellipseIn: CGRect(x: info.point.x - radius,
                                          y: info.point.y - radius,
                                          width: 2 * radius,
                                          height: 2 * radius))
        ctx.stroke(ring, with: .color(color.opacity(0.45 + 0.45 * g)),
                   lineWidth: 3)

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

    /// The strike estimate on the 0–127 scale at the ring's right; `alpha`
    /// fades the released ghost.
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

    /// A pitch in the scale's vocabulary: the nearest degree's label (any
    /// octave, `'`/`,` marks) plus signed cents when meaningfully off it.
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

