import Foundation

/// NYXI Hyperion 3 Ultra left-controller input, carried on the BLE command-response channel.
public enum JoyConNYXIReport {
    /// Recognize the vendor input envelope without interpreting ordinary command acknowledgements.
    public static func decode(_ data: Data, timestamp: CFAbsoluteTime,
                              generation: Int = 0) -> JoyConReport? {
        let d = [UInt8](data)
        guard d.count >= 16,
              d.starts(with: [0xEA, 0x01, 0x00, 0x8B, 0x00, 0x78, 0x00, 0x00, 0x0C])
        else { return nil }

        // Captured from individual presses on the upright left controller.
        let primary: [(UInt8, JoyConControl)] = [
            (0x08, .dpadUp), (0x04, .dpadDown),
            (0x02, .dpadLeft), (0x01, .dpadRight),
            (0x80, .l), (0x40, .zl), (0x20, .minus), (0x10, .stickClick),
        ]
        let secondary: [(UInt8, JoyConControl)] = [
            (0x04, .capture), (0x01, .sl), (0x02, .sr), (0x08, .rearZ),
        ]
        var down: Set<JoyConControl> = []
        for (mask, control) in primary where d[9] & mask != 0 { down.insert(control) }
        for (mask, control) in secondary where d[10] & mask != 0 { down.insert(control) }

        // Preserve the shared raw-stick calibration path in its 12-bit units.
        func stick(_ offset: Int) -> Double {
            let value = Int16(bitPattern: UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8))
            return 2048 + Double(value) / 16
        }
        return JoyConReport(source: .bleAlt, timestamp: timestamp, generation: generation,
                            buttons: .snapshot(down), stick: .raw(stick(11), stick(13)),
                            hexPrefix: "nyxi: ", hexBytes: Array(d.prefix(16)))
    }
}
