# Sound Design

Sound design lives entirely on the Mac (StarpadMac). The iPad is a MIDI controller and produces no audio. The Mac receives MPE over USB and renders the **sarangi String voice** — the only voice. It is `SarangiKit.BowEngine` driving the `CBowKernel` C friction kernel: a pure-physics bowed gut string that carries the **whole instrument** in-kernel — the played strings, the sympathetic (tarab) web with modal-jawari buzz, the formula body, radiation, and room. There is no hosted plugin, no base-voice selection, and no coupled bridge–body network in the signal path (the SWAM/sitar chain that used those was removed on 2026-07-24).

## Signal path

```
MPE in ► routeSarangiModelMIDI ► StringVoiceSource (BowEngine + CBowKernel, 96 kHz → 48 kHz) ► symGain ► mainMixerNode ► out
```

The `StringVoiceSource` (`Packages/StarpadCore/.../StringVoiceSource.swift`) wraps the `BowEngine` as a 48 kHz `AVAudioSourceNode` connected **directly** to `symGain → mainMixerNode`. The kernel runs at 96 kHz internally and half-band-decimates to 48 kHz; the mixer input converts to the engine rate (44.1 kHz). There is no master filter/reverb bus — the kernel owns its own body and room. See [sarangi.md](sarangi.md) for the full physics treatment.

## The played voice — the String kernel

The kernel is the byte-exact twin of the offline reference in `~/Desktop/sarangi` (`bow_kernel.c` mono + `bow_kernel_poly.c` poly, always `-O3`). Fed by **`bowed_string.json`** (`Presets.bowedStringParams()`), it produces:

- **Played strings.** `bow_live_poly` gut strings on ONE shared delay-free bridge (poly-as-physics); a single held line is mono meend through the 9 Hz pitch smoother. Analytic Schelleng press envelope, place-then-draw + attack-bite articulation, aftertouch vibrato, self-calibrated intonation tables.
- **The modal-jawari taraf, fused in-kernel** (`bow_jt_*`, armed by default) — modal steel strings over grazing jawari bones on the steel-lattice subset of the tarab rows, driven one block late on its own worker pool (the callback never waits). **This is the instrument's entire sympathetic response** since 2026-07-24: a second, LINEAR comb web (`bow_taraf_*`, plus the open gut pair `bow_open_*`) used to hang off the same bridge, approximating a buzzing sympathetic with a comb and a flat-bridge buzz term. Silenced it sounded better, so it was deleted. Tuned from the **Tarab tab** rows. The tanpura/sitar **twang** — the harmonic cascade that sweeps the ring's spectrum upward and back down — lives in a narrow amplitude band around the graze knee, and `bow_jt_evolve` (2026-07-26, default 0.5 = bit-exact, `.live` — a kernel-slewed bone lift, the one sanctioned runtime bone move, tilt-sweepable without a strum) makes it fast-and-reliable (1) or absent (0); `bow_jt_tap` + `bow_jt_hp` voice the radiated ring as the jawari formant (high-harmonic cluster over quiet lows); `bow_jt_body` (2026-08-01, `.live`, default 0 = byte-exact) blends the radiated taraf through the voice's own body radiation bank — the coherence lever: the taraf rings from the instrument's body instead of beside it. Mechanism and measurements in [sarangi.md](sarangi.md).
- **The formula body** — modal resonators derived from physical scalars (no FIR/fingerprint/coupled artifacts).
- **Stereo** — the poly kernel renders a side stream of the direct radiation (jawari rows + bow noise), panned per pitch class around the tonic; `L/R = mid ± side`, mono fold-down bit-identical, plus the width-decorrelated room (`Reverb.processMonoStereo`).

## Editing the sound

