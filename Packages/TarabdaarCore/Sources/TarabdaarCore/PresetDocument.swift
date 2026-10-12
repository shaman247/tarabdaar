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
/// Version 1 supports partial files. Version 2 is a validated complete
/// snapshot, enveloped so old readers cannot silently apply only part of it.
public struct TarabdaarPreset: Codable {

    /// Version 1 is the legacy flat format; version 2 requires a complete snapshot.
    public static let currentVersion = 2
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

    /// Legacy files merge split stores and express the old strum threshold on today's scale.
    public func resolvedParamValues() -> [String: Double]? {
        guard version == 1 else { return paramValues }
        guard paramValues != nil || stringOverrides != nil else { return nil }
        var values = (stringOverrides ?? [:]).merging(paramValues ?? [:]) { _, value in value }
        if let threshold = values["ctl_strum_thresh"], threshold > 1 {
            values["ctl_strum_thresh"] = min(1, threshold / 127)
        }
        return values
    }

    /// The FX rack's EQ curves — each insert point's control points, keyed
    /// by the point's key prefix (`fx_voice_`). The curve is inferred from
    /// the points (`SarangiKit.EQCurve`); a point with no entry is flat.
    public var fxCurves: [String: [EQPoint]]?

    /// Editable bow-axis points, keyed by expr / pos / press; an empty section resets to factory.
    public var bowAxisCurves: [String: [BowAxisPoint]]?

    public static func factoryBowAxisCurves() -> [String: [BowAxisPoint]] {
        let bp = Presets.bowedStringParams() ?? BowParams(num: [:])
        return Dictionary(uniqueKeysWithValues: BowAxis.allCases.map {
            ($0.rawValue, BowAxisTransform(bp: bp, axis: $0.rawValue).points)
        })
    }

    /// Structured curves win; older parameter sections inherit untouched factory knots.
    public func resolvedBowAxisCurves() -> [String: [BowAxisPoint]]? {
        let factory = Self.factoryBowAxisCurves()
        if let curves = bowAxisCurves {
            return factory.merging(curves.filter { BowAxis(rawValue: $0.key) != nil }
                .mapValues(BowAxisTransform.normalize)) { _, curve in curve }
        }
        guard paramValues != nil || stringOverrides != nil else { return nil }
        var bp = Presets.bowedStringParams() ?? BowParams(num: [:])
        let values = (stringOverrides ?? [:]).merging(paramValues ?? [:]) { _, value in value }
        for (key, value) in values { bp.num[key] = value }
        return Dictionary(uniqueKeysWithValues: BowAxis.allCases.map {
            ($0.rawValue, BowAxisTransform(bp: bp, axis: $0.rawValue).points)
        })
    }

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
    /// Ordered drone-button slots for Down / GL; repetitions are intentional.
    public var droneSequence: [Int]?

    /// The complete playing surface; absent only in legacy or partial presets.
    public var playingSurface: PresetPlayingSurface?
    /// Informational provenance, independent of the document format version.
    public var savedBy: String?

    /// Validate before applying any section of a complete snapshot.
    public func validate() throws {
        guard (1...Self.currentVersion).contains(version) else {
            throw PresetError.invalid("Preset version \(version) is not supported by this app.")
        }
        guard version >= 2 else { return }
        guard let instrument, let paramValues, let tiltMapping,
              fxCurves != nil, bowAxisCurves != nil, let composites,
              let mainInstrument, let droneVoice, droneSequence != nil,
              let playingSurface else {
            throw PresetError.invalid("The complete preset is missing a required section.")
        }
        let unknown = paramValues.keys.filter { ParamRegistry.spec($0) == nil }.sorted()
        guard unknown.isEmpty else {
            throw PresetError.invalid("Unsupported preset parameters: " + unknown.joined(separator: ", "))
        }
        guard paramValues.values.allSatisfy(\.isFinite) else {
            throw PresetError.invalid("The preset contains a non-finite parameter.")
        }
        let unknownTargets = tiltMapping.mappings.filter {
            !$0.value.bindings.isEmpty && MapTarget.from(storageKey: $0.key) == nil
        }.keys.sorted()
        guard unknownTargets.isEmpty else {
            throw PresetError.invalid("Unsupported controller targets: " + unknownTargets.joined(separator: ", "))
        }
        guard composites.flatMap(\.members).allSatisfy({ ParamRegistry.spec($0.key) != nil }) else {
            throw PresetError.invalid("The preset contains an unsupported composite member.")
        }
        guard ["string", "tanpura", "sitar"].contains(mainInstrument),
              ["tanpura", "sympathetic"].contains(droneVoice) else {
            throw PresetError.invalid("The preset contains unsupported voice routing.")
        }
        let ratios = scaleDegrees(from: PitchScale(points: playingSurface.scalePoints)).map(\.ratio)
        guard ratios == instrument.scaleRatios,
              instrument.tonicHz.isFinite, instrument.tonicHz > 20, instrument.tonicHz < 4000,
              Set(instrument.strings.map(\.id)).count == instrument.strings.count else {
            throw PresetError.invalid("The preset's tuning or string identities are inconsistent.")
        }
    }

