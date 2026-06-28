# Sarangi — the played voice

Starpad's sarangi is the ported **`SarangiKit`** model
(`Packages/SarangiKit/`). It takes the **dry SWAM Violin** (`aumu/Svl3`) audio as
input and transforms it, through a block signal chain, into the **complete**
sarangi sound — bowed string + sympathetic strings + bridge buzz + body, then a
**per‑voice FX rack** (filter + EQ + reverb). It is the whole played voice, not a
halo layered on top of the violin.

> **Why violin, not viola.** SWAM **Violin** is a bright, edgy bowed model whose
> 2–6 kHz energy reaches the real sarangi's penetrating *sharpness* (the darker
> viola could not). It runs **dry** — SWAM's own room/reverb/ambience/body are all
> off in the preset's `hostedAUParams` — because the model supplies body and room
> itself, and the offline fit's input (`input1.wav`) was a dry violin. The
> shipping preset case keeps its `swamViola` rawValue for persistence
> compatibility but hosts `Svl3`. Code names like `violaBodyEQ` are historical.

This model was built and fitted in a **separate project** (`~/Desktop/sarangi`)
against two real sarangi recordings (`target1.wav` E♭ harmonic minor, `target2.wav`
Bhairav) whose notes were re-played on the dry violin (`input1/2.wav`). It was
ported into Starpad by **vendoring its pure‑Swift DSP library wholesale**; re‑sync
by recopying `Sources/SarangiKit/{DSP,Model}` + `Resources/*.json` from upstream.

## The block chain

`SarangiEngine.renderSample(_ input: Double, amp: Double) -> (Double, Double)`
runs mono‑internally and goes stereo at the per‑voice FX rack (each FX stage
produces a stereo reverb). `input` is one dry‑violin sample; `amp` ∈ [0,1] is the
note's amplitude envelope (a causal one‑pole follower on the drive — see
*Excitation* below). The blocks (`Packages/SarangiKit/Sources/SarangiKit/DSP/`):

- **A — dry/body pre‑EQ.** A parametric pre‑shaper (currently a pass‑through; room for future tuning).
- **B — sympathetic bank** (`ResonatorBank` of `CombString`s). **37 strings** in
  two choirs: a **clean** chromatic row (15 fixed JI ratios, driven by the dry
  input) and a **bright** raga‑tuned set (driven by `input + C_to_bank·jaw`),
  built by `RagaTuning.buildStrings(tonic:intervals:)`. Each string is a
  **Karplus–Strong feedback comb** (fundamental + all harmonics → a real plucked
  shimmer, not a pure sine), with a seeded ±cents Gaussian detune so the strings
  beat against each other like a real tarab.
- **C — jawari exciter** (`JawariExciter`). The bridge "buzz": a 4× oversampled
  asymmetric `tanh` shaper (adds odd+even harmonics) feeding a **downward‑sweeping
  morphing bandpass** (the precursor that descends as the note decays), plus
  optional rasp + top‑edge HF shimmer. The drive/sweep/wet all scale with `amp`.
- **D — drone generator** — *REMOVED in Starpad.* It was an activity‑gated
  resonator bank at `tonic/4` (the laraj/jiva low resonance), but at sub‑bass it
  turned into a clipping low rumble when the sym was boosted, so block D
  (`DroneGen`, the `D_*`/`mix_drone` params) was deleted from the model.
- **E — body color** (`BodyColor`, two instances: `bodyViolin` + `bodySym`). A
  measured min‑phase **body FIR** (1025 taps, per preset) on the dry branch + a low
  shelf, plus **6 modal body resonances** (parchment/wood formants) on the generated
  content. Split into a violin‑voice ring and a sym‑voice ring because
  `colorSupplement`'s RMS energy‑match is non‑additive (you can't run one shared
  body over the summed signal and get the same result).
