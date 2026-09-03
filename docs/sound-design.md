# Sound Design

Sound design lives entirely on the Mac (TarabdaarMac). The iPad is a MIDI controller and produces no audio. The Mac receives MPE over USB and renders the **sarangi String voice** — the only voice. It is `SarangiKit.BowEngine` driving the `CBowKernel` C friction kernel: a pure-physics bowed gut string that carries the **whole instrument** in-kernel — the played strings, the sympathetic (tarab) web with modal-jawari buzz, the formula body, radiation, and room. There is no hosted plugin, no base-voice selection, and no coupled bridge–body network in the signal path (the SWAM/sitar chain that used those was removed on 2026-07-24).

## Signal path

```
MPE in ► routeSarangiModelMIDI ► StringVoiceSource (BowEngine + CBowKernel, 96 kHz → 48 kHz) ► symGain ► mainMixerNode ► out
```

The `StringVoiceSource` (`Packages/TarabdaarCore/.../StringVoiceSource.swift`) wraps the `BowEngine` as a 48 kHz `AVAudioSourceNode` connected **directly** to `symGain → mainMixerNode`. The kernel runs at 96 kHz internally and half-band-decimates to 48 kHz; the mixer input converts to the engine rate (44.1 kHz). There is no master filter/reverb bus — the kernel owns its own body and room. See [sarangi.md](sarangi.md) for the full physics treatment.

## The played voice — the String kernel

The kernel is `bow_kernel_poly.c` (always `-O3`) — Tarabdaar's own code since the `~/Desktop/sarangi` link was cut 2026-07-24. It was once the byte-exact twin of that project's offline reference, which is why its comments still cite a `bow_kernel.c` "mono kernel": that second, mono-only source existed purely for upstream byte-parity, Tarabdaar never ran it, and it was deleted with the rest of the parity machinery. Bit-exactness is now pinned locally by `TarafRemovalParityTests`. Fed by **`bowed_string.json`** (`Presets.bowedStringParams()`), it produces:

