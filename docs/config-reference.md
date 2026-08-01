# Config Reference

System-level tunable parameters live in `Packages/StarpadCore/Sources/StarpadCore/Config.swift`. Tilt-binding endpoint ranges come from the target itself (`MapTarget.defaultRange` in `TiltMapping.swift`): 0–1 for a composite, the parameter's own range otherwise. See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping) and the generated [Parameters](parameters.md) table.

The Mac-side **String voice** parameters are the `bow_*` keys of `ParamRegistry` — the `bowed_string.json` scalars (`SarangiKit`) plus the live bow/taraf/tone axes — all edited in the **Parameters tab** (⌘5). Physics values persist as an override dict (`StringParamStore`); the live/hybrid resting values persist in `AppController.paramValues`. The **tarab** is the editable `[StringSpec]` table on `InstrumentState` (Tarab tab ⌘2). **Composite parameters** (named 0–1 controls built from `bow_*` members) live on `AppController.composites` (Controls tab ⌘4). There is no hosted AU, no base-voice selection, no coupled-network params, and no master-FX bus (all removed 2026-07-24; the 2026-08-01 **FX tab** is a new, unrelated rack of `fx_*` registry params inside `BowEngine` — see [FX](fx.md)). See [Sound Design](sound-design.md) and [Sarangi](sarangi.md).

## Keyboard

The legacy keyboard is no longer on the playing path. The playing scale is a `PitchScale` of JI ratios, edited on the Mac in the Fret Pad tab and synced to the iPad. See [Scales and Tuning](scales-and-tuning.md) and [Fret Pad](fret-pad.md).

## Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| `velocityDelay` | 200ms | Time to wait after touch for accelerometer spike. Skipped entirely when no parameter uses the Pressure dimension. |

**Tuning**: Lower = faster response but may miss the spike. Higher = more reliable velocity but adds latency.

## Glide

| Parameter | Value | Description |
|-----------|-------|-------------|
| `glideDistanceExponent` | 0.6 | Sublinear distance scaling. 1.0 = linear, 0.5 = sqrt |
| `releaseGracePeriod` | 50ms | Window after all touches lift to connect next tap as glide |
| `glideMidpoint` | 0.6 | Sigmoid midpoint `m`. Lower = faster onset |

**Tuning**:
- `glideDistanceExponent`: Lower = larger intervals complete faster relative to small ones. At 0.6, an octave (12 semitones) takes ~4.4x a single semitone rather than 12x.
- `releaseGracePeriod`: Increase if notes are disconnecting when you intend them to be legato.
- `glideMidpoint`: 0.5 = symmetric. Lower values shift the fast phase earlier (faster onset, gentler landing).
- Glide speed and compression ranges are dimension-mappable (defaults: 20–200 ms/st and 15–40 ms).
- Glide curve steepness (k) is dimension-mappable (default range 3–12).

## Drag Glide

| Parameter | Value | Description |
|-----------|-------|-------------|
| `dragSnapDelay` | 60ms | How long the finger must be still before snapping to a scale tone |

**Tuning**:
- `dragSnapDelay`: Lower = snaps sooner when finger pauses. Higher = more tolerance for brief pauses mid-slide.
- Drag smoothing is dimension-mappable (default range 0.1–0.5). Snap smoothing is 2× the base value, clamped to 1.0.

## MIDI

| Parameter | Value | Description |
|-----------|-------|-------------|
| `midiPitchBendRange` | ±48 semitones | Must match the receiving synth's pitch bend range |

**Tuning**: Must exactly match the receiving instrument. Ableton MPE default is ±48. Other synths may use ±2, ±12, or ±24. Mismatched values cause pitch bend to be scaled incorrectly.

## Audio

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sampleRate` | 44100 Hz | Audio sample rate |
| `frequencySmoothing` | 0.002 | Per-sample smoothing coefficient (~11ms time constant) |
| `attackCoefficient` | 0.05 | Envelope attack speed (~2ms to reach full amplitude) |
| `releaseCoefficient` | 0.9993 | Envelope release speed (~50ms to fade out) |
| `maxAmplitude` | 0.3 | Maximum amplitude at velocity 127 (headroom for clipping) |

**Tuning**:
- `frequencySmoothing`: Lower = smoother glides on audio thread, but more latency. Higher = tighter tracking but potential zipper noise.
- `attackCoefficient`: Higher = snappier attack. Lower = softer onset. Keep below 0.1 to avoid clicks.
- `releaseCoefficient`: Closer to 1.0 = slower release. Must be < 1.0. Voices are removed when envelope < 0.001.
- `maxAmplitude`: Increase for louder output (may clip with amplitude boost). Decrease if distortion occurs.

## Motion

| Parameter | Value | Description |
|-----------|-------|-------------|
| `motionUpdateRate` | 200 Hz | CoreMotion sample rate |
| `accelHistoryLength` | 200 | Display buffer size (~1 second at 200Hz) |
| `accelBufferDuration` | 100ms | Ring buffer for velocity correlation |
| `peakDecayRate` | 0.95 | Peak indicator decay per sample |

**Tuning**: Generally don't change these. `motionUpdateRate` above 200Hz gives diminishing returns. `accelBufferDuration` must be > `velocityDelay`.

## Velocity Mapping

| Parameter | Value | Description |
|-----------|-------|-------------|
| `velocityMinG` | 0.01g | Accelerometer reading for softest playable tap |
| `velocityMaxG` | 0.5g | Accelerometer reading for hardest tap |

**Tuning**: Adjust based on the player's touch and the specific iPad model. Narrower range = more sensitive. `velocityMinG` too low may trigger from ambient vibration. These only apply when Pressure is in use.

## Sliders

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sliderWidth` | 150pt | Slider track length (~1.5 inches on iPad) |
| `sliderHeight` | 66pt | Slider track height (1.5× finger-width) |
| `slider1Default` | 0.5 | Value Slider 1 returns to when released |
| `slider2Default` | 0.5 | Value Slider 2 returns to when released |