    /// Legacy documents carry ratios only; keep matching labels when reconstructing their scale.
    public func resolvedScale(current: PitchScale) -> PitchScale? {
        if let playingSurface { return PitchScale(points: playingSurface.scalePoints) }
        guard let instrument else { return nil }
        if scaleDegrees(from: current).map(\.ratio) == instrument.scaleRatios { return current }
        return PitchScale(points: instrument.scaleRatios.map { ratio in
            if let point = current.points.first(where: { abs($0.ratio - ratio) < 1e-12 }) {
                var point = point; point.enabled = true; return point
            }
            let fraction = bestFraction(ratio, maxDen: 16383)
            return PitchPoint(num: fraction.num, den: fraction.den, y: 0.5)
        })
    }

    // MARK: - Sections

    /// What a file carries, for the load-time summary.
    public func sections() -> [String] {
        var s: [String] = []
        if instrument != nil { s.append("instrument") }
        if playingSurface != nil { s.append("scale and frets") }
        if let o = stringOverrides, !o.isEmpty { s.append("\(o.count) physics") }
        if let p = paramValues, !p.isEmpty { s.append("\(p.count) parameters") }
        if let c = composites, !c.isEmpty { s.append("\(c.count) composites") }
        if let f = fxCurves, !f.isEmpty { s.append("\(f.count) EQ curves") }
        if bowAxisCurves != nil { s.append("bow-axis curves") }
        if let t = tiltMapping {
            let n = t.mappings.values.filter { !$0.bindings.isEmpty }.count
            if n > 0 { s.append("\(n) tilt bindings") }
        }
        if mainInstrument != nil || droneVoice != nil { s.append("voice routing") }
        if droneSequence != nil { s.append("drone sequence") }
        return s
    }

    /// True when the file has nothing to apply — the case worth telling
    /// the player about instead of silently doing nothing.
    public var isEmpty: Bool { sections().isEmpty }

