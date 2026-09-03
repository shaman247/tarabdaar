import Combine
import CoreBluetooth
import Foundation
import GameController
import TarabdaarCore
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
/// **Two input reports (2026-09-02, per ndeadly/switch2_controller_research):**
/// the standard characteristic …7FD2 carries the COMMON report 0x05
/// (buttons 4–7, sticks 0x0A/0x0D, mag 0x19, motion block at 0x2A
/// with accel i16×3 at 0x30 + gyro at 0x36 — the layout parsed here),
/// and CC1BBBB5-… is the Joy-Con 2 (L)'s OWN report 0x07 (buttons
/// 2–3, stick 5–7, a motion-LENGTH byte at 0x0E and a 40-byte PACKED
/// motion blob at 0x0F whose encoding is undocumented). A real Joy-Con
/// 2 streams report 0x07 INSTEAD of 0x05 the moment 0x07 is
/// subscribed — the 2026-08-21 subscribe-everything probe did exactly
/// that ~1 s before the standard subscribe, so a first-party
/// controller was parsed by the clone path with report-0x05 IMU
/// offsets inside the packed blob (±6 g at rest, gyro y/z pinned at
/// zero, a magnetometer web). So `JoyCon2BLE` subscribes ONLY …7FD2
/// first and enables the controller-specific characteristic as a
/// fallback after `altFallbackDelay` of silence.
///
/// **Third-party Switch 2 clones (2026-08-21, Mobacon):** impersonate
/// a Joy-Con 2 byte-perfectly (advertisement AND characteristic
/// inventory) but ignore all 0x91 commands, stream nothing on the
/// standard input characteristic (then drop the link after 60 s), and
/// stream report 0x07 on CC1BBBB5-… with no handshake at all — that
/// is what the fallback subscribe is for. Its notifications forward
/// to `bleAltNotification`, whose header documents the measured
/// layout. No IMU — the clone's motion length stays zero.
///
/// Handlers fire on the main queue; the host's funnels are thread-safe.
final class JoyConInput: ObservableObject {

    /// The controller's buttons, named by position on an upright left
    /// Joy-Con. A sideways grip's A/B/X/Y map onto the same four
    /// directional controls by their physical placement.
    enum Control: String, CaseIterable {
        case dpadUp = "Up", dpadDown = "Down"
        case dpadLeft = "Left", dpadRight = "Right"
        /// The four shoulder-family buttons, DISTINCT since 2026-08-21
        /// (they were merged as L·SL / ZL·SR before — the raw reports
        /// always carried separate bits, and the Mobapad's ergonomics
        /// make the split worth having). L and ZL carry the default
        /// actions (strum, re-zero); SL and SR are unassigned.
        case l = "L", zl = "ZL"
        case sl = "SL", sr = "SR"
        /// The remaining reported inputs (2026-08-21): stick click,
        /// Minus, Capture — unassigned, surfaced as panel chips. (The
        /// Mobapad's M2 mirrors L on the wire and its brightness
        /// button never reports, so neither can appear here.)
        case stickClick = "Stick", minus = "Minus", capture = "Capture"
    }

    /// THE ARM AXES (2026-08-13): the calibrated three-dimension output
    /// — arm ↕, arm ↔, arm ⟲, each −1…+1 (rest = 0, sweep extremes ±1;
    /// the app-wide tilt convention since 2026-08-18) — from the joint
    /// solve over the iPad's raw tilt report (`armTick` → `armCal`).
    /// Non-perpendicular sweeps are separated by the least-squares
    /// solve, which attributes shared attitude motion to whichever
    /// calibrated movement direction explains it. Change-gated +
    /// quantized. (The 2026-08-12 wrist half — Joy-Con gravity features,
    /// wrist sweeps, tilt4 — was removed 2026-08-13.)
    var onArmAxes: ((Double, Double, Double) -> Void)?
    /// The stick as its own two axes (−1…+1, centre 0), per-axis
    /// gate + rescale, change-gated. No ownership/priority — every axis
    /// has exactly one source now.
    var onStickAxes: ((Double, Double) -> Void)?
    var onButton: ((_ control: Control, _ pressed: Bool) -> Void)?
    /// WRIST display (2026-08-18): the Joy-Con's fused attitude as three
    /// −1…+1 display axes (pitch/roll at ±90° full scale, yaw wrapped at
    /// ±180°; centre 0) for the iPad's wrist square. ~10 Hz, main
    /// thread; nil = fusion gone (Joy-Con detached). Display only —
    /// nothing binds to these.
    var onWristAttitude: (((Double, Double, Double)?) -> Void)?
    /// THE WRIST CONTROL AXES (2026-09-02): wrist ↕, ↔, ⟲ (−1…+1, rest
    /// 0) from the wrist `TiltCalibrator` over the Joy-Con's fused
    /// attitude — fires only while a wrist calibration exists;
    /// change-gated + quantized like the arm axes. Main thread.
    var onWristAxes: ((Double, Double, Double) -> Void)?
    /// JOY-CON ACCELERATION (2026-09-02): the gravity-removed
    /// acceleration magnitude through the strike law + envelope, 0…1
    /// (unipolar — the host maps it onto its axis), change-gated at
    /// 1/256, every IMU packet. Main thread. 0 on detach.
    var onJoyConAccel: ((Double) -> Void)?

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
    // 9-AXIS (2026-08-15, Joy-Con 2 only — classic Joy-Cons have no
    // magnetometer). The mag pins the one axis the 6-axis filter can't:
    // yaw. Hard-iron offset is learned as the running min/max midpoint
    // (needs rotation coverage — the standard figure-eight compass
    // dance; until the seen extremes span most of the field sphere the
    // mag is IGNORED and yaw stays gyro-integrated). The corrected
    // field's horizontal component drives a body-frame north estimate
    // `nHat`, propagated by the same ṅ = n × ω law as gravity, and yaw
    // is pulled gently toward the mag heading — gyro-smooth short-term,
    // drift-free long-term.
    private var nHat: SIMD3<Double>?
    private var magMin: SIMD3<Double>?
    private var magMax: SIMD3<Double>?
    /// Fused attitude for the panel (~10 Hz): [pitch°, roll°, yaw°].
    /// Convention: roll = atan2(gy, gz), pitch = atan2(−gx, √(gy²+gz²))
    /// from the gravity estimate; yaw = heading of the device x-axis
    /// about gravity (mag-pinned when `yawPinned`, integrated
    /// otherwise). Display/verification only — nothing downstream
    /// consumes it yet.
    @Published private(set) var fusedAttitude: [Double] = []
    /// True once the magnetometer's hard-iron estimate is trusted and
    /// yaw is being corrected toward magnetic heading.
    @Published private(set) var yawPinned = false
    private var lastFusedPublish: CFAbsoluteTime = 0

