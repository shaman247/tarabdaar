import Combine
import CoreBluetooth
import Foundation
import GameController
import TarabdaarCore
import IOKit.hid
import simd

/// Supplemental game-controller input: a Nintendo Switch Joy-Con (L) over
/// Bluetooth, or any GameController device with a stick and buttons.
/// Additive beside the iPad — it feeds the same host funnels (control
/// axes, drone buttons). Stick → its own two axes (−1…+1); buttons →
/// semantic `Control` events named by the UPRIGHT grip (macOS presents a
/// lone Joy-Con SIDEWAYS; `attach` rotates stick + face diamond 90° back).
///
/// **Alias trap:** a `GCPhysicalInputProfile` names one physical element
/// under several keys — a lone Joy-Con's stick is both "Left Thumbstick"
/// AND "Direction Pad", so binding the d-pad without an identity check
/// turns stick deflection into button presses. `attach` resolves the
/// stick first and binds only a DISTINCT Direction Pad element.
///
/// **Switch 2 Joy-Con:** BLE-only, vendor GATT — macOS cannot pair them
/// and neither GameController nor IOHID sees them. `JoyCon2BLE` (below)
/// owns the connection; `bleNotification` parses report 0x05 from the
/// standard characteristic …7FD2 into the same funnels. The controller-
/// specific characteristic CC1BBBB5-… carries report 0x07 (undecoded
/// packed motion); a real Joy-Con 2 switches to 0x07 and SILENCES 0x05
/// the moment 0x07 is subscribed, so it is enabled only as the clone
/// fallback after `altFallbackDelay` of silence — third-party clones
/// (Mobacon) mimic the GATT, ignore 0x91 commands and stream report 0x07
/// there with no handshake (`bleAltNotification`; no IMU). ONE stick
/// calibration is stored — recalibrate after switching generations.
///
/// Handlers fire on the main queue; the host's funnels are thread-safe.
final class JoyConInput: ObservableObject {

    /// Buttons, named by position on an upright left Joy-Con.
    enum Control: String, CaseIterable {
        case dpadUp = "Up", dpadDown = "Down"
        case dpadLeft = "Left", dpadRight = "Right"
        /// The shoulder family. L and ZL carry the default actions
        /// (strum, re-zero); SL and SR are unassigned.
        case l = "L", zl = "ZL"
        case sl = "SL", sr = "SR"
        /// Stick click, Minus, Capture — unassigned, shown as panel chips.
        case stickClick = "Stick", minus = "Minus", capture = "Capture"
    }

    /// THE ARM AXES: arm ↕, ↔, ⟲, each −1…+1 (rest 0, sweep extremes ±1),
    /// from `armCal`'s joint least-squares solve over the iPad's raw tilt
    /// report (`armTick`). Change-gated + quantized. Main thread.
    var onArmAxes: ((Double, Double, Double) -> Void)?
    /// The stick as two axes (−1…+1, centre 0): per-axis gate + rescale,
    /// change-gated. Main thread.
    var onStickAxes: ((Double, Double) -> Void)?
    var onButton: ((_ control: Control, _ pressed: Bool) -> Void)?
    /// WRIST display: the Joy-Con's fused attitude as three −1…+1 axes
    /// (pitch/roll ±90° full scale, yaw wrapped ±180°) for the iPad's
    /// wrist square. ~10 Hz, main thread; nil = fusion gone. Display only.
    var onWristAttitude: (((Double, Double, Double)?) -> Void)?
    /// THE WRIST CONTROL AXES: wrist ↕, ↔, ⟲ (−1…+1, rest 0) from
    /// `wristCal` over the fused attitude — fires only while a wrist
    /// calibration exists; change-gated + quantized. Main thread.
    var onWristAxes: ((Double, Double, Double) -> Void)?
    /// JOY-CON ACCELERATION: gravity-removed acceleration magnitude through
    /// the strike law + envelope, 0…1 (unipolar), change-gated at 1/256,
    /// every IMU packet. Main thread. 0 on detach.
    var onJoyConAccel: ((Double) -> Void)?

