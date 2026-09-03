import Foundation

/// THE PARAMETER REGISTRY — the one source of truth for every parameter
/// of the instrument. Each entry has a key, a group, a native range, a
/// resting value and an **apply strategy**:
///
///  * `.live`    — a runtime setter on the engine; instant, no rebuild.
///  * `.rebuild` — a `bowed_string.json` build scalar; applied as a
///                 persisted override with a debounced off-main rebuild
///                 (most land in place — see `inPlaceKeys`).
///  * `.hybrid`  — a build scalar that ALSO has a live 0…1 scaler in the
///                 kernel (vibrato depth ↔ the aftertouch amount): one
///                 knob in native units, instant at or below the built
///                 value, the build path above it.
///
/// Everything here is editable in the Parameters tab, usable as a
/// composite member, and bindable to a control axis (directly or through
/// a composite).
public enum ParamApply: String, Codable {
    case live, rebuild, hybrid
}

/// WHO a parameter acts on. `.global` = ONE shared mechanism (bridge/body,
/// taraf bank, FX/output chain, shared string physics, a control axis) —
/// changing it moves the whole instrument. `.perNote` = a mechanism with
/// its own state per sounding note (onset clock, settle envelope, vibrato
/// phase, drift walk, blend window); the attack family is CAPTURED at the
/// articulation edge, so an edit changes subsequent onsets only. The line
/// follows per-note CONTROL STATE, not physics plumbing: friction/string
/// values are `.global` even though every string evaluates them.
public enum ParamScope: String, Codable {
    case global, perNote

    public var label: String {
        self == .global ? "global" : "per-note"
    }

    /// One-line row summary (the Parameters tab's per-row description).
    public var summary: String {
        switch self {
        case .global:
            return "one shared mechanism — changing it moves the whole instrument at once"
        case .perNote:
            return "each sounding note evaluates it with its own state; attack-family values are captured at onset, so an edit changes subsequent notes"
        }
    }

    /// Full legend text (the docs/parameters.md scope table).
    public var explanation: String {
        switch self {
        case .global:
            return "ONE shared mechanism — the bridge/body, the taraf bank, the room/FX/output chain, the shared string physics, or a control axis every note rides together. Changing it moves the whole instrument at once."
        case .perNote:
            return "Runs SEPARATELY for each note: every sounding note carries its own state for it (onset clock, settle envelope, vibrato phase, drift walk, strike-blend window), so simultaneous notes are affected independently. The attack family is CAPTURED at the articulation edge — an edit changes subsequent onsets, never a sounding note."
        }
    }
}

/// WHEN a change is heard — the USER-FACING timing truth, derived from
/// the apply strategy + `inPlaceKeys`, with per-spec overrides for keys
/// whose live routing hides a slow re-mount (the tanpura scale-shape
/// family). ONE vocabulary: the Parameters tab's row descriptions and the
/// generated docs/parameters.md legend both render these labels, so the
/// app can never tell a different timing story than the documentation
/// (never derive display timing from `apply` alone).
public enum ParamTiming: String {
    case live
    case inPlace = "in-place"
    case rebuild
    case hybrid

    public var label: String { rawValue }

    /// One-line row summary (the Parameters tab's per-row description).
    public var summary: String {
        switch self {
        case .live:
            return "instant everywhere, including through tilt/strike bindings — the right kind for continuous real-time control"
        case .inPlace:
            return "lands on the running kernel (no rebuild, no lost ring) ~0.2 s after the value settles — the same debounce applies through bindings, so prefer a live parameter for continuous control"
        case .rebuild:
            return "needs a fresh engine: ~0.2 s debounce, then a crossfaded off-main rebuild"
        case .hybrid:
            return "instant at or below the built headroom; above it, the debounced build path"
        }
    }

    /// Full legend text (the docs/parameters.md timing table).
    public var explanation: String {
        switch self {
        case .live:
            return "A dedicated runtime setter — instant everywhere, including through tilt/strike bindings and composites. The right kind for continuous real-time control."
        case .inPlace:
            return "A build scalar whose change lands on the RUNNING kernel (no rebuild, no lost ring) — but it persists as an override and flushes through a ~0.2 s debounce, in the Parameters tab and through bindings alike. Fine for set-and-listen editing; for continuous binding prefer a `live` parameter."
        case .rebuild:
            return "Needs a fresh engine: ~0.2 s debounce, then an off-main rebuild adopted through a crossfade."
        case .hybrid:
            return "Instant at or below the built headroom (a live 0–1 kernel scaler); pushing above the built value takes the debounced build-scalar path (in place when the key allows it — the one shipped hybrid, vibrato depth, does)."
        }
    }
}

public struct ParamSpec: Identifiable {
    public let key: String
    public let label: String
    /// Group heading (the Parameters tab's disclosure sections).
    public let group: String
    public let lo: Double, hi: Double
    /// Authoring default — the artifact value wins when it carries the key
    /// (the fit moves values wherever the physics wants them).
    public let def: Double
    /// Integer-ish parameters (mode count, armed flags).
    public let step: Double?
    public let apply: ParamApply
    /// `.hybrid` only: the resting value as a FRACTION of the build-time
    /// headroom — 1 = the fitted depth, 0 = off.
    public let restFraction: Double?
    /// Global vs per-note — see `ParamScope`.
    public let scope: ParamScope
    /// Explicit timing override for keys whose `.live` ROUTING hides a
    /// slow re-mount (the tanpura scale-shape family); nil = derive from
    /// the apply strategy + `inPlaceKeys` (see `timing`).
    public let timingOverride: ParamTiming?
    public let help: String

    /// The user-facing timing truth — what the Parameters tab rows and
    /// docs/parameters.md both render (never derive display timing from
    /// `apply` alone: most `.rebuild`-strategy keys land in place).
    public var timing: ParamTiming {
        if let t = timingOverride { return t }
        switch apply {
        case .live:   return .live
        case .hybrid: return .hybrid
        case .rebuild:
            return ParamRegistry.inPlaceKeys.contains(key)
                ? .inPlace : .rebuild
        }
    }

    public var id: String { key }

    public init(_ key: String, _ label: String, group: String,
                _ lo: Double, _ hi: Double, _ def: Double,
                step: Double? = nil, apply: ParamApply = .rebuild,
                restFraction: Double? = nil, timing: ParamTiming? = nil,
                scope: ParamScope = .global,
                help: String = "") {
        self.key = key; self.label = label; self.group = group
        self.lo = lo; self.hi = hi; self.def = def; self.step = step
        self.apply = apply; self.restFraction = restFraction
        self.timingOverride = timing
        self.scope = scope; self.help = help
    }

    /// True when the value applies instantly (no engine rebuild) for at
    /// least part of its range.
    public var isLive: Bool { apply != .rebuild }
}

public enum ParamRegistry {

    // MARK: - Groups

