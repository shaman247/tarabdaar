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

    /// The FX rack's EQ curves — each insert point's control points, keyed
    /// by the point's key prefix (`fx_voice_`). The curve is inferred from
    /// the points (`SarangiKit.EQCurve`); a point with no entry is flat.
    public var fxCurves: [String: [EQPoint]]?

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
        if let f = fxCurves, !f.isEmpty { s.append("\(f.count) EQ curves") }
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

    /// Decode a preset file. A file with no section decodes fine and
    /// reports `isEmpty`.
    public static func decode(_ data: Data) throws -> TarabdaarPreset {
        try JSONDecoder().decode(TarabdaarPreset.self, from: data)
    }

    // MARK: - The graphic-EQ bands of older files

    /// The octave centres of the 10-band graphic EQ that preceded the
    /// curve (`fx_<point>_eq_b1`…`_b10`).
    public static let legacyEQBandHz: [Double] =
        [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]

    /// Curves equivalent to the graphic-EQ band values in `values`: a
    /// point at every band centre for each insert point whose bands are
    /// not all flat. Empty when the values carry no bands — a file from
    /// this build, or an older one that never touched the EQ.
    public static func legacyEQCurves(in values: [String: Double])
        -> [String: [EQPoint]] {
        var out: [String: [EQPoint]] = [:]
        for point in FXPoint.allCases {
            let gains = legacyEQBandHz.indices.map {
                values[point.keyPrefix + "eq_b\($0 + 1)"] ?? 0
            }
            guard gains.contains(where: { $0 != 0 }) else { continue }
            out[point.keyPrefix] = zip(legacyEQBandHz, gains)
                .map { EQPoint(hz: $0, db: $1) }
        }
        return out
    }
}
