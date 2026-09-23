import Foundation

/// Select the left controller whose buttons the instrument maps, including unnamed advertisements.
public enum JoyConBLEDiscovery {
    public static func accepts(manufacturerData: Data?, name: String) -> Bool {
        let m = manufacturerData.map { [UInt8]($0) } ?? []
        let nintendo = m.count >= 2 && m[0] == 0x53 && m[1] == 0x05
        // Nintendo's advertisement embeds its USB vendor/product IDs.
        // 2067 is Joy-Con 2 (L); 2066 is (R). Product identity beats a cached name.
        if nintendo, m.count >= 9, m[5] == 0x7E, m[6] == 0x05 {
            return m[7] == 0x67 && m[8] == 0x20
        }
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.hasSuffix("-r"), !lower.hasSuffix("(r)") else { return false }
        return nintendo || lower.contains("joy-con")
            || (lower.hasPrefix("nyxi ") && lower.hasSuffix("-l"))
    }
}
