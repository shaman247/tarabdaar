import Combine
import Foundation
import GameController
import TarabdaarCore
import simd

/// Supplemental game-controller input: a Nintendo Switch Joy-Con (L) over
/// Bluetooth, or any GameController device with a stick and buttons.
/// Additive beside the iPad — it feeds the same host funnels (control
/// axes, drone buttons).
///
/// THE SHAPE (three bearers, one coordinator). Each way a Joy-Con can
/// reach this app is its own `JoyConTransport` (one file each) — the GameController
/// profile, the raw IOHID side-channel, the Switch 2 vendor GATT — and
/// each parses its own wire format into the platform-neutral
/// `JoyConReport`. `JoyConInput` is then a thin coordinator: it hands
/// reports to `JoyConMapper` (button edges, stick deadband + calibration)
/// and `JoyConFusion` (attitude, wrist features, the acceleration axis),
/// both in TarabdaarCore and unit-tested, and it owns everything the
/// Setup panel draws plus the two guided `TiltCalibrator` flows. The
/// transports stay Mac-side because they ARE the frameworks.
///
/// Stick → its own two axes (−1…+1); buttons → semantic `Control` events
/// named by the UPRIGHT grip (macOS presents a lone Joy-Con SIDEWAYS;
/// `attach` rotates stick + face diamond 90° back).
///
/// **Alias trap:** a `GCPhysicalInputProfile` names one physical element
/// under several keys — a lone Joy-Con's stick is both "Left Thumbstick"
/// AND "Direction Pad", so binding the d-pad without an identity check
/// turns stick deflection into button presses. `attach` resolves the
/// stick first and binds only a DISTINCT Direction Pad element.
///
/// **Switch 2 Joy-Con:** BLE-only, vendor GATT — macOS cannot pair them
/// and neither GameController nor IOHID sees them. `JoyCon2BLE` (`JoyConBLE.swift`)
/// owns the connection; `JoyConBLETransport` parses report 0x05 from the
/// standard characteristic …7FD2 into the same funnels. The controller-
/// specific characteristic CC1BBBB5-… carries report 0x07 (undecoded
/// packed motion); a real Joy-Con 2 switches to 0x07 and SILENCES 0x05
/// the moment 0x07 is subscribed, so it is enabled only as the clone
/// fallback after `altFallbackDelay` of silence — third-party clones
/// (Mobacon) mimic the GATT, ignore 0x91 commands and stream report 0x07
/// there with no handshake (`.bleAlt` reports; no IMU). ONE stick
/// calibration is stored — recalibrate after switching generations.
///
/// Handlers fire on the main queue; the host's funnels are thread-safe.
final class JoyConInput: ObservableObject {

    /// Buttons, named by position on an upright left Joy-Con. The type
    /// lives in TarabdaarCore beside the mapper that reads it; the alias
    /// keeps `JoyConInput.Control` spelled as the panels spell it.
    typealias Control = JoyConControl
    typealias RawTiltSample = JoyConRawTiltSample
    typealias RawAccelSample = JoyConVectorSample
    typealias StickCal = JoyConStickCal
    typealias CalPhase = JoyConStickCalPhase

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

    /// The BLE client's status line for the panel (Joy-Con 2 never appear
    /// in macOS Bluetooth settings; the connection lives in `JoyCon2BLE`).
    @Published private(set) var bleStatus = "off"
    /// Joy-Con 2 IMU, panel display (~10 Hz): [ax, ay, az] in g, then
    /// [gx, gy, gz] in °/s (raw i16 scaled: ±8 g → /4096, ±2000 °/s →
    /// /16.4). Empty until real frames arrive.
    @Published private(set) var bleIMU: [Double] = []
    /// Fused attitude for the panel (~10 Hz): [pitch°, roll°, yaw°].
    /// roll = atan2(gy, gz), pitch = atan2(−gx, √(gy²+gz²)); yaw = heading
    /// of the device x-axis about gravity (mag-pinned when `yawPinned`).
    @Published private(set) var fusedAttitude: [Double] = []
    /// True while yaw is being corrected toward magnetic heading.
    @Published private(set) var yawPinned = false
    /// Panel readout of the acceleration envelope (~10 Hz).
    @Published private(set) var joyConAccelLevel = 0.0
    /// The stick calibration's phase + live summary (panel buttons).
    @Published private(set) var calPhase: CalPhase = .idle
    @Published private(set) var calInfo = ""