- **F — reverb** — *replaced by the per‑voice FX rack.* The model's old single
  Freeverb tank (block F) is **gone**; its `F_*` params were removed from
  `ParamSpec`. Instead `renderSample` splits its output into the **Violin** voice
  (dry + jawari, through `bodyViolin`) and the **Sym** voice (bank, through
  `bodySym`), applies a per‑voice **FX stage** to each, sums them, then applies a
  **Global** FX stage. Each stage = a low‑pass filter (cutoff + resonance) → 3‑band
  parametric EQ → reverb (mix + width). See *FX rack* below.

### Excitation

The sarangi is driven by SWAM's **audio**, not by note events. On the audio
thread (`AudioEngine`), the `SarangiProcessorAU` effect's `internalRenderBlock`
pulls the summed dry SWAM stereo (full level) synchronously into a private scratch
buffer, forms the mono drive `x = 0.5·(L+R)` (lifted by `sarangiDriveGain`),
derives `amp` with a `SignalAmpFollower` (one‑pole on `|x|` vs a fixed reference —
the live replacement for the offline `env/env.max()` normalisation), and calls
`renderSample(x, amp:)` per sample. There is **no `setPlayedNotes`** — the bank
rings from whatever harmonics the drive contains.

## Sympathetic strings (the Tarab tab, ⌘3)

The tarab live in their own **Tarab tab** (`TarabView`), split into the four
physical **choirs** — a `StringSpec` (`Model/StringSpec.swift`) is `freq, gain,
t60, bright, enabled, group`, where `group: StringGroup` is one of
`chromatic / scale / lowOctave / upperOctave`. The editor shows one collapsible
section per choir (count + Enable-all + add + per-string rows).

**By default the bank auto-tunes to the Pitch Pad scale** (`autoSyncToScale`,
true by default): an `AppController` sink on `pitchPad.$scale`/`$tonicMidi`
calls `syncTarabFromScale` → `SarangiStore.syncTarabToScale` →
`InstrumentState.regenerateFromScale(tonicHz:ratios:)`, which rebuilds the
choirs from the tonic Hz + the scale's degree ratios
(`scaleDegrees(from:).map(\.ratio)`) via `RagaTuning.buildGroupedSpecs`. The
chromatic choir stays the fixed 15 JI ratios; the scale / low / upper choirs
follow the degrees. So the strings resonate with the notes you actually play —
the physical sarangi behaviour.

Editing a string, toggling a choir, picking a **raga** (the *Manual tuning*
fallback — two ships in `RagaTuning.ragas`), or setting the tonic there flips
`autoSyncToScale` **off** (manual mode, so edits stick); the tab's "Follow the
Pitch Pad scale" switch / "Re-sync" button re-engages it
(`AppController.setTarabAutoSync`). `RagaTuning.buildStrings(intervals:) ->
[ResolvedString]` is unchanged (DSP + golden parity); `buildChoirs` /
`buildGroupedSpecs` are the group-tagged builders.

> This **re-couples** the tarab to the Pitch Pad scale — reversing the interim
> "tarab independent of the scale" design (the user re-requested auto-sync).

## The model parameters

`ParamSpec.all` (`Model/ParamSpec.swift`) defines every tweakable (23: the
upstream fit's set minus the removed drone **and the removed `F_*` reverb group**,
plus the Starpad knobs below), with a range, default, group, label, and a
**`structural`** flag. Structural params (filter designs: bank `t60` scale, jawari
pre‑HP / sweep range, body shelf) rebuild the engine off the audio thread; the rest
are **live scalars** (gains/mixes) pushed without a rebuild. Groups:

| Group | Params |
|---|---|
| **Bank** | `B_gain`, `B_t60_scale`*, `B_bright`, `B_lp`* (gut-string brightness), `sym_bow_follow` |
| **Jawari** | `C_pre_hp`*, `C_drive_min`, `C_drive_max`, `C_asym`, `C_wet`, `C_rasp`, `C_top`, `C_sweep_lo`*, `C_sweep_hi`*, `C_to_bank` |
| **Body** | `E_low_shelf_f`*, `E_low_shelf_db`*, `E_body` |
| **Reverb** | *empty — the `F_*` reverb params were removed; reverb is now the per‑voice **FX rack** (the FX tab, ⌘4), not a `ParamSpec` group. The `ParamGroup.reverb` enum case is kept (empty).* |
| **Mix** | `mix_dry`, `mix_bank`, `mix_jaw`, `main_gain`, `sym_gain` |

