import CoreBluetooth
import Foundation
import GameController
import IOKit.hid
import simd

/// Supplemental game-controller input (2026-08-05): a single Nintendo
/// Switch Joy-Con (L) paired to the Mac over Bluetooth — though any
/// GameController-framework device with a stick and buttons works. Mac-side
/// and purely ADDITIVE: it feeds the same funnels the iPad's MIDI stream
/// feeds (the tilt evaluation and the drone buttons), so both inputs work
/// at once and the iPad loses nothing when the controller sleeps or
/// disconnects — last writer wins.
///
/// * **Stick** — while deflected past the deadzone the calibrated x/y
///   drive tilt 1 / tilt 2 directly (0…1, centre = 0.5) and the host
///   gives them PRIORITY over the iPad's tilt stream (no last-writer
///   ping-pong); at rest the Joy-Con is silent and the iPad's stream
///   has the axes to itself.
/// * **Buttons** — semantic `Control` events the host maps, named by the
///   UPRIGHT grip (the printed arrows). macOS presents a lone Joy-Con in
///   its SIDEWAYS orientation, so `attach` rotates the stick axes and
///   the face-button diamond 90° back (`rotateForUpright`).
///
/// **The alias trap:** a `GCPhysicalInputProfile` names one physical
/// element under SEVERAL keys — a lone Joy-Con's stick is both
/// "Left Thumbstick" AND "Direction Pad". Binding the d-pad without an
/// identity check therefore turns stick deflection into button presses
/// (drones plucked by the stick — the launch bug). `attach` resolves the
/// stick first and only binds a Direction Pad that is a DISTINCT element.
/// The published monitor state below (raw stick, buttons down, last raw
/// event, the alias-grouped element inventory) feeds the Setup tab's
/// Game Controller panel so surprises like this are visible.
///
/// **Switch 2 Joy-Con (2026-08-11):** Joy-Con 2 are BLE devices with a
/// vendor GATT protocol — no Bluetooth-Classic HID, no HID-over-GATT —
/// so macOS cannot pair them at all (nothing shows in Bluetooth
/// settings) and neither GameController nor IOHID ever sees them. A
/// `JoyCon2BLE` CoreBluetooth client (bottom of this file) scans for
/// Nintendo's company ID, connects, subscribes to the input notify
/// characteristic, and hands notifications to `bleNotification`, which
/// feeds the SAME funnels: buttons → `setButton`, 12-bit stick →
/// `processRawStick` (shared calibration + tilt pipeline — recalibrate
/// after switching controller generations, the electrical ranges
/// differ). Protocol per the community RE (Nohzockt/Switch2-Controllers).
///
/// Handlers fire on the main queue; the host's funnels are thread-safe.
final class JoyConInput: ObservableObject {

    /// The controller's buttons, named by position on an upright left
    /// Joy-Con. A sideways grip's A/B/X/Y map onto the same four
    /// directional controls by their physical placement.
    enum Control: String, CaseIterable {
        case dpadUp = "Up", dpadDown = "Down"
        case dpadLeft = "Left", dpadRight = "Right"
        /// L upright / SL sideways.
        case shoulder1 = "L·SL"
        /// ZL upright / SR sideways.
        case shoulder2 = "ZL·SR"
    }

    /// THE ARM AXES (2026-08-13): the calibrated three-dimension output
    /// — arm ↕, arm ↔, arm ⟲, each 0…1 (rest = 0.5) — from the joint
    /// solve over the iPad's raw tilt report (`armTick` → `bodyCal`).
    /// Non-perpendicular sweeps are separated by the least-squares
    /// solve, which attributes shared attitude motion to whichever
    /// calibrated movement direction explains it. Change-gated +
    /// quantized. (The 2026-08-12 wrist half — Joy-Con gravity features,
    /// wrist sweeps, tilt4 — was removed 2026-08-13.)
    var onArmAxes: ((Double, Double, Double) -> Void)?
    /// The stick as its own two axes (0…1, centre 0.5), per-axis
    /// gate + rescale, change-gated. No ownership/priority — every axis
    /// has exactly one source now.
    var onStickAxes: ((Double, Double) -> Void)?
    var onButton: ((_ control: Control, _ pressed: Bool) -> Void)?

    // Monitor state for the Setup tab's panel. All written on the main
    // queue; the stick and raw-event fields are throttled to ~15 Hz
    // (the control path via `onStick` is NOT throttled).
    @Published private(set) var connectedName: String?
    /// Raw stick, −1…+1 per axis.
    @Published private(set) var stickX = 0.0
    @Published private(set) var stickY = 0.0
    /// True while the stick is outside the deadzone (= driving tilts).
    @Published private(set) var stickActive = false
    @Published private(set) var buttonsDown: Set<Control> = []
    /// The last raw element event, named by the OS — shows what an
    /// unmapped or surprisingly-aliased input actually arrives as.
    @Published private(set) var lastEvent = "—"
    /// The profile's element inventory, one line per PHYSICAL element
    /// with all its alias names joined ("Direction Pad / Left Thumbstick"
    /// = one element with two names).
    @Published private(set) var elementNames: [String] = []

    // RAW HID SIDE-CHANNEL (2026-08-05). macOS presents a lone Joy-Con
    // as a `GCGamepad`: no L/ZL elements at all, and the stick arrives
    // as a DIGITAL 8-direction hat (`isAnalog == false`) even though
    // the device's simple-mode report (0x3F) carries 16 buttons and
    // four 16-bit axes. So an `IOHIDManager` listens to the raw input
    // reports in parallel (read-only — gamecontrollerd keeps driving
    // the GC profile): L/ZL come from the button bytes; the analog
    // stick values are published for the panel so their frame/signs
    // can be verified before the tilt path adopts them.
    /// "open" or the failing IOReturn — shown in the panel.
    @Published private(set) var hidStatus = "off"
    /// Last raw input report (hex, truncated) — layout verification.
    @Published private(set) var hidReportHex = "—"
    /// Raw analog stick from the HID report, −1…+1, device frame
    /// (display only until verified). Two pairs: X/Y and Rx/Ry.
    @Published private(set) var hidAxes: [Double] = []

    private var attached: GCController?
    private var observers: [NSObjectProtocol] = []
    /// Per-axis deflection gate: an axis counts as deflected only at
    /// |v| ≥ this (the neutral drifts a little, and sub-threshold
    /// wiggle was leaking into the tilt readouts); below it the axis
    /// pins to exact centre. Both axes under threshold = rest.
    private let deadzone = 0.1
    /// GRIP (2026-08-05): macOS presents a LONE Joy-Con as a SIDEWAYS
    /// mini-gamepad — stick axes in the sideways frame, the printed
    /// arrows as A/B/X/Y by sideways placement. We hold it UPRIGHT, so
    /// stick and face buttons are rotated 90° back (the sideways frame
    /// is the upright device turned 90° CCW: upright = (x, y) →
    /// sideways (−y, x)). A paired L+R duo ("Joy-Con (L/R)") is a real
    /// gamepad — no rotation.
    private var rotateForUpright = false
    private var lastStickPublish: CFAbsoluteTime = 0
    private var lastEventPublish: CFAbsoluteTime = 0
    /// SWITCH 2 (2026-08-11): the BLE client's status line for the
    /// panel — Joy-Con 2 never appear in macOS Bluetooth settings
    /// (vendor GATT protocol, nothing pairable), connection lives
    /// entirely in `JoyCon2BLE`.
    @Published private(set) var bleStatus = "off"
    /// Joy-Con 2 IMU, panel display (~10 Hz): [ax, ay, az] in ≈g then
    /// [gx, gy, gz] in ≈°/s. Raw int16 scaled by the classic Joy-Con
    /// constants (±8 g → /4096, ±2000 °/s → /16.4) — close enough for
    /// display/gestures until measured. Empty until motion streaming is
    /// enabled and real frames arrive.
    @Published private(set) var bleIMU: [Double] = []
    private var lastIMUPublish: CFAbsoluteTime = 0
    private var bleDown: Set<Control> = []
    private let ble = JoyCon2BLE()

    // ORIENTATION FUSION (2026-08-11). Complementary filter: the
    // body-frame gravity estimate `gHat` integrates the gyro
    // (ġ = g × ω) and is pulled slowly toward the accelerometer's unit
    // vector; yaw integrates the gyro's component about gravity (kept
    // for future use — the body features are drift-free gravity only).
    private var gHat: SIMD3<Double>?
    private var gyroBias = SIMD3<Double>.zero
    private var yaw = 0.0
    private var lastIMUTime: CFAbsoluteTime = 0

