import SwiftUI
import SarangiKit

/// The String instrument's OWN parameter editor — the `bowed_string.json`
/// physics scalars the pure-physics played voice actually uses (the coupled
/// network's model-parameter panel is meaningless for it). The taraf TUNING
/// (which strings, pitches, gains, decay times) lives in the **Tarab tab** —
/// this panel owns the taraf PHYSICS. Groups mirror the physics: the formula
/// body, the bow/string friction constants, the playing-range mapping, the
/// modal-jawari and sympathetic taraf, articulation, and radiation/output.
/// Ported from the upstream Sarangi Live `StringParamsView` (2026-07-21);
/// rows/ranges/help verbatim so the two editors stay greppably in step.
/// Every edit applies live (debounced String-engine rebuild through
/// `StringParamStore`); "Default" clears every override — the bundled
/// artifact IS the Sarangi Live default.
struct StringParamsView: View {
    @EnvironmentObject var stringStore: StringParamStore

    struct Row: Identifiable {
        let id: String        // artifact key
        let label: String
        let lo: Double, hi: Double
        let def: Double
        let step: Double?     // integer-ish params (mode count …)
        let help: String
        init(_ id: String, _ label: String, _ lo: Double, _ hi: Double,
             _ def: Double, step: Double? = nil, help: String = "") {
            self.id = id; self.label = label; self.lo = lo; self.hi = hi
            self.def = def; self.step = step; self.help = help
        }
    }

