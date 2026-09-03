import Foundation

/// The default instrument preset. There is ONE: the sarangi Pilu bank —
/// since the scale centralization purely a SEED document (the
/// Pilu scale's JI degree ratios + the generated string layout); on launch
/// the Pitch Pad scale is pushed over it, so what ships is the layout and
/// the gains/t60s, not a pitch table. The timbre lives in
/// `bowed_string.json`.
///
/// (Strings sit exactly on the scale's JI grid — there is no per-string
/// detune table; see docs/history/ for the retired fitted table.)
public enum Preset: String, CaseIterable, Sendable {
    case sarangiPilu = "sarangi_pilu"

    public var ragaId: Int { 3 }
    public var displayName: String { "Default (Sarangi Live) — Pilu" }
}

public enum Presets {
    /// A full instrument state for the preset: the raga's JI degree ratios
    /// as the scale, its session tonic as the starting tonic, and the
    /// generated string layout — BOTH sets  the raga
    /// bridge's degree-indexed rows plus the chromatic bridge's fixed
    /// 15-semitone row (`chromatic: false` = the raga set alone, for
    /// scaffolds that measure one bridge).
    public static func state(_ p: Preset, chromatic: Bool = true) -> InstrumentState {
        let raga = RagaTuning.raga(id: p.ragaId)
        let scale = RagaTuning.ratios(forIntervals: raga.intervals)
        return InstrumentState(tonicHz: raga.tonicHint,
                               scaleRatios: scale,
                               strings: RagaTuning.buildSpecs(scaleRatios: scale)
                                   + (chromatic ? RagaTuning.buildChromaticSpecs() : []))
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
    /// the fitting project's exporter `scripts/export_tanpura_live.py`).
    /// String-construction laws per register role, the bridge
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

    /// The bundled fitted SITAR artifact (`sitar_live.json`, written by
    /// `scripts/export_sitar_live.py` in the same fitting project — the
    /// modal-contact model retuned to a sitar reference:
    /// bare-bone jawari with no jiva thread, steel string, near-bridge
    /// pluck, its own body FIR baked from the reference residual). Same
    /// schema as the tanpura artifact — the sitar voice is a second
    /// `TanpuraEngine` mounted from this file; the sympathetic taraf
    /// halo is NOT in the artifact (it is the sarangi jt web, driven
    /// live over `bow_poly_jt_inject_write`). Same RECAL LAW.
    /// nil when missing from the bundle.
    public static func sitarParams() -> TanpuraParams? {
        guard let url = Bundle.module.url(forResource: "sitar_live", withExtension: "json") else {
            return nil
        }
        return TanpuraParams(url: url)
    }

}