    // ARM CALIBRATION (2026-08-13) — the three iPad tilt axes, guided.
    // Descended from the 2026-08-12 body calibration with the WRIST
    // HALF REMOVED (no Joy-Con gravity in the features, no wrist
    // sweeps, no tilt4): feature vector f ∈ R³ = the iPad's raw tilt
    // report, and the whole pipeline — capture, PCA per sweep, joint
    // least squares c = (DᵀD)⁻¹Dᵀ(f − f0), piecewise asymmetric
    // extents, ROBUST rest merge (rest phase + each sweep's start/end
    // windows = 7 readings, median → inliers → mean) — runs on the
    // tilt stream itself, so NO Joy-Con is needed. A guided capture
    // records a REST pose then three arm sweeps (↕, ↔, rotation);
    // rest → 0.5, sweep extremes → 0/1. ZL re-captures f0 (quick
    // re-zero); dpad-up advances, dpad-down redoes the previous phase
    // (both optional — the panel buttons do the same).
    struct BodyCal: Codable {
        var f0: [Double]       // rest feature vector (3)
        var m: [[Double]]      // solve matrix (3×3)
        var lo: [Double]       // per-axis negative extent (3, < 0)
        var hi: [Double]       // per-axis positive extent (3, > 0)
    }
    /// Feature/axis count for the arm calibration (the iPad's 3 tilts).
    static let armDims = 3
    /// nil = idle; 0 = rest capture; 1…3 = the three sweeps.
    @Published private(set) var bodyCalStep: Int? = nil
    @Published private(set) var bodyCalInfo = ""
    /// Live calibrated arm axes for the panel (0…1 ×3, ~10 Hz).
    @Published private(set) var bodyTilts: [Double] = []
    static let bodyCalStepNames = [
        "REST: hold the arm still in playing position",
        "Sweep the ARM up and down — start from rest, end near rest",
        "Sweep the ARM inward and outward — start from rest, end near rest",
        "Rotate the ARM inward and outward — start from rest, end near rest",
    ]
    /// Short sweep names for feedback messages (phases 1…3).
    static let bodyCalSweepNames = ["ARM ↕", "ARM ↔", "ARM ⟲"]
    /// Secondary calibration feedback: the last phase's verdict while
    /// capturing (sample count, both-ways, alignment against earlier
    /// sweeps), the separation summary or discard advice afterward.
    @Published private(set) var bodyCalDetail = ""
    /// Live 3D sample cloud for the Setup panel's rotating scatter —
    /// per phase (rest + the three sweeps), decimated for display and
    /// published at ~20 Hz while samples stream in. Kept after the fit
    /// so the finished capture can still be inspected; cleared when a
    /// new capture begins. The fit itself always uses the full
    /// `calSamples`, never this.
    @Published private(set) var calCloud: [[SIMD3<Double>]] = []
    private var lastCloudPublish: CFAbsoluteTime = 0
    /// Calibrated-model geometry for the 3D panel: the rest point plus
    /// the three solved movement SEGMENTS — each fitted direction
    /// scaled by its lo/hi extents. Because `m·d = 1` by construction,
    /// the extents are feature-space lengths along each direction, so
    /// the segments are exactly the linear model the live solve
    /// applies. Rebuilt at fit, on load (directions recovered as the
    /// columns of `m⁻¹`), and on ZL re-zero (f0 moves).
    struct CalViz {
        var f0: SIMD3<Double>
        var axes: [(dir: SIMD3<Double>, lo: Double, hi: Double)]
    }
    @Published private(set) var calViz: CalViz?
    /// EMA-smoothed arm feature vector, updated per incoming message
    /// (`armSmoothAlpha`). The raw report is 7-bit-quantized attitude
    /// and a resting arm flickers ±1–2 steps across quantization
    /// boundaries; unsmoothed, the joint solve AMPLIFIES that (its
    /// Gram-inverse rows grow with sweep cross-talk) into visibly
    /// jittering control axes, and the panel marker dances around the
    /// segment crossing. The smoothed vector feeds the live solve, the
    /// calibration capture and the marker alike — per-message α means
    /// fast convergence while moving (60 Hz stream) and strong
    /// averaging of the sparse rest-jitter messages.
    private var armSmooth: SIMD3<Double>?
    private static let armSmoothAlpha = 0.25
    /// FRAME COALESCING (2026-08-14). The wire delivers ONE AXIS PER
    /// MESSAGE, so a single 60 Hz report arrives as up to three
    /// messages a few hundred µs apart — sampling the full vector at
    /// each one records torn frames (new pitch, stale roll, stale yaw).
    /// Measured on a circular arm motion: the per-message trail was
    /// 100% axis-aligned segments with a 90° mean turn (a staircase),
    /// the burst-merged trail 0% and 4° (the actual circle). Messages
    /// within this gap update the CURRENT frame in place — trail,
    /// capture and smoothing all see atomic frames; only a real
    /// inter-report gap starts a new one.
    private static let frameGap: CFAbsoluteTime = 0.004
    private var lastArmMsgT: CFAbsoluteTime = 0
    /// EMA state as of the START of the current frame, so in-place
    /// burst updates re-derive the smoothed value instead of advancing
    /// the filter three times per report.
    private var armSmoothPrev: SIMD3<Double>?
    /// Raw-stream trail for the Setup panel's "Received motion (3D)"
    /// view: the UNSMOOTHED per-message feature vectors, last ~8 s.
    /// Not published — the view reads `liveTrace` inside its 60 Hz
    /// TimelineView tick, so the trail moves at the wire rate like the
    /// iPad's GYRO overlay. Runs whether or not a calibration exists.
    struct RawTiltSample {
        var t: CFAbsoluteTime
        var raw: SIMD3<Double>
    }
    private var rawBuf: [RawTiltSample] = []
    private static let traceWindow: CFAbsoluteTime = 8
    /// Flips once when the first tilt message lands — gates the panel.
    @Published private(set) var traceActive = false
    /// Received raw accelerometer trail (g, gravity removed), the
    /// accel twin of `rawBuf` — display-only, same ~8 s window.
    struct RawAccelSample {
        var t: CFAbsoluteTime
        var a: SIMD3<Double>
    }
    private var accelBuf: [RawAccelSample] = []
    /// The Joy-Con's own IMU trails (device frame, same ~8 s window):
    /// gyro in °/s, accel in g (INCLUDES gravity, unlike the iPad's
    /// `userAcceleration` — at rest the vector sits on the 1 g sphere),
    /// magnetometer in raw i16 units (Joy-Con 2 only; classic Joy-Cons
    /// have no magnetometer). Classic: three 5 ms-spaced frames per
    /// 0x30 report once subcommand 0x40 enables the IMU; Joy-Con 2:
    /// every BLE notification.
    private var jcGyroBuf: [RawAccelSample] = []
    private var jcAccelBuf: [RawAccelSample] = []
    private var jcMagBuf: [RawAccelSample] = []
    /// Flip once when the first NON-ZERO IMU / magnetometer sample
    /// lands — they gate the Setup panels (a disabled classic IMU
    /// streams zeros; a Joy-Con 2 without the mag block never trips
    /// the second).
    @Published private(set) var jcIMUActive = false
    @Published private(set) var jcMagActive = false
    /// Live reads for the Setup panel's 60 Hz TimelineViews — fresher
    /// than a throttled @Published mirror. Main thread only (all these
    /// buffers and `armSmooth` are written solely on main).
    var liveTrace: [RawTiltSample] { rawBuf }
    var liveAccelTrace: [RawAccelSample] { accelBuf }
    var liveJoyConGyro: [RawAccelSample] { jcGyroBuf }
    var liveJoyConAccel: [RawAccelSample] { jcAccelBuf }
    var liveJoyConMag: [RawAccelSample] { jcMagBuf }
    var liveArmPos: SIMD3<Double>? { armSmooth }

    /// Append one Joy-Con IMU sample set (main thread).
    private func appendJoyConIMU(t: CFAbsoluteTime,
                                 gyroDps: SIMD3<Double>,
                                 accelG: SIMD3<Double>,
                                 mag: SIMD3<Double>? = nil) {
        jcGyroBuf.append(RawAccelSample(t: t, a: gyroDps))
        jcAccelBuf.append(RawAccelSample(t: t, a: accelG))
        if let first = jcGyroBuf.first, first.t < t - Self.traceWindow {
            jcGyroBuf.removeAll { $0.t < t - Self.traceWindow }
            jcAccelBuf.removeAll { $0.t < t - Self.traceWindow }
        }
        if !jcIMUActive, gyroDps != .zero || accelG != .zero {
            jcIMUActive = true
        }
        if let mag {
            jcMagBuf.append(RawAccelSample(t: t, a: mag))
            if let first = jcMagBuf.first, first.t < t - Self.traceWindow {
                jcMagBuf.removeAll { $0.t < t - Self.traceWindow }
            }
            if !jcMagActive, mag != .zero { jcMagActive = true }
        }
    }

    private func clearJoyConIMU() {
        jcGyroBuf = []
        jcAccelBuf = []
        jcMagBuf = []
        jcIMUActive = false
        jcMagActive = false
        imuEnableTries = 0
    }

