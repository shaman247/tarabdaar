import Foundation
import simd

/// THE NORMALIZED JOY-CON REPORT — the one shape every transport speaks.
///
/// Three very different bearers feed the same instrument funnels (see
/// `JoyConTransport` below): the GameController framework's profile
/// handlers, a raw `IOHIDManager` side-channel, and the Switch 2
/// Joy-Con's vendor GATT over CoreBluetooth. Each parses its own wire
/// format and hands the coordinator one of these; nothing downstream —
/// `JoyConMapper`, `JoyConFusion` — knows which bearer it came from.
///
/// The transports themselves are inherently platform-bound (they import
/// GameController / IOKit / CoreBluetooth), so they live Mac-side; this
/// file and the mapper/fusion it feeds are platform-neutral and testable.

/// Buttons, named by position on an upright left Joy-Con.
public enum JoyConControl: String, CaseIterable, Hashable, Sendable {
    case dpadUp = "Up", dpadDown = "Down"
    case dpadLeft = "Left", dpadRight = "Right"
    /// The shoulder family. L and ZL carry the default actions
    /// (strum, re-zero); SL and SR are unassigned.
    case l = "L", zl = "ZL"
    case sl = "SL", sr = "SR"
    /// Stick click, Minus, Capture — unassigned, shown as panel chips.
    case stickClick = "Stick", minus = "Minus", capture = "Capture"
}

/// How a report carries button state. Report-parsing bearers (HID, BLE)
/// send the whole SNAPSHOT and the mapper diffs it; the GameController
/// profile delivers per-button callbacks, which arrive as EDGES.
public enum JoyConButtonUpdate {
    case snapshot(Set<JoyConControl>)
    case edge(JoyConControl, Bool)
}

/// The stick, in whichever frame the bearer produced.
public enum JoyConStickValue {
    /// 12-bit device-frame units — runs the calibration state machine.
    case raw(Double, Double)
    /// Already −1…+1 and already rotated for the upright grip (the
    /// GameController path).
    case unit(Double, Double)
}

/// One IMU packet in the device frame: gyro °/s, accel g (INCLUDING
/// gravity — at rest on the 1 g sphere), magnetometer raw i16
/// (Joy-Con 2 only).
public struct JoyConIMUSample {
    public var t: CFAbsoluteTime
    public var gyroDps: SIMD3<Double>
    /// The same rotation rate in rad/s — carried rather than derived so a
    /// bearer whose wire units ARE rad/s (the GameController motion
    /// profile) hands the fusion its own number back unrounded.
    public var gyroRadPerSec: SIMD3<Double>
    public var accelG: SIMD3<Double>
    public var mag: SIMD3<Double>?

    public init(t: CFAbsoluteTime, gyroDps: SIMD3<Double>,
                accelG: SIMD3<Double>, mag: SIMD3<Double>? = nil,
                gyroRadPerSec: SIMD3<Double>? = nil) {
        self.t = t
        self.gyroDps = gyroDps
        self.gyroRadPerSec = gyroRadPerSec ?? gyroDps * .pi / 180
        self.accelG = accelG
        self.mag = mag
    }
}

/// One normalized report from any bearer. Every field is optional
/// except the identity ones — a bearer fills only what its wire format
/// actually carried.
public struct JoyConReport {
    public enum Source: Hashable, Sendable {
        case gameController
        case hid
        /// Joy-Con 2 report 0x05 on the standard input characteristic.
        case ble
        /// Report 0x07 on the controller-specific characteristic (the
        /// third-party clone stream).
        case bleAlt
    }

    public var source: Source
    public var timestamp: CFAbsoluteTime
    /// Bumps on every device (re)attach for this bearer — the mapper
    /// drops a stale button snapshot when it changes.
    public var generation: Int
    public var buttons: JoyConButtonUpdate?
    public var stick: JoyConStickValue?
    public var imu: [JoyConIMUSample]
    /// True when the IMU samples should run the orientation fusion.
    /// FALSE for the classic Joy-Con's HID stream — its packets fill the
    /// raw trails only, which is why the fused panels stay dark there.
    public var fuseIMU: Bool
    /// Panel hex readout, split so the (throttled) coordinator formats
    /// only the reports it actually shows.
    public var hexPrefix: String
    public var hexBytes: [UInt8]

    public init(source: Source,
                timestamp: CFAbsoluteTime,
                generation: Int = 0,
                buttons: JoyConButtonUpdate? = nil,
                stick: JoyConStickValue? = nil,
                imu: [JoyConIMUSample] = [],
                fuseIMU: Bool = false,
                hexPrefix: String = "",
                hexBytes: [UInt8] = []) {
        self.source = source
        self.timestamp = timestamp
        self.generation = generation
        self.buttons = buttons
        self.stick = stick
        self.imu = imu
        self.fuseIMU = fuseIMU
        self.hexPrefix = hexPrefix
        self.hexBytes = hexBytes
    }
}

/// One bearer of Joy-Con input. Deliberately tiny: start listening, stop
/// listening, hand normalized reports up. Everything bearer-SPECIFIC —
/// element inventories, HID mode-switch status, BLE connection state —
/// stays as concrete properties on the transport, because it is exactly
/// the part the panel wants to show verbatim.
public protocol JoyConTransport: AnyObject {
    /// Normalized reports, main queue.
    var onReport: ((JoyConReport) -> Void)? { get set }
    func connect()
    func disconnect()
}

/// A received-tilt trail sample (the arm stream's raw report).
public struct JoyConRawTiltSample {
    public var t: CFAbsoluteTime
    public var raw: SIMD3<Double>
    public init(t: CFAbsoluteTime, raw: SIMD3<Double>) {
        self.t = t
        self.raw = raw
    }
}

/// A vector trail sample (accelerometer / gyro / magnetometer / fused).
public struct JoyConVectorSample {
    public var t: CFAbsoluteTime
    public var a: SIMD3<Double>
    public init(t: CFAbsoluteTime, a: SIMD3<Double>) {
        self.t = t
        self.a = a
    }
}
