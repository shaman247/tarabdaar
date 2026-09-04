# Sound Design

Sound design lives on the Mac (TarabdaarMac). The iPad is a controller — it streams TLP touch/tilt frames ([MIDI & Audio](midi-and-audio.md)) and produces no audio. The Mac renders three voices from the one [Fret Pad](fret-pad.md): the sarangi **String voice** (the default played voice — this page), the [Tanpura](tanpura-voice.md) (default drone voice, optional main instrument) and the [Sitar](sitar-voice.md) (main-instrument only). The String voice is `SarangiKit.BowEngine` driving the `CBowKernel` C friction kernel: a pure-physics bowed gut string that carries the whole instrument in-kernel — played strings, the sympathetic (tarab) web with its modal-jawari buzz, the formula body, radiation and room. There is no hosted plugin and no coupled bridge–body network (not present — see docs/history/).

## Signal path

```
TLP touches ► BowControlMapper ► StringVoiceSource (BowEngine + CBowKernel, 96 kHz → 48 kHz) ► symGain ► mainMixerNode ► out
```

`StringVoiceSource` (`Packages/TarabdaarCore/.../StringVoiceSource.swift`) wraps the `BowEngine` as a 48 kHz `AVAudioSourceNode` connected directly to `symGain → mainMixerNode`. The kernel runs at 96 kHz and half-band-decimates to 48 kHz; the mixer converts to the engine rate. There is no master filter/reverb bus — the kernel owns its body and room, and the only inserts are the four-point [FX rack](fx.md) inside `BowEngine`. The tanpura and sitar are sibling source nodes; the sitar's output and the tanpura's `tp_taraf` tap charge the String kernel's jt web through its inject ring. Full physics: [Sarangi](sarangi.md).

## The played voice — the String kernel

The kernel is `bow_kernel_poly.c` (always `-O3`), Tarabdaar's own code; `TarafRemovalParityTests` pins a SHA-256 of the shipped render so an accidental edit fails loudly. It is fed by **`bowed_string.json`** (`Presets.bowedStringParams()`).

### Played strings

`bow_live_poly` gut strings on ONE shared delay-free bridge (poly-as-physics). Every note-on mounts a fresh string with a fresh attack; within a note the filter ramps log2 f0 linearly to the latest wire target across each render block, so all meend is the finger's own trajectory at wire rate — the instrument adds no glide shaping ([Glide System](glide-system.md)).

- **Register damping** (`bow_loss_reg`, shipped 0.7). The fitted nut/bridge/gut loss corners (`bow_nut_fc`/`bow_br_fc`/`bow_gut_fc2`) are absolute frequencies, so a note below the tonic would keep its corners as sharp as the fitted register — brassy, with a hollowed fundamental. Armed, the corners scale as fc·(f0/tonic)^γ for notes BELOW the tonic only (per sample, continuous at the tonic, at/above untouched). A kernel scalar: pushes in place, rides a tilt. `RegisterDampingTests`.
- **Slide dulling** (`bow_slide_dull` 0.35 / `bow_slide_rate` 900, Liveness group). A moving finger absorbs more top than a stopped one: the kernel tracks each string's own pitch slew (signed 10 ms pre-smoothing, 80 ¢/s floor — STEADY notes render byte-identically with the key armed), maps r/(r+rate), smooths 15 ms / 120 ms, and scales the loop corners down by dull×env. The tone dulls through the slide and blooms back on arrival.
- **Slide noise** (`bow_slide_noise` 0.008 / `bow_slide_acc` 25 000 ¢/s²). Finger-slide friction noise injected at the nut write (the finger IS the nut-side termination), driven by the slew's DERIVATIVE — 6000 ¢/s² floor, 10/100 ms envelope, half-saturation at `bow_slide_acc` — so it scrapes where the finger starts, stops or turns and stays quiet through a constant-rate meend. `SlideTextureTests`.
- **Articulation.** Analytic Schelleng press envelope, place-then-draw + attack bite: sharpness = max(press law, `bow_attack_vel` × onset strike velocity) — per-note martelé/legato from the iPad's accelerometer strike byte or MIDI velocity, fresh attacks only.
- **Control rate.** `BowControlFilter` evaluates the whole dynamics / wedge / place law once every 32 kernel samples (~0.33 ms at 96 kHz) on the axes lerped to the segment's end, and lerps its (velocity, force, β) across the segment; pitch, the gate, the vibrato phase and the liveness smoothers advance every sample. Per-sample evaluation cost 6–10 transcendentals per slot-sample for a curve the wire only moves at 120 Hz.