- **The parameter list (Parameters tab, ⌘5).** `ParametersView` over `ParamRegistry` — seven groups (Bow stroke / Body / Bow & string / Playing ranges / Jawari taraf / Articulation / Radiation & output) covering **every** parameter, physics and live alike, in native units with a filter box and a per-row mapping button. No row is tagged by apply strategy: `rebuild` rows re-apply through a **crossfaded** off-main `BowEngine` rebuild ~0.2 s after the value settles (see below) and persist as an override dict (`starpad.stringOverrides.v1`); `live` and `hybrid` rows apply instantly and persist in `starpad.controlDefaults.v1`. "Default (Sarangi Live)" / "Reset all" clears both, double-clicking a row label resets one. Audition path: `string.<key>` or `param.<key>`.
- **Sympathetic strings (Tarab tab, ⌘2).** The editable `[StringSpec]` tarab table (see below) tunes the kernel's in-kernel taraf.
- **Tilt / composite parameters (Controls tab, ⌘4).** Named 0–1 composite macros built from any parameters, plus direct tilt→parameter bindings — driven live from tilts or audition scores, without a rebuild wherever the parameter allows it.

## Sympathetic strings — the editable bank

The sympathetic taraf bank is a **fully editable `[StringSpec]` table** — each row a `(degree, octave, gain, t60, enabled)` string. **Pitches come straight from the centralized scale** (2026-07-25): `degree` indexes the Pitch Pad scale's ratios, `octave` shifts by whole octaves, and absolute Hz is minted only at resolve time (millihertz grid) against the one tonic — so a scale or tonic move retunes the whole bank, always. Owned Mac-side by `SarangiStore` in `InstrumentState` and edited in the **Tarab tab (⌘2)** as one flat table (pitch + octave dropdowns; no ratio or Hz inputs — the app's one Hz input is the tonic on the Fret Pad tab). The rows tune the String voice's in-kernel modal-jawari taraf. They used to feed a linear comb web as well; that web was deleted 2026-07-24, so a row the jawari selection does not pick up is now inert.

