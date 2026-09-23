import Foundation
import simd

/// Standard Joy-Con 2 BLE report 0x05, including NYXI's console-session stream.
public final class JoyCon2ReportDecoder {
    private var lastGeneration: Int?
    private var lastDeviceTime: UInt32?
    private var sampleTime: CFAbsoluteTime = 0
    private var lastArrival: CFAbsoluteTime = 0

    public init() {}

    public func decode(_ data: Data, timestamp: CFAbsoluteTime,
                       generation: Int = 0, isNYXI: Bool = false) -> JoyConReport? {
        let d = [UInt8](data)
        guard d.count >= 13 else { return nil }
        let b = UInt32(d[4]) | (UInt32(d[5]) << 8)
              | (UInt32(d[6]) << 16) | (UInt32(d[7]) << 24)
        var down: Set<JoyConControl> = []
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
        let s0 = Double(Int(d[10]) | (Int(d[11] & 0x0F) << 8))
        let s1 = Double((Int(d[11]) >> 4) | (Int(d[12]) << 4))

        // NYXI duplicates the rear paddle in GL/GR; only interpret it on this device.
        if isNYXI, b & (1 << 25) != 0 { down.insert(.rearZ) }
        var imu: [JoyConIMUSample] = []
        if d.count >= 0x3C {
            func i16(_ offset: Int) -> Double {
                Double(Int16(bitPattern: UInt16(d[offset]) | UInt16(d[offset + 1]) << 8))
            }
            var t: CFAbsoluteTime? = timestamp
            if isNYXI {
                let tick = UInt32(d[42]) | UInt32(d[43]) << 8
                         | UInt32(d[44]) << 16 | UInt32(d[45]) << 24
                // Measured NYXI ticks are milliseconds (Nintendo documents microseconds).
                // BLE delivers batches, so arrival spacing is not the sample spacing.
                if lastGeneration == generation, let previous = lastDeviceTime,
                   timestamp - lastArrival < 0.25 {
                    let delta = tick &- previous
                    if delta == 0 {
                        t = nil
                    } else if delta <= 250 {
                        sampleTime += Double(delta) / 1000
                        t = sampleTime
                    } else {
                        sampleTime = timestamp  // sensor reset / discontinuity
                    }
                } else {
                    sampleTime = timestamp
                }
                lastGeneration = generation
                lastDeviceTime = tick
                lastArrival = timestamp
            }
            if let t {
                let accel = SIMD3(i16(48), i16(50), i16(52)) / 4096
                let gyro = SIMD3(i16(54), i16(56), i16(58)) / 16.4
                let rawMag = SIMD3(i16(25), i16(27), i16(29))
                // NYXI has no measured magnetometer output; zero is unavailable.
                imu.append(JoyConIMUSample(t: t, gyroDps: gyro, accelG: accel,
                                           mag: rawMag == .zero ? nil : rawMag))
            }
        }
        return JoyConReport(source: isNYXI ? .bleAlt : .ble,
                            timestamp: timestamp, generation: generation,
                            buttons: .snapshot(down), stick: .raw(s0, s1), imu: imu,
                            fuseIMU: !imu.isEmpty, hexPrefix: isNYXI ? "nyxi: " : "ble: ",
                            hexBytes: Array(d.prefix(13)))
    }
}