    // THE BEARERS. All three run at once — a classic Joy-Con is seen by
    // GameController AND IOHID (the HID full-mode stream then wins, see
    // `standDown`), a Joy-Con 2 only over BLE.
    private let gc = JoyConGameControllerTransport()
    private let hid = JoyConHIDTransport()
    private let bleTransport = JoyConBLETransport()
    /// The pure report → control mapping (button edges, stick deadband
    /// and calibration). TarabdaarCore; `JoyConMapperTests` pins its laws.
    private let mapper = JoyConMapper()
    /// The orientation filter behind the wrist axes and the acceleration
    /// dimension. TarabdaarCore.
    private let fusion = JoyConFusion()

    private var lastStickPublish: CFAbsoluteTime = 0
    private var lastEventPublish: CFAbsoluteTime = 0
    private var lastIMUPublish: CFAbsoluteTime = 0
    private var lastFusedPublish: CFAbsoluteTime = 0
    private var lastHIDPublish: CFAbsoluteTime = 0
    private static let calKey = "tarabdaar.joyconStickCal.v2"

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

    // MARK: Trails (Setup panel)

    /// The Setup panel's display trails, last ~8 s each. Not published —
    /// the views read them inside their 60 Hz TimelineView ticks. Main
    /// thread only (written on main beside the calibrators).
    private static let traceWindow: CFAbsoluteTime = 8
    /// The arm stream: the UNSMOOTHED per-message feature vectors.
    private var rawBuf = TrailBuffer<RawTiltSample>()
    /// Received raw accelerometer (g, gravity removed).
    private var accelBuf = TrailBuffer<RawAccelSample>()
    /// The Joy-Con's own IMU (device frame): gyro in °/s, accel in g
    /// (INCLUDES gravity — at rest on the 1 g sphere), magnetometer in
    /// raw i16 (Joy-Con 2 only).
    private var jcGyroBuf = TrailBuffer<RawAccelSample>()
    private var jcAccelBuf = TrailBuffer<RawAccelSample>()
    private var jcMagBuf = TrailBuffer<RawAccelSample>()
    /// FUSED (Joy-Con 2 only — filled by `processIMU`): attitude
    /// [pitch, roll, yaw] in radians, and linear acceleration in g with
    /// the gravity estimate subtracted (rests at the origin).
    private var jcAttitudeBuf = TrailBuffer<RawAccelSample>()
    private var jcLinAccelBuf = TrailBuffer<RawAccelSample>()
    /// The panel gates — each flips once when its stream's first sample
    /// lands (`gatePanels`) and stays false for a stream the bearer never
    /// carries: the arm trail; the fused panels (classic Joy-Cons have
    /// none); the IMU panels (first NON-ZERO sample); the magnetometer
    /// (Joy-Con 2 only).
    @Published private(set) var traceActive = false
    @Published private(set) var jcFusedActive = false
    @Published private(set) var jcIMUActive = false
    @Published private(set) var jcMagActive = false
    /// Live reads for the Setup panel's 60 Hz TimelineViews.
    var liveTrace: [RawTiltSample] { rawBuf.samples }
    var liveAccelTrace: [RawAccelSample] { accelBuf.samples }
    var liveJoyConGyro: [RawAccelSample] { jcGyroBuf.samples }
    var liveJoyConAccel: [RawAccelSample] { jcAccelBuf.samples }
    var liveJoyConMag: [RawAccelSample] { jcMagBuf.samples }
    var liveJoyConAttitude: [RawAccelSample] { jcAttitudeBuf.samples }
    var liveJoyConLinAccel: [RawAccelSample] { jcLinAccelBuf.samples }
    var liveArmPos: SIMD3<Double>? { armCal.livePos }

    /// The one place the panel gates flip: an append site names the
    /// streams it just fed, and a gate that is still closed opens.
    private func gatePanels(trace: Bool = false, fused: Bool = false,
                            imu: Bool = false, mag: Bool = false) {
        if trace, !traceActive { traceActive = true }
        if fused, !jcFusedActive { jcFusedActive = true }
        if imu, !jcIMUActive { jcIMUActive = true }
        if mag, !jcMagActive { jcMagActive = true }
    }

