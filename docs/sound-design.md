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
- **The modal-jawari taraf, fused in-kernel** (`bow_jt_*`, armed by default). The sympathetic web + the steel-lattice jawari subset, driven one block late on its own worker pool (the callback never waits). Tuned from the **Tarab tab** rows.
- **The formula body** — modal resonators derived from physical scalars (no FIR/fingerprint/coupled artifacts).
- **Stereo** — the poly kernel renders a side stream of the direct radiation (taraf tap + jawari rows + bow noise), panned per pitch class around the tonic; `L/R = mid ± side`, mono fold-down bit-identical, plus the width-decorrelated room (`Reverb.processMonoStereo`).

## Editing the sound

- **The parameter list (Parameters tab, ⌘5).** `ParametersView` over `ParamRegistry` — eight groups (Bow stroke / Body / Bow & string / Playing ranges / Jawari taraf / Taraf / Articulation / Radiation & output) covering **every** parameter, physics and live alike, in native units with a filter box and a per-row mapping button. No row is tagged by apply strategy: `rebuild` rows re-apply through a **crossfaded** off-main `BowEngine` rebuild ~0.2 s after the value settles (see below) and persist as an override dict (`starpad.stringOverrides.v1`); `live` and `hybrid` rows apply instantly and persist in `starpad.controlDefaults.v1`. "Default (Sarangi Live)" / "Reset all" clears both, double-clicking a row label resets one. Audition path: `string.<key>` or `param.<key>`.
- **Sympathetic strings (Tarab tab, ⌘2).** The editable `[StringSpec]` tarab table (see below) tunes the kernel's in-kernel taraf.
- **Tilt / composite parameters (Controls tab, ⌘4).** Named 0–1 composite macros built from any parameters, plus direct tilt→parameter bindings — driven live from tilts or audition scores, without a rebuild wherever the parameter allows it.

## Sympathetic strings — the editable bank

The sympathetic taraf bank is a **fully editable `[StringSpec]` table** — each row a `(freq, gain, weight, t60, bright, enabled, group)` string — owned Mac-side by `SarangiStore` in `InstrumentState` and edited in the **Tarab tab (⌘2)**. The rows tune the String voice's in-kernel taraf (linear web + the modal-jawari subset).

Since the String-era default, **auto-sync to the scale starts OFF** — the default preset is the Sarangi Live default and its EXACT fitted Pilu table must stick (a scale re-sync REPLACES it with Swift-RNG-regenerated detunes, ~5 c/string off the fit; the exact table audibly matters — the string-table law). The tab's "Follow the Pitch Pad scale" switch / "Re-sync" button opt in; a hand edit / choir toggle / raga pick flips it back off. Strings are tagged by `StringGroup` (chromatic / scale-tuned / low octave / upper octave — the four choirs `RagaTuning.buildChoirs` constructs) and shown one section per choir. Full detail: [sarangi.md](sarangi.md).

## The preset

One preset ships — **"Default (Sarangi Live) — Pilu, fitted"** (`SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`), also the fresh-install default: untouched artifact physics, the exact fitted Pilu string table (`sarangi_pilu_strings.json`), Sa 328.9 Hz, auto-sync OFF. The whole `InstrumentState` persists to UserDefaults (`starpad.sarangiState.v8`) and can be exported/imported as a `.sarangi` JSON file.

## Drones

Four press-to-sound drone buttons inside the Fret Pad's right edge drive the kernel's jawari-taraf rows (pitches on `FretArrangement.droneRatios`, relative to the played tonic). Every configured pitch gets a jawari row at engine build. See [Fret Pad](fret-pad.md) for the full drone treatment and the calibrated levels.

## Levels

Calibration is inside the fitted preset (`bow_live_trim` / `bow_rev_*` set the output level). The Mac pads hold a flat per-note CC11 = 32 (the fitted expr median — CC11 is a real ±16 dB loudness axis). Loud peaks are backstopped inside the kernel.

## Re-fitting

To change the model's DSP or re-fit, work in `~/Desktop/sarangi`, then re-vendor `Packages/SarangiKit/Sources/SarangiKit/{DSP,Model,Violin,Bow}` + `Sources/CBowKernel` + the resources. Starpad vendors the fitted package and does not re-fit in-tree. See CLAUDE.md's "Sound Design Iteration" section and [sarangi.md](sarangi.md).

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
latency. It is now **4 blocks** (324 → 218 ms), guarded by an A/B test
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
labels it, and the tooltip mentions it only for anyone chasing latency.

## In-place parameters (2026-07-24, stages 1+2)

Most parameters no longer rebuild at all. `BowEngine.setLiveParams` pushes
an edit onto the **running** kernel: the 61 per-sample scalars are
overwritten (`bow_[poly_]set_scalars`, a new Starpad divergence in the
vendored C alongside the existing `bow_set_jaw_gain` / `bow_jt_set_lp`)
and the Swift-side mapping constants are re-read. Nothing is reset — the
string histories, taraf ring, jawari web, room tail and note articulation
all carry straight through.

**How far it goes.** `ParamLivenessTests` classifies every parameter
empirically (perturb it, rebuild the tables, diff what actually moved):

| Tier | Count | Status |
|---|---|---|
| kernel scalars | 22 | **in place** (stage 2) |
| no table movement (mapping constants, output/room/radiation) | 31 | **in place** (stage 1) |
| coefficient arrays — body modal bank + jawari tables | 13 | **in place** (stage 3) |
| coefficient arrays — sympathetic web | 7 | rebuilds |
| array **sizes** change (`bow_body_modes`) | 1 | genuine rebuild |

Stage 3 reloads the body bank (`bow_set_body`) and the jawari tables
(`bow_jt_set_coeffs`) onto the running kernel. Histories are kept on both:
the body resonators keep their state (so retuning the body under a note is
click-free, the same trick as swapping biquad coefficients), and the
jawari web keeps its settled wrap, so it relaxes into the new bone
geometry the way a real jawari adjustment does.

The sympathetic web is the one group left out, for two concrete reasons
rather than caution: `bow_taraf_damp`, `bow_taraf_inharm` and
`bow_taraf_pol_cents` move the **delay-line lengths**, which cannot be
swapped under a running ring; and `bow_taraf_Z` / `bow_taraf_bright` /
`bow_taraf_gain` ride the per-voice arrays including the charge window,
which `bow_init` consumes rather than stores. (`bow_taraf_jawari` is
already live downward through its hybrid scaler — the direction that
matters musically.)

`ParamRegistry.inPlaceKeys` is the shipped set (58 keys);
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
| gain-like parameters (`bow_w`, `bow_body_c0`, `bow_taraf_dir`, `bow_live_trim`, `bow_rev_mix`), full range in 150 ms | −0.4 … +0.1 dB |

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
