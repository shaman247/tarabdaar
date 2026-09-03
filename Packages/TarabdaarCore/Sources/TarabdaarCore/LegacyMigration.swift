import Foundation

#if os(macOS)

/// One-time migration from the app's earlier identities. The app was
/// renamed **Starpad → TarabPad**  and **TarabPad →
/// Tarabdaar** , before anything shipped under the interim
/// name — so an existing install is either Starpad-era (the common case)
/// or a one-day TarabPad build, and both are migrated here.
///
/// A bundle-ID change silently orphans everything keyed to the old
/// identity, so on launch — BEFORE any store reads UserDefaults — the Mac
/// app calls `runIfNeeded()`, which:
///
///   1. moves the newest surviving legacy folder (`Application
///      Support/TarabPad`, else `Application Support/Starpad`) to
///      `Application Support/Tarabdaar` (presets, scales, fret
///      recordings, audition fallback — the whole folder), then renames
///      the presets inside from the legacy `.starpad`/`.tarabpad` (and
///      `map`) extensions to `.tarabdaar`/`.tarabdaarmap`;
///   2. imports the newest surviving preferences domain
///      (`com.tarabpad.TarabPadMac`, else `com.starpad.StarpadMac`, read
///      straight off its plist — the app is not sandboxed) into the new
///      one, mapping the `starpad.`/`tarabpad.` key prefixes to
///      `tarabdaar.` and dropping retired keys (`starpad.tonicHz` — see
///      AppController, the tonic is deliberately per-sitting — and the
///      interim identity's own migration marker).
///
/// Defaults import runs once (marker key below); the folder move is
/// naturally idempotent (the legacy folder is gone after the first run).
/// Existing values in the NEW domain are never overwritten, so re-running
/// after the user has made new edits cannot regress them.
public enum LegacyMigration {

    static let markerKey = "tarabdaar.migratedFromLegacy.v1"

    /// Newest first — a TarabPad-era folder/domain contains the migrated
    /// Starpad data already, so it wins when both exist.
    static let legacyFolders = ["TarabPad", "Starpad"]
    static let legacyDomains = ["com.tarabpad.TarabPadMac",
                                "com.starpad.StarpadMac"]
    static let legacyPrefixes = ["starpad.", "tarabpad."]
    static let retiredKeys: Set<String> = [
        "starpad.tonicHz", "tarabpad.tonicHz",
        "tarabpad.migratedFromStarpad.v1",   // the interim build's marker
    ]

    public static func runIfNeeded() {
        migrateApplicationSupport()
        migrateUserDefaults()
    }

    // MARK: - Application Support/{Starpad,TarabPad} → Tarabdaar

    static func migrateApplicationSupport() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return }
        let new = base.appendingPathComponent("Tarabdaar", isDirectory: true)
        if !fm.fileExists(atPath: new.path),
           let old = legacyFolders
               .map({ base.appendingPathComponent($0, isDirectory: true) })
               .first(where: { fm.fileExists(atPath: $0.path) }) {
            try? fm.moveItem(at: old, to: new)
        }
        renameLegacyPresets(in: new.appendingPathComponent("Presets",
                                                          isDirectory: true))
    }

    /// `.starpad`/`.tarabpad` → `.tarabdaar` (and the split-era `map`
    /// variants), skipping any rename that would clobber an existing
    /// file of the new name.
    static func renameLegacyPresets(in presets: URL) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: presets, includingPropertiesForKeys: nil)) ?? []
        let map = ["starpad": "tarabdaar", "starpadmap": "tarabdaarmap",
                   "tarabpad": "tarabdaar", "tarabpadmap": "tarabdaarmap"]
        for url in urls {
            guard let newExt = map[url.pathExtension] else { continue }
            let dest = url.deletingPathExtension()
                .appendingPathExtension(newExt)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.moveItem(at: url, to: dest)
        }
    }

    // MARK: - UserDefaults legacy domain → the new domain

    static func migrateUserDefaults(into defaults: UserDefaults = .standard,
                                    legacyPlist: URL? = nil) {
        guard defaults.object(forKey: markerKey) == nil else { return }
        defaults.set(true, forKey: markerKey)
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let plist = legacyPlist ?? legacyDomains
            .map { prefsDir.appendingPathComponent("\($0).plist") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let plist,
              let data = try? Data(contentsOf: plist),
              let dict = (try? PropertyListSerialization.propertyList(
                  from: data, format: nil)) as? [String: Any] else { return }
        for (key, value) in dict {
            guard !retiredKeys.contains(key) else { continue }
            let newKey = legacyPrefixes.first(where: key.hasPrefix)
                .map { "tarabdaar." + key.dropFirst($0.count) } ?? key
            guard defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(value, forKey: newKey)
        }
    }
}

#endif