    // Setup-tab monitor state. Written on the main queue; the stick and
    // raw-event fields are throttled to ~15 Hz (the control path is not).
    @Published private(set) var connectedName: String?
    /// Raw stick, −1…+1 per axis.
    @Published private(set) var stickX = 0.0
    @Published private(set) var stickY = 0.0
    /// True while the stick is outside the deadzone.
    @Published private(set) var stickActive = false
    @Published private(set) var buttonsDown: Set<Control> = []
    /// The last raw element event, named by the OS.
    @Published private(set) var lastEvent = "—"
    /// Element inventory, one line per PHYSICAL element with its alias
    /// names joined ("Direction Pad / Left Thumbstick" = one element).
    @Published private(set) var elementNames: [String] = []

    // RAW HID SIDE-CHANNEL. macOS presents a lone Joy-Con as a `GCGamepad`
    // (no L/ZL, the stick a DIGITAL 8-way hat), so an `IOHIDManager` reads
    // the raw reports in parallel (read-only — gamecontrollerd keeps the GC
    // profile): L/ZL from the button bytes, the 12-bit stick in full mode.
    /// "open" or the failing IOReturn — shown in the panel.
    @Published private(set) var hidStatus = "off"
    /// Last raw input report (hex, truncated).
    @Published private(set) var hidReportHex = "—"
    /// Raw analog stick from the HID report, −1…+1, device frame.
    @Published private(set) var hidAxes: [Double] = []

    private var attached: GCController?
    private var observers: [NSObjectProtocol] = []
    /// Per-axis deflection gate: |v| below this pins the axis to exact
    /// centre (the neutral drifts). Both axes under threshold = rest.
    private let deadzone = 0.1
    /// A LONE Joy-Con is presented SIDEWAYS; held UPRIGHT, stick and face
    /// buttons rotate 90° back (upright (x, y) → sideways (−y, x)). A
    /// paired L+R duo ("Joy-Con (L/R)") is a real gamepad — no rotation.
    private var rotateForUpright = false
    private var lastStickPublish: CFAbsoluteTime = 0
    private var lastEventPublish: CFAbsoluteTime = 0
    /// The BLE client's status line for the panel (Joy-Con 2 never appear
    /// in macOS Bluetooth settings; the connection lives in `JoyCon2BLE`).
    @Published private(set) var bleStatus = "off"
    /// Joy-Con 2 IMU, panel display (~10 Hz): [ax, ay, az] in g, then
    /// [gx, gy, gz] in °/s (raw i16 scaled: ±8 g → /4096, ±2000 °/s →
    /// /16.4). Empty until real frames arrive.
    @Published private(set) var bleIMU: [Double] = []
    private var lastIMUPublish: CFAbsoluteTime = 0
    private var bleDown: Set<Control> = []
    private let ble = JoyCon2BLE()

    // ORIENTATION FUSION, complementary filter: the body-frame gravity
    // estimate `gHat` integrates the gyro (ġ = g × ω) and is pulled slowly
    // toward the accelerometer; yaw integrates the gyro about gravity.
    private var gHat: SIMD3<Double>?
    private var gyroBias = SIMD3<Double>.zero
    private var yaw = 0.0
    private var lastIMUTime: CFAbsoluteTime = 0
    // 9-AXIS (Joy-Con 2 only). The mag pins yaw: hard-iron offset = the
    // running min/max midpoint, IGNORED until the seen extremes span most
    // of the field sphere; the corrected horizontal field drives a north
    // estimate `nHat` (ṅ = n × ω) that pulls yaw gently toward heading.
    private var nHat: SIMD3<Double>?
    private var magMin: SIMD3<Double>?
    private var magMax: SIMD3<Double>?
    /// Fused attitude for the panel (~10 Hz): [pitch°, roll°, yaw°].
    /// roll = atan2(gy, gz), pitch = atan2(−gx, √(gy²+gz²)); yaw = heading
    /// of the device x-axis about gravity (mag-pinned when `yawPinned`).
    @Published private(set) var fusedAttitude: [Double] = []
    /// True while yaw is being corrected toward magnetic heading.
    @Published private(set) var yawPinned = false
    private var lastFusedPublish: CFAbsoluteTime = 0

