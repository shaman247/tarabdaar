import Foundation

// MARK: - Codable conformance

/// Layout JSON stores only the pitch reference and row.
extension FretSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case degreeIndex, row, y, topY, bottomY, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let degree = try c.decode(Int.self, forKey: .degreeIndex)
        if let row = try c.decodeIfPresent(FretRow.self, forKey: .row) {
            self.init(degreeIndex: degree, row: row)
            return
        }
        let y: Double
        if let center = try c.decodeIfPresent(Double.self, forKey: .y) {
            y = center
        } else {
            y = try (c.decode(Double.self, forKey: .topY)
                     + c.decode(Double.self, forKey: .bottomY)) / 2
        }
        self.init(degreeIndex: degree, row: FretRow.legacy((1...3).min { abs((3.5 - Double($0)) / 3 - y) < abs((3.5 - Double($1)) / 3 - y) }!)!)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(degreeIndex, forKey: .degreeIndex)
        try c.encode(row, forKey: .row)
    }

    /// Legacy disabled entries become absent pairs; all retained entries use fixed geometry.
    static func decodeList(from decoder: Decoder, legacyRows: Bool = false) throws -> [FretSegment] {
        var list = try decoder.unkeyedContainer()
        var frets: [FretSegment] = []
        while !list.isAtEnd {
            let item = try list.superDecoder()
            let c = try item.container(keyedBy: CodingKeys.self)
            var fret = try FretSegment(from: item)
            if legacyRows, let old = try c.decodeIfPresent(Int.self, forKey: .row) {
                guard let row = FretRow.legacy(old) else { throw CocoaError(.coderReadCorrupt) }
                fret.row = row
            }
            if try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true {
                frets.append(fret)
            }
        }
        return frets
    }
}

/// Version 7 stores pitch/row pairs; older coordinates migrate to the nearest row.
struct FretArrangementDocument: Codable {
    var version: Int = 7
    var segments: [FretSegment]
    var ghostExtentOctaves: Double?
    var droneRatios: [Double]?

    init(segments: [FretSegment], ghostExtentOctaves: Double?, droneRatios: [Double]?) {
        self.segments = segments
        self.ghostExtentOctaves = ghostExtentOctaves
        self.droneRatios = droneRatios
    }

    private enum CodingKeys: String, CodingKey {
        case version, segments, ghostExtentOctaves, droneRatios
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard (4...7).contains(version) else { throw CocoaError(.coderReadCorrupt) }
        segments = try FretSegment.decodeList(from: c.superDecoder(forKey: .segments), legacyRows: version < 7)
        ghostExtentOctaves = try c.decodeIfPresent(Double.self, forKey: .ghostExtentOctaves)
        droneRatios = try c.decodeIfPresent([Double].self, forKey: .droneRatios)
    }
}

// MARK: - FretArrangementStore

/// Saves and loads Fret-Pad arrangements as JSON. Mac-only persistence with
/// no iPad coupling. Writes are atomic (`*.json.tmp` → move) so a reader never
/// observes a partial file. The live arrangement is auto-saved to a reserved
/// `_Current.json`, and the player's **named layouts** sit beside it in the same folder, one
/// `<name>.json` each, listed by `savedNames()` (`_Current` filtered out).
/// The built-in layouts are `FretLayoutPreset`, not files.
public enum FretArrangementStore {
    /// Reserved name for the live autosave. The save UI refuses it so a
    /// named layout can never shadow (or be shadowed by) the working one.
    public static let currentName = "_Current"

    /// Test seam: when set, the store reads/writes here instead of
    /// Application Support, so a round-trip test never touches the player's
    /// own layouts. Always nil in the app.
    static var dirOverride: URL? = nil

    /// Directory holding arrangements. Created on first save.
    public static var dir: URL {
        if let dirOverride { return dirOverride }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Tarabdaar", isDirectory: true)
            .appendingPathComponent("FretArrangements", isDirectory: true)
    }

    public static func url(forName name: String) -> URL {
        dir.appendingPathComponent(name).appendingPathExtension("json")
    }

    // MARK: Live autosave

    /// Persist the live arrangement to `_Current.json`. Best-effort.
    public static func saveCurrent(_ arrangement: FretArrangement) {
        try? write(arrangement, to: url(forName: currentName))
    }

    /// The last auto-saved live arrangement, or `nil` if none has been written
    /// yet (first launch — the caller builds a default from the scale).
    public static func loadCurrent() -> FretArrangement? {
        try? read(url(forName: currentName))
    }

    // MARK: Named layouts

    /// Names of the player's saved layouts (filename minus `.json`), sorted
    /// case-insensitively. The live autosave is not listed, and neither are
    /// the built-in `FretLayoutPreset`s — they're generated from the scale,
    /// not stored.
    public static func savedNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != currentName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Save `arrangement` under `name`, replacing an existing layout of that
    /// name. Throws on an empty/reserved name (after sanitizing) or a write
    /// failure. The name doubles as the filename, so separators are folded.
    @discardableResult
    public static func save(_ arrangement: FretArrangement,
                            name: String) throws -> String {
        let clean = try sanitized(name)
        try write(arrangement, to: url(forName: clean))
        return clean
    }

    public static func load(name: String) throws -> FretArrangement {
        try read(url(forName: name))
    }

    public static func delete(name: String) throws {
        try FileManager.default.removeItem(at: url(forName: name))
    }

    /// A layout name doubles as its filename: path separators (and the
    /// legacy-HFS `:`) are replaced, surrounding whitespace dropped, and the
    /// reserved autosave name refused — same rule as `PresetLibrary`.
    public static func sanitized(_ name: String) throws -> String {
        let cleaned = try PresetLibrary.sanitized(name)
        guard cleaned != currentName else {
            throw NSError(domain: "FretArrangementStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Layout name is empty or reserved",
            ])
        }
        return cleaned
    }

    // MARK: Atomic I/O

    private static func write(_ arrangement: FretArrangement, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let doc = FretArrangementDocument(
            segments: arrangement.segments,
            ghostExtentOctaves: arrangement.ghostExtentOctaves,
            droneRatios: arrangement.droneRatios)
        let data = try encoder.encode(doc)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    private static func read(_ url: URL) throws -> FretArrangement {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(FretArrangementDocument.self, from: data)
        // any drone count but the current one falls back in the initializer
        return FretArrangement(
            segments: doc.segments,
            ghostExtentOctaves: doc.ghostExtentOctaves ?? FretArrangement.defaultGhostExtentOctaves,
            droneRatios: doc.droneRatios ?? FretArrangement.defaultDroneRatios)
    }
}
