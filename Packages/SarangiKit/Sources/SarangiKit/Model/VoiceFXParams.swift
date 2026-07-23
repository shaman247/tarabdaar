import Foundation

/// The filter shape of one graphical-EQ node. `peaking`/`highPass`/`lowPass` use
/// the band's `q`; the shelves use a fixed slope (`q` is ignored for them).
public enum EQBandType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case peaking, lowShelf, highShelf, highPass, lowPass

    /// Short label for menus / readouts.
    public var label: String {
        switch self {
        case .peaking:   return "Bell"
        case .lowShelf:  return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .highPass:  return "High Pass"
        case .lowPass:   return "Low Pass"
        }
    }
    /// Whether `q` is meaningful for this shape (UI shows/edits Q only when true).
    public var usesQ: Bool { self != .lowShelf && self != .highShelf }
    /// Whether `gainDB` is meaningful (cuts have no gain — they roll off).
    public var usesGain: Bool { self == .peaking || self == .lowShelf || self == .highShelf }
}

/// One graphical-EQ node, used by the per-voice FX rack. A draggable point on the
/// curve: `(freq, gainDB, q)` shaped by `type`. `id` gives stable identity across
/// re-sorting / add / remove so the UI never addresses a band by a stale index.
public struct EQBand: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var freq: Double
    public var gainDB: Double
    public var q: Double
    public var type: EQBandType
    public var enabled: Bool

    public init(id: UUID = UUID(), freq: Double, gainDB: Double, q: Double,
                type: EQBandType = .peaking, enabled: Bool = true) {
        self.id = id; self.freq = freq; self.gainDB = gainDB; self.q = q
        self.type = type; self.enabled = enabled
    }

    // Tolerant decode: pre-graphical-EQ data has only freq/gainDB/q — those load
    // as enabled `.peaking` bands (behaviourally identical to the old 3-band EQ),
    // so old persisted/`.sarangi` state keeps working without a key bump.
    private enum CodingKeys: String, CodingKey { case id, freq, gainDB, q, type, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        freq    = try c.decode(Double.self, forKey: .freq)
        gainDB  = try c.decode(Double.self, forKey: .gainDB)
        q       = try c.decode(Double.self, forKey: .q)
        type    = (try? c.decode(EQBandType.self, forKey: .type)) ?? .peaking
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }
}

/// The configurable FX for one voice stage (Violin / Sympathetic / Global): a
/// reverb (mix + width), a low-pass filter (cutoff + resonance — the graphical
/// EQ's right-edge node), and a variable-length graphical parametric EQ.
/// `enabled`, `reverbMix`, `reverbWidth` are **live**; the filter + EQ bands are
/// **live filter** (in-place coefficient swap, no engine rebuild — see
/// `VoiceFX.updateFilters`); only `reverbRT60` is **structural**.
/// **Starpad-local** — not part of the upstream standalone model.
public struct VoiceFXParams: Codable, Sendable, Equatable {
    /// Hard cap on graphical-EQ nodes per stage (UI/CPU guard). Min is 0 (an
    /// empty EQ is an exact passthrough — `BiquadChain([])` does nothing).
    public static let maxEQBands = 12
    public static let minEQBands = 0

    public var enabled: Bool
    public var reverbMix: Double         // 0..1  (live)
    public var reverbWidth: Double       // 0..1.5 (live)
    public var reverbRT60: Double        // seconds (structural)
    public var filterCutoff: Double      // Hz (live filter — graphical-EQ right-edge node)
    public var filterResonance: Double   // 0..1 → Q (live filter)
    public var eq: [EQBand]              // 0..maxEQBands graphical-EQ nodes (live filter)

    public init(enabled: Bool, reverbMix: Double, reverbWidth: Double, reverbRT60: Double,
                filterCutoff: Double, filterResonance: Double, eq: [EQBand]) {
        self.enabled = enabled; self.reverbMix = reverbMix; self.reverbWidth = reverbWidth
        self.reverbRT60 = reverbRT60; self.filterCutoff = filterCutoff
        self.filterResonance = filterResonance; self.eq = eq
    }

    /// Flat 3-band starting point (low / mid / high, 0 dB).
    public static var flatEQ: [EQBand] {
        [EQBand(freq: 250, gainDB: 0, q: 1.0),
         EQBand(freq: 1500, gainDB: 0, q: 1.0),
         EQBand(freq: 6000, gainDB: 0, q: 1.0)]
    }

    /// **Pre-drive** stage — **OFF** by default. Sits in front of the coupled
    /// network: it shapes the played-voice signal BEFORE it excites the bridge
    /// / taraf web. Off → the network is driven by the raw voice, exactly as
    /// upstream, so the stage's existence doesn't change the default sound.
    public static func violinPreDefault() -> VoiceFXParams {
        VoiceFXParams(enabled: false, reverbMix: 0.0, reverbWidth: 0.3, reverbRT60: 1.0,
                      filterCutoff: 18000, filterResonance: 0, eq: flatEQ)
    }
    /// Global (output) — **OFF** by default (the v57 ear-law is "no reverb:
    /// the ringing taraf is the room"; the model's own block-F room is a
    /// separate F_mix param, also shipped 0).
    public static func globalDefault() -> VoiceFXParams {
        VoiceFXParams(enabled: false, reverbMix: 0.2, reverbWidth: 0.2, reverbRT60: 1.5,
                      filterCutoff: 18000, filterResonance: 0, eq: flatEQ)
    }
}

/// The FX rack carried on `InstrumentState` — TWO stages since the v57
/// re-vendor (the passive coupled network has ONE output stream, so the old
/// per-voice violin/sym stages have nothing separate to process): `violinPre`
/// (shapes the drive before the network) and `global` (mid/side on the output).
public struct FXRack: Codable, Sendable, Equatable {
    /// FX BEFORE the network — shapes the excitation into the bridge/taraf web.
    public var violinPre: VoiceFXParams
    public var global: VoiceFXParams

    public init(violinPre: VoiceFXParams, global: VoiceFXParams) {
        self.violinPre = violinPre; self.global = global
    }

    public static func makeDefault() -> FXRack {
        FXRack(violinPre: .violinPreDefault(), global: .globalDefault())
    }

    // Tolerant decode: any missing stage (older 4-stage documents predate the
    // persistKey bump anyway) defaults OFF.
    private enum CodingKeys: String, CodingKey { case violinPre, global }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        violinPre = (try? c.decode(VoiceFXParams.self, forKey: .violinPre)) ?? .violinPreDefault()
        global = (try? c.decode(VoiceFXParams.self, forKey: .global)) ?? .globalDefault()
    }
}