(`*` = structural.) See [config-reference.md](config-reference.md) for ranges and
defaults. `gin`/`gout` are non‑grouped input/output gains. `sym_bow_follow`,
`main_gain`, and `sym_gain` are non‑fitted Starpad knobs (the offline
`chain.process` ignores them).

**`main_gain` / `sym_gain`** are independent **playback** levels for the two
voices — **main** = the bowed note (dry violin + jawari buzz), **sym** = the
sympathetic **bank**. They are applied at the output mix *only*: the bank is
excited by the raw drive (`x`, `jaw`) computed *before* these gains, so
**`main_gain` never changes how hard the sympathetic strings ring** (raise it for
playback volume without altering the halo, or raise `sym_gain` to bring the
shimmer forward). The bank sits **at/above** the played note; it is
**intrinsically ~30 dB below the bowed voice** in the fit, so `sym_gain` has a
wide range (0–40, default **12** ≈ −12 dB under the main = an audible halo; 40 ≈
equal). `main_gain` 0–6, default 1.0. Block E body coloring is linear, so scaling
the components at the mix is exact.

### Drive level

**`AudioEngine.sarangiDriveGain`** (the **"Drive (SWAM→model)"** slider — now in the
**FX tab's Violin section**, ⌘4) scales the SWAM signal before *both* the amp
follower and the model. The default is **1× (unity)**, matching the standalone
**Sarangi Live** app, which feeds SWAM straight into `renderSample`.

Earlier this defaulted to **10×** — calibrated to the *previous, quiet* fit
(raw in‑app SWAM ~0.017 peak is ~50× below the `input1.wav` fit level, so the old
recipe's bank was inaudible without a big lift). The **re‑vendored shared recipe
is ~15 dB hotter in the bank**, so 10× now over‑drives the model: it pins the amp
follower (reference 0.1) at saturation → the jawari sits at `C_drive_max` → a
harsh constant buzz, plus over‑hot peaks downstream. Both read as **distortion**.
At 1× the buzz tracks playing dynamics like Sarangi Live; raise toward **~3–4**
for more presence before the follower starts to saturate (~5× at SWAM ≈0.02). A
**soft limiter** on the output (`SarangiEngine.softClip`, linear below 0.9)
backstops loud peaks so pushing the drive can't hard‑clip.

See *Responsiveness* below for `sym_bow_follow`.

## Responsiveness (onset lag / the "second peak")

The bowed note and the sympathetic shimmer can arrive as two distinct peaks on a
staccato. Two mechanisms, both addressed:

- **Onset (the jawari swell).** `amp` (the `SignalAmpFollower`) gates the jawari
  swell. It is a **fast‑attack / slow‑release** peak follower (attack 5 ms,
  release 180 ms) so it tracks the bow ONSET instead of blooming ~200 ms late (a
  symmetric slow follower was the original lag).
- **After‑ring (the comb bank).** A Karplus‑Strong comb's buildup time *equals*
  its ring time, so the lush long‑`t60` bank rings ~3× longer than a staccato note
  → a late shimmer. **`sym_bow_follow`** (0–1, default 0.7) gates the bank toward
  a dedicated fast bow follower (5 ms attack / 90 ms release, decoupled from the
  jawari/drone `amp`): `0` = free authentic ring; `1` = the sym fades *with* the
  bow. At the deployed 0.7 the staccato sym tail collapses from ~400 ms to ~180 ms
  (measured: bank late‑energy 20 %→8 % at 1.0), with the in‑note timbre unchanged
  (during a held note the follower sits at ≈1, so the gate is transparent).

Quantified by `OnsetLagTests` (`swift test --filter OnsetLag`): it renders a
staccato through the live path, decomposes it into dry/bank/jawari/drone via the
mix scalars, and prints per‑component peak/centroid lag + an envelope sparkline,
writing WAVs to `/tmp/sarangi_onset/`.

## FX rack (the FX tab, ⌘4)

The model's reverb/filter/EQ live in a **per‑voice FX rack** (`FXRack`), replacing
the old single block‑F Freeverb. `renderSample` splits its output into two voices —
**Violin** (dry + jawari, through `bodyViolin`) and **Sym** (the bank, through
`bodySym`) — applies a per‑voice **FX stage** to each, sums them, then applies a
**Global** stage in mid/side (so a disabled Global is an exact passthrough). Each
stage is a **low‑pass filter** (cutoff + resonance) → **3‑band parametric EQ**
(`EQBand`: freq/gainDB/q) → **reverb** (mix + width). The DSP is `VoiceFX`
(`SarangiKit/DSP/VoiceFX.swift`, reusing `Biquad` / `BiquadChain` / `Reverb`); the
params are `EQBand` / `VoiceFXParams` / `FXRack` (`Model/VoiceFXParams.swift`). The
rack is stored on `InstrumentState.fx` (persisted to UserDefaults with a tolerant
decode; `SarangiStore.persistKey` was bumped **v3 → v4**).

**Defaults: Violin FX ON** (reverb ≈ 0.25 + an open filter), **Sym OFF** (dry),
**Global OFF**. This **intentionally drops the old block‑F Sarangi‑Live reverb
match** — the default sound now has violin‑only reverb and a dry sym, by design.

**Live vs structural.** A stage's **enable** flag and its **reverb mix / width** are
**live scalars** (`AudioEngine.applySarangiFXScalars` ← `SarangiStore.applyFXChange(structural: false)`).
Its **filter** (cutoff/resonance), **EQ**, and **reverb rt60** are **structural** —
they rebuild the engine (`SarangiStore` → `AudioEngine.rebuildSarangi`).
`rebuildSarangi` and `applySarangiScalars` both now also take `fx: FXRack`.

**Audition.** `voiceParam` paths reach the rack:
`sarangi.fx.<violin|sym|global>.<enabled|reverbMix|reverbWidth|reverbRT60|filterCutoff|filterResonance>`
and `sarangi.fx.<stage>.eq<0..2>.<freq|gainDB|q>` (parsed in
`SarangiStore.setAuditionParam` / `setFXAudition`).

## Presets

Two fitted presets ship as `SarangiKit` resources, loaded via `Presets`:

- **pair1** — E♭ harmonic minor (`pair1.json` + `pair1_fir.json`)
- **pair2** — Bhairav (`pair2.json` + `pair2_fir.json`)

Each is a full `InstrumentState` (raga + tonic + strings + the 23 params + the
1025‑tap body FIR + the FX rack), so loading one reproduces that recording's offline
render. The default on first launch is **pair1**.

## Mac side: state, editor, persistence

- **`SarangiStore`** (`StarpadMac/SarangiStore.swift`) owns the editable
  `InstrumentState`. A param change routes to a **live‑scalar** update
  (`AudioEngine.applySarangiScalars`) or a **debounced structural rebuild**
  (`AudioEngine.rebuildSarangi`), keyed off `ParamDescriptor.structural` —
  exactly the split the standalone model uses. Auto‑saves to UserDefaults; can
  export/import `.sarangi` JSON.
- **Sarangi tab (⌘2)** (`StarpadMac/Views/SarangiEditorView.swift`): the model's
  **timbre** only — a preset picker (pair1/pair2), Reset / Save / Load, the 23
  grouped param sliders + master output. (The old master‑FX section moved out — see
  the FX tab below.)
- **Tarab tab (⌘3)** (`StarpadMac/Views/TarabView.swift`): the sympathetic
  strings — the auto-sync switch + "Re-sync", the four choir sections, and the
  raga/tonic *Manual tuning* fallback. See *Sympathetic strings* above.
- **FX tab (⌘4)** (`StarpadMac/Views/FXView.swift`): the per‑voice FX rack — three
  sections (**Violin / Sympathetic / Global**), each an enable toggle + reverb
  (mix + width) + filter + 3‑band EQ; the **Violin** section also hosts **Drive
  (SWAM→model)**. See *FX rack* above.

## Audio graph

`AudioEngine` (`Packages/StarpadCore/Sources/StarpadCore/AudioEngine.swift`):

```
N × SWAM Violin (dry) → hostedDriveTap → SarangiProcessorAU → symGain ──────────────────────► mainMixerNode → output
                          (sums poly)     renderSample(x, amp)                                      ▲
                                          (per-voice FX rack inside)                                │
   tanpuraSource → tanpuraGain ───────────────────────────┐                                        │
   sitarSource   → sitarGain   ───────────────────────────┤                                        │
                          preReverbMixer → masterFilter → reverb → postReverbEQ ────────────────────┘
```

The sarangi model is rendered **inline** by `SarangiProcessorAU` — a custom
in‑process AUv3 effect (`Packages/StarpadCore/.../SarangiProcessorAU.swift`)
spliced into the graph right after `hostedDriveTap`. Its `internalRenderBlock`
pulls the summed SWAM stereo and runs the model render closure
(`AudioEngine.makeSarangiProcessBlock()`) inline, so it adds **~0 ms latency**
(`sarangiEffect_latency = 0.00 ms`); it replaced an earlier
`installTap(4096)` → `SPSCAudioRing` → separate `sourceNode` transport that added
~140 ms. The effect is created synchronously **before `engine.start()`** (an
`AVAudioUnitEffect` after a one‑time `registerSarangiAUOnce()`, subtype `'Srng'`),
because a custom AU connected into an already‑running engine does not allocate its
render resources. The model applies its **per‑voice FX rack** internally
(Violin + Sym FX stages → sum → Global stage; no more block‑F reverb) and goes
`symGain → mainMixerNode` **directly, bypassing Starpad's master FX** (the
`SWAM→model` drive default is 1× = unity). The master chain (`preReverbMixer →
masterFilter → reverb → postReverbEQ`) is now the room for the **tanpura + sitar
only**. The model also keeps its own **body** (block E, split `bodyViolin` +
`bodySym`). The old muted dry‑SWAM passthrough is gone; the now‑dangling
`hostedInstrumentGain` / `hostedMakeupGain` / `sarangiMixer` / `violaBodyEQ` nodes
stay **attached but disconnected** so their property setters remain valid.

## Tests

`Packages/SarangiKit/Tests/SarangiKitTests/` (15 tests): DSP parity against Python
goldens (`Biquad`, `Resonator`, `CombString`, `ResonatorBank`, `BodyColor`,
`FIRFilter`) plus engine tests (`testBankRings`, `testDryPassthrough`,
`testStability`, `testStereoWidth`, `testBankCount`) and model tests
(`buildStrings` parity, note‑name round‑trip, preset defaults/ranges). Run with
`cd Packages/SarangiKit && swift test`.

## Calibration notes

- **Sample rate matches.** The whole offline fit runs at `PROC_SR = 44100`
  (`io_util` resamples the 48 kHz input WAVs down to 44.1 kHz before fitting), and
  the body **FIR** is designed at 44.1 kHz (`app/tools/gen_fir.py`). Starpad runs
  at `Config.sampleRate = 44100`, so the FIR and Starpad agree exactly — no
  resampling, no coloration mismatch. (The upstream *app* runs its engine at
  SWAM's 48 kHz native rate, so Starpad is actually a *closer* match to the fit
  than the standalone is.) The combs/jawari/drone/reverb are sample‑rate‑parametric
  (designed from `sr`), so they're correct at 44.1 kHz too.
- The `SignalAmpFollower` reference (0.1) and the model's `gin`/`gout` are the
  knobs for matching SWAM's in‑app drive level to the fit. Tune by ear.
