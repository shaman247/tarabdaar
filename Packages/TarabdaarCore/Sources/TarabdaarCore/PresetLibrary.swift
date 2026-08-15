import Foundation

/// THE PRESET LIBRARY (2026-07-30) — the app-managed folder of saved
/// presets.
///
/// The player never sees a file panel: saving asks for a NAME, and every
/// saved preset appears in the Load-preset menu automatically. Under the
/// hood each preset is one `.tarabdaar` file (`TarabdaarPreset`) in
/// `Application Support/Tarabdaar/Presets/`, named after the preset — so a
/// preset can still be shared or backed up by copying the file, and a
/// file dropped into the folder shows up in the menu on the next refresh.
public struct PresetLibrary {

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The shipping location: `Application Support/Tarabdaar/Presets/`
    /// (inside the sandbox container when sandboxed).
    public static func standard() -> PresetLibrary {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return PresetLibrary(directory: base
            .appendingPathComponent("Tarabdaar", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true))
    }

    /// Saved preset names, sorted for the menu. A missing folder is just
    /// an empty library.
    public func names() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        // `.starpad`/`.tarabpad` are the pre-rename extensions (see
        // `LegacyMigration`) — still listed so a legacy backup dropped
        // into the folder works without a manual rename.
        return Set(urls.filter { Self.extensions.contains($0.pathExtension) }
            .map { $0.deletingPathExtension().lastPathComponent })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Save under `name`, overwriting an existing preset of that name.
    /// Throws on an empty name (after sanitizing) or on a write failure.
    @discardableResult
    public func save(_ preset: TarabdaarPreset, name: String) throws -> URL {
        var p = preset
        p.name = try Self.sanitized(name)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = url(for: p.name)
        try p.encoded().write(to: url)
        return url
    }

    public func load(name: String) throws -> TarabdaarPreset {
        let target = urls(for: name)
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? url(for: name)
        return try TarabdaarPreset.decode(Data(contentsOf: target))
    }

    public func delete(name: String) throws {
        var deleted = false
        for url in urls(for: name)
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            deleted = true
        }
        if !deleted {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    /// Current extension first, then the pre-rename ones.
    private static let extensions = ["tarabdaar", "starpad", "tarabpad"]

    /// Every filename `name` may live under, current extension first.
    private func urls(for name: String) -> [URL] {
        Self.extensions.map {
            directory.appendingPathComponent(name).appendingPathExtension($0)
        }
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
            .appendingPathExtension("tarabdaar")
    }

    /// A preset name doubles as its filename, so path separators (and the
    /// legacy-HFS `:`) are replaced and surrounding whitespace dropped.
    public static func sanitized(_ name: String) throws -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "PresetLibrary", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Preset name is empty",
            ])
        }
        return cleaned
    }
}