    static let groups: [(String, [Row])] = [
        ("Body (formula modes)", [
            Row("bow_body_modes", "modes", 0, 16, 12, step: 1,
                help: "Analytic mode count. 0 = rigid bridge (the bare string — the pre-body 'synthy' sound)."),
            Row("bow_body_scale", "body size", 0.15, 2.5, 1.0,
                help: "Scales every mode: <1 = smaller body (violin direction), >1 = larger (cello direction). 1 = built for the current tonic."),
            Row("bow_body_air_ratio", "air mode ratio", 0.4, 2.2, 1.4,
                help: "Lowest (air) resonance as a multiple of the open string. Under 1 (air mode BELOW the tonic) is what charges the taraf."),
            Row("bow_body_q", "wood Q", 5, 60, 25,
                help: "Mode sharpness: low = damp/soft wood, high = ringy/hard."),
            Row("bow_body_q_air", "air Q", 4, 30, 12,
                help: "Air-resonance sharpness."),
            Row("bow_body_y", "mobility depth", 0.0, 2.0, 0.35,
                help: "How much the bridge moves at the modes — note-to-note unevenness, wolf tendency, attack bloom."),
            Row("bow_body_rad", "modal radiation", 0.0, 3.0, 1.0,
                help: "How loudly the modes radiate (vs the direct term)."),
            Row("bow_body_c0", "direct radiation", 0.0, 1.0, 0.3,
                help: "Non-modal (flat) radiation floor. 1 with modes 0 = the raw bridge force."),
            Row("bow_yinf", "bridge give", 0.0, 0.4, 0.05,
                help: "Broadband bridge admittance floor under the modes."),
            Row("bow_kret", "body return", 0.0, 0.5, 0.35,
                help: "Bridge motion fed back into the string (loop-cap protected). More = livelier, wolfier."),
        ]),
        ("Bow & string", [
            Row("bow_mu_s", "static friction", 0.4, 1.2, 0.8,
                help: "Rosin stick strength (grip)."),
            Row("bow_mu_d", "dynamic friction", 0.1, 0.6, 0.3,
                help: "Slip friction. The stick/slip GAP sets the Schelleng ceiling."),
            Row("bow_v0", "friction corner", 0.05, 0.5, 0.2,
                help: "Friction-curve knee: smaller = sharper corner = brighter attack edge."),
            Row("bow_Zt", "torsional damping", 0.0, 15.0, 7.9,
                help: "String rotation losses at the bow contact."),
            Row("bow_gut_g", "gut loss", 0.985, 1.0, 0.998,
                help: "Per-round-trip broadband loss — lower = duller, deader string."),
            Row("bow_gut_fc2", "gut top (Hz)", 500, 12000, 3500,
                help: "Second termination pole: the gut string's own HF ceiling."),
            Row("bow_nut_fc", "nut corner (Hz)", 1000, 12000, 5500,
                help: "Nut/finger termination low-pass."),
            Row("bow_br_fc", "bridge corner (Hz)", 1000, 12000, 6750,
                help: "Bridge termination low-pass."),
            Row("bow_noise", "contact noise", 0.0, 0.4, 0.1,
                help: "Hair-scatter noise recirculated into the friction loop."),
            Row("bow_noise_dir", "direct noise", 0.0, 0.4, 0.12,
                help: "Contact noise radiated directly (inter-harmonic air)."),
            Row("bow_tors_c", "torsion coupling", 0.0, 0.5, 0.0,
                help: "Slip → torsional wave → returned micro-slips: period-locked harmonic HF regeneration at the source. 0 = off."),
            Row("bow_tors_g", "torsion return", 0.5, 0.98, 0.85,
                help: "Torsional loop reflection/loss (higher = stronger ripple)."),
            Row("bow_tors_ratio", "torsion speed ×", 3.5, 8.0, 5.2,
                help: "Torsional/transverse wave-speed ratio (gut ≈ 5)."),
            Row("bow_age_a", "contact aging", 0.0, 0.9, 0.0,
                help: "Rate-and-state friction: static grip grows with stick time — a freshly-slipped contact is weak, so slips collect at one phase per period (cleaner, more locked slip pattern). 0 = off."),
            Row("bow_age_ms", "aging time (ms)", 0.2, 5.0, 1.5,
                help: "Contact re-adhesion timescale (fraction of a period = strongest phase discipline)."),
            Row("bow_cr_w", "contact spread", 0.0, 0.5, 0.0,
                help: "Continuum contact: grip-limit spread across the hair band — partial release near the boundary (adds bow-surface flutter texture; darkens quiet mids). 0 = off."),
            Row("bow_cr_ms", "release time (ms)", 0.0, 0.15, 0.0,
                help: "Continuum contact: release-front crossing time (release-only; capture snaps). Large values distort the quiet duty cycle. 0 = off."),
        ]),
        ("Playing ranges", [
            Row("bow_v_lo", "speed floor", 0.02, 0.15, 0.065,
                help: "Bow velocity at expression 0 (above the lift zone)."),
            Row("bow_v_hi", "speed ceiling", 0.1, 0.5, 0.23,
                help: "Bow velocity at full expression."),
            Row("bow_live_beta_lo", "pos: bridge end", 0.02, 0.1, 0.05,
                help: "β at pos 0 — sul ponticello limit."),
            Row("bow_live_beta_hi", "pos: tasto end", 0.12, 0.33, 0.24,
                help: "β at pos 1 — sul tasto limit."),
            Row("bow_live_press_under", "press-0 undershoot", 0.2, 1.0, 0.55,
                help: "Press 0 dips to this ×fmin — the flautando/whistle edge."),
            Row("bow_live_press_over", "press-1 overshoot", 1.0, 1.8, 1.25,
                help: "Press 1 pushes to this ×fmax — the grit edge."),
            Row("bow_expr_lift", "lift zone", 0.0, 0.4, 0.2,
                help: "Expression below this fades the bow off the string entirely."),
            Row("bow_f_cap", "force cap", 1.0, 8.0, 4.0,
                help: "Hard force guard over every push (tilt/register)."),
        ]),
        ("Jawari taraf (modal contact)", [
            Row("bow_jtaraf_on", "armed", 0, 1, 0, step: 1,
                help: "The tanpura-evolution block: modal steel strings over grazing jawari bones on the raga-lattice rows. 0 = off (zero cost). Live config runs at 48 kHz, ~half a core when armed."),
            Row("bow_jt_gain", "level", 0.0, 3.0, 0.3,
                help: "Output mix of the jawari web (the gap-law calibration landed at 0.3)."),
            Row("bow_jt_drive", "drive", 0.001, 0.3, 0.03,
                help: "Bridge-force coupling INTO the strings — sets the graze operating point: too low = no cascade, too high = over-drained/linearized."),
            Row("bow_jt_apex", "graze depth", 2e-6, 5e-5, 1e-5,
                help: "Bone protrusion. The evolution lives at the grazing knee — deep press linearizes (sparkle only), too shallow never engages."),
            Row("bow_jt_alpha", "contact law", 1.0, 2.0, 1.5,
                help: "Contact stiffness exponent. 1.5 = Hertz (fast sqrt path — the live default); other values cost more CPU."),
            Row("bow_jt_norm", "level norm", 0.0, 1.5, 1.0,
                help: "Per-string t60-response normalization — evens the driven level across scale degrees (long-ring rows charge hotter); 0 = raw physics."),
        ]),
        ("Taraf (sympathetic)", [
            Row("bow_taraf_Z", "coupling Z", 0.0, 0.05, 0.0033,
                help: "Junction impedance per string (passive wave junction — structurally stable). Small = long free ring; large = strong charge but the bridge drains it. 0 = no taraf."),
            Row("bow_taraf_gain", "ring level", 0.0, 12.0, 1.0,
                help: "Taraf output weight (√count-normalized; zero loop-gain impact)."),
            Row("bow_taraf_dir", "ring radiation", 0.0, 2.0, 0.5,
                help: "Ringing-string radiation tap through the body — a passive junction cannot radiate free decay; this is how the wash reaches the air."),
            Row("bow_taraf_pol_cents", "polarization (¢)", 0.0, 8.0, 3.0,
                help: "Two polarizations per string, golden-ratio detuned — the slow near-unison shimmer of a real string pair."),
            Row("bow_taraf_damp", "HF damping", 0.0, 1.0, 0.5,
                help: "f² string damping — high partials of the ring die faster."),
            Row("bow_taraf_bright", "brightness", 0.0, 1.0, 0.5,
                help: "Termination corner of the ring (0 = dark, 1 = wiry)."),
            Row("bow_taraf_inharm", "inharmonicity", 0.0, 0.5, 0.1,
                help: "Stiff-wire dispersion — upper ring partials sharp."),
            Row("bow_taraf_t60", "ring length ×", 0.1, 6.0, 1.0,
                help: "Scales the string table's per-string decay times (capped at 8 s — energy discipline)."),
            Row("bow_taraf_jawari", "jawari buzz", 0.0, 2.0, 0.0,
                help: "Flat-bridge contact buzz on the taraf (0 = the plain bridge of a viola d'amore / hardanger; >0 = sitar/sarangi direction)."),
            Row("bow_open_Z", "open-string coupling", 0.0, 0.04, 0.0,
                help: "The un-bowed MAIN GUT strings (mandra Pa + mandra Sa) as sympathetics — the real sarangi's LF halo. 0 = off."),
            Row("bow_open_gain", "open-string ring", 0.0, 3.0, 0.0,
                help: "Radiated level of the open gut pair."),
            Row("bow_open_t60", "open ring (s)", 0.5, 5.0, 2.5,
                help: "Gut open-string decay."),
            Row("bow_open_damp", "open HF damp", 0.3, 1.0, 0.85,
                help: "Gut kills high partials fast — the warm dark ring."),
            Row("bow_taraf_duck", "driven-tap duck", 0.0, 1.0, 1.0,
                help: "While a taraf string is DRIVEN at a partial coincidence with the bowed note, its direct tap ducks to this weight (the junction still radiates the driven response; the tap owns the free ring). 1 = off."),
        ]),
        ("Articulation", [
            Row("bow_place_ms", "place (ms)", 0, 120, 35,
                help: "Bow-set hold before the draw: force on, velocity 0 (static stick). 0 = instant legacy attack."),
            Row("bow_draw_ms", "draw (ms)", 5, 200, 60,
                help: "Velocity rise for a GENTLE (legato) attack — the pre-Helmholtz crunch window."),
            Row("bow_draw_min_ms", "sharp draw (ms)", 3, 60, 8,
                help: "Velocity rise for a maximally SHARP attack: a hard-press onset draws this fast (accent/martelé)."),
            Row("bow_attack_bite", "attack bite", 0, 4, 2.0,
                help: "How hard a sharp onset over-forces: the high force under a fast velocity onset drives the friction loop's own upper-harmonic multi-slip burst. 0 = off (plain place-then-draw). Sharpness = press above the threshold."),
            Row("bow_attack_bite_ms", "bite decay (ms)", 10, 200, 60,
                help: "How long the onset over-force lasts before settling into the steady note."),
            Row("bow_attack_thresh", "bite threshold", 0.0, 1.0, 0.5,
                help: "Press below this = legato (no bite); above it the attack sharpens toward the full bite at press 1."),
            Row("bow_vib_cents", "vibrato depth (¢)", 0, 60, 25,
                help: "Aftertouch → finger vibrato peak depth."),
            Row("bow_vib_hz", "vibrato rate (Hz)", 3, 9, 5.5,
                help: "Vibrato frequency (real players ~5–7 Hz)."),
        ]),
        ("Radiation & output", [
            Row("bow_rad_hp", "radiation HP (Hz)", 50, 600, 200,
                help: "A finite radiator can't radiate below its size — butter-2 high-pass corner."),
            Row("bow_rad_lp", "radiation LP (Hz)", 500, 16000, 8000,
                help: "Air/skin HF absorption — one-pole corner."),
            Row("bow_w", "excitation level", 0.2, 2.5, 1.196,
                help: "Bridge-force weight (pre-radiation drive)."),
            Row("bow_live_trim", "output trim", 0.01, 0.5, 0.175,
                help: "Final level (matched to the Sarangi Live instrument)."),
            Row("bow_rev_mix", "room mix", 0.0, 0.3, 0.08,
                help: "Slight mono room (no stereo width — the L/R split stays pan-invariant). 0 = bone dry."),
            Row("bow_rev_rt60", "room decay (s)", 0.2, 2.0, 1.0,
                help: "Room reverberation time."),
        ]),
    ]

