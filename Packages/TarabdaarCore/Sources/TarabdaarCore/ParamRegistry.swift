import Foundation

/// THE PARAMETER REGISTRY (2026-07-24 unification) — one source of truth
/// for every parameter of the String instrument. Replaces the old split
/// between `BaseParamRegistry` (the `bowed_string.json` physics scalars,
/// edited in the deleted Sarangi tab) and `ControlParamRegistry` (the
/// "live" runtime keys, edited in the Parameters tab). That split put the
/// SAME perceptual knob in two tabs under two names — web buzz vs jawari
/// buzz, vibrato depth vs vibrato depth — with different edit semantics.
///
/// Now there is ONE list. Every parameter has a key, a group, a native
/// range, a resting value, and an **apply strategy**:
///
///  * `.live`    — a runtime setter on the engine; instant, no rebuild.
///  * `.rebuild` — a `bowed_string.json` build scalar; applied as a
///                 persisted override with a debounced off-main rebuild.
///  * `.hybrid`  — a build scalar that ALSO has a live 0…1 scaler in the
///                 kernel (vibrato cents ↔ the aftertouch amount). The
///                 user sees ONE knob in native units: values at or below
///                 the built value ride the scaler (instant); pushing
///                 above it raises the build scalar (rebuild). This is
///                 what collapsed the duplicate pairs — the old
///                 `bow_vibrato` WAS that scaler, exposed as if it were a
///                 separate parameter. (The other hybrid, the sympathetic
///                 web's buzz depth, went away with the web itself on
///                 2026-07-24.)
///
/// Everything in this registry is editable in the Parameters tab, usable
/// as a composite member, and bindable to a tilt (directly or through a
/// composite).
public enum ParamApply: String, Codable {
    case live, rebuild, hybrid
}

/// WHO a parameter acts on (the 2026-08-23 audit):
///
///  * `.global`  — ONE shared mechanism: the bridge/body, the taraf bank,
///    the room/FX/output chain, the shared string physics, or a control
///    axis every note rides together. Changing it moves the whole
///    instrument at once.
///  * `.perNote` — parameterizes a mechanism that runs SEPARATELY for
///    each note: every sounding note carries its own state for it (onset
///    clock, settle/linger envelope, vibrato phase, drift walk, blend
///    window), so simultaneous notes are affected independently. The
///    attack family is CAPTURED at the articulation edge — an edit
///    changes subsequent onsets, never re-articulates a sounding note.
///
/// The line deliberately follows per-note CONTROL STATE, not physics
/// plumbing: friction/string construction values (`bow_mu_s`, twang, …)
/// are `.global` even though every string evaluates them — they carry no
/// per-note state and cannot differ between simultaneous notes.
public enum ParamScope: String, Codable {
    case global, perNote
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
    /// headroom — 1 = the fitted depth (full buzz), 0 = off (no vibrato).
    /// This is what the deleted scaler parameters' defaults used to be.
    public let restFraction: Double?
    /// Global vs per-note — see `ParamScope`.
    public let scope: ParamScope
    public let help: String

    public var id: String { key }