    // TILT CALIBRATIONS (2026-09-02): two `TiltCalibrator`s (the guided
    // rest + three-sweep capture, PCA per sweep, joint least squares,
    // robust rest merge — the machinery of the 2026-08-13 arm
    // calibration, moved into TarabdaarCore so it can run twice). The
    // ARM: the iPad's raw tilt report (`feedArmTilt` → `armTick`; no
    // Joy-Con involvement). The WRIST: the Joy-Con's fused attitude —
    // gravity pitch/roll + drift-learned relative yaw — ticked from
    // `processIMU` every IMU packet. The 2026-08-12 joint R⁶ arm+wrist
    // solve is NOT back: the wrist is an INDEPENDENT capture on the
    // Joy-Con's own stream. Each calibrator's published state is
    // forwarded into this object's `objectWillChange` so the Setup
    // panels, which observe `JoyConInput`, update.
    let armCal = TiltCalibrator(config: .arm)
    let wristCal = TiltCalibrator(config: .wrist)
    private var calSinks: [AnyCancellable] = []
    private var lastArmMsgT: CFAbsoluteTime = 0
    /// The latest wrist axes (calibrated only) — the iPad's wrist
    /// square shows these instead of the raw attitude once calibrated.
    private var lastWristAxes: (Double, Double, Double)?
    /// The wrist feature's RELATIVE yaw: the fused yaw's wrap-safe
    /// increments, drift-rate-learned while quiescent (rate under
    /// ~0.57°/s, ~10 s constant) and leaked toward zero with a 60 s
    /// constant — the iPad's tilt-3 law (`MotionManager.updateYaw`), so
    /// an unpinned gyro yaw can't rail the wrist axis and a held twist
    /// re-centres over ~a minute (ZL re-zero stays instant).
    private var yawRel = 0.0
    private var yawRelBias = 0.0
    private var lastFusedYaw: Double?
    private static let yawLeakTau = 60.0
    /// The Joy-Con acceleration envelope (0…1) + its change gate.
    private var jcAccelEnv = 0.0
    private var lastJcAccelSent = 0.0
    /// Panel readout of the envelope (~10 Hz).
    @Published private(set) var joyConAccelLevel = 0.0