    @State private var expanded: Set<String> = ["Body (formula modes)"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("String instrument").font(.headline)
                Spacer()
                if stringStore.dirty {
                    Button("Default (Sarangi Live)") { stringStore.resetToDefault() }
                        .font(.caption)
                        .help("Clear every override — back to the bundled bowed_string.json, the Sarangi Live default")
                }
            }
            Text("Pure physics — every value is a formula input, applied live. "
                 + "Taraf tuning (pitches/gains/decays) is the Tarab tab; this "
                 + "panel is the physics. Body/string edits shift intonation a "
                 + "few cents (the pitch tables were calibrated at the saved "
                 + "physics). Double-click a row label to reset that value.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(Self.groups, id: \.0) { (name, rows) in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(name) },
                    set: { if $0 { expanded.insert(name) } else { expanded.remove(name) } })) {
                    VStack(spacing: 2) {
                        ForEach(rows) { row in
                            StringParamRow(row: row)
                                .environmentObject(stringStore)
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text(name).font(.subheadline).bold()
                }
            }
        }
    }
}

struct StringParamRow: View {
    @EnvironmentObject var stringStore: StringParamStore
    let row: StringParamsView.Row

    var body: some View {
        HStack(spacing: 8) {
            Text(row.label)
                .frame(width: 130, alignment: .leading).font(.caption)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { stringStore.reset(row.id) }
            Slider(value: binding, in: bounds)
            Text(format(currentValue))
                .frame(width: 52, alignment: .trailing)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help(row.help)
    }

    /// Artifact value when the key exists there, else the authored default —
    /// the same fallback `BowParams.v` uses at build time.
    private var currentValue: Double {
        stringStore.values[row.id] ?? row.def
    }

    /// The authored range is an AUTHORING HINT, the artifact is truth: a fit
    /// round moves values wherever the physics wants them, so a loaded value
    /// outside [lo, hi] widens the slider instead of being snap-clamped by
    /// the first drag (a clamp would ship live and get persisted).
    private var bounds: ClosedRange<Double> {
        let v = currentValue
        guard v < row.lo || v > row.hi else { return row.lo...row.hi }
        let pad = max((row.hi - row.lo) * 0.25, abs(v) * 0.25)
        return min(row.lo, v - pad)...max(row.hi, v + pad)
    }

    private var binding: Binding<Double> {
        let base = stringStore.binding(for: row.id, default: row.def)
        guard let step = row.step else { return base }
        return Binding(get: { base.wrappedValue },
                       set: { base.wrappedValue = ($0 / step).rounded() * step })
    }

    private func format(_ v: Double) -> String {
        if row.step != nil { return String(format: "%.0f", v) }
        if abs(v) < 0.001, v != 0 { return String(format: "%.1e", v) }
        return row.hi >= 100 ? String(format: "%.0f", v)
                             : String(format: "%.3f", v)
    }
}
