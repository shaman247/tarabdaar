import Foundation

/// Which block a parameter belongs to (drives the grouped sliders in the UI).
public enum ParamGroup: String, CaseIterable, Sendable, Codable {
    case bank = "Bank"        // B + the junction tap
    case drone = "Drone"      // D
    case body = "Body"        // E_lp
    case reverb = "Reverb"    // F
    case mix = "Mix"
}

/// One tweakable model parameter — the v57 instrument's live surface (the
/// 2026-07-12 simplification removed the legacy feedforward/κ eras' params:
/// jawari exciter C_*, dry/bank/jaw mixes, H1–H5, body ring/shelves, chorus,
/// per-string jawari, bridge coupling, sym gains — none are read by the
/// passive coupled render; git history has the old table). `structural`
/// params redesign filter coefficients (off-thread snapshot rebuild),
/// non-structural ones are live gains the render thread reads per buffer.
public struct ParamDescriptor: Identifiable, Sendable {
    public let id: String          // == name, e.g. "B_gain"
    public let lo: Double
    public let hi: Double
    public let `default`: Double
    public let group: ParamGroup
    public let label: String
    public let structural: Bool
    public var name: String { id }
}

public enum ParamSpec {
    /// (name, lo, hi, default, group, label, structural). Ranges from
    /// fit.py PARAM_SPEC / diff COUPLED_SPEC; defaults from the fitted
    /// artifacts' conventions.
    public static let all: [ParamDescriptor] = [
        d("B_gain",        0.0,  6.0,  0.4,  .bank,   "Bank gain",         false),
        d("B_t60_scale",   0.5,  3.55, 1.0,  .bank,   "Decay × (t60)",     true),
        d("B_bright",      0.0,  1.5,  0.0,  .bank,   "Bright choir",      false),
        // Gut-string HF roll-off baked into the comb loop. Structural.
        d("B_lp",          0.1,  1.0,  0.4,  .bank,   "String brightness", true),
        // THE WEB: polarization doublets + stiff-wire inharmonicity +
        // in-loop f² damping. Structural — rebakes combs. The doublet is
        // MEASUREMENT+EAR-owned (2026-07-12 pol_measure campaign): split
        // ~2.75 ¢ confirmed from the recordings; pairing is the Weinreich
        // AFTERSOUND — the quiet polarization rings LONGER (t60× > 1).
        d("B_pol_split",   0.0,  6.0,  0.0,  .bank,   "Polarization ¢",    true),
        d("B_pol_gain",    0.4,  1.0,  0.85, .bank,   "Polarization gain", true),
        d("B_pol_t60",     0.3,  2.0,  0.65, .bank,   "Polarization t60×", true),
        d("B_inharm",      0.0,  0.3,  0.0,  .bank,   "Wire stiffness",    true),
        d("B_damp",        0.0,  1.0,  0.0,  .bank,   "String damping",    true),
        // stereo: per-string pan spread across the bridge
        d("B_spread",      0.0,  1.0,  0.7,  .bank,   "Stereo spread",     false),
        // Per-class taraf jawari buzz (it22 law: raga > chrom; the bridge
        // is per-string physics). EAR-OWNED depths — every band-spectrum
        // objective prefers 0 (2026-07-12 law); adopted at raga .4/chrom .2
        // /lp 6k ("row+buzz mid" verdict). Applied to the radiated copy
        // only — zero stability impact.
        d("N_jaw_raga",    0.0,  1.2,  0.0,  .bank,   "Jawari (raga)",     true),
        d("N_jaw_chrom",   0.0,  0.8,  0.0,  .bank,   "Jawari (chrom)",    true),
        d("N_jaw_lp",      0.0, 12000.0, 6000.0, .bank, "Jawari LP (Hz)",  true),
        // v57 direct taraf-velocity radiation tap (coupled._dir_lp twin):
        // the ringing-comb persistence the junction's W cannot radiate.
        // Preset-carried — NEVER sarangi_coupled.json (the bow tables read
        // that artifact's N_taraf_dir; the bow must not inherit this pick).
        d("N_taraf_dir",   0.0,  0.12, 0.0,  .bank,   "Taraf direct tap",  true),
        d("N_taraf_dir_lp", 0.0, 4000.0, 900.0, .bank, "Tap low-pass (Hz)", true),
        // D : the sustained low drone (≈ tonic/4). v57/Pilu ships mix 0
        // (session ground truth: no drone); the block stays playable live.
        d("mix_drone",     0.0,  1.0,  0.0,  .drone,  "Drone",             false),
        d("D_t60",         0.5,  6.0,  2.0,  .drone,  "Drone decay s",     true),
        d("D_level",       0.0,  1.0,  0.36, .drone,  "Drone level",       true),
        d("D_nharm",       1.0,  4.0,  3.0,  .drone,  "Drone harmonics",   true),
        d("D_floor",       0.0,  1.0,  0.6,  .drone,  "Drone floor",       true),
        // Playback gain at the output mix only (never changes how hard the
        // strings are driven).
        d("main_gain",     0.0,  6.0,  1.0,  .mix,    "Main gain",         false),
        // E_lp: the body's radiation low-pass (the skin's efficiency rolloff)
        d("E_lp",       6000.0, 19000.0, 16000.0, .body, "Body low-pass (Hz)", true),
        // F : room. The v57 ear-law is NO REVERB (the ringing taraf is the
        // room) — preset ships F_mix 0; the slider stays for taste.
        d("F_rt60",        0.5,  2.0,  1.2,  .reverb, "Room RT60 (s)",     true),
        d("F_mix",         0.0,  0.6,  0.0,  .reverb, "Room mix",          false),
        d("F_predelay",    8.0, 40.0, 20.0,  .reverb, "Pre-delay (ms)",    true),
    ]

    public static let byName: [String: ParamDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func grouped(_ g: ParamGroup) -> [ParamDescriptor] { all.filter { $0.group == g } }

    private static func d(_ id: String, _ lo: Double, _ hi: Double, _ def: Double,
                          _ group: ParamGroup, _ label: String, _ structural: Bool) -> ParamDescriptor {
        ParamDescriptor(id: id, lo: lo, hi: hi, default: def, group: group, label: label, structural: structural)
    }
}
