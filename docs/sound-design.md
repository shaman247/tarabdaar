# Sound Design

Sound design lives on the Mac (TarabdaarMac). The iPad is a controller — it streams TLP touch/tilt frames ([MIDI & Audio](midi-and-audio.md)) and produces no audio. The Mac renders three voices from the one [Fret Pad](fret-pad.md): the sarangi **String voice** (the default played voice — this page), the [Tanpura](tanpura-voice.md) (default drone voice, optional main instrument) and the [Sitar](sitar-voice.md) (main-instrument only). The String voice is `SarangiKit.BowEngine` driving the `CBowKernel` C friction kernel. Its C/Swift signal path owns the bowed gut strings, physical raga and quadratic chromatic sympathetic banks, formula body, radiation and room.

## Signal path

```
TLP touches ► BowControlMapper ► StringVoiceSource (BowEngine + CBowKernel, 96 kHz → 48 kHz) ► symGain ► final gain + limiter ► mainMixerNode ► out
```

`StringVoiceSource` (`Packages/TarabdaarCore/.../StringVoiceSource.swift`) wraps the `BowEngine` as a 48 kHz `AVAudioSourceNode` connected directly to `symGain → final gain + limiter → mainMixerNode`. The kernel runs at 96 kHz and half-band-decimates to 48 kHz; the mixer converts to the engine rate. The String engine owns its body and room; its four-point [FX rack](fx.md) also runs inside `BowEngine`. The tanpura and sitar are sibling source nodes; the sitar's output and the tanpura's `tp_taraf` tap charge the String kernel's jt web through its inject ring. Full physics: [Sarangi](sarangi.md).

## The played voice — the String kernel

The kernel is `bow_kernel_poly.c` (always `-O3`), Tarabdaar's own code; `TarafRemovalParityTests` pins a SHA-256 of the shipped render so an accidental edit fails loudly. It is fed by **`bowed_string.json`** (`Presets.bowedStringParams()`).

### Played strings

`bow_live_poly` gut strings on ONE shared delay-free bridge (poly-as-physics). Every note-on mounts a fresh string with a fresh attack; within a note the filter ramps log2 f0 linearly to the latest wire target across each render block, so all meend is the finger's own trajectory at wire rate — the instrument adds no glide shaping ([Glide System](glide-system.md)).

