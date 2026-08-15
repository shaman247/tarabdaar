import Foundation

/// The default instrument preset. There is ONE: the sarangi Pilu bank —
/// since the scale centralization (2026-07-25) purely a SEED document (the
/// Pilu scale's JI degree ratios + the generated string layout); on launch
/// the Pitch Pad scale is pushed over it, so what ships is the layout and
/// the gains/t60s, not a pitch table. The timbre lives in
/// `bowed_string.json`.
///
/// (The EXACT fitted string table — `sarangi_pilu_strings.json`, PCG64-
/// seeded per-string detunes, and with it the STRING-TABLE LAW — was
/// retired 2026-07-25 with the scale-defined pitch model: a degree can't
/// be a few cents off itself. Strings now sit exactly on the scale's JI
/// grid. Git history has the fitted artifact and the law's measurements.)
public enum Preset: String, CaseIterable, Sendable {
    case sarangiPilu = "sarangi_pilu"

    public var ragaId: Int { 3 }
    public var displayName: String { "Default (Sarangi Live) — Pilu" }
}

public enum Presets {
    /// A full instrument state for the preset: the raga's JI degree ratios
    /// as the scale, its session tonic as the starting tonic, and the
    /// generated degree-indexed string layout.
    public static func state(_ p: Preset) -> InstrumentState {
        let raga = RagaTuning.raga(id: p.ragaId)
        let scale = RagaTuning.ratios(forIntervals: raga.intervals)
        return InstrumentState(tonicHz: raga.tonicHint,
                               scaleRatios: scale,
                               strings: RagaTuning.buildSpecs(scaleRatios: scale))
    }

    // MARK: - The String instrument (pure-physics bowed gut string)

    /// The bundled generic pure-physics bowed-string artifact
    /// (`bowed_string.json`, written by upstream `scripts/make_bowed_string.py`
    /// + the fit7-era String campaign). Everything the live String engine
    /// needs: friction/body/control-law scalars, the calibrated pitch tables,
    /// the modal-jawari taraf physics (`bow_jt_*`) and the live trims. nil when
    /// missing from the bundle.
    public static func bowedStringParams() -> BowParams? {
        guard let url = Bundle.module.url(forResource: "bowed_string", withExtension: "json") else {
            return nil
        }
        return BowParams(url: url)
    }

    // MARK: - The Tanpura voice (r7 modal-contact plucked drone)

    /// The bundled fitted tanpura artifact (`tanpura_live.json`, written by
    /// the Sarangi Live exporter `scripts/export_tanpura_live.py`; ported
    /// 2026-08-04). String-construction laws per register role, the bridge
    /// geometry, the polarization config, the per-note pitch-calibration
    /// cents and the body/capture EQ FIR. RECAL LAW: the cents and role
    /// t60s are secanted at this exact physics config — regenerate the
    /// artifact upstream-style after any physics change, never hand-edit.
    /// nil when missing from the bundle.
    public static func tanpuraParams() -> TanpuraParams? {
        guard let url = Bundle.module.url(forResource: "tanpura_live", withExtension: "json") else {
            return nil
        }
        return TanpuraParams(url: url)
    }

}
