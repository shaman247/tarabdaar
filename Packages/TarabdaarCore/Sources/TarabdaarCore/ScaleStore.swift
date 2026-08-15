import Foundation

// MARK: - Codable conformance

/// A `PitchPoint` round-trips through JSON by its musical fields only —
/// `num`, `den`, `y`, `label`, `enabled`. The `id` is **not** persisted:
/// it's a per-process identity used for SwiftUI diffing and gesture
/// targeting, so a fresh one is minted on decode. That means loading the
/// same file twice yields points with different ids (correct — they're
/// distinct instances) and a freshly-loaded scale never collides ids
/// with whatever was on the pad before.
extension PitchPoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case num, den, y, label, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let num = try c.decode(Int.self, forKey: .num)
        let den = try c.decode(Int.self, forKey: .den)
        let y = try c.decode(Double.self, forKey: .y)
        let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.init(num: num, den: den, y: y, label: label, enabled: enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(num, forKey: .num)
        try c.encode(den, forKey: .den)
        try c.encode(y, forKey: .y)
        try c.encode(label, forKey: .label)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// On-disk representation of a Pitch-Pad scale. Versioned so a future
/// format change can be migrated on load rather than failing to decode.
struct ScaleDocument: Codable {
    var version: Int = 1
    var points: [PitchPoint]
}

// MARK: - ScaleStore

/// Saves and loads Pitch-Pad scales as JSON. The read-only **Default**
/// scale ships inside the app bundle (`Default.json`); user-saved scales
/// are written to `~/Library/Application Support/Tarabdaar/Scales/`.
///
/// This is Mac-only persistence with no iPad coupling — scales live
/// entirely on this side, like presets and audition scores. Writes are
/// atomic (`*.json.tmp` → move) so a reader never observes a partial
/// file, matching the convention the audition runner relies on.
public enum ScaleStore {
    /// Reserved name for the bundled default. The Save UI refuses it so
    /// the default can't be shadowed by a user file of the same name.
    public static let defaultName = "Default"

    /// Directory holding user-saved scales. Created on first save.
    public static var userScalesDir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Tarabdaar", isDirectory: true)
            .appendingPathComponent("Scales", isDirectory: true)
    }

    /// The default scale, loaded from the bundled `Default.json`. Falls
    /// back to the in-code `PitchScale.defaultJI` if the resource is
    /// missing or unreadable, so the pad always opens on a sane scale
    /// even in a build where the resource didn't make it in.
    public static func loadDefault() -> PitchScale {
        if let url = Bundle.main.url(forResource: "Default", withExtension: "json"),
           let scale = try? load(url: url) {
            return scale
        }
        return .defaultJI
    }

    /// Names of all user-saved scales (filename minus `.json`), sorted
    /// case-insensitively. The bundled Default isn't listed — it's
    /// reachable via "Reset to Default" instead.
    public static func savedScaleNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: userScalesDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func url(forName name: String) -> URL {
        userScalesDir.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// Write `scale` under `name`. Atomic: encode to `name.json.tmp`,
    /// then move into place over any existing file.
    public static func save(_ scale: PitchScale, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: userScalesDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ScaleDocument(points: scale.points))
        let dest = url(forName: name)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    public static func load(name: String) throws -> PitchScale {
        try load(url: url(forName: name))
    }

    public static func delete(name: String) throws {
        try FileManager.default.removeItem(at: url(forName: name))
    }

    private static func load(url: URL) throws -> PitchScale {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(ScaleDocument.self, from: data)
        return PitchScale(points: doc.points)
    }
}