    public init(_ key: String, _ label: String, group: String,
                _ lo: Double, _ hi: Double, _ def: Double,
                step: Double? = nil, apply: ParamApply = .rebuild,
                restFraction: Double? = nil, scope: ParamScope = .global,
                help: String = "") {
        self.key = key; self.label = label; self.group = group
        self.lo = lo; self.hi = hi; self.def = def; self.step = step
        self.apply = apply; self.restFraction = restFraction
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
                      help: "Analytic mode count. 0 = rigid bridge (the bare string — the pre-body 'synthy' sound)."),
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
            ParamSpec("bow_twang", "sitar twang", group: "Bow & string",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Grazing jawari WRAP on the PLAYED strings' bridge (the sitar's flat-bridge contact on the melody string — the taraf's bones are separate; fitted to sitar1.wav). 0 = the plain bridge, byte-exact. Rising = while an excursion tip presses the bone, the string's speaking length shortens a hair (an energy-conserving per-cycle phase modulation that pumps the harmonic cascade), and the terminations morph toward sitar hardware — brighter bridge/nut, eased release damping — so a staccato note keeps a SUSTAINED buzzy 2.5–6 kHz cluster through its ring instead of losing it in ~150 ms. The sitar1.wav match sits near 0.75 of the throw; the last quarter opens the wrap and brightness further (extended-top rev) for a hotter, more present buzz. The graze knee rides each string's own envelope, so the twang engages at ANY strike level — the consistency the fixed-geometry jawari never had — and two pitch-lock terms (termination phase restore + the fitted wrap trim) hold the twanged ring on the plain ring's pitch (±5 c wander at the extremes, a brief sitar-like onset settle at high notes). Applies live, slewed in-kernel."),
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
                      help: "Output mix of the jawari web (the gap-law calibration landed at 0.3)."),
            ParamSpec("bow_jt_drive", "drive", group: "Jawari taraf (modal contact)",
                      0.001, 0.3, 0.03,
                      help: "Bridge-force coupling INTO the strings — sets the graze operating point: too low = no cascade, too high = over-drained/linearized."),
            ParamSpec("bow_jt_apex", "graze depth", group: "Jawari taraf (modal contact)",
                      2e-6, 5e-5, 1e-5,
                      help: "Bone protrusion. The evolution lives at the grazing knee — deep press linearizes (sparkle only), too shallow never engages."),
            ParamSpec("bow_jt_evolve", "evolution", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.5, apply: .live,
                      help: "Harmonic-evolution rate — the tanpura/sitar twang axis: a signed bone offset spanning graze margin ×4 … ×¼ around the fitted bone, slewed inside the kernel (~40 ms) so the bone GLIDES — tilt-sweepable without a strum. 1 = the ring always sits in the grazing band: energy cascades up the partials fast (centroid rise ~0.3 s vs ~1.2 s stock) and at ANY level — the twang is reliable, and the taraf rings a few dB hotter (a real opened jawari does too; trim with level). 0 = the string is pressed past the knee: the wrap holds, harmonics stay put, no twang. 0.5 = the fitted geometry, byte-null. Applies live."),
            ParamSpec("bow_jt_tap", "radiation tap", group: "Jawari taraf (modal contact)",
                      0.86, 0.98, 0.90,
                      help: "Where along the string the taraf radiates (fraction of its length; the drive tap stays fitted). Radiated harmonic k weighs |sin(k·π·tap)| — 0.90 (legacy) humps at h5 and NULLS h10, which muffles the jawari formant; toward the bridge the hump slides up (0.95 → h10, 0.97 → h16) and the fundamental falls away, voicing the ring as the classic cluster of high harmonics over quiet lows."),
            ParamSpec("bow_jt_alpha", "contact law", group: "Jawari taraf (modal contact)",
                      1.0, 2.0, 1.5,
                      help: "Contact stiffness exponent. 1.5 = Hertz (fast sqrt path — the live default); other values cost more CPU."),
            ParamSpec("bow_jt_norm", "level norm", group: "Jawari taraf (modal contact)",
                      0.0, 1.5, 1.0,
                      help: "Per-string t60-response normalization — evens the driven level across scale degrees (long-ring rows charge hotter); 0 = raw physics."),
            ParamSpec("bow_jt_hcb", "contact damping", group: "Jawari taraf (modal contact)",
                      1.0, 40.0, 8.0,
                      help: "Hysteretic damping of the string–bone contact. More = softer buzz transients (rounder force pulses, less clang); the legacy hardcoded value is 8."),
            ParamSpec("bow_jt_fhf", "damping corner (Hz)", group: "Jawari taraf (modal contact)",
                      800.0, 12000.0, 4000.0,
                      help: "Corner of the per-mode f² damping law — above it, partials die progressively faster. LOWER = warmer (the top decays in tens of ms while fundamentals sustain). Legacy 4000."),
            ParamSpec("bow_jt_bst", "inharmonicity", group: "Jawari taraf (modal contact)",
                      0.0, 1.0e-3, 2.0e-4,
                      help: "Stiffness stretch of the upper partials (steel-wire dispersion). Lower = more harmonic top = less bell-metallic; legacy 2e-4 puts mode 40 ~15% sharp."),
            // The two LIVE jawari-taraf axes.
            ParamSpec("bow_jt_lp", "tone LP (Hz)", group: "Jawari taraf (modal contact)",
                      1000.0, 20000.0, 20000.0, apply: .live,
                      help: "One-pole low-pass on the radiated jawari sum ONLY (the main string is untouched). ≥ 20 kHz = bypass, bit-exact legacy. Applies live."),
            ParamSpec("bow_jt_hp", "tone HP (Hz)", group: "Jawari taraf (modal contact)",
                      0.0, 4000.0, 0.0, apply: .live,
                      help: "One-pole high-pass on the radiated jawari sum ONLY — the formant voicing: quiets the taraf's fundamental band so the high-harmonic cluster (see radiation tap) carries the ring. ~1–2× the tonic leaves the twang untouched and drops the lows ~6 dB/oct below the corner. 0 = bypass, bit-exact legacy. Applies live."),
            ParamSpec("bow_jt_body", "body radiation", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Blend of the radiated jawari sum through the SAME formula-body radiation bank the played strings radiate through — the coherence lever: at 0 the taraf radiates raw (beside the instrument), at 1 it rings from the instrument's body with the voice's own formants. Shared coefficients (a body edit re-voices both), own filter state. 0 = bypass, bit-exact legacy. Applies live."),
            ParamSpec("bow_jt_gov", "charge governor", group: "Jawari taraf (modal contact)",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Per-string governor on how much of a phrase the taraf remembers (2026-08-15). The long-ring anchor rows (Sa/Pa, 7\u{2013}9 s) accumulate every note and glide: measured +8\u{2026}+12 dB of extra ring when high Sa lands after a 4-note phrase vs the same note struck cold, a several-dB strike-to-strike lottery (re-excitation phase against the stored ring), and at high expression the pile-up crosses the contact knee into the loud-buzz regime (buzz share 1% \u{2192} 16%). This knob sheds bridge drive into any row already ringing above the graze target (its contact-zone envelope, kernel-side), so rows saturate at their single-strike ring instead of piling up. At 1 (calibrated ref 48\u{d7}apex): a resting-level solo strike is untouched BIT-EXACTLY (the envelope never crosses the target), the moderate sympathetic swell through a phrase survives (~0.2 dB moved), and the hot pile-up is what goes \u{2014} 14\u{2013}16 dB shed, buzz share back to ~1.5%. 0 = raw physics (bit-exact off). Held drones are never ducked (their drive adds after the shed). Graze target: `bow_jt_gov_ref` bp scalar (\u{d7}apex, default 48; ~96 is a trap \u{2014} it parks the ring AT the buzz-maximal graze band). Applies live."),
            ParamSpec("bow_jt_damp", "extra damping", group: "Jawari taraf (modal contact)",
                      0, 1, 0.0, apply: .live,
                      help: "Runtime damping of these modal rows: 0 = the natural long ring, 1 = choked within a second. Applies live — this is what the Taraf Decay composite sweeps."),
            ParamSpec("bow_jt_sel", "recruitment", group: "Jawari taraf (modal contact)",
                      0, 1, 0.5, apply: .live,
                      help: "Which strings contribute to the taraf — the contribution PROFILE, at held loudness (2026-08-01 rework: the old top half was a pure boost and the knob read as a taraf volume). 0.5 = the fitted natural response: unison rows dominate, octaves a few dB down, fifths faint, unrelated rows only haze. Below: rows lose bridge drive by harmonic distance from the played notes until at 0 only kin rows ring; chords recruit additively (soft-OR, bounded). Above: the profile FLATTENS — resonant rows are cut toward the common haze level until at 1 every string contributes equally and the taraf's response (contributions AND level) no longer depends on what the voice plays. Loudness holds throughout via the radiated jt gain (incoherent power model; below 0.5 anchored to the note's own fitted level, above 0.5 blending to one fixed common level; cap ×`bow_jt_sel_comp` [4]). Held drones and the melody follower count as fully ringing in the model so they are never pumped, and rings already sounding are never ducked. Lattice: `bow_jt_sel_width` (cents, 30) and `bow_jt_sel_kin` (exponent, 0.7 — shared with the drone spread), bp scalars like the tilt range keys. Applies live — the Taraf Purity composite's recruitment member (purity up = kin-only)."),
        ]),