Mechanisms and traps: [Sarangi](sarangi.md).

### The sustain-liveness layer

`BowControlFilter`, "Liveness" registry group. Three mechanisms, dB-shaped on the bow controls, all **0 = bit-null**:

1. **Post-onset settle.** The friction loop alone overshoots ~+7 dB for ~0.5 s after capture; `bow_settle_db` 7 / `bow_settle_ms` 130 subtracts a smoothstep-in, exp-out envelope from vbow that is zero through the place+draw window, so the staccato bite is untouched. Every note-on is a fresh mount, so every note settles; `bow_settle_sharp` (default 0) exempts a SHARP attack — depth × (1 − key × sharpness) — so an accented staccato holds its level.
2. **OU drift.** Three independent Ornstein–Uhlenbeck walks (deterministic per-slot xorshift64; panic → `reset()` rewinds, so renders reproduce) at `bow_drift_hz` 1.2, scaling into pitch cents (0.55), vbow dB (0.15) and force dB (0.3) — the not-quite-vibrato life of a held note, its harmonic shimmer arriving through the body slope. **TRAP:** the fitted sarangi body is ~3 dB/¢ steep around D4, so tune drift to the LEVEL outcome (0.55 ¢ ≈ 0.7 dB std), not to a violin's pitch depth — 2 ¢ reads as slow tremolo. Do NOT inject per-harmonic motion directly.
3. **Glide dip.** The bow eases toward `bow_glide_dip_db` 5 · r/(r+`bow_glide_dip_rate` 900 ¢/s) while the SOUNDING pitch slews (15 ms attack / 120 ms release; full depth on vbow, 0.3× on force — more slows the string's re-capture). Fast finger glides dip 2–7 dB; drift-rate motion (~20 ¢/s) never triggers it.

Guards: `LivenessTests` (settle shape, drift bounds/determinism, dip selectivity, absent-keys bit-null); `BowControlsTests` strips the liveness keys for the law tests.

### The modal-jawari taraf, fused in-kernel

`bow_jt_*`, always on — modal steel strings over grazing jawari bones, driven one block late on their own worker pool (the callback never waits). **This is the instrument's entire RADIATED sympathetic response**: the rows radiate their bridge contact force (there is no separate radiation pickup and no linear comb web — not present, see docs/history/). Tuned from the **Strings tab** rows.

- `bow_jt_evolve` (`.live`, 0.5 = bit-exact): a kernel-slewed bone lift, the one sanctioned runtime bone move, tilt-sweepable without a strum — makes the twang cascade fast-and-reliable (1) or absent (0).
- `bow_jt_ev_reg` (`.live`, 0 = byte-null): tilts that axis by register — evolve units per octave from the tonic — so the low Sa/Pa anchors' sustained cascade bloom is dialable on its own.
- `bow_jt_hp` voices the ring as the jawari formant; `bow_jt_body` (`.live`, 0 = byte-exact) blends the radiated taraf through the voice's own body radiation bank — the coherence lever.

Mechanism and measurements: [Sarangi](sarangi.md).

### The formula body

Modal resonators derived from physical scalars (no FIR/fingerprint artifacts): nine signature modes (55–250 Hz) plus the **formant forest** tail — `bow_body_tail_*`: 150 modes, 280–6500 Hz, Q 40, mobility 0.4, radiation 3.5 — so every harmonic sweeps through FIXED peaks and valleys during meend, the body slope the drift shimmer works against. The forest's **radiation residues are Gaussian** (sign and magnitude) from a seeded stream (`bow_body_tail_seed`, `SeededGaussian` in `BowTables`): in the diffuse regime a mode's shape at the bridge and at the listener are independent normal variates, so the radiated sum has Rayleigh statistics — about 10 local peaks per octave, a ripple std ≈ 4 dB against the `bow_body_c0` floor with nulls 25–35 dB deep, and a per-partial vibrato modulation (±25 ¢) of ~2 dB median, ~9 dB at the 90th percentile — where a bounded residue law gave an even scallop half as dense. The seed picks the instrument; every seed has the same statistics. The tail's bridge-load side is deliberately light (positive, bounded admittance residues; the loop cap holds), so stability and wolf behaviour are those of a lightly loaded bridge. All seven `bow_body_tail_*` keys are Parameters-tab rows (rebuild tier); the **Body tab (⌘0)** draws the response as built ([UI Layout](ui-layout.md)).

### Stereo

ONE width law: `bow_st_width` (0.2) — the whole instrument (voice, taraf wash, drones, bow noise) heard from two observation points via a diffuse-field difference bank per bus. Lows stay identical in L/R, the upper spectrum decorrelates like a real instrument's, zero net lean, mono fold-down bit-identical, plus the width-decorrelated room (`Reverb.processMonoStereo`). It is the WHOLE stereo law — every source stays centred; the legacy per-source pans are gone. Details: [Sarangi](sarangi.md).

## Editing the sound

- **Parameters tab (⌘5).** `ParametersView` over `ParamRegistry` — filterable groups covering **every** parameter, physics and live alike, in native units, each row with a mapping button. `rebuild` rows re-apply through a crossfaded off-main `BowEngine` rebuild ~0.2 s after the value settles (below) and persist as an override dict (`tarabdaar.stringOverrides.v1`); `live` and `hybrid` rows apply instantly and persist in `tarabdaar.controlDefaults.v1`. "Default (Sarangi Live)" / "Reset all" clears both; double-clicking a row label resets one.
- **DEFAULT = ENGINE TRUTH.** An untouched `.rebuild` row displays `ParamSpec.def`, but the engine runs artifact + overrides only — so for a key the artifact does not carry, the authored def MUST equal the engine's code fallback or the tab lies about the sound. `ParamUnificationTests.testAuthoredDefaultsMatchEngineFallbacks` pins the articulation/liveness set; when adding an artifact-absent rebuild key, keep def, code fallback and that test in step.
- **Strings tab (⌘2).** The editable `[StringSpec]` tarab table (below) tunes the in-kernel taraf.
- **Controls tab (⌘4).** Named 0–1 composite macros built from any parameters, plus direct tilt→parameter bindings — driven live from the sensors, without a rebuild wherever the parameter allows it.
- **FX tab (⌘6).** The four-insert rack, all `.live` `fx_<point>_*` params, off by default = byte-null ([FX](fx.md)).

## Sympathetic strings — the editable bank

**Two sets on two bridges** — the raga set (scale-degree strings, the `bow_jt_*` bridge) and the chromatic set (15 semitone strings on the fixed JI grid, the "Chromatic bridge" group: its own level, level norm and live evolution — `bow_jtc_gain`/`_norm`/`_evolve` — over the raga bridge's jawari geometry; resting values equal the raga bridge's, so the split alone adds strings). Full detail: [Sarangi](sarangi.md#sympathetic-strings-the-strings-tab-2). The rest of this section is the raga set.

Each row is a `(degree, octave, gain, t60, enabled, set)` string. **Pitches come straight from the centralized scale**: `degree` indexes the Fret Pad scale's ratios, `octave` shifts by whole octaves, and absolute Hz is minted only at resolve time (millihertz grid) against the one tonic — a scale or tonic move retunes the whole bank, always. Owned Mac-side by `SarangiStore` in `InstrumentState`, edited in the Strings tab as one flat table (pitch + octave dropdowns; no ratio or Hz inputs — the app's one Hz input is the tonic on the Fret Pad tab). A row the jawari selection does not pick up is inert.

**Following the scale is unconditional.** The row LAYOUT (degrees + Sa/Pa emphasis + octave repeats; always pitch-sorted, one string per pitch — `InstrumentState.normalizeStrings`) regenerates when the scale's degree count changes or via "Regenerate from scale"; hand edits to gains/decays/rows otherwise stand. The taraf sits exactly on the scale's JI grid — there are no per-string detunes (not present — see docs/history/).

### The controller strum set

The Strings tab also holds the drone-button mapping and the **strum set** (`InstrumentState.strumStringIds`): the strings the Joy-Con L button sounds all at once as a **held chord in the MAIN voice** — default low Sa · low Pa (`autoStrumMapping`), remappable to raga chords (scale-degree references, so a chord re-voices with the scale). The chord goes through the shared `pitchPad` touch path (`AppController.strum(pressed:)` → `PitchPadEngine.noteOn(ratio:velocity01:)`, firm 0.9 strike velocity), so it sounds on whichever main instrument is selected, allocates fresh strings under the normal laws and charges the taraf like played notes; it sustains while L is held. The set follows the pool invariant (twin folds re-point members, deletions prune, regenerate restores the default — `DroneStringTests`).

- **Its own expression** (`ctl_strum_expr`, Controller group, bound to the Joy-Con stick Y by default): a per-slot expr multiplier in `BowControlMapper`, pushed LIVE to the held notes. The wire's touch record is untouched and every non-strum path multiplies by exactly 1.0; plucked mains consume it at the onset as a pluck-level scale.
- **A hard shake can strike it** (`ctl_strum_thresh`, 0…1, default 1 = off): the iPad's strike envelope crossing the threshold triggers as an L press and releases when it falls back below, with a 100 ms retrigger cooldown (the L button ignores the cooldown).
- **The chord bar overrides the set.** With a chord selected in the strip below the Fret Pad's band ([Fret Pad](fret-pad.md)), the strum plays THAT chord — octave-agnostic, sounded under the **Shepard register law** (`shepardChordNotes`: pitch-class chord tones as raised-cosine-weighted octave copies centered in the octave below the tonic, so a VII chord sits no higher than a I chord); deselecting falls back to the configured set. A selection change while the chord is RINGING retunes it in place — surviving members glide, surplus notes release, extra members strike fresh (`AppController.retuneStrumChord`).

## The factory preset

One factory preset ships — **"Default (Sarangi Live) — Pilu"** (`SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`), also the fresh-install default: untouched artifact physics + the generated seed bank, replaced by the Fret Pad scale on the first push. The whole `InstrumentState` persists to UserDefaults (`tarabdaar.sarangiState.v8`).

## Saving and loading presets

Five UserDefaults keys hold the editable state: the sarangi `InstrumentState` (`tarabdaar.sarangiState.v8`), String physics overrides (`tarabdaar.stringOverrides.v1`), resting parameter values (`tarabdaar.controlDefaults.v1`), composites (`tarabdaar.compositeParams.v1`) and tilt bindings (`tarabdaar_dimensionMapping_v6`).

They save and load as **one `TarabdaarPreset` document** — one preset is one rig (`Packages/TarabdaarCore/.../PresetDocument.swift`; data, not UI, hence the package) via `AppController.capturePreset(name:)` / `applyPreset(_:)`, driven from the Parameters-tab toolbar (`PresetToolbar`). A preset carries every section: the sarangi document, the physics overrides, `paramValues`, the composites and `tiltMapping`. Every section is optional, so a partial file applies exactly the sections it carries.

**No file panels.** Saved presets live in the app-managed **library** (`PresetLibrary`, `Application Support/Tarabdaar/Presets/`, one `.tarabdaar` file per preset named after it): **Save preset…** asks only for a NAME (same name = overwrite, the popover says so), and every saved preset appears in the **Load preset** menu automatically, under the factory default (`AppController.loadFactoryPreset`, which resets the whole rig — bank, physics, parameter values, composites AND tilt bindings). A **Delete preset** submenu removes entries. The menu refreshes on every save/delete and on toolbar appear, so a `.tarabdaar` file dropped into the folder by hand shows up too — that folder IS the import/export surface. Guards: `PresetLibraryTests`, `PresetCodingTests`.

**Traps:**

- A tilt binding survives a round-trip **only through its `MapTarget.storageKey`**. Unknown `param:` keys are silently dropped on load (`DimensionMapping.pruned`) — rename a parameter key and every binding to it disappears from the preset without an error.
- `StringParamStore.replaceOverrides` **clears `dirtyKeys`** to force the full rebuild path rather than the in-place push. That is required: a preset can move keys that resize tables, which the in-place path refuses.

## Drones

Three press-to-sound drone buttons inside the Fret Pad's right edge each pluck **one mapped sympathetic string** (Strings tab "Drone buttons" section, `InstrumentState.droneStringIds`; auto-mapped to the loudest strings near low Sa · low Pa · Sa) — on the Tanpura drone voice by default, on the legacy jt swell via the tab's Voice picker. There are no dedicated drone rows: a mapped string sounds exactly as its row is tuned, and an unmapped/disabled/unselected row leaves the button silent. Full treatment and calibrated levels: [Fret Pad](fret-pad.md).

## Levels

Calibration is inside the fitted preset: `bow_live_trim` / `bow_rev_*` set the output level, and **`bow_gain`** (def 1 = bit-exact) multiplies the trim as the PERFORMANCE master volume of the whole radiated instrument — the knob that moves total loudness where expression can't, because the taraf keeps ringing. The Mac pads hold the expression axis at its fitted median (0.25) — a real ±16 dB loudness axis, not a trim.

**The safety limiter.** Loud peaks are backstopped inside the kernel, and a **linked-stereo output safety limiter** rides the very end of both post-chains (after the global FX insert): instant-attack peak detector, `bow_lim_rel_ms` release, hard clamp at min(1, 1.25 × ceiling) for the attack samples. **Below `bow_lim_thresh` (default 0.8) it is bit-exact passthrough** — the parity phrase peaks ~0.06, so every golden is untouched (`LimiterTests`).

**Kin notes and `bow_jt_norm`.** The notes that get near the ceiling are the KIN notes — a hard-struck unison Sa/Pa adds the played voice and the jt ring coherently (~+4 dB peak over a non-kin degree, more under high expression). The musical fix is **`bow_jt_norm`** (t60-response normalization — the long-ring Sa/Pa anchor rows charge hotter than the shortened crowd; **0.6 measures near-even across degrees**, 1.0 overshoots and the crowd wins); the limiter is the safety net behind it. For the ACCUMULATION side — the anchors remembering a whole phrase and blooming on the next kin note — the voice-relative cap below is the lever.

**Voice↔taraf balance.** One `.live` lever at the SPLIT-BUS merge — the same point as the FX voice/taraf inserts and the iPad volume-readout meter tap (the `bow_poly_process3` split path's `bus + bus` sum is bit-exact against the fused path; `BusMeterTests`):

- **`bow_bal`** (−1…+1, def 0): the voice↔taraf mix as a pure ATTENUATOR pair — −1 = voice only, +1 = taraf only, 0 = the calibrated mix bit-exactly. The favoured side never boosts past its calibrated level, so no new headroom appears and the limiter calibration holds. Slewed ~30 ms with per-sample interpolation; instant like `bow_gain`, so it binds well to a tilt. The iPad volume readout taps post-balance.

**The voice-relative taraf cap** (`bow_jt_cap` / `bow_jt_cap_ratio`) is the runaway-bloom lever: with high `bow_jt_evolve` the web can feed itself and bloom LOUDER than the played voice, and a fixed threshold can't follow a phrase's dynamics. The cap side-chains its ceiling from the VOICE bus itself — an instant-attack peak envelope with a slow ~1.2 s-τ release (≈7 dB/s), so a string may ring on after a note and decay more slowly than the voice but never PEAK above what the voice reached.

- Ceiling = voice peak × `bow_jt_cap_ratio` (1 = parity, 0.5 ≈ −6 dB under, 2 = a loose leash). `bow_jt_cap` 0…1 is the hardness — the applied reduction is that fraction of the full dB overshoot: 0 = off (byte-null, the default), 1 = a hard relative limiter. A dimensionless ratio, so it rides `bow_gain` and expression untouched.
- **Applied INSIDE the kernel, string by string** (`bow_poly_jt_set_cap`): the render loop records the voice peak envelope beside the jt drive (sync buffer and async ring alike — state only, byte-null unarmed); the tick scheduler converts it to a per-tick ROW ceiling (voice env × ratio ÷ the jt output gain), and each row runs its own 150 ms peak envelope and gain (3 ms toward reduction / 120 ms recovery) on its radiated output — a pure output gain after the physics, so the string's ring and the quiescence gate both see the un-capped string. Per-row state is worker-owned; an arm edge bumps a generation counter and each row resets itself on its next tick (no control-thread array writes under running workers). The strings sum AFTER the cap, so the whole web can still stand above one string's ceiling.
- Pre-FX and pre-trim; the balance stays a manual mix move after it. One deliberate consequence: armed hard while the voice is silent from launch, the ceiling is ~zero — drones and the tanpura's `tp_taraf` charge are held down until the voice first sounds.

`TarafCapTests` pins byte-null at hard 0, taraf-only reduction, monotonicity in both knobs and the worker-pool path.

## Re-fitting

To change the DSP, edit `Packages/SarangiKit/` directly — it is Tarabdaar's own code, and `TarafRemovalParityTests` flags any change to the shipping signal path. Tarabdaar does not re-fit the physics in-tree; the fitted values ship in `bowed_string.json`. See CLAUDE.md's "Sound Design Iteration" and [Sarangi](sarangi.md).

## What a rebuild costs

Parameters that are engine-build values (`rebuild`, and `hybrid` pushed above its built value) cannot be poked into a running kernel — they require constructing a fresh `BowEngine`. `RebuildCostTests` keeps the numbers honest:

| | |
|---|---|
| Full rebuild | **~360 ms** (off-thread — latency, never a dropout) |
| …of which tables + kernel + worker pool | **~4.5 ms** |
| …of which the **settle pre-roll** | the rest (~98%) |

**The settle pre-roll** is the whole cost. A fresh kernel's jawari web relaxes off the builder's `q0` — the analytic static wrap is not an exact equilibrium of the discrete contact — so `buildEngine` renders and discards `StringVoiceSource.settleBlocks` (**5** blocks of ~85 ms) while it dies. **The damped settle** kills the chime at the cause: the taraf is choked (`BowEngine.setJtSettleDamp`, t60 50 ms) while the discarded blocks render — the contact still settles the wrap to its true discrete equilibrium, only the oscillation dies — and the natural ring is restored EXACTLY before publish (a pure per-tick momentum scalar, 0 = byte-null). `RebuildCostTests` holds the publish peak to an absolute **−80 dBFS bar**; five blocks clear it with margin on the bridge-force radiation (three do not). The silent publish also lets the quiescence gate close on the web within ~30 ms of launch. Lengthening the crossfade does not substitute — what remains past the fade is the web's steady idle floor, not a decaying transient; fixing it properly means a `q0` that does not leave the web charged at t = 0.

**Continuity.** A fresh engine has zero string/taraf/room state, so a hard swap under a held note is a step (96% of level within 43 ms) and a hard swap during the ring cuts it (4.9% of the tail survives). `StringVoiceSource.setEngine` therefore keeps the outgoing engine rendering and equal-power crossfades into the new one over `StringVoiceSource.engineCrossfadeMs` (300 ms): seamless under a note, 69% of a ring survives. That costs 2× voice CPU for the fade window only (at the 128-frame buffer: 11% of realtime for one engine, 19% for two).

**Why the distinction exists internally.** At ~360 ms per build plus a 300 ms fade, build-time parameters are fine under a slider but cannot be swept at tilt rate. `ParamRegistry`'s `apply` field is therefore a routing hint; the user-facing truth is `ParamSpec.timing` (live / in-place / rebuild / hybrid), rendered identically in the Parameters-tab row help and [parameters.md](parameters.md).

**Rest fractions.** A `hybrid` parameter's `ParamSpec.restFraction` keeps the shipped sound when its live scaler is at rest: jawari buzz rests at **1.0×** the built depth (the fitted sound), vibrato depth at **0×** (silent until the player asks). Get these wrong and the instrument boots sounding different from the artifact.

## In-place parameters

Most parameters do not rebuild at all. `BowEngine.setLiveParams` pushes an edit onto the **running** kernel: the per-sample scalars are overwritten (`bow_poly_set_scalars`) and the Swift-side mapping constants re-read. Nothing is reset — string histories, taraf ring, jawari web, room tail and note articulation carry straight through.

`ParamLivenessTests` classifies every parameter empirically (perturb it, rebuild the tables, diff what moved) into three in-place tiers — kernel scalars; keys that move no table (mapping constants, output/room/radiation); coefficient arrays (the body modal bank via `bow_set_body`, the jawari tables via `bow_jt_set_coeffs`) — plus the genuine rebuilds: `bow_body_modes` (resizes the bank) and the keys `BowEngine` reads once at construction (`bow_rev_rt60`, the `bow_st_*` spreads). Coefficient reloads keep histories: the body resonators keep their state (retuning the body under a note is click-free, the biquad-swap trick), and the jawari web keeps its settled wrap, relaxing into the new bone geometry the way a real jawari adjustment does.

**Trap:** `bow_jt_load` is the *init-only* entry point and it **mallocs** — calling it a second time leaks and re-allocates the web. Reloading jawari coefficients onto a live kernel is `bow_[poly_]jt_set_coeffs`, which overwrites in place and refuses on a shape change.

`ParamRegistry.inPlaceKeys` is the shipped set; `StringParamStore` tries the fast path and falls back to a rebuild when a touched key needs fresh tables. A pushed value settles within **0.03 dB** of an engine built with it baked in; a held note keeps 100% of its level and a decaying ring 76%.

### Zipper

The push writes coefficients directly, so `ZipperTests` measures it rather than assuming it safe. Friction coefficients cannot click by construction — they change how the string *evolves*, not the current sample (`bow_mu_s` swept over 2 s at 60 Hz: −2 dB excess HF vs a smooth sweep). The parameters that CAN click are the ones that multiply the signal, and only on a large instantaneous jump: a +17 dB `bow_live_trim` step mid-note is a **17.9×** seam (an audible click) with no ramp, 3.4× with a 25 ms chunk-rate ramp, and **0.0×** with per-sample `outGain` interpolation on top. Both are needed — the chunk ramp alone leaves a ~20% step at the first boundary — so `postChain` interpolates the output gain **across** the chunk, and the ramp caps the render chunk to 256 frames while it runs (otherwise an offline render resolves a whole 4096-frame glide in one step, which is exactly the click being prevented).

### The chunk cap is not neutral

Chunk size sets the control-interpolation grid and the jawari web's block boundaries, so splitting a 4096-frame offline render moves a chaotic friction loop onto a different (valid, but different) trajectory — a push that changed *nothing* deviates 41% of peak for this reason alone. The ramp is therefore armed only when a ramped quantity actually moved: a no-op push is bit-identical (`testNoOpPushIsBitIdentical`), and a coefficient-only reload does not arm it at all. For a real edit the chunk still splits, which is why a pushed value settles within ~0.4 dB of a rebuilt engine rather than exactly on it.

## Real-time validation

`RealtimePerformanceTests` (headless, buffer-accurate; a gated slow suite — see CLAUDE.md) renders the voice at the device's 128-frame buffer with notes through `BowControlMapper` and tilts evaluated through `DimensionBinding` into the same apply paths `AppController` uses: a composite swept by tilt, direct params, 5 Hz full-range flicks, polyphony with everything moving, and a crossfaded rebuild-tier sweep. It asserts zero over-budget buffers, zero dropouts and bounded worst steps against the 2.67 ms budget.

**Judge realtime behaviour on p99 with preallocated buffers** — a `[Float]` allocation per buffer or wall-clock timing in a normal-priority process reports phantom overruns. In the app, the overrun watchdog logs render overruns and jawari-web overloads to Console; a run with the parameter motion removed is the control that proves a clean measurement is not measuring an inert path. Not covered: a real iPad over the wire adds link jitter the in-process pump does not have.