    /// iPad raw accelerometer in (link receive queue) — display only,
    /// no calibration or solve involvement.
    func feedAccel(_ x: Double, _ y: Double, _ z: Double) {
        let a = SIMD3(x, y, z)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.accelBuf.append(RawAccelSample(t: now, a: a))
            if let first = self.accelBuf.first,
               first.t < now - Self.traceWindow {
                self.accelBuf.removeAll { $0.t < now - Self.traceWindow }
            }
        }
    }
    /// Per-sweep dominant directions, computed as each sweep ends
    /// (feedback only — the fit recomputes its own).
    private var calDirs: [[Double]?] = [nil, nil, nil]
    /// Phase-0 rest mean — the live anchor `evaluateSweep` uses to pick
    /// each sweep's rest reading (the fit re-picks against the robust
    /// merged rest).
    private var calRestMean: [Double]?

    /// Rest-window length used to read a sweep's start/end rest pose
    /// (a fraction of a second of tilt-report samples). Every sweep
    /// starts at the rest pose (ending there is good practice), so
    /// each phase contributes two rest readings — the rest pose is
    /// never assumed to hold perfectly still across the whole capture.
    private static let restWindow = 15

    /// Mean of a sweep's first and last `restWindow` samples — its
    /// start and end rest readings.
    private static func restWindowMeans(of samples: [[Double]])
        -> (start: [Double], end: [Double]) {
        let n = samples.first?.count ?? armDims
        let m = max(1, min(restWindow, samples.count / 2))
        var a = [Double](repeating: 0, count: n)
        var b = a
        for s in samples.prefix(m) { for i in 0..<n { a[i] += s[i] } }
        for s in samples.suffix(m) { for i in 0..<n { b[i] += s[i] } }
        return (a.map { $0 / Double(m) }, b.map { $0 / Double(m) })
    }

    /// Euclidean distance between two feature vectors.
    private static func dist(_ a: [Double], _ b: [Double]) -> Double {
        var d = 0.0
        for (x, y) in zip(a, b) { d += (x - y) * (x - y) }
        return d.squareRoot()
    }
    private var bodyCal: BodyCal? {
        didSet {
            armLock.lock()
            bodyCalActiveFlag = bodyCal != nil
            armLock.unlock()
        }
    }
    private var calSamples: [[[Double]]] = []
    private var lastBodySent: [Double]?
    private var lastBodyPublish: CFAbsoluteTime = 0
    /// Arm-only calibration (3-dim). The retired 6-dim body capture
    /// under `tarabdaar.bodyCal.v1` is simply ignored.
    private static let bodyCalKey = "tarabdaar.armCal.v1"

    // The ARM input: the iPad's raw tilt report, written from the MIDI
    // thread; the calibration capture and the live solve tick off it
    // (hopped to the main thread) — no Joy-Con involvement.
    private let armLock = NSLock()
    private var armTilt = SIMD3<Double>(0.5, 0.5, 0.5)
    private var armTime: CFAbsoluteTime = 0
    private var bodyCalActiveFlag = false

    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private let hidReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    /// Controls currently held according to the raw HID reports (L/ZL
    /// always; every button once full mode streams).
    private var hidDown: Set<Control> = []
    private var lastHIDPublish: CFAbsoluteTime = 0
    /// FULL MODE (2026-08-05): simple mode (0x3F) sends the analog axis
    /// fields as constant-centre filler — real 12-bit stick data only
    /// streams in full mode (0x30), entered via subcommand 0x03/0x30 on
    /// output report 0x01. Once 0x30 reports arrive the HID stick DRIVES
    /// the tilts (the GC hat handler stands down).
    private var hidFullMode = false
    private var hidPacketCounter: UInt8 = 0
    private var modeSwitchTries = 0
    /// Fallback pre-calibration behaviour: rest position from the first
    /// samples after attach + a typical fixed span.
    private var hidStickCenter: (x: Double, y: Double)?
    private var hidCenterAccum: [(Double, Double)] = []
    /// 12-bit units of full deflection from centre (typical hardware
    /// span; the output is clamped so an under-estimate only costs a
    /// little edge sensitivity).
    private let hidStickSpan = 1400.0

    // STICK CALIBRATION (2026-08-05). The stick's gate is roughly a
    // circle around an off-centre rest, so per-axis min/max can never
    // send a diagonal to (±1, ±1) — the rim at 45° reaches neither
    // axis extreme. Instead the RIM is calibrated as a radius per
    // angle bin (captured by sweeping a full circle along the gate)
    // and mapped circle → square at runtime: rest → (0.5, 0.5) tilts,
    // rim in ANY direction = full deflection, diagonal rim = (1, 1).
    // Captured from the panel's Recalibrate flow (phase 1: ~half a
    // second of rest samples in the playing grip; phase 2: sweep the
    // circle, then Done) and persisted.
    struct StickCal: Codable {
        var cx, cy: Double     // rest, raw 12-bit units
        var rim: [Double]      // gate radius per angle bin, raw units
    }
    enum CalPhase { case idle, rest, range }
    @Published private(set) var calPhase: CalPhase = .idle
    /// Live summary of the calibration in progress / in use.
    @Published private(set) var calInfo = ""
    private var stickCal: StickCal?
    private var calDraft: StickCal?
    private var calRestAccum: [(Double, Double)] = []
    private static let calBins = 16
    /// Rim samples closer to rest than this are noise, not the gate.
    private static let calMinRadius = 150.0
    private static let calKey = "tarabdaar.joyconStickCal.v2"

    /// Start the two-phase calibration: rest capture, then the rim
    /// sweep until `finishCalibration`. The stick stops driving the
    /// tilts while it runs.
    func beginCalibration() {
        calRestAccum = []
        calDraft = nil
        calPhase = .rest
        calInfo = "Hold the stick at rest (playing grip)…"
    }

    func finishCalibration() {
        defer { calPhase = .idle }
        guard let d = calDraft else { return }
        // Every bin must have been swept — an empty one would divide
        // by ~zero for deflections in its direction.
        let missing = d.rim.filter { $0 < Self.calMinRadius }.count
        guard missing == 0 else {
            calInfo = "Discarded — \(missing) rim segments unswept; do a full circle"
            NSLog("Tarabdaar: Joy-Con stick calibration discarded (%d empty rim bins)", missing)
            return
        }
        stickCal = d
        if let data = try? JSONEncoder().encode(d) {
            UserDefaults.standard.set(data, forKey: Self.calKey)
        }
        calInfo = ""
        NSLog("Tarabdaar: Joy-Con stick calibrated — rest (%.0f, %.0f), rim %.0f…%.0f",
              d.cx, d.cy, d.rim.min() ?? 0, d.rim.max() ?? 0)
    }

    /// Angle-bin position (0…bins) of an offset from rest.
    private static func binPos(dx: Double, dy: Double, bins: Int) -> Double {
        let b = Double(bins)
        return (atan2(dy, dx) / (2 * .pi) * b + b).truncatingRemainder(dividingBy: b)
    }

    /// Rest-relative raw offset → the unit square. Radius is
    /// normalized by the interpolated rim radius at this angle, then
    /// the direction is scaled so the larger component reaches 1 at
    /// the rim — the circle → square map that sends a diagonal rim
    /// deflection to (±1, ±1).
    private static func calMap(dx: Double, dy: Double, cal: StickCal) -> (Double, Double) {
        let r = (dx * dx + dy * dy).squareRoot()
        guard r > 1 else { return (0, 0) }
        let pos = binPos(dx: dx, dy: dy, bins: cal.rim.count)
        let i0 = Int(pos) % cal.rim.count
        let i1 = (i0 + 1) % cal.rim.count
        let f = pos - pos.rounded(.down)
        let rimR = cal.rim[i0] * (1 - f) + cal.rim[i1] * f
        let rho = min(r / max(rimR, 1), 1)
        let c = dx / r, s = dy / r
        let m = max(abs(c), abs(s))
        return (rho * c / m, rho * s / m)
    }

    func start() {
        if let data = UserDefaults.standard.data(forKey: Self.bodyCalKey),
           let cal = try? JSONDecoder().decode(BodyCal.self, from: data),
           cal.f0.count == Self.armDims, cal.m.count == Self.armDims {
            bodyCal = cal
            bodyCalInfo = "Calibrated"
            // Rebuild the panel's model segments: directions are the
            // columns of m⁻¹ (M·D = I by the joint-solve construction).
            if let inv = Self.invert(cal.m) {
                calViz = CalViz(
                    f0: SIMD3(cal.f0[0], cal.f0[1], cal.f0[2]),
                    axes: (0..<Self.armDims).map { k in
                        (SIMD3(inv[0][k], inv[1][k], inv[2][k]),
                         cal.lo[k], cal.hi[k])
                    })
            }
        }
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            self?.attach(c)
        })
        observers.append(nc.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let c = note.object as? GCController,
                  c === self.attached else { return }
            self.detach()
            NSLog("Tarabdaar: game controller disconnected")
            // Fall over to any other controller still paired.
            if let next = GCController.controllers().first { self.attach(next) }
        })
        if let c = GCController.controllers().first { attach(c) }
        startHID()
        // Switch 2 Joy-Cons: BLE only — scan/connect/subscribe, then
        // notifications feed the same funnels as the HID path.
        ble.onStatus = { [weak self] s in self?.bleStatus = s }
        ble.onConnect = { [weak self] name in
            guard let self else { return }
            self.bleStatus = "connected — \(name)"
            NSLog("Tarabdaar: Joy-Con 2 connected over BLE — %@", name)
            if self.connectedName == nil { self.connectedName = name }
        }
        ble.onDisconnect = { [weak self] in
            guard let self else { return }
            for c in self.bleDown { self.setButton(c, false) }
            self.bleDown = []
            self.bleIMU = []
            self.gHat = nil
            self.bodyTilts = []
            self.lastBodySent = nil
            self.clearJoyConIMU()
            if self.bodyCalStep != nil { self.cancelBodyCalibration() }
            if self.attached == nil { self.connectedName = nil }
        }
        ble.onNotification = { [weak self] data in
            self?.bleNotification(data)
        }
        ble.start()
    }

    /// One Joy-Con 2 input notification (community-RE layout,
    /// Nohzockt/Switch2-Controllers): buttons as a little-endian u32 at
    /// bytes 4–7 — left Joy-Con: dpad Down/Up/Right/Left = bits 16–19,
    /// SR 20, SL 21, L 22, ZL 23 — and the left stick 12-bit packed at
    /// bytes 10–12, device frame, same packing as the classic 0x30
    /// report. Feeds the shared button funnel + stick pipeline.
    private func bleNotification(_ d: Data) {
        guard d.count >= 13 else { return }
        let b = UInt32(d[4]) | (UInt32(d[5]) << 8)
              | (UInt32(d[6]) << 16) | (UInt32(d[7]) << 24)
        var down: Set<Control> = []
        if b & (1 << 16) != 0 { down.insert(.dpadDown) }
        if b & (1 << 17) != 0 { down.insert(.dpadUp) }
        if b & (1 << 18) != 0 { down.insert(.dpadRight) }
        if b & (1 << 19) != 0 { down.insert(.dpadLeft) }
        if b & (1 << 21) != 0 { down.insert(.shoulder1) }   // SL
        if b & (1 << 22) != 0 { down.insert(.shoulder1) }   // L
        if b & (1 << 20) != 0 { down.insert(.shoulder2) }   // SR
        if b & (1 << 23) != 0 { down.insert(.shoulder2) }   // ZL
        for c in down.subtracting(bleDown) { setButton(c, true) }
        for c in bleDown.subtracting(down) { setButton(c, false) }
        bleDown = down
        let s0 = Double(Int(d[10]) | (Int(d[11] & 0x0F) << 8))
        let s1 = Double((Int(d[11]) >> 4) | (Int(d[12]) << 4))
        processRawStick(s0, s1)
        // IMU (motion streaming enabled at connect): accel int16 LE ×3
        // at 0x30, gyro ×3 at 0x36 (trevlars layout, 63-byte report).
        // Fusion runs on EVERY packet; the panel line publishes ~10 Hz.
        if d.count >= 0x3C {
            func i16(_ o: Int) -> Double {
                Double(Int16(bitPattern: UInt16(d[o]) | (UInt16(d[o + 1]) << 8)))
            }
            let accel = SIMD3(i16(0x30), i16(0x32), i16(0x34))
            let gyroDps = SIMD3(i16(0x36), i16(0x38), i16(0x3A)) / 16.4
            processIMU(accel: accel, gyroRadPerSec: gyroDps * .pi / 180)
            let now = CFAbsoluteTimeGetCurrent()
            // Magnetometer: i16 ×3 directly after the gyro (0x3C) in
            // the community layout — offset UNVERIFIED against real
            // hardware, raw units. Parsed only when the notification
            // extends that far; the panel appears only on non-zero
            // data, so a wrong guess that reads zeros stays invisible.
            let mag: SIMD3<Double>? = d.count >= 0x42
                ? SIMD3(i16(0x3C), i16(0x3E), i16(0x40)) : nil
            appendJoyConIMU(t: now, gyroDps: gyroDps,
                            accelG: accel / 4096.0, mag: mag)
            if now - lastIMUPublish > 0.1 {
                lastIMUPublish = now
                bleIMU = [accel.x / 4096.0, accel.y / 4096.0, accel.z / 4096.0,
                          gyroDps.x, gyroDps.y, gyroDps.z]
            }
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastEventPublish > 0.2 {
            lastEventPublish = now
            hidReportHex = "ble: " + d.prefix(13)
                .map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    /// Raw HID listener — see the side-channel note on the published
    /// state above. Scheduled on the main run loop, so all callbacks
    /// land on the main thread like the GC handlers.
    private func startHID() {
        if let data = UserDefaults.standard.data(forKey: Self.calKey),
           let cal = try? JSONDecoder().decode(StickCal.self, from: data) {
            stickCal = cal
        }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOHIDOptionsType(kIOHIDOptionsTypeNone))
        hidManager = mgr
        // Nintendo VID; the device filter in the matching callback
        // narrows to Joy-Cons.
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x057E] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<JoyConInput>.fromOpaque(ctx).takeUnretainedValue()
                .hidDeviceMatched(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<JoyConInput>.fromOpaque(ctx).takeUnretainedValue()
                .hidDeviceRemoved()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        hidStatus = r == kIOReturnSuccess ? "open" : String(format: "open failed 0x%x", r)
        if r != kIOReturnSuccess {
            NSLog("Tarabdaar: IOHIDManagerOpen failed (0x%x) — L/ZL unavailable; grant Input Monitoring if prompted", r)
        }
    }

    private func hidDeviceMatched(_ device: IOHIDDevice) {
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        guard pid == 0x2006 || pid == 0x2007 else { return }   // Joy-Con L/R
        hidDevice = device
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, hidReportBuffer, 512, {
            ctx, _, _, _, reportID, report, length in
            guard let ctx else { return }
            Unmanaged<JoyConInput>.fromOpaque(ctx).takeUnretainedValue()
                .hidReport(id: reportID, report: report, length: Int(length))
        }, ctx)
        NSLog("Tarabdaar: raw HID listener on Joy-Con (pid 0x%x)", pid)
        requestFullMode()
    }

    /// Ask the Joy-Con for full input mode (60 Hz 0x30 reports with the
    /// real analog stick): output report 0x01, neutral rumble bytes,
    /// subcommand 0x03, argument 0x30. Retried a few times — the
    /// arrival of a 0x30 report is the ack.
    private func requestFullMode() {
        guard let device = hidDevice, !hidFullMode, modeSwitchTries < 4
        else { return }
        modeSwitchTries += 1
        hidPacketCounter = (hidPacketCounter &+ 1) & 0x0F
        let cmd: [UInt8] = [0x01, hidPacketCounter,
                            0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40,
                            0x03, 0x30]
        let r = cmd.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01,
                                 $0.baseAddress!, cmd.count)
        }
        if r != kIOReturnSuccess {
            NSLog("Tarabdaar: Joy-Con mode-switch send failed (0x%x)", r)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.requestFullMode()
        }
    }

    /// Enable the classic Joy-Con's IMU streaming (subcommand 0x40,
    /// argument 0x01) — without it the 0x30 report's motion bytes stay
    /// zero. Sent once full mode is confirmed; retried until non-zero
    /// motion data arrives (`jcIMUActive` is the ack).
    private var imuEnableTries = 0
    private func requestIMUEnable() {
        guard let device = hidDevice, hidFullMode, !jcIMUActive,
              imuEnableTries < 4 else { return }
        imuEnableTries += 1
        hidPacketCounter = (hidPacketCounter &+ 1) & 0x0F
        let cmd: [UInt8] = [0x01, hidPacketCounter,
                            0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40,
                            0x40, 0x01]
        let r = cmd.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01,
                                 $0.baseAddress!, cmd.count)
        }
        if r != kIOReturnSuccess {
            NSLog("Tarabdaar: Joy-Con IMU-enable send failed (0x%x)", r)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.requestIMUEnable()
        }
    }

    private func hidDeviceRemoved() {
        for c in hidDown { setButton(c, false) }
        hidDown = []
        hidDevice = nil
        hidFullMode = false
        modeSwitchTries = 0
        hidStickCenter = nil
        hidCenterAccum = []
        hidReportHex = "—"
        hidAxes = []
        clearJoyConIMU()
        calPhase = .idle       // abort any calibration in progress
        calDraft = nil
        calRestAccum = []
        calInfo = ""
        lastStickSent = nil
        onStickAxes?(0.5, 0.5)   // park the stick axes at centre
    }

    /// Parse one raw input report. Simple mode (0x3F): L/ZL from button
    /// byte 2 bits 6/7 (the axis fields are filler — ignored). Full
    /// mode (0x30/0x21): the left-side button byte carries the arrows,
    /// SL/SR and L/ZL in the UPRIGHT device frame, and bytes 6–8 pack
    /// the 12-bit analog stick, which then drives the tilts. The
    /// report-ID byte may or may not be included in the buffer —
    /// detected and skipped. Layout verifiable live via `hidReportHex`.
    private func hidReport(id: UInt32, report: UnsafePointer<UInt8>, length: Int) {
        guard length >= 3 else { return }
        let base = report[0] == UInt8(id & 0xFF) ? 1 : 0
        var down: Set<Control> = []
        if id == 0x3F, length >= base + 2 {
            let b2 = report[base + 1]
            if b2 & 0x40 != 0 { down.insert(.shoulder1) }
            if b2 & 0x80 != 0 { down.insert(.shoulder2) }
            // Arrows/SL/SR stay with the GC path in simple mode.
            down.formUnion(hidDown.intersection([.dpadUp, .dpadDown,
                                                 .dpadLeft, .dpadRight]))
        } else if id == 0x30 || id == 0x21, length >= base + 8 {
            if !hidFullMode {
                hidFullMode = true
                hidStatus = "full mode"
                NSLog("Tarabdaar: Joy-Con in full input mode — analog stick live")
                requestIMUEnable()
            }
            let left = report[base + 4]
            if left & 0x01 != 0 { down.insert(.dpadDown) }
            if left & 0x02 != 0 { down.insert(.dpadUp) }
            if left & 0x04 != 0 { down.insert(.dpadRight) }
            if left & 0x08 != 0 { down.insert(.dpadLeft) }
            if left & 0x10 != 0 { down.insert(.shoulder2) }   // SR
            if left & 0x20 != 0 { down.insert(.shoulder1) }   // SL
            if left & 0x40 != 0 { down.insert(.shoulder1) }   // L
            if left & 0x80 != 0 { down.insert(.shoulder2) }   // ZL
            let s0 = Double(Int(report[base + 5]) | (Int(report[base + 6] & 0x0F) << 8))
            let s1 = Double((Int(report[base + 6]) >> 4) | (Int(report[base + 7]) << 4))
            processRawStick(s0, s1)
            // IMU (streams zeros until subcommand 0x40 enables it):
            // three 12-byte frames ~5 ms apart at base+12 — accel
            // i16 ×3 (±8 g, 1 g = 4096 LSB) then gyro i16 ×3
            // (±2000 °/s, 16.4 LSB per °/s), device frame — the same
            // scales the Joy-Con 2 BLE report uses.
            if id == 0x30, length >= base + 48 {
                let now = CFAbsoluteTimeGetCurrent()
                func i16(_ o: Int) -> Double {
                    Double(Int16(bitPattern: UInt16(report[o])
                        | (UInt16(report[o + 1]) << 8)))
                }
                for f in 0..<3 {
                    let o = base + 12 + f * 12
                    appendJoyConIMU(
                        t: now - Double(2 - f) * 0.005,
                        gyroDps: SIMD3(i16(o + 6), i16(o + 8),
                                       i16(o + 10)) / 16.4,
                        accelG: SIMD3(i16(o), i16(o + 2),
                                      i16(o + 4)) / 4096.0)
                }
            }
        } else {
            return
        }
        for c in down.subtracting(hidDown) { setButton(c, true) }
        for c in hidDown.subtracting(down) { setButton(c, false) }
        hidDown = down
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastEventPublish > 0.2 {
            lastEventPublish = now
            let n = min(length, 12)
            hidReportHex = "id \(String(format: "%02x", id)): " + (0..<n)
                .map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        }
    }

    /// The shared raw-stick pipeline — HID full-mode (Joy-Con 1) and
    /// BLE (Joy-Con 2) both land here with 12-bit device-frame values:
    /// the calibration state machine, then the calibrated map into
    /// `handleStick`. ONE calibration is stored — switching controller
    /// generations needs a quick recalibrate (the ranges differ).
    private func processRawStick(_ s0: Double, _ s1: Double) {
        switch calPhase {
            case .rest:
                // Phase 1: the in-grip rest position.
                calRestAccum.append((s0, s1))
                if calRestAccum.count >= 30 {
                    let cx = calRestAccum.map(\.0).reduce(0, +) / Double(calRestAccum.count)
                    let cy = calRestAccum.map(\.1).reduce(0, +) / Double(calRestAccum.count)
                    calDraft = StickCal(cx: cx, cy: cy,
                                        rim: Array(repeating: 0, count: Self.calBins))
                    calPhase = .range
                }
            case .range:
                // Phase 2: the rim sweep — grow each angle bin's radius.
                if var d = calDraft {
                    let dx = s0 - d.cx, dy = s1 - d.cy
                    let r = (dx * dx + dy * dy).squareRoot()
                    if r >= Self.calMinRadius {
                        let idx = Int(Self.binPos(dx: dx, dy: dy,
                                                  bins: d.rim.count)) % d.rim.count
                        d.rim[idx] = max(d.rim[idx], r)
                        calDraft = d
                    }
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastHIDPublish > 0.1 {
                        lastHIDPublish = now
                        let swept = d.rim.filter { $0 >= Self.calMinRadius }.count
                        calInfo = String(format:
                            "rest (%.0f, %.0f) · rim %d/%d segments swept",
                            d.cx, d.cy, swept, d.rim.count)
                    }
                }
            case .idle:
                var x: Double, y: Double
                if let cal = stickCal {
                    (x, y) = Self.calMap(dx: s0 - cal.cx, dy: s1 - cal.cy, cal: cal)
                } else {
                    // Uncalibrated fallback: rest position from the
                    // first samples after attach + a typical span.
                    if hidStickCenter == nil {
                        hidCenterAccum.append((s0, s1))
                        if hidCenterAccum.count >= 24 {
                            let cx = hidCenterAccum.map(\.0).reduce(0, +) / Double(hidCenterAccum.count)
                            let cy = hidCenterAccum.map(\.1).reduce(0, +) / Double(hidCenterAccum.count)
                            hidStickCenter = (cx, cy)
                            hidCenterAccum = []
                        }
                    }
                    guard let c = hidStickCenter else { break }
                    x = min(max((s0 - c.x) / hidStickSpan, -1), 1)
                    y = min(max((s1 - c.y) / hidStickSpan, -1), 1)
                }
                handleStick(x: x, y: y)
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastHIDPublish > 0.066 {
                    lastHIDPublish = now
                    hidAxes = [x, y]
                }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// One controller at a time — the first to appear wins; later
    /// arrivals are ignored until it disconnects.
    private func attach(_ c: GCController) {
        guard attached == nil else { return }
        attached = c
        connectedName = c.vendorName ?? c.productCategory
        c.handlerQueue = .main
        let profile = c.physicalInputProfile

        // Element inventory: group the profile's names by the element
        // they actually refer to, so aliases read as one line.
        var groups: [ObjectIdentifier: [String]] = [:]
        for (name, el) in profile.elements {
            groups[ObjectIdentifier(el), default: []].append(name)
        }
        elementNames = groups.values
            .map { $0.sorted().joined(separator: " / ") }.sorted()
        NSLog("Tarabdaar: game controller attached — %@ [%@]",
              connectedName ?? "?", elementNames.joined(separator: ", "))

        // Raw event tap, display only — fires for EVERY element,
        // bound or not.
        profile.valueDidChangeHandler = { [weak self] _, element in
            self?.noteRawEvent(element)
        }

        let cat = c.productCategory
        rotateForUpright = cat.localizedCaseInsensitiveContains("joy-con")
            && !cat.localizedCaseInsensitiveContains("l/r")

        // The stick. A lone Joy-Con exposes it as the left thumbstick;
        // the right thumbstick covers a lone right Joy-Con, and the
        // last fallback covers a stick-only presentation that names it
        // Direction Pad alone.
        let stick = profile.dpads[GCInputLeftThumbstick]
            ?? profile.dpads[GCInputRightThumbstick]
            ?? profile.dpads[GCInputDirectionPad]
        stick?.valueChangedHandler = { [weak self] _, x, y in
            guard let self, !self.hidFullMode else { return }
            // (Once full mode streams, the raw HID stick drives the
            // tilts at 12-bit resolution — this digital hat stands down.)
            if self.rotateForUpright {
                // Sideways frame → upright: x = y_os, y = −x_os
                // (push printed-up reads sideways-left).
                self.handleStick(x: Double(y), y: Double(-x))
            } else {
                self.handleStick(x: Double(x), y: Double(y))
            }
        }

        // The four directional buttons: a d-pad element when one is
        // distinct from the stick, not its alias (see the alias trap
        // above)…
        if let dpad = profile.dpads[GCInputDirectionPad], dpad !== stick {
            bind(dpad.up, .dpadUp)
            bind(dpad.down, .dpadDown)
            bind(dpad.left, .dpadLeft)
            bind(dpad.right, .dpadRight)
        }
        // …and the A/B/X/Y of the sideways mini-gamepad presentation.
        // Upright grip: the diamond positions rotate 90° CCW, so the
        // sideways labels land on the printed arrows as A(right pos)=↓,
        // B(bottom)=←, X(top)=→, Y(left)=↑.
        if rotateForUpright {
            bind(profile.buttons[GCInputButtonA], .dpadDown)
            bind(profile.buttons[GCInputButtonB], .dpadLeft)
            bind(profile.buttons[GCInputButtonX], .dpadRight)
            bind(profile.buttons[GCInputButtonY], .dpadUp)
        } else {
            bind(profile.buttons[GCInputButtonA], .dpadRight)
            bind(profile.buttons[GCInputButtonB], .dpadDown)
            bind(profile.buttons[GCInputButtonX], .dpadUp)
            bind(profile.buttons[GCInputButtonY], .dpadLeft)
        }

        // The shoulder family. The sideways presentation names SL/SR
        // leftShoulder/rightShoulder; which names the physical L and ZL
        // get is presentation-dependent, so bind the whole family — the
        // panel's Last-event line identifies any that land oddly.
        bind(profile.buttons[GCInputLeftShoulder], .shoulder1)
        bind(profile.buttons[GCInputLeftTrigger],
             rotateForUpright ? .shoulder1 : .shoulder2)
        bind(profile.buttons[GCInputRightShoulder], .shoulder2)
        bind(profile.buttons[GCInputRightTrigger], .shoulder2)
    }

    private func detach() {
        attached = nil
        connectedName = nil
        stickX = 0; stickY = 0
        stickActive = false
        buttonsDown = []
        lastEvent = "—"
        elementNames = []
    }

    private func bind(_ button: GCControllerButtonInput?, _ control: Control) {
        button?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.setButton(control, pressed)
        }
    }

    /// Shared button funnel — GC bindings and the raw HID L/ZL bits
    /// both land here (main thread).
    private func setButton(_ control: Control, _ pressed: Bool) {
        if pressed { buttonsDown.insert(control) }
        else { buttonsDown.remove(control) }
        onButton?(control, pressed)
    }

    private var lastStickSent: (Double, Double)?

    /// Per-axis deflection gate: the neutral drifts, so |v| < 0.1 pins
    /// to exact centre, rescaled for continuity (0.1 → 0, full → ±1).
    private func gate(_ v: Double) -> Double {
        guard abs(v) >= deadzone else { return 0 }
        return (v - (v < 0 ? -deadzone : deadzone)) / (1 - deadzone)
    }

    /// The stick path → its own two axes (Stick X/Y). Gated, quantized
    /// (~9 bits), change-gated — a held or centred stick is silent (the
    /// centre value 0.5 is written exactly once on release).
    private func handleStick(x: Double, y: Double) {
        // Throttled monitor publish; the rest position always lands so
        // the readout never freezes mid-deflection.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastStickPublish > 0.066 || (x == 0 && y == 0) {
            lastStickPublish = now
            stickX = x
            stickY = y
        }
        let gx = gate(x)
        let gy = gate(y)
        let active = gx != 0 || gy != 0
        if active != stickActive { stickActive = active }
        func q(_ v: Double) -> Double { (v * 256).rounded() / 256 }
        let s = (q(gx), q(gy))
        if let l = lastStickSent, l == s { return }
        lastStickSent = s
        onStickAxes?((s.0 + 1) / 2, (s.1 + 1) / 2)
    }

    /// iPad raw-tilt in (MIDI thread — the only cross-thread entry).
    /// Returns true when the arm calibration CONSUMES the value (a
    /// calibration exists or is being captured) — the caller must then
    /// not pass it through to the axes directly. The capture and the
    /// live solve tick off this stream (hopped to main), so they need
    /// nothing from the Joy-Con.
    func feedArmTilt(_ axis: Int, _ value01: Double) -> Bool {
        armLock.lock()
        if axis >= 0, axis < 3 {
            armTilt[axis] = value01
            armTime = CFAbsoluteTimeGetCurrent()
        }
        let consumed = bodyCalActiveFlag
        let f = [armTilt.x, armTilt.y, armTilt.z]
        armLock.unlock()
        // Always tick — even when nothing consumes the value, the tick
        // feeds the Setup panel's raw-stream scope and the marker.
        DispatchQueue.main.async { [weak self] in self?.armTick(f) }
        return consumed
    }

    /// One arm-stream tick on the main thread: append to the running
    /// capture phase, or solve and drive the three calibrated arm axes.
    private func armTick(_ f: [Double]) {
        let now = CFAbsoluteTimeGetCurrent()
        let raw = SIMD3(f[0], f[1], f[2])
        let newFrame = now - lastArmMsgT >= Self.frameGap
        lastArmMsgT = now
        if newFrame { armSmoothPrev = armSmooth ?? raw }
        let base = armSmoothPrev ?? raw
        let sm = base + (raw - base) * Self.armSmoothAlpha
        armSmooth = sm
        let fs = [sm.x, sm.y, sm.z]
        let sample = RawTiltSample(t: now, raw: raw)
        if newFrame || rawBuf.isEmpty {
            rawBuf.append(sample)
        } else {
            rawBuf[rawBuf.count - 1] = sample
        }
        if let first = rawBuf.first, first.t < now - Self.traceWindow {
            rawBuf.removeAll { $0.t < now - Self.traceWindow }
        }
        if !traceActive { traceActive = true }
        if let step = bodyCalStep {
            if newFrame || calSamples[step].isEmpty {
                calSamples[step].append(fs)
            } else {
                calSamples[step][calSamples[step].count - 1] = fs
            }
            let count = calSamples[step].count
            if count % 15 == 0 {
                let need = step == 0 ? 20 : 30
                bodyCalInfo = Self.bodyCalStepNames[step]
                    + (count >= need ? "  (\(count) samples ✓)"
                                     : "  (\(count) of \(need) samples)")
            }
            if now - lastCloudPublish > 0.05 {
                lastCloudPublish = now
                publishCloud()
            }
            return
        }
        guard let cal = bodyCal else { return }
        let n = Self.armDims
        var out = [Double](repeating: 0.5, count: n)
        for k in 0..<n {
            var c = 0.0
            for i in 0..<n { c += cal.m[k][i] * (fs[i] - cal.f0[i]) }
            out[k] = c >= 0 ? 0.5 + 0.5 * min(c / cal.hi[k], 1)
                            : 0.5 - 0.5 * min(c / cal.lo[k], 1)
        }
        let q = out.map { ($0 * 256).rounded() / 256 }
        if q != lastBodySent {
            lastBodySent = q
            onArmAxes?(q[0], q[1], q[2])
        }
        if now - lastBodyPublish > 0.1 {
            lastBodyPublish = now
            bodyTilts = q
        }
    }

    /// Snapshot `calSamples` for the 3D scatter, decimated to ≤600
    /// points per phase (display only — the fit keeps every sample).
    private func publishCloud() {
        calCloud = calSamples.map { phase in
            let step = max(1, phase.count / 600)
            return phase.enumerated().compactMap { i, s in
                i % step == 0 ? SIMD3(s[0], s[1], s[2]) : nil
            }
        }
    }

    /// Recompute the MIDI-thread-readable consume flag: the calibration
    /// owns the iPad's tilt values whenever one exists OR one is being
    /// captured.
    private func refreshArmConsumeFlag() {
        armLock.lock()
        bodyCalActiveFlag = bodyCal != nil || bodyCalStep != nil
        armLock.unlock()
    }

    // MARK: Arm calibration control (panel buttons + dpad-up/down)

    func beginBodyCalibration() {
        calSamples = Array(repeating: [], count: 4)
        calDirs = [nil, nil, nil]
        calRestMean = nil
        bodyCalDetail = ""
        bodyCalStep = 0
        bodyCalInfo = Self.bodyCalStepNames[0]
        publishCloud()
        refreshArmConsumeFlag()
    }

    /// Advance to the next phase; after the last sweep, fit. Also on
    /// dpad-up, so the controller hand can step through alone. A phase
    /// that hasn't captured enough samples refuses to advance (the fit
    /// would discard the whole run at the end anyway) and says why;
    /// each completed sweep gets an instant verdict (`evaluateSweep`)
    /// so a doomed run is visible long before the fit.
    func advanceBodyCalibration() {
        guard let step = bodyCalStep else { return }
        let need = step == 0 ? 20 : 30
        guard calSamples[step].count >= need else {
            bodyCalDetail = "⚠ Can't advance — only \(calSamples[step].count) of \(need) samples; if the count isn't rising, the iPad tilt stream isn't flowing"
            return
        }
        let n = Self.armDims
        if step == 0 {
            var mean = [Double](repeating: 0, count: n)
            for s in calSamples[0] { for i in 0..<n { mean[i] += s[i] } }
            for i in 0..<n { mean[i] /= Double(calSamples[0].count) }
            calRestMean = mean
            bodyCalDetail = "✓ Rest captured (\(calSamples[0].count) samples)"
        } else if !evaluateSweep(step) {
            // A fatally bad sweep (one-sided, or a near-duplicate of an
            // earlier one) redoes ITSELF immediately — continuing the
            // remaining phases would only postpone the discard to the
            // fit. Samples clear; the phase prompt stays.
            calSamples[step] = []
            bodyCalInfo = Self.bodyCalStepNames[step] + "  — REDO"
            publishCloud()
            return
        }
        if step < 3 {
            bodyCalStep = step + 1
            bodyCalInfo = Self.bodyCalStepNames[step + 1]
        } else {
            bodyCalStep = nil
            fitBodyCalibration()
        }
        refreshArmConsumeFlag()
    }

    /// Verdict when a sweep phase ends: its dominant movement direction,
    /// whether it returned to rest, whether it crossed rest both ways,
    /// and how aligned it is with the sweeps already captured. Returns
    /// false when the sweep must be REDONE (the caller clears it and
    /// stays on the phase). Extents are measured against the sweep's OWN
    /// start/end rest readings, not the phase-0 rest — the rest pose
    /// drifts slightly between phases, and judging against a stale rest
    /// is how a genuine both-ways sweep used to read one-sided. ≥95%
    /// alignment with an earlier sweep also fails; 80–95% warns but
    /// advances (some alignment is physically expected — the three arm
    /// motions overlap in attitude space). The fit re-derives everything
    /// jointly; this is the early exit, not the authority.
    private func evaluateSweep(_ step: Int) -> Bool {
        let idx = step - 1
        let name = Self.bodyCalSweepNames[idx]
        let samples = calSamples[step]
        let (startRest, endRest) = Self.restWindowMeans(of: samples)
        // The sweep's rest reference: whichever of its start/end windows
        // sits closer to the phase-0 rest. Ending back at rest is GOOD
        // PRACTICE, not a requirement — a player who can't reproduce
        // the exact rest pose after a sweep must not be forced to redo;
        // the off-rest reading is simply ignored (the fit re-picks
        // against the robust merged rest).
        let anchor = calRestMean ?? startRest
        let startOff = Self.dist(startRest, anchor)
        let endOff = Self.dist(endRest, anchor)
        let local = startOff <= endOff ? startRest : endRest
        let dir = Self.dominantDirection(of: samples)
        var lo = 0.0, hi = 0.0
        for s in samples {
            var c = 0.0
            for i in 0..<dir.count { c += dir[i] * (s[i] - local[i]) }
            lo = min(lo, c)
            hi = max(hi, c)
        }
        guard hi > 0.02, -lo > 0.02 else {
            calDirs[idx] = nil
            bodyCalDetail = String(
                format: "⚠ %@ was one-sided about its rest (%+.3f / %+.3f, need ±0.02) — redo, sweeping past the rest pose both ways; if rest sits at one end of this motion's range, the motion can't calibrate.",
                name, lo, hi)
            return false
        }
        var worst = 0.0
        var worstIdx = -1
        for j in 0..<idx {
            guard let other = calDirs[j] else { continue }
            let cos = Self.alignment(dir, other)
            if cos > worst { worst = cos; worstIdx = j }
        }
        let pct = Int((worst * 100).rounded())
        if worstIdx >= 0, worst >= 0.95 {
            calDirs[idx] = nil
            bodyCalDetail = "⚠ \(name) was \(pct)% aligned with \(Self.bodyCalSweepNames[worstIdx]) — near-identical movements can't be separated; redo with a distinct motion (or Cancel if \(Self.bodyCalSweepNames[worstIdx]) was the bad capture)"
            return false
        }
        calDirs[idx] = dir
        var msg = "\(name) captured (\(calSamples[step].count) samples)"
        if max(startOff, endOff) > 0.05 {
            msg += String(
                format: ", %@ sat %.3f off rest (fine — using the %@ reading)",
                startOff > endOff ? "start" : "end", max(startOff, endOff),
                startOff > endOff ? "end" : "start")
        }
        var warning = ""
        if worstIdx >= 0 {
            if worst >= 0.8 {
                warning = "\(pct)% aligned with \(Self.bodyCalSweepNames[worstIdx]) — separable, but the axes will cross-talk; consider Cancel and a cleaner run"
            } else {
                msg += ", closest to \(Self.bodyCalSweepNames[worstIdx]) at \(pct)%"
            }
        }
        bodyCalDetail = warning.isEmpty ? "✓ \(msg)" : "⚠ \(msg) — \(warning)"
        return true
    }

    /// |cos| between two direction vectors, defensively normalized.
    private static func alignment(_ a: [Double], _ b: [Double]) -> Double {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let la = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        let lb = (b.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard la > 1e-12, lb > 1e-12 else { return 0 }
        return abs(dot / (la * lb))
    }

    /// Step BACK one phase and re-capture it — the current phase's
    /// partial samples and the previous phase's samples are cleared,
    /// everything captured before them stands. Dpad-down during a
    /// running calibration triggers this too (mirror of dpad-up =
    /// advance), so the controller hand can back up alone.
    func redoPreviousBodyCalibrationStep() {
        guard let step = bodyCalStep, step > 0 else { return }
        calSamples[step] = []
        calSamples[step - 1] = []
        if step == 1 {
            calRestMean = nil
        } else {
            calDirs[step - 2] = nil
        }
        bodyCalStep = step - 1
        bodyCalInfo = Self.bodyCalStepNames[step - 1] + "  — redo"
        bodyCalDetail = ""
        publishCloud()
        refreshArmConsumeFlag()
    }

    func cancelBodyCalibration() {
        bodyCalStep = nil
        calSamples = []
        bodyCalDetail = ""
        bodyCalInfo = bodyCal != nil ? "Calibrated" : ""
        refreshArmConsumeFlag()
    }

    /// Quick re-zero (ZL): the CURRENT pose becomes rest (0.5 on all
    /// three arm axes) without re-fitting the directions.
    func recenterBody() {
        guard var cal = bodyCal else { return }
        // Prefer the smoothed vector — a re-zero on a raw sample would
        // bake up to ±2 quantization steps of flicker into f0.
        let arm: SIMD3<Double>
        if let sm = armSmooth {
            arm = sm
        } else {
            armLock.lock()
            arm = armTilt
            armLock.unlock()
        }
        cal.f0 = [arm.x, arm.y, arm.z]
        bodyCal = cal
        calViz?.f0 = arm
        persistBodyCal()
    }

    private func persistBodyCal() {
        if let cal = bodyCal, let data = try? JSONEncoder().encode(cal) {
            UserDefaults.standard.set(data, forKey: Self.bodyCalKey)
        }
    }

    /// Fit the joint 4-axis map from the recorded phases. Directions by
    /// PCA per sweep, cross-talk removed by the joint pseudo-inverse,
    /// extents measured through the final solve (so they include the
    /// cross-talk correction), signs oriented so each sweep's dominant
    /// side is positive.
    private func fitBodyCalibration() {
        let n = Self.armDims
        let rest = calSamples[0]
        guard rest.count >= 20 else {
            bodyCalInfo = "Discarded — rest phase too short"
            refreshArmConsumeFlag()
            return
        }
        // The rest pose is measured SEVEN times — the rest phase plus
        // each sweep's start and end windows — and merged ROBUSTLY:
        // component-wise median, then the mean of the readings that
        // agree with it. A player who doesn't reliably return to the
        // exact rest pose leaves off-rest readings in the set; they get
        // rejected as outliers instead of biasing f0 or failing the
        // capture. Each sweep's extents are then measured against its
        // own nearest inlier reading (start or end; merged f0 if
        // neither qualifies).
        var readings: [[Double]] = []
        var mean0 = [Double](repeating: 0, count: n)
        for s in rest { for i in 0..<n { mean0[i] += s[i] } }
        for i in 0..<n { mean0[i] /= Double(rest.count) }
        readings.append(mean0)

        var dirs: [[Double]] = []
        var windows: [(start: [Double], end: [Double])] = []
        for k in 1...n {
            let sweep = calSamples[k]
            guard sweep.count >= 30 else {
                bodyCalInfo = "Discarded — sweep \(k) (\(Self.bodyCalSweepNames[k - 1])) too short (\(sweep.count) of 30 samples)"
                refreshArmConsumeFlag()
                return
            }
            dirs.append(Self.dominantDirection(of: sweep))
            let w = Self.restWindowMeans(of: sweep)
            windows.append(w)
            readings.append(w.start)
            readings.append(w.end)
        }

        var med = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let col = readings.map { $0[i] }.sorted()
            med[i] = col[col.count / 2]
        }
        let dists = readings.map { Self.dist($0, med) }
        let tol = max(0.05, 2 * dists.sorted()[dists.count / 2])
        let inliers = zip(readings, dists).filter { $0.1 <= tol }.map { $0.0 }
        var f0 = [Double](repeating: 0, count: n)
        for e in inliers { for i in 0..<n { f0[i] += e[i] } }
        for i in 0..<n { f0[i] /= Double(max(inliers.count, 1)) }
        if inliers.isEmpty { f0 = med }
        var restSpread = 0.0
        for e in inliers { restSpread = max(restSpread, Self.dist(e, f0)) }
        let rejected = readings.count - max(inliers.count, 1)

        var localRests: [[Double]] = []
        for w in windows {
            let ds = Self.dist(w.start, f0)
            let de = Self.dist(w.end, f0)
            let best = ds <= de ? w.start : w.end
            localRests.append(min(ds, de) <= tol ? best : f0)
        }

        // Name the failure before it becomes a numerical one: the most-
        // aligned pair of sweep directions. Some alignment is expected
        // (the three arm motions overlap in attitude space); past ~95%
        // the joint solve amplifies cross-talk ~10× and the fit is junk
        // — the Gram inversion below fails only at near-exact parallels,
        // so it stays as the last-resort backstop.
        var worst = 0.0
        var worstA = 0
        var worstB = 1
        for a in 0..<n {
            for b in (a + 1)..<n {
                let cos = Self.alignment(dirs[a], dirs[b])
                if cos > worst { worst = cos; worstA = a; worstB = b }
            }
        }
        let worstPct = Int((worst * 100).rounded())
        let worstPair = "sweeps \(worstA + 1) (\(Self.bodyCalSweepNames[worstA])) and \(worstB + 1) (\(Self.bodyCalSweepNames[worstB]))"

        var gram = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for a in 0..<n {
            for b in 0..<n {
                gram[a][b] = zip(dirs[a], dirs[b]).reduce(0) { $0 + $1.0 * $1.1 }
            }
        }
        let gramInverse = Self.invert(gram)
        guard worst < 0.95, let gInv = gramInverse else {
            bodyCalInfo = "Discarded — \(worstPair) were nearly identical movements (\(worstPct)% aligned)"
            bodyCalDetail = "Redo with more distinct motions — three clearly different arm movements (up/down, in/out, rotation)"
            refreshArmConsumeFlag()
            return
        }
        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for k in 0..<n {
            for i in 0..<n {
                for a in 0..<n { m[k][i] += gInv[k][a] * dirs[a][i] }
            }
        }

        var lo = [Double](repeating: 0, count: n)
        var hi = [Double](repeating: 0, count: n)
        var flipped = [Bool](repeating: false, count: n)
        for k in 0..<n {
            // Extents about the sweep's own local rest — robust to the
            // rest pose drifting between phases.
            for s in calSamples[k + 1] {
                var c = 0.0
                for i in 0..<n { c += m[k][i] * (s[i] - localRests[k][i]) }
                lo[k] = min(lo[k], c)
                hi[k] = max(hi[k], c)
            }
            if -lo[k] > hi[k] {          // dominant side positive
                for i in 0..<n { m[k][i] = -m[k][i] }
                (lo[k], hi[k]) = (-hi[k], -lo[k])
                flipped[k] = true        // keep the viz direction in step
            }
            guard hi[k] > 0.02, lo[k] < -0.02 else {
                bodyCalInfo = "Discarded — sweep \(k + 1) (\(Self.bodyCalSweepNames[k])) didn't move both ways from rest"
                bodyCalDetail = "Each sweep must cross the rest pose in both directions — e.g. ARM ↕ goes above AND below where the arm rested"
                refreshArmConsumeFlag()
                return
            }
        }

        bodyCal = BodyCal(f0: f0, m: m, lo: lo, hi: hi)
        calViz = CalViz(
            f0: SIMD3(f0[0], f0[1], f0[2]),
            axes: (0..<n).map { k in
                let sign = flipped[k] ? -1.0 : 1.0
                return (SIMD3(dirs[k][0], dirs[k][1], dirs[k][2]) * sign,
                        lo[k], hi[k])
            })
        persistBodyCal()
        calSamples = []
        bodyCalInfo = String(
            format: "Calibrated · extents %@",
            (0..<n).map { String(format: "%.2f/%.2f", -lo[$0], hi[$0]) }
                .joined(separator: "  "))
        bodyCalDetail = String(
            format: "Axis separation: closest sweep pair %@ at %d%% aligned (lower separates more cleanly) · rest: %d of %d readings agreed (±%.3f)%@",
            worstPair, worstPct, readings.count - rejected, readings.count,
            restSpread,
            rejected > 0 ? ", \(rejected) off-rest reading\(rejected == 1 ? "" : "s") ignored" : "")
        NSLog("Tarabdaar: arm calibration fitted — %@ · %@",
              bodyCalInfo, bodyCalDetail)
        refreshArmConsumeFlag()
    }

    /// Dominant movement direction of a sample cloud — the covariance's
    /// top eigenvector by power iteration, taken about the cloud's OWN
    /// mean. About-the-mean is load-bearing: the original code took the
    /// covariance about the REST pose, so a sweep whose average pose sat
    /// even slightly off rest (postural settling between phases, drift)
    /// had a constant-offset term N·(μ−f0)(μ−f0)ᵀ that outweighed the
    /// motion's scatter, rotating the "direction" toward the offset —
    /// and a genuine both-ways sweep then projected strictly one-sided
    /// (the "+0.000 / +0.395" failure). Unit length for any cloud with
    /// spread; a degenerate (motionless) cloud returns the un-normalized
    /// all-ones seed, which the extent checks and Gram backstop reject
    /// downstream.
    private static func dominantDirection(of samples: [[Double]]) -> [Double] {
        let n = samples.first?.count ?? armDims
        var mean = [Double](repeating: 0, count: n)
        for s in samples { for i in 0..<n { mean[i] += s[i] } }
        for i in 0..<n { mean[i] /= Double(max(samples.count, 1)) }
        var cov = [Double](repeating: 0, count: n * n)
        for s in samples {
            for i in 0..<n {
                let di = s[i] - mean[i]
                for j in 0..<n { cov[i * n + j] += di * (s[j] - mean[j]) }
            }
        }
        var v = [Double](repeating: 1, count: n)
        for _ in 0..<100 {
            var w = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in 0..<n { w[i] += cov[i * n + j] * v[j] }
            }
            let len = (w.reduce(0) { $0 + $1 * $1 }).squareRoot()
            guard len > 1e-12 else { break }
            v = w.map { $0 / len }
        }
        return v
    }

    /// n×n inverse by Gauss-Jordan with partial pivoting.
    private static func invert(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        var m = a
        var inv = (0..<n).map { r in
            (0..<n).map { c in r == c ? 1.0 : 0.0 }
        }
        for col in 0..<n {
            var p = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[p][col]) { p = r }
            guard abs(m[p][col]) > 1e-9 else { return nil }
            m.swapAt(col, p)
            inv.swapAt(col, p)
            let d = m[col][col]
            for j in 0..<n {
                m[col][j] /= d
                inv[col][j] /= d
            }
            for r in 0..<n where r != col {
                let f = m[r][col]
                guard f != 0 else { continue }
                for j in 0..<n {
                    m[r][j] -= f * m[col][j]
                    inv[r][j] -= f * inv[col][j]
                }
            }
        }
        return inv
    }

    /// One fused IMU step (accel raw units — only its direction is
    /// used; gyro rad/s). Keeps the gravity estimate warm for the
    /// panel/telemetry; the tilt pipeline no longer consumes it — the
    /// arm calibration runs entirely on the iPad's tilt stream
    /// (`armTick`), and the 2026-08-12 wrist axes are gone.
    private func processIMU(accel: SIMD3<Double>, gyroRadPerSec: SIMD3<Double>) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(max(now - lastIMUTime, 0.001), 0.1)
        lastIMUTime = now
        guard simd_length(accel) > 1 else { return }
        // Gyro-bias learner: converge on the reading while still.
        if simd_length(gyroRadPerSec - gyroBias) < 0.05 {
            gyroBias += (gyroRadPerSec - gyroBias) * 0.02
        }
        let w = gyroRadPerSec - gyroBias
        let aN = simd_normalize(accel)
        var g = gHat ?? aN
        g = simd_normalize(g + simd_cross(g, w) * dt)   // ġ = g × ω
        g = simd_normalize(g + (aN - g) * 0.02)         // accel pull
        gHat = g
        yaw += simd_dot(w, g) * dt
    }

    private func noteRawEvent(_ element: GCControllerElement) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEventPublish > 0.066 else { return }
        lastEventPublish = now
        let name = element.localizedName ?? element.aliases.first ?? "?"
        if let d = element as? GCControllerDirectionPad {
            lastEvent = String(format: "%@  x %+.2f  y %+.2f",
                               name, d.xAxis.value, d.yAxis.value)
        } else if let b = element as? GCControllerButtonInput {
            lastEvent = String(format: "%@  %@ (%.2f)",
                               name, b.isPressed ? "down" : "up", b.value)
        } else {
            lastEvent = name
        }
    }
}

