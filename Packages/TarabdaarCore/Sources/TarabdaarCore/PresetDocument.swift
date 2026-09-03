import Foundation
import SarangiKit

/// THE TARABDAAR PRESET — the saved-rig document: the tarab table, tonic
/// and model params, the parameter values, the composites built from
/// them, and the tilt bindings that drive them.
///
/// **One file, the whole rig**: a `.tarabdaar` save carries every
/// section — the instrument AND the controls. Loading
/// applies whatever sections a file has, so older partial files still
/// work — a `.tarabdaarmap` simply carries only composites + tilt bindings
/// and leaves the instrument alone. (Split-era files also wrote a `kind`
/// tag; it decodes away ignored.)
///
/// Sections stay optional so a partial file is legitimate and so a file
/// written by a newer build that adds a section still loads here.
public struct TarabdaarPreset: Codable {

    /// 1 = the initial format. Bump only for changes a reader cannot
    /// tolerate; adding an optional section does not need it.
    public var version = 1
    public var name: String = ""
    /// ISO-8601, informational only.
    public var savedAt: String?

    /// The sarangi instrument document: tarab strings, tonic, model
    /// params.
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

    /// Voice routing (with the tanpura port): which voice the
    /// played notes drive (`AudioEngine.MainInstrument` raw value) and
    /// which the drone buttons drive (`AudioEngine.DroneVoiceMode` raw
    /// value). Strings, not enums, so an unknown future value decodes and
    /// simply fails the lookup at apply time.
    public var mainInstrument: String?
    public var droneVoice: String?

    // MARK: - Sections

    /// What a file carries, for the load-time summary.
    public func sections() -> [String] {
        var s: [String] = []
        if instrument != nil { s.append("instrument") }
        if let o = stringOverrides, !o.isEmpty { s.append("\(o.count) physics") }
        if let p = paramValues, !p.isEmpty { s.append("\(p.count) parameters") }
        if let c = composites, !c.isEmpty { s.append("\(c.count) composites") }
        if let t = tiltMapping {
            let n = t.mappings.values.filter { !$0.bindings.isEmpty }.count
            if n > 0 { s.append("\(n) tilt bindings") }
        }
        if mainInstrument != nil || droneVoice != nil { s.append("voice routing") }
        return s
    }

    /// True when the file has nothing to apply — the case worth telling
    /// the player about instead of silently doing nothing.
    public var isEmpty: Bool { sections().isEmpty }

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
    public static func decode(_ data: Data) throws -> TarabdaarPreset {
        let dec = JSONDecoder()
        if let p = try? dec.decode(TarabdaarPreset.self, from: data),
           p.version > 0, p.hasAnySection {
            return p
        }
        // legacy: the whole file IS the instrument document
        let state = try dec.decode(InstrumentState.self, from: data)
        var p = TarabdaarPreset()
        p.name = "Imported instrument"
        p.instrument = state
        return p
    }

    private var hasAnySection: Bool {
        instrument != nil || stringOverrides != nil || paramValues != nil
            || composites != nil || tiltMapping != nil
            || mainInstrument != nil || droneVoice != nil
    }
}
