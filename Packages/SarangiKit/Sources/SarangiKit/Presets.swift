import Foundation

/// The fitted instrument preset, bundled as resources. Since the v57-only
/// simplification (upstream 2026-07-12) there is ONE: the v57 sarangi (Pilu
/// session fit — the shared fitted chain + the v57 deltas: no reverb, no
/// drone, taraf direct tap — plus the EXACT offline string table). The
/// additive-era presets (pair1/pair2/sarangi_eb/sarangi_d) were removed with
/// the legacy render paths (upstream git history). Raga/tonic remain live
/// choices: switching raga (or the Pitch-Pad tarab sync) retunes the taraf
/// bank; only Pilu has a fitted table today.
public enum Preset: String, CaseIterable, Sendable {
    case sarangiPilu = "sarangi_pilu"

    public var ragaId: Int { 3 }
    public var displayName: String { "Default (Sarangi Live) — Pilu, fitted" }
}

public enum Presets {
    public static func params(_ p: Preset) -> SarangiParams {
        guard let url = Bundle.module.url(forResource: p.rawValue, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? SarangiParams.loadPreset(data: data) else { return .defaults }
        return parsed
    }

    /// Exact offline string table bundled with the preset
    /// (`<preset>_strings.json`, exported by `gen_sarangi_presets.py` from
    /// `raga.get`). STRING-TABLE LAW (upstream 2026-07-12): the offline detunes
    /// are PCG64-seeded while `StringSpec.bank` uses the Swift RNG — the tables
    /// differ ~5 c rms PER STRING, which moves every taraf resonance relative
    /// to the voice's harmonics (measured upstream: a −3.7 dB 125–250 Hz lean +
    /// audibly weaker ring vs the offline render; the exact table closed it to
    /// −0.5 dB). A live twin of a fitted bank must LOAD the fitted table, never
    /// regenerate it. (Note: Starpad's tarab auto-sync REPLACES this table when
    /// the Pitch Pad scale differs — turn auto-sync off to keep the fit exact.)
    ///
    /// Starpad: rows are tagged with their `StringGroup` positionally, using
    /// the same choir segmentation `RagaTuning.buildChoirs` emits (15 chromatic
    /// + |ratios|+2 scale + 7 low + 6 upper — validated against the row count).
    static func bundledStrings(_ p: Preset) -> [StringSpec]? {
        guard let url = Bundle.module.url(forResource: "\(p.rawValue)_strings",
                                          withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["strings"] as? [[Any]] else { return nil }
        let raga = RagaTuning.raga(id: p.ragaId)
        let nScale = raga.intervals.count + 2
        var groups: [StringGroup] = []
        groups.append(contentsOf: [StringGroup](repeating: .chromatic, count: 15))
        groups.append(contentsOf: [StringGroup](repeating: .scale, count: nScale))
        groups.append(contentsOf: [StringGroup](repeating: .lowOctave, count: 7))
        groups.append(contentsOf: [StringGroup](repeating: .upperOctave, count: 6))
        let tagged = groups.count == rows.count
        let specs: [StringSpec] = rows.enumerated().compactMap { (i, r) in
            guard r.count >= 4,
                  let f = (r[0] as? NSNumber)?.doubleValue,
                  let g = (r[1] as? NSNumber)?.doubleValue,
                  let t = (r[2] as? NSNumber)?.doubleValue,
                  let b = (r[3] as? NSNumber)?.doubleValue else { return nil }
            return StringSpec(freq: f, gain: g, t60: t, bright: b > 0.5,
                              group: tagged ? groups[i] : .scale)
        }
        return specs.isEmpty ? nil : specs
    }

    /// A full instrument state for the fitted preset (raga + tonic + strings +
    /// params). Output EQ seeds FLAT (upstream 2026-07-09 law: the fitted W
    /// valley supersedes the de-horn cuts; dehornA remains a selectable preset).
    public static func state(_ p: Preset) -> InstrumentState {
        let raga = RagaTuning.raga(id: p.ragaId)
        var s = InstrumentState(ragaId: raga.id, ragaName: raga.name, intervals: raga.intervals,
                                tonicHz: raga.tonicHint,
                                strings: bundledStrings(p)
                                    ?? StringSpec.bank(tonic: raga.tonicHint, intervals: raga.intervals),
                                params: params(p))
        s.eqBands = []
        return s
    }

    // MARK: - Fitted source model (ViolinSynth data)

    /// Load the bundled fitted source model (`sarangi_model_v57.json` — the v57
    /// exact-timbre voice the `ViolinSynth` plays; upstream's sarangi9
    /// matcher-final state). ~3.5 MB of control-grid tables; parse once and
    /// cache in the caller.
    public static func sarangiSourceModel() throws -> ViolinModel {
        guard let url = Bundle.module.url(forResource: "sarangi_model_v57", withExtension: "json") else {
            throw ViolinModel.LoadError.badJSON("sarangi_model_v57.json missing from bundle")
        }
        return try ViolinModel(url: url)
    }

    /// The end-to-end per-note loudness calibration for the live expression
    /// equalizer (`live_comp.json`, written by the upstream
    /// calibrate_live_loudness tool). nil when absent — surfaces-only EQ.
    public static func liveLoudnessComp() -> (midis: [Double], db: [Double])? {
        guard let url = Bundle.module.url(forResource: "live_comp", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: [NSNumber]],
              let cm = j["midi"], let cd = j["db"], cm.count == cd.count else { return nil }
        return (cm.map(\.doubleValue), cd.map(\.doubleValue))
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

    /// The bundled coupled bridge–body network config (`sarangi_coupled.json`).
    /// REQUIRED since the v57-only simplification — `SarangiEngine` renders
    /// only the passive junction (`N_junction "passive"`); without this config
    /// it outputs silence (`isArmed == false`). Its radiation FIR ships at both
    /// 44.1 kHz (`N_rfir`, what Starpad's engine uses) and 48 kHz (`N_rfir_48k`).
    public static func coupledConfig() -> CoupledConfig? {
        guard let url = Bundle.module.url(forResource: "sarangi_coupled", withExtension: "json") else {
            return nil
        }
        return CoupledConfig(url: url)
    }
}
