import Foundation

/// Which block a parameter belongs to (drives the grouped sliders in the UI).
public enum ParamGroup: String, CaseIterable, Sendable, Codable {
    case bank = "Bank"        // B
    case jawari = "Jawari"    // C
    case drone = "Drone"      // D
    case body = "Body"        // E
    case reverb = "Reverb"    // F
    case mix = "Mix"
}

/// One tweakable model parameter — a 1:1 port of `fit.py` PARAM_SPEC plus a
/// human label, group, default (from `chain.default_params`), and the crucial
/// **structural** flag: structural params redesign filter coefficients (need an
/// off-thread snapshot rebuild), non-structural ones are live gains/mixes the
/// render thread reads as plain atomics.
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
    /// (name, lo, hi, default, group, label, structural). Ranges verbatim from
    /// fit.py PARAM_SPEC; defaults from chain.default_params().
    public static let all: [ParamDescriptor] = [
        d("B_gain",        0.0,  1.2,  0.4,  .bank,   "Bank gain",         false),
        d("B_t60_scale",   0.5,  2.8,  1.0,  .bank,   "Decay × (t60)",     true),
        d("B_bright",      0.0,  1.5,  0.8,  .bank,   "Bright choir",      false),
        // Gut-string HF roll-off on the comb strings (chain.process: clean choir
        // = 0.6·B_lp, bright/raga choir = B_lp). Structural — rebakes the combs.
        d("B_lp",          0.1,  1.0,  0.4,  .bank,   "String brightness", true),
        // Responsiveness: how much the sympathetic bank tracks the bow
        // envelope (`amp`). 0 = free ring (the bank decays on its own long
        // t60, which on a staccato rings ~3× longer than the note → a
        // perceived late "second peak"); 1 = the bank fades WITH the bow.
        // Not a fitted param (the offline `chain.process` ignores it).
        d("sym_bow_follow", 0.0, 1.0,  0.7,  .bank,   "Sym ↔ bow follow",  false),
        d("C_pre_hp",   1500.0, 3500.0, 2200.0, .jawari, "Pre HP (Hz)",    true),
        d("C_drive_min",   1.0,  3.0,  1.5,  .jawari, "Drive min",         false),
        d("C_drive_max",   4.0, 20.0, 12.0,  .jawari, "Drive max",         false),
        d("C_asym",        0.0,  0.5,  0.3,  .jawari, "Asymmetry",         false),
        d("C_wet",         0.0,  0.6,  0.25, .jawari, "Buzz wet",          false),
        d("C_rasp",        0.0,  1.0,  0.2,  .jawari, "Rasp",              false),
        d("C_top",         0.0,  0.8,  0.15, .jawari, "Top edge",          false),
        d("C_sweep_lo",    3.0,  7.0,  5.0,  .jawari, "Sweep lo (×f0)",    true),
        d("C_sweep_hi",   10.0, 20.0, 16.0,  .jawari, "Sweep hi (×f0)",    true),
        d("C_to_bank",     0.0,  1.0,  0.3,  .jawari, "Buzz → bright",     false),
        d("mix_dry",       0.5,  1.2,  0.85, .mix,    "Dry (violin)",      false),
        d("mix_bank",      0.0,  1.5,  0.5,  .mix,    "Bank",              false),
        d("mix_jaw",       0.0,  1.5,  1.0,  .mix,    "Jawari",            false),
        // Playback gains for the two voices, applied at the output MIX only
        // (the bank/drone are excited by the raw drive, so `main_gain` never
        // changes how hard the sympathetic strings ring). main = dry + jawari
        // buzz; sym = sympathetic bank + drone. Non-fitted (Starpad-added).
        d("main_gain",     0.0,  6.0,  1.0,  .mix,    "Main voice gain",   false),
        // The sympathetic bank is intrinsically ~30 dB below the bowed voice in
        // the fit, so a big range + high default is needed to bring the shimmer
        // up to an audible halo. 12 ≈ −9 dB under the main; push toward 40 for a
        // dominant tarab.
        d("sym_gain",      0.0, 40.0, 12.0,  .mix,    "Sym voice gain",    false),
        d("E_low_shelf_f", 80.0, 300.0, 160.0, .body, "Low shelf (Hz)",    true),
        d("E_low_shelf_db", -6.0, 12.0, 0.0, .body,   "Low shelf (dB)",    true),
        d("E_body",        0.0,  1.6,  1.0,  .body,   "Body ring",         false),
        // Block F (single combined reverb) was replaced by the per-voice FX rack
        // (`FXRack` on InstrumentState, edited in the FX tab) — the F_* params are
        // gone. The `.reverb` ParamGroup case is retained (empty) for back-compat.
    ]

    public static let byName: [String: ParamDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func grouped(_ g: ParamGroup) -> [ParamDescriptor] { all.filter { $0.group == g } }

    private static func d(_ id: String, _ lo: Double, _ hi: Double, _ def: Double,
                          _ group: ParamGroup, _ label: String, _ structural: Bool) -> ParamDescriptor {
        ParamDescriptor(id: id, lo: lo, hi: hi, default: def, group: group, label: label, structural: structural)
    }
}
