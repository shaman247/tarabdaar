import Foundation

// MARK: - Codable conformance

/// A `StringNote` round-trips through JSON by its musical/layout fields only —
/// `degreeIndex`, `octave`, `stringIndex`, `centerY`, `height`, `enabled`. The
/// `id` is **not** persisted (per-process identity for SwiftUI diffing / gesture
/// targeting), so a fresh one is minted on decode — same rule `ScaleStore` uses
/// for `PitchPoint.id`. `stringIndex` defaults to 0 if absent (e.g. an older
/// free-`x` file — load then `Reset to Scale`).
extension StringNote: Codable {
    private enum CodingKeys: String, CodingKey {
        case degreeIndex, octave, stringIndex, centerY, height, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let degreeIndex = try c.decode(Int.self, forKey: .degreeIndex)
        let octave = try c.decodeIfPresent(Int.self, forKey: .octave) ?? 0
        let stringIndex = try c.decodeIfPresent(Int.self, forKey: .stringIndex) ?? 0
        let centerY = try c.decode(Double.self, forKey: .centerY)
        let height = try c.decode(Double.self, forKey: .height)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.init(degreeIndex: degreeIndex, octave: octave, stringIndex: stringIndex,
                  centerY: centerY, height: height, enabled: enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(degreeIndex, forKey: .degreeIndex)
        try c.encode(octave, forKey: .octave)
        try c.encode(stringIndex, forKey: .stringIndex)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(height, forKey: .height)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// On-disk representation of a String-Pad arrangement. Versioned so a future
/// format change can be migrated on load rather than failing to decode.
/// `stringCount`/`ghostStringsPerSide` default for older files.
struct StringArrangementDocument: Codable {
    var version: Int = 3
    var notes: [StringNote]
    var stringCount: Int?
    var ghostStringsPerSide: Int?
    var rotationDegrees: Double?
}

// MARK: - StringArrangementStore

/// Saves and loads String-Pad arrangements as JSON. Mac-only persistence with
/// no iPad coupling — arrangements live entirely on this side, like Pitch-Pad
/// scales and presets. Writes are atomic (`*.json.tmp` → move) so a reader never
/// observes a partial file. The live arrangement is auto-saved to a reserved
/// `_Current.json` (not listed among the user's named arrangements); explicit
/// Save As / Load uses named files alongside it.
public enum StringArrangementStore {
    /// Reserved file holding the live (auto-saved) arrangement. Hidden from
    /// `savedNames()` so it can't be loaded as if it were a user file.
    private static let currentName = "_Current"

    /// Directory holding arrangements. Created on first save.
    public static var dir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Starpad", isDirectory: true)
            .appendingPathComponent("StringArrangements", isDirectory: true)
    }

    public static func url(forName name: String) -> URL {
        dir.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// Names of user-saved arrangements (filename minus `.json`), sorted
    /// case-insensitively. The reserved `_Current` autosave is excluded.
    public static func savedNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.hasPrefix("_") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Named save / load

    public static func save(_ arrangement: StringArrangement, name: String) throws {
        try write(arrangement, to: url(forName: name))
    }

    public static func load(name: String) throws -> StringArrangement {
        try read(url(forName: name))
    }

    public static func delete(name: String) throws {
        try FileManager.default.removeItem(at: url(forName: name))
    }

    // MARK: Live autosave

    /// Persist the live arrangement to `_Current.json`. Best-effort.
    public static func saveCurrent(_ arrangement: StringArrangement) {
        try? write(arrangement, to: url(forName: currentName))
    }

    /// The last auto-saved live arrangement, or `nil` if none has been written
    /// yet (first launch — the caller builds a default from the scale).
    public static func loadCurrent() -> StringArrangement? {
        try? read(url(forName: currentName))
    }

    // MARK: Atomic I/O

    private static func write(_ arrangement: StringArrangement, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let doc = StringArrangementDocument(
            notes: arrangement.notes,
            stringCount: arrangement.stringCount,
            ghostStringsPerSide: arrangement.ghostStringsPerSide,
            rotationDegrees: arrangement.rotationDegrees)
        let data = try encoder.encode(doc)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    private static func read(_ url: URL) throws -> StringArrangement {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(StringArrangementDocument.self, from: data)
        // Fall back to a count that covers the notes if the file predates it.
        let derived = (doc.notes.map(\.stringIndex).max() ?? -1) + 1
        return StringArrangement(
            notes: doc.notes,
            stringCount: doc.stringCount ?? max(derived, 1),
            ghostStringsPerSide: doc.ghostStringsPerSide ?? 4,
            rotationDegrees: doc.rotationDegrees ?? StringArrangement.defaultRotationDegrees)
    }
}
