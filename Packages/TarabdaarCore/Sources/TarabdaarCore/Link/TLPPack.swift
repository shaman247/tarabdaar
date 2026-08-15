import Foundation

/// The SysEx envelope for TLP frames on CoreMIDI transports (USB session
/// or the BLE-MIDI session — both legs identical):
///
///     F0 7D 10 <role> <7-in-8 packed frame bytes> F7
///
/// 0x7D = MIDI non-commercial manufacturer ID; subtype 0x10 = TLP tunnel.
/// `<role>` (one septet: 0 = pad, 1 = host) identifies the SENDER so a
/// receiver can drop its own traffic echoed back through a MIDI loop
/// (IAC bus, MIDI patchbays, dual USB+BLE delivery) — measured on the
/// development Mac: its own pings looped back with a 0.3 ms self-RTT and
/// the echoed stream chopped the iPad's frames in the shared reassembler.
/// (Subtypes 0x01/0x03/0x05 were the legacy scale/arrangement/Joy-Con
/// messages, retired into TLP events; 0x02/0x04 were deleted earlier and
/// stay dead.)
///
/// 7-in-8 packing: each group of ≤7 payload bytes becomes 1 MSB septet
/// followed by the 7 bytes with bit 7 cleared; septet bit i carries byte
/// i's high bit. A final partial group of n bytes is 1 + n wire bytes —
/// the decoder infers n from the remaining length. Overhead 8/7 (~14 %)
/// vs base64's 4/3 (~33 %).
public enum TLPPack {
    public static let sysExSubtype: UInt8 = 0x10
    public static let header: [UInt8] = [0xF0, 0x7D, 0x10]

    /// 8-bit bytes → 7-bit-safe septet stream.
    public static func pack(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + (bytes.count + 6) / 7 )
        var i = 0
        while i < bytes.count {
            let n = min(7, bytes.count - i)
            var msb: UInt8 = 0
            for j in 0..<n where bytes[i + j] & 0x80 != 0 {
                msb |= 1 << UInt8(j)
            }
            out.append(msb)
            for j in 0..<n {
                out.append(bytes[i + j] & 0x7F)
            }
            i += n
        }
        return out
    }

    /// Septet stream → 8-bit bytes. nil if any byte has bit 7 set or the
    /// stream ends with a lone MSB septet (a group must carry ≥1 data byte).
    public static func unpack(_ septets: ArraySlice<UInt8>) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(septets.count)
        var i = septets.startIndex
        while i < septets.endIndex {
            let msb = septets[i]
            guard msb & 0x80 == 0 else { return nil }
            i += 1
            let n = min(7, septets.endIndex - i)
            guard n > 0 else { return nil }
            for j in 0..<n {
                let b = septets[i + j]
                guard b & 0x80 == 0 else { return nil }
                out.append(msb & (1 << UInt8(j)) != 0 ? b | 0x80 : b)
            }
            i += n
        }
        return out
    }

    /// Full SysEx message for one TLP frame, stamped with the sender role.
    public static func envelope(_ frame: [UInt8], role: TLPRole) -> [UInt8] {
        var out = header
        out.append(role.rawValue & 0x7F)
        out.append(contentsOf: pack(frame))
        out.append(0xF7)
        return out
    }

    /// Decodes a complete SysEx message (F0…F7 inclusive) into the sender
    /// role + TLP frame bytes. nil if it is not a TLP tunnel message or is
    /// malformed.
    public static func unenvelope(_ sysex: [UInt8]) -> (role: TLPRole, frame: [UInt8])? {
        guard sysex.count >= header.count + 2,
              Array(sysex.prefix(header.count)) == header,
              sysex.last == 0xF7,
              let role = TLPRole(rawValue: sysex[header.count])
        else { return nil }
        guard let frame = unpack(sysex[(header.count + 1)..<(sysex.count - 1)])
        else { return nil }
        return (role, frame)
    }
}