/// CoreBluetooth client for Switch 2 Joy-Cons (2026-08-11). Joy-Con 2
/// are BLE-only with a vendor GATT protocol — macOS cannot pair them
/// (they never appear in Bluetooth settings) and neither GameController
/// nor IOHID sees them, so this client owns the whole connection: scan
/// broadly, filter on Nintendo's manufacturer-data company ID (0x057E),
/// connect, subscribe to the vendor input characteristic, forward every
/// notification. First connection needs the Joy-Con advertising — hold
/// its small sync button (on the rail). One peripheral at a time;
/// rescans whenever powered on and unconnected. Delegate callbacks on
/// the main queue. Protocol constants per Nohzockt/Switch2-Controllers.
final class JoyCon2BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
    static let inputCharacteristic = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")
    /// The `0x91`-framed command channel (per trevlars/switch2-controllers-linux
    /// — the classic `30 …` subcommand format is IGNORED by Joy-Con 2):
    /// commands write here, acks arrive on the response characteristic.
    static let commandWriteCharacteristic =
        CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")
    static let commandResponseCharacteristic =
        CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A")
    /// Nintendo's Bluetooth SIG company identifier — NOT 0x057E, which
    /// is their USB vendor ID and appears further into the payload
    /// (measured from a live Joy-Con 2 (L) advertisement:
    /// `53 05 01 00 03 7e 05 67 20 …` — company 0x0553, then VID
    /// 0x057E + PID 0x2067, name empty).
    private static let nintendoCompanyID: UInt16 = 0x0553

    var onStatus: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onNotification: ((Data) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The service's write characteristic — commands (player LED) go
    /// here.
    private var outputCharacteristic: CBCharacteristic?
    private var ledSent = false

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: scan()
        case .unauthorized: onStatus?("Bluetooth permission denied — grant in System Settings ▸ Privacy")
        case .poweredOff: onStatus?("Bluetooth is off")
        default: onStatus?("Bluetooth unavailable")
        }
    }

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil
        else { return }
        // The advertisement doesn't list the vendor service, so scan
        // broadly and filter in didDiscover.
        central.scanForPeripherals(withServices: nil)
        onStatus?("scanning — hold the Joy-Con 2 sync button")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        var nintendo = false
        if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            let bytes = [UInt8](m)
            let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            nintendo = company == Self.nintendoCompanyID
        }
        // Name fallback only — a live Joy-Con 2 advertises with an
        // EMPTY name, so the manufacturer data is the real filter.
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "")
        if !nintendo {
            nintendo = name.localizedCaseInsensitiveContains("joy-con")
        }
        guard nintendo, peripheral == nil else { return }
        peripheral = p
        c.stopScan()
        onStatus?("connecting — \(name.isEmpty ? "Joy-Con 2" : name)")
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                        error: Error?) {
        peripheral = nil
        onStatus?("connect failed — \(error?.localizedDescription ?? "?")")
        scan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        peripheral = nil
        outputCharacteristic = nil
        ledSent = false
        onDisconnect?()
        onStatus?("disconnected")
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        guard services.contains(where: { $0.uuid == Self.service }) else {
            // A Nintendo BLE device without the vendor service (or a
            // stray company-ID match) — drop it and keep scanning.
            onStatus?("no Joy-Con 2 input service — skipping \(p.name ?? "device")")
            central?.cancelPeripheralConnection(p)
            return
        }
        // The command channel may live in a different service than the
        // input — sweep them all.
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.inputCharacteristic:
                p.setNotifyValue(true, for: ch)
                onConnect?(p.name ?? "Joy-Con 2")
            case Self.commandResponseCharacteristic:
                // Subscribe before commanding — acks land here.
                p.setNotifyValue(true, for: ch)
            case Self.commandWriteCharacteristic:
                outputCharacteristic = ch
                ledSent = false
                // Give the response-CCCD subscribe a beat to land.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.setPlayerLED(1)
                    self?.enableFeatures()
                }
            default:
                break
            }
        }
    }

    /// Assign the player-number LEDs — without this the controller
    /// stays "unassigned" and the lights race forever. Joy-Con 2 use
    /// the `0x91` command framing on the dedicated command
    /// characteristic: `09 91 01 07 00 <len> 00 00 <pattern…>`
    /// (command 0x09 = LEDs, subcommand 0x07 = set player), pattern
    /// 0x01 = player 1.
    private func setPlayerLED(_ player: Int) {
        let patterns: [UInt8] = [0x01, 0x03, 0x07, 0x0F, 0x09, 0x05, 0x0D, 0x06]
        writeCommand(0x09, 0x07,
                     [patterns[max(0, min(7, player - 1))], 0x00, 0x00, 0x00])
        ledSent = true
    }

    /// Feature init + enable with the motion flag — without it the
    /// notification's IMU fields stay zero. Flags 0x03 | 0x04 (motion),
    /// per the Linux driver's initialize().
    private func enableFeatures() {
        let flags: [UInt8] = [0x07, 0x00, 0x00, 0x00]
        writeCommand(0x0C, 0x02, flags)   // SUBCOMMAND_FEATURE_INIT
        writeCommand(0x0C, 0x04, flags)   // SUBCOMMAND_FEATURE_ENABLE
    }

    /// One `0x91`-framed command:
    /// `<cmd> 91 01 <sub> 00 <len> 00 00 <payload…>`.
    private func writeCommand(_ command: UInt8, _ subcommand: UInt8,
                              _ payload: [UInt8]) {
        guard let p = peripheral, let ch = outputCharacteristic else { return }
        let cmd: [UInt8] = [command, 0x91, 0x01, subcommand, 0x00,
                            UInt8(payload.count), 0x00, 0x00] + payload
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse
                                                          : .withResponse
        p.writeValue(Data(cmd), for: ch, type: type)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        guard ch.uuid == Self.inputCharacteristic else { return }
        // Belt-and-suspenders: if the LED write raced discovery,
        // re-send once real input is flowing.
        if !ledSent, outputCharacteristic != nil {
            setPlayerLED(1)
            enableFeatures()
        }
        if let d = ch.value { onNotification?(d) }
    }
}