        // The "Taraf (sympathetic)" group — `bow_taraf_*` and `bow_open_*`,
        // the LINEAR comb web on the passive wave junction plus the open gut
        // pair — was DELETED 2026-07-24. It was a cheap approximation of a
        // buzzing sympathetic string (comb + a flat-bridge buzz term) living
        // alongside the modal-jawari block, which models the same thing
        // properly. Silenced (coupling Z 0) the instrument sounded better,
        // so the web is gone and `bow_jt_*` above IS the taraf. The Tarab
        // tab still tunes it — those rows now feed the jawari builder only.
        // 2026-08-01: the web MACHINERY is re-armed as a SILENT coupling
        // layer (`bow_cpl_*` below) — the buzz and the radiated ring stay
        // deleted; only the bridge load returns.

        ("Taraf coupling (bridge load)", [
            ParamSpec("bow_cpl_z", "coupling Z", group: "Taraf coupling (bridge load)",
                      0.0, 0.1, 0.0,
                      help: "TWO-WAY sympathetic coupling: each enabled tarab row becomes a silent comb string on the passive bridge junction, so the played strings feel the taraf as a load — a note at a kin pitch drains into the row and the row returns the energy through the body (the bloom a one-way drive can't make). 0 = off, bit-exact legacy. PER-ROW impedance (follows the row's gain) — the bank multiplies it: total bridge load ≈ rows × value, so what a single row tolerates over-damps a full bank (measured: 0.05 on one row = the bloom optimum, but on the 19-row default bank it drags held notes ~5 dB). The offline fit's 0.0141 was fitted AT full-bank scale — start there; ~0.03 is already a strong load. Needs a rebuild."),
            ParamSpec("bow_cpl_t60", "ring scale", group: "Taraf coupling (bridge load)",
                      0.2, 2.0, 1.0,
                      help: "Scale on each row's own t60 for its coupling comb (capped 8 s): how long the bridge holds absorbed energy before it has all returned or dissipated. 1 = the row's tabled decay — the physical default (the comb IS the same string the jt row models)."),
            ParamSpec("bow_cpl_damp", "HF damping", group: "Taraf coupling (bridge load)",
                      0.0, 1.0, 0.019,
                      help: "Frequency-dependent loop damping of the coupling combs — upper partials couple and die faster, matching real string damping. Default = the offline fit's web value (0.019)."),
            ParamSpec("bow_cpl_bright", "bandwidth", group: "Taraf coupling (bridge load)",
                      0.0, 1.0, 0.8,
                      help: "Coupling bandwidth: loop low-pass corner 1.4–7.4 kHz. Above the corner the taraf stops exchanging energy with the bridge. Default = the offline fit's web brightness (0.80 ≈ 6.2 kHz)."),
            ParamSpec("bow_cpl_inharm", "inharmonicity", group: "Taraf coupling (bridge load)",
                      0.0, 0.6, 0.1,
                      help: "Stiffness dispersion of the coupling combs (steel-string upper partials run sharp), matching the jt rows' bst stretch in spirit. Default = the offline fit's web value (0.1)."),
        ]),