    /// Append one Joy-Con IMU sample set (main thread).
    private func appendJoyConIMU(t: CFAbsoluteTime,
                                 gyroDps: SIMD3<Double>,
                                 accelG: SIMD3<Double>,
                                 mag: SIMD3<Double>? = nil) {
        let cutoff = t - Self.traceWindow
        jcGyroBuf.append(RawAccelSample(t: t, a: gyroDps))
        jcAccelBuf.append(RawAccelSample(t: t, a: accelG))
        jcGyroBuf.trim(before: cutoff)
        jcAccelBuf.trim(before: cutoff)
        if let mag {
            jcMagBuf.append(RawAccelSample(t: t, a: mag))
            jcMagBuf.trim(before: cutoff)
        }
        gatePanels(imu: gyroDps != .zero || accelG != .zero,
                   mag: mag.map { $0 != .zero } ?? false)
    }

    private func clearJoyConIMU() {
        jcGyroBuf.removeAll()
        jcAccelBuf.removeAll()
        jcMagBuf.removeAll()
        jcIMUActive = false
        jcMagActive = false
        hid.resetIMUEnableTries()
        // A reconnected Joy-Con re-earns its hard-iron estimate.
        let wasSendingAccel = fusion.reset()
        if yawPinned { yawPinned = false }
        fusedAttitude = []
        jcAttitudeBuf.removeAll()
        jcLinAccelBuf.removeAll()
        jcFusedActive = false
        onWristAttitude?(nil)
        lastWristAxes = nil
        joyConAccelLevel = 0
        if wasSendingAccel { onJoyConAccel?(0) }
    }

