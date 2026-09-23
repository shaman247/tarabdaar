import Foundation

/// THE WRIST DISPLAY CLUSTER the Mac mirrors to the iPad's bars: the wrist
/// tilt (the fused attitude, or the solved axes once calibrated), its
/// rate and the gravity-removed acceleration per body axis, all
/// pre-scaled to −1…+1, plus that acceleration's magnitude over the same
/// full scale (0…1).
/// Display only — nothing here drives a binding.
public struct JoyConWristMotion: Equatable {
    /// The rate bars' full scale in tilt full-scales per second: one tilt
    /// unit is its ±90° span, so a bar rails at 360°/s.
    public static let rateFullScale = 4.0
    /// The per-axis acceleration bars' full scale, g.
    public static let accelFullScaleG = 1.0

    public var tilt: SIMD3<Double>
    public var rate: SIMD3<Double>
    public var accel: SIMD3<Double>
    public var accelLevel: Double

    public init(tilt: SIMD3<Double>, rate: SIMD3<Double> = .zero,
                accel: SIMD3<Double> = .zero, accelLevel: Double = 0) {
        self.tilt = tilt
        self.rate = rate
        self.accel = accel
        self.accelLevel = accelLevel
    }
}

/// THE JOY-CON DISPLAY MIRROR (Mac → iPad, latest-wins `JOYCON_STATE`).
///
/// Holds the axis values the iPad only DRAWS (stick, wrist, calibrated
/// arm) and assembles them with the fields the pad ACTS on — `connected`
/// (hides the drone buttons), `strikeWindowS` (the scope's onset fade),
/// `fieldWarp` (the fret field's pitch warp) and `octaveShift` (the
/// playing range) — into one frame. Extracted from `AppController`, which
/// supplies those four as providers and the send as a closure, so nothing
/// here needs `TarabLink` itself.
///
/// Main queue only. The link paces axis motion; an EDGE on one of the
/// acted-on fields goes out immediately — the relay compares them against
/// the last frame it sent, so no caller decides.
public final class JoyConDisplayRelay {

    /// `(display, immediate)` → `TarabLink.setJoyConState`.
    public var send: (JoyConTiltDisplay, Bool) -> Void = { _, _ in }
    public var connected: () -> Bool = { false }
    public var strikeWindowS: () -> Double = { 2.0 }
    public var fieldWarp: () -> Double = { 0 }
    public var octaveShift: () -> Int = { 0 }

    /// Latest axis values. Wrist is nil until the fusion runs; arm is nil
    /// while no calibration drives.
    public private(set) var stick: (Double, Double) = (0, 0)
    public private(set) var wrist: JoyConWristMotion?
    public private(set) var arm: (Double, Double, Double)?
    /// The last frame handed to `send` — the edge detector's reference.
    private var lastSent: JoyConTiltDisplay?

    public init() {}

    public func setStick(_ x: Double, _ y: Double) {
        stick = (x, y)
        push()
    }

    /// The wrist cluster — nil while the fusion has nothing (the pad draws
    /// the wrist bars dim).
    public func setWrist(_ w: JoyConWristMotion?) {
        wrist = w
        push()
    }

    public func setArm(_ a1: Double, _ a2: Double, _ a3: Double) {
        arm = (a1, a2, a3)
        push()
    }

    /// The frame as it stands (pure — the assembly the tests check).
    public func frame() -> JoyConTiltDisplay {
        let isConnected = connected()
        return JoyConTiltDisplay(
            stickX: stick.0, stickY: stick.1,
            wrist1: wrist?.tilt.x ?? 0,
            wrist2: wrist?.tilt.y ?? 0,
            stickLive: isConnected,
            bodyLive: wrist != nil,
            connected: isConnected,
            wrist3: wrist?.tilt.z ?? 0,
            arm1: arm?.0 ?? 0,
            arm2: arm?.1 ?? 0,
            arm3: arm?.2 ?? 0,
            armLive: arm != nil,
            strikeWindowS: strikeWindowS(),
            fieldWarp: fieldWarp(),
            octaveShift: octaveShift(),
            wristRate1: wrist?.rate.x ?? 0,
            wristRate2: wrist?.rate.y ?? 0,
            wristRate3: wrist?.rate.z ?? 0,
            accel1: wrist?.accel.x ?? 0,
            accel2: wrist?.accel.y ?? 0,
            accel3: wrist?.accel.z ?? 0,
            accelLevel: wrist?.accelLevel ?? 0)
    }

    /// Assemble and send. Paced, unless an acted-on field changed since the
    /// last send (or nothing has been sent yet) — then immediate.
    public func push() {
        let f = frame()
        let edge = lastSent.map { !Self.sameActedOnFields($0, f) } ?? true
        lastSent = f
        send(f, edge)
    }

    /// Send the current frame immediately regardless of edges — for a peer
    /// that has just (re)appeared and holds no state yet.
    public func resend() {
        let f = frame()
        lastSent = f
        send(f, true)
    }

    private static func sameActedOnFields(_ a: JoyConTiltDisplay,
                                          _ b: JoyConTiltDisplay) -> Bool {
        a.connected == b.connected && a.strikeWindowS == b.strikeWindowS
            && a.fieldWarp == b.fieldWarp && a.octaveShift == b.octaveShift
    }
}

/// THE VOLUME READOUT RELAY: a 60 Hz poll of the engine's integrate-and-
/// dump bus levels (the ONE poller — a second reader would steal samples)
/// converted to the two log-scale `TLPVolume` bytes and pushed onto the
/// JOYCON_STATE frame, change-gated so a silent instrument costs nothing.
/// Runs on its own utility queue.
public final class VolumeMeterRelay {

    private let levels: () -> (voice: Double, taraf: Double)
    private let send: (UInt8, UInt8) -> Void
    private var timer: DispatchSourceTimer?
    /// Timer queue only.
    private var lastBytes: (UInt8, UInt8) = (0, 0)
    private let noteControls: () -> TLPNoteControls
    private let sendNoteControls: (TLPNoteControls) -> Void
    private var noteTick = 0
    private var lastNoteControls: TLPNoteControls = .idle

    public init(levels: @escaping () -> (voice: Double, taraf: Double),
                send: @escaping (UInt8, UInt8) -> Void,
                noteControls: @escaping () -> TLPNoteControls = { .idle },
                sendNoteControls: @escaping (TLPNoteControls) -> Void = { _ in }) {
        self.levels = levels
        self.send = send
        self.noteControls = noteControls
        self.sendNoteControls = sendNoteControls
    }

    deinit { timer?.cancel() }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0,
                   leeway: .milliseconds(3))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One poll: convert, drop an unchanged pair, else send.
    public func tick() {
        if noteTick == 0 {
            let controls = noteControls()
            if controls != lastNoteControls {
                lastNoteControls = controls
                sendNoteControls(controls)
            }
        }
        noteTick = (noteTick + 1) % 4
        let l = levels()
        let bytes = (TLPVolume.byte(fromLinear: l.voice),
                     TLPVolume.byte(fromLinear: l.taraf))
        guard bytes != lastBytes else { return }
        lastBytes = bytes
        send(bytes.0, bytes.1)
    }
}