        ("Articulation", [
            ParamSpec("bow_place_ms", "place (ms)", group: "Articulation",
                      0, 120, 35,
                      scope: .perNote,
                      help: "Bow-set hold before the draw: force on, velocity 0 (static stick). 0 = instant legacy attack."),
            ParamSpec("bow_draw_ms", "draw (ms)", group: "Articulation",
                      5, 200, 60,
                      scope: .perNote,
                      help: "Velocity rise for a GENTLE (legato) attack — the pre-Helmholtz crunch window."),
            // DEFAULT = ENGINE TRUTH (2026-08-19): the artifact carries no
            // bow_draw_min_ms / bow_attack_bite key, and absent keys fall
            // to the ENGINE fallbacks (draw_min follows bow_draw_ms; bite
            // 0 = off) — these defs used to show the offline fit's 8/2.0
            // while the engine ran 60/0. Keep def == engine fallback for
            // every artifact-absent rebuild key (ParamUnificationTests
            // pins the articulation/liveness set).
            ParamSpec("bow_draw_min_ms", "sharp draw (ms)", group: "Articulation",
                      3, 60, 60,
                      scope: .perNote,
                      help: "Velocity rise for a maximally SHARP attack: a hard onset draws this fast (accent/martelé). Untouched it follows the gentle draw time (no speedup); the offline fit played accents at ~8 ms."),
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
                      help: "Force rise of a maximally SHARP attack (velocity-leads-force martelé mechanics: the bow moves at once, the force ramps in over this time). Was a fixed constant; registered 2026-08-19."),
            ParamSpec("bow_attack_vel", "velocity sharpness", group: "Articulation",
                      0.0, 1.0, 0.0,
                      scope: .perNote,
                      help: "How much the ONSET STRIKE VELOCITY sharpens the attack: sharpness = max(press law, this × velocity 0…1). Makes articulation per-note — tap hard = martelé bite, place gently = legato draw. Velocity comes from the iPad's accelerometer strike estimate (or MIDI/audition velocity); 0 = off (the historic press-only law)."),
            // HYBRID: the vibrato depth in cents. The kernel scales it by the
            // aftertouch amount 0…1 — which the old `bow_vibrato` "vibrato
            // depth" parameter drove as a second knob. Nothing else writes
            // that axis (per-voice aftertouch emission was deleted
            // 2026-07-24), so one knob in cents now owns it: 0…built ¢ is
            // instant, above the built depth rebuilds.
            ParamSpec("bow_vib_cents", "vibrato depth (¢)", group: "Articulation",
                      0, 60, 25, apply: .hybrid, restFraction: 0.0,
                      scope: .perNote,
                      help: "Finger-vibrato peak depth in cents at the vibrato rate. 0 = none (the resting default). Up to the built depth this applies instantly; above it the engine rebuilds."),
            ParamSpec("bow_vib_hz", "vibrato rate (Hz)", group: "Articulation",
                      3, 9, 5.5,
                      scope: .perNote,
                      help: "Vibrato frequency (real players ~5–7 Hz)."),
        ]),

        // THE STRIKE→ACCELERATION BLEND (2026-08-23): the control-layer
        // knob of the `.strike`/`.acceleration` dimension pair. Not a
        // voice parameter — `AppController.applyParamToVoice` intercepts
        // the key before the voice routing and feeds `StrikeBlendWindow`
        // + the JOYCON_STATE relay (the iPad scope's onset fade tracks
        // it).
        ("Strike blend", [
            ParamSpec("ctl_strike_window", "blend window (s)", group: "Strike blend",
                      0.25, 8.0, 2.0, apply: .live,
                      scope: .perNote,
                      help: "How long a note takes to hand the accelerometer measure from its Strike bindings to its Acceleration bindings: at onset the Strike side applies fully, by this many seconds the Acceleration side does — linear in between, per note (a new note never resets a sounding note's window). Also sets the iPad strike scope's white→cyan onset fade."),
        ]),

        // SUSTAIN LIVENESS + LEGATO LIGHTENING (2026-08-01) — fitted to
        // clean SWAM Violin 3 captures (room off, vibrato 0, constant
        // expression): the settle matches its +1.8 dB post-onset ease-down,
        // the drift its 0.5 dB / 0.6–2.5 Hz sustain wander, the glide dip
        // its 3.5–9 dB legato-transition bow lightening.
        ("Liveness", [
            ParamSpec("bow_settle_db", "onset settle (dB)", group: "Liveness",
                      0, 12, 7.0,
                      scope: .perNote,
                      help: "How far the bow eases down after a fresh attack: the friction loop alone overshoots ~+7 dB over the sustainable level for ~0.5 s; this trims the stroke onto SWAM's ~+2 dB settle. Zero through the place+draw window, so the staccato bite is untouched. 0 = off."),
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
                      help: "Slow random pitch wander of a held note (bounded random walk, NOT vibrato) — the finger/bow life of a sustain. The body slope turns it into decorrelated per-harmonic shimmer; the fitted sarangi body is steep (~3 dB/¢ at D4), so a little goes far. 0 = the old dead-flat sustain."),
            ParamSpec("bow_drift_hz", "drift bandwidth (Hz)", group: "Liveness",
                      0.2, 6, 1.2,
                      scope: .perNote,
                      help: "Bandwidth of all three liveness walks (pitch, level, force). SWAM's sustain motion lives at 0.5–2.5 Hz — well below vibrato rate."),
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
                      help: "Legato bow lightening: the bow eases while the pitch is MOVING (full depth on velocity, 0.3× on force), reproducing SWAM's 3.5–9 dB transition dips. The dip follows the sounding-pitch slew, so drift/vibrato never trigger it. 0 = off."),
            ParamSpec("bow_glide_dip_rate", "dip half-rate (¢/s)", group: "Liveness",
                      100, 5000, 900,
                      scope: .perNote,
                      help: "Pitch slew at which the glide dip reaches half depth. A fret-to-fret legato step sweeps ~1500 ¢/s; slow meend ~200 ¢/s gets a gentle ~1 dB."),
        ]),

        // FRET LINGER + Y-DEPTH AUTO-VIBRATO (2026-08-18): the fret as a
        // control surface. A finger LINGERING on a fret slowly loses
        // expression and grows a vibrato whose ceiling is set by where the
        // finger sits WITHIN ITS HOME FRET's vertical extent, oriented
        // OUTWARD: the dead zone is the fret's 70% toward the pad's
        // centre-line, and depth ramps to full at the fret's OUTER end
        // (the v5 rev — the ceiling axis was briefly the whole pad band,
        // then briefly fret-centre-symmetric); STROKING the finger vertically
        // along the fret recharges expression to the base value and
        // returns the note to its no-vibrato birth state. All first-order
        // envelopes evolved at kernel rate in BowControlFilter — smooth by
        // construction. Only touches whose surface reports a fret-band y
        // engage any of this (the fret pads; unsnapped/fretless onsets
        // have no home fret and get no auto-vibrato); the keyboard,
        // audition scores and external MIDI stay on the legacy path
        // bit-exact. The Mac streams the evaluated envelopes back to the
        // iPad's touch overlay (LINGER_STATE).
        ("Fret linger", [
            ParamSpec("bow_linger_decay", "expression decay (s)", group: "Fret linger",
                      0, 60, 8.0,
                      scope: .perNote,
                      help: "Time constant of the expression ease-down while the finger rests on a fret without moving. The note fades toward the linger floor; a vertical stroke along the fret brings it back. 0 = no decay (lingering holds full expression)."),
            ParamSpec("bow_linger_floor", "linger floor", group: "Fret linger",
                      0, 1, 0.0,
                      scope: .perNote,
                      help: "Where the lingering note's expression settles, as a fraction of the played expression. 0 = all the way down (with an expression-lift zone the bow eventually lifts to silence); 1 = no audible decay."),
            ParamSpec("bow_linger_recharge", "recharge time (s)", group: "Fret linger",
                      0.05, 2, 0.35,
                      scope: .perNote,
                      help: "How fast a vertical finger stroke restores things: expression back to the base value, the auto-vibrato back to none. Small = a single stroke snaps the note awake; large = it swells back gradually."),
            ParamSpec("bow_linger_speed", "full-drive speed (band/s)", group: "Fret linger",
                      0.05, 2, 0.35,
                      scope: .perNote,
                      help: "Vertical finger speed (in fret-band heights per second, smoothed ~100 ms) at which the recharge reaches full strength. Slower movement recharges proportionally less."),
            ParamSpec("bow_avib_cents", "auto-vib depth (¢)", group: "Fret linger",
                      0, 60, 30.0,
                      scope: .perNote,
                      help: "Peak depth of the y-position auto-vibrato at the OUTER end of the note's home fret (the end away from the pad's centre-line — the fret's wavy tail). Notes are born vibrato-free and grow toward the y-set ceiling over the growth time; the fret's inner portion (the dead zone) gives none, and a note that didn't snap to a fret has no ceiling at all. 0 = the feature off. Independent of the aftertouch vibrato (bow_vib_cents)."),
            ParamSpec("bow_avib_hz", "auto-vib rate (Hz)", group: "Fret linger",
                      3, 9, 5.2,
                      scope: .perNote,
                      help: "Rate of the auto-vibrato (real players ~5–7 Hz)."),
            ParamSpec("bow_avib_grow", "auto-vib growth (s)", group: "Fret linger",
                      0.3, 10, 2.5,
                      scope: .perNote,
                      help: "Time constant of the vibrato's rise while the finger rests: the note starts plain and the vibrato blooms toward the y-set ceiling."),
            ParamSpec("bow_avib_dead", "inner dead zone", group: "Fret linger",
                      0, 0.95, 0.7,
                      scope: .perNote,
                      help: "Fraction of the fret's length, from its INNER end (toward the pad's centre-line), that stays vibrato-free — the landing zone for plain notes. Depth then ramps to full at the fret's outer end (its wavy tail). The surfaces mark the default 0.7 split on the frets; the marking does not follow edits to this value."),
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
            ParamSpec("bow_live_trim", "output trim", group: "Radiation & output",
                      0.01, 0.5, 0.175,
                      help: "Final level (matched to the Sarangi Live instrument) — the CALIBRATION half; use master gain above for performance volume."),
            ParamSpec("bow_lim_thresh", "limiter ceiling", group: "Radiation & output",
                      0.1, 1.0, 0.8,
                      help: "Output safety limiter (2026-08-01): linked-stereo peak ceiling at the very end of the chain (after global FX). Below it, samples pass bit-exact; above, instant-attack gain riding with the release below. Exists for the coherent kin peaks (hard-struck Sa/Pa: voice + jt ring + coupling return add in phase) and the ±16 dB expression axis. For evening the CAUSE, see bow_jt_norm — long-ring anchor rows charge hotter."),
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
                      help: "L/R decorrelation of the room tail — a real room's reverberant field differs at the two ears. Cancels in the mono fold-down. 0 = the old mono room."),
            ParamSpec("bow_st_width", "instrument width", group: "Radiation & output",
                      0.0, 1.0, 0.2,
                      help: "THE width law (2026-08-01 unification): the whole instrument — played voice, taraf wash, drones, bow noise — heard from TWO observation points. A dense diffuse-field difference bank above the Schroeder crossover, so lows stay identical in L and R (one centred instrument) while the upper spectrum decorrelates the way a real instrument's does between two ears. Measured at the 0.2 default: melody interaural coherence ~0.9 at 4-8 kHz, the bare wash ~0.3-0.4, balance within ±0.8 dB. Not a pan: zero net lean by construction; cancels in the mono fold-down. Replaces the retired per-source pans (bow_st_spread / bow_st_played, disarmed legacy staging). 0 = point radiator (mono-in-place)."),
            ParamSpec("bow_st_spread", "taraf pan spread (legacy)", group: "Radiation & output",
                      0.0, 1.0, 0.0,
                      help: "LEGACY svara staging, disarmed by default since the 2026-08-01 width unification (which replaced per-source placement with the one instrument-width law): each jawari row panned to its own fixed place around the tonic (spread·sin(2π·pc)). Kept for A/B against bow_st_width; pending removal. Mono fold-down invariant."),
            ParamSpec("bow_st_played", "bow-noise pan spread (legacy)", group: "Radiation & output",
                      0.0, 0.5, 0.0,
                      help: "LEGACY per-voice bow-noise placement (the played string's position on the bridge), disarmed by default since the 2026-08-01 width unification. Kept for A/B; pending removal. Mono fold-down invariant."),
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
                      help: "Scales the drone buttons' tanpura pluck displacement (1 = the role's fitted pluck at velocity 100). Only the tanpura drone mode reads it; the legacy sympathetic drones keep their own bow_drone_* calibration."),
            ParamSpec("tp_drone_cycle", "drone re-pluck period (s)", group: "Tanpura",
                      0.0, 8.0, 2.5, apply: .live,
                      help: "While a drone button stays held, the tanpura re-plucks its string every this many seconds — the strumming hand. Below 0.1 s the cycle is off (a press is then a single pluck; the string still rings for its full t60 either way). Applies live, mid-hold."),
            ParamSpec("tp_pluck_level", "played pluck level", group: "Tanpura",
                      0.0, 2.0, 1.0, apply: .live,
                      help: "Scales the fret-note tanpura plucks when the tanpura is the MAIN instrument (velocity still shapes each pluck on top). Inert while the String voice is the played instrument."),
            ParamSpec("tp_rel_t60", "note-off release t60 (s)", group: "Tanpura",
                      0.05, 3.0, 0.4, apply: .live,
                      scope: .perNote,
                      help: "Main-instrument note-off decay (2026-08-05): a HELD fret note rings at the string's natural rate, a released one decays to −60 dB in this many seconds — a finger stop, not a hard damp (the jawari buzz cuts at note-off, the pitch rings down). Drone-button strings never read it (release = ring out, their nature)."),
            ParamSpec("tp_pluck_touch", "pluck isolation", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "How isolated each pluck is from the string's ringing past. At 0 (the physical default) a pluck lands ON TOP of whatever is still ringing — pluck-to-pluck phase alignment then decides the level and buzz (measured: +7 dB energy build-up under dense re-plucking, 5× buzz-energy swings), the tanpura's untamed side. Above 0, every pluck is a SEPARATE STRING: the ringing string moves to the history bank (full jawari simulation at its own pitch, its ring scaled by this value — 1 = it rings on in full) and the new pluck starts from settled state, so attacks are always consistent. tp_poly sets how many history strings stay alive; note that same-pitch strings still sum in the air — their slowly drifting phases beat like a jodi pair, which is the physics of two real strings, not a defect. A note-off-released string never resurrects. Applies to drone AND main-instrument plucks, live, at the next pluck."),
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
                      help: "Per-pitch jiva (jawari thread) calibration. The fitted thread geometry gives the LOW register its sustained graze — the slow, laddered harmonic cascade; higher strings extrapolate that geometry, fall off the bone, and ring clean/dark (measured: buzz energy drops from ~15% at low Sa to <1% an octave up, and no pluck level restores the regime — quiet stays dead, loud slams the whole cascade in ~0.2 s). This retargets each string's thread height the way a player adjusts the cotton thread per string: at 1 every pitch keeps low Sa's buzziness and laddered cascade (bench-measured targets, pitch cost under a cent); at 0 the fitted geometry is untouched. Edits schedule a debounced full tanpura rebuild (seconds of CPU), like the scale-shape trio."),
            ParamSpec("tp_cascade", "register cascade slowing", group: "Tanpura",
                      0.0, 1.0, 1.0, apply: .live,
                      help: "Slows the higher strings' harmonic cascade toward low Sa's unhurried pace. Even register-calibrated, higher pitches develop their overtone ladder faster in real time (the jawari converts on every graze pass, and passes come at the string's frequency — measured: mid harmonics arriving in 0.2 s at an octave up vs 2 s at low Sa). This raises each higher string's jiva thread a touch further toward the fitted height (a gentler graze — the instant harmonic jump becomes a ~1 s bloom) and lets its upper partials ring longer to keep the buzz level (both graded by pitch, zero at and below the 104 Hz anchor). At 1 the octave-up ladder matches low Sa's character; at 0 only the base calibration applies. Edits schedule the debounced full tanpura rebuild, like tp_jiva_comp."),
            ParamSpec("tp_shape_align", "scale-shape: overtone retune", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "SCALE-SHAPED OVERTONES (2026-08-05) — the altered tanpura: retunes each partial (modes 3+; 1–2 pin the pitch) toward the nearest scale pitch class, by this fraction of the distance. Full pull inside an 80 ¢ capture window, tapering to nothing by 160 ¢ — so harmonic 5 lands on komal ga (~71 ¢) and harmonic 7 on n, while partials in a pentatonic gap stay harmonic. 0 = the physical string. Applies through a DEBOUNCED full tanpura rebuild (~seconds, 750 ms after the drag settles) — not instant."),
            ParamSpec("tp_shape_focus", "scale-shape: sustain focus", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Tilts sustain toward scale-aligned partials: each mode's t60 is scaled by its post-retune proximity to the scale (a 30 ¢ gaussian kernel — aligned = full ring, a 71 ¢-off partial at focus 1 keeps ~6% of its t60, floored at 5% — thinned, never killed). Because the jawari keeps re-pumping every mode, the cascade EVOLVES toward the scale over the note's life rather than being statically EQ'd. Debounced rebuild like tp_shape_align."),
            ParamSpec("tp_shape_quiet", "scale-shape: misaligned quiet", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
                      help: "Turns down the RADIATED level of partials that don't align with the scale (post-retune, same 30 ¢ proximity kernel as tp_shape_focus): each mode's output projection is scaled toward silence — at 1 an off-scale partial is inaudible. Unlike tp_shape_focus this changes NO dynamics: the mode still rings at full energy and keeps trading energy through the jawari contact, it is simply heard less — a per-partial fader, where focus is a per-partial damper. Debounced rebuild like tp_shape_align."),
            ParamSpec("tp_shape_spread", "scale-shape: retune spread", group: "Tanpura",
                      0.0, 1.0, 0.0, apply: .live,
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

    /// One FX insert point's parameter block (FX tab, 2026-08-01): a
    /// 10-band graphic EQ and a selectable additive reverb, all `.live`
    /// (they never touch the physics tables) and all off by default —
    /// the untouched rack is byte-null. `prefix` matches
    /// `SarangiKit.FXPoint.keyPrefix`; the suffixes are what
    /// `FXSettings.apply(field:value:)` parses.
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

    /// IN-PLACE PARAMETERS (2026-07-24): keys whose change needs no fresh
    /// engine — `BowEngine.setLiveParams` can push them onto a RUNNING
    /// kernel, so they apply with no latency and no lost ring. Two
    /// families, both verified empirically by `ParamLivenessTests`
    /// (perturb the key, rebuild the tables, see what actually moved):
    ///
    ///  * **kernel scalars** — the change lands only in the 61-element
    ///    per-sample scalar vector, which `bow_[poly_]set_scalars`
    ///    overwrites in place.
    ///  * **mapping constants** — the change never reaches the tables at
    ///    all; it is read by `BowControlFilter` (playing ranges,
    ///    articulation, vibrato) or by the output/room/radiation stage.
    ///
    /// NOT included: anything that moves a coefficient ARRAY (the body
    /// modes, the sympathetic web, the jawari tables) or resizes one
    /// (`bow_body_modes`). Those still rebuild — see docs/sound-design.md.
    public static let inPlaceKeys: Set<String> = [
        // --- kernel scalars ---
        "bow_Zt", "bow_age_a", "bow_age_ms", "bow_body_c0", "bow_br_fc",
        "bow_cr_ms", "bow_cr_w", "bow_gut_fc2", "bow_gut_g", "bow_mu_d",
        "bow_mu_s", "bow_noise", "bow_noise_dir", "bow_nut_fc",
        "bow_tors_c", "bow_tors_g",
        "bow_tors_ratio", "bow_v0", "bow_w", "bow_yinf",
        // `bow_kret` reaches the kernel as a scalar too; the loop-gain cap
        // can swallow a small nudge, which is why the empirical probe
        // files it under "no tables".
        "bow_kret",
        // --- mapping constants (BowControlFilter) ---
        "bow_v_lo", "bow_v_hi", "bow_live_beta_lo", "bow_live_beta_hi",
        "bow_live_press_under", "bow_live_press_over", "bow_expr_lift",
        "bow_f_cap", "bow_place_ms", "bow_draw_ms", "bow_draw_min_ms",
        "bow_settle_db", "bow_settle_ms", "bow_settle_sharp",
        "bow_drift_cents", "bow_drift_hz",
        "bow_drift_db", "bow_drift_force_db", "bow_glide_dip_db",
        "bow_glide_dip_rate",
        "bow_attack_bite", "bow_attack_bite_ms", "bow_attack_thresh",
        "bow_attack_fms", "bow_attack_vel",
        "bow_vib_cents", "bow_vib_hz",
        // Fret linger / auto-vibrato: pure BowControlFilter mapping
        // constants. NOTE they act only on touches that report a fret-band
        // y, so the liveness probe's MIDI-path render files them under
        // "inert in this configuration, rebuild agrees" — correct.
        "bow_linger_decay", "bow_linger_floor", "bow_linger_recharge",
        "bow_linger_speed", "bow_avib_cents", "bow_avib_hz",
        "bow_avib_grow", "bow_avib_dead",
        // --- output / room / radiation ---
        "bow_live_trim", "bow_rev_mix", "bow_rev_width",
        "bow_rad_lp", "bow_rad_hp", "bow_lim_thresh", "bow_lim_rel_ms",
        // --- STAGE 3: coefficient arrays reloaded in place ---
        // The body modal bank (histories kept, so click-free) and the
        // modal-jawari tables (the wrap is kept, so the web relaxes into
        // its new geometry the way a real jawari adjustment does).
        // `bow_body_modes` is NOT here: it resizes the bank.
        "bow_body_air_ratio", "bow_body_q", "bow_body_q_air",
        "bow_body_rad", "bow_body_scale", "bow_body_y",
        "bow_jt_alpha", "bow_jt_apex", "bow_jt_bst", "bow_jt_drive",
        "bow_jt_fhf", "bow_jt_gain", "bow_jt_hcb", "bow_jt_norm",
        "bow_jt_tap",
        // The old exclusion list here covered the linear sympathetic web
        // (`bow_taraf_*`), whose delay lengths and per-voice charge window
        // could not be swapped under a running ring. That web is gone
        // (2026-07-24); `bow_body_modes` is the only structural key left.
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
