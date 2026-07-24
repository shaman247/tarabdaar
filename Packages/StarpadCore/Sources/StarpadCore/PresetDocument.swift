import Foundation
import SarangiKit

/// THE STARPAD PRESET (2026-07-24) — the saved-rig document.
///
/// It folds in what used to be the `.sarangi` document (the tarab table +
/// tonic + model params) and adds what was previously unsaveable: the
/// parameter values, the composites built from them, and the tilt
/// bindings that drive them.
///
/// **Two scopes, saved separately** (2026-07-24, second pass): a sound and
/// the way you map your tilts are independent things, and you want to swap
/// one without losing the other. So the app saves an **instrument** preset
/// (`.starpad`) and a **controls** preset (`.starpadmap`) from their own
/// tabs. Both are this same document with different sections filled in,
/// and loading is scope-filtered — a file that happens to carry both (an
/// older combined `.starpad`) can be loaded as either, applying only that
/// half.
///
/// Sections stay optional so a partial file is legitimate and so a file
/// written by a newer build that adds a section still loads here.
/// Which half of a rig a preset covers.
public enum PresetScope: String, Codable, CaseIterable, Sendable {
    /// The SOUND: the sarangi instrument document, the physics overrides,
    /// and every parameter's resting value.
    case instrument
    /// The MAPPING: composites and the tilt bindings that drive them.
    case controls
    /// Everything (what a combined save produced before the split).
    case all

    public var label: String {
        switch self {
        case .instrument: return "instrument"
        case .controls:   return "controls"
        case .all:        return "instrument + controls"
        }
    }

    /// Default file extension. Distinct so the open panel and the Finder
    /// make the two obviously different things.
    public var fileExtension: String {
        self == .controls ? "starpadmap" : "starpad"
    }

    /// True when this scope includes `other` — `.all` covers both.
    public func covers(_ other: PresetScope) -> Bool {
        self == .all || self == other
    }
}

public struct StarpadPreset: Codable {

    /// 1 = the initial format. Bump only for changes a reader cannot
    /// tolerate; adding an optional section does not need it.
    public var version = 1
    public var name: String = ""
    /// ISO-8601, informational only.
    public var savedAt: String?
    /// What this file was saved AS. Informational — loading is filtered by
    /// the scope the caller asks for, not by this — but it lets the UI say
    /// "that's a controls preset" when you open one in the wrong place.
    /// Absent in files written before the instrument/controls split.
    public var kind: PresetScope?

    /// The sarangi instrument document: tarab strings, tonic, model
    /// params. This is exactly what a `.sarangi` file used to hold.
    public var instrument: InstrumentState?

    /// `bowed_string.json` physics overrides — the `.rebuild` and
    /// `.hybrid`-headroom half of the parameter list.
    public var stringOverrides: [String: Double]?

    /// Resting values of the `.live` / `.hybrid` parameters (what
    /// `AppController.paramValues` holds).
    public var paramValues: [String: Double]?

    /// Composite parameters (the 0–1 macros).
    public var composites: [CompositeParam]?

    /// Tilt bindings — composites AND direct single-parameter targets.
    public var tiltMapping: DimensionMapping?

    // MARK: - Sections

    /// What a file carries, for the load-time summary. Pass a scope to
    /// describe only the half that will actually be applied.
    public func sections(in scope: PresetScope = .all) -> [String] {
        var s: [String] = []
        if scope.covers(.instrument) {
            if instrument != nil { s.append("instrument") }
            if let o = stringOverrides, !o.isEmpty { s.append("\(o.count) physics") }
            if let p = paramValues, !p.isEmpty { s.append("\(p.count) parameters") }
        }
        if scope.covers(.controls) {
            if let c = composites, !c.isEmpty { s.append("\(c.count) composites") }
            if let t = tiltMapping {
                let n = t.mappings.values.filter { !$0.bindings.isEmpty }.count
                if n > 0 { s.append("\(n) tilt bindings") }
            }
        }
        return s
    }

    /// True when the file has nothing this scope would apply — the case
    /// worth telling the player about instead of silently doing nothing.
    public func isEmpty(in scope: PresetScope) -> Bool {
        sections(in: scope).isEmpty
    }

    // MARK: - Coding

    public init() {}

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Decode a preset file. Falls back to the LEGACY `.sarangi` format (a
    /// bare `InstrumentState`), so files saved before this existed still
    /// open — they simply carry only the instrument section.
    public static func decode(_ data: Data) throws -> StarpadPreset {
        let dec = JSONDecoder()
        if let p = try? dec.decode(StarpadPreset.self, from: data),
           p.version > 0, p.hasAnySection {
            return p
        }
        // legacy: the whole file IS the instrument document
        let state = try dec.decode(InstrumentState.self, from: data)
        var p = StarpadPreset()
        p.name = "Imported instrument"
        p.instrument = state
        return p
    }

    private var hasAnySection: Bool {
        instrument != nil || stringOverrides != nil || paramValues != nil
            || composites != nil || tiltMapping != nil
    }
}