- **Played strings.** `bow_live_poly` gut strings on ONE shared delay-free bridge (poly-as-physics). **Every note-on mounts a fresh string (2026-08-24)** — the mono-meend re-bow, the legato steal and the note-off glide-back were removed from the mapper; pitch glides exist only within a note (the finger dragging its own string), and a new note always snaps onto a freshly mounted string with a fresh attack. **The 9 Hz meend smoother went the same day (2026-08-24):** the filter now ramps log2 f0 linearly to the latest wire target across each render block — continuous, on target within one block — so all meend is literally the finger's own trajectory at wire rate (~120 Hz updates, each landing as a ≤ one-block ramp) and the instrument adds no glide shaping. A steady pitch renders bit-identically to the smoother era (the parity hash did not move); the slide-texture/glide-dip slew trackers now read the finger's true rate instead of the smoother's exponential tail (their tests drive stepped `touchGlide` meends). **Register damping (`bow_loss_reg`, 2026-08-24; SHIPPED at 0.7 in the artifact — baked the same day, blessed by ear against the A/B renders; 0 = the pre-2026-08-24 fixed corners):** the fitted nut/bridge/gut loss corners (`bow_nut_fc`/`bow_br_fc`/`bow_gut_fc2`) are ABSOLUTE frequencies, so one string gliding the whole range keeps its Helmholtz corner as sharp per second at the bottom as in the fitted register — measured on the shipping rig: a note an octave below the tonic carries ~30 dB more relative 3–6 kHz energy than the tonic note (whose spectrum cliffs past ~2.3 kHz), with a hollowed fundamental — the "brassy/synthy low glide" report. Armed, the three corners scale as fc·(f0/tonic)^γ for notes BELOW the tonic only (kernel-side, per sample, composing after the `bow_nail_k` law and the twang morph; continuous at the tonic, at/above untouched, `RegisterDampingTests`). Lowering the corners was validated in-app before the law was built: gut corner 3172 → 1200 Hz on the low note dropped its 3–6 kHz share −27.8 → −35.0 dB AND recovered the fundamental (h1 −13 → −2 dB re max) — darker and *fuller*, not muffled. γ 0.7 (shipped) is a moderate warmth, 1.0 full period-proportional tracking; a kernel scalar, so it pushes in place and can ride a tilt. The baked 0.7 is INERT on the `TarafRemovalParityTests` phrase — its notes (E4/B4 over the 328.9 tonic) sound at/above `f0Open` where the law is a no-op (the 2026-08-24 re-bless was for the body formant forest, not this); a future phrase edit that adds a below-tonic note WILL move the hash, and that is the law working, not a regression. **Slide dulling (`bow_slide_dull` 0.35 / `bow_slide_rate` 900, 2026-08-24, kernel scalars, Liveness group):** a real meend is a finger MOVING on the string — the lighter moving contact absorbs more top than a firmly stopped finger. The kernel tracks each string's own pitch slew (SIGNED 10 ms pre-smoothing before rectifying — the OU drift's white micro-jitter would otherwise read as ~500 ¢/s of false slew; residual ~15 ¢/s sits under the 80 ¢/s floor, so STEADY notes render byte-identically with the key armed, `SlideTextureTests.testSteadyNoteIsByteExactWithKeysArmed` — which is what lets the fitted value ship without touching the parity phrase), maps r/(r+rate), smooths 15 ms attack / 120 ms release; while the envelope is up the loop corners scale down by dull×env (composed into the register-damping pow), so the tone dulls through the slide and blooms back on arrival. Strong finger vibrato drives the tracker too (~864 ¢/s peak slew at full depth) — physical. **Slide noise (`bow_slide_noise` 0.008 / `bow_slide_acc` 25000 ¢/s², ACCELERATION-driven — v2, 2026-08-24 evening):** finger-slide friction noise injected at the NUT write — the finger IS the nut-side termination of a stopped string, so the noise circulates the loop, combs at the sliding pitch and radiates through the body (per-slot xorshift stream → ~4.4 kHz one-pole; ×40 makeup: ~26 dB bow-contact+termination path loss, and the accel drive fires in brief ~30–50 ms bursts rather than a sustained envelope). **The drive is the slew's DERIVATIVE**, not the slew: a second signed 10 ms smoother on ΔslD, in ¢/s², 6000 ¢/s² floor (drift's smoothed accel jitter measures σ≈1500 ¢/s², so steady notes stay bit-exact with the key armed), 10 ms attack / 100 ms release, `bow_slide_acc` half-saturation (a smooth 700 ¢ meend over 0.35 s peaks near ~28k ¢/s²). The noise scrapes where the finger STARTS, STOPS or turns and stays quiet through a constant-rate meend — pinned by `SlideTextureTests.testSlideNoiseTracksFingerAcceleration` (bursts at the stepped test meend's endpoints, middle within noise of the silent-slide render). **History:** the v1 shipped that morning driven by the slew itself, calibrated +4.8 dB of 2.5–7 kHz through the whole glide — the user cut it by ear the same afternoon ("the noise covered the glide's fakeness but sounded unrelated to my movements") and it was reinstated acceleration-driven that evening. The v1's sustained-injection regime-shift ceiling (≥0.015 re-captured the landing note brighter) does not directly apply to burst injection, but the level range keeps the same top. (The same investigation cleared the two suspects the glide report pointed at: the glide dip's 0.3× force coupling raises relative pressure only ~3.5 dB and measured spectrally marginal — ~+3 dB of 3–6 kHz on the landing note, none during the glide — and force-wedge scaling ×0.5–×2 left the low register's brightness pattern unchanged, so the brightness is the loop losses, not the bowing regime.) Analytic Schelleng press envelope, place-then-draw + attack-bite articulation (2026-08-19: sharpness = max(press law, `bow_attack_vel` × onset strike velocity) — per-note martelé/legato from the iPad's accelerometer estimate or MIDI velocity; fresh attacks only, so glides are untouched — see [sarangi.md](sarangi.md)), aftertouch vibrato, self-calibrated intonation tables. **The sitar-twang axis** (`bow_twang`, 2026-08-01, `.live`, default 0 = byte-exact; fitted to `sitar1.wav`): a grazing jawari wrap on the played strings' own bridge — an energy-conserving rolling length modulation at the excursion tips plus a termination morph toward sitar hardware — that gives a staccato note the sitar's sustained buzzy high-harmonic cluster through its ring, at any strike level. Mechanism, fit measurements and traps: [sarangi.md](sarangi.md).
- **The sustain-liveness layer** (2026-08-01, `BowControlFilter`, "Liveness" registry group — fitted to clean SWAM Violin 3 captures rendered with its room off, vibrato 0, constant CC11). Three mechanisms, each dB-shaped on the bow controls, all **0 = bit-null** with the shipped values in the artifact: **(1) post-onset settle** — the friction loop alone overshoots ~+7 dB for ~0.5 s after capture (SWAM: +1.8 dB peaking ~200 ms, level by ~500 ms); `bow_settle_db` 7 / `bow_settle_ms` 130 subtracts a smoothstep-in, exp-out envelope from vbow that is zero through the place+draw window, so the staccato bite is untouched (measured: sustain overshoot +6.7 → +2.2 dB; staccato peak trimmed ~4 dB, which lands the staccato-vs-sustain balance on SWAM's). Since 2026-08-24 every note-on is a fresh mount, so every note settles (the legato-steal keep-stroke case went with the legato allocation laws). **2026-08-19: `bow_settle_sharp`** (default 0 = bit-null) exempts a SHARP attack from the settle — depth × (1 − key × sharpness) — so an accented staccato holds its level while gentle sustains keep the fitted balance (`LivenessTests.testSettleSharpExemption`). **(2) OU drift** — three independent unit-variance Ornstein–Uhlenbeck walks (deterministic per-slot xorshift64, `seedDrift`; panic → `reset()` rewinds, so renders reproduce) at `bow_drift_hz` 1.2 scaling into pitch cents (0.55), vbow dB (0.15) and force dB (0.3). This is the "not-quite-vibrato" life of a held note: SWAM wanders ±2 c / ±0.5 dB at 0.5–2.5 Hz and its harmonics shimmer ±1–5 dB decorrelated — ours does the same through the body slope. **TRAP measured, not assumed: the fitted sarangi body is ~3 dB/¢ steep around D4** (SWAM's violin body is far flatter), so 2 c of drift — SWAM's own depth — produced ±1.7 dB of level wobble (slow tremolo); the shipped 0.55 c targets SWAM's *level* outcome (0.72 dB std vs its 0.5) and the harmonic shimmer comes free. Do NOT inject per-harmonic motion directly. **(3) glide dip** — the causal form of the offline glide bow-lightening: the bow eases toward `bow_glide_dip_db` 5 · r/(r+`bow_glide_dip_rate` 900 ¢/s) while the SOUNDING pitch slews (15 ms attack / 120 ms release; full depth on vbow, 0.3× on force — 0.5× measurably slowed the string's re-capture, ~150 vs ~90 ms). Fast finger glides dip 2–7 dB like SWAM's 3.5–9 dB legato transitions (since 2026-08-24 only within-note movement glides — a new note snaps on a fresh string, so the dip serves meend, not note changes); drift-rate motion (~20 ¢/s) never triggers it. Guards: `LivenessTests` (SarangiKit) pins the settle shape, drift bounds/determinism, dip selectivity and the absent-keys bit-null; `BowControlsTests` strips the liveness keys (law tests); `TarafRemovalParityTests` re-blessed. Reference captures: `auditions/swam_refs/`.
- **The modal-jawari taraf, fused in-kernel** (`bow_jt_*`, always on — the `bow_jtaraf_on` arming switch was removed 2026-08-02) — modal steel strings over grazing jawari bones on the steel-lattice subset of the tarab rows, driven one block late on its own worker pool (the callback never waits). **This is the instrument's entire RADIATED sympathetic response** since 2026-07-24: a second, LINEAR comb web (`bow_taraf_*`, plus the open gut pair `bow_open_*`) used to hang off the same bridge, approximating a buzzing sympathetic with a comb and a flat-bridge buzz term. Silenced it sounded better, so it was deleted. (2026-08-01: the web *machinery* returned as the `bow_cpl_*` SILENT bridge-coupling layer — one buzz-free, tap-free comb per tarab row so the played strings feel the taraf as a two-way load; the buzz and the radiated comb ring stay deleted. Default off = byte-null. See [sarangi.md](sarangi.md).) Tuned from the **Strings tab** rows. The tanpura/sitar **twang** — the harmonic cascade that sweeps the ring's spectrum upward and back down — lives in a narrow amplitude band around the graze knee, and `bow_jt_evolve` (2026-07-26, default 0.5 = bit-exact, `.live` — a kernel-slewed bone lift, the one sanctioned runtime bone move, tilt-sweepable without a strum) makes it fast-and-reliable (1) or absent (0); `bow_jt_ev_reg` (2026-08-27, `.live`, default 0 = byte-null) tilts that axis by register — evolve units per octave from the tonic, per-row bone offsets — so the low Sa/Pa anchors' sustained cascade bloom (the "sarod drone" that emerges at high evolve, because those long-t60 kin-charged rows are the ones that sit in the grazing band) is dialable on its own, without the whole web buzzing; `bow_jt_hp` voices the radiated ring as the jawari formant (high-harmonic cluster over quiet lows; the `bow_jt_tap` radiation pickup it used to pair with was deleted 2026-09-03 — the rows radiate their bridge contact force, see [Sarangi](sarangi.md)); `bow_jt_body` (2026-08-01, `.live`, default 0 = byte-exact) blends the radiated taraf through the voice's own body radiation bank — the coherence lever: the taraf rings from the instrument's body instead of beside it. Mechanism and measurements in [sarangi.md](sarangi.md).
- **The formula body** — modal resonators derived from physical scalars (no FIR/fingerprint/coupled artifacts). **The formant forest (2026-08-24, baked):** the diffuse tail (`bow_body_tail_*` — the Schroeder-region mode bank the builder always had) shipped near-silent (3 modes, radiation 0.017), leaving the 250–6500 Hz radiated transfer measured ±0.3 dB FLAT — so a glide's spectral envelope moved WITH the pitch, the single strongest "pitch-shifted oscillator" tell, and the OU drift's harmonic shimmer had no body slope to work against above the 9 signature modes (55–250 Hz). Baked now: 32 modes, 280–6500 Hz, Q 30, mobility 0.4, radiation 2.5 — radiated ripple std ±3.8 dB (extremes ~26 dB, real-body territory), so every harmonic sweeps through FIXED peaks and valleys during meend. The admittance max is UNCHANGED (1.89 — the tail's bridge-load side is deliberately light), so the loop cap, stability and wolf behavior are untouched; calibrated by direct transfer-function analysis of the builder's formula, not by ear-fitting renders. All six `bow_body_tail_*` keys are Parameters-tab rows now (rebuild tier); `tail_rad` back at 0.017 ≈ the pre-2026-08-24 flat body.
- **Stereo** — ONE width law since the 2026-08-01 unification: `bow_st_width` (seed 0.2), the whole instrument — played voice, taraf wash, drones, bow noise — heard from two observation points via a diffuse-field difference bank run per bus in the poly kernel; lows stay identical in L/R, the upper spectrum decorrelates like a real instrument's between two ears, zero net lean. The old per-source pans (`bow_st_spread` pitch-class staging, `bow_st_played` noise positions) are disarmed legacy, kept for A/B pending removal. `L/R = mid ± side`, mono fold-down bit-identical, plus the width-decorrelated room (`Reverb.processMonoStereo`). Details: [sarangi.md](sarangi.md).

## Editing the sound

- **The parameter list (Parameters tab, ⌘5).** `ParametersView` over `ParamRegistry` — filterable groups (Bow stroke / Body / Bow & string / Playing ranges / Jawari taraf / Taraf coupling / Articulation / Liveness / Radiation & output / the four FX points) covering **every** parameter, physics and live alike, in native units with a filter box and a per-row mapping button. No row is tagged by apply strategy: `rebuild` rows re-apply through a **crossfaded** off-main `BowEngine` rebuild ~0.2 s after the value settles (see below) and persist as an override dict (`tarabdaar.stringOverrides.v1`); `live` and `hybrid` rows apply instantly and persist in `tarabdaar.controlDefaults.v1`. "Default (Sarangi Live)" / "Reset all" clears both, double-clicking a row label resets one. Audition path: `string.<key>` or `param.<key>`. **DEFAULT = ENGINE TRUTH (2026-08-19):** an untouched `.rebuild` row displays `ParamSpec.def`, but the engine runs artifact + overrides only — so for a key the artifact does not carry, the authored def MUST equal the engine's code fallback or the tab lies about the sound (it did once: attack bite showed 2.0 while the engine ran 0, sharp draw showed the offline fit's 8 ms while the engine followed the 60 ms draw). `ParamUnificationTests.testAuthoredDefaultsMatchEngineFallbacks` pins the articulation/liveness set; when adding an artifact-absent rebuild key, keep def, code fallback and that test in step.
- **Sympathetic strings (Strings tab, ⌘2).** The editable `[StringSpec]` tarab table (see below) tunes the kernel's in-kernel taraf.
- **Tilt / composite parameters (Controls tab, ⌘4).** Named 0–1 composite macros built from any parameters, plus direct tilt→parameter bindings — driven live from tilts or audition scores, without a rebuild wherever the parameter allows it.

## Sympathetic strings — the editable bank

**Two sets on two bridges since 2026-09-02** — the raga set (scale-degree strings, the `bow_jt_*` bridge) and the chromatic set (15 semitone strings on the fixed JI grid, the `bow_jtc_*` "Chromatic bridge" group: its own jawari geometry, contact law and live evolution; resting values equal the raga bridge's, so the split alone adds strings). Full detail in [sarangi.md](sarangi.md#sympathetic-strings-the-strings-tab-2). The rest of this section describes the raga set.

The sympathetic taraf bank is a **fully editable `[StringSpec]` table** — each row a `(degree, octave, gain, t60, enabled, set)` string. **Pitches come straight from the centralized scale** (2026-07-25): `degree` indexes the Pitch Pad scale's ratios, `octave` shifts by whole octaves, and absolute Hz is minted only at resolve time (millihertz grid) against the one tonic — so a scale or tonic move retunes the whole bank, always. Owned Mac-side by `SarangiStore` in `InstrumentState` and edited in the **Strings tab (⌘2)** as one flat table (pitch + octave dropdowns; no ratio or Hz inputs — the app's one Hz input is the tonic on the Fret Pad tab). The tab also holds the drone-button mapping and, since 2026-08-27, the **controller strum set** (`InstrumentState.strumStringIds`): the strings the Joy-Con L button sounds all at once as a **held chord in the MAIN voice** (2026-08-28) — default low Sa · low Pa (`autoStrumMapping`), remappable to raga chords (members are scale-degree references, so a chord re-voices with the scale). The chord goes through the shared `pitchPad` touch path (`AppController.strum(pressed:)` → `PitchPadEngine.noteOn(ratio:velocity01:)` at `strumStringRatios`, firm 0.9 strike velocity), so the notes sound on whichever main instrument is selected, allocate fresh strings under the normal laws, and charge the taraf like played notes; it sustains while L is held and note-offs on release. **The chord has its own expression** (`ctl_strum_expr`, 2026-08-28, Controller group — bound to the Joy-Con stick Y by default): a per-note scale on the chord notes' bow-expression axis, pushed LIVE to the held notes so the stick swells the ringing chord independently of the melody's global expression (the mechanism is a per-slot expr multiplier in `BowControlMapper`, carried in-process through the touch chain — the wire's 9-byte touch record is untouched and every non-strum path multiplies by exactly 1.0, so parity stands; plucked mains consume it at the onset as a pluck-level scale — a sounded pluck can't swell). **A hard shake can strike the chord** (`ctl_strum_thresh`, 2026-08-28): the iPad's strike envelope crossing the threshold triggers exactly as an L press, releasing the moment it falls back below the same threshold, with a 100 ms retrigger cooldown after each release (2026-08-29 — replaced the original ~60% release hysteresis; a jittery envelope hovering at the threshold can't machine-gun the chord, and the L button ignores the cooldown); default 127 = off. The set follows the pool invariant (twin folds re-point members, deletions prune, regenerate restores the default — `DroneStringTests` strum guards). **The CHORD BAR overrides the set (2026-08-28)**: when a chord is selected in the strip below the Fret Pad's band (see [Fret Pad](fret-pad.md) — derived per-degree triads, roman-numeral cells, either surface), the strum plays THAT chord instead — octave-agnostic since 2026-08-30, sounded under the **Shepard register law** (`shepardChordNotes`: pitch-class chord tones realized as raised-cosine-weighted octave copies centered in the octave below the tonic, weights riding the notes' per-slot expression scale, so a VII chord sits no higher than a I chord and any octave's cell sounds identically); deselecting (or a selection dangling past a scale shrink) falls back to this configured set. A selection change while the chord is RINGING takes effect immediately (2026-08-29): the held notes glide to the new chord in place — no new attack on the surviving members, surplus notes release, extra members strike fresh (`AppController.retuneStrumChord`). Two earlier versions are dead: the first same-day (08-27) build strummed through the drone voice's pluck/swell machinery, and the second swept the set as staggered staccato notes (`ctl_strum_stagger`/`ctl_strum_gate`, retired 08-28) — replaced by this, do not revive either. The rows tune the String voice's in-kernel modal-jawari taraf. They used to feed a linear comb web as well; that web was deleted 2026-07-24, so a row the jawari selection does not pick up is now inert.