    public static let groups: [(name: String, params: [ParamSpec])] = [

        ("Bow stroke", [
            ParamSpec("bow_expr", "expression", group: "Bow stroke",
                      0, 1, 0.251, apply: .live,
                      help: "Loudness of the played stroke: low = fade toward silence, high = push harder. The fitted playing median is ~0.25."),
            ParamSpec("bow_press", "bow pressure", group: "Bow stroke",
                      0, 1, 0.562, apply: .live,
                      help: "Bow force inside the playable wedge — under-pressed flautando/whistle at the low end, pressed grit at the high end."),
            ParamSpec("bow_pos", "bow position (brightness)", group: "Bow stroke",
                      0, 1, 0.45, apply: .live,
                      help: "Where the bow contacts the string: low = sul ponticello (bright/edgy near the bridge), high = sul tasto (soft/round over the fingerboard)."),
            ParamSpec("bow_tilt", "bow tilt", group: "Bow stroke",
                      0, 1, 0.331, apply: .live,
                      help: "Harmonic color of the bow stroke (bow-hair tilt). The default 0.331 is the neutral 0 dB point."),
        ]),

        ("Body (formula modes)", [
            ParamSpec("bow_body_modes", "modes", group: "Body (formula modes)",
                      0, 16, 12, step: 1,
                      help: "Analytic body mode count. 0 = rigid bridge (the bare string, no body colour)."),
            ParamSpec("bow_body_scale", "body size", group: "Body (formula modes)",
                      0.15, 2.5, 1.0,
                      help: "Scales every mode: <1 = smaller body (violin direction), >1 = larger (cello direction). 1 = built for the current tonic."),
            ParamSpec("bow_body_air_ratio", "air mode ratio", group: "Body (formula modes)",
                      0.4, 2.2, 1.4,
                      help: "Lowest (air) resonance as a multiple of the open string. Under 1 (air mode BELOW the tonic) is what charges the taraf."),
            ParamSpec("bow_body_q", "wood Q", group: "Body (formula modes)",
                      5, 60, 25,
                      help: "Mode sharpness: low = damp/soft wood, high = ringy/hard."),
            ParamSpec("bow_body_q_air", "air Q", group: "Body (formula modes)",
                      4, 30, 12,
                      help: "Air-resonance sharpness."),
            ParamSpec("bow_body_y", "mobility depth", group: "Body (formula modes)",
                      0.0, 2.0, 0.35,
                      help: "How much the bridge moves at the modes — note-to-note unevenness, wolf tendency, attack bloom."),
            ParamSpec("bow_body_rad", "modal radiation", group: "Body (formula modes)",
                      0.0, 3.0, 1.0,
                      help: "How loudly the modes radiate (vs the direct term)."),
            ParamSpec("bow_body_c0", "direct radiation", group: "Body (formula modes)",
                      0.0, 1.0, 0.3,
                      help: "Non-modal (flat) radiation floor. 1 with modes 0 = the raw bridge force."),
            ParamSpec("bow_body_tail_n", "formant modes", group: "Body (formula modes)",
                      0, 48, 32, step: 1,
                      help: "Diffuse mid/high mode forest between the tail corners — the FIXED body formants the harmonics sweep through during a glide, the cue that separates a real slide from a pitch-shifted tone. √n-normalized: more modes = denser, individually shallower structure at held total power. 0 = flat feedthrough only."),
            ParamSpec("bow_body_tail_f0", "formants from (Hz)", group: "Body (formula modes)",
                      150, 1500, 280,
                      help: "Low edge of the diffuse formant forest."),
            ParamSpec("bow_body_tail_f1", "formants to (Hz)", group: "Body (formula modes)",
                      2000, 12000, 6500,
                      help: "High edge of the diffuse formant forest."),
            ParamSpec("bow_body_tail_q", "formant Q", group: "Body (formula modes)",
                      5, 60, 30,
                      help: "Formant sharpness: higher = deeper peaks/valleys and slower per-mode bloom (Q 30 at 300 Hz rings ~70 ms — body bloom, physical)."),
            ParamSpec("bow_body_tail_y", "formant mobility", group: "Body (formula modes)",
                      0.0, 1.5, 0.4,
                      help: "Bridge-load side of the formant modes. The default 0.4 leaves the admittance maximum (and the loop cap) unchanged; raising it far invites wolves."),
            ParamSpec("bow_body_tail_rad", "formant radiation", group: "Body (formula modes)",
                      0.0, 8.0, 2.5,
                      help: "How loudly the formant forest radiates against the flat floor. The default 2.5 gives ≈ ±4 dB ripple std across 250–6500 Hz (extremes ~26 dB) — real-body territory; near 0 the transfer is inaudibly flat."),
            ParamSpec("bow_yinf", "bridge give", group: "Body (formula modes)",
                      0.0, 0.4, 0.05,
                      help: "Broadband bridge admittance floor under the modes."),
            ParamSpec("bow_kret", "body return", group: "Body (formula modes)",
                      0.0, 0.5, 0.35,
                      help: "Bridge motion fed back into the string (loop-cap protected). More = livelier, wolfier."),
        ]),

        ("Bow & string", [
            ParamSpec("bow_mu_s", "static friction", group: "Bow & string",
                      0.4, 1.2, 0.8, help: "Rosin stick strength (grip)."),
            ParamSpec("bow_mu_d", "dynamic friction", group: "Bow & string",
                      0.1, 0.6, 0.3,
                      help: "Slip friction. The stick/slip GAP sets the Schelleng ceiling."),
            ParamSpec("bow_v0", "friction corner", group: "Bow & string",
                      0.05, 0.5, 0.2,
                      help: "Friction-curve knee: smaller = sharper corner = brighter attack edge."),
            ParamSpec("bow_Zt", "torsional damping", group: "Bow & string",
                      0.0, 15.0, 7.9,
                      help: "String rotation losses at the bow contact."),
            ParamSpec("bow_gut_g", "gut loss", group: "Bow & string",
                      0.985, 1.0, 0.998,
                      help: "Per-round-trip broadband loss — lower = duller, deader string."),
            ParamSpec("bow_gut_fc2", "gut top (Hz)", group: "Bow & string",
                      500, 12000, 3500,
                      help: "Second termination pole: the gut string's own HF ceiling."),
            ParamSpec("bow_nut_fc", "nut corner (Hz)", group: "Bow & string",
                      1000, 12000, 5500,
                      help: "Nut/finger termination low-pass."),
            ParamSpec("bow_br_fc", "bridge corner (Hz)", group: "Bow & string",
                      1000, 12000, 6750,
                      help: "Bridge termination low-pass."),
            ParamSpec("bow_loss_reg", "register damping", group: "Bow & string",
                      0.0, 1.5, 0.7,
                      help: "Register-tracking string loss: below the tonic the nut/bridge/gut loss corners scale down with pitch — fc × (f0/tonic)^this — so a low note's Helmholtz corner rounds in proportion to its period, keeping the low register warm instead of brassy, and glides darken smoothly on the way down. At and above the tonic the corners are untouched. 0 = fixed corners; 0.7 (default) = moderate warmth; 1 = full period-proportional tracking."),
            ParamSpec("bow_twang", "sitar twang", group: "Bow & string",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Grazing jawari wrap on the PLAYED strings' bridge — the sitar's flat-bridge contact on the melody string (the taraf's bones are separate). 0 = the plain bridge, bit-exact. Rising: while an excursion tip presses the bone the speaking length shortens a hair (an energy-conserving per-cycle phase modulation that pumps the harmonic cascade) and the terminations morph toward sitar hardware (brighter bridge/nut, eased release damping), so a staccato note keeps a sustained buzzy 2.5–6 kHz cluster through its ring. ~0.75 is a classic sitar buzz; the last quarter opens the wrap and brightness further for a hotter, more present buzz. The graze knee rides each string's own envelope, so the twang engages at any strike level, and pitch-lock terms hold the twanged ring on the plain ring's pitch (±5 ¢ at the extremes). Applies live, slewed in-kernel."),
            ParamSpec("bow_noise", "contact noise", group: "Bow & string",
                      0.0, 0.4, 0.1,
                      help: "Hair-scatter noise recirculated into the friction loop."),
            ParamSpec("bow_noise_dir", "direct noise", group: "Bow & string",
                      0.0, 0.4, 0.12,
                      help: "Contact noise radiated directly (inter-harmonic air)."),
            ParamSpec("bow_tors_c", "torsion coupling", group: "Bow & string",
                      0.0, 0.5, 0.0,
                      help: "Slip → torsional wave → returned micro-slips: period-locked harmonic HF regeneration at the source. 0 = off."),
            ParamSpec("bow_tors_g", "torsion return", group: "Bow & string",
                      0.5, 0.98, 0.85,
                      help: "Torsional loop reflection/loss (higher = stronger ripple)."),
            ParamSpec("bow_tors_ratio", "torsion speed ×", group: "Bow & string",
                      3.5, 8.0, 5.2,
                      help: "Torsional/transverse wave-speed ratio (gut ≈ 5)."),
            ParamSpec("bow_age_a", "contact aging", group: "Bow & string",
                      0.0, 0.9, 0.0,
                      help: "Rate-and-state friction: static grip grows with stick time — a freshly-slipped contact is weak, so slips collect at one phase per period (cleaner, more locked slip pattern). 0 = off."),
            ParamSpec("bow_age_ms", "aging time (ms)", group: "Bow & string",
                      0.2, 5.0, 1.5,
                      help: "Contact re-adhesion timescale (fraction of a period = strongest phase discipline)."),
            ParamSpec("bow_cr_w", "contact spread", group: "Bow & string",
                      0.0, 0.5, 0.0,
                      help: "Continuum contact: grip-limit spread across the hair band — partial release near the boundary (adds bow-surface flutter texture; darkens quiet mids). 0 = off."),
            ParamSpec("bow_cr_ms", "release time (ms)", group: "Bow & string",
                      0.0, 0.15, 0.0,
                      help: "Continuum contact: release-front crossing time (release-only; capture snaps). Large values distort the quiet duty cycle. 0 = off."),
        ]),

        ("Playing ranges", [
            ParamSpec("bow_v_lo", "speed floor", group: "Playing ranges",
                      0.02, 0.15, 0.065,
                      help: "Bow velocity at expression 0 (above the lift zone)."),
            ParamSpec("bow_v_hi", "speed ceiling", group: "Playing ranges",
                      0.1, 0.5, 0.23,
                      help: "Bow velocity at full expression."),
            ParamSpec("bow_live_beta_lo", "pos: bridge end", group: "Playing ranges",
                      0.02, 0.1, 0.05, help: "β at pos 0 — sul ponticello limit."),
            ParamSpec("bow_live_beta_hi", "pos: tasto end", group: "Playing ranges",
                      0.12, 0.33, 0.24, help: "β at pos 1 — sul tasto limit."),
            ParamSpec("bow_live_press_under", "press-0 undershoot", group: "Playing ranges",
                      0.2, 1.0, 0.55,
                      help: "Press 0 dips to this ×fmin — the flautando/whistle edge."),
            ParamSpec("bow_live_press_over", "press-1 overshoot", group: "Playing ranges",
                      1.0, 1.8, 1.25,
                      help: "Press 1 pushes to this ×fmax — the grit edge."),
            ParamSpec("bow_expr_lift", "lift zone", group: "Playing ranges",
                      0.0, 0.4, 0.2,
                      help: "Expression below this fades the bow off the string entirely."),
            ParamSpec("bow_f_cap", "force cap", group: "Playing ranges",
                      1.0, 8.0, 4.0,
                      help: "Hard force guard over every push (tilt/register)."),
        ]),

        ("Jawari taraf (modal contact)", [
            ParamSpec("bow_jt_gain", "level", group: "Jawari taraf (modal contact)",
                      0.0, 3.0, 0.3,
                      help: "Output mix of the jawari web (the raga bridge's rows). Slewed ~40 ms inside the kernel, so a bound sweep never clicks."),
            ParamSpec("bow_jt_drive", "drive", group: "Jawari taraf (modal contact)",
                      0.001, 0.3, 0.03,
                      help: "Bridge-force coupling INTO the strings — sets the graze operating point: too low = no cascade, too high = over-drained/linearized."),
            ParamSpec("bow_jt_apex", "graze depth", group: "Jawari taraf (modal contact)",
                      2e-6, 5e-5, 1e-5,
                      help: "Bone protrusion of the raga bridge. The evolution lives at the grazing knee — pressed deep it linearizes (sparkle only), too shallow it never engages. This group is the raga set's bridge plus the web-wide taraf controls; the chromatic set has its own bridge group below."),
            ParamSpec("bow_jt_zone", "contact zone (m)", group: "Jawari taraf (modal contact)",
                      0.002, 0.02, 0.006,
                      help: "Length of the bone the string can touch, in metres — the flat of the jawari. The default 6 mm concentrates the contact grid on the active region; wider = a flatter, more open jawari whose wrap spreads along the bone (longer, more diffuse buzz), narrower = a sharper knee."),
            ParamSpec("bow_jt_radius", "bone radius (m)", group: "Jawari taraf (modal contact)",
                      0.05, 2.0, 0.3,
                      help: "Curvature radius of the bone's parabola, in metres. Small = a rounded bridge (the wrap point stays put, a cleaner ring); large = a nearly flat bone (the string rolls along it as it swings — the wide open sitar/tanpura-style jawari)."),
            ParamSpec("bow_jt_evolve", "evolution", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.5, apply: .live,
                      help: "Harmonic-evolution rate — the tanpura/sitar twang axis: a signed bone offset spanning graze margin ×4 … ×¼ around the fitted bone, slewed inside the kernel (~40 ms) so the bone glides — tilt-sweepable without a strum. 1 = the ring always sits in the grazing band: energy cascades up the partials fast (centroid rise ~0.3 s) at any level, and the taraf rings a few dB hotter (trim with level). 0 = the string is pressed past the knee: harmonics stay put, no twang. 0.5 = the fitted geometry, bit-exact. Applies live."),
            ParamSpec("bow_jt_ev_reg", "evolution register", group: "Jawari taraf (modal contact)",
                      -1.0, 1.0, 0.0, apply: .live,
                      help: "Register tilt of the evolution axis, in evolve units per octave from the tonic — each row's bone evaluates the margin map at its own shifted evolve (kernel-slewed ~40 ms). Positive opens the below-tonic rows toward the grazing band while pressing the above-tonic web closed, so the long-ringing Sa/Pa anchor rows bloom for their whole ring without the whole web buzzing; negative reverses it (highs shimmer, lows stay put). 0 = the uniform bone, bit-exact. Relative to wherever the evolution knob sits. Applies live."),
            ParamSpec("bow_jt_alpha", "contact law", group: "Jawari taraf (modal contact)",
                      1.0, 2.0, 1.5,
                      help: "Contact stiffness exponent. 1.5 = Hertz (the fast sqrt path); the fitted instrument runs 1.3, and other values cost more CPU."),
            ParamSpec("bow_jt_norm", "level norm", group: "Jawari taraf (modal contact)",
                      0.0, 1.5, 1.0,
                      help: "Per-string t60-response normalization — evens the driven level across scale degrees (long-ring rows charge hotter); 0 = raw physics."),
            ParamSpec("bow_jt_hcb", "contact damping", group: "Jawari taraf (modal contact)",
                      1.0, 40.0, 8.0,
                      help: "Hysteretic damping of the string–bone contact. More = softer buzz transients (rounder force pulses, less clang). Default 8."),
            ParamSpec("bow_jt_fhf", "damping corner (Hz)", group: "Jawari taraf (modal contact)",
                      800.0, 12000.0, 4000.0,
                      help: "Corner of the per-mode f² damping law — above it, partials die progressively faster. Lower = warmer (the top decays in tens of ms while fundamentals sustain). Default 4000 Hz."),
            ParamSpec("bow_jt_bst", "inharmonicity", group: "Jawari taraf (modal contact)",
                      0.0, 1.0e-3, 2.0e-4,
                      help: "Stiffness stretch of the upper partials (steel-wire dispersion). Lower = a more harmonic, less bell-metallic top; the default 2e-4 puts mode 40 ~15% sharp."),
            // Live taraf axes.
            ParamSpec("bow_jt_lp", "tone LP (Hz)", group: "Jawari taraf (modal contact)",
                      1000.0, 20000.0, 20000.0, apply: .live,
                      help: "One-pole low-pass on the radiated jawari sum only (the played string is untouched). ≥ 20 kHz = bypass, bit-exact. Applies live — the Taraf Purity composite's tone member."),
            ParamSpec("bow_jt_hp", "tone HP (Hz)", group: "Jawari taraf (modal contact)",
                      0.0, 4000.0, 0.0, apply: .live,
                      help: "One-pole high-pass on the radiated jawari sum only — the formant voicing: quiets the taraf's fundamental band so its high-harmonic cluster carries the ring. ~1–2× the tonic leaves the twang untouched and drops the lows ~6 dB/oct below the corner. 0 = bypass, bit-exact. Applies live."),
            ParamSpec("bow_jt_body", "body radiation", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Blend of the radiated jawari sum through the same formula-body radiation bank the played strings radiate through — the coherence lever: at 0 the taraf radiates raw (beside the instrument), at 1 it rings from the instrument's body with the voice's own formants. Shared coefficients (a body edit re-voices both), own filter state. 0 = bypass, bit-exact. Applies live."),
            ParamSpec("bow_jt_gov", "charge governor", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Per-string governor on how much of a phrase the taraf remembers. The long-ring anchor rows (Sa/Pa) accumulate every note and glide, so a note landing after a phrase can ring far hotter than the same note struck cold, and a hot pile-up can cross the contact knee into loud buzz. This sheds bridge drive into any row already ringing above its graze target (its contact-zone envelope, kernel-side), so rows saturate at their single-strike ring instead of piling up. At 1 a resting-level solo strike is untouched bit-exactly and the moderate sympathetic swell through a phrase survives — only the hot pile-up is shed. 0 = raw physics, bit-exact. Held drones are never ducked. Applies live."),
            ParamSpec("bow_jt_damp", "extra damping", group: "Jawari taraf (modal contact)",
                      0, 1, 0.0, apply: .live,
                      help: "Runtime damping of these modal rows: 0 = the natural long ring, 1 = choked within a second. Applies live — this is what the Taraf Decay composite sweeps."),
            // Taraf-bus compressor: dynamics on the radiated jt bus ONLY,
            // at the split-bus merge — the played voice is untouched.
            // Threshold 0 = off = bit-exact.
            ParamSpec("bow_jt_comp_thresh", "comp threshold", group: "Jawari taraf (modal contact)",
                      0.0, 0.3, 0.0, apply: .live,
                      help: "Taraf compressor threshold, in the CALIBRATED output units the master limiter and the iPad volume readout speak (≈ linear dBFS at master gain 1 — it does not move with bow_gain). The stock taraf rides ~0.01–0.1 (−40…−20 dBFS), so ~0.02–0.05 starts holding the ring's swells while single strikes pass. 0 = off, bit-exact. Applies live."),
            ParamSpec("bow_jt_comp_ratio", "comp ratio", group: "Jawari taraf (modal contact)",
                      1.0, 20.0, 4.0, apply: .live,
                      help: "Compression slope above the threshold: 1 = off (unity), 4 = classic leveling, 20 ≈ a taraf limiter — the sympathetic wash sits at a near-constant level however hard the phrase charges it. Applies live."),
            ParamSpec("bow_jt_comp_atk_ms", "comp attack (ms)", group: "Jawari taraf (modal contact)",
                      0.0, 100.0, 5.0, apply: .live,
                      help: "Gain-reduction attack: how much of a strike's first milliseconds passes before the compressor holds the ring. 0 = instant (clamps the transient too); longer keeps the jawari sparkle and compresses only the sustained wash. Applies live."),
            ParamSpec("bow_jt_comp_rel_ms", "comp release (ms)", group: "Jawari taraf (modal contact)",
                      20.0, 1000.0, 150.0, apply: .live,
                      help: "Gain recovery after the taraf level falls back under the threshold. Short pumps audibly on a ringing wash; long ducks the tail after every hot phrase. Applies live."),
            // Voice-relative taraf cap: holds each sympathetic string
            // against the played voice's OWN level, row by row inside the
            // kernel's jt tick. Hardness 0 = off = bit-exact.
            ParamSpec("bow_jt_cap", "voice cap", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "How hard each sympathetic string is held at or below the played voice's own level — the runaway-bloom lever: with high evolve the web can feed itself past the voice, and a fixed-threshold comp can't follow a phrase's dynamics. The ceiling is the voice bus's instant-attack peak envelope decaying ~7 dB/s, times bow_jt_cap_ratio — a string may ring on after a note but never peak above what the voice reached. Applied per string inside the kernel (see bow_jt_cap_bus), so one blooming anchor row is held while the rest of the web stands. 0 = off, bit-exact; 1 = a hard relative limiter; between = a soft proportional lean. A dimensionless ratio law, so it rides bow_gain and expression untouched. Armed hard with the voice silent, drones and the tanpura's taraf charge are held down until the voice first sounds. Applies live."),
            ParamSpec("bow_jt_cap_ratio", "voice cap ratio", group: "Jawari taraf (modal contact)",
                      0.1, 2.0, 1.0, apply: .live,
                      help: "The level each sympathetic string (or, toward `bow_jt_cap_bus` 1, the whole taraf) is allowed relative to the voice's peak, when `bow_jt_cap` is armed: 1 = parity (may match but not exceed the voice), 0.5 = held ~6 dB under, 2 = allowed 6 dB over (a loose leash — still stops the extreme bloom). Per string, the strings sum after the cap, so the whole web can still stand above a single string's ceiling. Applies live."),
            ParamSpec("bow_jt_cap_bus", "voice cap scope", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "What the cap holds against the voice's ceiling: 0 = each sympathetic string on its own (one blooming anchor is held, its neighbours stand, the web may sum above the ceiling); 1 = the whole taraf as one bus (the strings stand, the summed web never peaks above the ceiling — one hot string ducks all of them). Between, both stages share the hardness: each string removes that fraction less of its own overshoot and the sum removes the rest of what remains. Applies live."),
            ParamSpec("bow_jt_sel", "recruitment", group: "Jawari taraf (modal contact)",
                      0, 1, 0.5, apply: .live,
                      help: "Which strings contribute to the taraf — the contribution profile, at held loudness. 0.5 = the fitted natural response: unison rows dominate, octaves a few dB down, fifths faint, unrelated rows only haze. Below it rows lose bridge drive by harmonic distance from the played notes until at 0 only kin rows ring (chords recruit additively). Above it the profile flattens — resonant rows are cut toward the common haze level until at 1 every string contributes equally and the taraf no longer depends on what the voice plays. Loudness holds throughout via the radiated jt gain (incoherent power model); held drones and the melody follower count as fully ringing, and rings already sounding are never ducked. Lattice width/kin exponent are bp scalars (bow_jt_sel_width 30 ¢, bow_jt_sel_kin 0.7). Applies live — the Taraf Purity composite's recruitment member (purity up = kin-only)."),
        ]),

        // TWO BRIDGES: the CHROMATIC sympathetic set (the Strings tab's
        // second table — 15 semitone strings on the fixed JI grid) sits on
        // its own bridge with its own jawari. Every knob here is the
        // chromatic twin of a `bow_jt_*` knob and lands the same way; the
        // web-wide taraf controls (tone, body, gov, damp, comp, cap,
        // recruitment) stay shared above. Defaults MUST equal
        // `BowTables.chromaticBridgeDefaults` — the artifact never carries
        // these keys, so the registry default IS what the engine plays
        // (`TarabSetTests` pins it).
        ("Chromatic bridge (jawari taraf)", [
            ParamSpec("bow_jtc_gain", "level", group: "Chromatic bridge (jawari taraf)",
                      0.0, 3.0, 0.3,
                      help: "Output mix of the chromatic set's rows (the raga set keeps `bow_jt_gain`). Baked into the rows' radiation taps as a ratio against the raga bridge's level, so silencing the raga bridge silences this too — trim with the row gains for finer balance."),
            ParamSpec("bow_jtc_drive", "drive", group: "Chromatic bridge (jawari taraf)",
                      0.001, 0.3, 0.03,
                      help: "Bridge-force coupling INTO the chromatic strings — their graze operating point, independent of the raga bridge's. On the instrument the chromatic set passes through the main bridge, closest to the played strings: a touch more drive than the side bridges is the physical picture."),
            ParamSpec("bow_jtc_apex", "graze depth", group: "Chromatic bridge (jawari taraf)",
                      2e-6, 5e-5, 1e-5,
                      help: "Bone protrusion of the chromatic bridge — its own grazing knee (the deep-substep threshold and the evolution map follow it per row)."),
            ParamSpec("bow_jtc_evolve", "evolution", group: "Chromatic bridge (jawari taraf)",
                      0.0, 1.0, 0.5, apply: .live,
                      help: "The chromatic bridge's harmonic-evolution axis — the twang of the chromatic set alone, the same graze-margin map (×4 … ×¼) on its own bone, kernel-slewed (~40 ms) so it is tilt-sweepable. 0.5 = its fitted geometry. Rides `bow_jt_ev_reg` like the raga rows (the register tilt is web-wide). Applies live."),
            ParamSpec("bow_jtc_zone", "contact zone (m)", group: "Chromatic bridge (jawari taraf)",
                      0.002, 0.02, 0.006,
                      help: "Length of the chromatic bridge's bone the string can touch (the flat of its jawari), in metres — wider = a more open, diffuse buzz."),
            ParamSpec("bow_jtc_radius", "bone radius (m)", group: "Chromatic bridge (jawari taraf)",
                      0.05, 2.0, 0.3,
                      help: "Curvature radius of the chromatic bridge's bone, in metres — large = nearly flat (the wide open jawari), small = rounded."),
            ParamSpec("bow_jtc_alpha", "contact law", group: "Chromatic bridge (jawari taraf)",
                      1.0, 2.0, 1.3,
                      help: "Contact stiffness exponent of the chromatic bridge (per row in the kernel). 1.5 = Hertz (the fast sqrt path); the default 1.3 matches the fitted raga bridge."),
            ParamSpec("bow_jtc_norm", "level norm", group: "Chromatic bridge (jawari taraf)",
                      0.0, 1.5, 0.0,
                      help: "Per-string t60-response normalization for the chromatic rows; 0 = raw physics."),
            ParamSpec("bow_jtc_hcb", "contact damping", group: "Chromatic bridge (jawari taraf)",
                      1.0, 40.0, 8.0,
                      help: "Hysteretic damping of the string–bone contact on the chromatic bridge (per row in the kernel). More = softer buzz transients."),
            ParamSpec("bow_jtc_fhf", "damping corner (Hz)", group: "Chromatic bridge (jawari taraf)",
                      800.0, 12000.0, 4000.0,
                      help: "Corner of the chromatic strings' per-mode f² damping law — LOWER = warmer. Their own string material, independent of the raga set's."),
            ParamSpec("bow_jtc_bst", "inharmonicity", group: "Chromatic bridge (jawari taraf)",
                      0.0, 1.0e-3, 2.0e-4,
                      help: "Stiffness stretch of the chromatic strings' upper partials (steel-wire dispersion); lower = more harmonic top."),
        ]),

        ("Taraf coupling (bridge load)", [
            ParamSpec("bow_cpl_z", "coupling Z", group: "Taraf coupling (bridge load)",
                      0.0, 0.1, 0.0,
                      help: "Two-way sympathetic coupling: each enabled tarab row becomes a silent comb string on the passive bridge junction, so the played strings feel the taraf as a load — a note at a kin pitch drains into the row and the row returns the energy through the body (the bloom a one-way drive can't make). 0 = off, bit-exact. Per-row impedance (follows the row's gain), and the bank multiplies it: total bridge load ≈ rows × value, so a value one row tolerates over-damps a full bank (0.05 on one row blooms; on the default bank it drags held notes ~5 dB). Start near 0.014; ~0.03 is already a strong load. Needs a rebuild."),
            ParamSpec("bow_cpl_t60", "ring scale", group: "Taraf coupling (bridge load)",
                      0.2, 2.0, 1.0,
                      help: "Scale on each row's own t60 for its coupling comb (capped 8 s): how long the bridge holds absorbed energy before it has all returned or dissipated. 1 = the row's tabled decay — the physical default (the comb IS the same string the jt row models)."),
            ParamSpec("bow_cpl_damp", "HF damping", group: "Taraf coupling (bridge load)",
                      0.0, 1.0, 0.019,
                      help: "Frequency-dependent loop damping of the coupling combs — upper partials couple and die faster, matching real string damping. Default 0.019."),
            ParamSpec("bow_cpl_bright", "bandwidth", group: "Taraf coupling (bridge load)",
                      0.0, 1.0, 0.8,
                      help: "Coupling bandwidth: loop low-pass corner 1.4–7.4 kHz; above it the taraf stops exchanging energy with the bridge. Default 0.8 ≈ 6.2 kHz."),
            ParamSpec("bow_cpl_inharm", "inharmonicity", group: "Taraf coupling (bridge load)",
                      0.0, 0.6, 0.1,
                      help: "Stiffness dispersion of the coupling combs (steel-string upper partials run sharp), matching the jt rows' inharmonicity in spirit. Default 0.1."),
        ]),

        ("Articulation", [
            ParamSpec("bow_place_ms", "place (ms)", group: "Articulation",
                      0, 120, 35,
                      scope: .perNote,
                      help: "Bow-set hold before the draw: force on, velocity 0 (static stick). 0 = no hold, instant attack."),
            ParamSpec("bow_draw_ms", "draw (ms)", group: "Articulation",
                      5, 200, 60,
                      scope: .perNote,
                      help: "Velocity rise for a GENTLE (legato) attack — the pre-Helmholtz crunch window."),
            // DEFAULT = ENGINE TRUTH: the artifact carries no
            // bow_draw_min_ms / bow_attack_bite key, so each def MUST equal
            // the engine fallback (draw_min follows bow_draw_ms; bite 0 =
            // off). `ParamUnificationTests` pins the set.
            ParamSpec("bow_draw_min_ms", "sharp draw (ms)", group: "Articulation",
                      3, 60, 60,
                      scope: .perNote,
                      help: "Velocity rise for a maximally SHARP attack: a hard onset draws this fast (accent/martelé). At the default it equals the gentle draw time (no speedup); ~8 ms gives crisp accents."),
            ParamSpec("bow_attack_bite", "attack bite", group: "Articulation",
                      0, 4, 0.0,
                      scope: .perNote,
                      help: "How hard a sharp onset over-forces: the high force under a fast velocity onset drives the friction loop's own upper-harmonic multi-slip burst — the violin-attack consonant. 0 = off (plain place-then-draw); 1–2 with a low threshold gives martelé accents. Sharpness = press above the threshold, or strike velocity when armed."),
            ParamSpec("bow_attack_bite_ms", "bite decay (ms)", group: "Articulation",
                      10, 200, 60,
                      scope: .perNote,
                      help: "How long the onset over-force lasts before settling into the steady note."),
            ParamSpec("bow_attack_thresh", "bite threshold", group: "Articulation",
                      0.0, 1.0, 0.5,
                      scope: .perNote,
                      help: "Press below this = legato (no bite); above it the attack sharpens toward the full bite at press 1. The pads hold press ~0.56, so lowering this sharpens EVERY onset."),
            ParamSpec("bow_attack_fms", "sharp force ramp (ms)", group: "Articulation",
                      2, 60, 15,
                      scope: .perNote,
                      help: "Force rise of a maximally SHARP attack (velocity-leads-force martelé mechanics: the bow moves at once, the force ramps in over this time)."),
            ParamSpec("bow_attack_vel", "velocity sharpness", group: "Articulation",
                      0.0, 1.0, 0.0,
                      scope: .perNote,
                      help: "How much the ONSET STRIKE VELOCITY sharpens the attack: sharpness = max(press law, this × velocity 0…1). Makes articulation per-note — tap hard = martelé bite, place gently = legato draw. Velocity comes from the iPad's accelerometer strike estimate (or MIDI/audition velocity); 0 = off (the press law alone decides)."),
            // HYBRID: the vibrato depth in cents. The kernel scales the
            // built depth by a live 0…1 amount — 0…built ¢ is instant,
            // above it the build scalar moves.
            ParamSpec("bow_vib_cents", "vibrato depth (¢)", group: "Articulation",
                      0, 60, 25, apply: .hybrid, restFraction: 0.0,
                      scope: .perNote,
                      help: "Finger-vibrato peak depth in cents at the vibrato rate. 0 = none (the resting default). Up to the built depth this applies instantly; above it the value re-applies in place after the debounce (no rebuild)."),
            ParamSpec("bow_vib_hz", "vibrato rate (Hz)", group: "Articulation",
                      3, 9, 5.5,
                      scope: .perNote,
                      help: "Vibrato frequency (real players ~5–7 Hz)."),
        ]),

        // THE STRIKE→ACCELERATION BLEND: a control-layer key, not a voice
        // parameter — `AppController.applyParamToVoice` intercepts it and
        // feeds `StrikeBlendWindow` + the JOYCON_STATE relay (the iPad
        // scope's onset fade tracks it).
        ("Strike blend", [
            ParamSpec("ctl_strike_window", "blend window (s)", group: "Strike blend",
                      0.25, 8.0, 2.0, apply: .live,
                      scope: .perNote,
                      help: "How long a note takes to hand the accelerometer measure from its Strike bindings to its Acceleration bindings: at onset the Strike side applies fully, by this many seconds the Acceleration side does — linear in between, per note (a new note never resets a sounding note's window). Also sets the iPad strike scope's onset fade (yellow → violet on the shared magma level ramp)."),
        ]),

        // THE FRET PITCH WARP: a control-layer key — intercepted in
        // `applyParamToVoice` and relayed to the iPad over JOYCON_STATE,
        // where the fret field resolves touch pitch through it. Bindable
        // live (ride a stick between fretless meend and quantized runs).
        ("Fret pad", [
            ParamSpec("ctl_fret_warp", "pitch warp", group: "Fret pad",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "How strongly the frets warp the pitch space around them (the Fret Pad's logistic field reshaping): 0 = linear (pitch moves at a constant rate between frets), 1 = pitch plateaus hard around each fret and jumps quickly through the middle of each gap — a straight slide traces a logistic curve, and fast runs land near-quantized. Applies at every touch onset and move on both surfaces (relayed to the iPad over JOYCON_STATE), so a tilt/stick binding morphs the pad mid-phrase between meend-friendly and run-friendly."),
        ]),

        // THE GLIDE QUEUE: control-layer keys intercepted in
        // `applyParamToVoice` and fed to `AudioEngine.glideQueue` (the
        // `GlideSequencer`). Notes that OVERLAP in time chain into queued
        // glissandi: the later onset never mounts a string, the sounding
        // voice glides to it, shaped by `ctl_fret_warp`. Releases are
        // never deferred. Toggle 0 = off (pure pass-through).
        ("Glide", [
            ParamSpec("ctl_glide_on", "glide enable", group: "Glide",
                      0.0, 1.0, 0.0, apply: .live,
                      scope: .perNote,
                      help: "The glide queue's on/off toggle (≥ 0.5 = on). On: a note played while another is still HELD does not mount a fresh string — it is QUEUED and the sounding voice glides to it; further overlapping notes join the queue and are hit in sequence, and once every chained touch has lifted the next tap is a fresh attack (staccato is untouched — releases are never deferred). A repeat tap at the sounding pitch still re-attacks. 0 = off — every onset is a fresh note."),
            ParamSpec("ctl_glide_rate", "glide rate (st/s)", group: "Glide",
                      2.0, 200.0, 40.0, apply: .live,
                      scope: .perNote,
                      help: "Base speed of a queued glide, in semitones per second, when the note being left has been RELEASED. A 12-semitone glide at 40 st/s takes 0.3 s. Bindable."),
            ParamSpec("ctl_glide_held", "held glide ×", group: "Glide",
                      0.05, 1.0, 0.3, apply: .live,
                      scope: .perNote,
                      help: "Rate multiplier while the note being left is STILL HELD — holding the old note makes the glide slower and more deliberate (expressive meend); lifting it mid-glide snaps back to the full rate. 1 = held and released glide alike."),
            ParamSpec("ctl_glide_catchup", "catch-up ×", group: "Glide",
                      1.0, 16.0, 4.0, apply: .live,
                      scope: .perNote,
                      help: "Rate multiplier while the note being glided TOWARD is not the END of the queue — when the player has already moved on, the trajectory hurries through the intermediate pitches to catch up. 1 = no hurry (every waypoint at the plain rate)."),
            // DEFAULT = SEQUENCER FALLBACK: GlideSequencer.overFrac must
            // equal this def (tests construct the sequencer directly).
            ParamSpec("ctl_glide_over", "overshoot", group: "Glide",
                      0.0, 0.3, 0.08, apply: .live,
                      scope: .perNote,
                      help: "How far a glide's FINAL approach overshoots past the target before settling back, as a fraction of the glide distance (capped at ±50 ¢) — the human player's land-and-correct: a 12-semitone jump at 0.08 lands ~50 ¢ past and eases back on at a gentler rate. Only the run's last note gets the miss (catch-up glides through a queue are already hurrying and hit their waypoints dead-on). 0 = every glide lands exactly."),
        ]),

        // THE CONTROLLER STRUM: control-layer keys intercepted in
        // `applyParamToVoice`. The strum SET lives in the sarangi document
        // (Strings tab, scale-degree references); the Joy-Con L button
        // holds the chord.
        ("Controller", [
            ParamSpec("ctl_strum_expr", "strum expression", group: "Controller",
                      0.0, 1.0, 1.0, apply: .live,
                      help: "Loudness of the controller strum's held chord: a per-note expression scale on the chord's notes only. On the String bow voice it multiplies the bow's expression axis for those strings LIVE — a bound stick swells the ringing chord without touching the melody; on the Tanpura/Sitar mains it scales the pluck level at the onset (a sounded pluck can't swell). 1 = the chord follows the global expression untouched; 0 = the bow lifts to silence. Bound to the Joy-Con stick Y by default (rest = 0.5)."),
            ParamSpec("ctl_strum_thresh", "strum accel trigger", group: "Controller",
                      1.0, 127.0, 127.0, apply: .live,
                      help: "Accelerometer level that TRIGGERS the strum chord — the iPad's strike envelope (the same measurement the Strike dimension reads), on a 0–127 scale. Crossing the threshold strikes the chord exactly as an L press does; the chord releases when the envelope falls back below ~60% of the threshold (unless L is holding it). 127 = off (the default — no accel strum). Lower values let a gentler shake strum."),
        ]),

        // SUSTAIN LIVENESS: the post-onset settle, the slow sustain
        // drift walks and the glide bow-lightening — per-note control
        // state in `BowControlFilter`.
        ("Liveness", [
            ParamSpec("bow_settle_db", "onset settle (dB)", group: "Liveness",
                      0, 12, 7.0,
                      scope: .perNote,
                      help: "How far the bow eases down after a fresh attack: the friction loop alone overshoots ~+7 dB over the sustainable level for ~0.5 s; this trims the stroke onto a natural ~+2 dB settle. Zero through the place+draw window, so the staccato bite is untouched. 0 = off."),
            ParamSpec("bow_settle_ms", "settle decay (ms)", group: "Liveness",
                      30, 500, 130,
                      scope: .perNote,
                      help: "Exponential time constant of the post-onset ease-down (starts where the draw ends)."),
            ParamSpec("bow_settle_sharp", "sharp settle exemption", group: "Liveness",
                      0.0, 1.0, 0.0,
                      scope: .perNote,
                      help: "How much a SHARP attack is exempted from the settle: depth × (1 − this × sharpness). At 1 a full-sharp (martelé) staccato keeps its level while gentle sustains keep the fitted settle balance. 0 = off (every attack settles equally)."),
            ParamSpec("bow_drift_cents", "drift depth (¢)", group: "Liveness",
                      0, 8, 0.55,
                      scope: .perNote,
                      help: "Slow random pitch wander of a held note (bounded random walk, NOT vibrato) — the finger/bow life of a sustain. The body slope turns it into decorrelated per-harmonic shimmer, and the sarangi body is steep (~3 dB/¢ at D4), so a little goes far. 0 = a perfectly steady sustain."),
            ParamSpec("bow_drift_hz", "drift bandwidth (Hz)", group: "Liveness",
                      0.2, 6, 1.2,
                      scope: .perNote,
                      help: "Bandwidth of all three liveness walks (pitch, level, force). Natural sustain motion lives at 0.5–2.5 Hz — well below vibrato rate."),
            ParamSpec("bow_drift_db", "level drift (dB)", group: "Liveness",
                      0, 3, 0.15,
                      scope: .perNote,
                      help: "Direct bow-velocity wander (dB std) on top of what the pitch drift already does to the level."),
            ParamSpec("bow_drift_force_db", "force drift (dB)", group: "Liveness",
                      0, 4, 0.3,
                      scope: .perNote,
                      help: "Bow-force wander (dB std): slow timbre motion — brightness breathes without the level moving much."),
            ParamSpec("bow_glide_dip_db", "glide dip (dB)", group: "Liveness",
                      0, 12, 5.0,
                      scope: .perNote,
                      help: "Glide bow lightening: the bow eases while the pitch is MOVING (full depth on velocity, 0.3× on force) — the 3.5–9 dB dip a player makes through a transition. Only within-note movement (finger glides / meend) triggers it; the dip follows the sounding-pitch slew, so drift and vibrato never do. 0 = off."),
            ParamSpec("bow_glide_dip_rate", "dip half-rate (¢/s)", group: "Liveness",
                      100, 5000, 900,
                      scope: .perNote,
                      help: "Pitch slew at which the glide dip reaches half depth. A fast fret-to-fret finger drag sweeps ~1500 ¢/s; slow meend ~200 ¢/s gets a gentle ~1 dB."),
            ParamSpec("bow_slide_noise", "slide noise", group: "Liveness",
                      0.0, 0.02, 0.008,
                      scope: .perNote,
                      help: "Finger-slide friction noise: filtered per-note noise injected at the finger termination in the kernel — it circulates the string, combs at the sliding pitch and radiates through the body — driven by the CHANGE of the finger's pitch slew, so it scrapes where the finger starts, stops or turns and stays quiet through a constant-rate meend. A 6000 ¢/s² drive floor keeps drift and steady notes bit-exact with it armed. 10 ms attack / 100 ms release, faded with the note's gate. 0 = silent slides."),
            ParamSpec("bow_slide_acc", "noise half-accel (¢/s²)", group: "Liveness",
                      5000, 100000, 25000,
                      scope: .perNote,
                      help: "Finger acceleration at which the slide noise reaches half strength. A smooth 700 ¢ meend over 0.35 s peaks near ~28k ¢/s²; strong vibrato ~25k. Lower = the noise speaks on gentler gestures."),
            ParamSpec("bow_slide_dull", "slide dulling", group: "Liveness",
                      0.0, 0.8, 0.35,
                      scope: .perNote,
                      help: "Moving-finger HF absorption: while the pitch slews, the loop-loss corners (nut/bridge/gut) scale down by up to this fraction — a finger in motion presses lighter and damps more top than a firmly stopped one, so the tone dulls slightly through the slide and blooms back on arrival. Composes with the register damping law; drift never triggers it (80 ¢/s slew floor), strong finger vibrato does. 0 = static terminations."),
            ParamSpec("bow_slide_rate", "slide half-rate (¢/s)", group: "Liveness",
                      100, 4000, 900,
                      scope: .perNote,
                      help: "Pitch slew at which the slide dulling reaches half strength (80 ¢/s drive floor)."),
        ]),

        ("Radiation & output", [
            ParamSpec("bow_rad_hp", "radiation HP (Hz)", group: "Radiation & output",
                      50, 600, 200,
                      help: "A finite radiator can't radiate below its size — butter-2 high-pass corner."),
            ParamSpec("bow_rad_lp", "radiation LP (Hz)", group: "Radiation & output",
                      500, 16000, 8000,
                      help: "Air/skin HF absorption — one-pole corner."),
            ParamSpec("bow_w", "excitation level", group: "Radiation & output",
                      0.2, 2.5, 1.196,
                      help: "Bridge-force weight (pre-radiation drive)."),
            ParamSpec("bow_gain", "master gain", group: "Radiation & output",
                      0.0, 2.0, 1.0, apply: .live,
                      help: "Performance volume of the WHOLE radiated instrument — played voice, taraf ring and room together — on top of the fitted calibration trim. Expression drives the bow (the played string only), so the ringing taraf keeps the total level up; this is the knob that actually moves it. 1 = the calibrated level. INSTANT (a dedicated 25 ms-ramped engine setter — no rebuild, no debounce), so bind it to a tilt or the Strike/Acceleration pair for real-time volume control. The safety limiter still guards the ceiling."),
            ParamSpec("bow_bal", "voice↔taraf balance", group: "Radiation & output",
                      -1.0, 1.0, 0.0, apply: .live,
                      help: "Volume balance between the played VOICE bus and the sympathetic TARAF (jt) bus, at the point where they merge: −1 = voice only, 0 = neutral (the calibrated mix, bit-exact), +1 = taraf only. A pure attenuator pair — the favored side stays at its calibrated level, the other turns down — so no headroom appears and the limiter calibration holds. Slewed ~30 ms; INSTANT like master gain, so bind it to a tilt to lean into the wash mid-phrase. The iPad volume readout tracks it (the meter taps post-balance). Applies live."),
            ParamSpec("bow_live_trim", "output trim", group: "Radiation & output",
                      0.01, 0.5, 0.175,
                      help: "Final calibration level of the fitted instrument — the CALIBRATION half; use master gain for performance volume."),
            ParamSpec("bow_lim_thresh", "limiter ceiling", group: "Radiation & output",
                      0.1, 1.0, 0.8,
                      help: "Output safety limiter: linked-stereo peak ceiling at the very end of the chain (after global FX). Below it samples pass bit-exact; above, instant-attack gain riding with the release below. Guards the coherent kin peaks (hard-struck Sa/Pa: voice + jt ring + coupling return add in phase) and the ±16 dB expression axis. To even the CAUSE, see bow_jt_norm — long-ring anchor rows charge hotter."),
            ParamSpec("bow_lim_rel_ms", "limiter release (ms)", group: "Radiation & output",
                      20.0, 500.0, 150.0,
                      help: "Release time of the output safety limiter's gain recovery. Shorter pumps on sustained hot material; longer ducks the wash noticeably after a peak."),
            ParamSpec("bow_rev_mix", "room mix", group: "Radiation & output",
                      0.0, 0.3, 0.08,
                      help: "Room level. The wet pair is width-decorrelated (see room width); the L+R fold-down stays pan-invariant. 0 = bone dry."),
            ParamSpec("bow_rev_rt60", "room decay (s)", group: "Radiation & output",
                      0.2, 2.0, 1.0, help: "Room reverberation time."),
            ParamSpec("bow_rev_width", "room width", group: "Radiation & output",
                      0.0, 1.0, 0.8,
                      help: "L/R decorrelation of the room tail — a real room's reverberant field differs at the two ears. Cancels in the mono fold-down. 0 = a mono room."),
            ParamSpec("bow_st_width", "instrument width", group: "Radiation & output",
                      0.0, 1.0, 0.2,
                      help: "The width law: the whole instrument — played voice, taraf wash, drones, bow noise — heard from TWO observation points. A dense diffuse-field difference bank above the Schroeder crossover, so lows stay identical in L and R (one centred instrument) while the upper spectrum decorrelates the way a real instrument's does between two ears. At the 0.2 default: melody interaural coherence ~0.9 at 4–8 kHz, the bare wash ~0.3–0.4, balance within ±0.8 dB. Not a pan — zero net lean by construction; cancels in the mono fold-down. 0 = point radiator (mono-in-place)."),
            ParamSpec("bow_st_spread", "taraf pan spread (legacy)", group: "Radiation & output",
                      0.0, 1.0, 0.0,
                      help: "Fixed per-row staging of the jawari rows around the tonic (spread·sin(2π·pitch class)) — an alternative placement to the instrument-width law, for A/B against bow_st_width. 0 = off (default). Mono fold-down invariant."),
            ParamSpec("bow_st_played", "bow-noise pan spread (legacy)", group: "Radiation & output",
                      0.0, 0.5, 0.0,
                      help: "Per-voice placement of the bow noise (the played string's position on the bridge) — for A/B against bow_st_width. 0 = off (default). Mono fold-down invariant."),
            ParamSpec("bow_tone_tilt", "tone tilt (bass–treble)", group: "Radiation & output",
                      -1, 1, 0.0, apply: .live,
                      help: "Overall spectral tilt: −1 = bass-biased, 0 = flat, +1 = treble-biased. A complementary shelf pair on the whole voice before the room. Applies live — the Tone Tilt composite sweeps this."),
        ]),
        ("Tanpura", [
            ParamSpec("tp_gain", "output gain", group: "Tanpura",
                      0.0, 0.1, 0.02, apply: .live,
                      help: "The tanpura voice's output trim, applied after its fitted body EQ and before its calibration room. The 0.02 default IS the artifact's fitted trim (tanpura_live.json `gain`) — keep the two in step when the artifact regenerates."),
            ParamSpec("tp_drone_level", "drone pluck level", group: "Tanpura",
                      0.0, 2.0, 1.0, apply: .live,
                      help: "Scales the drone buttons' tanpura pluck displacement (1 = the role's fitted pluck at velocity 100). Only the tanpura drone voice reads it; the sympathetic-swell drone voice keeps its own bow_drone_* calibration."),
            ParamSpec("tp_drone_cycle", "drone re-pluck period (s)", group: "Tanpura",
                      0.0, 8.0, 2.5, apply: .live,
                      help: "While a drone button stays held, the tanpura re-plucks its string every this many seconds — the strumming hand. Below 0.1 s the cycle is off (a press is then a single pluck; the string still rings for its full t60 either way). Applies live, mid-hold."),
            ParamSpec("tp_pluck_level", "played pluck level", group: "Tanpura",
                      0.0, 2.0, 1.0, apply: .live,
                      help: "Scales the fret-note tanpura plucks when the tanpura is the MAIN instrument (velocity still shapes each pluck on top). Inert while the String voice is the played instrument."),
            ParamSpec("tp_rel_t60", "note-off release t60 (s)", group: "Tanpura",
                      0.05, 3.0, 0.4, apply: .live,
                      scope: .perNote,
                      help: "Main-instrument note-off decay: a HELD fret note rings at the string's natural rate, a released one decays to −60 dB in this many seconds — a finger stop, not a hard damp (the jawari buzz cuts at note-off, the pitch rings down). Drone-button strings never read it (release = ring out, their nature)."),
            ParamSpec("tp_pluck_touch", "pluck isolation", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "How isolated each pluck is from the string's ringing past. At 0 (the physical default) a pluck lands ON TOP of whatever is still ringing — pluck-to-pluck phase alignment then decides the level and buzz (dense re-plucking builds up several dB and swings the buzz), the tanpura's untamed side. Above 0 every pluck is a SEPARATE STRING: the ringing string moves to the history bank (full jawari simulation at its own pitch, its ring scaled by this value — 1 = it rings on in full) and the new pluck starts from settled state, so attacks are always consistent. tp_poly sets how many history strings stay alive; same-pitch strings still sum in the air, and their slowly drifting phases beat like a jodi pair — the physics of two real strings. A note-off-released string never resurrects. Applies to drone and main-instrument plucks, live, at the next pluck."),
            ParamSpec("tp_poly", "history string bank", group: "Tanpura",
                      0.0, 16.0, 6.0, apply: .live,
                      help: "The size of the tanpura's history bank: how many previous plucks keep ringing as REAL strings (full jawari simulation each — their cascades keep developing) before the oldest is retired to a cheap linear ring-out (natural decay, no further jawari re-pumping) and, below audibility, culled. Each live history string costs about one string's worth of CPU; raise it for dense strumming on a strong machine, lower it if the overload watchdog complains. 0 = no history strings at all: the previous ring goes straight to the linear ring-out with its low partials restarted by the new pluck (the most consistent-volume, least-CPU mode). Only read when pluck isolation (tp_pluck_touch) is above 0. Applies live."),
            ParamSpec("tp_pluck_drive", "pluck contact drive", group: "Tanpura",
                      0.25, 4.0, 1.0, apply: .live,
                      help: "The mellow↔buzzy axis at constant loudness: how hard the pluck drives the string into the jawari bone, decoupled from the note's level (the pluck displacement scales by this and the string's output trim by its inverse, together, at the pluck). The jawari contact is a power law, so engagement depth IS the buzz conversion — below 1 the same note rings cleaner and darker, above 1 it buzzes brighter and the cascade develops faster. 1 = the calibrated instrument (bit-exact). Applies live, at the next pluck (drone and main-instrument)."),
            ParamSpec("tp_taraf", "sympathetic taraf drive", group: "Tanpura",
                      0.0, 8.0, 4.0, apply: .live,
                      help: "How strongly the tanpura's output drives the sarangi taraf (the modal-jawari web — the Strings tab's rows), as though the tanpura were strung into the bowed instrument: drone-button plucks (and main-instrument tanpura notes) charge the web sympathetically and it rings back through the String voice's body. Same inject ring as the sitar's st_taraf, at its own level (kernel drive, shaped by the voice→taraf FX insert like any drive). 0 = no coupling (byte-exact String-voice parity). The web only rings while the String voice is armed — it always is."),
            ParamSpec("tp_jiva_comp", "register jawari calibration", group: "Tanpura",
                      0.0, 1.0, 1.0, apply: .live,
                      timing: .rebuild,
                      help: "Per-pitch jiva (jawari thread) calibration. The fitted thread geometry gives the low register its sustained graze — the slow, laddered harmonic cascade; higher strings extrapolate that geometry, fall off the bone and ring clean/dark, and no pluck level restores the regime. This retargets each string's thread height the way a player adjusts the cotton thread per string: at 1 every pitch keeps low Sa's buzziness and laddered cascade (pitch cost under a cent); at 0 the fitted geometry is untouched. Edits schedule a debounced full tanpura rebuild (seconds of CPU), like the scale-shape family."),
            ParamSpec("tp_cascade", "register cascade slowing", group: "Tanpura",
                      0.0, 1.0, 1.0, apply: .live,
                      timing: .rebuild,
                      help: "Slows the higher strings' harmonic cascade toward low Sa's unhurried pace. Even register-calibrated, higher pitches develop their overtone ladder faster in real time (the jawari converts on every graze pass, and passes come at the string's frequency). This raises each higher string's jiva thread a touch further toward the fitted height (a gentler graze — the instant harmonic jump becomes a ~1 s bloom) and lets its upper partials ring longer to keep the buzz level, both graded by pitch and zero at and below the 104 Hz anchor. At 1 the octave-up ladder matches low Sa's character; at 0 only the base calibration applies. Edits schedule the debounced full tanpura rebuild, like tp_jiva_comp."),
            ParamSpec("tp_shape_align", "scale-shape: overtone retune", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      timing: .rebuild,
                      help: "Scale-shaped overtones — the altered tanpura: retunes each partial (modes 3+; 1–2 pin the pitch) toward the nearest scale pitch class, by this fraction of the distance. Full pull inside an 80 ¢ capture window, tapering to nothing by 160 ¢ — so harmonic 5 lands on komal ga (~71 ¢) and harmonic 7 on n, while partials in a pentatonic gap stay harmonic. 0 = the physical string. Applies through a DEBOUNCED full tanpura rebuild (~seconds, 750 ms after the drag settles) — not instant."),
            ParamSpec("tp_shape_focus", "scale-shape: sustain focus", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      timing: .rebuild,
                      help: "Tilts sustain toward scale-aligned partials: each mode's t60 is scaled by its post-retune proximity to the scale (a 30 ¢ gaussian kernel — aligned = full ring, a 71 ¢-off partial at focus 1 keeps ~6% of its t60, floored at 5% — thinned, never killed). Because the jawari keeps re-pumping every mode, the cascade EVOLVES toward the scale over the note's life rather than being statically EQ'd. Debounced rebuild like tp_shape_align."),
            ParamSpec("tp_shape_quiet", "scale-shape: misaligned quiet", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      timing: .rebuild,
                      help: "Turns down the RADIATED level of partials that don't align with the scale (post-retune, same 30 ¢ proximity kernel as tp_shape_focus): each mode's output projection is scaled toward silence — at 1 an off-scale partial is inaudible. Unlike tp_shape_focus this changes NO dynamics: the mode still rings at full energy and keeps trading energy through the jawari contact, it is simply heard less — a per-partial fader, where focus is a per-partial damper. Debounced rebuild like tp_shape_align."),
            ParamSpec("tp_shape_spread", "scale-shape: retune spread", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      timing: .rebuild,
                      help: "Decorrelates the retune per string: a deterministic per-string/per-mode jitter scales the pull fraction (0 = every string corrected identically — shared partials lock to exact 0-beat, which can go organ-static; 1 = pulls vary 0–100%, restoring slow shimmer between strings). Inert unless tp_shape_align > 0. Debounced rebuild like tp_shape_align."),
        ]),
        ("Sitar", [
            ParamSpec("st_gain", "output gain", group: "Sitar",
                      0.0, 0.1, 0.015186, apply: .live,
                      help: "The sitar voice's output trim, applied before its calibration room (the body weighting is baked per mode — the scale-model radiation law). The 0.015186 default IS the artifact's fitted trim (sitar_live.json `gain`, calibrated so a velocity-100 sitar pluck peaks like a tanpura drone pluck) — keep the two in step when the artifact regenerates."),
            ParamSpec("st_pluck_level", "played pluck level", group: "Sitar",
                      0.0, 2.0, 1.0, apply: .live,
                      help: "Scales the fret-note sitar plucks when the sitar is the MAIN instrument (velocity still shapes each pluck on top). Inert otherwise."),
            ParamSpec("st_rel_t60", "note-off release t60 (s)", group: "Sitar",
                      0.05, 3.0, 0.15, apply: .live,
                      scope: .perNote,
                      help: "Note-off decay: a HELD fret note rings at the string's natural rate, a released one decays to −60 dB in this many seconds — a finger lift off the fret. Shorter than the tanpura's default: sitar lines articulate."),
            ParamSpec("st_pluck_touch", "pluck isolation", group: "Sitar",
                      0.0, 1.0, 1.0, apply: .live,
                      help: "Same axis as tp_pluck_touch (0 = each pluck rides the ringing past; above 0 the old ring moves to a history string and the new pluck starts settled). Defaults to 1 for the sitar: fret runs re-pluck at NEW pitches, and isolation keeps the previous note's tail at its own pitch instead of retuning history with the glide."),
            ParamSpec("st_poly", "history string bank", group: "Sitar",
                      0.0, 16.0, 4.0, apply: .live,
                      help: "How many previous sitar plucks keep ringing as REAL strings (full jawari simulation each) before the oldest retires to the cheap linear ring-out. Same machinery as tp_poly; only read when st_pluck_touch is above 0."),
            ParamSpec("st_pluck_drive", "pluck contact drive", group: "Sitar",
                      0.25, 4.0, 1.0, apply: .live,
                      help: "The mellow↔buzzy axis at constant loudness — how hard the pluck drives the string into the jawari bridge, decoupled from level (same mechanism as tp_pluck_drive). 1 = the fitted sitar (bit-exact). Applies at the next pluck."),
            ParamSpec("st_taraf", "sympathetic taraf drive", group: "Sitar",
                      0.0, 8.0, 4.0, apply: .live,
                      help: "How strongly the sitar's output drives the sarangi taraf (the modal-jawari web — the Strings tab's rows ARE the sitar's sympathetic strings). The rendered sitar signal feeds the web's bridge drive alongside the String voice's own (kernel inject ring, shaped by the voice→taraf FX insert like any drive). 0 = no halo (byte-exact String-voice parity). The web only rings while the String voice is armed — it always is."),
        ]),
        fxGroup("FX — voice → taraf", "fx_drive_",
                "the main voice AS THE SYMPATHETIC STRINGS HEAR IT (the recorded taraf-drive signal, mono, kernel rate). Shapes only what excites the taraf; the radiated voice is untouched"),
        fxGroup("FX — voice", "fx_voice_",
                "the main voice bus (bridge radiation + bow noise) after the taraf tap, before the shared radiation chain"),
        fxGroup("FX — taraf", "fx_taraf_",
                "the sympathetic web's own radiated output (drones included), before the shared radiation chain"),
        fxGroup("FX — global", "fx_global_",
                "the final stereo output, after the whole fitted post-chain (radiation, tone tilt, calibration room, level)"),
    ]

    /// One FX insert point's parameter block: a 10-band graphic EQ and a
    /// selectable additive reverb, all `.live` (they never touch the
    /// physics tables) and all off by default — the untouched rack is
    /// byte-null. `prefix` matches `SarangiKit.FXPoint.keyPrefix`; the
    /// suffixes are what `FXSettings.apply(field:value:)` parses.
    private static func fxGroup(_ name: String, _ prefix: String,
                                _ what: String)
        -> (name: String, params: [ParamSpec]) {
        var p: [ParamSpec] = [
            ParamSpec("\(prefix)eq_on", "EQ on", group: name,
                      0, 1, 0, step: 1, apply: .live,
                      help: "Enable the 10-band graphic EQ at this point — \(what). Toggling glides the bands to/from flat (click-free)."),
        ]
        let bands = ["31.5 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz",
                     "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]
        for (i, b) in bands.enumerated() {
            p.append(ParamSpec("\(prefix)eq_b\(i + 1)", "EQ \(b) (dB)",
                               group: name, -12, 12, 0, apply: .live,
                               help: "Octave peaking band at \(b), ±12 dB. Inert while the point's EQ is off."))
        }
        p += [
            ParamSpec("\(prefix)rev_on", "reverb on", group: name,
                      0, 1, 0, step: 1, apply: .live,
                      help: "Enable the reverb at this point — \(what). Toggling glides the wet level (click-free)."),
            ParamSpec("\(prefix)rev_type", "reverb type", group: name,
                      0, 1, 0, step: 1, apply: .live,
                      help: "0 = Bigverb (sndkit/Costello reverbsc: 8 jittered feedback delay lines — a wide modulated hall, the default), 1 = Room (the Freeverb-style tank, tighter and energy-matched to the dry level)."),
            ParamSpec("\(prefix)rev_mix", "reverb mix", group: name,
                      0, 1, 0.3, apply: .live,
                      help: "Wet level 0…1. The dry path always passes at unity (a send, not a crossfade). Inert while the point's reverb is off."),
            ParamSpec("\(prefix)rev_size", "reverb size", group: name,
                      0, 1, 0.93, apply: .live,
                      help: "Decay: Bigverb feedback directly (0.93 = the reference default); the Room maps it onto RT60 0.25 s → 8 s."),
            ParamSpec("\(prefix)rev_cut", "reverb cutoff (Hz)", group: name,
                      500, 20000, 10000, apply: .live,
                      help: "Tail damping low-pass: inside Bigverb's feedback loop (the tail darkens as it recirculates) / the Room's band-limit."),
        ]
        return (name, p)
    }

    // MARK: - Lookup

    public static let all: [ParamSpec] = groups.flatMap(\.params)

    private static let byKey: [String: ParamSpec] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func spec(_ key: String) -> ParamSpec? { byKey[key] }

    /// Keys whose value applies without an engine rebuild (`.live` plus the
    /// downward range of every `.hybrid`).
    public static let liveKeys: Set<String> =
        Set(all.filter(\.isLive).map(\.key))

    /// Keys that carry a resting value OUTSIDE the `bowed_string.json`
    /// override dict — the `.live` and `.hybrid` parameters, whose values
    /// the Mac persists itself (`AppController.paramValues`).
    public static let storedKeys: [ParamSpec] = all.filter { $0.apply != .rebuild }

    /// IN-PLACE PARAMETERS: keys whose change needs no fresh engine —
    /// `BowEngine.setLiveParams` pushes them onto the RUNNING kernel, so
    /// they apply with no lost ring. Verified empirically by
    /// `ParamLivenessTests` (perturb the key, rebuild the tables, see what
    /// moved):
    ///
    ///  * **kernel scalars** — land in the per-sample scalar vector, which
    ///    `bow_[poly_]set_scalars` overwrites in place.
    ///  * **mapping constants** — never reach the tables; read by
    ///    `BowControlFilter` or the output/room/radiation stage.
    ///  * **coefficient arrays reloaded in place** — the body modal bank
    ///    and the jawari tables (histories/wrap kept, so click-free).
    ///
    /// NOT included: anything that RESIZES an array (`bow_body_modes`).
    /// See docs/sound-design.md.
    public static let inPlaceKeys: Set<String> = [
        // --- kernel scalars ---
        "bow_Zt", "bow_age_a", "bow_age_ms", "bow_body_c0", "bow_br_fc",
        "bow_cr_ms", "bow_cr_w", "bow_gut_fc2", "bow_gut_g", "bow_loss_reg",
        "bow_mu_d",
        "bow_mu_s", "bow_noise", "bow_noise_dir", "bow_nut_fc",
        "bow_tors_c", "bow_tors_g",
        "bow_tors_ratio", "bow_v0", "bow_w", "bow_yinf",
        // `bow_kret` is a kernel scalar too (the loop-gain cap can swallow
        // a small nudge, so the probe files it under "no tables").
        "bow_kret",
        // --- mapping constants (BowControlFilter) ---
        "bow_v_lo", "bow_v_hi", "bow_live_beta_lo", "bow_live_beta_hi",
        "bow_live_press_under", "bow_live_press_over", "bow_expr_lift",
        "bow_f_cap", "bow_place_ms", "bow_draw_ms", "bow_draw_min_ms",
        "bow_settle_db", "bow_settle_ms", "bow_settle_sharp",
        "bow_drift_cents", "bow_drift_hz",
        "bow_drift_db", "bow_drift_force_db", "bow_glide_dip_db",
        "bow_glide_dip_rate",
        // slide dulling + accel-driven noise: kernel scalars
        "bow_slide_dull", "bow_slide_rate", "bow_slide_noise",
        "bow_slide_acc",
        "bow_attack_bite", "bow_attack_bite_ms", "bow_attack_thresh",
        "bow_attack_fms", "bow_attack_vel",
        "bow_vib_cents", "bow_vib_hz",
        // --- output / room / radiation ---
        "bow_live_trim", "bow_rev_mix", "bow_rev_width",
        "bow_rad_lp", "bow_rad_hp", "bow_lim_thresh", "bow_lim_rel_ms",
        // --- coefficient arrays reloaded in place ---
        // The body modal bank (histories kept) and the modal-jawari tables
        // (the wrap is kept, so the web relaxes into its new geometry).
        // `bow_body_modes` is NOT here: it resizes the bank.
        "bow_body_air_ratio", "bow_body_q", "bow_body_q_air",
        "bow_body_rad", "bow_body_scale", "bow_body_y",
        "bow_jt_alpha", "bow_jt_apex", "bow_jt_bst", "bow_jt_drive",
        "bow_jt_fhf", "bow_jt_gain", "bow_jt_hcb", "bow_jt_norm",
        "bow_jt_zone", "bow_jt_radius",
        // The chromatic bridge: the same per-row table bake plus the
        // kernel's per-row contact law, re-pushed after every jt reload.
        "bow_jtc_alpha", "bow_jtc_apex", "bow_jtc_bst", "bow_jtc_drive",
        "bow_jtc_fhf", "bow_jtc_gain", "bow_jtc_hcb", "bow_jtc_norm",
        "bow_jtc_zone", "bow_jtc_radius",
    ]

    /// True when a change to `key` can be pushed onto the running engine.
    public static func appliesInPlace(_ key: String) -> Bool {
        inPlaceKeys.contains(key) || spec(key)?.apply == .live
    }

    /// The kernel's live 0…1 scaler behind a `.hybrid` parameter. The
    /// scaler is an implementation detail — no UI shows it.
    public enum HybridScaler: String {
        case vibratoAmount // the aftertouch axis — vibrato cents
    }

    public static func hybridScaler(_ key: String) -> HybridScaler? {
        switch key {
        case "bow_vib_cents": return .vibratoAmount
        default:              return nil
        }
    }
}