    // TILT CALIBRATIONS: two INDEPENDENT `TiltCalibrator`s (guided rest +
    // three-sweep capture). ARM: the iPad's raw tilt report (`armTick`).
    // WRIST: the Joy-Con's fused attitude, ticked from `processIMU`. Their
    // published state is forwarded into this object's `objectWillChange`.
    let armCal = TiltCalibrator(config: .arm)
    let wristCal = TiltCalibrator(config: .wrist)
    private var calSinks: [AnyCancellable] = []
    private var lastArmMsgT: CFAbsoluteTime = 0
    /// The latest calibrated wrist axes — the iPad's wrist square shows
    /// these instead of the raw attitude once calibrated.
    private var lastWristAxes: (Double, Double, Double)?
    /// The wrist feature's RELATIVE yaw: wrap-safe increments of the fused
    /// yaw, drift-rate-learned while quiescent (< ~0.57°/s, ~10 s constant)
    /// and leaked to zero over 60 s, so gyro drift can't rail the axis.
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

    /// Raw-stream trail for the Setup panel's received-motion view: the
    /// UNSMOOTHED per-message feature vectors, last ~8 s. Not published —
    /// the view reads `liveTrace` inside its 60 Hz TimelineView tick.
    struct RawTiltSample {
        var t: CFAbsoluteTime
        var raw: SIMD3<Double>
    }
    private var rawBuf: [RawTiltSample] = []
    private static let traceWindow: CFAbsoluteTime = 8
    /// Flips once when the first tilt message lands — gates the panel.
    @Published private(set) var traceActive = false
    /// Received raw accelerometer trail (g, gravity removed), display only.
    struct RawAccelSample {
        var t: CFAbsoluteTime
        var a: SIMD3<Double>
    }
    private var accelBuf: [RawAccelSample] = []
    /// The Joy-Con's own IMU trails (device frame, ~8 s): gyro in °/s,
    /// accel in g (INCLUDES gravity — at rest on the 1 g sphere),
    /// magnetometer in raw i16 (Joy-Con 2 only).
    private var jcGyroBuf: [RawAccelSample] = []
    private var jcAccelBuf: [RawAccelSample] = []
    private var jcMagBuf: [RawAccelSample] = []
    /// FUSED trails (Joy-Con 2 only — filled by `processIMU`): attitude
    /// [pitch, roll, yaw] in radians, and linear acceleration in g with
    /// the gravity estimate subtracted (rests at the origin).
    private var jcAttitudeBuf: [RawAccelSample] = []
    private var jcLinAccelBuf: [RawAccelSample] = []
    /// Flips once when the first fused sample lands — gates the fused
    /// panels (stays false for classic Joy-Cons).
    @Published private(set) var jcFusedActive = false
    /// Flip once when the first NON-ZERO IMU / magnetometer sample lands —
    /// they gate the Setup panels.
    @Published private(set) var jcIMUActive = false
    @Published private(set) var jcMagActive = false
    /// Live reads for the Setup panel's 60 Hz TimelineViews. Main thread
    /// only (these buffers and the calibrators are written on main).
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
        // A reconnected Joy-Con re-earns its hard-iron estimate.
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

    /// iPad raw accelerometer in (link receive queue) — display only.
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
    // The ARM input: the iPad's raw tilt report (MIDI thread → main).
    private let armLock = NSLock()
    private var armTilt = SIMD3<Double>(0, 0, 0)
    private var armTime: CFAbsoluteTime = 0

    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private let hidReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    /// Controls held according to the raw HID reports.
    private var hidDown: Set<Control> = []
    private var lastHIDPublish: CFAbsoluteTime = 0
    /// FULL MODE: simple mode (0x3F) sends filler axis fields — real 12-bit
    /// stick data streams only in full mode (0x30), entered via subcommand
    /// 0x03/0x30 on output report 0x01; then the GC handlers stand down.
    private var hidFullMode = false
    private var hidPacketCounter: UInt8 = 0
    private var modeSwitchTries = 0
    /// Uncalibrated fallback: rest from the first samples + a fixed span.
    private var hidStickCenter: (x: Double, y: Double)?
    private var hidCenterAccum: [(Double, Double)] = []
    /// 12-bit units of full deflection from centre (typical span; the
    /// output is clamped).
    private let hidStickSpan = 1400.0