    init() {
        for cal in [armCal, wristCal] {
            cal.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &calSinks)
        }
        armCal.onAxes = { [weak self] a, b, c in self?.onArmAxes?(a, b, c) }
        wristCal.onAxes = { [weak self] a, b, c in
            guard let self else { return }
            self.lastWristAxes = (a, b, c)
            self.onWristAxes?(a, b, c)
        }
    }

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
    /// FUSED trails (2026-08-15, Joy-Con 2 only — filled by
    /// `processIMU`, which only the BLE path calls): the analogs of
    /// the iPad's received views. Attitude [pitch, roll, yaw] in
    /// radians (the received-motion twin — orientation in 3D, drawn
    /// mean-centred since the rest pose is arbitrary), and linear
    /// acceleration in g with the gravity estimate subtracted (the
    /// received-acceleration twin — rests at the origin, strikes read
    /// as excursions).
    private var jcAttitudeBuf: [RawAccelSample] = []
    private var jcLinAccelBuf: [RawAccelSample] = []
    /// Flips once when the first fused sample lands — gates the fused
    /// panels (stays false for classic Joy-Cons, whose IMU never runs
    /// the fusion).
    @Published private(set) var jcFusedActive = false
    /// Flip once when the first NON-ZERO IMU / magnetometer sample
    /// lands — they gate the Setup panels (a disabled classic IMU
    /// streams zeros; a Joy-Con 2 without the mag block never trips
    /// the second).
    @Published private(set) var jcIMUActive = false
    @Published private(set) var jcMagActive = false
    /// Live reads for the Setup panel's 60 Hz TimelineViews — fresher
    /// than a throttled @Published mirror. Main thread only (all these
    /// buffers and the calibrators are written solely on main).
    var liveTrace: [RawTiltSample] { rawBuf }
    var liveAccelTrace: [RawAccelSample] { accelBuf }
    var liveJoyConGyro: [RawAccelSample] { jcGyroBuf }
    var liveJoyConAccel: [RawAccelSample] { jcAccelBuf }
    var liveJoyConMag: [RawAccelSample] { jcMagBuf }
    var liveJoyConAttitude: [RawAccelSample] { jcAttitudeBuf }
    var liveJoyConLinAccel: [RawAccelSample] { jcLinAccelBuf }
    var liveArmPos: SIMD3<Double>? { armCal.livePos }

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
        // Fusion mag state: a reconnected (possibly different) Joy-Con
        // must re-earn its hard-iron estimate.
        nHat = nil
        magMin = nil
        magMax = nil
        if yawPinned { yawPinned = false }
        fusedAttitude = []
        jcAttitudeBuf = []
        jcLinAccelBuf = []
        jcFusedActive = false
        onWristAttitude?(nil)
        lastWristAxes = nil
        lastFusedYaw = nil
        yawRel = 0
        yawRelBias = 0
        jcAccelEnv = 0
        joyConAccelLevel = 0
        if lastJcAccelSent != 0 {
            lastJcAccelSent = 0
            onJoyConAccel?(0)
        }
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
    // The ARM input: the iPad's raw tilt report, written from the MIDI
    // thread; the calibration capture and the live solve tick off it
    // (hopped to the main thread) — no Joy-Con involvement.
    private let armLock = NSLock()
    private var armTilt = SIMD3<Double>(0, 0, 0)
    private var armTime: CFAbsoluteTime = 0

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
            self.lastAltButtons = nil
            self.bleIMU = []
            self.gHat = nil
            self.clearJoyConIMU()
            // A running WRIST capture has lost its stream; the arm
            // calibration never needed the Joy-Con and carries on.
            if self.wristCal.isCapturing { self.wristCal.cancel() }
            if self.attached == nil { self.connectedName = nil }
        }
        ble.onNotification = { [weak self] data in
            self?.bleNotification(data)
        }
        ble.onAltNotification = { [weak self] data in
            self?.bleAltNotification(data)
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
        if b & (1 << 21) != 0 { down.insert(.sl) }
        if b & (1 << 22) != 0 { down.insert(.l) }
        if b & (1 << 20) != 0 { down.insert(.sr) }
        if b & (1 << 23) != 0 { down.insert(.zl) }
        // Shared byte (bits 8–15): minus, left-stick click, capture.
        if b & (1 << 8) != 0 { down.insert(.minus) }
        if b & (1 << 11) != 0 { down.insert(.stickClick) }
        if b & (1 << 13) != 0 { down.insert(.capture) }
        for c in down.subtracting(bleDown) { setButton(c, true) }
        for c in bleDown.subtracting(down) { setButton(c, false) }
        bleDown = down
        let s0 = Double(Int(d[10]) | (Int(d[11] & 0x0F) << 8))
        let s1 = Double((Int(d[11]) >> 4) | (Int(d[12]) << 4))
        processRawStick(s0, s1)
        // IMU (motion streaming enabled at connect, 63-byte report):
        // accel int16 LE ×3 at 0x30, gyro ×3 at 0x36 — the community
        // layout (trevlars, joycon2py, ndeadly agree), briefly "fixed"
        // the other way on 2026-08-15 and reverted the same day: the
        // raw trails were being compared against the iPad's FUSED
        // views (attitude + gravity-removed accel), which made the raw
        // sensors read as swapped. The fused analogs now render in
        // their own panels — judge against those, not the raw trails.
        // Scales are the classic constants (±8 g → /4096, ±2000 °/s →
        // /16.4); joycon2py claims 48000 LSB = 360 °/s (≈133.3 per °/s)
        // for the JC2 gyro — if a deliberate 90°-in-1 s turn reads
        // ~730 °/s on the panel, that scale is the truth, not this one.
        // Fusion runs on EVERY packet; the panel line publishes ~10 Hz.
        if d.count >= 0x3C {
            func i16(_ o: Int) -> Double {
                Double(Int16(bitPattern: UInt16(d[o]) | (UInt16(d[o + 1]) << 8)))
            }
            let accelG = SIMD3(i16(0x30), i16(0x32), i16(0x34)) / 4096.0
            let gyroDps = SIMD3(i16(0x36), i16(0x38), i16(0x3A)) / 16.4
            // Magnetometer: i16 ×3 at 0x19 (ndeadly's layout — battery
            // voltage follows at 0x1F; the old 0x3C guess read zeros).
            // Raw units, and it streams only with FEATURE_MAGNETOMETER
            // (0x80) in the feature-enable flags. The panel appears only
            // on non-zero data, so a wrong offset stays invisible
            // (joycon2py's rival candidate is 0x16).
            let mag: SIMD3<Double>? = d.count >= 0x1F
                ? SIMD3(i16(0x19), i16(0x1B), i16(0x1D)) : nil
            processIMU(accelG: accelG, gyroRadPerSec: gyroDps * .pi / 180,
                       mag: mag)
            let now = CFAbsoluteTimeGetCurrent()
            appendJoyConIMU(t: now, gyroDps: gyroDps,
                            accelG: accelG, mag: mag)
            if now - lastIMUPublish > 0.1 {
                lastIMUPublish = now
                bleIMU = [accelG.x, accelG.y, accelG.z,
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

    /// THIRD-PARTY ALTERNATE INPUT (2026-08-21, Mobacon). Some
    /// Switch 2 clones present the Joy-Con 2 GATT faithfully but
    /// stream their input on CC1BBBB5-… instead of …7FD2, in a
    /// SHIFTED 63-byte layout (measured live, per-button): byte 0 =
    /// counter, buttons at bytes 2–3 — byte 2: Down 0x01, Right 0x02,
    /// Left 0x04, Up 0x08, L 0x10 (the M2 paddle mirrors it), ZL
    /// 0x20, Minus 0x40, stick click 0x80; byte 3: Capture 0x01,
    /// SR 0x40, SL 0x80 — and the 12-bit packed stick at bytes 5–7
    /// (rest ≈ 2048/2047, same packing as everywhere else). Byte 4
    /// holds constant flags (0x07); the IMU region streams zeros (the
    /// clone ignores the feature-enable command — no motion). The
    /// brightness button is device-local and never reports. Feeds the
    /// SAME funnels as the standard parse; a change in the button
    /// bytes still dumps the full report for future mapping.
    private var lastAltButtons: [UInt8]?
    private var altMotionLengthLogged = false
    private func bleAltNotification(_ d: Data) {
        guard d.count >= 8 else { return }
        let btn = [d[2], d[3], d[4]]
        if let last = lastAltButtons, btn != last {
            NSLog("Tarabdaar ble: alt buttons %02x %02x %02x → %02x %02x %02x  full [%@]",
                  last[0], last[1], last[2], btn[0], btn[1], btn[2],
                  d.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        lastAltButtons = btn
        var down: Set<Control> = []
        if d[2] & 0x01 != 0 { down.insert(.dpadDown) }
        if d[2] & 0x02 != 0 { down.insert(.dpadRight) }
        if d[2] & 0x04 != 0 { down.insert(.dpadLeft) }
        if d[2] & 0x08 != 0 { down.insert(.dpadUp) }
        if d[2] & 0x10 != 0 { down.insert(.l) }   // L (and the M2 mirror)
        if d[2] & 0x20 != 0 { down.insert(.zl) }
        if d[2] & 0x40 != 0 { down.insert(.minus) }
        if d[2] & 0x80 != 0 { down.insert(.stickClick) }
        if d[3] & 0x01 != 0 { down.insert(.capture) }
        if d[3] & 0x80 != 0 { down.insert(.sl) }
        if d[3] & 0x40 != 0 { down.insert(.sr) }
        for c in down.subtracting(bleDown) { setButton(c, true) }
        for c in bleDown.subtracting(down) { setButton(c, false) }
        bleDown = down
        let s0 = Double(Int(d[5]) | (Int(d[6] & 0x0F) << 8))
        let s1 = Double((Int(d[6]) >> 4) | (Int(d[7]) << 4))
        processRawStick(s0, s1)
        // IMU: report 0x07 carries motion as a LENGTH byte at 0x0E
        // ({0, 30, 40}) followed by a packed blob at 0x0F whose
        // encoding nobody has decoded (it is NOT i16 triplets — the
        // 2026-09-02 misparse read it at the report-0x05 offsets and
        // showed ±6 g at rest). Not parsed: a real Joy-Con 2 never
        // reaches this path in normal operation (its raw IMU rides
        // report 0x05 on the standard characteristic), and the clone
        // streams length 0. Log the length once so a device that DOES
        // fill it is visible in Console.
        if d.count > 0x0E, d[0x0E] != 0, !altMotionLengthLogged {
            altMotionLengthLogged = true
            NSLog("Tarabdaar ble: alt report motion length %d — packed format, not decoded",
                  d[0x0E])
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastEventPublish > 0.2 {
            lastEventPublish = now
            hidReportHex = "alt: " + d.prefix(13)
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
        onStickAxes?(0, 0)   // park the stick axes at centre
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
            if b2 & 0x40 != 0 { down.insert(.l) }
            if b2 & 0x80 != 0 { down.insert(.zl) }
            // Arrows/SL/SR stay with the GC path in simple mode.
            down.formUnion(hidDown.intersection([.dpadUp, .dpadDown,
                                                 .dpadLeft, .dpadRight]))
        } else if id == 0x30 || id == 0x21, length >= base + 8 {
            if !hidFullMode {
                hidFullMode = true
                hidStatus = "full mode"
                NSLog("Tarabdaar: Joy-Con in full input mode — analog stick live")
                requestIMUEnable()
                // The GC bindings stand down from here; release any
                // press they delivered so nothing sticks held across
                // the transition (the HID byte re-presses real holds
                // in this same report).
                for c in buttonsDown { setButton(c, false) }
            }
            let left = report[base + 4]
            if left & 0x01 != 0 { down.insert(.dpadDown) }
            if left & 0x02 != 0 { down.insert(.dpadUp) }
            if left & 0x04 != 0 { down.insert(.dpadRight) }
            if left & 0x08 != 0 { down.insert(.dpadLeft) }
            if left & 0x10 != 0 { down.insert(.sr) }
            if left & 0x20 != 0 { down.insert(.sl) }
            if left & 0x40 != 0 { down.insert(.l) }
            if left & 0x80 != 0 { down.insert(.zl) }
            // Shared button byte (report byte 4, one before the left
            // byte): minus, left-stick click, capture; the right-side
            // bits (plus 0x02, R-stick 0x04, home 0x10) wait for a
            // right controller.
            let shared = report[base + 3]
            if shared & 0x01 != 0 { down.insert(.minus) }
            if shared & 0x08 != 0 { down.insert(.stickClick) }
            if shared & 0x20 != 0 { down.insert(.capture) }
            let s0 = Double(Int(report[base + 5]) | (Int(report[base + 6] & 0x0F) << 8))
            let s1 = Double((Int(report[base + 6]) >> 4) | (Int(report[base + 7]) << 4))
            processRawStick(s0, s1)
            // IMU (streams zeros until subcommand 0x40 enables it):
            // three 12-byte frames ~5 ms apart at base+12 — accel
            // i16 ×3 (±8 g, 1 g = 4096 LSB) then gyro i16 ×3
            // (±2000 °/s, 16.4 LSB per °/s), device frame — the same
            // scales and order as the Joy-Con 2 BLE report.
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
        if rotateForUpright {
            // Sideways lone Joy-Con: the rail's SL/SR are named
            // Left/Right Shoulder; L/ZL usually aren't in the profile
            // at all (they arrive via the raw HID side-channel).
            bind(profile.buttons[GCInputLeftShoulder], .sl)
            bind(profile.buttons[GCInputRightShoulder], .sr)
            bind(profile.buttons[GCInputLeftTrigger], .l)
            bind(profile.buttons[GCInputRightTrigger], .zl)
        } else {
            bind(profile.buttons[GCInputLeftShoulder], .l)
            bind(profile.buttons[GCInputLeftTrigger], .zl)
            bind(profile.buttons[GCInputRightShoulder], .sr)
            bind(profile.buttons[GCInputRightTrigger], .sr)
        }
        // The misc inputs, for pads without the Nintendo HID
        // side-channel (full mode overrides these like everything GC).
        bind(profile.buttons[GCInputButtonOptions], .minus)
        bind(profile.buttons[GCInputLeftThumbstickButton], .stickClick)

        // GC MOTION (2026-08-21): controllers that pair over classic
        // Bluetooth (Pro Controller presentations; third-party
        // multi-mode pads like the Mobapad in Switch-1 mode) deliver
        // their IMU through GCMotion rather than any raw channel.
        // Feed the same fusion + panels as the BLE path: total
        // acceleration includes gravity (like the Joy-Con reports),
        // rotation rate is rad/s.
        if let motion = c.motion {
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            NSLog("Tarabdaar: GC motion available (manual activation %@, rotation rate %@)",
                  motion.sensorsRequireManualActivation ? "yes" : "no",
                  motion.hasRotationRate ? "yes" : "no")
            motion.valueChangedHandler = { [weak self] m in
                guard let self else { return }
                let a = SIMD3(m.acceleration.x, m.acceleration.y,
                              m.acceleration.z)
                let w = m.hasRotationRate
                    ? SIMD3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z)
                    : SIMD3<Double>.zero
                self.processIMU(accelG: a, gyroRadPerSec: w)
                let now = CFAbsoluteTimeGetCurrent()
                let dps = w * 180 / .pi
                self.appendJoyConIMU(t: now, gyroDps: dps, accelG: a)
                if now - self.lastIMUPublish > 0.1 {
                    self.lastIMUPublish = now
                    self.bleIMU = [a.x, a.y, a.z, dps.x, dps.y, dps.z]
                }
            }
        } else {
            NSLog("Tarabdaar: GC controller has no motion profile")
        }
    }

    private func detach() {
        attached?.motion?.valueChangedHandler = nil
        attached = nil
        connectedName = nil
        stickX = 0; stickY = 0
        stickActive = false
        buttonsDown = []
        lastEvent = "—"
        elementNames = []
        // Don't wipe the IMU trails while a BLE controller still feeds
        // them — only when the GC controller was the (sole) source.
        if !bleStatus.hasPrefix("connected") { clearJoyConIMU() }
    }

    /// GC bindings stand down once the raw HID side-channel is in full
    /// mode (2026-08-21) — the 0x30 report carries every button
    /// authoritatively, and third-party clones assign the GC face
    /// buttons unpredictably (the Mobapad reported its arrows as a
    /// distinct dpad element PLUS a differently-rotated A/B/X/Y alias,
    /// so each press fired twice, once 90° wrong). Same rule the stick
    /// handler has always used.
    private func bind(_ button: GCControllerButtonInput?, _ control: Control) {
        button?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, !self.hidFullMode else { return }
            self.setButton(control, pressed)
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
        onStickAxes?(s.0, s.1)
    }

    /// iPad raw-tilt in (MIDI thread — the only cross-thread entry).
    /// Returns true when the arm calibration CONSUMES the value (a
    /// calibration exists or is being captured) — the caller must then
    /// not pass it through to the axes directly. The capture and the
    /// live solve tick off this stream (hopped to main), so they need
    /// nothing from the Joy-Con.
    func feedArmTilt(_ axis: Int, _ value: Double) -> Bool {
        armLock.lock()
        if axis >= 0, axis < 3 {
            armTilt[axis] = value
            armTime = CFAbsoluteTimeGetCurrent()
        }
        let f = [armTilt.x, armTilt.y, armTilt.z]
        armLock.unlock()
        let consumed = armCal.isActive
        // Always tick — even when nothing consumes the value, the tick
        // feeds the Setup panel's raw-stream scope and the marker.
        DispatchQueue.main.async { [weak self] in self?.armTick(f) }
        return consumed
    }

    /// One arm-stream tick on the main thread: the raw trail (frame-
    /// coalesced — the wire delivers one axis per message; see
    /// `TiltCalibrator.frameGap`), then the calibrator (capture or
    /// solve → `onArmAxes`).
    private func armTick(_ f: [Double]) {
        let now = CFAbsoluteTimeGetCurrent()
        let raw = SIMD3(f[0], f[1], f[2])
        let newFrame = now - lastArmMsgT >= TiltCalibrator.frameGap
        lastArmMsgT = now
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
        armCal.tick(raw, at: now)
    }

    // MARK: Calibration control (panel buttons + dpad-up/down + ZL)

    /// The calibration currently CAPTURING — the dpad-up/down target
    /// (the arm first if both somehow run at once).
    var capturingCalibrator: TiltCalibrator? {
        armCal.isCapturing ? armCal : (wristCal.isCapturing ? wristCal : nil)
    }

    /// Dpad-up: advance whichever capture is running (no-op otherwise).
    func advanceCalibration() { capturingCalibrator?.advance() }

    /// Dpad-down during a capture: step it back one phase.
    func redoPreviousCalibrationStep() { capturingCalibrator?.redoPrevious() }

    /// ZL: the CURRENT poses become rest on BOTH calibrations (0 on
    /// every arm and wrist axis) without re-fitting the directions.
    func recenterBody() {
        armCal.recenter()
        wristCal.recenter()
    }

    /// One fused IMU step (accel in g; gyro rad/s; mag raw units,
    /// Joy-Con 2 only). The tilt pipeline doesn't consume it — the arm
    /// calibration runs entirely on the iPad's tilt stream (`armTick`),
    /// and the 2026-08-12 wrist axes are gone; the outputs are the
    /// Setup panels' fused views: the attitude trail (pitch/roll from
    /// the gravity estimate, mag-pinned yaw — see the 9-AXIS note on
    /// the state above) and the gravity-removed linear acceleration,
    /// the Joy-Con analogs of the iPad's received motion/acceleration.
    private func processIMU(accelG: SIMD3<Double>, gyroRadPerSec: SIMD3<Double>,
                            mag: SIMD3<Double>? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(max(now - lastIMUTime, 0.001), 0.1)
        lastIMUTime = now
        // Free-fall / degenerate guard: no usable gravity direction.
        guard simd_length(accelG) > 0.25 else { return }
        // Gyro-bias learner: converge on the reading while still.
        if simd_length(gyroRadPerSec - gyroBias) < 0.05 {
            gyroBias += (gyroRadPerSec - gyroBias) * 0.02
        }
        let w = gyroRadPerSec - gyroBias
        let aN = simd_normalize(accelG)
        var g = gHat ?? aN
        g = simd_normalize(g + simd_cross(g, w) * dt)   // ġ = g × ω
        g = simd_normalize(g + (aN - g) * 0.02)         // accel pull
        gHat = g
        yaw += simd_dot(w, g) * dt
        var pinned = false
        if let mag, mag != .zero {
            magMin = magMin.map { simd_min($0, mag) } ?? mag
            magMax = magMax.map { simd_max($0, mag) } ?? mag
            let lo = magMin!, hi = magMax!
            let m = mag - (lo + hi) * 0.5
            let fieldMag = simd_length(m)
            // Trust the hard-iron midpoint only once the seen extremes
            // span most of the field sphere (≈1.4 × field after broad
            // rotation) — a biased center warps every heading it feeds.
            if fieldMag > 1e-6, simd_length(hi - lo) > fieldMag * 0.7 {
                let h = m - g * simd_dot(m, g)      // horizontal field
                if simd_length(h) > fieldMag * 0.2 {  // usable unless the
                    let hN = simd_normalize(h)        // field is near-vertical
                    var n = nHat ?? hN
                    n += simd_cross(n, w) * dt        // ṅ = n × ω
                    n += (hN - n) * 0.02              // mag pull
                    n -= g * simd_dot(n, g)           // keep n ⊥ gravity
                    if simd_length(n) > 1e-6 {
                        n = simd_normalize(n)
                        nHat = n
                        // Drift-free yaw: heading of the device x-axis'
                        // horizontal projection, measured from north
                        // about gravity; pulled wrap-aware so the gyro
                        // still owns the short term.
                        var xh = SIMD3(1.0, 0, 0)
                        xh -= g * simd_dot(xh, g)
                        if simd_length(xh) > 0.2 {    // near-vertical x:
                            xh = simd_normalize(xh)   // keep integrating
                            let yawMag = atan2(
                                simd_dot(simd_cross(n, xh), g),
                                simd_dot(n, xh))
                            var e = (yawMag - yaw)
                                .truncatingRemainder(dividingBy: 2 * .pi)
                            if e > .pi { e -= 2 * .pi }
                            if e < -.pi { e += 2 * .pi }
                            yaw += e * 0.02
                            pinned = true
                        }
                    }
                }
            }
        }
        if pinned != yawPinned { yawPinned = pinned }
        // The fused trails — every packet, same ~8 s window as the raw
        // ones. Attitude in radians (yaw is the continuous integrator,
        // pulled wrap-aware, so the trail never jumps at ±180°);
        // linear acceleration = measured accel minus the unit gravity
        // estimate, in g — rests at the origin like the iPad's
        // userAcceleration.
        let att = SIMD3(atan2(-g.x, (g.y * g.y + g.z * g.z).squareRoot()),
                        atan2(g.y, g.z),
                        yaw)
        let lin = accelG - g
        jcAttitudeBuf.append(RawAccelSample(t: now, a: att))
        jcLinAccelBuf.append(RawAccelSample(t: now, a: lin))
        // THE WRIST FEATURE (2026-09-02): gravity pitch/roll plus the
        // relative yaw (see `yawRel`), all at ±90° full scale, −1…+1 —
        // the arm calibration's convention — into the wrist calibrator
        // every packet (capture, or solve → `onWristAxes`).
        updateRelativeYaw(att.z, dt: dt)
        let wristF = SIMD3(att.x, att.y, yawRel) / (.pi / 2)
        wristCal.tick(simd_clamp(wristF, SIMD3(repeating: -1), SIMD3(repeating: 1)),
                      at: now)
        // THE JOY-CON ACCELERATION AXIS (2026-09-02): |accel − ĝ| through
        // the strike law and the iPad tracker's fast-attack / 150 ms-
        // decay envelope, 0…1, change-gated at 1/256.
        jcAccelEnv = max(StrikeLaw.scale01(simd_length(lin)),
                         jcAccelEnv * exp(-dt / StrikeLaw.envelopeTau))
        let qa = (jcAccelEnv * 256).rounded() / 256
        if qa != lastJcAccelSent {
            lastJcAccelSent = qa
            onJoyConAccel?(qa)
        }
        if let first = jcAttitudeBuf.first, first.t < now - Self.traceWindow {
            jcAttitudeBuf.removeAll { $0.t < now - Self.traceWindow }
            jcLinAccelBuf.removeAll { $0.t < now - Self.traceWindow }
        }
        if !jcFusedActive { jcFusedActive = true }
        if now - lastFusedPublish > 0.1 {
            lastFusedPublish = now
            let deg = 180.0 / .pi
            fusedAttitude = [att.x * deg, att.y * deg, att.z * deg]
            joyConAccelLevel = qa
            // Calibrated: the iPad's wrist square mirrors the SOLVED
            // wrist axes (the arm square's rule); raw attitude otherwise.
            if wristCal.isCalibrated, let w = lastWristAxes {
                onWristAttitude?(w)
                return
            }
            // Wrist display axes for the iPad square: pitch/roll at ±90°
            // full scale (the iPad's own-attitude convention), yaw
            // wrapped to ±180° (the integrator is continuous). −1…+1.
            func disp(_ rad: Double, fullScale: Double) -> Double {
                min(max(rad / fullScale, -1), 1)
            }
            var yawWrapped = att.z.truncatingRemainder(dividingBy: 2 * .pi)
            if yawWrapped > .pi { yawWrapped -= 2 * .pi }
            if yawWrapped < -.pi { yawWrapped += 2 * .pi }
            onWristAttitude?((disp(att.x, fullScale: .pi / 2),
                              disp(att.y, fullScale: .pi / 2),
                              disp(yawWrapped, fullScale: .pi)))
        }
    }

    /// The wrist feature's yaw: wrap-safe increments of the fused yaw,
    /// drift rate learned while quiescent and subtracted, leaked toward
    /// zero with `yawLeakTau` — the iPad's `MotionManager.updateYaw`.
    private func updateRelativeYaw(_ rawYaw: Double, dt: Double) {
        if let last = lastFusedYaw {
            var dy = rawYaw - last
            if dy > .pi { dy -= 2 * .pi } else if dy < -.pi { dy += 2 * .pi }
            let rate = dy / dt
            if abs(rate - yawRelBias) < 0.01 {
                yawRelBias += (rate - yawRelBias) * min(1, dt / 10)
            }
            yawRel += dy - yawRelBias * dt
            yawRel -= yawRel * (dt / Self.yawLeakTau)
        }
        lastFusedYaw = rawYaw
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
    /// Third-party clones (Mobacon, 2026-08-21) stream their input
    /// here instead of the standard input characteristic — shifted
    /// layout, parsed by `bleAltNotification`.
    static let altInputCharacteristic =
        CBUUID(string: "CC1BBBB5-7354-4D32-A716-A81CB241A32A")
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
    /// Input notifications from the third-party alternate input
    /// characteristic — forwarded only while the standard input
    /// characteristic stays silent (a real Joy-Con 2 owns that one).
    var onAltNotification: ((Data) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The service's write characteristic — commands (player LED) go
    /// here.
    private var outputCharacteristic: CBCharacteristic?
    private var inputCharacteristic: CBCharacteristic?
    private var cmdRespCharacteristic: CBCharacteristic?
    private var ledSent = false
    private var initStarted = false
    // THIRD-PARTY DIAGNOSTICS (2026-08-21, Mobacon): a clone that
    // advertises the Joy-Con 2 GATT can reach "connected" and then
    // stream nothing, or stream a different report layout. These logs
    // make the wire visible in Console (`Tarabdaar ble` filter):
    // notification arrival/rate, and a full hex dump whenever the
    // button word (bytes 4–7) changes — press each button once and the
    // log names its bit.
    private var notifCount = 0
    private var lastNotifLog: CFAbsoluteTime = 0
    private var lastButtonWord: UInt32?
    /// Per-characteristic log throttle for the probe subscriptions on
    /// the unknown notify characteristics.
    private var lastCharLog: [CBUUID: CFAbsoluteTime] = [:]
    // MOTION-ENABLE PROBE (2026-08-21, Mobapad M12-S). The clone
    // advertises 9-axis motion but streams zeros in the report's IMU
    // region and ignores the standard feature-enable on the standard
    // command characteristic. Its GATT holds four other write-capable
    // characteristics — one may be its real command channel. Once the
    // alt input stream identifies clone-mode, walk every write char ×
    // two command dialects (0x91 feature-enable, classic subcommand
    // mode+IMU), one candidate per 1.2 s, and watch the IMU/mag
    // regions: an enabled accelerometer reads gravity even at rest,
    // so success is self-announcing — the log names the candidate.
    private var probeChars: [CBCharacteristic] = []
    private var probeStarted = false
    private var probeStep = -1
    private var altMotionSeen = false
    /// Notify-capable characteristics OTHER than the standard input and
    /// command-response ones (the controller-specific report 0x07 char
    /// among them). Subscribed only by `scheduleAltFallback` — a real
    /// Joy-Con 2 switches to report 0x07 and silences report 0x05 the
    /// moment 0x07 is enabled, which is what broke the IMU parse on
    /// 2026-09-02.
    private var deferredNotifyChars: [CBCharacteristic] = []
    /// How long the standard input characteristic may stay silent after
    /// its subscribe before the clone fallback subscribes the rest. A
    /// real Joy-Con 2 streams within ~100 ms of the CCCD write.
    static let altFallbackDelay: TimeInterval = 2.0

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
        let mfg = (ad[CBAdvertisementDataManufacturerDataKey] as? Data)?
            .prefix(12).map { String(format: "%02x", $0) }
            .joined(separator: " ") ?? "—"
        NSLog("Tarabdaar ble: discovered \"%@\" rssi %@ mfg [%@]",
              name.isEmpty ? "(no name)" : name, rssi, mfg)
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
        inputCharacteristic = nil
        cmdRespCharacteristic = nil
        ledSent = false
        initStarted = false
        lastCharLog = [:]
        probeChars = []
        probeStarted = false
        probeStep = -1
        altMotionSeen = false
        NSLog("Tarabdaar ble: disconnected after %d notifications — %@",
              notifCount, error?.localizedDescription ?? "clean")
        notifCount = 0
        lastButtonWord = nil
        onDisconnect?()
        onStatus?("disconnected")
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        NSLog("Tarabdaar ble: services [%@]%@",
              services.map { $0.uuid.uuidString }.joined(separator: ", "),
              error.map { " error: \($0.localizedDescription)" } ?? "")
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
        NSLog("Tarabdaar ble: service %@ chars [%@]",
              service.uuid.uuidString,
              (service.characteristics ?? []).map {
                  String(format: "%@ (props 0x%02x)",
                         $0.uuid.uuidString, $0.properties.rawValue)
              }.joined(separator: ", "))
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.inputCharacteristic:
                inputCharacteristic = ch
            case Self.commandResponseCharacteristic:
                // Subscribe before commanding — acks land here.
                cmdRespCharacteristic = ch
                p.setNotifyValue(true, for: ch)
            case Self.commandWriteCharacteristic:
                outputCharacteristic = ch
                ledSent = false
            default:
                break
            }
        }
        // ENCRYPTION/LAYOUT PROBE (2026-08-21, Mobacon): commands to
        // this controller go write-without-response, which cannot
        // surface an ATT "insufficient authentication" error — a
        // firmware that requires an encrypted link just drops them
        // silently. A READ does surface it, and macOS reacts by
        // initiating SMP pairing automatically. So read every readable
        // characteristic (worst case we learn its bytes — the input
        // char's read may be a live report snapshot). The other
        // notify-capable characteristics are only COLLECTED here: the
        // controller-specific input char is among them, and enabling
        // it silences the standard report on a real Joy-Con 2, so the
        // subscribe waits for `scheduleAltFallback`. Log-only; the
        // real init stays in maybeBeginInit.
        for ch in service.characteristics ?? [] {
            if ch.properties.contains(.read) {
                p.readValue(for: ch)
            }
            if ch.properties.contains(.notify),
               ch.uuid != Self.inputCharacteristic,
               ch.uuid != Self.commandResponseCharacteristic,
               !deferredNotifyChars.contains(where: { $0.uuid == ch.uuid }) {
                deferredNotifyChars.append(ch)
            }
            if ch.properties.contains(.write)
                || ch.properties.contains(.writeWithoutResponse),
               !probeChars.contains(where: { $0.uuid == ch.uuid }) {
                probeChars.append(ch)
            }
        }
        maybeBeginInit(p)
        // Fallback for a device exposing the input characteristic
        // without the command channel: subscribe directly, the
        // pre-2026-08-21 behaviour.
        if inputCharacteristic != nil, !initStarted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.peripheral === p, !self.initStarted,
                      let input = self.inputCharacteristic else { return }
                self.initStarted = true
                NSLog("Tarabdaar ble: no command channel — subscribing input directly")
                p.setNotifyValue(true, for: input)
                self.onConnect?(p.name ?? "Joy-Con 2")
                self.scheduleAltFallback(p)
            }
        }
    }

    /// CLONE FALLBACK (2026-09-02). `altFallbackDelay` after the
    /// standard input subscribe, if not one report 0x05 notification
    /// has arrived, subscribe every other notify-capable characteristic
    /// — the controller-specific report 0x07 char (CC1BBBB5-… on a
    /// left Joy-Con 2) is where the Mobacon clone streams. A real
    /// Joy-Con 2 has been streaming for ~1.9 s by now and never takes
    /// this path, so its report 0x05 IMU parse stays intact.
    private func scheduleAltFallback(_ p: CBPeripheral) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.altFallbackDelay) { [weak self] in
            guard let self, self.peripheral === p else { return }
            guard self.notifCount == 0 else { return }
            NSLog("Tarabdaar ble: standard input silent for %.1f s — subscribing %d alternate characteristic(s) (clone fallback)",
                  Self.altFallbackDelay, self.deferredNotifyChars.count)
            for ch in self.deferredNotifyChars {
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    /// CONSOLE-STYLE INIT (2026-08-21). A real Joy-Con 2 streams input
    /// as soon as the notify subscription lands, commands or no
    /// commands — but third-party Switch 2 controllers (Mobacon) that
    /// emulate the same GATT wait for the console's handshake, stream
    /// nothing, and drop the link after a 60 s timeout. So run the
    /// sequence the Linux driver (trevlars/switch2-controllers-linux)
    /// uses for genuine hardware: command-response subscribe first,
    /// then controller-info read → player LED → vibration preset →
    /// feature init/enable, and the INPUT subscribe LAST. The driver
    /// gates each step on its ack; the steps here are paced by delay
    /// instead (a real Joy-Con 2 acks within ms, and a clone that acks
    /// nothing would stall an ack-gated sequence at step one). The
    /// vibration preset doubles as tactile proof the controller is
    /// processing commands.
    private func maybeBeginInit(_ p: CBPeripheral) {
        guard !initStarted, let input = inputCharacteristic,
              outputCharacteristic != nil, cmdRespCharacteristic != nil
        else { return }
        initStarted = true
        let steps: [(Double, String, () -> Void)] = [
            (0.30, "controller-info read", { [weak self] in self?.readControllerInfo() }),
            (0.55, "player LED", { [weak self] in self?.setPlayerLED(1) }),
            (0.80, "vibration preset", { [weak self] in self?.playVibrationPreset(0x03) }),
            (1.05, "feature enable", { [weak self] in self?.enableFeatures() }),
            (1.30, "input subscribe", { [weak self] in
                guard let self, self.peripheral === p else { return }
                p.setNotifyValue(true, for: input)
                self.onConnect?(p.name ?? "Joy-Con 2")
                self.scheduleAltFallback(p)
            }),
        ]
        for (delay, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.peripheral === p else { return }
                NSLog("Tarabdaar ble: init — %@", name)
                action()
            }
        }
    }

    /// The console's first command: read 0x40 bytes of controller info
    /// at 0x00013000 (command 0x02 = memory, subcommand 0x04 = read;
    /// payload = length, 7e 00 00, address little-endian).
    private func readControllerInfo() {
        writeCommand(0x02, 0x04,
                     [0x40, 0x7E, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00])
    }

    /// Play a built-in rumble preset (command 0x0A, subcommand 0x02);
    /// 0x03 = soft.
    private func playVibrationPreset(_ preset: UInt8) {
        writeCommand(0x0A, 0x02, [preset, 0x00, 0x00, 0x00])
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

    /// Feature init + enable — without the motion flag the
    /// notification's IMU fields stay zero. 0x07 = the Linux driver's
    /// initialize() base (0x03 | FEATURE_MOTION 0x04); 0x80 =
    /// FEATURE_MAGNETOMETER (trevlars protocol constants) so the mag
    /// block at 0x19 streams too — without it that field stays zero
    /// and the mag panel never appears.
    ///
    /// The two commands are SPACED (2026-09-02): written back to back
    /// without response, the init's ack came back as all zeros and
    /// motion stayed off — it only armed when the clone probe happened
    /// to re-send the pair 150 ms apart.
    private func enableFeatures() {
        let flags: [UInt8] = [0x87, 0x00, 0x00, 0x00]
        writeCommand(0x0C, 0x02, flags)   // SUBCOMMAND_FEATURE_INIT
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.writeCommand(0x0C, 0x04, flags)   // SUBCOMMAND_FEATURE_ENABLE
        }
    }

    /// One `0x91`-framed command:
    /// `<cmd> 91 01 <sub> 00 <len> 00 00 <payload…>`.
    private func writeCommand(_ command: UInt8, _ subcommand: UInt8,
                              _ payload: [UInt8]) {
        guard let p = peripheral, let ch = outputCharacteristic else {
            NSLog("Tarabdaar ble: command %02x/%02x dropped — no command characteristic",
                  command, subcommand)
            return
        }
        NSLog("Tarabdaar ble: command %02x/%02x sent", command, subcommand)
        let cmd: [UInt8] = [command, 0x91, 0x01, subcommand, 0x00,
                            UInt8(payload.count), 0x00, 0x00] + payload
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse
                                                          : .withResponse
        p.writeValue(Data(cmd), for: ch, type: type)
    }

    /// Success detector for the motion probe: report 0x07 carries a
    /// motion-block LENGTH byte at 0x0E (0 with the IMU off, 30 or 40
    /// once enabled), so a nonzero length means a candidate worked —
    /// the log names it via `probeStep`.
    private func checkAltMotion(_ d: Data) {
        guard !altMotionSeen, d.count > 0x0E else { return }
        let nonzero = d[0x0E] != 0
        if nonzero {
            altMotionSeen = true
            NSLog("Tarabdaar ble: ALT MOTION LIVE — IMU region nonzero (after probe step %d)",
                  probeStep)
        }
    }

    /// Raw write for the motion probe — targets an arbitrary
    /// characteristic, unlike `writeCommand`.
    private func probeWrite(_ ch: CBCharacteristic, _ bytes: [UInt8]) {
        guard let p = peripheral else { return }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse
                                                          : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    /// Walk every write-capable characteristic with both command
    /// dialects (see the state note above). Steps stop advancing the
    /// moment `checkAltMotion` fires, so the successful candidate is
    /// the last one logged.
    private func startMotionProbe() {
        guard peripheral != nil, !altMotionSeen, !probeChars.isEmpty else { return }
        let feat: [[UInt8]] = [
            [0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x87, 0x00, 0x00, 0x00],
            [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0x87, 0x00, 0x00, 0x00],
        ]
        let classic: [[UInt8]] = [
            [0x01, 0x01, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30],
            [0x01, 0x02, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01],
        ]
        var steps: [(String, CBCharacteristic, [[UInt8]])] = []
        for ch in probeChars {
            steps.append(("0x91 feature-enable", ch, feat))
            steps.append(("classic mode+IMU", ch, classic))
        }
        NSLog("Tarabdaar ble: motion probe starting — %d candidates over %d write chars",
              steps.count, probeChars.count)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { [weak self] in
                guard let self, self.peripheral != nil, !self.altMotionSeen
                else { return }
                self.probeStep = i
                NSLog("Tarabdaar ble: motion probe %d/%d — %@ → %@",
                      i + 1, steps.count, step.0, step.1.uuid.uuidString)
                self.probeWrite(step.1, step.2[0])
                if step.2.count > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self, self.peripheral != nil else { return }
                        self.probeWrite(step.1, step.2[1])
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(steps.count) * 1.2 + 1.0
        ) { [weak self] in
            guard let self, self.peripheral != nil, !self.altMotionSeen
            else { return }
            NSLog("Tarabdaar ble: motion probe exhausted — IMU region still zero")
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateNotificationStateFor ch: CBCharacteristic,
                    error: Error?) {
        NSLog("Tarabdaar ble: notify %@ on %@%@",
              ch.isNotifying ? "ON" : "OFF", ch.uuid.uuidString,
              error.map { " error: \($0.localizedDescription)" } ?? "")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic,
                    error: Error?) {
        if let error {
            NSLog("Tarabdaar ble: write to %@ FAILED — %@",
                  ch.uuid.uuidString, error.localizedDescription)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        if let error {
            // The interesting failure: an "insufficient authentication /
            // encryption" ATT error here means the firmware wants a
            // paired link — macOS should follow up by pairing.
            NSLog("Tarabdaar ble: read/notify on %@ FAILED — %@",
                  ch.uuid.uuidString, error.localizedDescription)
            return
        }
        if ch.uuid == Self.commandResponseCharacteristic {
            let hex = (ch.value ?? Data()).prefix(16)
                .map { String(format: "%02x", $0) }.joined(separator: " ")
            NSLog("Tarabdaar ble: command ack [%@]", hex)
            return
        }
        if ch.uuid == Self.altInputCharacteristic {
            // The controller-specific report 0x07 stream — reached
            // only via the clone fallback. Forward only while the
            // standard input characteristic is silent, so it can
            // never race the report-0x05 parse.
            if notifCount == 0, let d = ch.value {
                onAltNotification?(d)
                checkAltMotion(d)
                if !probeStarted {
                    probeStarted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.startMotionProbe()
                    }
                }
            }
            return
        }
        if ch.uuid != Self.inputCharacteristic {
            // Probe traffic: reads and unknown-characteristic
            // notifications, throttled per characteristic.
            let now = CFAbsoluteTimeGetCurrent()
            if now - (lastCharLog[ch.uuid] ?? 0) > 1 {
                lastCharLog[ch.uuid] = now
                let d = ch.value ?? Data()
                NSLog("Tarabdaar ble: %@ value, %d bytes [%@]",
                      ch.uuid.uuidString, d.count, d.prefix(24)
                          .map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            return
        }
        // Belt-and-suspenders: if the LED write raced discovery,
        // re-send once real input is flowing.
        if !ledSent, outputCharacteristic != nil {
            setPlayerLED(1)
            enableFeatures()
        }
        guard let d = ch.value else { return }
        notifCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if notifCount == 1 || now - lastNotifLog > 5 {
            lastNotifLog = now
            NSLog("Tarabdaar ble: input #%d, %d bytes [%@]",
                  notifCount, d.count, d.prefix(16)
                      .map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        if d.count >= 8 {
            let word = UInt32(d[4]) | (UInt32(d[5]) << 8)
                     | (UInt32(d[6]) << 16) | (UInt32(d[7]) << 24)
            if let last = lastButtonWord, word != last {
                NSLog("Tarabdaar ble: buttons %08x → %08x  full [%@]",
                      last, word, d.map { String(format: "%02x", $0) }
                          .joined(separator: " "))
            }
            lastButtonWord = word
        }
        onNotification?(d)
    }
}
