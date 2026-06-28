import Foundation

/// The full, persisted instrument document: raga + tonic, the editable
/// sympathetic strings, and the model parameters. Saved/loaded as `.sarangi` JSON.
public struct InstrumentState: Codable, Sendable {
    public var ragaId: Int
    public var ragaName: String
    public var intervals: [Int]
    public var tonicHz: Double
    public var strings: [StringSpec]
    public var params: SarangiParams
    public var fir: [Double]?              // block E body transfer (per fitted preset)
    public var manualEdits: Bool
    /// When true (default), the sympathetic strings auto-tune to the Pitch Pad
    /// scale (tonic + degrees). A manual string edit turns it off so edits stick;
    /// the Tarab tab re-enables it. See `regenerateFromScale`.
    public var autoSyncToScale: Bool
    /// Per-voice FX rack (Violin / Sympathetic / Global) — edited in the FX tab.
    public var fx: FXRack
    public var schemaVersion: Int

    public init(ragaId: Int, ragaName: String, intervals: [Int], tonicHz: Double,
         strings: [StringSpec], params: SarangiParams, fir: [Double]? = nil,
         manualEdits: Bool = false, autoSyncToScale: Bool = true,
         fx: FXRack = .makeDefault(), schemaVersion: Int = 2) {
        self.ragaId = ragaId; self.ragaName = ragaName; self.intervals = intervals
        self.tonicHz = tonicHz; self.strings = strings; self.params = params; self.fir = fir
        self.manualEdits = manualEdits; self.autoSyncToScale = autoSyncToScale
        self.fx = fx; self.schemaVersion = schemaVersion
    }

    // Tolerant decode: `autoSyncToScale`/`fx` default for older documents.
    private enum CodingKeys: String, CodingKey {
        case ragaId, ragaName, intervals, tonicHz, strings, params, fir, manualEdits, autoSyncToScale, fx, schemaVersion
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ragaId = try c.decode(Int.self, forKey: .ragaId)
        ragaName = try c.decode(String.self, forKey: .ragaName)
        intervals = try c.decode([Int].self, forKey: .intervals)
        tonicHz = try c.decode(Double.self, forKey: .tonicHz)
        strings = try c.decode([StringSpec].self, forKey: .strings)
        params = try c.decode(SarangiParams.self, forKey: .params)
        fir = try c.decodeIfPresent([Double].self, forKey: .fir)
        manualEdits = (try? c.decode(Bool.self, forKey: .manualEdits)) ?? false
        autoSyncToScale = (try? c.decode(Bool.self, forKey: .autoSyncToScale)) ?? true
        fx = (try? c.decode(FXRack.self, forKey: .fx)) ?? .makeDefault()
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 2
    }

    /// Strings as the DSP bank consumes them (the bank filters `enabled` itself).
    public var resolvedStrings: [ResolvedString] { strings.map(\.resolved) }

    /// Default to a fitted preset (the latest settings + body FIR) so the live
    /// model matches the offline render out of the box. pair1 = E♭ harmonic minor,
    /// matching Starpad's historically-deployed raga.
    public static func makeDefault() -> InstrumentState { Presets.state(.pair1) }

    /// Switch raga: reset tonic to the raga hint and regenerate the bank.
    public mutating func setRaga(id: Int) {
        let raga = RagaTuning.raga(id: id)
        ragaId = raga.id; ragaName = raga.name; intervals = raga.intervals; tonicHz = raga.tonicHint
        regenerate()
    }

    /// Rebuild the bank from raga + tonic (discards manual edits).
    public mutating func regenerate(detune: Bool = true) {
        strings = StringSpec.bank(tonic: tonicHz, intervals: intervals, detune: detune)
        manualEdits = false
    }

    /// Rebuild the bank from the current SCALE: a tonic (Hz) + scale-degree
    /// ratios (the Pitch Pad scale). Sets `tonicHz` to match and clears manual
    /// edits. Used by the auto-sync path.
    public mutating func regenerateFromScale(tonicHz: Double, ratios: [Double], detune: Bool = true) {
        guard tonicHz > 20, tonicHz < 4000, !ratios.isEmpty else { return }
        self.tonicHz = tonicHz
        strings = StringSpec.bank(tonic: tonicHz, ratios: ratios, detune: detune)
        manualEdits = false
    }

    /// Change key while preserving manual edits (scale every string frequency).
    public mutating func transpose(toTonic newTonic: Double) {
        guard tonicHz > 0 else { return }
        let ratio = newTonic / tonicHz
        for i in strings.indices { strings[i].freq *= ratio }
        tonicHz = newTonic
    }
}
