import TarabdaarCore
import SwiftUI
import simd

/// Game-controller monitor (Setup tab): what the paired Joy-Con is
/// actually sending — raw stick, buttons currently down, the last raw
/// element event, the alias-grouped element inventory — plus the live
/// tilt values the evaluation funnel last received (Joy-Con stick and
/// iPad report land in the same readout). Exists because controller
/// PRESENTATIONS surprise: a lone Joy-Con names its one stick both
/// "Left Thumbstick" and "Direction Pad", and this panel is where such
/// aliasing becomes visible.
struct JoyConStatusView: View {
    @ObservedObject private var joyCon: JoyConInput

    init(controller: AppController) {
        self.joyCon = controller.joyCon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GAME CONTROLLER")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            statusPanel
            if joyCon.connectedName != nil {
                inputsPanel
            }
            if joyCon.jcFusedActive {
                joyConFusedPanels
            }
            if joyCon.jcIMUActive {
                joyConIMUPanels
            }
            bodyPanel
            if joyCon.jcFusedActive || joyCon.wristCal.isCalibrated {
                wristPanel
            }
            if joyCon.traceActive {
                HStack(alignment: .top, spacing: 12) {
                    receivedPanel
                    accelPanel
                }
            }
        }
        .padding(20)
    }

    private var statusPanel: some View {
        Panel(title: "Status") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(joyCon.connectedName != nil ? Color.green : .gray)
                        .frame(width: 10, height: 10)
                    Text(joyCon.connectedName
                         ?? "No controller — pair one in System Settings ▸ Bluetooth")
                        .font(.system(.body))
                }
                // Switch 2 Joy-Cons never appear in macOS Bluetooth
                // settings — Tarabdaar's own BLE client owns them; this
                // line is its whole pairing UI.
                LabeledContent("Joy-Con 2 (BLE)") {
                    Text(joyCon.bleStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !joyCon.elementNames.isEmpty {
                    // One line per physical element, aliases joined —
                    // "Direction Pad / Left Thumbstick" is ONE element
                    // with two names.
                    Text("Elements: "
                         + joyCon.elementNames.joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var inputsPanel: some View {
        Panel(title: "Inputs") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Stick")
                    Text(String(format: "x %+.2f   y %+.2f",
                                joyCon.stickX, joyCon.stickY))
                        .font(.system(.body).monospacedDigit())
                    Text(joyCon.stickActive ? "driving tilts" : "deadzone")
                        .font(.caption)
                        .foregroundStyle(joyCon.stickActive
                                         ? Color.accentColor : .secondary)
                }
                // Two rows: dpad + the shoulder family, then the misc
                // inputs (stick click, Minus, Capture).
                VStack(alignment: .leading, spacing: 4) {
                    controlChips(Array(JoyConInput.Control.allCases.prefix(8)))
                    controlChips(Array(JoyConInput.Control.allCases.dropFirst(8)))
                }
                LabeledContent("Last event") {
                    Text(joyCon.lastEvent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                // Raw HID side-channel: L/ZL come from here (the GC
                // profile omits them); the axes are shown so their
                // frame/signs can be verified against real motion.
                LabeledContent("Raw HID (\(joyCon.hidStatus))") {
                    Text(joyCon.hidReportHex)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !joyCon.bleIMU.isEmpty {
                    // Joy-Con 2 motion (≈g / ≈°/s, classic scale
                    // constants pending measurement).
                    LabeledContent("IMU") {
                        Text(String(format:
                            "a %+.2f %+.2f %+.2f g   ω %+5.0f %+5.0f %+5.0f °/s",
                            joyCon.bleIMU[0], joyCon.bleIMU[1], joyCon.bleIMU[2],
                            joyCon.bleIMU[3], joyCon.bleIMU[4], joyCon.bleIMU[5]))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !joyCon.fusedAttitude.isEmpty {
                    // Complementary-filter output — judge jitter here,
                    // not on the raw trails (the iPad's apparent
                    // steadiness is CoreMotion's fused attitude, not
                    // quieter sensors). Yaw is mag-pinned once the
                    // hard-iron estimate is earned: figure-eight the
                    // Joy-Con until the label flips to 9-axis.
                    LabeledContent("Fused") {
                        Text(String(format:
                            "pitch %+6.1f°  roll %+6.1f°  yaw %+7.1f°  ·  %@",
                            joyCon.fusedAttitude[0], joyCon.fusedAttitude[1],
                            joyCon.fusedAttitude[2],
                            joyCon.yawPinned
                                ? "9-axis (mag-pinned yaw)"
                                : "6-axis (yaw drifts — figure-eight to calibrate the mag)"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !joyCon.wristCal.axes.isEmpty || joyCon.jcFusedActive {
                    // The wrist control axes (calibrated) + the
                    // acceleration envelope — what the bindings see.
                    LabeledContent("Wrist axes") {
                        Text(joyCon.wristCal.axes.isEmpty
                             ? "uncalibrated — see Wrist calibration below"
                             : joyCon.wristCal.axes
                                .map { String(format: "%+.2f", $0) }
                                .joined(separator: "  ")
                               + String(format: "   accel %.2f",
                                        joyCon.joyConAccelLevel))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !joyCon.hidAxes.isEmpty || joyCon.calPhase != .idle {
                    LabeledContent("HID axes") {
                        Text(joyCon.hidAxes
                            .map { String(format: "%+.2f", $0) }
                            .joined(separator: "  "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    // Stick calibration: rest + per-direction endpoints
                    // (asymmetric on real hardware) → tilts 0.5 / 0 / 1.
                    HStack(spacing: 10) {
                        switch joyCon.calPhase {
                        case .idle:
                            Button("Recalibrate stick") { joyCon.beginCalibration() }
                        case .rest:
                            Text("Hold the stick at rest (playing grip)…")
                                .foregroundStyle(Color.accentColor)
                        case .range:
                            Button("Done") { joyCon.finishCalibration() }
                            Text("Sweep a full circle along the rim, then Done")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.caption)
                    if !joyCon.calInfo.isEmpty {
                        Text(joyCon.calInfo)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(.body))
        }
    }

    /// The ARM calibration: a guided capture — rest, then the three arm
    /// sweeps — advanced by the Next button or the Joy-Con's dpad-up,
    /// fitted jointly (cross-talk solved out). iPad-only: it runs on
    /// the tilt stream; the Joy-Con is optional (dpad stepping, ZL
    /// re-zero).
    private var bodyPanel: some View {
        TiltCalPanel(
            cal: joyCon.armCal, title: "Arm calibration",
            intro: "The iPad's tilt calibration: the iPad streams raw attitude and this capture learns the whole map — rest pose, movement directions and ranges (rest = 0 on every axis). Needs only the iPad on the arm; the Joy-Con is optional (dpad-up advances, dpad-down steps back, ZL re-zeroes the rest pose). Four phases. Start each sweep from rest and end near rest if you can — all seven rest readings are merged robustly, and a reading that isn't at rest is simply ignored, never a redo. A one-sided or duplicate sweep clears itself and repeats on the spot.")
    }

    /// The WRIST calibration : the same guided capture over
    /// the Joy-Con's fused attitude — wrist up/down, in/out, rotation
    /// → the Wrist ↕/↔/⟲ control axes. Shown once the Joy-Con's motion
    /// fusion is live (or a calibration already exists).
    private var wristPanel: some View {
        TiltCalPanel(
            cal: joyCon.wristCal, title: "Wrist calibration",
            intro: "The Joy-Con's tilt calibration: hold the Joy-Con in the playing grip and capture a rest pose, then two wrist sweeps, each starting from rest. Up/down defines the Wrist ↕ axis exactly; inward/outward is fitted at right angles to it (the part shared with up/down is dropped) and becomes Wrist ↔; Wrist ⟲ is inferred as the axis perpendicular to both, with the mean of the two measured ranges. Rest = 0, sweep extremes ±1 on the Controls tab. Dpad-up advances, dpad-down steps back, ZL re-zeroes the rest pose. Without a calibration the wrist axes stay silent; Joy-Con Accel needs no calibration.")
    }

    /// The Mac twin of the iPad's GYRO overlay: the same 3D attitude
    /// trail, drawn from the TRANSMITTED values instead of the sensor —
    /// put the two screens side by side to see what the wire does to
    /// the motion.
    private var receivedPanel: some View {
        Panel(title: "Received motion (3D)") {
            ReceivedMotionView(
                samples: { joyCon.liveTrace.map { s in
                    (s.raw * 2 - SIMD3<Double>(1, 1, 1)) * (.pi / 2)
                } },
                names: ["pitch ", "roll  ", "yaw hp"],
                caption: "as received over MIDI · last 8 s · compare against the iPad's GYRO overlay")
        }
    }

    /// The Joy-Con 2 fused pair — the analogs of the
    /// iPad's received motion/acceleration views, from the 9-axis
    /// fusion: orientation in 3D space (mag-pinned yaw once the
    /// hard-iron estimate is earned) and gravity-removed linear
    /// acceleration resting at the origin. Judge the Joy-Con's
    /// steadiness here — the raw trails below are unfiltered sensors,
    /// which is why they look busier than the iPad's fused views.
    private func controlChips(_ controls: [JoyConInput.Control]) -> some View {
        HStack(spacing: 6) {
            ForEach(controls, id: \.self) { c in
                let down = joyCon.buttonsDown.contains(c)
                Text(c.rawValue)
                    .font(.caption.weight(down ? .bold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(down ? Color.accentColor.opacity(0.8)
                                   : Color.secondary.opacity(0.15)))
            }
        }
    }

    private var joyConFusedPanels: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel(title: "Joy-Con motion (3D)") {
                ReceivedMotionView(
                    samples: { joyCon.liveJoyConAttitude.map { $0.a } },
                    names: ["pitch ", "roll  ", "yaw   "],
                    caption: "fused attitude (9-axis complementary filter) · last 8 s · compare against Received motion")
            }
            Panel(title: "Joy-Con acceleration (3D)") {
                VectorTrailView(
                    samples: { joyCon.liveJoyConLinAccel },
                    viewRadius: 0.5, names: ["x", "y", "z"], unit: "g",
                    caption: "fused: accel minus the gravity estimate · rests at the origin · last 8 s")
            }
        }
    }

    /// The accelerometer twin — same wire, same A/B purpose against the
    /// iPad overlay's accel half. Fixed ±0.5 g scale (velocityMaxG —
    /// the top of the strike range; harder spikes clip briefly).
    private var accelPanel: some View {
        Panel(title: "Received acceleration (3D)") {
            VectorTrailView(
                samples: { joyCon.liveAccelTrace },
                viewRadius: 0.5, names: ["x", "y", "z"], unit: "g",
                caption: "raw userAcceleration as received · last 8 s · compare against the iPad overlay")
        }
    }

    /// The Joy-Con's own IMU, from whichever transport is live —
    /// classic: 0x30 report frames once subcommand 0x40 enables the
    /// IMU; Joy-Con 2: every BLE notification. The magnetometer panel
    /// (Joy-Con 2 only) appears only when non-zero data arrives, so an
    /// absent or unverified mag block stays invisible.
    private var joyConIMUPanels: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel(title: "Joy-Con gyroscope (3D)") {
                VectorTrailView(
                    samples: { joyCon.liveJoyConGyro },
                    viewRadius: 360, names: ["ωx", "ωy", "ωz"], unit: "°/s",
                    caption: "raw rotation rate, device frame · last 8 s")
            }
            Panel(title: "Joy-Con accelerometer (3D)") {
                VectorTrailView(
                    samples: { joyCon.liveJoyConAccel },
                    viewRadius: 2, names: ["x", "y", "z"], unit: "g",
                    caption: "raw accel, device frame · includes gravity (rest = 1 g sphere) · last 8 s")
            }
            if joyCon.jcMagActive {
                Panel(title: "Joy-Con magnetometer (3D)") {
                    VectorTrailView(
                        samples: { joyCon.liveJoyConMag },
                        viewRadius: 2000, names: ["mx", "my", "mz"], unit: "raw",
                        caption: "magnetometer, raw units · Joy-Con 2 only · last 8 s")
                }
            }
        }
    }
}

// MARK: - Received motion (3D)

/// Shared attitude-trail view (the iPad GYRO overlay's rendering):
/// turntable projection, age-faded trail and per-axis Δ° readouts over
/// [pitch, roll, yaw] samples in radians. Two clients: "Received
/// motion" (the TRANSMITTED tilt values — side by side with the iPad
/// overlay this is the transmission A/B; the wire's yaw is the
/// HIGH-PASSED, bias-corrected axis, so raw yaw drift visible on the
/// iPad and absent there is correct behaviour) and the Joy-Con 2's
/// fused attitude .
private struct ReceivedMotionView: View {
    /// Sampled fresh inside each 60 Hz timeline tick (attitude in
    /// radians). Deliberately not observed state: the TimelineView
    /// drives the redraws, so the trail moves at the source rate.
    let samples: () -> [SIMD3<Double>]
    let names: [String]
    let caption: String

    private static let spin = 0.3
    private static let colors: [Color] = [.orange, .green, .cyan]
    /// Fixed view scale: ±30° of attitude to the frame edge, the same
    /// constant as the iPad overlay — the two views render motion at
    /// identical size, and the zoom no longer pumps with the trail's
    /// extent (auto-zoom also blew sub-degree noise up into a
    /// full-frame fuzz ball; at a fixed scale it reads as the near-
    /// stillness it is, with the Δ° labels carrying the magnitude).
    /// Only the scale is fixed — the view stays CENTRED on the trail
    /// mean, since the rest pose is arbitrary.
    private static let viewRadius = 30.0 * Double.pi / 180

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { tl in
            let pts = samples()
            VStack(alignment: .leading, spacing: 3) {
                Canvas { ctx, size in
                    Self.draw(ctx, size: size, pts: pts,
                              azimuth: tl.date.timeIntervalSinceReferenceDate
                                  * Self.spin)
                }
                .frame(width: 250, height: 190)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                ForEach(0..<3, id: \.self) { a in
                    let vals = pts.map { $0[a] }
                    let pp = ((vals.max() ?? 0) - (vals.min() ?? 0)) * 180 / .pi
                    let cur = (vals.last ?? 0) * 180 / .pi
                    Text(String(format: "%@ %+8.3f°  Δ%.3f°",
                                names[a], cur, pp))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Self.colors[a])
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             pts allPts: [SIMD3<Double>], azimuth: Double) {
        MotionScatter.drawTrail(ctx, size: size, points: allPts,
                                maxRadius: viewRadius, axisColors: colors,
                                azimuth: azimuth)
    }
}

// MARK: - Origin-centred vector trail (3D)

/// Shared origin-centred turntable trail: the received-acceleration
/// view and the Joy-Con IMU panels. Unlike `ReceivedMotionView`
/// (attitude, centred on the trail mean because the rest pose is
/// arbitrary), these signals have a natural zero — strikes and turns
/// read as excursions from the centre dot, gravity/earth-field
/// vectors as points riding a sphere around it. Scale is FIXED
/// (`viewRadius` in the signal's own units = frame edge), same rule
/// as the attitude pair.
private struct VectorTrailView: View {
    /// Sampled fresh inside each 60 Hz timeline tick (the closure
    /// captures the JoyConInput reference; nothing here is observed).
    let samples: () -> [JoyConInput.RawAccelSample]
    let viewRadius: Double
    let names: [String]
    let unit: String
    let caption: String

    private static let spin = 0.3
    private static let colors: [Color] = [.orange, .green, .cyan]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { tl in
            let pts = samples().map { $0.a }
            VStack(alignment: .leading, spacing: 3) {
                Canvas { ctx, size in
                    Self.draw(ctx, size: size, pts: pts, maxR: viewRadius,
                              azimuth: tl.date.timeIntervalSinceReferenceDate
                                  * Self.spin)
                }
                .frame(width: 250, height: 190)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                ForEach(0..<3, id: \.self) { a in
                    let vals = pts.map { $0[a] }
                    let pp = (vals.max() ?? 0) - (vals.min() ?? 0)
                    let cur = vals.last ?? 0
                    Text(String(format: "%@ %+9.3f %@  Δ%.3f %@",
                                names[a], cur, unit, pp, unit))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Self.colors[a])
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             pts allPts: [SIMD3<Double>], maxR: Double,
                             azimuth: Double) {
        // Origin-centred: these signals have a natural zero.
        MotionScatter.drawTrail(ctx, size: size, points: allPts,
                                maxRadius: maxR, center: SIMD3<Double>(),
                                axisColors: colors, azimuth: azimuth)
    }
}

// MARK: - Guided calibration panel + sample cloud (3D)

/// One guided-calibration panel (shared by the arm and the
/// wrist): the start button or the running phase prompt, the live
/// verdict line, the calibrated axes readout and the rotating sample
/// cloud with the fitted model.
private struct TiltCalPanel: View {
    @ObservedObject var cal: TiltCalibrator
    let title: String
    let intro: String

    var body: some View {
        Panel(title: title) {
            VStack(alignment: .leading, spacing: 8) {
                if cal.step == nil {
                    HStack(spacing: 10) {
                        Button(cal.isCalibrated ? "Recalibrate…" : "Calibrate…") {
                            cal.begin()
                        }
                        if !cal.info.isEmpty {
                            Text(cal.info)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    if !cal.detail.isEmpty {
                        Text(cal.detail)
                            .font(.caption)
                            .foregroundStyle(cal.detail.hasPrefix("⚠")
                                             ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(cal.info)
                        .font(.system(.body).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if !cal.detail.isEmpty {
                        Text(cal.detail)
                            .font(.caption)
                            .foregroundStyle(cal.detail.hasPrefix("⚠")
                                             ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button(cal.step == cal.config.sweepCount ? "Finish" : "Next") {
                            cal.advance()
                        }
                        Button("Redo previous") {
                            cal.redoPrevious()
                        }
                        .disabled(cal.step == 0)
                        Button("Cancel") { cal.cancel() }
                    }
                    .font(.caption)
                }
                if !cal.axes.isEmpty {
                    Text("axes  " + cal.axes
                        .map { String(format: "%+.2f", $0) }
                        .joined(separator: "  "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if cal.cloud.contains(where: { !$0.isEmpty }) || cal.viz != nil {
                    CalCloudView(cal: cal)
                }
            }
        }
    }
}

/// Rotating 3D scatter of a guided-calibration capture, live while
/// samples stream in: the REST cluster plus the three sweep arcs in
/// feature space (the calibrator's three input axes). A slow turntable
/// spin with depth-scaled dot size/opacity supplies the parallax; the
/// white ring marks the rest cluster's centre, so how cleanly the arcs
/// intersect at rest reads directly off the picture. Overlaid on the
/// raw data: the CALIBRATED MODEL — three straight segments through
/// the fitted rest point, each solved direction scaled by its lo/hi
/// extents (what the live solve actually applies; how closely they
/// hug the arcs is the fit quality) — and a yellow "you are here"
/// marker at the current position. The view is centred on the rest
/// cluster (else the fitted rest) and auto-scaled to the data. The
/// capture stays on screen after the fit; the model segments show
/// whenever a calibration exists, including right after launch.
private struct CalCloudView: View {
    /// Observed for the cloud/phase/model; `livePos` is READ fresh
    /// inside each 60 Hz timeline tick for the marker.
    @ObservedObject var cal: TiltCalibrator

    private static let colors: [Color] = [.white, .orange, .green, .cyan]
    /// Turntable rate in rad/s — one revolution ≈ 21 s.
    private static let spin = 0.3

    var body: some View {
        let names = ["Rest"] + Array(cal.config.sweepNames.prefix(cal.config.sweepCount))
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { tl in
                Canvas { ctx, size in
                    Self.draw(ctx, size: size,
                              azimuth: tl.date.timeIntervalSinceReferenceDate
                                  * Self.spin,
                              cloud: cal.cloud, currentPhase: cal.step,
                              viz: cal.viz, pos: cal.livePos,
                              featureNames: cal.config.featureNames)
                }
            }
            .frame(height: 230)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 12) {
                ForEach(0..<names.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(Self.colors[i]).frame(width: 6, height: 6)
                        Text(names[i])
                    }
                }
                if cal.viz != nil {
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.secondary)
                            .frame(width: 10, height: 2)
                        Text("fit")
                    }
                    if cal.config.sweepCount < 3 {
                        HStack(spacing: 4) {
                            Rectangle().fill(Self.colors[3])
                                .frame(width: 10, height: 2)
                            Text(cal.config.sweepNames[2] + " inferred")
                        }
                    }
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.yellow).frame(width: 6, height: 6)
                    Text(cal.config.markerName)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             azimuth: Double,
                             cloud: [[SIMD3<Double>]], currentPhase: Int?,
                             viz: TiltCalibrator.Viz?, pos: SIMD3<Double>?,
                             featureNames: [String]) {
        let all = cloud.flatMap { $0 }
        // The fitted model's segment endpoints participate in centring
        // and auto-scale alongside the raw samples (so a fresh launch
        // with no cloud still frames the model), as does the live
        // marker.
        var segments: [(a: SIMD3<Double>, b: SIMD3<Double>, phase: Int)] = []
        if let viz {
            for (k, axis) in viz.axes.enumerated() {
                segments.append((viz.f0 + axis.dir * axis.lo,
                                 viz.f0 + axis.dir * axis.hi, k + 1))
            }
        }
        var extentPts = all + segments.flatMap { [$0.a, $0.b] }
        if let pos { extentPts.append(pos) }
        guard !extentPts.isEmpty else {
            ctx.draw(Text("waiting for samples…")
                .font(.caption).foregroundColor(.gray),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        // Centre on the rest cluster when it exists — that's the point
        // the arcs are supposed to thread — else the fitted rest, else
        // the data mean.
        let restPts = cloud.first ?? []
        let c: SIMD3<Double>
        if !restPts.isEmpty {
            c = MotionScatter.mean(restPts)
        } else if let viz {
            c = viz.f0
        } else {
            c = MotionScatter.mean(extentPts)
        }
        var maxR = 0.04   // floor doubled with the −1…+1 tilt rescale
        for p in extentPts { maxR = max(maxR, simd_length(p - c)) }
        // Unlike the trail views this one auto-scales to the cloud.
        let proj = MotionScatter.Projection(center: c, maxRadius: maxR,
                                            size: size, inset: 14,
                                            azimuth: azimuth)
        let project = proj.project

        // Feature axes through the rest centre, for orientation.
        let unit = [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0),
                    SIMD3<Double>(0, 0, 1)]
        for (i, axis) in unit.enumerated() {
            let a = project(c - axis * maxR)
            let b = project(c + axis * maxR)
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
            let label = i < featureNames.count ? featureNames[i] : "t\(i + 1)"
            ctx.draw(Text(label).font(.system(size: 8)).foregroundColor(.gray),
                     at: CGPoint(x: b.x, y: b.y))
        }

        var dots: [(x: Double, y: Double, depth: Double, phase: Int)] = []
        dots.reserveCapacity(all.count)
        for (phase, pts) in cloud.enumerated() {
            for p in pts {
                let q = project(p)
                dots.append((q.x, q.y, q.depth, phase))
            }
        }
        if var minD = dots.first?.depth {
            var maxD = minD
            for d in dots {
                minD = min(minD, d.depth)
                maxD = max(maxD, d.depth)
            }
            let span = max(maxD - minD, 1e-9)
            dots.sort { $0.depth < $1.depth }   // painter: far → near
            for d in dots {
                let near = (d.depth - minD) / span
                let dim = currentPhase == nil || d.phase == currentPhase
                    ? 1.0 : 0.5
                let r = 1.2 + 1.6 * near
                let color = colors[min(d.phase, colors.count - 1)]
                    .opacity((0.3 + 0.6 * near) * dim)
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r,
                                                width: 2 * r, height: 2 * r)),
                         with: .color(color))
            }
        }

        // The fitted model: three straight segments through the fitted
        // rest point, colored like their sweeps — the linear motion the
        // live solve assumes. How closely they hug the raw arcs IS the
        // fit quality.
        for seg in segments {
            let a = project(seg.a)
            let b = project(seg.b)
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.stroke(path,
                       with: .color(colors[min(seg.phase, colors.count - 1)]
                           .opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        if let viz {
            let q = project(viz.f0)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2, y: q.y - 2,
                                            width: 4, height: 4)),
                     with: .color(.white))
        }

        // Rest-centre ring: the target every arc should pass through.
        if !restPts.isEmpty {
            let q = project(c)
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5,
                                              width: 10, height: 10)),
                       with: .color(.white.opacity(0.9)), lineWidth: 1)
        }

        // "You are here": the live position, topmost, with its feature
        // values (−1…+1) beside it.
        if let pos {
            let q = project(pos)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.yellow))
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4,
                                              width: 8, height: 8)),
                       with: .color(.white.opacity(0.8)), lineWidth: 1)
            // Keep the label inside the canvas: lead on the left half,
            // trail on the right.
            let onLeft = q.x < Double(size.width) / 2
            ctx.draw(Text(tiltLabel(pos))
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.yellow),
                at: CGPoint(x: q.x + (onLeft ? 8 : -8), y: q.y - 8),
                anchor: onLeft ? .leading : .trailing)
        }
    }

    /// "(+.4, −.2, −.3)" — the marker's feature values, one decimal,
    /// leading zero dropped.
    private static func tiltLabel(_ p: SIMD3<Double>) -> String {
        func f(_ v: Double) -> String {
            String(format: "%+.1f", v).replacingOccurrences(of: "0.", with: ".")
        }
        return "(\(f(p.x)), \(f(p.y)), \(f(p.z)))"
    }
}
