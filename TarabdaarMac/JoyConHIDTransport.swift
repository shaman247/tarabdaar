import Foundation
import IOKit.hid
import TarabdaarCore
import simd

// MARK: - Bearer 2: the raw HID side-channel

/// Raw HID listener (see the side-channel note on `JoyConInput`).
/// Scheduled on the main run loop, so callbacks land on main like the GC
/// handlers. Read-only — gamecontrollerd keeps the GC profile.
final class JoyConHIDTransport: JoyConTransport {
    var onReport: ((JoyConReport) -> Void)?
    /// "open" / the failing IOReturn / "full mode".
    var onStatus: ((String) -> Void)?
    /// Full input mode confirmed — the GC bindings must stand down.
    var onFullMode: (() -> Void)?
    var onRemoved: (() -> Void)?
    /// The host's "IMU has produced non-zero data" flag — the ack the
    /// IMU-enable retry loop waits for.
    var imuActive: () -> Bool = { false }

    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private let hidReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    /// Controls held according to the raw HID reports (the simple-mode
    /// branch carries the arrows forward from the previous snapshot).
    private var hidDown: Set<JoyConControl> = []
    private var generation = 0
    /// FULL MODE: simple mode (0x3F) sends filler axis fields — real 12-bit
    /// stick data streams only in full mode (0x30), entered via subcommand
    /// 0x03/0x30 on output report 0x01; then the GC handlers stand down.
    private(set) var isFullMode = false
    private var hidPacketCounter: UInt8 = 0
    private var modeSwitchTries = 0
    private var imuEnableTries = 0

    func connect() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOHIDOptionsType(kIOHIDOptionsTypeNone))
        hidManager = mgr
        // Nintendo VID; the matching callback narrows to Joy-Cons.
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x057E] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<JoyConHIDTransport>.fromOpaque(ctx).takeUnretainedValue()
                .hidDeviceMatched(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<JoyConHIDTransport>.fromOpaque(ctx).takeUnretainedValue()
                .hidDeviceRemoved()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        onStatus?(r == kIOReturnSuccess ? "open"
                                        : String(format: "open failed 0x%x", r))
        if r != kIOReturnSuccess {
            NSLog("Tarabdaar: IOHIDManagerOpen failed (0x%x) — L/ZL unavailable; grant Input Monitoring if prompted", r)
        }
    }

    func disconnect() {
        if let mgr = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(),
                                              CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        hidDevice = nil
    }

    /// The IMU-enable retry budget is re-armed whenever the host clears
    /// its IMU state (a reconnect must be able to ask again).
    func resetIMUEnableTries() { imuEnableTries = 0 }

    private func hidDeviceMatched(_ device: IOHIDDevice) {
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        guard pid == 0x2006 || pid == 0x2007 else { return }   // Joy-Con L/R
        hidDevice = device
        generation += 1
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, hidReportBuffer, 512, {
            ctx, _, _, _, reportID, report, length in
            guard let ctx else { return }
            Unmanaged<JoyConHIDTransport>.fromOpaque(ctx).takeUnretainedValue()
                .hidReport(id: reportID, report: report, length: Int(length))
        }, ctx)
        NSLog("Tarabdaar: raw HID listener on Joy-Con (pid 0x%x)", pid)
        requestFullMode()
    }

    /// Ask for full input mode (60 Hz 0x30 reports): output report 0x01,
    /// neutral rumble bytes, subcommand 0x03, argument 0x30. Retried a few
    /// times — the arrival of a 0x30 report is the ack.
    private func requestFullMode() {
        guard let device = hidDevice, !isFullMode, modeSwitchTries < 4
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
    /// (`imuActive` is the ack).
    private func requestIMUEnable() {
        guard let device = hidDevice, isFullMode, !imuActive(),
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
        hidDown = []
        hidDevice = nil
        isFullMode = false
        modeSwitchTries = 0
        onRemoved?()
    }

    /// Parse one raw input report. Simple mode (0x3F): L/ZL from button
    /// byte 2 bits 6/7. Full mode (0x30/0x21): the left-side button byte
    /// (arrows, SL/SR, L/ZL, UPRIGHT frame) and the 12-bit stick at bytes
    /// 6–8. The report-ID byte may or may not be in the buffer — detected.
    private func hidReport(id: UInt32, report: UnsafePointer<UInt8>, length: Int) {
        guard length >= 3 else { return }
        let base = report[0] == UInt8(id & 0xFF) ? 1 : 0
        let now = CFAbsoluteTimeGetCurrent()
        var down: Set<JoyConControl> = []
        var stick: JoyConStickValue?
        var imu: [JoyConIMUSample] = []
        if id == 0x3F, length >= base + 2 {
            let b2 = report[base + 1]
            if b2 & 0x40 != 0 { down.insert(.l) }
            if b2 & 0x80 != 0 { down.insert(.zl) }
            // Arrows/SL/SR stay with the GC path in simple mode.
            down.formUnion(hidDown.intersection([.dpadUp, .dpadDown,
                                                 .dpadLeft, .dpadRight]))
        } else if id == 0x30 || id == 0x21, length >= base + 8 {
            if !isFullMode {
                isFullMode = true
                onStatus?("full mode")
                NSLog("Tarabdaar: Joy-Con in full input mode — analog stick live")
                requestIMUEnable()
                onFullMode?()
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
            stick = .raw(s0, s1)
            // IMU (zeros until subcommand 0x40 enables it): three 12-byte
            // frames ~5 ms apart at base+12 — accel i16 ×3 (4096 LSB/g)
            // then gyro i16 ×3 (16.4 LSB per °/s), device frame. NOT fused:
            // these fill the raw trails only.
            if id == 0x30, length >= base + 48 {
                func i16(_ o: Int) -> Double {
                    Double(Int16(bitPattern: UInt16(report[o])
                        | (UInt16(report[o + 1]) << 8)))
                }
                for f in 0..<3 {
                    let o = base + 12 + f * 12
                    imu.append(JoyConIMUSample(
                        t: now - Double(2 - f) * 0.005,
                        gyroDps: SIMD3(i16(o + 6), i16(o + 8),
                                       i16(o + 10)) / 16.4,
                        accelG: SIMD3(i16(o), i16(o + 2),
                                      i16(o + 4)) / 4096.0))
                }
            }
        } else {
            return
        }
        hidDown = down
        let n = min(length, 12)
        onReport?(JoyConReport(
            source: .hid, timestamp: now, generation: generation,
            buttons: .snapshot(down), stick: stick, imu: imu,
            fuseIMU: false,
            hexPrefix: "id \(String(format: "%02x", id)): ",
            hexBytes: Array(UnsafeBufferPointer(start: report, count: n))))
    }
}
