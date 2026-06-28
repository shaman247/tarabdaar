import Foundation

/// The fitted offline presets (params + baked body FIR), bundled as resources.
/// Loading a preset reproduces that pair's full setup so the live model matches
/// the offline render: raga + tonic, the fitted `pairN.json` parameters, and the
/// `pairN_fir.json` body transfer (block E).
public enum Preset: String, CaseIterable, Sendable {
    case pair1, pair2

    public var ragaId: Int { self == .pair1 ? 1 : 2 }
    public var displayName: String { self == .pair1 ? "pair1 — E♭ harmonic minor" : "pair2 — Bhairav" }
}

public enum Presets {
    public static func params(_ p: Preset) -> SarangiParams {
        guard let url = Bundle.module.url(forResource: p.rawValue, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? SarangiParams.loadPreset(data: data) else { return .defaults }
        return parsed
    }

    public static func fir(_ p: Preset) -> [Double]? {
        guard let url = Bundle.module.url(forResource: "\(p.rawValue)_fir", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let taps = try? JSONDecoder().decode([Double].self, from: data) else { return nil }
        return taps
    }

    /// A full instrument state for a fitted preset (raga + tonic + strings + params + FIR).
    public static func state(_ p: Preset) -> InstrumentState {
        let raga = RagaTuning.raga(id: p.ragaId)
        var s = InstrumentState(ragaId: raga.id, ragaName: raga.name, intervals: raga.intervals,
                                tonicHz: raga.tonicHint,
                                strings: StringSpec.bank(tonic: raga.tonicHint, intervals: raga.intervals),
                                params: params(p))
        s.fir = fir(p)
        return s
    }
}
