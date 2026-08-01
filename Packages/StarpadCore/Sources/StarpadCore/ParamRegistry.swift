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
    public let help: String

    public var id: String { key }

    public init(_ key: String, _ label: String, group: String,
                _ lo: Double, _ hi: Double, _ def: Double,
                step: Double? = nil, apply: ParamApply = .rebuild,
                restFraction: Double? = nil, help: String = "") {
        self.key = key; self.label = label; self.group = group
        self.lo = lo; self.hi = hi; self.def = def; self.step = step
        self.apply = apply; self.restFraction = restFraction; self.help = help
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
            ParamSpec("bow_jtaraf_on", "armed", group: "Jawari taraf (modal contact)",
                      0, 1, 0, step: 1,
                      help: "The tanpura-evolution block: modal steel strings over grazing jawari bones on the raga-lattice rows. 0 = off (zero cost). Live config runs at 48 kHz, ~half a core when armed."),
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
            ParamSpec("bow_jt_damp", "extra damping", group: "Jawari taraf (modal contact)",
                      0, 1, 0.0, apply: .live,
                      help: "Runtime damping of these modal rows: 0 = the natural long ring, 1 = choked within a second. Applies live — this is what the Taraf Decay composite sweeps."),
            ParamSpec("bow_jt_sel", "recruitment", group: "Jawari taraf (modal contact)",
                      0, 1, 0.5, apply: .live,
                      help: "How much of the taraf joins each note, bipolar around 0.5 = the fitted response. Below: rows lose bridge drive by harmonic distance from the played notes until at 0 only kin rows ring (unison, faint octaves, fainter fifth); chords recruit additively (soft-OR, bounded). Above: the chorus swells — at 1 every row is driven harder AND the radiated jt sum is lifted, both ×`bow_jt_sel_lush` [2] (~+6 dB with extra cascade — an opened-jawari lushness where the whole taraf joins prominently). Held drones and rings already sounding are never ducked. Lattice: `bow_jt_sel_width` (cents, 30) and `bow_jt_sel_kin` (exponent, 0.7 — shared with the drone spread), bp scalars like the tilt range keys. Applies live — the Taraf Purity composite's recruitment member (purity up = kin-only)."),
        ]),

        // The "Taraf (sympathetic)" group — `bow_taraf_*` and `bow_open_*`,
        // the LINEAR comb web on the passive wave junction plus the open gut
        // pair — was DELETED 2026-07-24. It was a cheap approximation of a
        // buzzing sympathetic string (comb + a flat-bridge buzz term) living
        // alongside the modal-jawari block, which models the same thing
        // properly. Silenced (coupling Z 0) the instrument sounded better,
        // so the web is gone and `bow_jt_*` above IS the taraf. The Tarab
        // tab still tunes it — those rows now feed the jawari builder only.

        ("Articulation", [
            ParamSpec("bow_place_ms", "place (ms)", group: "Articulation",
                      0, 120, 35,
                      help: "Bow-set hold before the draw: force on, velocity 0 (static stick). 0 = instant legacy attack."),
            ParamSpec("bow_draw_ms", "draw (ms)", group: "Articulation",
                      5, 200, 60,
                      help: "Velocity rise for a GENTLE (legato) attack — the pre-Helmholtz crunch window."),
            ParamSpec("bow_draw_min_ms", "sharp draw (ms)", group: "Articulation",
                      3, 60, 8,
                      help: "Velocity rise for a maximally SHARP attack: a hard-press onset draws this fast (accent/martelé)."),
            ParamSpec("bow_attack_bite", "attack bite", group: "Articulation",
                      0, 4, 2.0,
                      help: "How hard a sharp onset over-forces: the high force under a fast velocity onset drives the friction loop's own upper-harmonic multi-slip burst. 0 = off (plain place-then-draw). Sharpness = press above the threshold."),
            ParamSpec("bow_attack_bite_ms", "bite decay (ms)", group: "Articulation",
                      10, 200, 60,
                      help: "How long the onset over-force lasts before settling into the steady note."),
            ParamSpec("bow_attack_thresh", "bite threshold", group: "Articulation",
                      0.0, 1.0, 0.5,
                      help: "Press below this = legato (no bite); above it the attack sharpens toward the full bite at press 1."),
            // HYBRID: the vibrato depth in cents. The kernel scales it by the
            // aftertouch amount 0…1 — which the old `bow_vibrato` "vibrato
            // depth" parameter drove as a second knob. Nothing else writes
            // that axis (per-voice aftertouch emission was deleted
            // 2026-07-24), so one knob in cents now owns it: 0…built ¢ is
            // instant, above the built depth rebuilds.
            ParamSpec("bow_vib_cents", "vibrato depth (¢)", group: "Articulation",
                      0, 60, 25, apply: .hybrid, restFraction: 0.0,
                      help: "Finger-vibrato peak depth in cents at the vibrato rate. 0 = none (the resting default). Up to the built depth this applies instantly; above it the engine rebuilds."),
            ParamSpec("bow_vib_hz", "vibrato rate (Hz)", group: "Articulation",
                      3, 9, 5.5,
                      help: "Vibrato frequency (real players ~5–7 Hz)."),
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
            ParamSpec("bow_live_trim", "output trim", group: "Radiation & output",
                      0.01, 0.5, 0.175,
                      help: "Final level (matched to the Sarangi Live instrument)."),
            ParamSpec("bow_rev_mix", "room mix", group: "Radiation & output",
                      0.0, 0.3, 0.08,
                      help: "Room level. The wet pair is width-decorrelated (see room width); the L+R fold-down stays pan-invariant. 0 = bone dry."),
            ParamSpec("bow_rev_rt60", "room decay (s)", group: "Radiation & output",
                      0.2, 2.0, 1.0, help: "Room reverberation time."),
            ParamSpec("bow_rev_width", "room width", group: "Radiation & output",
                      0.0, 1.0, 0.8,
                      help: "L/R decorrelation of the room tail — a real room's reverberant field differs at the two ears. Cancels in the mono fold-down. 0 = the old mono room."),
            ParamSpec("bow_st_spread", "taraf width", group: "Radiation & output",
                      0.0, 1.0, 0.2,
                      help: "Stereo spread of the jawari rows' DIRECT radiation (drones included): each svara rings from its own fixed place around the tonic. Bridge-borne energy stays centred. Mono fold-down invariant. 0 = mono. Default narrowed 0.7 → 0.2 (2026-08-01): a real sarangi is one small radiator — a wide source halo reads as an accompanying chorus; the room width carries the image instead."),
            ParamSpec("bow_st_played", "bow-noise spread", group: "Radiation & output",
                      0.0, 0.5, 0.15,
                      help: "Per-voice spread of the bow-contact noise (the played string's position on the bridge). The played tone itself radiates from the body and stays centred."),
            ParamSpec("bow_tone_tilt", "tone tilt (bass–treble)", group: "Radiation & output",
                      -1, 1, 0.0, apply: .live,
                      help: "Overall spectral tilt: −1 = bass-biased, 0 = flat, +1 = treble-biased. A complementary shelf pair on the whole voice before the room. Applies live — the Tone Tilt composite sweeps this."),
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
        "bow_attack_bite", "bow_attack_bite_ms", "bow_attack_thresh",
        "bow_vib_cents", "bow_vib_hz",
        // --- output / room / radiation ---
        "bow_live_trim", "bow_rev_mix", "bow_rev_width",
        "bow_rad_lp", "bow_rad_hp",
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