**Following the scale is unconditional** — the "Follow the Pitch Pad scale" toggle was removed 2026-07-25. The row LAYOUT (the string set: degrees + Sa/Pa emphasis + octave repeats; always pitch-sorted, one string per pitch since 2026-07-26) regenerates when the scale's degree count changes or via the tab's "Regenerate from scale" button; hand edits to gains/decays/rows otherwise stand. (The fitted-table era's opt-in sync and the **string-table law** it protected were retired the same day with the scale-defined pitch model — a degree can't be a few cents off itself, so the fitted per-string detunes are gone and the taraf sits exactly on the scale's JI grid.) Full detail: [sarangi.md](sarangi.md).

## The preset

One preset ships — **"Default (Sarangi Live) — Pilu"** (`SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`), also the fresh-install default: untouched artifact physics + the generated Pilu-scale seed bank, replaced by the Pitch Pad scale on the first push. The whole `InstrumentState` persists to UserDefaults (`starpad.sarangiState.v8`) and can be exported/imported as a `.sarangi` JSON file.

## Saving and loading presets (2026-07-24; unified 2026-07-30)

Five UserDefaults keys hold the editable state: the sarangi `InstrumentState`
(`starpad.sarangiState.v8`), String physics overrides
(`starpad.stringOverrides.v1`), resting parameter values
(`starpad.controlDefaults.v1`), composites (`starpad.compositeParams.v1`) and
tilt bindings (`starpad_dimensionMapping_v6`).

They save and load as **one `StarpadPreset` document** — one preset is one
rig (`Packages/StarpadCore/.../PresetDocument.swift` — it is data, not UI,
hence the package), via `AppController.capturePreset(name:)` /
`applyPreset(_:)`, driven from the Parameters-tab toolbar
(`PresetToolbar`). A preset carries every section: the sarangi document,
the physics overrides, `paramValues`, the composites and `tiltMapping`.

**No file panels.** Saved presets live in the app-managed **library**
(`PresetLibrary`, `Application Support/Starpad/Presets/`, one `.starpad`
file per preset named after it): **Save preset…** asks only for a NAME
(same name = overwrite, the popover says so), and every saved preset
appears in the **Load preset** menu automatically, under the factory
default(s) (`AppController.loadFactoryPreset`, which resets the whole
rig — bank, physics, parameter values, composites AND tilt bindings). A
**Delete preset** submenu removes entries. The menu refreshes on every
save/delete and on toolbar appear, so a `.starpad` file dropped into the
folder by hand shows up too — that folder IS the import/export surface.
Guard: `PresetLibraryTests`.

History: from 2026-07-24 to 2026-07-30 the document saved as two
scope-filtered halves — an instrument `.starpad` (Parameters tab) and a
controls `.starpadmap` (Controls tab), each through its own save/open
panel. The split was folded back together and the panels replaced by the
library; `PresetScope` is gone. Every section is still optional, so a
split-era file dropped into the library folder (rename a `.starpadmap`
to `.starpad` first) opens and applies exactly the sections it carries
(the `kind` tag decodes away ignored), and old bare-`InstrumentState`
`.sarangi`-content files load through `StarpadPreset.decode`'s legacy
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

Guards: `Packages/StarpadCore/Tests/StarpadCoreTests/PresetCodingTests.swift`.

## Drones

Three press-to-sound drone buttons inside the Fret Pad's right edge each pluck **one mapped sympathetic string** (Tarab tab "Drone buttons" section, `InstrumentState.droneStringIds`; auto-mapped to the loudest strings near low Sa · low Pa · Sa). There are no dedicated drone rows — the jawari web is the tarab alone, a mapped string sounds exactly as its row is tuned, and an unmapped/disabled/unselected row leaves the button silent. See [Fret Pad](fret-pad.md) for the full drone treatment and the calibrated levels.

## Levels

Calibration is inside the fitted preset (`bow_live_trim` / `bow_rev_*` set the output level). The Mac pads hold a flat per-note CC11 = 32 (the fitted expr median — CC11 is a real ±16 dB loudness axis). Loud peaks are backstopped inside the kernel.

## Re-fitting

To change the DSP, edit `Packages/SarangiKit/` directly — it is Starpad's own code since the upstream link was cut (2026-07-24), and `TarafRemovalParityTests` will flag any change to the shipping signal path. Starpad does not re-fit the physics in-tree; the fitted values ship in `bowed_string.json`. See CLAUDE.md's "Sound Design Iteration" section and [sarangi.md](sarangi.md).

## What a rebuild costs (measured 2026-07-24)

Parameters that are engine-build values (`rebuild`, and `hybrid` pushed
above its built value) cannot be poked into a running kernel — they
require constructing a fresh `BowEngine`. Numbers from
`Packages/StarpadCore/Tests/StarpadCoreTests/RebuildCostTests.swift`,
which is checked in so these stay honest:

| | |
|---|---|
| Full rebuild | **~218 ms** (off-thread — latency, never a dropout) |
| …of which tables + kernel + worker pool | **~4.5 ms** |
| …of which the **settle pre-roll** | **~214 ms (98%)** |

The pre-roll is the whole cost. A fresh kernel's jawari web relaxes off
the builder's `q0` with an audible chime, so `buildEngine` renders and
discards audio until it dies down. Measured idle peak per 85 ms block:
−33, −45, −48, −49, −49, −50, −53 dBFS — it asymptotes near −50, so the
old 6-block pre-roll bought ~1 dB over 4 blocks for ~110 ms of extra
latency. It is now **4 blocks** (`StringVoiceSource.settleBlocks`,
324 → 218 ms), guarded by an A/B test
that publishes with both lengths and fails if the short one is more than
2 dB louder. Lengthening the crossfade does *not* substitute: 180 → 450 ms
of fade bought only 1 dB, because what remains is the web's steady idle
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
an edit onto the **running** kernel: the 61 per-sample scalars are
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
tier — the 7 keys that could not be pushed live. Five keys still take the
rebuild path in practice: `bow_body_modes`, which resizes the bank, plus
`bow_jtaraf_on`, `bow_rev_rt60` and the two `bow_st_*` stereo spreads,
which the probe files as engine-side but which `BowEngine` reads once at
construction.)

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

`ParamRegistry.inPlaceKeys` is the shipped set (55 keys);
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

**In the app**: 19 audition runs through the running StarpadMac, which
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