    // MARK: - Coding

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, name, savedAt, savedBy, snapshot, instrument, stringOverrides,
             paramValues, fxCurves, bowAxisCurves, composites, tiltMapping,
             mainInstrument, droneVoice, droneSequence, playingSurface
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(format) else {
            throw PresetError.invalid("Preset version \(format) is not supported by this app.")
        }
        if format == 2 {
            // Old readers see no legacy sections and cannot partially apply a new snapshot.
            self = try c.decode(TarabdaarPreset.self, forKey: .snapshot)
            version = format
            try validate()
            return
        }
        version = format
        name = try c.decode(String.self, forKey: .name)
        savedAt = try c.decodeIfPresent(String.self, forKey: .savedAt)
        savedBy = try c.decodeIfPresent(String.self, forKey: .savedBy)
        instrument = try c.decodeIfPresent(InstrumentState.self, forKey: .instrument)
        stringOverrides = try c.decodeIfPresent([String: Double].self, forKey: .stringOverrides)
        paramValues = try c.decodeIfPresent([String: Double].self, forKey: .paramValues)
        fxCurves = try c.decodeIfPresent([String: [EQPoint]].self, forKey: .fxCurves)
        bowAxisCurves = try c.decodeIfPresent([String: [BowAxisPoint]].self, forKey: .bowAxisCurves)
        composites = try c.decodeIfPresent([CompositeParam].self, forKey: .composites)
        tiltMapping = try c.decodeIfPresent(DimensionMapping.self, forKey: .tiltMapping)
        mainInstrument = try c.decodeIfPresent(String.self, forKey: .mainInstrument)
        droneVoice = try c.decodeIfPresent(String.self, forKey: .droneVoice)
        droneSequence = try c.decodeIfPresent([Int].self, forKey: .droneSequence)
        playingSurface = try c.decodeIfPresent(PresetPlayingSurface.self, forKey: .playingSurface)
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(savedAt, forKey: .savedAt)
        try c.encodeIfPresent(savedBy, forKey: .savedBy)
        if version == 2 {
            var body = self; body.version = 1
            try c.encode(body, forKey: .snapshot)
            return
        }
        try c.encodeIfPresent(instrument, forKey: .instrument)
        try c.encodeIfPresent(stringOverrides, forKey: .stringOverrides)
        try c.encodeIfPresent(paramValues, forKey: .paramValues)
        try c.encodeIfPresent(fxCurves, forKey: .fxCurves)
        try c.encodeIfPresent(bowAxisCurves, forKey: .bowAxisCurves)
        try c.encodeIfPresent(composites, forKey: .composites)
        try c.encodeIfPresent(tiltMapping, forKey: .tiltMapping)
        try c.encodeIfPresent(mainInstrument, forKey: .mainInstrument)
        try c.encodeIfPresent(droneVoice, forKey: .droneVoice)
        try c.encodeIfPresent(droneSequence, forKey: .droneSequence)
        try c.encodeIfPresent(playingSurface, forKey: .playingSurface)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Decode a preset file. A file with no section decodes fine and
    /// reports `isEmpty`.
    public static func decode(_ data: Data) throws -> TarabdaarPreset {
        // Check bank tags before the tolerant legacy string decoder can replace them.
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let body = (raw?["snapshot"] as? [String: Any]) ?? raw
        if let instrument = body?["instrument"] as? [String: Any],
           let schema = instrument["schemaVersion"] as? Int {
            guard schema <= InstrumentState.currentSchemaVersion else {
                throw PresetError.invalid("This instrument document needs a newer app.")
            }
            if schema >= 4, let rows = instrument["strings"] as? [[String: Any]] {
                guard rows.allSatisfy({ row in
                    ["raga", "chromatic"].contains(row["set"] as? String ?? "")
                        && (schema < 5 || row["followsScale"] is Bool)
                }) else {
                    throw PresetError.invalid("The preset has lost its string-bank tags. Restore an intact backup.")
                }
            }
        }
        return try JSONDecoder().decode(TarabdaarPreset.self, from: data)
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


public enum PresetError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// Scale labels, exact ratios and the complete editable playing surface.
public struct PresetPlayingSurface: Codable {
    public var scalePoints: [PitchPoint]
    public var fretRowCount = 5
    public var fretSegments: [FretSegment]
    public var ghostExtentOctaves: Double
    public var droneRatios: [Double]
    public var snapPixels: Double
    public var primeLimit: Int

    public init(scale: PitchScale, arrangement: FretArrangement,
                snapPixels: Double, primeLimit: Int) {
        scalePoints = scale.points
        fretSegments = arrangement.segments
        ghostExtentOctaves = arrangement.ghostExtentOctaves
        droneRatios = arrangement.droneRatios
        self.snapPixels = snapPixels
        self.primeLimit = primeLimit
    }

    private enum CodingKeys: String, CodingKey {
        case scalePoints, fretRowCount, fretSegments, ghostExtentOctaves, droneRatios, snapPixels, primeLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scalePoints = try c.decode([PitchPoint].self, forKey: .scalePoints)
        fretRowCount = try c.decodeIfPresent(Int.self, forKey: .fretRowCount) ?? 3
        guard [3, 5].contains(fretRowCount) else { throw CocoaError(.coderReadCorrupt) }
        fretSegments = try FretSegment.decodeList(from: c.superDecoder(forKey: .fretSegments),
                                                 legacyRows: fretRowCount == 3)
        fretRowCount = 5
        ghostExtentOctaves = try c.decode(Double.self, forKey: .ghostExtentOctaves)
        droneRatios = try c.decode([Double].self, forKey: .droneRatios)
        snapPixels = try c.decode(Double.self, forKey: .snapPixels)
        primeLimit = try c.decode(Int.self, forKey: .primeLimit)
    }

    public var arrangement: FretArrangement {
        FretArrangement(segments: fretSegments, ghostExtentOctaves: ghostExtentOctaves,
                        droneRatios: droneRatios)
    }
}