**Tuning**: Adjust defaults to match the most common resting value for the parameter they're mapped to. `sliderWidth`/`sliderHeight` can be adjusted for ergonomics.

## String voice (Mac)

The played voice is the **String kernel** (`SarangiKit.BowEngine` + `CBowKernel`, fed by `bowed_string.json`). Its parameters are the `bow_*` keys, edited in the **Parameters tab** (⌘5) over `ParamRegistry` (seven voice groups plus the four `fx_*` groups of the [FX rack](fx.md); `rebuild` rows ride a debounced off-main rebuild, `live`/`hybrid` rows apply instantly) and persisted as an override dict (`starpad.stringOverrides.v1`) plus the resting-value dict (`starpad.controlDefaults.v1`). Audition scores reach any parameter via `voiceParam` name `string.<key>` or `param.<key>`. The exhaustive per-key treatment is in [Sarangi](sarangi.md); the groups are:

| Group | Keys (representative) |
|-------|-----------------------|
| Body (formula modes) | `bow_body_*`, `bow_yinf`, `bow_kret` |
| Bow & string | `bow_mu_*`, `bow_v0`, `bow_Zt`, `bow_gut_*`, `bow_nut_fc`, `bow_br_fc`, `bow_noise*`, `bow_tors_*`, `bow_age_*`, `bow_cr_*` |
| Playing ranges | `bow_v_lo/hi`, `bow_live_beta_*`, `bow_live_press_*`, `bow_expr_lift`, `bow_f_cap`, `bow_live_poly` |
| Jawari taraf | `bow_jtaraf_on`, `bow_jt_*` |
| Articulation | `bow_place_ms`, `bow_draw_*`, `bow_attack_*`, `bow_vib_*` |
| Radiation & output | `bow_rad_*`, `bow_w`, `bow_live_trim`, `bow_rev_*`, stereo `bow_st_*` |
| Drones | `bow_drone_*` (excitation level/envelope, drive band `bow_drone_lp_hz`/`bow_drone_hp_hz`, kin spread `bow_drone_spread` — mellow-drone rev 2026-07-26; `bow_drone_comp_cents` retired 2026-07-25 with the dedicated drone rows) |

### Sympathetic-string table (tarab) + tuning

The taraf bank is a fully editable `[StringSpec]` table — each row `(degree, octave, gain, t60, enabled)`, the pitch a **scale degree + octave** of the centralized Pitch Pad scale (2026-07-25; absolute Hz is minted at resolve time on a millihertz grid against the one tonic) — edited in the **Tarab tab (⌘2)** as one flat pool via pitch/octave dropdowns (the chromatic row, the choir grouping, and the per-string ratio/Hz inputs are all gone); the rows tune the kernel's in-kernel modal-jawari taraf. (Until 2026-07-24 they also fed a second, LINEAR comb web — `bow_taraf_*`/`bow_open_*`; that web is deleted and the jawari block is the whole sympathetic response, so a row that the jawari selection doesn't pick up is now inert.) **Pitches always follow the scale — there is no opt-out** (the "Follow the Pitch Pad scale" toggle was removed 2026-07-25); the row layout regenerates when the scale's degree count changes or via the tab's "Regenerate from scale" button — `RagaTuning.buildSpecs` (one string per degree + Sa/Pa doublings + low- and upper-octave repeats; the detune chorus died with the scale-defined model, so strings sit exactly on the scale's JI grid). Editing a row, adding/removing strings, or a scale change triggers a structural rebuild. See [Sarangi](sarangi.md).

### Composite parameters

Named 0–1 macros (`CompositeParam`, `AppController.composites`, persisted `starpad.compositeParams.v1`) built from `bow_*` parameter members each sweeping lo→hi as the composite rises. Ships with **Taraf Purity** (the jawari tone LP + the recruitment amount `bow_jt_sel`), **Taraf Decay**, **Tone Tilt**, **Expression** on slots 1–4. Bound to tilts in the Controls tab (⌘4) — where a tilt may equally bind a single parameter directly; audition names `stringPurity` / `stringTarafDecay` / `stringToneTilt` (slots 1–3) + generic `composite1`–`composite8`.

### Preset

One preset ships — **"Default (Sarangi Live) — Pilu"** (also the fresh-install default): untouched artifact physics + the generated Pilu-scale seed bank (re-aligned to the centralized Pitch Pad scale on the first push). `InstrumentState` persists to UserDefaults (`starpad.sarangiState.v8`) and exports/imports as a `.sarangi` JSON file.


## Polyphonic Mode

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maxPolyVoices` | 16 | Maximum simultaneous voices in poly mode (iPad channel allocation). The String voice's own polyphony is `bow_live_poly` gut strings on one shared bridge (poly-as-physics). |

## Display

| Parameter | Value | Description |
|-----------|-------|-------------|
| `pitchHistoryLength` | 120 | Pitch graph buffer (~2 seconds at 60Hz) |
| `peakDelayHistory` | 20 | Rolling window for velocity delay instrumentation |

**Tuning**: Increase `pitchHistoryLength` for a longer graph (more memory, wider view). Decrease for a more zoomed-in, responsive view.
