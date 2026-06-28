import Foundation

/// One parametric-EQ band (`(freq, gainDB, q)`), used by the per-voice FX rack.
public struct EQBand: Codable, Sendable, Equatable, Hashable {
    public var freq: Double
    public var gainDB: Double
    public var q: Double
    public init(freq: Double, gainDB: Double, q: Double) {
        self.freq = freq; self.gainDB = gainDB; self.q = q
    }
}

/// The configurable FX for one voice stage (Violin / Sympathetic / Global): a
/// reverb (mix + width), a low-pass filter (cutoff + resonance), and a 3-band
/// parametric EQ. `enabled`, `reverbMix`, `reverbWidth` are **live** (no engine
/// rebuild); the filter/EQ/`reverbRT60` are **structural** (rebuild the stage).
/// **Starpad-local** — not part of the upstream standalone model.
public struct VoiceFXParams: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var reverbMix: Double         // 0..1  (live)
    public var reverbWidth: Double       // 0..1.5 (live)
    public var reverbRT60: Double        // seconds (structural)
    public var filterCutoff: Double      // Hz (structural)
    public var filterResonance: Double   // 0..1 → Q (structural)
    public var eq: [EQBand]              // exactly 3 bands (structural)

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

    /// Violin (main) voice — **ON** by default: a ~25% room + an open filter, the
    /// reverb the user asked to "restore for the violin voice".
    public static func violinDefault() -> VoiceFXParams {
        VoiceFXParams(enabled: true, reverbMix: 0.25, reverbWidth: 0.4, reverbRT60: 1.2,
                      filterCutoff: 18000, filterResonance: 0, eq: flatEQ)
    }
    /// Sympathetic voice — **OFF** by default (dry bank).
    public static func symDefault() -> VoiceFXParams {
        VoiceFXParams(enabled: false, reverbMix: 0.25, reverbWidth: 0.3, reverbRT60: 1.0,
                      filterCutoff: 18000, filterResonance: 0, eq: flatEQ)
    }
    /// Global (post-sum) — **OFF** by default (nothing enabled).
    public static func globalDefault() -> VoiceFXParams {
        VoiceFXParams(enabled: false, reverbMix: 0.2, reverbWidth: 0.2, reverbRT60: 1.5,
                      filterCutoff: 18000, filterResonance: 0, eq: flatEQ)
    }
}

/// The three-stage per-voice FX rack carried on `InstrumentState`.
public struct FXRack: Codable, Sendable, Equatable {
    public var violin: VoiceFXParams
    public var sym: VoiceFXParams
    public var global: VoiceFXParams

    public init(violin: VoiceFXParams, sym: VoiceFXParams, global: VoiceFXParams) {
        self.violin = violin; self.sym = sym; self.global = global
    }

    public static func makeDefault() -> FXRack {
        FXRack(violin: .violinDefault(), sym: .symDefault(), global: .globalDefault())
    }
}