**Following the scale is unconditional** — the "Follow the Pitch Pad scale" toggle was removed 2026-07-25. The row LAYOUT (the string set: degrees + Sa/Pa emphasis + octave repeats; always pitch-sorted, one string per pitch since 2026-07-26) regenerates when the scale's degree count changes or via the tab's "Regenerate from scale" button; hand edits to gains/decays/rows otherwise stand. (The fitted-table era's opt-in sync and the **string-table law** it protected were retired the same day with the scale-defined pitch model — a degree can't be a few cents off itself, so the fitted per-string detunes are gone and the taraf sits exactly on the scale's JI grid.) Full detail: [sarangi.md](sarangi.md).

## The preset

One preset ships — **"Default (Sarangi Live) — Pilu"** (`SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`), also the fresh-install default: untouched artifact physics + the generated Pilu-scale seed bank, replaced by the Pitch Pad scale on the first push. The whole `InstrumentState` persists to UserDefaults (`tarabdaar.sarangiState.v8`) and can be exported/imported as a `.sarangi` JSON file.

## Saving and loading presets (2026-07-24; unified 2026-07-30)

Five UserDefaults keys hold the editable state: the sarangi `InstrumentState`
(`tarabdaar.sarangiState.v8`), String physics overrides
(`tarabdaar.stringOverrides.v1`), resting parameter values
(`tarabdaar.controlDefaults.v1`), composites (`tarabdaar.compositeParams.v1`) and
tilt bindings (`tarabdaar_dimensionMapping_v6`).

They save and load as **one `TarabdaarPreset` document** — one preset is one
rig (`Packages/TarabdaarCore/.../PresetDocument.swift` — it is data, not UI,
hence the package), via `AppController.capturePreset(name:)` /
`applyPreset(_:)`, driven from the Parameters-tab toolbar
(`PresetToolbar`). A preset carries every section: the sarangi document,
the physics overrides, `paramValues`, the composites and `tiltMapping`.

**No file panels.** Saved presets live in the app-managed **library**
(`PresetLibrary`, `Application Support/Tarabdaar/Presets/`, one `.tarabdaar`
file per preset named after it): **Save preset…** asks only for a NAME
(same name = overwrite, the popover says so), and every saved preset
appears in the **Load preset** menu automatically, under the factory
default(s) (`AppController.loadFactoryPreset`, which resets the whole
rig — bank, physics, parameter values, composites AND tilt bindings). A
**Delete preset** submenu removes entries. The menu refreshes on every
save/delete and on toolbar appear, so a `.tarabdaar` file dropped into the
folder by hand shows up too — that folder IS the import/export surface.
Guard: `PresetLibraryTests`.

History: from 2026-07-24 to 2026-07-30 the document saved as two
scope-filtered halves — an instrument `.tarabdaar` (Parameters tab) and a
controls `.tarabdaarmap` (Controls tab), each through its own save/open
panel. The split was folded back together and the panels replaced by the
library; `PresetScope` is gone. Every section is still optional, so a
split-era file dropped into the library folder (rename a `.tarabdaarmap`
to `.tarabdaar` first) opens and applies exactly the sections it carries
(the `kind` tag decodes away ignored), and old bare-`InstrumentState`
`.sarangi`-content files load through `TarabdaarPreset.decode`'s legacy
fallback.

**Traps:**

- A tilt binding survives a round-trip **only through its
  `MapTarget.storageKey`**. Unknown `param:` keys are silently dropped on
  load (`DimensionMapping.pruned`) — rename a parameter key and every
  binding to it disappears from the preset without an error.
- `StringParamStore.replaceOverrides` **clears `dirtyKeys`** to force the
  full rebuild path rather than the in-place push. That is required, not
  incidental: a preset can move keys that resize tables, which the in-place
  path refuses.

Guards: `Packages/TarabdaarCore/Tests/TarabdaarCoreTests/PresetCodingTests.swift`.

## Drones

Three press-to-sound drone buttons inside the Fret Pad's right edge each pluck **one mapped sympathetic string** (Strings tab "Drone buttons" section, `InstrumentState.droneStringIds`; auto-mapped to the loudest strings near low Sa · low Pa · Sa). There are no dedicated drone rows — the jawari web is the tarab alone, a mapped string sounds exactly as its row is tuned, and an unmapped/disabled/unselected row leaves the button silent. See [Fret Pad](fret-pad.md) for the full drone treatment and the calibrated levels.

## Levels

Calibration is inside the fitted preset (`bow_live_trim` / `bow_rev_*` set the output level). The Mac pads hold a flat per-note CC11 = 32 (the fitted expr median — CC11 is a real ±16 dB loudness axis). Loud peaks are backstopped inside the kernel, and since 2026-08-01 a **linked-stereo output safety limiter** rides the very end of both post-chains (after the global FX insert): instant-attack peak detector, `bow_lim_rel_ms` release, hard clamp at min(1, 1.25 × ceiling) for the attack samples. **Below `bow_lim_thresh` (default 0.8) it is bit-exact passthrough** — the parity phrase peaks ~0.06, so every golden is untouched (`LimiterTests` pins the bound, the passthrough and the exact-unity release). The notes that get near the ceiling are the KIN notes — a hard-struck unison Sa/Pa adds the played voice, the jt ring and the coupling return coherently (measured ~+4 dB peak over a non-kin degree, more under high expression). The musical fix for that imbalance is `bow_jt_norm` (t60-response normalization — the long-ring Sa/Pa anchor rows charge hotter than the shortened crowd; **0.6 measured near-even across degrees**, 1.0 overshoots and the crowd wins); the limiter is the safety net behind it. For the ACCUMULATION side of the same imbalance — the anchors remembering a whole phrase and blooming +8…+12 dB (with buzz, at high expression) on the next kin note — see `bow_jt_gov`, the per-row charge governor (2026-08-15, [sarangi.md](sarangi.md)); norm evens the driven level per strike, the governor caps what a phrase piles up.

**Voice↔taraf balance + the taraf compressor (2026-08-24).** Two `.live` levers at the SPLIT-BUS merge — the same point the FX voice/taraf inserts and the volume-readout meter tap (armed, the render takes the `bow_poly_process3` split path, whose host-side `bus + bus` sum is bit-exact against the fused path; `BusMeterTests` pins neutral settings as byte-null and the extremes as true bus isolation):

- **`bow_bal`** (−1…+1, def 0): the voice↔taraf mix as a pure ATTENUATOR pair — −1 = voice only, +1 = taraf only, 0 = the calibrated mix bit-exactly. The favored side never boosts past its calibrated level, so no new headroom appears and the limiter calibration holds. Slewed ~30 ms with per-sample interpolation (offline 4096-frame chunks don't step); instant like `bow_gain`, so it binds well to a tilt. The iPad volume readout taps post-balance and tracks it.
- **`bow_jt_comp_*`** (thresh/ratio/atk_ms/rel_ms; thresh 0 = off, bit-exact): a feed-forward compressor on the jt bus ONLY — the played voice is untouched (pinned: the voice bus repeats bit-identically under compression). Threshold is in CALIBRATED OUTPUT units (× the build-time trim, the scale the master limiter and the iPad meter speak — it does not move with `bow_gain`); the stock taraf rides ~0.01–0.1 (−40…−20 dBFS). Instant-attack envelope, `atk_ms` gain slew toward reduction (lets the jawari strike transient through before the ring is held), `rel_ms` recovery, linked mid/side from the mid stream so the width law's fold-down stays consistent. This is the DYNAMICS lever on the wash — where `bow_jt_norm` evens the per-strike drive and `bow_jt_gov` caps the phrase pile-up at the CAUSE, the compressor holds the radiated result; at ratio 20 it is effectively a taraf limiter.

**The per-string voice-relative taraf cap (`bow_jt_cap` / `bow_jt_cap_ratio`, 2026-08-31; PER STRING since 2026-09-01).** The runaway-bloom lever: with high `bow_jt_evolve` the web can feed itself and bloom LOUDER than the played voice, and the fixed-threshold comp can't follow a phrase's dynamics — a threshold that holds a quiet passage lets a loud one bloom, and vice versa. The cap side-chains the ceiling from the VOICE bus itself: an instant-attack peak envelope with a slow ~1.2 s-τ release (≈7 dB/s), so a string may ring on after a note and decay more slowly than the voice, but never PEAK above what the voice reached. Ceiling = voice peak × `bow_jt_cap_ratio` (1 = parity, 0.5 ≈ −6 dB under, 2 = a loose leash); `bow_jt_cap` 0…1 is the hardness — the applied reduction is that fraction of the full dB overshoot, so 0 = off (bit-exact byte-null, the default), 1 = a hard relative limiter, between = a soft proportional lean. The law is a dimensionless ratio, so it rides `bow_gain` and expression untouched. **It is applied INSIDE the kernel, string by string** (`bow_poly_jt_set_cap`; the 2026-08-31 version limited the summed taraf bus in `BowEngine`, so one blooming anchor row ducked the whole web — the user asked for the limit per string the next day): the render loop tracks the voice peak envelope on the voice bus and records it beside the jt drive (same slot/buffer layout, sync buffer and async ring alike — state only, byte-null unarmed); the tick scheduler converts it to a per-tick ROW ceiling (voice env × ratio ÷ the jt output gain, so a row's raw radiated sample compares with the voice in bus units), and each row runs its own 150 ms peak envelope and gain (3 ms toward reduction / 120 ms recovery) on its radiated output — a pure output gain after the physics, so the string's ring, the charge governor and the quiescence gate all see the un-capped string. Per-row state is worker-owned; an arm edge bumps a generation counter and each row resets itself on its next tick (no control-thread array writes under running workers). The strings sum AFTER the cap, so the whole web can still stand above one string's ceiling — the ratio is per string, not per bus. **`bow_jt_cap_bus` (2026-09-02) blends the SCOPE** between the two: 0 = per string (the above, the default); 1 = per taraf — the rows stand and the summed web is held against the same ceiling in the kernel's hold walk (`jt_cap_bus`: a feed-forward 150 ms peak envelope of the raw sum, the same slews, one gain on mono and side — the 2026-08-31 bus limiter, now inside the kernel); between, both stages share the hardness — each row removes hard·(1−bus) of its own dB overshoot, then the sum removes hard·bus of what remains. The bus end leaves LESS ring than the per-string end at the same ratio (it holds the sum; per string, the capped rows still add), so the knob runs from "one hot string is held alone" to "one hot string ducks the whole web" — bind it to a tilt axis to lean between them mid-phrase. Pre-FX and pre-trim (both buses share the trim, so the ratio matches the calibrated merge); the balance stays a manual mix move after it, and the cap no longer forces the split-bus render path. One deliberate consequence: armed hard while the voice is silent from launch, the ceiling is ~zero — drones and the tanpura's `tp_taraf` charge are held down until the voice first sounds. `TarafCapTests` pins byte-null at hard 0, taraf-only reduction (the voice bus repeats exactly), monotonicity in both knobs, the worker-pool path (`bow_jt_threads` 2, async off) and the scope blend (bus 1 < bus 0.5 ≤ bus 0 in remaining ring at ratio 0.1).

## Re-fitting

To change the DSP, edit `Packages/SarangiKit/` directly — it is Tarabdaar's own code since the upstream link was cut (2026-07-24), and `TarafRemovalParityTests` will flag any change to the shipping signal path. Tarabdaar does not re-fit the physics in-tree; the fitted values ship in `bowed_string.json`. See CLAUDE.md's "Sound Design Iteration" section and [sarangi.md](sarangi.md).

## What a rebuild costs (measured 2026-07-24)

Parameters that are engine-build values (`rebuild`, and `hybrid` pushed
above its built value) cannot be poked into a running kernel — they
require constructing a fresh `BowEngine`. Numbers from
`Packages/TarabdaarCore/Tests/TarabdaarCoreTests/RebuildCostTests.swift`,
which is checked in so these stay honest:

| | |
|---|---|
| Full rebuild | **~218 ms** (off-thread — latency, never a dropout) |
| …of which tables + kernel + worker pool | **~4.5 ms** |
| …of which the **settle pre-roll** | **~214 ms (98%)** |

The pre-roll is the whole cost. A fresh kernel's jawari web relaxes off
the builder's `q0` with an audible chime — the analytic static wrap is
not an exact equilibrium of the discrete contact — so `buildEngine`
renders and discards audio while it dies. **The DAMPED SETTLE
(2026-08-18) kills the chime at the cause:** the taraf is choked
(`BowEngine.setJtSettleDamp`, t60 50 ms) while the discarded blocks
render — the contact still settles the wrap to its true discrete
equilibrium, only the oscillation dies — and the natural ring is
restored EXACTLY before publish (a pure per-tick momentum scalar,
0 = byte-null). Undamped, the chime asymptoted near −50 dBFS (per
85 ms block: −33, −45, −48, −49, −49, −50, −53) and the anchors' 7–9 s
tails rode out audibly for ~10 s after launch; damped, the publish
peak measured −80/−88/−93/−102 dBFS at 1/2/3/5 blocks on the velocity
pickup, and **3 blocks** shipped from 2026-08-18. **2026-09-03: 5 blocks
again** (`StringVoiceSource.settleBlocks`) — the bridge-force radiation
hears the choked chime ~7 dB hotter per block than the pickup did
(publish peak −74/−80/−87/−102 dBFS at 3/4/5/8 blocks), so 3 broke the
absolute −80 dBFS publish bar in `RebuildCostTests` and 4 only grazed it;
the pre-roll is back to ~360 ms of off-thread latency (the table above
predates it — scale the pre-roll row ×5/3). The silent publish also lets the quiescence gate close
on the web within ~30 ms of launch instead of ~10 s.
Lengthening the crossfade never substituted: 180 → 450 ms
of fade bought only 1 dB, because what remained was the web's steady idle
floor, not a decaying transient. Fixing it properly means an upstream `q0`
that does not leave the web charged at t = 0.

**Continuity.** A fresh engine has zero string/taraf/room state, so an
abrupt swap is very different depending on what is sounding:

| | hard swap | crossfaded |
|---|---|---|
| Note **held** across the rebuild | 96% of level within 43 ms — a step, not a dropout | seamless |
| Swap **during the ring** (after note-off) | **4.9% of the tail survives** — the ring is cut | **69%** — it decays naturally |

So `StringVoiceSource.setEngine` keeps the outgoing engine rendering and
equal-power crossfades into the new one over
`StringVoiceSource.engineCrossfadeMs` (300 ms). That costs 2× voice CPU
for the fade window only: measured at the app's 128-frame buffer,
**11% of realtime for one engine, 19% for two**.

**Why the distinction still exists internally.** At ~218 ms per build
plus a 300 ms fade, build-time parameters are fine under a slider but
cannot be swept at tilt rate (60 Hz). `ParamRegistry`'s `apply` field is
therefore a routing hint, not a user-facing category — nothing in the UI
labels it, and the row's help text mentions it only for anyone chasing
latency (click a row label to show the help text inline; hover tooltips
carry the same text but macOS shows them unreliably).

A `hybrid` parameter's `ParamSpec.restFraction` is what keeps the shipped
sound when its live scaler is at rest: jawari buzz rests at **1.0×** the
built depth (the fitted sound), vibrato depth at **0×** (silent until the
player asks for it). Get these wrong and the instrument boots sounding
different from the artifact.

## In-place parameters (2026-07-24, stages 1+2)

Most parameters no longer rebuild at all. `BowEngine.setLiveParams` pushes
an edit onto the **running** kernel: the 65 per-sample scalars are
overwritten (`bow_poly_set_scalars`) and the Swift-side mapping constants
are re-read. Nothing is reset — the
string histories, taraf ring, jawari web, room tail and note articulation
all carry straight through.

**How far it goes.** `ParamLivenessTests` classifies every parameter
empirically (perturb it, rebuild the tables, diff what actually moved):

| Tier | Count | Status |
|---|---|---|
| kernel scalars | 20 | **in place** (stage 2) |
| no table movement (mapping constants, output/room/radiation) | 26 | **in place** (stage 1) |
| coefficient arrays — body modal bank + jawari tables | 13 | **in place** (stage 3) |
| array **sizes** change (`bow_body_modes`) | 1 | genuine rebuild |

(Counts are post-2026-07-24: deleting the sympathetic web removed 14
parameters and with them the whole "coefficient arrays — sympathetic web"
tier — the 7 keys that could not be pushed live. A handful of keys still take the
rebuild path in practice: `bow_body_modes`, which resizes the bank, plus
`bow_rev_rt60` and the three `bow_st_*` stereo spreads, which the probe
files as engine-side but which `BowEngine` reads once at construction.
`bow_jtaraf_on` was a fifth until 2026-08-02, when the taraf's arming
switch was removed — the block is unconditional now.)

Stage 3 reloads the body bank (`bow_set_body`) and the jawari tables
(`bow_jt_set_coeffs`) onto the running kernel. Histories are kept on both:
the body resonators keep their state (so retuning the body under a note is
click-free, the same trick as swapping biquad coefficients), and the
jawari web keeps its settled wrap, so it relaxes into the new bone
geometry the way a real jawari adjustment does.

**Trap:** `bow_jt_load` is the *init-only* entry point and it **mallocs** —
calling it a second time leaks and re-allocates the web. Reloading jawari
coefficients onto a live kernel is `bow_[poly_]jt_set_coeffs`, which
overwrites in place and refuses on a shape change.

The sympathetic web used to be the one group left out — its delay-line
lengths and per-voice charge window cannot be swapped under a running ring
— but the web itself is gone (2026-07-24), so `bow_body_modes` is now the
only genuinely structural parameter left.

`ParamRegistry.inPlaceKeys` is the shipped set (73 keys);
`StringParamStore` tries the fast path and falls back to a rebuild when a
touched key needs fresh tables. Verified: a pushed value settles within
**0.03 dB** of an engine built with it baked in, a held note keeps 100% of
its level, and a decaying ring keeps 76% (a hard swap kept 4.9%).

### Zipper

The push writes coefficients directly, so it was measured for zipper
(`ZipperTests`) rather than assumed safe:

| Case | Excess HF vs a smooth sweep |
|---|---|
| `bow_mu_s` swept over 2 s at 60 Hz | −2.0 dB |
| gain-like parameters (`bow_w`, `bow_body_c0`, `bow_jt_gain`, `bow_live_trim`, `bow_rev_mix`), full range in 150 ms | −0.4 … +0.1 dB |

No zipper at tilt rate. Friction coefficients cannot click by
construction — they change how the string *evolves*, not the current
sample. The parameters that CAN click are the ones that multiply the
signal, and only on a large instantaneous jump. Measured worst case, a
+17 dB `bow_live_trim` jump mid-note:

| | seam step vs the signal's own largest sample-to-sample motion |
|---|---|
| no ramp | **17.9×** — an audible click |
| 25 ms chunk-rate ramp | 3.4× |
| + per-sample `outGain` interpolation | **0.0×** (5.2e-6 vs 3.9e-3) |

Both were needed. The chunk ramp alone leaves a ~20% step at the first
boundary because a 7× gain ratio in ~19 steps still starts coarse, so
`postChain` interpolates the output gain **across** the chunk. The ramp
also caps the render chunk to 256 frames while it runs — otherwise the
offline/audition path (4096 frames at a time) resolves the whole glide in
one step, which is exactly the click being prevented.

### The chunk cap is not neutral

The zipper ramp caps `render`'s chunk to 256 frames while it runs. Chunk
size is **not** a neutral choice: it sets the control-interpolation grid
and the jawari web's block boundaries, so splitting a 4096-frame offline
render moves a chaotic friction loop onto a different (valid, but
different) trajectory. A push that changed *nothing* was measured
deviating **41% of peak** for exactly this reason.

The ramp is therefore armed only when a ramped quantity actually moved —
a no-op push is now bit-identical (`testNoOpPushIsBitIdentical`), and a
coefficient-only reload does not arm it at all, since swapping filter
coefficients while keeping state is click-free without one. For a real
edit the chunk still splits, which is why a pushed value settles within
~0.4 dB of a rebuilt engine rather than exactly on it.

## Real-time validation (2026-07-24)

Two layers, both clean.

**Headless, buffer-accurate** (`RealtimePerformanceTests`): the voice at
the device's 128-frame buffer, notes through `BowControlMapper`, a tilt
evaluated through `DimensionBinding` into the same apply paths
`AppController` uses. Five scenarios, 1500–1875 buffers each:

| Scenario | render p50 | p99 | over budget | dropouts | worst step |
|---|---|---|---|---|---|
| Composite (Taraf Purity) swept by tilt | 9% | 23% | 0 | 0 | 2.3× |
| Direct params (`bow_mu_s` + `bow_body_q`) | 10% | 15% | 0 | 0 | 1.8× |
| 5 Hz full-range flicks | 19% | 53% | 0 | 0 | 3.6× |
| Polyphonic, everything moving | 15% | 22% | 0 | 0 | 1.9× |
| Rebuild-tier sweep (crossfaded) | 19% | 68% | 0 | 0 | 2.8× |

(Percentages are of the 2.67 ms realtime budget; "worst step" is the
largest sample-to-sample jump against the signal's own 99.9th-percentile
step.) A first version of this harness reported 13 overruns and 243% —
both were artifacts of the harness itself: a `[Float]` allocation per
buffer and wall-clock timing in a normal-priority test process. Judge
realtime behavior on p99 with preallocated buffers.

**In the app**: 19 audition runs through the running TarabdaarMac, which
renders in realtime through the device path. Held-note tilt sweeps, 5 Hz
and 20 Hz flicks, all three tilt axes, 60 Hz in-place parameter sweeps,
polyphony, drones + notes + tilts + parameters together, a 30-second
continuous phrase, and a **rebuild storm** (a rebuild-tier parameter swept
at 60 Hz, queueing fresh engine builds continuously — the worst thing a
tilt could be mapped to). Every render: worst step **1.0–1.9×**, **zero**
dropout windows, zero NaN, and the app's own watchdog logged **zero
render overruns and zero jawari-web overloads**. Repeats of the four
hardest scores were equally clean.

The control matters as much as the result: an identical score with the
parameter motion removed differs from the swept one by 128% of signal
RMS, so the clean numbers are not measuring an inert path.

**Not covered**: in-app the tilts drove composites (the shipped default
bindings) — a tilt bound *directly* to a single parameter was exercised
only in the headless harness. And a real iPad over USB-MIDI adds
MIDI-thread jitter the in-process simulator does not have.