- **Register damping** (`bow_loss_reg`, shipped 0.7). The fitted nut/bridge/gut loss corners (`bow_nut_fc`/`bow_br_fc`/`bow_gut_fc2`) are absolute frequencies, so a note below the tonic would keep its corners as sharp as the fitted register — brassy, with a hollowed fundamental. Armed, the corners scale as fc·(f0/tonic)^γ for notes BELOW the tonic only (per sample, continuous at the tonic, at/above untouched). A kernel scalar: pushes in place, rides a tilt. The law is implemented in the played-string kernel.
- **Slide dulling** (`bow_slide_dull` 0.35 / `bow_slide_rate` 900, Liveness group). A moving finger absorbs more top than a stopped one: the kernel tracks each string's own pitch slew (signed 10 ms pre-smoothing, 80 ¢/s floor — STEADY notes render byte-identically with the key armed), maps r/(r+rate), smooths 15 ms / 120 ms, and scales the loop corners down by dull×env. The tone dulls through the slide and blooms back on arrival.
- **Slide noise** (`bow_slide_noise` 0.008 / `bow_slide_acc` 25 000 ¢/s²). Finger-slide friction noise injected at the nut write (the finger IS the nut-side termination), driven by the slew's DERIVATIVE — 6000 ¢/s² floor, 10/100 ms envelope, half-saturation at `bow_slide_acc` — so it scrapes where the finger starts, stops or turns and stays quiet through a constant-rate meend. The motion tracker and nut excitation live in the played-string kernel.
- **Glide grace.** A final finger lift releases immediately. With glide enabled, the next onset within 150 ms reopens the released string and glides from its last pitch. The mapper preserves its serial and waveguide state; the filter skips the fresh bow engagement on resume.
- **Release decay** (`bow_release_t60`, String · Damping, factory 8 s, in-place). Adds a gentle broadband loss only after lifting a touch. Shorter positive values shorten the ring; 0 keeps natural decay. This t60 describes the added loss, which combines with the string's existing losses. A fresh note smoothly damps all earlier released played strings with a 120 ms additional t60, preserving held chord notes and the sympathetic/room tails. Glide grace reconnects the existing string instead.
- **Articulation.** `bow_attack_sharpness` is the only attack parameter, captured at each fresh touch. It selects one **320–20 ms** bow engagement; speed and force follow the same finite smoothstep. The factory **0.8** gives a **34.8 ms** draw, while the string and body determine the audible rise. Expression, pressure and position set its tone through the ordinary bow law. Release and continuous glide reconnection retain the **25 ms** gate smoother. See [Sarangi](sarangi.md#articulation-and-sustain) and the reference experiment (local research: `tools/experiments/reference_onsets/README.md`).
- **Control rate.** `BowControlFilter` evaluates the whole dynamics / wedge / engagement law once every 32 kernel samples (~0.33 ms at 96 kHz) on the axes lerped to the segment's end, and lerps its (velocity, force, β) across the segment; pitch, the gate, the vibrato phase and the liveness smoothers advance every sample. Per-sample evaluation cost 6–10 transcendentals per slot-sample for a curve the wire only moves at 120 Hz.

Mechanisms and traps: [Sarangi](sarangi.md).

### The sustain-liveness layer

`BowControlFilter`, "Liveness" registry group. Two mechanisms, dB-shaped on the bow controls, all **0 = bit-null**:

1. **OU drift.** Three independent Ornstein–Uhlenbeck walks (deterministic per-slot xorshift64; panic → `reset()` rewinds, so renders reproduce) at `bow_drift_hz` 1.2, scaling into pitch cents (0.55), vbow dB (0.15) and force dB (0.3) — the not-quite-vibrato life of a held note, its harmonic shimmer arriving through the body slope. **TRAP:** the fitted sarangi body is ~3 dB/¢ steep around D4, so tune drift to the LEVEL outcome (0.55 ¢ ≈ 0.7 dB std), not to a violin's pitch depth — 2 ¢ reads as slow tremolo. Do NOT inject per-harmonic motion directly.
2. **Glide dip.** The bow eases toward `bow_glide_dip_db` 5 · r/(r+`bow_glide_dip_rate` 900 ¢/s) while the SOUNDING pitch slews (15 ms attack / 120 ms release; full depth on vbow, 0.3× on force — more slows the string's re-capture). Fast finger glides dip 2–7 dB; drift-rate motion (~20 ¢/s) never triggers it.

The optional drift and glide lightening act on the physical bow controls. Onset contracts are covered by `BowAttackTests`; zero-valued optional render paths are covered by `ByteNullContractTests`.

### The sympathetic banks

`bow_jt_*`, always on — modal steel strings over grazing jawari bones. Raga rows run on their worker pool with a 64 ms audio reserve; chromatic rows use a 24-mode, four-contact quadratic model in the current callback at 96 kHz. These banks provide the instrument's sympathetic response: physical raga rows use their fitted radiation response, while chromatic rows radiate contact plus termination force. Both feed the shared taraf output chain. Tuned from the **Strings tab** rows.

- `bow_jt_drive` (`.live`, 0.03 = bit-exact): how far the rows swing into the bone — the graze operating point, kernel-slewed ~40 ms so it sweeps under a tilt without a strum. `bow_jt_drive_norm` (`.live`, 0.7) compensates the level swing on the row output — 0 = raw physics (46 dB over the range), 1 = constant loudness — averaged over the energy the web holds, so a sweep never pumps a ring-out.
- `bow_jtc_evolve` (`.live`, 0.5 = bit-exact): the chromatic bank’s kernel-slewed bone lift, the one sanctioned runtime bone move, tilt-sweepable without a strum — makes the twang cascade fast-and-reliable (1) or absent (0).
- `bow_jt_ev_reg` (`.live`, 0 = byte-null): tilts chromatic evolution by register — evolve units per octave from the tonic — so the low Sa/Pa anchors' sustained cascade bloom is dialable on its own.
- `bow_jt_hp` voices the ring as the jawari formant; `bow_jt_body` (`.live`, 0 = byte-exact) blends the radiated taraf through the voice's own body radiation bank — the coherence lever.

Mechanism and measurements: [Sarangi](sarangi.md).

The raga harmonic-cleanup filter is an immediate, exact passthrough at its
20000 Hz bypass setting (the default). Enabled cleanup adds a pitch-dependent
21–171 ms analysis delay; bypass adds none. This keeps the unfiltered raga
response closer to the played voice and avoids spreading its onsets by register.
The asynchronous bank retains its 64 ms worker reserve, and the fitted radiation
response and natural sympathetic buildup still shape the attack. Live cleanup
toggles crossfade between the two timings after filling the analysis window.

For finite chromatic-row plucks, `bow_jt_pluck` selects a short pitched
excitation and `bow_jt_pulse` adds a decaying evolution excursion. Both default
to zero. Excitation decay sets how long energy enters the row; pulse attack
and decay set how the jawari opens and returns; the row's t60 still sets its
natural loss. The taraf sitar study (local research: `tools/experiments/taraf_sitar/README.md`)
includes local comparisons and reproducible measurements. Its original preset
was rejected by listening; use the current measurement report (local research: `tools/experiments/taraf_sitar/measurement_v2/README.md`)
for the remaining differences. It uses the String kernel's rows and the
sympathetic drone routing.

### The formula body

Modal resonators derived from physical scalars (no FIR/fingerprint artifacts): nine signature modes (55–250 Hz) plus the **formant forest** tail — `bow_body_tail_*`: 150 modes, 280–6500 Hz, Q 40, mobility 0.4, radiation 3.5 — so every harmonic sweeps through FIXED peaks and valleys during meend, the body slope the drift shimmer works against. The forest's **radiation residues are Gaussian** (sign and magnitude) from a seeded stream (`bow_body_tail_seed`, `SeededGaussian` in `BowTables`): in the diffuse regime a mode's shape at the bridge and at the listener are independent normal variates, so the radiated sum has Rayleigh statistics — about 10 local peaks per octave, a ripple std ≈ 4 dB against the `bow_body_c0` floor with nulls 25–35 dB deep, and a per-partial vibrato modulation (±25 ¢) of ~2 dB median, ~9 dB at the 90th percentile — where a bounded residue law gave an even scallop half as dense. The seed picks the instrument; every seed has the same statistics. The tail's bridge-load side is deliberately light (positive, bounded admittance residues; the loop cap holds), so stability and wolf behaviour are those of a lightly loaded bridge. All seven `bow_body_tail_*` keys are Parameters-tab rows (rebuild tier); the **Body tab (⌘0)** follows the running engine’s adopted coefficients ([UI Layout](ui-layout.md)).

### Stereo

ONE width law: `bow_st_width` (0.2) — the whole instrument (voice, taraf wash, drones, bow noise) heard from two observation points via a diffuse-field difference bank per bus. Lows stay identical in L/R, the upper spectrum decorrelates like a real instrument's, zero net lean, mono fold-down bit-identical with chromatic compression and stereo-sensitive FX bypassed, plus the width-decorrelated room (`Reverb.processMonoStereo`). It is the WHOLE stereo law — every source stays centred; the legacy per-source pans are gone. Details: [Sarangi](sarangi.md).

## Editing the sound

- **Parameters tab (⌘5).** `ParametersView` over `ParamRegistry` — filterable groups covering **every** parameter, physics and live alike, in native units, each row with a mapping button. `rebuild` rows re-apply through a crossfaded off-main `BowEngine` rebuild ~0.2 s after the value settles (below); `live` and `hybrid` rows apply instantly. All resting values persist together in `tarabdaar.paramValues.v2`. "Default (Sarangi Live)" / "Reset all" clears that store; double-clicking a row label resets one.
- **DEFAULT = ENGINE TRUTH.** An untouched `.rebuild` row displays `ParamSpec.def`, but the engine runs artifact + overrides only — so for a key the artifact does not carry, the authored def MUST equal the engine's code fallback or the tab lies about the sound. `ParamUnificationTests.testAuthoredDefaultsMatchEngineFallbacks` pins the articulation/liveness set; when adding an artifact-absent rebuild key, keep def, code fallback and that test in step.
- **Strings tab (⌘2).** The editable `[StringSpec]` tarab table (below) tunes the sympathetic banks.
- **Controls tab (⌘4).** Named 0–1 composite macros built from any parameters, plus direct tilt→parameter bindings — driven live from the sensors, without a rebuild wherever the parameter allows it.
- **FX tab (⌘6).** The four-insert rack, all `.live` `fx_<point>_*` params, off by default = byte-null ([FX](fx.md)).

## Sympathetic strings — the editable bank

**Two sets on two bridges** — the raga set defaults to twelve Pilu strings: all nine main-octave scale notes plus low Sa, low Pa and upper Sa, using the measured two-direction model. The chromatic set holds both former layouts on the reduced distributed-contact model, with duplicate pitches merged. Its level, level norm and evolution remain `bow_jtc_gain`/`_norm`/`_evolve`; migrated scale rows retain their scale references. Full detail: [Sarangi](sarangi.md#two-bridges-two-sets). Legacy contact-law controls below describe the chromatic model; the raga profile is currently fixed, with a pitch-scaled reference pluck control (0–1 reference mm, default 0.5) and optional harmonic-selective radiation cleanup, bypassed by default. At pitch ratio `r = frequency/561`, actual displacement is reference displacement divided by `r`; the stronger range can yield rough contact motion.

Each row stores `(degree, octave, gain, t60, enabled, set, followsScale)` and a stable ID. Bridge and pitch source are independent: `followsScale` rows use the Fret Pad scale; other rows use the fixed JI chromatic grid. Both resolve against the one tonic on a millihertz grid. `SarangiStore` owns the document, and the Strings tab edits separate raga and chromatic tables with the appropriate pitch picker. A row outside the jawari selection is inert.

Scale-reference rows follow scale edits. The raga layout regenerates when the scale's degree count changes or via "Regenerate from scale"; other hand edits persist. `InstrumentState.normalizeStrings` sorts by pitch and keeps one string per pitch **per bridge**. There are no per-string ratio/Hz inputs or detunes; the tonic on the Fret Pad tab is the app's only Hz input.

### The controller strum set

The Strings tab also holds the drone-button mapping and the **strum set** (`InstrumentState.strumStringIds`): the strings the Joy-Con L button sounds all at once as a **held chord in the MAIN voice** — default low Sa · low Pa (`autoStrumMapping`), remappable to raga chords (scale-degree references, so a chord re-voices with the scale). The chord goes through the shared `pitchPad` touch path (`AppController.strum(pressed:)` → `PitchPadEngine.noteOn(ratio:)`), so it sounds on whichever main instrument is selected, allocates fresh strings under the normal laws and charges the taraf like played notes; it sustains while L is held. The set follows the pool invariant (twin folds re-point members, deletions prune, regenerate restores the default — `DroneStringTests`).

- **Its own expression** (`ctl_strum_expr`, Controller group, bound to the Joy-Con Stick Up / Stick Down by default): a per-slot expr multiplier in `BowControlMapper`, pushed LIVE to the held notes. The wire's touch record is untouched and every non-strum path multiplies by exactly 1.0; plucked mains consume it at the onset as a pluck-level scale. The same per-slot scale carries the **pitch accent** (`ctl_fret_accent`, [Fret Pad](fret-pad.md)) — `AudioEngine` hands the voice the product of the two.
- **A hard shake can strike it** (`ctl_strum_thresh`, 0…1, default 1 = off): the iPad's strike envelope crossing the threshold triggers as an L press and releases when it falls back below, with a 100 ms retrigger cooldown (the L button ignores the cooldown).
- **The chord bar overrides the set.** With a chord selected in the strip below the Fret Pad's band ([Fret Pad](fret-pad.md)), the strum plays THAT chord — octave-agnostic, sounded under the **Shepard register law** (`shepardChordNotes`: pitch-class chord tones as raised-cosine-weighted octave copies centered in the octave below the tonic, so a VII chord sits no higher than a I chord); deselecting falls back to the configured set. A selection change while the chord is RINGING retunes it in place — surviving members glide, surplus notes release, extra members strike fresh (`AppController.retuneStrumChord`).

## Fitted observation controls

**Output · Fitted model** exposes the shared research timbre and acoustic
response. Harmonic correction and spectral response are independent live
amounts (0 bypass, 1 fitted). Bow history scales the 180 ms control-memory
features; timbre smoothing sets the 10–150 ms gain response, default 30 ms.
The upper shelf controls 6 kHz coloration. Acoustic room controls the fitted
synthetic convolution, with separate low/mid/high gains at 1 and 3 kHz.
Acoustic resonances adds force-driven output modes; it never replaces the
physical taraf or enters its feedback. Fitted body radiation blends the
shared modal residues in place, retaining the body's mobility coefficients.

Every added sound stage defaults to zero. Saved presets carry these controls
through the ordinary parameter dictionary and mappings; loading a preset that
omits them restores bypass. The factory artifact remains unchanged. The
research preset uses fitted main-voice settings and the user's existing taraf,
scale and controller rig. The old room and FX reverbs remain independently
available; the research preset sets the original room mix to zero.

The registry also exposes the fitted contact width and thermal relaxation in
String · Friction, and bridge-resonance gain, frequency and Q in Output · Tone
& stereo. These values pass through preset loading as model scalars. Preset
conversion retains the saved resting values of performance controls; an
artifact's vibrato capacity does not activate vibrato. `paramdoc --json`
provides the same strategy and resting-default metadata to the converter.
The converter takes an explicit verified version-2 production preset and rejects a
snapshot without bridge/pitch-source tags or the complete current parameter set.
Its hashed research profile names the only parameters it may replace. Both
taraf banks, including disabled rows, controller bindings, bow-axis curves,
scale/fret layout, routing and unrelated parameter values remain exact copies.
A sidecar audit lists every changed value and the preserved sections.
Preset equality alone cannot validate a source captured by an older app;
compare its banks and bindings with the current rig before conversion.

The live timbre correction is causal. It converts the fitted spectral gains to
a minimum-phase FIR and crossfades successive filters, with no fixed lookahead
or block delay. This preserves fitted magnitudes while changing phase and
transient fine structure relative to the offline centered transform. The
fitted room retains its full synthetic impulse response. Details and
reproducibility: [live research port](../tools/live_research_port/README.md).

## The factory preset

The **"Default (Sarangi Live) — Pilu"** factory action restores untouched artifact physics, default controls and the current Strings **Default** setup. Fresh installs use that Strings setup against the active Fret Pad scale; the bundled bank captures 12 raga and 16 chromatic rows. The whole `InstrumentState` persists to UserDefaults (`tarabdaar.sarangiState.v8`).

## Saving and loading presets

UserDefaults persists the sarangi `InstrumentState` (`tarabdaar.sarangiState.v8`), every parameter's resting value (`tarabdaar.paramValues.v2` — physics scalars, live knobs and hybrids in one dictionary; a key that is absent rests at its default), composites (`tarabdaar.compositeParams.v1`) and tilt bindings (`tarabdaar_dimensionMapping_v6`), alongside the curve and routing stores. Bindings and composites modulate on top of the resting values and never write them.

Launch reads the current parameter, EQ-curve and bow-axis-curve stores. Missing stores use factory defaults; superseded defaults stores and retired scalar curve controls are not imported. File loading retains the version-1 preset compatibility below, including split parameter sections, scalar curves and the older strum-threshold units.

They save and load as **one `TarabdaarPreset` document** via `AppController.capturePreset(name:)` / `applyPreset(_:)`. New saves are complete version-2 snapshots: both string banks and their identities, drone/strum assignments, every resolved parameter rest (including defaults), all EQ and bow-axis curves, composites, controller bindings, voice routing, drone sequence, full scale points/labels, tonic, fret positions/extents, octave display range and snap distance. Hybrid rests remain performance values; build-time vibrato capacity is never saved as an active depth. Empty EQ and composite sections are explicit, so loading a flat/empty setup clears the previous rig's values. The snapshot records the writing app's version/build. Device connections and calibrations, held notes, live sensor positions and temporary performance octave shifts remain session/device state.

Version 2 stores its required sections inside `snapshot`. A legacy flat-format reader sees no applicable sections rather than loading half a rig. The current reader rejects unsupported versions, incomplete snapshots, missing modern string-bank tags, unknown active controller targets and unsupported snapshot parameter keys before changing live state. Retired prime-limit fields in older playing surfaces are ignored and omitted on save. The retired output-limiter keys (`bow_lim_thresh`, `bow_lim_rel_ms`) and pitch-history adaptation key (`ctl_taraf_adapt`) are removed from values, physics overrides, direct bindings and composite members before snapshot validation; unrelated unsupported keys still fail. Saved controller stores also prune retired targets and members at launch. Legacy version-1 full and partial files remain readable; missing sections in those files still leave existing state alone. Loading applies the saved scale and tonic to the shared `Tuning` before installing the string bank, and discards pending gesture rebuilds from the previous rig. The bank therefore retains its row identities through the subsequent scale sync.

**No file panels.** Saved presets live in the app-managed **library** (`PresetLibrary`, `Application Support/Tarabdaar/Presets/`, one `.tarabdaar` file per preset named after it). **Save preset…** asks for a name. The library validates the encoded document, preserves the previous bytes under `Presets/Backups/` on overwrite, then replaces the preset atomically. A failed encode/validation does not overwrite the existing file. Every saved preset appears in **Load preset**; backups stay outside that menu. **Delete preset** removes the selected library entry. The menu refreshes on save/delete and toolbar appearance, so copying a `.tarabdaar` file into the folder imports it. Guards: `PresetCodingTests`.

The Strings tab also has an independent [Strings preset library](sarangi.md#the-strings-tab-2-and-the-tarab-model).
It saves the tab's editable configuration without changing the playing scale,
tonic, other voice parameters or control bindings when loaded. Its **Default**
snapshot seeds missing Strings settings on launch; existing autosaves take precedence.

**Traps:**

- A tilt binding survives a round-trip **only through its `MapTarget.storageKey`**. Version-2 snapshots reject unknown active targets. Legacy mappings still prune unknown `param:` keys (`DimensionMapping.pruned`), so renaming a parameter requires a migration for older files.
- `StringParamStore.replaceOverrides` **clears `dirtyKeys`** to force the full rebuild path rather than the in-place push. That is required: a preset can move keys that resize tables, which the in-place path refuses.

## Drones

The Joy-Con drone sequence uses three slots, each mapped to **one sympathetic string** (Strings tab "Drones" section, `InstrumentState.droneStringIds`; auto-mapped to the loudest strings near low Sa · low Pa · Sa) — on the Tanpura drone voice by default, on the sympathetic bank via the tab's Voice picker. There are no dedicated drone rows: Tanpura drones sound one octave below the mapped row by default, with Joy-Con Up toggling the original octave for subsequent plucks; sympathetic drones sound exactly as their row is tuned, and an unmapped/disabled/unselected row leaves the slot silent. Full treatment and calibrated levels: [Fret Pad](fret-pad.md).

## Levels

Calibration is inside the fitted preset: `bow_live_trim` / `bow_rev_*` set the output level, and **`bow_gain`** (0…4, def 1 = bit-exact) multiplies the trim as the PERFORMANCE master volume of the whole radiated instrument — the knob that moves total loudness where expression can't, because the taraf keeps ringing. Its maximum is about +12 dB relative to the calibrated level. The expression command passes through the user-editable Expression transform
before it controls the physical bow. Pressure and position have matching curves,
initially identity. The Transforms tab edits freely placed input/output points
with bounded linear interpolation; Identity restores raw response and Factory
curve restores the shipped calibration. Curves persist in their own structured
store and the `bowAxisCurves` section of `.tarabdaar` presets. Older fixed-band
settings migrate to points without changing their response.

**Factory expression curve.** With taraf disabled, the curve targets equal dB
steps: −36 dB at command 0.1, then +4 dB per 0.1 up to full level at 1.
Command 0 is silent; the first tenth fades into that finite range. The fit uses
the median normalized sustained stereo RMS over five notes from 164.45 to
657.8 Hz at pressure 0, position 1. Validation at intermediate commands measures
0.28 dB RMS error in that median curve (0.27 dB at the tonic). This is a dB-based
loudness progression, not linear amplitude. Low-register regime changes at low
pressure can depart by as much as 15.9 dB; a shared static curve does not correct
note-dependent vibration regimes. At factory pressure/position, all-note RMS
error is 0.54 dB. Measurement procedure, plots and limitations:
expression calibration (local research: `tools/experiments/expression_response/README.md`).

**Final output.** `output_gain_db` (−60…+24 dB, default 0) applies after the complete String, Tanpura and Sitar outputs are summed, including drones, effects and release tails. The final audio unit ramps gain changes over 20 ms, then applies linked stereo peak protection. Its render callback uses preallocated storage and never waits for a control writer or meter reader. The Mac’s persistent output strip and Parameters → Output · Final edit the same registry value; presets, composites and bindings use the ordinary parameter path. Older presets without the key restore 0 dB. The existing `bow_gain` remains specific to String + taraf.

The output-meter tap shares the mixer's explicitly connected 48 kHz output format.
That connection is established before the tap, so the device consumes samples at
the declared rate. See [the audio graph contract](midi-and-audio.md#audio-graph-mac-audioengineswift)
for startup ordering and sample-rate diagnostics.

The output strip shows independent L/R sample peaks after gain and limiting, before device volume. Bars hold for 600 ms, then fall at 24 dB/s; numerical maxima and **CLIP** latch until **Reset meters**. Any output sample at or above absolute amplitude 1 (0 dBFS), or invalid source sample, latches CLIP. Invalid source samples are replaced with zero before entering the delay. **LIMIT** shows the shared attenuation in dB, in amber while active; it holds the largest reduction for 600 ms before falling at 24 dB/s. The readouts are nondestructive. The shared main-mixer tap also feeds optional pluck diagnostics, so recordings capture the protected mix. These are sample peaks, not oversampled true peaks or measurements of analog output voltage.

The output strip also exposes independent **Main**, **Chromatic taraf** and **Raga taraf** interval RMS levels with maxima retained by the existing 60 Hz bus-meter poll. **Reset meters** clears all output and bus maxima together. These RMS readings include their voice/bank gain and balance but precede `output_gain_db` and the final limiter. The bank taps precede shared taraf FX; Main includes its voice FX and the selected plucked main, excludes the separate drone, and precedes room/global FX. RMS maxima reveal sustained blooms without the limiter hiding their relative level. They do not add up to the final stereo sample peaks: effects, phase, crest factor and the separate drone also contribute to that output. The [bus-meter contract](midi-and-audio.md) defines the tap points.

**Output protection.** The final mix has a linked stereo limiter with three global, live controls in **Parameters → Output · Final**. They save with presets and use the ordinary composite/binding path. Older presets without these keys use the defaults below.

| Parameter | Range | Default |
|---|---|---|
| `output_limiter_ceiling_db` | −24…0 dBFS | −1 dBFS |
| `output_limiter_lookahead_ms` | 1…20 ms | 5 ms |
| `output_limiter_release_ms` | 20…1000 ms | 120 ms |

The fixed 3 dB soft knee starts 1.5 dB below the selected sample ceiling. A shared gain follows the larger absolute L/R sample, preserving stereo balance. Lookahead sets both the audio delay and the triangular attack window, rounded to an even number of samples (240 at the default 48 kHz/5 ms); the AU reports the selected delay as its latency. Release sets exponential gain recovery. When inactive, samples pass unchanged apart from the delay and requested gain. The default one dB margin leaves output headroom; it is not an oversampled true-peak guarantee. A ceiling of 0 dBFS can light CLIP when samples reach full scale. Heavy sustained boost reduces dynamics; the limiter is intended to catch occasional peaks at performance gain settings such as +10 dB.

Live limiter edits warm a second preallocated lane for its lookahead interval, seeding its envelope from the current attenuation, then crossfade the two protected outputs over 20 ms with a smoothstep curve. Neither lane changes delay or ceiling mid-render. During a ceiling change the output remains within the larger of the old and new ceilings, reaching the new ceiling after the transition. A lookahead change can briefly blend different waveform phases; it is best set between phrases. Rapid edits coalesce to the latest request after the current transition. Both lanes reserve the maximum delay storage before rendering, so edits allocate no audio-thread memory and never wait for control writers.

`StereoOutputLimiter` holds each sample's required attenuation for the complete lookahead window with a monotonic minimum queue, then smooths it with two moving averages whose combined support equals that window. When the delayed sample exits, every contributing envelope value is at least as protective as that sample requires. The envelope therefore meets the ceiling without a waveform clipper; a final numerical guard handles roundoff and extreme source levels. `StereoOutputLimiterTests` pins delayed unity parity, burst containment at device sample rates, stereo linking, smooth attack/release and sustained-tone shape. `FinalOutputTests` covers the production three-source graph, gain edits and post-limiter metering.

Both standalone String-engine post-chains still end at the global FX insert; `BowStereoTests` checks their linear gain above full scale. Final mix protection lives outside these engines, after the three-voice sum, and does not restore the retired `bow_lim_*` parameters. The kernel’s physical stability guards and optional voice-relative taraf cap remain independent.

**Kin notes and `bow_jt_norm`.** The hottest notes are the KIN notes — a hard-struck unison Sa/Pa adds the played voice and the jt ring coherently (~+4 dB peak over a non-kin degree, more under high expression). The musical fix is **`bow_jt_norm`** (t60-response normalization — the long-ring Sa/Pa anchor rows charge hotter than the shortened crowd; **0.6 measures near-even across degrees**, 1.0 overshoots and the crowd wins). For the ACCUMULATION side — the anchors remembering a whole phrase and blooming on the next kin note — the voice-relative cap below is the lever.

**Voice↔taraf balance.** One `.live` lever at the SPLIT-BUS merge — the same point as the FX voice/taraf inserts and the iPad volume-readout meter tap (`bow_poly_process3`; `ByteNullContractTests` pins meter-on and neutral-balance parity):

- **`bow_bal`** (−1…+1, def 0): the voice↔taraf mix as a pure ATTENUATOR pair — −1 = voice only, +1 = taraf only, 0 = the calibrated mix bit-exactly. The favoured side never boosts past its calibrated level, so the balance consumes no additional headroom. Slewed ~30 ms with per-sample interpolation; instant like `bow_gain`, so it binds well to a tilt. The iPad's separate main, chromatic and raga readouts include this balance. The bank taps precede shared taraf FX; see [MIDI & Audio](midi-and-audio.md).

**Independent taraf levels.** `bow_jt_gain` controls raga radiation and
`bow_jtc_gain` controls chromatic radiation.
Either may be zero while the other bank rings. Both use in-place row gain
slews, with the common output carrier held constant so moving one bank cannot
pump the other's uncoupled sound. Shared bridge feedback still permits
physical interaction when coupling is enabled. Parameter ownership and
model-specific controls are listed in [Sarangi](sarangi.md#parameter-ownership).

**Direct raga plucks.** **Pluck loudness** (`bow_jt_dual_pluck_level`, in
Taraf · Raga) controls a pluck-triggered radiation boost: 0 is the original
level, 1 is the full calibrated boost, and the default 0.5 is halfway in
decibels. Changes slew over 40 ms and apply to ringing plucks. The boost is
stronger in the low register, approaches its peak smoothly over 4 ms and
returns toward the ordinary sympathetic level with a 2 s time constant.
The plectrum displacement and physical feedback are unchanged. Unplucked rows
retain their ordinary sympathetic level; the plucked row's shared radiation
receives the envelope for its tail. The normal row controls, balance and output gain
remain downstream. Calibration and measurements:
raga pluck balance (local research: `docs/history/Codex-2026-09-23-raga-pluck-levels.md`).

**Raga bow bloom** (`bow_jt_bow_bloom`, default 1) shapes the energy entering
physical raga strings: fresh bow energy charges them, then steady forcing
recedes over a 2.1 s adaptation time so their natural jawari ring changes the
harmonic balance gradually over several seconds. The raga
layer settles softer and quieter under a held bow; output gain does not
compensate that decay. Zero restores continuous drive. This applies to incoming
bridge energy, including coupled return and plucked-voice injection, but not
to the direct plectrum gesture. See [Sarangi](sarangi.md) for the envelope and
the distinction between an isolated pluck and a pluck in a driven bank.

**The voice-relative taraf cap** (`bow_jt_cap` / `bow_jt_cap_ratio`) is the runaway-bloom lever: with high `bow_jtc_evolve` the web can feed itself and bloom LOUDER than the played voice, and a fixed threshold can't follow a phrase's dynamics. The cap side-chains its ceiling from the VOICE bus itself — an instant-attack peak envelope with a slow ~1.2 s-τ release (≈7 dB/s), so a string may ring on after a note and decay more slowly than the voice but never PEAK above what the voice reached.

- Ceiling = voice peak × `bow_jt_cap_ratio` (1 = parity, 0.5 ≈ −6 dB under, 2 = a loose leash). `bow_jt_cap` 0…1 is the hardness — the applied reduction is that fraction of the full dB overshoot: 0 = off (byte-null, the default), 1 = a hard relative limiter. A dimensionless ratio, so it rides `bow_gain` and expression untouched.
- **Applied INSIDE the kernel, string by string** (`bow_poly_jt_set_cap`): the render loop records the voice peak envelope beside the jt drive (sync buffer and async ring alike — state only, byte-null unarmed); the tick scheduler converts it to a per-tick ROW ceiling (voice env × ratio ÷ the jt output gain), and each row runs its own 150 ms peak envelope and gain (3 ms toward reduction / 120 ms recovery) on its radiated output — a pure output gain after the physics, so the string's ring and the quiescence gate both see the un-capped string. Per-row state is worker-owned; an arm edge bumps a generation counter and each row resets itself on its next tick (no control-thread array writes under running workers). The strings sum AFTER the cap, so the whole web can still stand above one string's ceiling.
- Pre-FX and pre-trim; the balance stays a manual mix move after it. One deliberate consequence: armed hard while the voice is silent from launch, the ceiling is ~zero — drones and the tanpura's `tp_taraf` charge are held down until the voice first sounds.

`ByteNullContractTests` pins the cap's hard-0 bypass. Active reduction is implemented by `cap_gain_step` in `bow_jt.c`; the former standalone cap suite is not part of the current guard set.

**Chromatic bank compression.** The Taraf · Chromatic controls
`bow_jtc_comp_ratio`, `bow_jtc_comp_voice` and `bow_jtc_comp_floor_db` restrain
the summed chromatic radiation, including simultaneous rows and independent
plucks. The default ratio 1 is a byte-null bypass; 4 is 4:1 compression, and
20 approaches limiting. The threshold is
`max(recentVoicePeak × voiceThreshold, 10^(minimumThresholdDB / 20))`.
The voice multiplier defaults to 0.5 and the minimum to −40 dB (0.01 internal
bus amplitude). This dB reference is before calibration trim, performance master
gain and shared FX; it is not a final-output dBFS ceiling. The positive floor
keeps a silent voice from suppressing independent plucks to silence.
The separate shared per-row voice cap still acts earlier; if armed, its own
silent-voice behavior remains in effect.

Compression uses a 6 dB soft knee, a stereo-linked peak detector with a 50 ms
release, 5 ms gain attack and 250 ms gain recovery. The voice reference holds
recent peaks with a 1.2 s release. It only attenuates, has no makeup gain or
lookahead, and does not guarantee a maximum transient peak. Returning to 1:1
recovers smoothly to exact bypass. Bank tone/body, row caps and width precede
the compressor; the combined taraf FX and output chain follow it. Raga audio,
mechanical feedback and physical decay remain unchanged. Row scope meters show
pre-compression radiation; the chromatic bank meter shows compressed output.
`ChromaticCompressorTests` pins the relative/floor law, stereo linking and live
bypass recovery; `ChromaticTarafTests` pins bank isolation, bypass parity and
callback-size/worker independence.

## Re-fitting

Change production DSP in `Packages/SarangiKit/`; `TarafRemovalParityTests` detects changes to the shipped render. The app edits values over bundled model artifacts and does not run fitting. Local research and artifact-conversion tools are separate from runtime. Keep fitted artifacts, their calibration and generated metadata consistent, and deliberately bless sound changes after the full guard and listening comparison. See [AGENTS.md](../AGENTS.md) and [Sarangi](sarangi.md).

## Rebuilds and publication

A structural edit constructs a fresh `BowEngine` off the main thread. Table
shape changes and hybrid values beyond built headroom take this path;
`ParamRegistry.inPlaceKeys` identifies edits the existing engine can accept.
Construction cost depends on the bank, contact state and active fitted stages.
Measure the current bank with `RebuildCostTests`; the former initialization
and continuity timings are [archived measurements](history/documentation-audit-2026-10-12.md#original-rebuild-and-continuity-measurements).

**The settle contract.** Setup uses an empty control snapshot; held touches
stay on the shared mapper and mount after publication. The host seeds saved
live controls before requesting its first build. Each build snapshots chromatic
evolution and register offset into the initial geometry, before preparation and
settling, so restoring these controls does not move a resting bridge after its
silence check. Publication refreshes their latest values, including a return to
neutral if the player changed them during construction; unchanged geometry is
a no-op. Residual-checked stationary preparation permits one 4096-frame warmup block; unsupported
states use at least five blocks with 50 ms momentum damping. Natural decay
is then restored and output histories reset without resetting the physical
state. Verification checks both channels and their sum below **−100 dBFS**,
for at most 24 blocks. A still-noisy build returns nil. The host logs the failure
and retains the last working String engine and its bank metadata. Construction
leaves the live mapper's slot limit and held touches intact; only an accepted
publication adopts the replacement's polyphony limit. Failed
plucked replacements likewise retain the engine and touch bindings; an
intentionally empty plucked grid is a successful clear. The shared
`EngineBuildCoordinator` skips obsolete queued work and rejects stale results
before publication, including late String builds after disable.
A publication fade does not replace the silence check.
`RebuildCostTests` guards **−80 dBFS** publication across tunings and bone
positions, plus preservation of held touches.
`StringVoicePublicationTests` also checks saved live geometry against both
audible startup output and bus-meter spikes, and preserves control changes
made during construction.

**Continuity.** `StringVoiceSource.setEngine` publishes through
`EngineCrossfader` and renders outgoing and incoming engines through a
300 ms equal-power fade. A publication during an audio buffer starts fresh
fade progress; the older buffer cannot advance or finish it. The overlap
renders two engines, so `RebuildCostTests` separately checks callback timing.
Rebuilds suit structural edits, not tilt-rate modulation. `ParamSpec.timing`
is the displayed timing contract in the Parameters tab and generated docs.

**Rest fractions.** The `bow_vib_cents` hybrid parameter rests at **0×** its
built depth (`ParamSpec.restFraction`). Its built capacity does not activate
vibrato; the shared player-depth axis controls the live amount.

## In-place parameters

`BowEngine.setLiveParams` stages kernel scalars, mapping constants and
supported coefficient changes for adoption by the running engine. String
histories, taraf motion, room tails and articulation persist.
`ParamRegistry.inPlaceKeys` defines the shipped set, and
`ParamUnificationTests` checks its registry classification. `LiveParamPushTests`
compares a representative pushed friction edit with a rebuilt engine and
pins exact no-op behavior.
`StringParamStore` falls back to a rebuild when an edit needs fresh tables.
An edit arriving during a pending structural build also supersedes that build
with the current overrides, so an older snapshot cannot undo a newer edit.

Body coefficients reload through `bow_poly_set_body`; modal-jawari coefficients
reload through `bow_[poly_]jt_set_coeffs`, which refuses shape changes.
**`bow_jt_load` is initialization-only and allocates:** never call it again
to update a live bank. Physical raga geometry retains its fitted profile;
chromatic coefficients use the supported in-place route.

The Body tab reads a versioned snapshot of the coefficients the kernel accepts,
including current ramped body scalars and radiation filters. It refreshes on
coefficient changes as well as rebuilds; unapplied or rejected tables do not
change the plot. `BowBodyResponseTests` compares adopted diagnostics with a
fresh build and pins no-op and rejected-shape behavior.

**Gain continuity.** Signal multipliers need smoothing as well as continuous
physical state. The live ramp interpolates output gain per sample and caps
render chunks to 256 frames while it runs. `ZipperTests` guards audible seams;
`LiveParamPushTests` guards continuity and supported reloads.

**Chunk boundaries are part of the sound.** They set the control interpolation
grid and deferred-web boundaries. Arm the ramp only when a ramped quantity
changes: no-op pushes stay bit-identical, and coefficient-only reloads do not
arm it. A live edit need not reproduce the waveform of a freshly built state.
The original seam and continuity comparisons are
[archived](history/documentation-audit-2026-10-12.md#original-in-place-and-zipper-measurements).

## Real-time validation

`RealtimePerformanceTests` uses preallocated buffers at `Config.preferredOutputBufferFrames` (128 frames at 48 kHz, a 2.67 ms budget). It exercises mapped parameter motion and full polyphony, plus paced full-bank runs with raga plucks, cleanup changes and fitted observation enabled. The guards require p99 callback time below the buffer budget, no dropouts, bounded seams, and no new worker drops, flat fills or solver failures in the full-bank scenarios. Isolated scheduling outliers are reported rather than treated as a zero-overrun guarantee. Run the gated suites through `tools/test-full.sh`; its realtime/rebuild phase runs serially (see [AGENTS.md](../AGENTS.md)).

**Judge realtime behaviour on p99 with preallocated buffers** — a `[Float]` allocation per buffer or wall-clock timing in a normal-priority process reports phantom overruns. In the app, the overrun watchdog logs render overruns and jawari-web overloads to Console; a run with the parameter motion removed is the control that proves a clean measurement is not measuring an inert path. Not covered: a real iPad over the wire adds link jitter the in-process pump does not have.
