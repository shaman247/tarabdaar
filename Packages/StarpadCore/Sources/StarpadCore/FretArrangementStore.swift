import Foundation

// MARK: - Codable conformance

/// A `FretSegment` round-trips through JSON by its musical/layout fields only —
/// `degreeIndex`, `x`, `topY`, `bottomY`, `enabled`. The `id` is **not**
/// persisted (per-process identity for SwiftUI diffing / gesture targeting), so
/// a fresh one is minted on decode — same rule `ScaleStore` uses for
/// `PitchPoint.id`.
extension FretSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case degreeIndex, x, topY, bottomY, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let degreeIndex = try c.decode(Int.self, forKey: .degreeIndex)
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        let topY = try c.decode(Double.self, forKey: .topY)
        let bottomY = try c.decode(Double.self, forKey: .bottomY)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.init(degreeIndex: degreeIndex, x: x, topY: topY, bottomY: bottomY,
                  enabled: enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(degreeIndex, forKey: .degreeIndex)
        try c.encode(x, forKey: .x)
        try c.encode(topY, forKey: .topY)
        try c.encode(bottomY, forKey: .bottomY)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// On-disk representation of a Fret-Pad arrangement. Versioned so a future
/// format change can be migrated on load rather than failing to decode.
/// v2 replaced the integer `ghostOctavesPerSide` with the fractional
/// `ghostExtentOctaves` (a v1 file just gets the 0.5 default); v3 added
/// `legato` (older files default to true); v4 added the free per-segment `x`
/// — pre-v4 files carry pitch-derived positions that no longer exist, so
/// they're **rejected** on load (the caller rebuilds the new default).
/// (`droneRatios` — the drone-button pitches — is optional: older files
/// fall back to the default, no version bump; both historical 4-slot
/// defaults migrate to the current 3-slot ,Sa·,Pa·Sa default on read, and
/// a hand-picked 4-slot set drops its second (,Ma-era) slot.)
struct FretArrangementDocument: Codable {
    var version: Int = 4
    var segments: [FretSegment]
    var ghostExtentOctaves: Double?
    var legato: Bool?
    var droneRatios: [Double]?
}

// MARK: - FretArrangementStore

/// Saves and loads the Fret-Pad arrangement as JSON. Mac-only persistence with
/// no iPad coupling. Writes are atomic (`*.json.tmp` → move) so a reader never
/// observes a partial file. The live arrangement is auto-saved to a reserved
/// `_Current.json` — the same store pattern the deleted String Pad used.
public enum FretArrangementStore {
    private static let currentName = "_Current"

    /// Directory holding arrangements. Created on first save.
    public static var dir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Starpad", isDirectory: true)
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

    // MARK: Atomic I/O

    private static func write(_ arrangement: FretArrangement, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let doc = FretArrangementDocument(
            segments: arrangement.segments,
            ghostExtentOctaves: arrangement.ghostExtentOctaves,
            legato: arrangement.legato,
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
        // Pre-v4 layouts had no per-segment x (positions were pitch-derived);
        // treat them as absent so the caller rebuilds the new default.
        guard doc.version >= 4 else { throw CocoaError(.coderReadCorrupt) }
        var drones = doc.droneRatios ?? FretArrangement.defaultDroneRatios
        // 4-slot-era migrations (2026-07-25): both historical defaults —
        // the first revision's Sa·Ma·Pa·Sa′ and the octave-lowered
        // ,Sa·,Ma·,Pa·Sa — become the current 3-slot default; a
        // hand-picked 4-slot set keeps its choices minus the second
        // (,Ma-era) slot. Any other count falls back in the initializer.
        if drones.count == 4 {
            let oldDefaults = [[1.0, 4.0 / 3.0, 3.0 / 2.0, 2.0],
                               [0.5, 2.0 / 3.0, 3.0 / 4.0, 1.0]]
            if oldDefaults.contains(where: {
                zip(drones, $0).allSatisfy { abs($0 - $1) < 1e-6 } }) {
                drones = FretArrangement.defaultDroneRatios
            } else {
                drones.remove(at: 1)
            }
        }
        return FretArrangement(
            segments: doc.segments,
            ghostExtentOctaves: doc.ghostExtentOctaves ?? 0.5,
            legato: doc.legato ?? true,
            droneRatios: drones)
    }
}