    /// iPad raw accelerometer in (link receive queue) — display only.
    func feedAccel(_ x: Double, _ y: Double, _ z: Double) {
        let a = SIMD3(x, y, z)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.accelBuf.append(RawAccelSample(t: now, a: a))
            self.accelBuf.trim(before: now - Self.traceWindow)
        }
    }

    // The ARM input: the iPad's raw tilt report (MIDI thread → main).
    private let armLock = NSLock()
    private var armTilt = SIMD3<Double>(0, 0, 0)

    // MARK: Start — wiring the three bearers

    func start() {
        if let data = UserDefaults.standard.data(forKey: Self.calKey),
           let cal = try? JSONDecoder().decode(StickCal.self, from: data) {
            mapper.stickCal = cal
        }

        gc.onReport = { [weak self] r in self?.handle(r) }
        gc.onAttach = { [weak self] name, elements in
            guard let self else { return }
            self.connectedName = name
            self.elementNames = elements
        }
        gc.onDetach = { [weak self] in
            guard let self else { return }
            self.connectedName = nil
            self.stickX = 0; self.stickY = 0
            self.stickActive = false
            self.mapper.clearButtons(source: .gameController)
            self.buttonsDown = []
            self.lastEvent = "—"
            self.elementNames = []
            // Keep the IMU trails while a BLE controller still feeds them.
            if !self.bleStatus.hasPrefix("connected") { self.clearJoyConIMU() }
        }
        gc.onRawEvent = { [weak self] element in self?.noteRawEvent(element) }
        // GC bindings stand down in HID full mode: the 0x30 report carries
        // every button, and clones alias the GC face buttons unpredictably
        // (a distinct dpad PLUS a rotated A/B/X/Y — each press firing twice).
        gc.standDown = { [weak self] in self?.hid.isFullMode ?? false }

        hid.onReport = { [weak self] r in self?.handle(r) }
        hid.onStatus = { [weak self] s in self?.hidStatus = s }
        hid.imuActive = { [weak self] in self?.jcIMUActive ?? false }
        hid.onFullMode = { [weak self] in
            // GC bindings stand down; release any press they delivered.
            self?.deliver(self?.mapper.releaseAll() ?? [])
        }
        hid.onRemoved = { [weak self] in
            guard let self else { return }
            self.deliver(self.mapper.release(source: .hid))
            self.hidReportHex = "—"
            self.hidAxes = []
            self.clearJoyConIMU()
            // Abort any calibration in progress.
            self.mapper.cancelCalibration()
            self.calPhase = self.mapper.calPhase
            self.calInfo = ""
            self.mapper.resetStickSend()
            self.onStickAxes?(0, 0)   // park the stick axes at centre
        }

        bleTransport.onReport = { [weak self] r in self?.handle(r) }
        bleTransport.onStatus = { [weak self] s in self?.bleStatus = s }
        bleTransport.onConnect = { [weak self] name in
            guard let self else { return }
            self.bleStatus = "connected — \(name)"
            NSLog("Tarabdaar: Joy-Con 2 connected over BLE — %@", name)
            if self.connectedName == nil { self.connectedName = name }
        }
        bleTransport.onDisconnect = { [weak self] in
            guard let self else { return }
            self.deliver(self.mapper.release(source: .ble))
            self.deliver(self.mapper.release(source: .bleAlt))
            self.bleIMU = []
            self.fusion.resetGravity()
            self.clearJoyConIMU()
            // A running WRIST capture has lost its stream; the arm
            // calibration carries on.
            if self.wristCal.isCapturing { self.wristCal.cancel() }
            if !self.gc.isAttached { self.connectedName = nil }
        }

        gc.connect()
        hid.connect()
        bleTransport.connect()
    }

    // MARK: The one report funnel

    /// Every bearer lands here (main thread): buttons through the mapper,
    /// stick through the calibration + deadband law, IMU into the trails
    /// and — where the bearer fuses — the orientation filter.
    private func handle(_ r: JoyConReport) {
        if let update = r.buttons {
            deliver(mapper.edges(update, from: r.source,
                                 generation: r.generation))
        }
        if let stick = r.stick {
            switch stick {
            case .unit(let x, let y): handleStick(x: x, y: y)
            case .raw(let s0, let s1): processRawStick(s0, s1)
            }
        }
        for s in r.imu {
            if r.fuseIMU {
                processIMU(accelG: s.accelG, gyroRadPerSec: s.gyroRadPerSec,
                           mag: s.mag, at: s.t)
            }
            appendJoyConIMU(t: s.t, gyroDps: s.gyroDps,
                            accelG: s.accelG, mag: s.mag)
        }
        if r.fuseIMU, let last = r.imu.last,
           r.timestamp - lastIMUPublish > 0.1 {
            lastIMUPublish = r.timestamp
            bleIMU = [last.accelG.x, last.accelG.y, last.accelG.z,
                      last.gyroDps.x, last.gyroDps.y, last.gyroDps.z]
        }
        if !r.hexBytes.isEmpty, r.timestamp - lastEventPublish > 0.2 {
            lastEventPublish = r.timestamp
            hidReportHex = r.hexPrefix + r.hexBytes
                .map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    /// Shared button funnel — every input path lands here (main thread).
    private func deliver(_ edges: [(Control, Bool)]) {
        guard !edges.isEmpty else { return }
        buttonsDown = mapper.buttonsDown
        for (control, pressed) in edges { onButton?(control, pressed) }
    }

    /// The shared raw-stick pipeline — HID full mode and BLE both land here
    /// with 12-bit device-frame values: the calibration state machine, then
    /// the calibrated map into `handleStick`.
    private func processRawStick(_ s0: Double, _ s1: Double) {
        let sample = mapper.ingestRawStick(s0, s1)
        if calPhase != mapper.calPhase { calPhase = mapper.calPhase }
        switch sample {
        case .capturingRest, .pending:
            break
        case .capturingRange:
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHIDPublish > 0.1 {
                lastHIDPublish = now
                calInfo = mapper.calSummary
            }
        case .axes(let x, let y):
            handleStick(x: x, y: y)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHIDPublish > 0.066 {
                lastHIDPublish = now
                hidAxes = [x, y]
            }
        }
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
        let out = mapper.gateStick(x: x, y: y)
        if out.active != stickActive { stickActive = out.active }
        if let axes = out.axes { onStickAxes?(axes.x, axes.y) }
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

    // MARK: Stick calibration (panel buttons)

    /// Start the two-phase calibration: rest capture, then the rim sweep
    /// until `finishCalibration`. The stick stops driving axes meanwhile.
    func beginCalibration() {
        mapper.beginCalibration()
        calPhase = mapper.calPhase
        calInfo = "Hold the stick at rest (playing grip)…"
    }

    func finishCalibration() {
        let result = mapper.finishCalibration()
        calPhase = mapper.calPhase
        switch result {
        case .noDraft:
            break
        case .discarded(let missing):
            calInfo = "Discarded — \(missing) rim segments unswept; do a full circle"
            NSLog("Tarabdaar: Joy-Con stick calibration discarded (%d empty rim bins)", missing)
        case .accepted(let d):
            if let data = try? JSONEncoder().encode(d) {
                UserDefaults.standard.set(data, forKey: Self.calKey)
            }
            calInfo = ""
            NSLog("Tarabdaar: Joy-Con stick calibrated — rest (%.0f, %.0f), rim %.0f…%.0f",
                  d.cx, d.cy, d.rim.min() ?? 0, d.rim.max() ?? 0)
        }
    }

    // MARK: The arm stream (iPad tilt)

    /// iPad raw-tilt in (MIDI thread — the only cross-thread entry). Returns
    /// true when the arm calibration CONSUMES the value (one exists or is
    /// being captured); the caller must then not pass it to the axes.
    /// One message = one axis = one main hop, carrying the whole vector
    /// by value (no heap traffic on the MIDI thread).
    func feedArmTilt(_ axis: Int, _ value: Double) -> Bool {
        armLock.lock()
        if axis >= 0, axis < 3 { armTilt[axis] = value }
        let f = armTilt
        armLock.unlock()
        let consumed = armCal.isActive
        DispatchQueue.main.async { [weak self] in self?.armTick(f) }
        return consumed
    }

    /// One arm-stream tick on main: the raw trail (frame-coalesced — the
    /// wire delivers one axis per message; `TiltCalibrator.frameGap`),
    /// then the calibrator (capture or solve → `onArmAxes`).
    private func armTick(_ raw: SIMD3<Double>) {
        let now = CFAbsoluteTimeGetCurrent()
        let newFrame = now - lastArmMsgT >= TiltCalibrator.frameGap
        lastArmMsgT = now
        let sample = RawTiltSample(t: now, raw: raw)
        if newFrame || rawBuf.isEmpty {
            rawBuf.append(sample)
        } else {
            rawBuf.replaceLast(sample)
        }
        rawBuf.trim(before: now - Self.traceWindow)
        gatePanels(trace: true)
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

    // MARK: Fusion → panels, wrist calibrator, acceleration axis

    /// One fused IMU step (`JoyConFusion` does the filter): the fused
    /// panels, the wrist calibrator tick, the acceleration axis.
    private func processIMU(accelG: SIMD3<Double>, gyroRadPerSec: SIMD3<Double>,
                            mag: SIMD3<Double>? = nil,
                            at now: CFAbsoluteTime) {
        guard let step = fusion.ingest(accelG: accelG,
                                       gyroRadPerSec: gyroRadPerSec,
                                       mag: mag, at: now) else { return }
        if step.yawPinned != yawPinned { yawPinned = step.yawPinned }
        // Fused trails, every packet: attitude in radians (yaw continuous —
        // no jump at ±180°); linear accel = accel − unit gravity, in g.
        let att = step.attitude
        jcAttitudeBuf.append(RawAccelSample(t: now, a: att))
        jcLinAccelBuf.append(RawAccelSample(t: now, a: step.linearAccel))
        // THE WRIST FEATURE: gravity pitch/roll plus the relative yaw, all
        // at ±90° full scale, −1…+1, into the wrist calibrator every
        // packet (capture, or solve → `onWristAxes`).
        wristCal.tick(step.wristFeature, at: now)
        // THE JOY-CON ACCELERATION AXIS, change-gated at 1/256.
        if step.accelChanged { onJoyConAccel?(step.accelEnvelope) }
        jcAttitudeBuf.trim(before: now - Self.traceWindow)
        jcLinAccelBuf.trim(before: now - Self.traceWindow)
        gatePanels(fused: true)
        if now - lastFusedPublish > 0.1 {
            lastFusedPublish = now
            let deg = 180.0 / .pi
            fusedAttitude = [att.x * deg, att.y * deg, att.z * deg]
            joyConAccelLevel = step.accelEnvelope
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
}

// MARK: - TrailBuffer

/// A timestamped sample, for `TrailBuffer`'s expiry.
protocol TrailSample {
    var t: CFAbsoluteTime { get }
}

extension JoyConRawTiltSample: TrailSample {}
extension JoyConVectorSample: TrailSample {}

/// A time-ordered display trail: appends land at the back, expiry leaves
/// from the front. Samples arrive in time order, so `trim` scans only the
/// expired prefix and advances a head index over it — no scan of the
/// window per message and no shuffle of the live samples; the storage is
/// compacted once the dead prefix outgrows the live tail (amortised
/// O(1)). `samples` copies the live tail, a cost only the visible panels
/// pay.
struct TrailBuffer<Sample: TrailSample> {
    private var storage: [Sample] = []
    private var head = 0

    var isEmpty: Bool { head == storage.count }
    var samples: [Sample] { Array(storage[head...]) }

    mutating func append(_ sample: Sample) { storage.append(sample) }

    /// Overwrite the newest sample (frame coalescing); appends when empty.
    mutating func replaceLast(_ sample: Sample) {
        if isEmpty {
            storage.append(sample)
        } else {
            storage[storage.count - 1] = sample
        }
    }

    /// Drop every sample older than `cutoff`.
    mutating func trim(before cutoff: CFAbsoluteTime) {
        while head < storage.count, storage[head].t < cutoff { head += 1 }
        if head > 0, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}