    // STICK CALIBRATION. The gate is a circle around an off-centre rest,
    // so per-axis min/max can never send a diagonal to (±1, ±1): the RIM
    // is captured as a radius per angle bin (sweep a full circle) and
    // mapped circle → square at runtime (diagonal rim = (1, 1)). Persisted.
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

    /// Start the two-phase calibration: rest capture, then the rim sweep
    /// until `finishCalibration`. The stick stops driving axes meanwhile.
    func beginCalibration() {
        calRestAccum = []
        calDraft = nil
        calPhase = .rest
        calInfo = "Hold the stick at rest (playing grip)…"
    }

    func finishCalibration() {
        defer { calPhase = .idle }
        guard let d = calDraft else { return }
        // Every bin must have been swept — an empty one divides by ~zero.
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

    /// Rest-relative raw offset → the unit square: radius normalized by
    /// the interpolated rim radius at this angle, then scaled so the larger
    /// component reaches 1 at the rim (circle → square).
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
            // calibration carries on.
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

    /// One Joy-Con 2 report-0x05 notification: buttons as a LE u32 at bytes
    /// 4–7 — left Joy-Con: dpad Down/Up/Right/Left = bits 16–19, SR 20,
    /// SL 21, L 22, ZL 23; shared: Minus 8, stick click 11, Capture 13 —
    /// and the 12-bit packed stick at bytes 10–12, device frame.
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
        if b & (1 << 8) != 0 { down.insert(.minus) }
        if b & (1 << 11) != 0 { down.insert(.stickClick) }
        if b & (1 << 13) != 0 { down.insert(.capture) }
        for c in down.subtracting(bleDown) { setButton(c, true) }
        for c in bleDown.subtracting(down) { setButton(c, false) }
        bleDown = down
        let s0 = Double(Int(d[10]) | (Int(d[11] & 0x0F) << 8))
        let s1 = Double((Int(d[11]) >> 4) | (Int(d[12]) << 4))
        processRawStick(s0, s1)
        // IMU (63-byte report): accel i16 LE ×3 at 0x30, gyro ×3 at 0x36,
        // classic scales (±8 g → /4096, ±2000 °/s → /16.4). Judge axes
        // against the FUSED panels, not the raw trails; if a 90°-in-1 s
        // turn reads ~730 °/s the JC2 gyro scale is 133.3 LSB/°/s instead.
        if d.count >= 0x3C {
            func i16(_ o: Int) -> Double {
                Double(Int16(bitPattern: UInt16(d[o]) | (UInt16(d[o + 1]) << 8)))
            }
            let accelG = SIMD3(i16(0x30), i16(0x32), i16(0x34)) / 4096.0
            let gyroDps = SIMD3(i16(0x36), i16(0x38), i16(0x3A)) / 16.4
            // Magnetometer: i16 ×3 at 0x19, raw units; streams only with
            // FEATURE_MAGNETOMETER (0x80) in the feature-enable flags. The
            // panel appears only on non-zero data.
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

    /// THIRD-PARTY ALTERNATE INPUT: report 0x07 on CC1BBBB5-… (the Mobacon
    /// clone's stream). Byte 0 = counter; byte 2: Down 0x01, Right 0x02,
    /// Left 0x04, Up 0x08, L 0x10 (the M2 paddle mirrors it), ZL 0x20,
    /// Minus 0x40, stick click 0x80; byte 3: Capture 0x01, SR 0x40, SL
    /// 0x80; 12-bit packed stick at bytes 5–7; byte 4 = constant flags.
    /// A button change dumps the full report for mapping.
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
        // Motion: a LENGTH byte at 0x0E ({0, 30, 40}) + an undecoded packed
        // blob at 0x0F — not parsed; logged once if a device fills it.
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

    /// Raw HID listener (see the side-channel note above). Scheduled on
    /// the main run loop, so callbacks land on main like the GC handlers.
    private func startHID() {
        if let data = UserDefaults.standard.data(forKey: Self.calKey),
           let cal = try? JSONDecoder().decode(StickCal.self, from: data) {
            stickCal = cal
        }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOHIDOptionsType(kIOHIDOptionsTypeNone))
        hidManager = mgr
        // Nintendo VID; the matching callback narrows to Joy-Cons.
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

    /// Ask for full input mode (60 Hz 0x30 reports): output report 0x01,
    /// neutral rumble bytes, subcommand 0x03, argument 0x30. Retried a few
    /// times — the arrival of a 0x30 report is the ack.
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

    /// Enable the classic Joy-Con's IMU (subcommand 0x40, argument 0x01)
    /// once full mode is confirmed; retried until non-zero motion arrives
    /// (`jcIMUActive` is the ack).
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
    /// byte 2 bits 6/7. Full mode (0x30/0x21): the left-side button byte
    /// (arrows, SL/SR, L/ZL, UPRIGHT frame) and the 12-bit stick at bytes
    /// 6–8. The report-ID byte may or may not be in the buffer — detected.
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
                // GC bindings stand down; release any press they delivered.
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
            // Shared button byte: minus, left-stick click, capture.
            let shared = report[base + 3]
            if shared & 0x01 != 0 { down.insert(.minus) }
            if shared & 0x08 != 0 { down.insert(.stickClick) }
            if shared & 0x20 != 0 { down.insert(.capture) }
            let s0 = Double(Int(report[base + 5]) | (Int(report[base + 6] & 0x0F) << 8))
            let s1 = Double((Int(report[base + 6]) >> 4) | (Int(report[base + 7]) << 4))
            processRawStick(s0, s1)
            // IMU (zeros until subcommand 0x40 enables it): three 12-byte
            // frames ~5 ms apart at base+12 — accel i16 ×3 (4096 LSB/g)
            // then gyro i16 ×3 (16.4 LSB per °/s), device frame.
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

    /// The shared raw-stick pipeline — HID full mode and BLE both land here
    /// with 12-bit device-frame values: the calibration state machine, then
    /// the calibrated map into `handleStick`.
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
                    // Uncalibrated fallback: rest from the first samples.
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

    /// One controller at a time — the first to appear wins.
    private func attach(_ c: GCController) {
        guard attached == nil else { return }
        attached = c
        connectedName = c.vendorName ?? c.productCategory
        c.handlerQueue = .main
        let profile = c.physicalInputProfile

        var groups: [ObjectIdentifier: [String]] = [:]
        for (name, el) in profile.elements {
            groups[ObjectIdentifier(el), default: []].append(name)
        }
        elementNames = groups.values
            .map { $0.sorted().joined(separator: " / ") }.sorted()
        NSLog("Tarabdaar: game controller attached — %@ [%@]",
              connectedName ?? "?", elementNames.joined(separator: ", "))

        profile.valueDidChangeHandler = { [weak self] _, element in
            self?.noteRawEvent(element)
        }

        let cat = c.productCategory
        rotateForUpright = cat.localizedCaseInsensitiveContains("joy-con")
            && !cat.localizedCaseInsensitiveContains("l/r")

        // The stick: left thumbstick, else right, else a lone Direction Pad.
        let stick = profile.dpads[GCInputLeftThumbstick]
            ?? profile.dpads[GCInputRightThumbstick]
            ?? profile.dpads[GCInputDirectionPad]
        stick?.valueChangedHandler = { [weak self] _, x, y in
            guard let self, !self.hidFullMode else { return }
            if self.rotateForUpright {
                // Sideways frame → upright: x = y_os, y = −x_os.
                self.handleStick(x: Double(y), y: Double(-x))
            } else {
                self.handleStick(x: Double(x), y: Double(y))
            }
        }

        // A d-pad element only when DISTINCT from the stick (alias trap)…
        if let dpad = profile.dpads[GCInputDirectionPad], dpad !== stick {
            bind(dpad.up, .dpadUp)
            bind(dpad.down, .dpadDown)
            bind(dpad.left, .dpadLeft)
            bind(dpad.right, .dpadRight)
        }
        // …and the sideways A/B/X/Y, rotated 90° CCW: A=↓, B=←, X=→, Y=↑.
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

        // Shoulder family: L/ZL naming is presentation-dependent, bind all.
        if rotateForUpright {
            // Sideways: the rail's SL/SR are Left/Right Shoulder.
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
        bind(profile.buttons[GCInputButtonOptions], .minus)
        bind(profile.buttons[GCInputLeftThumbstickButton], .stickClick)

        // GC MOTION (classic-Bluetooth pads: Pro Controller presentations,
        // multi-mode pads in Switch-1 mode) — same fusion + panels as the
        // BLE path; acceleration includes gravity, rotation rate in rad/s.
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
        // Keep the IMU trails while a BLE controller still feeds them.
        if !bleStatus.hasPrefix("connected") { clearJoyConIMU() }
    }

    /// GC bindings stand down in HID full mode: the 0x30 report carries
    /// every button, and clones alias the GC face buttons unpredictably
    /// (a distinct dpad PLUS a rotated A/B/X/Y — each press firing twice).
    private func bind(_ button: GCControllerButtonInput?, _ control: Control) {
        button?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, !self.hidFullMode else { return }
            self.setButton(control, pressed)
        }
    }

    /// Shared button funnel — every input path lands here (main thread).
    private func setButton(_ control: Control, _ pressed: Bool) {
        if pressed { buttonsDown.insert(control) }
        else { buttonsDown.remove(control) }
        onButton?(control, pressed)
    }

    private var lastStickSent: (Double, Double)?

    /// Deadzone gate, rescaled for continuity (deadzone → 0, full → ±1).
    private func gate(_ v: Double) -> Double {
        guard abs(v) >= deadzone else { return 0 }
        return (v - (v < 0 ? -deadzone : deadzone)) / (1 - deadzone)
    }

    /// The stick path → its two axes: gated, quantized (~9 bits),
    /// change-gated — a held or centred stick is silent.
    private func handleStick(x: Double, y: Double) {
        // Throttled monitor publish; the rest position always lands.
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

    /// iPad raw-tilt in (MIDI thread — the only cross-thread entry). Returns
    /// true when the arm calibration CONSUMES the value (one exists or is
    /// being captured); the caller must then not pass it to the axes.
    func feedArmTilt(_ axis: Int, _ value: Double) -> Bool {
        armLock.lock()
        if axis >= 0, axis < 3 {
            armTilt[axis] = value
            armTime = CFAbsoluteTimeGetCurrent()
        }
        let f = [armTilt.x, armTilt.y, armTilt.z]
        armLock.unlock()
        let consumed = armCal.isActive
        DispatchQueue.main.async { [weak self] in self?.armTick(f) }
        return consumed
    }

    /// One arm-stream tick on main: the raw trail (frame-coalesced — the
    /// wire delivers one axis per message; `TiltCalibrator.frameGap`),
    /// then the calibrator (capture or solve → `onArmAxes`).
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

    /// The calibration currently CAPTURING — the dpad-up/down target.
    var capturingCalibrator: TiltCalibrator? {
        armCal.isCapturing ? armCal : (wristCal.isCapturing ? wristCal : nil)
    }

    /// Dpad-up: advance whichever capture is running (no-op otherwise).
    func advanceCalibration() { capturingCalibrator?.advance() }

    /// Dpad-down during a capture: step it back one phase.
    func redoPreviousCalibrationStep() { capturingCalibrator?.redoPrevious() }

    /// ZL: the CURRENT poses become rest on BOTH calibrations without
    /// re-fitting the directions.
    func recenterBody() {
        armCal.recenter()
        wristCal.recenter()
    }

    /// One fused IMU step (accel g; gyro rad/s; mag raw, Joy-Con 2 only):
    /// the fused panels, the wrist calibrator tick, the acceleration axis.
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
            // Trust the hard-iron midpoint only after broad rotation coverage.
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
                        // Mag yaw: device x-axis heading from north, wrap-aware.
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
        // Fused trails, every packet: attitude in radians (yaw continuous —
        // no jump at ±180°); linear accel = accel − unit gravity, in g.
        let att = SIMD3(atan2(-g.x, (g.y * g.y + g.z * g.z).squareRoot()),
                        atan2(g.y, g.z),
                        yaw)
        let lin = accelG - g
        jcAttitudeBuf.append(RawAccelSample(t: now, a: att))
        jcLinAccelBuf.append(RawAccelSample(t: now, a: lin))
        // THE WRIST FEATURE: gravity pitch/roll plus the relative yaw, all
        // at ±90° full scale, −1…+1, into the wrist calibrator every
        // packet (capture, or solve → `onWristAxes`).
        updateRelativeYaw(att.z, dt: dt)
        let wristF = SIMD3(att.x, att.y, yawRel) / (.pi / 2)
        wristCal.tick(simd_clamp(wristF, SIMD3(repeating: -1), SIMD3(repeating: 1)),
                      at: now)
        // THE JOY-CON ACCELERATION AXIS: |accel − ĝ| through the strike
        // law and its fast-attack / 150 ms-decay envelope, 0…1, change-
        // gated at 1/256.
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
            // Calibrated: the iPad's wrist square shows the SOLVED axes.
            if wristCal.isCalibrated, let w = lastWristAxes {
                onWristAttitude?(w)
                return
            }
            // Raw display axes: pitch/roll ±90°, yaw wrapped ±180°, −1…+1.
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

    /// Wrap-safe yaw increments, drift rate learned while quiescent and
    /// subtracted, leaked toward zero with `yawLeakTau`.
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

/// CoreBluetooth client for Switch 2 Joy-Cons: scan broadly, filter on
/// Nintendo's manufacturer-data company ID, connect, run the console-style
/// init, subscribe to the input characteristic, forward notifications.
/// First connection needs the Joy-Con advertising — hold its sync button.
/// One peripheral at a time; rescans when unconnected. Main-queue delegate.
final class JoyCon2BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
    static let inputCharacteristic = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")
    /// The `0x91`-framed command channel (the classic `30 …` subcommand
    /// format is IGNORED by Joy-Con 2): commands write here, acks arrive
    /// on the response characteristic.
    static let commandWriteCharacteristic =
        CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")
    static let commandResponseCharacteristic =
        CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A")
    /// The controller-specific report-0x07 characteristic — where clones
    /// stream their input (`bleAltNotification`).
    static let altInputCharacteristic =
        CBUUID(string: "CC1BBBB5-7354-4D32-A716-A81CB241A32A")
    /// Nintendo's Bluetooth SIG company identifier — NOT 0x057E (their USB
    /// vendor ID, which appears further into the payload: a live Joy-Con 2
    /// (L) advertises `53 05 01 00 03 7e 05 67 20 …`, name empty).
    private static let nintendoCompanyID: UInt16 = 0x0553

    var onStatus: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onNotification: ((Data) -> Void)?
    /// Notifications from the alternate input characteristic — forwarded
    /// only while the standard input characteristic stays silent.
    var onAltNotification: ((Data) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The command write characteristic.
    private var outputCharacteristic: CBCharacteristic?
    private var inputCharacteristic: CBCharacteristic?
    private var cmdRespCharacteristic: CBCharacteristic?
    private var ledSent = false
    private var initStarted = false
    // Wire diagnostics (Console filter `Tarabdaar ble`): arrival/rate, and
    // a full hex dump whenever the button word (bytes 4–7) changes.
    private var notifCount = 0
    private var lastNotifLog: CFAbsoluteTime = 0
    private var lastButtonWord: UInt32?
    /// Per-characteristic log throttle for unknown characteristics.
    private var lastCharLog: [CBUUID: CFAbsoluteTime] = [:]
    // MOTION-ENABLE PROBE (clones only): walk every write-capable
    // characteristic × two command dialects (0x91 feature-enable, classic
    // subcommand mode+IMU), one per 1.2 s, watching the motion-length byte.
    private var probeChars: [CBCharacteristic] = []
    private var probeStarted = false
    private var probeStep = -1
    private var altMotionSeen = false
    /// Notify-capable characteristics other than the standard input and
    /// command-response ones. Subscribed only by `scheduleAltFallback` — a
    /// real Joy-Con 2 silences report 0x05 the moment 0x07 is enabled.
    private var deferredNotifyChars: [CBCharacteristic] = []
    /// Silence allowed on the standard input characteristic before the
    /// clone fallback subscribes the rest (a real Joy-Con 2 streams within
    /// ~100 ms of the CCCD write).
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
        // The advertisement doesn't list the vendor service — scan broadly.
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
        // Name fallback only — a live Joy-Con 2 advertises an EMPTY name.
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
            // No vendor service — drop it and keep scanning.
            onStatus?("no Joy-Con 2 input service — skipping \(p.name ?? "device")")
            central?.cancelPeripheralConnection(p)
            return
        }
        // The command channel may live in another service — sweep all.
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
        // Read every readable characteristic: a write-without-response
        // cannot surface an ATT "insufficient authentication" error, a
        // READ does — and macOS then pairs itself. Other notify chars are
        // only COLLECTED here (see `deferredNotifyChars`).
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
        // A device exposing the input characteristic without the command
        // channel: subscribe directly.
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

    /// CLONE FALLBACK: if no report-0x05 notification has arrived
    /// `altFallbackDelay` after the standard subscribe, subscribe every
    /// other notify characteristic (a real Joy-Con 2 never reaches this).
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

    /// CONSOLE-STYLE INIT: a real Joy-Con 2 streams on subscribe alone, but
    /// clones wait for the console handshake (and drop the link after
    /// 60 s). Sequence: controller-info read → player LED → vibration
    /// preset (tactile proof) → feature init/enable → INPUT subscribe LAST,
    /// paced by delay rather than acks (a clone that acks nothing stalls).
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

    /// Assign the player-number LEDs — without this the lights race
    /// forever. `0x91` framing on the command characteristic: command 0x09
    /// = LEDs, subcommand 0x07 = set player, pattern 0x01 = player 1.
    private func setPlayerLED(_ player: Int) {
        let patterns: [UInt8] = [0x01, 0x03, 0x07, 0x0F, 0x09, 0x05, 0x0D, 0x06]
        writeCommand(0x09, 0x07,
                     [patterns[max(0, min(7, player - 1))], 0x00, 0x00, 0x00])
        ledSent = true
    }

    /// Feature init + enable: 0x07 = base | FEATURE_MOTION 0x04, 0x80 =
    /// FEATURE_MAGNETOMETER (the mag block at 0x19). The two commands MUST
    /// be spaced 150 ms: back to back, the ack returns zeros, motion off.
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

    /// Motion-probe success detector: report 0x07's motion-length byte at
    /// 0x0E is 0 with the IMU off, 30 or 40 once enabled.
    private func checkAltMotion(_ d: Data) {
        guard !altMotionSeen, d.count > 0x0E else { return }
        let nonzero = d[0x0E] != 0
        if nonzero {
            altMotionSeen = true
            NSLog("Tarabdaar ble: ALT MOTION LIVE — IMU region nonzero (after probe step %d)",
                  probeStep)
        }
    }

    /// Raw write for the motion probe — any characteristic.
    private func probeWrite(_ ch: CBCharacteristic, _ bytes: [UInt8]) {
        guard let p = peripheral else { return }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse
                                                          : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    /// Walk every write-capable characteristic with both command dialects.
    /// Steps stop the moment `checkAltMotion` fires.
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
            // An "insufficient authentication" ATT error = a paired link is
            // wanted; macOS follows up by pairing.
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
            // Report-0x07 stream (clone fallback): forwarded only while the
            // standard characteristic is silent — never races the 0x05 parse.
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
            // Reads and unknown-characteristic notifications, throttled.
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
        // If the LED write raced discovery, re-send once input flows.
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
