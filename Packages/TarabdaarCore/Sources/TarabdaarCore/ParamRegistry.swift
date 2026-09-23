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
/// changing it updates the affected mechanism. `.perNote` = a mechanism with
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
            return "one shared control for the affected voice, taraf bank or processing stage"
        case .perNote:
            return "each sounding note evaluates it with its own state; attack-family values are captured at onset, so an edit changes subsequent notes"
        }
    }

    /// Full legend text (the docs/parameters.md scope table).
    public var explanation: String {
        switch self {
        case .global:
            return "ONE shared mechanism — the bridge/body, the taraf bank, the room/FX/output chain, the shared string physics, or a control axis every note rides together. Changing it updates that mechanism across its affected voice, bank or processing stage."
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
    case onset = "onset"
    case live
    case inPlace = "in-place"
    case rebuild
    case hybrid

    public var label: String { rawValue }

    /// One-line row summary (the Parameters tab's per-row description).
    public var summary: String {
        switch self {
        case .onset:
            return "updates immediately for the next note; each onset captures its value"
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
        case .onset:
            return "A live binding target captured independently at each note onset. Changes do not reshape held notes or rebuild the engine."
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

/// WHERE a `.live` value goes — the other thing the one apply path
/// (`AppController.applyParamToVoice`) switches on, so a control-layer
/// knob is one registry entry and no special case.
public enum ParamTarget: Sendable {
    /// The String voice's control cache (`AudioEngine.setStringControlParam`).
    case stringVoice
    /// The strike→acceleration blend window (`ControlAxisEvaluator`), relayed to the iPad.
    case strikeWindow
    /// Additional Mac-side smoothing of an acceleration control.
    case accelerationSmoothing(InputDimension)
    /// The strum chord's expression (`StrumController.setExpression`).
    case strumExpression
    /// The strum chord's accel trigger (`StrumController.setAccelThreshold`).
    case strumThreshold
    /// The glide queue (`GlideSequencer.setControl`).
    case glideQueue
    /// The fret field's pitch warp: the glide queue, the Mac pad, the iPad.
    case fretWarp
    /// The pitch accent (`AudioEngine.setPitchAccent`): expression dips between frets.
    case pitchAccent
    /// Performance-history attenuation of the taraf radiation.
    case tarafAdaptation
}

/// One INSERT POINT of a repeated parameter block — the FX rack's four
/// points. `keyPrefix` matches `SarangiKit.FXPoint.keyPrefix`; a derived
/// key is the prefix plus a template knob (`fx_voice_rev_mix`).
public struct FXInsertPoint: Identifiable, Equatable, Sendable {
    /// `SarangiKit.FXPoint` raw value — the signal order.
    public let index: Int
    /// Display name ("Voice → Taraf").
    public let name: String
    public let keyPrefix: String
    /// What this point processes (the tail of the toggles' help text).
    public let what: String
    /// One-line caption for the surfaces that show the point (the FX tab
    /// panel, the Parameters tab's insert header, the docs' point table).
    public let blurb: String

    public var id: Int { index }
    public init(index: Int, name: String, keyPrefix: String,
                what: String, blurb: String) {
        self.index = index; self.name = name
        self.keyPrefix = keyPrefix; self.what = what; self.blurb = blurb
    }
    /// The registry key of one template knob at this point.
    public func key(_ knob: String) -> String { keyPrefix + knob }
}

/// ONE KNOB of an insert definition — described once, instantiated at
/// every point. `knob` is the field suffix (what
/// `SarangiKit.FXSettings.apply(field:value:)` parses).
public struct FXKnob: Sendable {
    public let knob: String, label: String
    public let lo: Double, hi: Double, def: Double
    public let step: Double?
    /// What changes, followed by the meaning of the two ends of the range.
    public let effect: String
    public let low: String
    public let high: String
    /// Plain-text help shared by tooltips, search and documentation.
    public var help: String { "\(effect)\nLow: \(low)\nHigh: \(high)" }

    public init(_ knob: String, _ label: String,
                _ lo: Double, _ hi: Double, _ def: Double,
                step: Double? = nil, effect: String, low: String, high: String) {
        self.knob = knob; self.label = label
        self.lo = lo; self.hi = hi; self.def = def
        self.step = step
        self.effect = effect; self.low = low; self.high = high
    }
}

/// Where a derived spec came from: which insert point, which knob.
public struct ParamInsert: Equatable, Sendable {
    public let point: FXInsertPoint
    public let knob: String
    /// The knob's own label, WITHOUT the point ("EQ 125 Hz (dB)"). The
    /// spec's `label` qualifies it with the point, because it is read out
    /// of context in the tilt/composite menus, where four identical "EQ
    /// 125 Hz (dB)" rows would be unpickable; a surface that already
    /// groups by point (the Parameters tab's insert sections, the docs'
    /// insert table) shows this one instead.
    public let knobLabel: String
    public init(point: FXInsertPoint, knob: String, knobLabel: String) {
        self.point = point; self.knob = knob; self.knobLabel = knobLabel
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
    /// `.live` only: where the value goes.
    public let target: ParamTarget
    /// `.hybrid` only: the resting value as a FRACTION of the build-time
    /// headroom — 1 = the fitted depth, 0 = off.
    public let restFraction: Double?
    /// Global vs per-note — see `ParamScope`.
    public let scope: ParamScope
    /// Set on a spec DERIVED from an insert definition instantiated at
    /// several points (the FX rack: one insert, four points) — which
    /// point, and which template knob. nil for an ordinary parameter.
    /// The UI and the docs group by it; the key itself is unchanged, so
    /// presets and bindings never see the difference.
    public let insert: ParamInsert?
    /// Explicit timing override for keys whose `.live` ROUTING hides a
    /// slow re-mount (the tanpura scale-shape family); nil = derive from
    /// the apply strategy + `inPlaceKeys` (see `timing`).
    public let timingOverride: ParamTiming?
    /// What changes, followed by the meaning of the two ends of the range.
    public let effect: String
    public let low: String
    public let high: String
    /// Plain-text help shared by tooltips, search and documentation.
    public var help: String { "\(effect)\nLow: \(low)\nHigh: \(high)" }

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

    /// Unambiguous name outside a parameter section (bindings and composites).
    public var qualifiedLabel: String {
        insert == nil ? "\(group) · \(label)" : label
    }

    public var id: String { key }

    /// The value held to the registry's range — the ONE clamp for a knob.
    public func clamp(_ v: Double) -> Double { min(max(v, lo), hi) }

    public init(_ key: String, _ label: String, group: String,
                _ lo: Double, _ hi: Double, _ def: Double,
                step: Double? = nil, apply: ParamApply = .rebuild,
                target: ParamTarget = .stringVoice,
                restFraction: Double? = nil, timing: ParamTiming? = nil,
                scope: ParamScope = .global,
                insert: ParamInsert? = nil,
                effect: String, low: String, high: String) {
        self.key = key; self.label = label; self.group = group
        self.lo = lo; self.hi = hi; self.def = def; self.step = step
        self.apply = apply; self.target = target
        self.restFraction = restFraction
        self.timingOverride = timing
        self.scope = scope; self.insert = insert
        self.effect = effect; self.low = low; self.high = high
    }

    /// True when the value applies instantly (no engine rebuild) for at
    /// least part of its range.
    public var isLive: Bool { apply != .rebuild }
}

public enum ParamRegistry {

    // MARK: - Groups

    public static let groups: [(name: String, params: [ParamSpec])] = [

        ("String · Bow stroke", [
            ParamSpec("bow_expr", "expression", group: "String · Bow stroke",
                      0, 1, 0.251, apply: .live,
                      effect: "Controls the played String voice through bow speed and force; it does not turn down an already ringing taraf.",
                      low: "A lighter stroke; below the lift-zone threshold the bow fades toward silence.",
                      high: "A faster, stronger stroke with greater loudness and excitation."),
            ParamSpec("bow_press", "bow pressure", group: "String · Bow stroke",
                      0, 1, 0.562, apply: .live,
                      effect: "Sets bow force between the playable stroke's lower and upper force limits.",
                      low: "Light contact, with airy or whistling tone near the lower edge.",
                      high: "Pressed contact, with more grit or choking near the upper edge."),
            ParamSpec("bow_pos", "bow position (brightness)", group: "String · Bow stroke",
                      0, 1, 0.45, apply: .live,
                      effect: "Sets the bow's distance from the bridge within the configured position range.",
                      low: "Closer to the bridge, usually brighter and edgier.",
                      high: "Farther toward the fingerboard, usually rounder and softer."),
            ParamSpec("bow_tilt", "bow tilt", group: "String · Bow stroke",
                      0, 1, 0.331, apply: .live,
                      effect: "Changes stroke color by shifting bow position and force together. About 0.331 is neutral.",
                      low: "Moves away from the bridge and reduces force for a softer color.",
                      high: "Moves toward the bridge and increases force for a brighter, more pressed color."),
        ]),

        ("String · Bow ranges", [
            ParamSpec("bow_v_lo", "speed floor", group: "String · Bow ranges",
                      0.02, 0.15, 0.065,
                      effect: "Sets the minimum bow speed in the expression response above the lift zone.",
                      low: "Allows a slower, quieter stroke at the bottom of the active range.",
                      high: "Raises the speed floor, so low expression still produces a firmer stroke."),
            ParamSpec("bow_v_hi", "speed ceiling", group: "String · Bow ranges",
                      0.1, 0.5, 0.23,
                      effect: "Sets the upper bow-speed reference used by the expression response.",
                      low: "Restrains the speed available at strong expression.",
                      high: "Allows faster, more energetic strokes; fitted dynamics may extend beyond this reference."),
            ParamSpec("bow_live_beta_lo", "pos: bridge end", group: "String · Bow ranges",
                      0.02, 0.1, 0.05,
                      effect: "Sets the bridge-side endpoint of bow position as a fraction of string length.",
                      low: "Position 0 reaches closer to the bridge, increasing edge and brightness.",
                      high: "Position 0 stays farther from the bridge, softening that extreme."),
            ParamSpec("bow_live_beta_hi", "pos: tasto end", group: "String · Bow ranges",
                      0.12, 0.33, 0.24,
                      effect: "Sets the fingerboard-side endpoint of bow position as a fraction of string length.",
                      low: "Position 1 stays closer to the bridge.",
                      high: "Position 1 reaches farther over the fingerboard, giving a softer extreme."),
            ParamSpec("bow_live_press_under", "press-0 undershoot", group: "String · Bow ranges",
                      0.2, 1.0, 0.55,
                      effect: "Sets pressure 0 as a multiple of the minimum force needed for stable bowing.",
                      low: "Falls farther below stable capture, encouraging airy or whistling strokes.",
                      high: "At 1, pressure 0 reaches the calculated stable-bowing floor."),
            ParamSpec("bow_live_press_over", "press-1 overshoot", group: "String · Bow ranges",
                      1.0, 1.8, 1.25,
                      effect: "Sets pressure 1 as a multiple of the calculated upper bow-force limit.",
                      low: "At 1, the pressure range ends at that limit.",
                      high: "Extends into over-pressed, gritty contact; the force cap still applies."),
            ParamSpec("bow_expr_lift", "lift zone", group: "String · Bow ranges",
                      0.0, 0.4, 0.2,
                      effect: "Sets the expression range in which bow force and speed fade toward zero.",
                      low: "A narrow fade zone; 0 disables this extra lift-to-silence law.",
                      high: "A wider fade zone, leaving less of the expression range for full contact."),
            ParamSpec("bow_f_cap", "force cap", group: "String · Bow ranges",
                      1.0, 8.0, 4.0,
                      effect: "Caps bow force after pressure, tilt, register compensation and attack bite are applied.",
                      low: "Restrains force sooner, limiting heavy attacks and pressed strokes.",
                      high: "Permits stronger force peaks; it does not add force by itself."),
        ]),

        ("String · Attack", [
            ParamSpec("bow_place_ms", "gentle placement (ms)", group: "String · Attack",
                      0, 120, 35,
                      scope: .perNote,
                      effect: "Sets the delay before drawing the bow on a gentle attack. Attack sharpness progressively removes this delay.",
                      low: "The draw starts sooner; 0 starts it immediately while retaining the draw ramp.",
                      high: "A longer placement phase before the gentle stroke speaks."),
            ParamSpec("bow_draw_ms", "gentle draw (ms)", group: "String · Attack",
                      5, 200, 60,
                      scope: .perNote,
                      effect: "Sets the bow-speed and force rise time at attack sharpness 0.",
                      low: "A quicker gentle attack.",
                      high: "A slower swell into the sustained stroke; sharp attacks use their separate ramp settings."),
            ParamSpec("bow_draw_min_ms", "sharp draw (ms)", group: "String · Attack",
                      3, 60, 60,
                      scope: .perNote,
                      effect: "Sets the bow-speed rise time at attack sharpness 1, with intermediate sharpness interpolating from the gentle draw time.",
                      low: "A faster draw and more abrupt onset.",
                      high: "A slower draw and softer onset, even with high sharpness."),
            ParamSpec("bow_attack_bite", "attack bite", group: "String · Attack",
                      0, 4, 0.0,
                      scope: .perNote,
                      effect: "Adds a temporary bow-force boost on sharp attacks, scaled by captured attack sharpness and constrained by the force cap.",
                      low: "Less force accent; 0 disables the boost.",
                      high: "A stronger pressed burst and more upper-harmonic bite at onset."),
            ParamSpec("bow_attack_bite_ms", "bite decay (ms)", group: "String · Attack",
                      10, 200, 60,
                      scope: .perNote,
                      effect: "Sets the decay time shared by sharp-attack force bite, bridgeward position shift and speed boost.",
                      low: "The attack gesture recedes quickly into the sustained bow.",
                      high: "The accent and contact-color shift persist longer."),
            ParamSpec("bow_attack_fms", "sharp force ramp (ms)", group: "String · Attack",
                      2, 60, 15,
                      scope: .perNote,
                      effect: "Sets the bow-force rise time at attack sharpness 1; intermediate sharpness blends from the gentle draw time.",
                      low: "Pressure builds more quickly, giving a firmer onset.",
                      high: "Pressure builds more gradually, softening the attack."),
            ParamSpec("bow_attack_sharpness", "attack sharpness", group: "String · Attack",
                      0.0, 1.0, 0.0, apply: .live,
                      timing: .onset, scope: .perNote,
                      effect: "Selects the attack shape independently at each new note. Held notes retain the shape captured at onset.",
                      low: "Toward 0, uses the placement delay and gentle draw ramps.",
                      high: "Toward 1, uses the sharp draw and force ramps plus any configured bite, position shift and speed boost."),
            ParamSpec("bow_attack_beta", "attack: toward bridge", group: "String · Attack",
                      0.0, 0.7, 0.0, scope: .perNote,
                      effect: "Moves the bow toward the bridge during a sharp attack, scaled by captured sharpness and fading with bite decay.",
                      low: "Less temporary movement; 0 leaves attack position unchanged.",
                      high: "A larger bridgeward shift for a brighter, more forceful attack color."),
            ParamSpec("bow_attack_speed_db", "attack: speed boost (dB)", group: "String · Attack",
                      0.0, 12.0, 0.0, scope: .perNote,
                      effect: "Temporarily boosts bow speed during a sharp attack, scaled by captured sharpness and fading with bite decay.",
                      low: "Less extra speed; 0 disables the boost.",
                      high: "A faster, more energetic onset before returning to the sustained speed."),
            ParamSpec("bow_tnoise", "force-change grain", group: "String · Attack",
                      0.0, 4.0, 0.0, scope: .perNote,
                      effect: "Adds friction grain when bow force changes, including during an attack.",
                      low: "Less force-change noise; 0 disables this contribution.",
                      high: "More transient grain as the bow force moves; steady contact noise has separate controls."),
            ParamSpec("bow_settle_db", "onset settle (dB)", group: "String · Attack",
                      0, 12, 7.0,
                      scope: .perNote,
                      effect: "Temporarily eases bow speed after an attack, then recovers to the sustained stroke.",
                      low: "A smaller post-attack dip; 0 disables settling.",
                      high: "A deeper dip, reducing the initial note's sustained energy after its attack."),
            ParamSpec("bow_settle_ms", "settle decay (ms)", group: "String · Attack",
                      30, 500, 130,
                      scope: .perNote,
                      effect: "Sets the recovery time of the post-attack bow-speed dip. Requires onset settle above 0.",
                      low: "The bow regains sustained speed sooner.",
                      high: "The eased-down phase lasts longer before recovering."),
            ParamSpec("bow_settle_sharp", "sharp settle exemption", group: "String · Attack",
                      0.0, 1.0, 0.0,
                      scope: .perNote,
                      effect: "Reduces post-attack settling for sharp attacks, using each note's captured sharpness.",
                      low: "At 0, all attack shapes receive the same settle depth.",
                      high: "At 1, fully sharp attacks skip the dip while gentle attacks retain it."),
        ]),

        ("String · Bow recovery", [
            ParamSpec("bow_grip_beta", "bow toward bridge", group: "String · Bow recovery",
                      0.0, 0.6, 0.35,
                      scope: .perNote,
                      effect: "Moves the bow toward the bridge when recovery detects an overtone lock instead of the intended fundamental. Heavy pressure reduces this movement.",
                      low: "Less corrective movement; 0 disables this lever.",
                      high: "A stronger bridgeward correction, helping move off contact positions that sustain an overtone lock."),
            ParamSpec("bow_grip_v_db", "bow speed change (dB)", group: "String · Bow recovery",
                      -12.0, 12.0, -4.0,
                      scope: .perNote,
                      effect: "Changes bow speed during overtone-lock recovery. Zero leaves speed unchanged.",
                      low: "Negative values slow the bow, lowering the force needed for stable capture.",
                      high: "Positive values speed the bow and may deepen an overtone lock rather than cure it."),
            ParamSpec("bow_grip_db", "bow force change (dB)", group: "String · Bow recovery",
                      -12.0, 12.0, 0.0,
                      scope: .perNote,
                      effect: "Changes bow force during overtone-lock recovery. Zero leaves force unchanged.",
                      low: "Negative values reduce pressure during recovery.",
                      high: "Positive values increase pressure; extra force can strengthen an overtone lock, so this is not a recovery-strength scale."),
            ParamSpec("bow_grip_thresh", "engage below", group: "String · Bow recovery",
                      0.05, 5.0, 1.0,
                      scope: .perNote,
                      effect: "Engages recovery when fundamental power relative to the strongest second-to-fourth harmonic stays below this ratio.",
                      low: "Requires a more severe loss of the fundamental before intervening.",
                      high: "Intervenes more readily, including on less pronounced overtone dominance."),
            ParamSpec("bow_grip_release", "release above", group: "String · Bow recovery",
                      0.05, 8.0, 1.5,
                      scope: .perNote,
                      effect: "Releases recovery when fundamental dominance stays above this ratio for the hold time. The effective value is at least the engage threshold.",
                      low: "Allows release with weaker fundamental dominance.",
                      high: "Requires a more clearly restored fundamental before release; a second failed recovery can latch for the note."),
            ParamSpec("bow_grip_wait_ms", "attack protection (ms)", group: "String · Bow recovery",
                      10, 500, 150,
                      scope: .perNote,
                      effect: "Sets the protected attack interval before overtone-lock recovery may engage.",
                      low: "Allows correction soon after onset, with more chance of reacting to a normal attack transient.",
                      high: "Gives the attack longer to settle before intervening."),
            ParamSpec("bow_grip_confirm_ms", "confirm lock (ms)", group: "String · Bow recovery",
                      0, 500, 60,
                      scope: .perNote,
                      effect: "Sets how long fundamental dominance must stay below the engage threshold before recovery starts.",
                      low: "Responds to brief dips; 0 adds no confirmation delay.",
                      high: "Requires a persistent overtone lock, reducing reactions to short disturbances."),
            ParamSpec("bow_grip_ms", "engage time (ms)", group: "String · Bow recovery",
                      2, 200, 30,
                      scope: .perNote,
                      effect: "Sets the time constant for moving into the configured recovery position, speed and force changes.",
                      low: "Applies correction more quickly.",
                      high: "Introduces correction more gradually."),
            ParamSpec("bow_grip_rel_ms", "release time (ms)", group: "String · Bow recovery",
                      10, 1000, 250,
                      scope: .perNote,
                      effect: "Sets the time constant for returning from recovery to the player's bow settings.",
                      low: "Returns to the played stroke quickly.",
                      high: "Fades the correction away more slowly."),
            ParamSpec("bow_grip_hold_ms", "stable hold (ms)", group: "String · Bow recovery",
                      0, 1000, 200,
                      scope: .perNote,
                      effect: "Sets how long the fundamental must remain above the release threshold before recovery may let go.",
                      low: "Releases sooner after capture returns.",
                      high: "Requires a longer stable interval, keeping the correction engaged longer."),
        ]),

        ("String · Sustain motion", [
            ParamSpec("bow_vib_cents", "vibrato depth (¢)", group: "String · Sustain motion",
                      0, 60, 25, apply: .hybrid, restFraction: 0.0,
                      scope: .perNote,
                      effect: "Sets peak pitch-modulation depth in cents for the String voice's vibrato control. It rests at 0; rate is set separately.",
                      low: "Narrower pitch movement; 0 disables this added modulation.",
                      high: "Wider excursions above and below the played pitch."),
            ParamSpec("bow_vib_hz", "vibrato rate (Hz)", group: "String · Sustain motion",
                      3, 9, 5.5,
                      scope: .perNote,
                      effect: "Sets the cycle rate of the String voice's vibrato modulation. Has no audible effect when vibrato depth is 0.",
                      low: "Slower pitch oscillations.",
                      high: "Faster pitch oscillations; it does not increase their depth."),
            ParamSpec("bow_drift_cents", "pitch drift (¢)", group: "String · Sustain motion",
                      0, 8, 0.55,
                      scope: .perNote,
                      effect: "Sets the scale of slow random pitch wander independently for each held String note, separate from vibrato.",
                      low: "Steadier pitch; 0 disables this pitch wander.",
                      high: "Wider irregular pitch motion and more shimmer as harmonics cross body resonances."),
            ParamSpec("bow_drift_hz", "drift bandwidth (Hz)", group: "String · Sustain motion",
                      0.2, 6, 1.2,
                      scope: .perNote,
                      effect: "Sets the bandwidth of the pitch, bow-speed and bow-force drift processes.",
                      low: "Slow, leisurely wandering.",
                      high: "Quicker random fluctuations; this is not a periodic vibrato rate."),
            ParamSpec("bow_drift_db", "speed drift (dB)", group: "String · Sustain motion",
                      0, 3, 0.15,
                      scope: .perNote,
                      effect: "Sets the size of random bow-speed fluctuations in dB, alongside pitch and force drift.",
                      low: "Steadier bow speed; 0 disables this speed wander.",
                      high: "Greater irregular changes in stroke energy and loudness."),
            ParamSpec("bow_drift_force_db", "force drift (dB)", group: "String · Sustain motion",
                      0, 4, 0.3,
                      scope: .perNote,
                      effect: "Sets the size of random bow-force fluctuations in dB, alongside pitch and speed drift.",
                      low: "Steadier pressure; 0 disables this force wander.",
                      high: "Greater irregular pressure changes and more changing contact color."),
        ]),

        ("String · Slide response", [
            ParamSpec("bow_glide_dip_db", "glide dip (dB)", group: "String · Slide response",
                      0, 12, 5.0,
                      scope: .perNote,
                      effect: "Lightens bow speed and, to a lesser extent, force while the played pitch slides within a note.",
                      low: "A smaller transition dip; 0 disables this lightening.",
                      high: "A deeper dip through moving-pitch transitions, recovering as the slide ends."),
            ParamSpec("bow_glide_dip_rate", "dip half-rate (¢/s)", group: "String · Slide response",
                      100, 5000, 900,
                      scope: .perNote,
                      effect: "Sets the pitch speed in cents per second at which slide lightening reaches half its configured depth.",
                      low: "Gentler slides produce substantial lightening.",
                      high: "Requires faster slides for the same dip; it does not set the glide speed itself."),
            ParamSpec("bow_slide_noise", "slide noise", group: "String · Slide response",
                      0.0, 0.02, 0.008,
                      scope: .perNote,
                      effect: "Sets finger-friction noise injected into the string when pitch movement accelerates, stops or reverses. Constant-speed slides produce little drive.",
                      low: "Quieter scrape; 0 removes this noise.",
                      high: "More audible finger scrape shaped by the string and body."),
            ParamSpec("bow_slide_acc", "noise half-accel (¢/s²)", group: "String · Slide response",
                      5000, 100000, 25000,
                      scope: .perNote,
                      effect: "Sets the pitch acceleration needed for half-strength slide noise, above the movement floor. Requires slide noise above 0.",
                      low: "Noise responds to gentler starts, stops and turns.",
                      high: "Sharper changes of finger speed are needed for the same noise level."),
            ParamSpec("bow_slide_dull", "slide dulling", group: "String · Slide response",
                      0.0, 0.8, 0.35,
                      scope: .perNote,
                      effect: "Lowers string-loss cutoffs while the finger moves, making slides temporarily darker.",
                      low: "Less moving-finger absorption; 0 keeps the cutoffs unchanged by slides.",
                      high: "Stronger darkening during motion, with brightness returning when the finger stops."),
            ParamSpec("bow_slide_rate", "slide half-rate (¢/s)", group: "String · Slide response",
                      100, 4000, 900,
                      scope: .perNote,
                      effect: "Sets the pitch speed needed for half-strength slide dulling, above the movement floor. Requires slide dulling above 0.",
                      low: "Gentler slides darken the string noticeably.",
                      high: "Requires faster slides for the same darkening."),
        ]),

        ("String · Friction", [
            ParamSpec("bow_mu_s", "static friction", group: "String · Friction",
                      0.4, 1.2, 0.8,
                      effect: "Sets the bow's static friction coefficient, governing how strongly rosin can hold the string.",
                      low: "Weaker stick grip and a smaller gap from sliding friction.",
                      high: "Stronger stick grip and a larger stick/slip contrast, depending on dynamic friction."),
            ParamSpec("bow_mu_d", "dynamic friction", group: "String · Friction",
                      0.1, 0.6, 0.3,
                      effect: "Sets friction while the string slips under the bow; its gap from static friction shapes bow capture.",
                      low: "Less sliding drag and a larger stick/slip contrast.",
                      high: "More sliding drag and a smaller contrast when static friction is held fixed."),
            ParamSpec("bow_v0", "friction corner", group: "String · Friction",
                      0.05, 0.5, 0.2,
                      effect: "Sets the relative-speed scale over which friction changes from sticking to sliding.",
                      low: "A sharper transition, often giving a brighter attack edge.",
                      high: "A more gradual transition across a wider range of sliding speeds."),
            ParamSpec("bow_Zt", "torsional impedance ×", group: "String · Friction",
                      0.0, 15.0, 7.9,
                      effect: "Sets torsional impedance at the bow contact relative to transverse string impedance.",
                      low: "More rotational give at the contact.",
                      high: "Less rotational give; the effective contact impedance approaches the transverse value."),
            ParamSpec("bow_noise", "contact noise", group: "String · Friction",
                      0.0, 0.4, 0.1,
                      effect: "Sets bow-hair noise fed back into the string's friction loop.",
                      low: "Less recirculating grain; 0 removes this noise source.",
                      high: "Stronger textured contact noise shaped by the string and body."),
            ParamSpec("bow_noise_dir", "direct noise", group: "String · Friction",
                      0.0, 0.4, 0.12,
                      effect: "Sets contact noise radiated directly alongside the pitched String voice.",
                      low: "Less audible air between harmonics; 0 removes this direct contribution.",
                      high: "More audible bow hiss and grain without increasing the recirculating noise setting."),
        ]),

        ("String · Damping", [
            ParamSpec("bow_gut_g", "round-trip retention", group: "String · Damping",
                      0.99, 1.0, 0.998,
                      effect: "Sets the fraction of string motion retained on each round trip.",
                      low: "More energy loss and a shorter, deader response.",
                      high: "Less broadband loss and longer sustain; 1 removes this loss term, while other damping remains."),
            ParamSpec("bow_gut_fc2", "gut top (Hz)", group: "String · Damping",
                      500, 12000, 3500,
                      effect: "Sets the gut string's additional high-frequency loss cutoff.",
                      low: "Damps upper harmonics earlier, producing a darker string.",
                      high: "Retains more upper harmonics for a brighter string."),
            ParamSpec("bow_nut_fc", "nut corner (Hz)", group: "String · Damping",
                      1000, 12000, 5500,
                      effect: "Sets the low-pass cutoff at the nut or stopping finger.",
                      low: "Absorbs more high-frequency energy at that end of the string.",
                      high: "Reflects more upper harmonics back along the string."),
            ParamSpec("bow_br_fc", "bridge corner (Hz)", group: "String · Damping",
                      1000, 12000, 6750,
                      effect: "Sets the low-pass cutoff at the bridge termination.",
                      low: "Absorbs more upper harmonics at the bridge.",
                      high: "Retains more high-frequency string energy."),
            ParamSpec("bow_loss_reg", "register damping", group: "String · Damping",
                      0.0, 1.5, 0.7,
                      effect: "Makes string-loss cutoffs follow pitch below the tonic. Notes at or above the tonic are unchanged.",
                      low: "Less register tracking; 0 keeps fixed cutoffs.",
                      high: "Low notes become progressively darker; 1 tracks pitch proportionally, above 1 darkens more strongly."),
        ]),

        ("String · Torsion", [
            ParamSpec("bow_tors_c", "torsion coupling", group: "String · Torsion",
                      0.0, 0.5, 0.0,
                      effect: "Feeds sliding motion into a torsional wave and returns it to the bow contact, adding harmonic detail.",
                      low: "Less torsional interaction; 0 disables this wave path.",
                      high: "Stronger returning micro-slips and more upper-harmonic texture."),
            ParamSpec("bow_tors_g", "torsion return", group: "String · Torsion",
                      0.5, 0.98, 0.85,
                      effect: "Sets how much torsional-wave energy survives each return. Requires torsion coupling above 0.",
                      low: "More damping and shorter-lived torsional ripple.",
                      high: "Less damping and stronger, more persistent ripple."),
            ParamSpec("bow_tors_ratio", "torsion speed ×", group: "String · Torsion",
                      3.5, 8.0, 5.2,
                      effect: "Sets torsional wave speed relative to transverse wave speed. Requires torsion coupling above 0.",
                      low: "Slower torsional travel and a longer return delay.",
                      high: "Faster torsional travel and a shorter delay, shifting the resulting harmonic detail upward."),
        ]),

        ("Body · Resonances", [
            ParamSpec("bow_body_modes", "main mode count", group: "Body · Resonances",
                      0, 16, 12, step: 1,
                      effect: "Sets the number of main body resonances. At 0, both these resonances and the formant bank are omitted.",
                      low: "Fewer resonances and simpler body coloration; 0 leaves direct radiation.",
                      high: "More resonances and a more detailed pattern of ringing and coloration."),
            ParamSpec("bow_body_scale", "resonance frequency ×", group: "Body · Resonances",
                      0.1, 1.5, 1.0,
                      effect: "Multiplies the frequencies of the main body resonances, including the air mode. Formant-band edges stay fixed.",
                      low: "Shifts these resonances downward, suggesting a larger body.",
                      high: "Shifts them upward, suggesting a smaller body; 1 keeps the base tuning."),
            ParamSpec("bow_body_air_ratio", "air mode ratio", group: "Body · Resonances",
                      0.4, 2.2, 1.4,
                      effect: "Sets the air resonance relative to the tonic, before the body-frequency multiplier; the other main modes follow it.",
                      low: "Lowers the air resonance and the main mode family.",
                      high: "Raises the air resonance and the main mode family."),
            ParamSpec("bow_body_q", "wood Q", group: "Body · Resonances",
                      5, 60, 25,
                      effect: "Sets the sharpness and decay of the main wood resonances, excluding the air mode.",
                      low: "Broad, quickly damped resonances with smoother coloration.",
                      high: "Narrower, longer-ringing resonances with stronger pitch-dependent color."),
            ParamSpec("bow_body_q_air", "air Q", group: "Body · Resonances",
                      4, 50, 12,
                      effect: "Sets the sharpness and decay of the lowest air resonance.",
                      low: "A broad, short-lived low resonance.",
                      high: "A narrower, longer-ringing low resonance."),
            ParamSpec("bow_body_y", "mobility depth", group: "Body · Resonances",
                      0.0, 2.0, 0.35,
                      effect: "Sets bridge motion at the main body resonances; body return determines how much reaches the strings.",
                      low: "Less resonant bridge movement; 0 removes this part of the bridge load.",
                      high: "Stronger resonant loading, more attack bloom and possible unstable or uneven notes."),
            ParamSpec("bow_body_rad", "modal radiation", group: "Body · Resonances",
                      0.0, 3.0, 1.0,
                      effect: "Sets the audible contribution of the main body resonances relative to direct radiation.",
                      low: "Less main-mode coloration; 0 silences their radiated contribution.",
                      high: "More prominent resonant peaks and dips, without directly increasing bridge mobility."),
            ParamSpec("bow_body_c0", "direct radiation", group: "Body · Resonances",
                      0.0, 1.0, 0.3,
                      effect: "Sets the direct bridge-force contribution alongside the resonant body sound.",
                      low: "Less direct sound; 0 leaves the resonant contributions alone.",
                      high: "More direct sound, filling the gaps between resonances; 1 passes this contribution at unity."),
        ]),

        ("Body · Formants", [
            ParamSpec("bow_body_tail_n", "formant modes", group: "Body · Formants",
                      0, 256, 150, step: 1,
                      effect: "Sets the number of fixed mid/high formants between the two band edges. Requires main body modes above 0.",
                      low: "A sparse pattern; 0 removes the formant bank but keeps the main modes.",
                      high: "A denser pattern of peaks and dips, normalized to avoid simply growing with the count."),
            ParamSpec("bow_body_tail_seed", "formant seed", group: "Body · Formants",
                      1, 64, 1, step: 1,
                      effect: "Chooses the repeatable pattern of formant peaks and nulls at the same overall statistics.",
                      low: "Selects an earlier numbered pattern.",
                      high: "Selects a different pattern, not a brighter, stronger or better one."),
            ParamSpec("bow_body_tail_f0", "formants from (Hz)", group: "Body · Formants",
                      150, 1500, 280,
                      effect: "Sets the lower edge of the formant band in Hz.",
                      low: "Extends formant coloration into lower frequencies.",
                      high: "Concentrates the same mode count higher in the spectrum."),
            ParamSpec("bow_body_tail_f1", "formants to (Hz)", group: "Body · Formants",
                      2000, 12000, 6500,
                      effect: "Sets the upper edge of the formant band in Hz.",
                      low: "Confines formant coloration to a narrower, lower band.",
                      high: "Spreads the formants farther into the upper spectrum."),
            ParamSpec("bow_body_tail_q", "formant Q", group: "Body · Formants",
                      5, 80, 40,
                      effect: "Sets the sharpness and ring time of the fixed formants.",
                      low: "Broader, faster-decaying features with gentler spectral detail.",
                      high: "Narrower, longer-ringing features with more pronounced peaks and valleys."),
            ParamSpec("bow_body_tail_y", "formant mobility", group: "Body · Formants",
                      0.0, 1.5, 0.4,
                      effect: "Sets how strongly the formant resonances move the bridge and load the played strings.",
                      low: "Less formant-related loading; 0 removes that part of the bridge movement.",
                      high: "Stronger interaction with the strings, potentially making some pitches uneven or unstable."),
            ParamSpec("bow_body_tail_rad", "formant radiation", group: "Body · Formants",
                      0.0, 8.0, 3.5,
                      effect: "Sets the audible formant contribution relative to direct radiation. It does not set formant bridge mobility.",
                      low: "Weaker formant color; 0 removes this contribution.",
                      high: "More pronounced formant peaks and nulls as harmonics move through the body response."),
        ]),

        ("Body · Bridge interaction", [
            ParamSpec("bow_w", "excitation level", group: "Body · Bridge interaction",
                      0.2, 2.5, 1.196,
                      effect: "Scales the played strings' bridge-force contribution before body radiation and taraf excitation.",
                      low: "Less bridge drive, quieter radiation and weaker sympathetic excitation.",
                      high: "More bridge drive and excitation, also increasing the body feedback load."),
            ParamSpec("bow_yinf", "bridge give", group: "Body · Bridge interaction",
                      0.0, 0.4, 0.05,
                      effect: "Sets broadband bridge mobility underneath the resonant peaks.",
                      low: "A more rigid baseline; 0 removes this broadband movement.",
                      high: "More bridge movement across the spectrum, returned to the strings through body return."),
            ParamSpec("bow_kret", "body return", group: "Body · Bridge interaction",
                      0.0, 0.5, 0.35,
                      effect: "Sets how much body-driven bridge motion feeds back into the played strings.",
                      low: "Less body loading; 0 disconnects this return while retaining body radiation.",
                      high: "Stronger interaction with body resonances, including more unevenness or wolf-like notes; the loop cap limits it."),
        ]),

        ("Taraf · Shared", [
            ParamSpec("bow_jt_drive", "drive", group: "Taraf · Shared",
                      0.001, 0.3, 0.03, apply: .live,
                      effect: "Sets bridge excitation of both taraf banks from played strings and injected Tanpura/Sitar sound. Also scales chromatic burst and drone drive; raga plectrum displacement is separate.",
                      low: "Gentler excitation and less contact activity.",
                      high: "Stronger excitation and more active jawari contact; drive normalization can compensate the audible level change."),
            ParamSpec("bow_jt_drive_norm", "drive normalization", group: "Taraf · Shared",
                      0.0, 1.0, 0.7, apply: .live,
                      effect: "Compensates the radiated level change caused by shared taraf drive, while tracking stored energy so existing ring-outs retain their level.",
                      low: "At 0, keeps the raw loudness changes caused by drive.",
                      high: "At 1, fully compensates the steady-state energy model; intermediate values retain some level change."),
            ParamSpec("bow_jt_sel", "recruitment", group: "Taraf · Shared",
                      0, 1, 0.5, apply: .live,
                      effect: "Sets which rows contribute in both taraf banks, with loudness compensation. The fitted natural response is 0.5.",
                      low: "Toward 0, favors rows harmonically related to the played notes.",
                      high: "Toward 1, flattens contributions toward a uniform haze that depends less on the played pitches."),
            ParamSpec("bow_jt_damp", "extra damping", group: "Taraf · Shared",
                      0, 1, 0.0, apply: .live,
                      effect: "Adds damping to both taraf banks while they ring.",
                      low: "At 0, preserves each row's natural decay.",
                      high: "Shortens the ring progressively; near 1 the strings are strongly choked."),
            ParamSpec("bow_jt_lp", "low-pass cutoff (Hz)", group: "Taraf · Shared",
                      1000.0, 20000.0, 20000.0, apply: .live,
                      effect: "Low-pass filters the combined audible taraf output; played-string sound and physical bridge return are unaffected.",
                      low: "Removes more high harmonics for a darker wash.",
                      high: "Preserves more brightness; 20000 Hz bypasses the filter."),
            ParamSpec("bow_jt_hp", "high-pass cutoff (Hz)", group: "Taraf · Shared",
                      0.0, 4000.0, 0.0, apply: .live,
                      effect: "High-pass filters the combined audible taraf output; played-string sound and physical bridge return are unaffected.",
                      low: "Retains more low-frequency body; 0 bypasses the filter.",
                      high: "Reduces fundamentals and low harmonics, leaving a thinner, brighter harmonic halo."),
            ParamSpec("bow_jt_body", "body radiation", group: "Taraf · Shared",
                      0.0, 1.0, 0.0, apply: .live,
                      effect: "Blends both taraf banks through the same body-radiation response as the played String voice.",
                      low: "At 0, the taraf radiates directly without this body coloration.",
                      high: "At 1, the taraf fully takes on the body's formants; body edits then color both voice and taraf."),
            ParamSpec("bow_jt_couple", "bridge coupling", group: "Taraf · Shared",
                      0.0, 1.0, 0.0, apply: .live,
                      effect: "Returns both taraf banks' bridge force to the played strings and subsequent excitation, creating a shared physical feedback path.",
                      low: "At 0, disables this return.",
                      high: "Increases mutual bridge loading and sympathetic interaction within the calibrated safe range."),
            ParamSpec("bow_jt_cap", "voice cap", group: "Taraf · Shared",
                      0.0, 1.0, 0.0, apply: .live,
                      effect: "Limits each taraf row against the played voice's recent peak, using the voice-cap ratio. A silent voice can hold down drones and injected plucks when this is armed.",
                      low: "At 0, no relative cap; small values apply gentle restraint.",
                      high: "At 1, enforces the per-row ceiling firmly; the summed bank can still exceed one row's ceiling."),
            ParamSpec("bow_jt_cap_ratio", "voice cap ratio", group: "Taraf · Shared",
                      0.1, 2.0, 1.0, apply: .live,
                      effect: "Sets each taraf row's permitted level relative to the voice's recent peak. Only affects sound when voice cap is above 0.",
                      low: "A tighter ceiling; 0.5 allows roughly 6 dB below the voice peak.",
                      high: "A looser ceiling; 1 permits parity and 2 permits roughly 6 dB above it."),
            ParamSpec("ctl_taraf_adapt", "history adaptation", group: "Taraf · Shared",
                      0.0, 1.0, 0.0, apply: .live, target: .tarafAdaptation,
                      effect: "Uses recent played-pitch history to attenuate incidental degrees in both taraf banks' radiation. Saved row gains and physical feedback stay intact.",
                      low: "At 0, uses the saved gains without history-based attenuation.",
                      high: "At 1, can reduce incidental degrees toward 15% of their saved gain; frequently used degrees remain prominent."),
        ]),

        ("Taraf · Raga", [
            ParamSpec("bow_jt_gain", "level", group: "Taraf · Raga",
                      0.0, 3.0, 0.3,
                      effect: "Sets the raga taraf's audible level independently of the chromatic bank, preserving ringing state and physical bridge coupling.",
                      low: "Quieter raga radiation; 0 mutes this bank's output.",
                      high: "Louder raga radiation, including its drone and explicit plucks."),
            ParamSpec("bow_jt_norm", "decay normalization", group: "Taraf · Raga",
                      0.0, 1.5, 1.0,
                      effect: "Weights raga rows by their decay response to reduce level differences between long- and short-ringing rows. Does not alter physical decay.",
                      low: "At 0, preserves raw row gains and their natural level differences.",
                      high: "Applies stronger decay-based compensation; 1 is full modeled normalization and above 1 goes further."),
            ParamSpec("bow_jt_dual_mm", "reference pluck (mm)", group: "Taraf · Raga",
                      0, 1, 0.5, apply: .live, timing: .onset, scope: .perNote,
                      effect: "Sets reference plectrum displacement for raga drone presses and explicit plucks, scaled by register and captured at onset.",
                      low: "Gentler plucks; 0 adds no plectrum displacement.",
                      high: "Stronger plucks and deeper initial contact; bowed excitation keeps its own drive."),
            ParamSpec("bow_jt_bow_bloom", "bow bloom", group: "Taraf · Raga",
                      0, 1, 1, apply: .live,
                      effect: "Lets fresh bridge energy charge raga rows, then reduces sustained forcing over about 2.1 seconds. Direct plectrum gestures are unaffected.",
                      low: "At 0, maintains continuous bridge drive.",
                      high: "At 1, sustained forcing settles to 3%, emphasizing the initial bloom and subsequent ring."),
            ParamSpec("bow_jt_dual_lp", "hiss cutoff (Hz)", group: "Taraf · Raga",
                      2000, 20000, 20000, apply: .live,
                      effect: "Removes high-frequency hiss from each raga row's radiation while retaining harmonic peaks. Contact motion and bridge return are unaffected.",
                      low: "Cleans a broader upper-frequency region.",
                      high: "Leaves more of the original top end; 20000 Hz bypasses cleanup with matched delay."),
            ParamSpec("bow_jt_dual_select", "filter selectivity", group: "Taraf · Raga",
                      0, 1, 0, apply: .live,
                      effect: "Sets how strictly raga hiss cleanup identifies harmonic peaks. Only active when hiss cutoff is below bypass.",
                      low: "Accepts weaker or less precisely aligned peaks, preserving more residual texture.",
                      high: "Requires stronger peaks nearer the row's harmonics, suppressing more residual noise."),
            ParamSpec("bow_jt_sav", "SAV contact solver", group: "Taraf · Raga",
                      0, 1, 0, step: 1, apply: .rebuild,
                      effect: "Chooses the contact solver for the physical raga rows and rebuilds them.",
                      low: "0 selects the Newton solver.",
                      high: "1 selects the corrected SAV solver; this is an algorithm choice, not an amount or quality scale."),
        ]),

        ("Taraf · Chromatic", [
            ParamSpec("bow_jtc_gain", "level", group: "Taraf · Chromatic",
                      0.0, 3.0, 0.3,
                      effect: "Sets the chromatic taraf and melody follower's audible level independently of the raga bank, preserving ringing state and physical bridge coupling.",
                      low: "Quieter chromatic radiation; 0 mutes this bank's output.",
                      high: "Louder chromatic radiation, including its drone and explicit plucks."),
            ParamSpec("bow_jtc_norm", "decay normalization", group: "Taraf · Chromatic",
                      0.0, 1.5, 0.0,
                      effect: "Weights chromatic rows and the melody follower by decay response to reduce level differences. Does not alter physical decay.",
                      low: "At 0, preserves raw row gains and their natural level differences.",
                      high: "Applies stronger decay-based compensation; 1 is full modeled normalization and above 1 goes further."),
            ParamSpec("bow_jtc_evolve", "evolution", group: "Taraf · Chromatic",
                      0.0, 1.0, 0.5, apply: .live,
                      effect: "Moves chromatic rows and the melody follower between pressed and grazing jawari contact. The fitted geometry is 0.5; raga geometry is separate.",
                      low: "Toward 0, presses the string against the bone.",
                      high: "Toward 1, opens the grazing contact band for evolving harmonics; brightness and sustain depend on the geometry."),
            ParamSpec("bow_jt_ev_reg", "evolution register", group: "Taraf · Chromatic",
                      -1.0, 1.0, 0.0, apply: .live,
                      effect: "Offsets chromatic and follower evolution by register relative to the tonic. Zero applies the same evolution at every pitch.",
                      low: "Negative values press lower rows and open higher rows.",
                      high: "Positive values open lower rows and press higher rows."),
            ParamSpec("bow_jt_apex", "graze depth (m)", group: "Taraf · Chromatic",
                      2e-6, 5e-5, 1e-5,
                      effect: "Sets bone protrusion into chromatic and follower strings. Its effect depends on the contact zone and curvature.",
                      low: "Shallower contact; the string may barely graze or miss the bone.",
                      high: "Deeper contact; beyond the grazing region the string becomes pressed, so more depth does not always mean more buzz."),
            ParamSpec("bow_jt_zone", "contact zone (m)", group: "Taraf · Chromatic",
                      0.002, 0.02, 0.006,
                      effect: "Sets the length of bone available for chromatic and follower contact, in metres.",
                      low: "A shorter, more localized contact region with a sharper knee.",
                      high: "A longer region that lets contact spread, often producing a more diffuse buzz."),
            ParamSpec("bow_jt_radius", "bone radius (m)", group: "Taraf · Chromatic",
                      0.05, 2.0, 0.3,
                      effect: "Sets the bone's curvature radius for chromatic rows and the melody follower.",
                      low: "A more rounded bone with localized contact, usually a cleaner ring.",
                      high: "A flatter bone that lets the contact point travel farther, opening the jawari character."),
            ParamSpec("bow_jt_alpha", "contact exponent", group: "Taraf · Chromatic",
                      1.0, 2.0, 1.5,
                      effect: "Sets the exponent relating penetration to contact force for chromatic rows and the melody follower.",
                      low: "Near 1, the contact-force law is closer to linear.",
                      high: "Near 2, force depends more nonlinearly on penetration; the audible result also depends on depth and stiffness, not a simple brightness scale."),
            ParamSpec("bow_jt_hcb", "contact damping", group: "Taraf · Chromatic",
                      1.0, 40.0, 8.0,
                      effect: "Sets energy loss during chromatic and follower string-bone contact.",
                      low: "Less contact damping and sharper, more clangorous transients.",
                      high: "More contact damping, rounding buzz transients and dissipating more motion."),
            ParamSpec("bow_jt_fhf", "damping corner (Hz)", group: "Taraf · Chromatic",
                      800.0, 12000.0, 4000.0,
                      effect: "Sets the frequency above which chromatic and follower partials receive progressively stronger damping.",
                      low: "Upper partials die sooner, leaving a warmer ring.",
                      high: "Upper partials survive longer, keeping the ring brighter."),
            ParamSpec("bow_jt_bst", "inharmonicity", group: "Taraf · Chromatic",
                      0.0, 1.0e-3, 2.0e-4,
                      effect: "Stretches chromatic and follower upper partials to model stiff wire.",
                      low: "More harmonic tuning; 0 removes this stiffness stretch.",
                      high: "Sharper upper partials and a more metallic, bell-like character."),
            ParamSpec("bow_jt_pluck", "pluck excitation", group: "Taraf · Chromatic",
                      0, 0.3, 0, apply: .live, timing: .onset, scope: .perNote,
                      effect: "Selects and scales a finite pitched force burst for chromatic drone presses and explicit plucks; raga plucks use reference displacement.",
                      low: "At exactly 0, keeps the held drone swell; just above 0, switches to a gentle finite burst.",
                      high: "A stronger finite burst on the pressed row, without held drive or spreading the gesture to related rows."),
            ParamSpec("bow_jt_pluck_decay_ms", "excitation decay (ms)", group: "Taraf · Chromatic",
                      1, 100, 12, apply: .live, timing: .onset, scope: .perNote,
                      effect: "Sets the force-burst decay time for chromatic plucks. Requires pluck excitation above 0; the row's natural ring time is separate.",
                      low: "A shorter impulse with a more abrupt excitation.",
                      high: "A longer push that injects energy for more time; the burst ends after twelve time constants."),
            ParamSpec("bow_jt_pulse", "evolution pulse", group: "Taraf · Chromatic",
                      0, 1, 0, apply: .live, timing: .onset, scope: .perNote,
                      effect: "Makes a chromatic drone press or explicit pluck briefly open that row toward evolution 1, then return to its resting geometry.",
                      low: "At 0, no evolution excursion.",
                      high: "A larger opening excursion, limited by the remaining distance to evolution 1."),
            ParamSpec("bow_jt_pulse_attack_ms", "pulse attack (ms)", group: "Taraf · Chromatic",
                      1, 100, 5, apply: .live, timing: .onset, scope: .perNote,
                      effect: "Sets how quickly a chromatic evolution pulse moves the bone. Requires evolution pulse above 0.",
                      low: "Faster movement and a sharper change in contact color.",
                      high: "Slower, smoother movement into the pulse."),
            ParamSpec("bow_jt_pulse_decay_ms", "pulse decay (ms)", group: "Taraf · Chromatic",
                      10, 2000, 180, apply: .live, timing: .onset, scope: .perNote,
                      effect: "Sets how quickly a chromatic evolution pulse returns toward resting geometry. It does not set string decay.",
                      low: "A brief change in contact color.",
                      high: "A longer evolving contact trajectory before the bone settles back."),
        ]),

        ("Tanpura · Voice", [
            ParamSpec("tp_gain", "output gain", group: "Tanpura · Voice",
                      0.0, 0.03, 0.02, apply: .live,
                      effect: "Sets Tanpura output trim after its fitted body response and before its calibration room, for both drone and played Tanpura sound.",
                      low: "Quieter Tanpura output; 0 mutes its new output contribution, while an existing room tail can decay.",
                      high: "Louder Tanpura output without increasing the pluck displacement itself."),
            ParamSpec("tp_pluck_level", "played pluck level", group: "Tanpura · Voice",
                      0.0, 2.0, 1.0, apply: .live,
                      effect: "Scales fret-note pluck displacement when Tanpura is the selected main instrument.",
                      low: "Gentler played plucks; 0 adds no new pluck displacement.",
                      high: "Stronger played plucks with more jawari excitation; 1 is the calibrated level."),
            ParamSpec("tp_rel_t60", "note-off release t60 (s)", group: "Tanpura · Voice",
                      0.05, 3.0, 0.4, apply: .live,
                      scope: .perNote,
                      effect: "Sets the time for released main-instrument Tanpura notes to fall by 60 dB. Held notes and drone-button strings keep their own natural decay.",
                      low: "Short, quickly damped note releases.",
                      high: "Longer ring-outs after lifting a fret touch."),
            ParamSpec("tp_pluck_touch", "pluck isolation", group: "Tanpura · Voice",
                      0.0, 1.0, 0.0, apply: .live,
                      effect: "Controls how a new Tanpura pluck interacts with earlier ringing motion, for both drones and played notes.",
                      low: "At exactly 0, re-plucks the ringing string; above 0, starts a fresh settled string and keeps a reduced old tail.",
                      high: "At 1, the new pluck stays isolated and the previous tail carries on at full level and its own pitch."),
            ParamSpec("tp_poly", "history string bank", group: "Tanpura · Voice",
                      0.0, 16.0, 6.0, apply: .live,
                      effect: "Sets how many earlier Tanpura plucks keep their full jawari simulation when pluck isolation is above 0; older tails move to a simpler ring-out.",
                      low: "Fewer evolving history strings and less CPU use; 0 sends old motion directly to the simpler tail.",
                      high: "More previous plucks keep developing their buzz, with greater CPU cost."),
            ParamSpec("tp_pluck_drive", "pluck contact drive", group: "Tanpura · Voice",
                      0.25, 4.0, 1.0, apply: .live,
                      effect: "Scales Tanpura pluck displacement with inverse output compensation at the next pluck, separating contact character from approximate loudness.",
                      low: "Below 1, gentler bone contact and a cleaner, mellower ring.",
                      high: "Above 1, deeper contact and a brighter, faster-developing buzz; 1 keeps the fitted character."),
            ParamSpec("tp_taraf", "sympathetic taraf drive", group: "Tanpura · Voice",
                      0.0, 8.0, 4.0, apply: .live,
                      effect: "Sets how strongly Tanpura sound excites both taraf banks through the Voice → Taraf insert, alongside the shared taraf drive.",
                      low: "Less sympathetic excitation; 0 disconnects this source from the taraf.",
                      high: "Stronger excitation and a more prominent sympathetic response; bank output levels remain separate."),
        ]),

        ("Tanpura · Drones", [
            ParamSpec("tp_drone_level", "drone pluck level", group: "Tanpura · Drones",
                      0.0, 2.0, 1.0, apply: .live,
                      effect: "Scales the Tanpura drone buttons' pluck displacement. Does not control the separate sympathetic-swell drone mode.",
                      low: "Gentler drone plucks; 0 adds no new pluck displacement.",
                      high: "Stronger drone plucks with more jawari excitation; 1 uses each role's calibrated displacement."),
            ParamSpec("tp_drone_cycle", "drone re-pluck period (s)", group: "Tanpura · Drones",
                      0.0, 8.0, 2.5, apply: .live,
                      effect: "Sets the interval between Tanpura re-plucks while a drone button remains held.",
                      low: "Below 0.1 seconds, disables repetition; above that, short intervals produce rapid re-plucking.",
                      high: "Longer intervals leave more space for each pluck to ring before the next."),
        ]),

        ("Tanpura · Jawari", [
            ParamSpec("tp_jiva_comp", "register jawari calibration", group: "Tanpura · Jawari",
                      0.0, 1.0, 1.0, apply: .live,
                      timing: .rebuild,
                      effect: "Adjusts the Tanpura jawari thread by pitch to preserve the low register's grazing contact in higher strings.",
                      low: "At 0, keeps the unadjusted fitted geometry, so high strings can become cleaner and darker.",
                      high: "At 1, applies the full register calibration for more consistent buzz and harmonic development across pitches."),
            ParamSpec("tp_cascade", "register cascade slowing", group: "Tanpura · Jawari",
                      0.0, 1.0, 1.0, apply: .live,
                      timing: .rebuild,
                      effect: "Slows the Tanpura's upper-register harmonic development toward the low string's pace, while retaining upper-partial sustain.",
                      low: "At 0, leaves the base register calibration alone, with quicker development in higher strings.",
                      high: "At 1, applies the full slowing adjustment above the low-register anchor for a more gradual harmonic bloom."),
        ]),

        ("Sitar · Voice", [
            ParamSpec("st_gain", "output gain", group: "Sitar · Voice",
                      0.0, 0.03, 0.015186, apply: .live,
                      effect: "Sets Sitar output trim before its calibration room.",
                      low: "Quieter Sitar output; 0 mutes its new output contribution, while an existing room tail can decay.",
                      high: "Louder Sitar output without increasing the pluck displacement itself."),
            ParamSpec("st_pluck_level", "played pluck level", group: "Sitar · Voice",
                      0.0, 2.0, 1.0, apply: .live,
                      effect: "Scales fret-note pluck displacement when Sitar is the selected main instrument.",
                      low: "Gentler played plucks; 0 adds no new pluck displacement.",
                      high: "Stronger played plucks with more jawari excitation; 1 is the calibrated level."),
            ParamSpec("st_rel_t60", "note-off release t60 (s)", group: "Sitar · Voice",
                      0.05, 3.0, 0.15, apply: .live,
                      scope: .perNote,
                      effect: "Sets the time for released Sitar notes to fall by 60 dB. Held notes keep their natural decay.",
                      low: "Short, quickly damped note releases.",
                      high: "Longer ring-outs after lifting a fret touch."),
            ParamSpec("st_pluck_touch", "pluck isolation", group: "Sitar · Voice",
                      0.0, 1.0, 1.0, apply: .live,
                      effect: "Controls how a new Sitar pluck interacts with earlier ringing motion.",
                      low: "At exactly 0, re-plucks the ringing string; above 0, starts a fresh settled string and keeps a reduced old tail.",
                      high: "At 1, the new pluck stays isolated and the previous tail carries on at full level and its own pitch."),
            ParamSpec("st_poly", "history string bank", group: "Sitar · Voice",
                      0.0, 16.0, 4.0, apply: .live,
                      effect: "Sets how many earlier Sitar plucks keep their full jawari simulation when pluck isolation is above 0; older tails move to a simpler ring-out.",
                      low: "Fewer evolving history strings and less CPU use; 0 sends old motion directly to the simpler tail.",
                      high: "More previous plucks keep developing their buzz, with greater CPU cost."),
            ParamSpec("st_pluck_drive", "pluck contact drive", group: "Sitar · Voice",
                      0.25, 4.0, 1.0, apply: .live,
                      effect: "Scales Sitar pluck displacement with inverse output compensation at the next pluck, separating contact character from approximate loudness.",
                      low: "Below 1, gentler bone contact and a cleaner, mellower ring.",
                      high: "Above 1, deeper contact and a brighter, faster-developing buzz; 1 keeps the fitted character."),
            ParamSpec("st_taraf", "sympathetic taraf drive", group: "Sitar · Voice",
                      0.0, 8.0, 4.0, apply: .live,
                      effect: "Sets how strongly Sitar sound excites both taraf banks through the Voice → Taraf insert, alongside the shared taraf drive.",
                      low: "Less sympathetic excitation; 0 disconnects this source from the taraf.",
                      high: "Stronger excitation and a more prominent sympathetic response; bank output levels remain separate."),
        ]),

        ("Output · Mix & limiter", [
            ParamSpec("bow_gain", "master gain (String + taraf)", group: "Output · Mix & limiter",
                      0.0, 4.0, 1.0, apply: .live,
                      effect: "Sets performance volume for the String engine's played voice, taraf and room together, on top of calibration trim. The output limiter still applies.",
                      low: "Quieter combined output; 0 mutes it.",
                      high: "Louder combined output; 1 is the calibrated level, and higher values add gain."),
            ParamSpec("bow_bal", "voice↔taraf balance", group: "Output · Mix & limiter",
                      -1.0, 1.0, 0.0, apply: .live,
                      effect: "Balances the String engine's played-voice and taraf buses by attenuating one side. Zero keeps the calibrated mix.",
                      low: "Toward −1, turns down the taraf until only the played-voice bus remains.",
                      high: "Toward +1, turns down the played-voice bus until only the taraf remains; bank levels still set their balance."),
            ParamSpec("bow_live_trim", "output trim", group: "Output · Mix & limiter",
                      0.01, 0.5, 0.175,
                      effect: "Sets the String engine's calibration output scale. Master gain is the separate performance-volume control.",
                      low: "Quieter calibrated output with more headroom before the limiter.",
                      high: "Louder calibrated output with more frequent limiting on strong peaks."),
            ParamSpec("bow_lim_thresh", "limiter ceiling", group: "Output · Mix & limiter",
                      0.1, 1.0, 0.8,
                      effect: "Sets the String engine's linked-stereo peak ceiling after global FX; signals below it pass unchanged.",
                      low: "A lower ceiling and more gain reduction on peaks.",
                      high: "A higher permitted peak level and less frequent limiting."),
            ParamSpec("bow_lim_rel_ms", "limiter release (ms)", group: "Output · Mix & limiter",
                      20.0, 500.0, 150.0,
                      effect: "Sets how quickly the String engine's limiter restores gain after a peak.",
                      low: "Faster recovery, which can make sustained loud material pump.",
                      high: "Slower recovery, keeping the following sound quieter for longer."),
        ]),

        ("Output · Tone & stereo", [
            ParamSpec("bow_rad_hp", "radiation HP (Hz)", group: "Output · Tone & stereo",
                      50, 600, 200,
                      effect: "High-pass filters the String engine's combined played-voice and taraf radiation before the room.",
                      low: "Retains more bass and low-frequency weight.",
                      high: "Removes more low-frequency energy for a leaner sound."),
            ParamSpec("bow_rad_lp", "radiation LP (Hz)", group: "Output · Tone & stereo",
                      500, 16000, 8000,
                      effect: "Low-pass filters the String engine's combined played-voice and taraf radiation before the room.",
                      low: "Darker output with fewer upper harmonics.",
                      high: "Brighter output with more upper-frequency detail."),
            ParamSpec("bow_tone_tilt", "tone tilt (bass–treble)", group: "Output · Tone & stereo",
                      -1, 1, 0.0, apply: .live,
                      effect: "Tilts the String engine's combined spectrum before the room. Zero leaves the spectral balance flat.",
                      low: "Negative values favor bass over treble.",
                      high: "Positive values favor treble over bass."),
            ParamSpec("bow_st_width", "instrument width", group: "Output · Tone & stereo",
                      0.0, 1.0, 0.2,
                      effect: "Sets stereo spread of the String engine's played voice, taraf, drones and bow noise. Low frequencies stay centered and the mono sum is preserved.",
                      low: "A narrower instrument; 0 gives a point-like mono source.",
                      high: "More left/right difference in the upper spectrum, giving a wider instrument."),
        ]),

        ("Output · Room", [
            ParamSpec("bow_rev_mix", "room mix", group: "Output · Room",
                      0.0, 0.3, 0.08,
                      effect: "Sets the built-in calibration room's wet contribution to the String engine output, separately from FX-rack reverbs.",
                      low: "Less room sound; 0 is dry.",
                      high: "More room ambience around the direct sound."),
            ParamSpec("bow_rev_rt60", "room decay (s)", group: "Output · Room",
                      0.2, 2.0, 1.0,
                      effect: "Sets the built-in room's decay time in seconds to fall by 60 dB. Requires room mix above 0.",
                      low: "A short, tight room tail.",
                      high: "A longer, more lingering room tail."),
            ParamSpec("bow_rev_width", "room width", group: "Output · Room",
                      0.0, 1.0, 0.8,
                      effect: "Sets left/right differences in the built-in room tail while preserving its mono sum. Requires room mix above 0.",
                      low: "A narrower room; 0 makes its tail mono.",
                      high: "A more spread-out room tail; it does not pan the instrument to either side."),
        ]),

        ("Controls · Fret pad", [
            ParamSpec("ctl_fret_warp", "pitch warp", group: "Controls · Fret pad",
                      0.0, 1.0, 0.0, apply: .live, target: .fretWarp,
                      effect: "Shapes how touch position maps to pitch between the pad's enabled frets.",
                      low: "At 0, pitch changes evenly through each gap, supporting continuous slides.",
                      high: "At 1, pitch stays near each fret longer and crosses the middle quickly, making runs more nearly quantized."),
            ParamSpec("ctl_fret_accent", "pitch accent", group: "Controls · Fret pad",
                      0.0, 1.0, 0.0, apply: .live, target: .pitchAccent,
                      effect: "Dips played expression between the pad's enabled frets, then restores it at each fret.",
                      low: "At 0, expression is unaffected by position between frets.",
                      high: "At 1, expression fades out midway through each gap, separating the notes of a glided run."),
        ]),

        ("Controls · Glide", [
            ParamSpec("ctl_glide_on", "glide enable", group: "Controls · Glide",
                      0.0, 1.0, 0.0, apply: .live, target: .glideQueue,
                      scope: .perNote,
                      effect: "Enables the glide queue, which connects qualifying touches into a pitch trajectory.",
                      low: "Below 0.5, touches use the ordinary independent-note path.",
                      high: "At 0.5 or above, qualifying touches become glide waypoints; this is an on/off choice."),
            ParamSpec("ctl_glide_grace", "glide grace (ms)", group: "Controls · Glide",
                      0.0, 500.0, 150.0, apply: .live, target: .glideQueue,
                      scope: .perNote,
                      effect: "Sets how long a released note remains available to connect to the next touch through the glide queue.",
                      low: "A smaller gap can still connect; 0 requires touch overlap.",
                      high: "Allows longer gaps between touches to continue the same phrase."),
            ParamSpec("ctl_glide_rate", "glide rate (st/s)", group: "Controls · Glide",
                      2.0, 200.0, 40.0, apply: .live, target: .glideQueue,
                      scope: .perNote,
                      effect: "Sets the base glide speed in semitones per second, before held-note and catch-up multipliers. Requires the glide queue enabled.",
                      low: "Slower transitions that take longer to reach the next pitch.",
                      high: "Faster transitions and quicker arrivals."),
            ParamSpec("ctl_glide_held", "held glide ×", group: "Controls · Glide",
                      0.05, 1.0, 0.3, apply: .live, target: .glideQueue,
                      scope: .perNote,
                      effect: "Multiplies glide speed while the note being left is still held. Requires the glide queue enabled.",
                      low: "Slows the transition more strongly while the old touch remains down.",
                      high: "At 1, held and released departures use the same base speed."),
            ParamSpec("ctl_glide_catchup", "catch-up ×", group: "Controls · Glide",
                      1.0, 16.0, 4.0, apply: .live, target: .glideQueue,
                      scope: .perNote,
                      effect: "Multiplies glide speed through intermediate waypoints when newer notes are already queued.",
                      low: "At 1, passes each waypoint at the ordinary rate.",
                      high: "Hurries through intermediate pitches to catch up with the latest touch."),
            ParamSpec("ctl_glide_over", "overshoot", group: "Controls · Glide",
                      0.0, 0.3, 0.08, apply: .live, target: .glideQueue,
                      scope: .perNote,
                      effect: "Sets how far the final glide passes its target before settling back, as a fraction of the interval, capped at 50 cents.",
                      low: "Less overshoot; 0 lands directly on the target.",
                      high: "A larger land-and-correct gesture, up to the cap; intermediate waypoints still land directly."),
        ]),

        ("Controls · Strum", [
            ParamSpec("ctl_strum_expr", "chord expression", group: "Controls · Strum",
                      0.0, 1.0, 1.0, apply: .live, target: .strumExpression,
                      effect: "Scales expression for the controller's strum chord only: continuously for bowed notes, or at pluck onset for Tanpura/Sitar.",
                      low: "Quieter chord notes; 0 removes their played excitation.",
                      high: "At 1, chord notes follow the unscaled expression level; melody expression is separate."),
            ParamSpec("ctl_strum_thresh", "accel trigger threshold", group: "Controls · Strum",
                      0.0, 1.0, 1.0, apply: .live, target: .strumThreshold,
                      effect: "Sets the iPad strike-envelope threshold that triggers the strum chord. The chord releases below about 60% of that threshold unless the strum button holds it.",
                      low: "Gentler movements can trigger a strum.",
                      high: "Requires a stronger movement; exactly 1 disables acceleration-triggered strumming."),
        ]),

        ("Controls · Strike blend", [
            ParamSpec("ctl_strike_window", "blend window (s)", group: "Controls · Strike blend",
                      0.25, 8.0, 2.0, apply: .live, target: .strikeWindow,
                      scope: .perNote,
                      effect: "Sets the per-note handoff from iPad Strike bindings at onset to Acceleration bindings during sustain.",
                      low: "A quicker handoff, shortening the influence of Strike bindings.",
                      high: "Strike bindings remain influential longer before Acceleration takes over fully."),
        ]),

        ("Controls · Acceleration smoothing", [
            ParamSpec("ctl_ipad_accel_smooth", "iPad smoothing (ms)", group: "Controls · Acceleration smoothing",
                      0, 1000, 0, apply: .live, target: .accelerationSmoothing(.acceleration),
                      effect: "Adds smoothing to iPad Acceleration bindings on the Mac. Strike response is separate; the source already has an envelope.",
                      low: "Follows motion more promptly; 0 adds no smoothing.",
                      high: "Smooths short fluctuations more strongly, with a slower response and greater lag."),
            ParamSpec("ctl_jc_accel_smooth", "Joy-Con smoothing (ms)", group: "Controls · Acceleration smoothing",
                      0, 1000, 0, apply: .live, target: .accelerationSmoothing(.jcAccel),
                      effect: "Adds smoothing to Joy-Con Accel bindings on the Mac, after the source envelope.",
                      low: "Follows motion more promptly; 0 adds no smoothing.",
                      high: "Smooths short fluctuations more strongly, with a slower response and greater lag."),
        ]),
        fxRackGroup(),
    ]

    // MARK: - The FX rack: ONE insert, four points

    /// THE FX RACK — one insert DEFINITION, instantiated at four points.
    ///
    /// The rack used to spell out 4 × N near-identical specs (more than a
    /// third of the whole registry). The insert is now described once
    /// (`fxTemplate`) and instantiated for each point (`fxPoints`):
    /// `ParamRegistry.all` still answers every `fx_<point>_<knob>` key, so
    /// presets, tilt targets, composites and the FX tab are untouched —
    /// but each derived spec carries its `insert`,
    /// so the Parameters tab shows FOUR collapsible inserts instead of
    /// flat rows and docs/parameters.md renders the template once.
    ///
    /// `keyPrefix` must equal `SarangiKit.FXPoint.keyPrefix` and every
    /// `knob` must be a field `FXSettings.apply(field:value:)` parses —
    /// `FXRackTests` pins both, plus def == `FXSettings()` (a drifted
    /// default would arm the rack at the startup resting push).
    public static let fxPoints: [FXInsertPoint] = [
        FXInsertPoint(
            index: 0, name: "Voice → Taraf", keyPrefix: "fx_drive_",
            what: "the excitation feeding both taraf banks, including played strings and injected Tanpura/Sitar sound",
            blurb: "What the sympathetic strings hear — shapes only the taraf's excitation, not the radiated voice."),
        FXInsertPoint(
            index: 1, name: "Voice", keyPrefix: "fx_voice_",
            what: "the played String voice’s bridge radiation and bow noise, after the taraf excitation tap and before the shared output chain",
            blurb: "The main voice bus (bridge + bow noise) after the taraf tap."),
        FXInsertPoint(
            index: 2, name: "Taraf", keyPrefix: "fx_taraf_",
            what: "both taraf banks’ audible output, including drones, before the shared output chain",
            blurb: "The sympathetic web's own radiated output, drones included."),
        FXInsertPoint(
            index: 3, name: "Global", keyPrefix: "fx_global_",
            what: "the String engine’s combined stereo voice, taraf and room output, after tone and gain but before its limiter",
            blurb: "The final stereo output, after the whole fitted chain."),
    ]

    /// The group every derived FX spec belongs to.
    public static let fxGroupName = "FX rack"

    /// THE INSERT, described once: the EQ curve's two knobs (its POINTS are
    /// not knobs — the FX tab edits them and presets carry them, see
    /// `TarabdaarPreset.fxCurves`) and a selectable additive reverb, all
    /// `.live` (they never touch the physics tables) and all off by default
    /// — the untouched rack is byte-null. `knob` is the field suffix;
    /// `{what}` in the help expands to the point's own description.
    public static let fxTemplate: [FXKnob] = {
        var t: [FXKnob] = [
            FXKnob("eq_on", "EQ on", 0, 1, 0, step: 1,
                   effect: "Enables the drawn EQ curve on {what}. Changes fade smoothly between the curve and a flat response.",
                   low: "0 bypasses the EQ.",
                   high: "1 enables the EQ at the configured amount."),
            FXKnob("eq_amount", "EQ amount", 0, 1, 1,
                   effect: "Scales the EQ curve drawn on the FX tab. Requires this insert’s EQ to be enabled.",
                   low: "At 0, the response is flat; small values soften every boost and cut.",
                   high: "At 1, applies the full curve as drawn."),
        ]
        t += [
            FXKnob("rev_on", "reverb on", 0, 1, 0, step: 1,
                   effect: "Enables reverb on {what}. The wet contribution fades smoothly when toggled.",
                   low: "0 disables the reverb contribution.",
                   high: "1 enables reverb at the configured mix."),
            FXKnob("rev_type", "reverb type", 0, 1, 0, step: 1,
                   effect: "Chooses the reverb algorithm at this insert. Requires reverb to be enabled.",
                   low: "0 selects Bigverb, a wide, modulated hall.",
                   high: "1 selects Room, a tighter room response; this is a choice of character, not reverb strength."),
            FXKnob("rev_mix", "reverb mix", 0, 1, 0.3,
                   effect: "Adds reverb at this insert while keeping the dry signal at unity. Requires reverb to be enabled.",
                   low: "Less wet sound; 0 leaves only the dry path.",
                   high: "More wet sound; 1 is the maximum added reverb level, not wet-only output."),
            FXKnob("rev_size", "reverb size", 0, 1, 0.93,
                   effect: "Sets reverb persistence: feedback for Bigverb, or a 0.25–8 second decay range for Room. Requires reverb to be enabled.",
                   low: "A shorter, less lingering tail.",
                   high: "A longer, more sustained tail that accumulates more sound during a phrase."),
            FXKnob("rev_cut", "reverb cutoff (Hz)", 500, 20000, 10000,
                   effect: "Sets the high-frequency damping cutoff in this insert’s reverb. Requires reverb to be enabled.",
                   low: "A darker tail with more upper-frequency absorption.",
                   high: "A brighter tail retaining more upper-frequency detail."),
        ]
        return t
    }()

    /// The rack's specs: the template instantiated per point.
    private static func fxRackGroup() -> (name: String, params: [ParamSpec]) {
        (fxGroupName, fxPoints.flatMap { point in
            fxTemplate.map { k in
                ParamSpec(point.key(k.knob), "\(point.name): \(k.label)",
                          group: fxGroupName,
                          k.lo, k.hi, k.def, step: k.step, apply: .live,
                          insert: ParamInsert(point: point, knob: k.knob,
                                              knobLabel: k.label),
                          effect: k.effect.replacingOccurrences(
                              of: "{what}", with: point.what),
                          low: k.low, high: k.high)
            }
        })
    }

    /// The rack as INSERT SECTIONS: each point with its own knobs, in
    /// registry order. The Parameters tab and paramdoc both render a group
    /// this way, so neither needs to know the FX keys.
    public static func insertSections(of params: [ParamSpec])
        -> (flat: [ParamSpec], inserts: [(point: FXInsertPoint,
                                          params: [ParamSpec])]) {
        var flat: [ParamSpec] = []
        var order: [Int] = []
        var byPoint: [Int: (FXInsertPoint, [ParamSpec])] = [:]
        for p in params {
            guard let ins = p.insert else { flat.append(p); continue }
            if byPoint[ins.point.index] == nil {
                byPoint[ins.point.index] = (ins.point, [])
                order.append(ins.point.index)
            }
            byPoint[ins.point.index]?.1.append(p)
        }
        return (flat, order.compactMap { byPoint[$0] }
                            .map { (point: $0.0, params: $0.1) })
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
    public static let inPlaceKeys: Set<String> = Set([
        // --- kernel scalars ---
        "bow_Zt", "bow_body_c0", "bow_br_fc",
        "bow_gut_fc2", "bow_gut_g", "bow_loss_reg",
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
        "bow_attack_bite", "bow_attack_bite_ms",
        "bow_attack_fms", "bow_attack_beta", "bow_attack_speed_db", "bow_tnoise",
        "bow_grip_beta", "bow_grip_v_db", "bow_grip_db", "bow_grip_thresh",
        "bow_grip_release", "bow_grip_wait_ms", "bow_grip_confirm_ms",
        "bow_grip_ms", "bow_grip_rel_ms", "bow_grip_hold_ms",
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
        "bow_jt_alpha", "bow_jt_apex", "bow_jt_bst",
        "bow_jt_fhf", "bow_jt_gain", "bow_jt_hcb", "bow_jt_norm",
        "bow_jt_zone", "bow_jt_radius",
        // The chromatic bridge: the same per-row table bake, re-pushed
        // after every jt reload.
        "bow_jtc_gain", "bow_jtc_norm",
    ])

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
