# Sarangi — the played voice

Starpad's sarangi is the ported **`SarangiKit`** model
(`Packages/SarangiKit/`), vendored from the Sarangi Live project
(`~/Desktop/sarangi`). Since the **2026‑07‑21 re‑vendor** (the upstream
**String‑only simplification** — "the String era") the played voice is the
**String instrument**: a GENERIC PURE‑PHYSICS bowed gut string —
**`BowEngine`** running the **C friction kernel** (`CBowKernel`,
`bow_kernel.c`/`bow_kernel_poly.c` — the byte‑exact twin of the offline
Python render's C source) at 96 kHz, decimated to 48 kHz, with:

- a **formula body** (modal resonators from physical scalars — no fitted FIR,
  no fingerprint mask, no coupled/chain artifacts),
- the **modal‑jawari taraf fused in‑kernel** (`bow_jt_*`: the grazing‑bone
  modal‑contact physics validated by the upstream tanpura campaign; armed by
  default via `bow_jtaraf_on 1`, running ASYNC one‑block‑late on its own
  worker pool so the audio callback never waits). Since the **2026‑07‑22
  J8z6 re‑vendor** the shipping jt config is **J8/zone6**: `bow_jt_J` 8
  with the new `bow_jt_zone` 0.006 key (default 0.010 = legacy) — the
  contact lives in ~6 mm around the apex, so a narrowed zone concentrates
  the modes on the active region (`BowTables.buildJawariTables` reads it;
  upstream measured J8z6 closer‑to‑converged than the old J16 at 10 mm and
  ~24% cheaper),
- an **analytic Schelleng press envelope** (wedge‑relative force mapping),
  place‑then‑draw articulation with attack bite, aftertouch vibrato, and
  **self‑calibrated intonation** (two‑stage pitch‑correction tables),
- **polyphony as physics**: `bow_live_poly 8` gut strings on ONE shared
  bridge (delay‑free junction) — chords are extra strings, a single line is
  mono meend on one string (9 Hz glide smoother).

The whole instrument — played strings + taraf + body + radiation + room — is
the kernel; it needs ONLY **`bowed_string.json`** and renders **straight to
the mix** (in Starpad: `StringVoiceSource` → `symGain`, BYPASSING
`SarangiProcessorAU`'s coupled network — that would double the taraf).
Upstream deleted the v57 additive voice and the fitted live Bow from its app
(git history holds them); Starpad follows: the v57 `SarangiModelSource` is
gone and the **"Sarangi (string model)" base voice** (`BaseVoice
.sarangiModel`, audition index 5) IS the String instrument.

**What remains of the v57 era in Starpad:** `SarangiEngine.renderSample` —
the passive coupled bridge–body network — is still vendored (upstream keeps
it for its offline tools) and still runs inside `SarangiProcessorAU` as the
chain that colors the **SWAM and sitar base voices** (those paths are
unchanged, including the FX rack / Sarangi‑tab params / Harmonics rings). The
2026‑07‑21 re‑vendor also brought the network the upstream **per‑class
taraf‑jawari buzz** (`N_jaw_raga`/`N_jaw_chrom`/`N_jaw_lp`, ParamSpec now
**25** params; applied to the radiated copy only) and the refreshed fitted
JSONs (rowfix‑era `sarangi_model_v57.json`, `sarangi_coupled.json`,
`sarangi_pilu.json` with the adopted jawari depths raga .4 / chrom .2).

The fit lives in `~/Desktop/sarangi`. Starpad **vendors the DSP library
wholesale**; re‑sync by recopying
`Sources/SarangiKit/{DSP,Model,Violin,Bow}` + `Sources/CBowKernel` + the
resource JSONs and re‑applying the Starpad‑local divergences (see *Starpad
divergences* below).

## The String instrument in Starpad

- **`StringVoiceSource`** (`Packages/StarpadCore/.../StringVoiceSource.swift`)
  — an `AVAudioSourceNode` at the artifact's native **48 kHz** (the mixer
  input SRCs to the 44.1 kHz engine) pulling `BowEngine.render`. Engine swaps
  are published under a brief unfair lock; swapped‑out engines are retained
  briefly so an in‑flight buffer never reads a freed one. Its static
  `buildEngine(tonicHz:strings:mapper:overrides:)` is the port of upstream
  `BowSource.buildStringEngine`: taraf TUNING rows = the enabled tarab
  strings, taraf PHYSICS = `bow_*` artifact keys, and the **modal‑jawari
  row selection** is the python `_jt_load` mirror (raga‑set pitch‑class
  coverage: playing‑register rows first, one 60‑cent class each keeping the
  row nearest the class median, remaining `bow_jt_max` slots by gain).
  **Realtime telemetry** (kept from the 2026‑07‑22 dynamic‑taraf
  experiment, since reverted): `StringVoiceSource.jtStats()` /
  `AudioEngine.stringVoiceJtStats()` expose the async jawari web's
  dropped‑job / flat‑fill counters, `StringVoiceSource.renderStats()`
  times every render callback against 90% of its buffer budget (a LATE
  callback glitches at the device while the audition tap records a clean
  WAV — the counter is the only way to see it), and `AppController` runs a
  5 s watchdog that NSLogs "jt OVERLOAD" / "render OVERRUN" only when the
  counters grow. When clicking is reported, check these two lines first.
- **Controls — `BowControlMapper`** (`SarangiKit/Bow/BowControls.swift`), the
  long‑lived mapper shared across rebuilds: CC11 expr · CC1 press · CC74 pos
  · CC2/**75** tilt · aftertouch = player vibrato · CC120/123 all‑off.
  **STARPAD MPE DIVERGENCE**: note identity and pitch bend are keyed by the
  status byte's channel nibble (per‑note channels, **per‑channel bend** —
  each Pitch Pad finger bends only its own gut string); a single‑channel
  controller behaves exactly like upstream. `bendRange` is set to
  `Config.midiPitchBendRange` at source creation. The Mac pads' flat CC11
  stays **32** (≈ the mapper's idle expr 0.251); the Setup‑tab axis sliders
  initialize from `BowControlMapper.default*`.
- **Rebuilds**: `AudioEngine.rebuildSarangi` (every structural tarab/tonic
  change, incl. the Pitch‑Pad scale sync) records `lastSarangiTonic`/
  `lastSarangiStrings` and, while the String voice is active, kicks
  `rebuildStringVoice` — the `BowEngine` is rebuilt **off‑main** on a serial
  queue (tables + kernel init + jt pool spawn), generation‑checked, and
  swapped in; the mapper keeps held notes/axes across the swap.
- **Artifact overrides**: `AudioEngine.stringVoiceOverrides` /
  `setStringVoiceOverrides` apply scalar overrides OVER `bowed_string.json`
  at build time. Audition path: **`string.<key>`** (e.g.
  `string.bow_jt_gain`, `string.bow_rev_mix`, `string.bow_live_trim`).
- **The String physics editor (Sarangi tab, ⌘3)** — `StringParamsView`
  (`StarpadMac/Views/StringParamsView.swift`, ported row‑for‑row from the
  upstream Sarangi Live editor so the two stay greppably in step) over
  **`StringParamStore`** (`StarpadMac/StringParamStore.swift`). Seven physics
  groups: **Body (formula modes) · Bow & string · Playing ranges · Jawari
  taraf (modal contact) · Taraf (sympathetic) · Articulation · Radiation &
  output** — every row is a `bowed_string.json` scalar, applied live via a
  debounced off‑main String‑engine rebuild. Starpad cannot rewrite the
  bundled artifact, so edits persist as an **override dict**
  (`starpad.stringOverrides.v1` in UserDefaults) applied over the artifact
  at build time; an override that lands back on the artifact value is
  dropped, so *dirty* means "differs from the Sarangi Live default".
  Double‑click a row label to reset that value; the header's **"Default
  (Sarangi Live)"** button clears everything. Slider ranges are authoring
  hints — an artifact value outside the range widens the slider rather than
  being clamped. The **25 coupled‑network params** stay below in a collapsed
  "Coupled network (SWAM / sitar chain)" section (they don't affect the
  String voice).
- **The default preset = the Sarangi Live default.** Fresh installs (and the
  preset menu's **"Default (Sarangi Live) — Pilu, fitted"** entry, via
  `SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`)
  give exactly the upstream default instrument: the untouched
  `bowed_string.json` physics (zero overrides), the EXACT fitted Pilu string
  table, Sa = 328.9 Hz, and — NEW since the String era — **tarab auto‑sync
  starts OFF** so the fitted table sticks (the Tarab tab's "Follow the Pitch
  Pad scale" switch opts back in; `SarangiStore.persistKey` bumped v7→**v8**
  so stale documents don't shadow the new default).
- **What the String voice ignores**: the coupled‑network params, the FX rack,
  the output user‑EQ, and `sarangiDriveGain` — those act on the coupled
  network (the SWAM/sitar chain). The Tarab tab IS the String voice's taraf
  tuning; room/level live in the physics panel (Radiation & output).

The sections below describe the **coupled‑network chain** — since the String
era this path colors only the SWAM / sitar base voices.

## The source model (`Violin/`, the "Sarangi (model)" base voice)

`ViolinModel` (`Violin/ViolinModel.swift`) loads `sarangi_model_v57.json`
(~3.5 MB): control‑grid dB tables for **64 harmonics** over four axes
(midi × expression × bow‑pressure × bow‑position), attack/release templates,
legato glide/dip stats, jitter/FM parameters, and per‑pitch intonation. The
voice noise bank is silenced upstream — the voice is fully deterministic.
`ViolinSynth` (`Violin/ViolinSynth.swift`) renders it causally per 256‑sample
block: coherent oscillator bank + IDLE→ATTACK→SUSTAIN→RELEASE state machine
with fitted legato glides, plus the fitted "liveness" mechanisms:

- **`SympatheticWeb`** — deterministic voice↔taraf source coupling: near‑unison
  taraf partials ring as complex one‑pole resonators in each harmonic's rotating
  frame and interfere with it *at the source*. Armed from the **live tarab
  strings** (`armSympathetic`), so it tracks the Pitch Pad scale sync.
- **`SourceFMBank`** — the taraf→source FM replica (the wash the voice excites
  modulates the voice's period, one block late).
- Audio‑rate **corner FM** + block‑rate fast FM (stick‑slip pitch noise) and the
  played‑string polarization beat (`vpol_*`).
- **`ExprEqualizer`** (`Violin/ExprEqualizer.swift`) — makes the expression axis
  a *loudness* axis: the fitted surfaces bake each note's as‑recorded loudness
  (~16 dB spread at fixed expr), so the player's expr is read as a loudness
  request on a reference curve and inverted onto the current note's own curve.
  A bundled end‑to‑end calibration (`live_comp.json`) folds in the symp/chain
  coloration.

**Control axes** (the upstream CC map, plus CC75 for the iPad): **CC11**
expression · **CC1** bow pressure · **CC74** bow position · **CC2 or CC75**
harmonic tilt (deterministic h≥5 bloom, loudness‑renormalized; −12…+24.3 dB).
Press/pos extrapolate the capture grid by up to 2 edge intervals (±12 dB cap).
Defaults idle at the fitted operating point (gated medians: expr 0.251,
press 0.562, pos 0.576, tilt +1.32 dB). The Setup tab shows the four sliders
when the model voice is active.

**Starpad integration** (`StarpadCore/SarangiModelSource.swift`): the synth runs
in an `AVAudioSourceNode` at the model's native **48 kHz** and feeds
`hostedDriveTap` in SWAM's place (the drive mixer converts to the engine's
44.1 kHz), so `SarangiProcessorAU` colors it exactly as it colors SWAM.
`SarangiModelVoiceControl` is the MIDI bridge — **monophonic** with a held‑note
stack (last‑note priority; the sarangi is a bowed single line — pick a SWAM
voice for polyphony) and **per‑channel MPE pitch bend** folded into `f0`: a bend
on the held note snaps per block (direct manipulation, ~5 ms steps), an
overlapping Note On plays the model's fitted legato glide/dip. Selected via the
Setup‑tab **Base voice** picker (`BaseVoice.sarangiModel`, the fresh‑install
default); `AppController.applyBaseVoice` unloads SWAM and connects the source.
The Mac pads' flat per‑note CC11 is **32** for this voice (≈ the fitted expr
median; 100 — a firm bow — remains for SWAM).

## The chain — the passive coupled bridge–body network

`SarangiEngine.renderSample(_ input: Double) -> (Double, Double)`, after
`beginBuffer()` **once per buffer** (pushes the live scalars and recomputes the
junction impedance tables). `input` is one dry source sample; there is **no
`amp` argument** any more — the network is driven purely by the audio. The
engine (`DSP/SarangiEngine.swift`) is the live twin of the offline
`coupled.junction_solve` / the C kernel's passive branch (parity ≤ 1e‑9,
`Goldens/coupled_passive.json`).

**The junction.** Every string loads ONE bridge with input impedance
`Z_in = Z(1+G)/(1−G)`, and the bridge velocity is solved **delay‑free per
sample**:

```
F0 = pGain·LP(input) + drone + Σ taraf states + Σ played (1−g)·w·α·x   (V-independent)
V  = (Vst + y0·F0) / (1 + y0·ΣZ)                                       (delay-free solve)
F  = F0 − ΣZ·V;  (V, rad) = body(F)                                    (states committed)
pass 2: every comb gets x_i = w·α·x − zdrv_i·V;  f_i = y_i + Z_i·V
L,R = ½(rad ± W(Σ pan_i·f_i)) + taraf tap → radiation FIR → E_lp → room → user EQ → global FX
```

The solve is **structurally stable** (the denominator is provably ≥ 1) — no
guard exists. It is realized as a two‑pass state/commit split on
`CombString` / `BodyAdmittance` / `ResonatorBank`. The per‑string impedance
tables are recomputed each `beginBuffer` from the live bank gains
(`coupled.junction_Z`: `Z_i ∝ w_i / mean w` with `w = choirGain·rel/√n` —
mean‑normalized, so `B_gain` cancels within a choir, exactly the offline law;
silent choirs are dropped).

**The pieces:**

- **Played strings.** The drive excites the bridge directly
  (`pGain` · a one‑pole LP at `N_pfc`) plus **3 open‑tuned played combs**
  (`CoupledConfig.playedRatios` = Sa 1.0 / Pa 0.75 / low Sa 0.5 at the engine
  tonic; `playedT60`/`playedBright`/`playedGain`, web‑form combs at
  inharm 0 / damp 0 = exact fractional‑delay tuning).
- **The taraf web** (`ResonatorBank` of `CombString`s, ~39 strings for the
  fitted Pilu bank): every string is its **two transverse polarizations**
  (`B_pol_split` cents apart, golden‑ratio spread; gain `B_pol_gain`, t60
  `B_pol_t60`), running in the **fractional‑delay web form** — exact tuning,
  in‑loop **dispersion allpass** (`B_inharm`: partials ring sharp like stiff
  wire), in‑loop **f² damping** (`B_damp`: upper partials decay in fractions of
  a second while the fundamental keeps the string's t60), and the gut‑string HF
  roll‑off `B_lp` baked into the loop.
- **The modal body** (`BodyAdmittance`): K modal bandpass sections with one
  shared state bank and two residue tap vectors — the bridge **admittance**
  `V = y∞·DCblock(F) + Σ aₖ·Bₖ(F)` (what loads and re‑excites the strings) and
  the **radiation** `rad = c₀·F + Σ cₖ·Bₖ(F)` (what the listener hears; signed
  `cₖ` ⇒ real interference antiresonances). **`WModalBank`** is the same
  radiation bank without the admittance, carrying the stereo **side** channel:
  the per‑string pans (`B_spread`, frequency rank across the bridge) form
  `Σ pan_i·f_i`, and `L = ½(rad + side)`, `R = ½(rad − side)` — so the stereo
  image is exactly the offline per‑string panning and the **mono sum is
  pan‑invariant**.
- **The direct taraf‑velocity tap** (`N_taraf_dir` / `N_taraf_dir_lp`): the
  taraf bank's own weighted string motion reaching the ear past the body's W —
  the string‑Q‑sharp ring lines the Q≤12 modal radiation cannot carry. Two
  cascaded one‑poles at `N_taraf_dir_lp` (the causal twin of the offline
  zero‑phase radiation‑efficiency magnitude), centre‑panned ahead of the
  radiation FIR. **Preset‑carried** (in `sarangi_pilu.json`), deliberately NOT
  in `sarangi_coupled.json` — the upstream bow tables read that artifact's
  `N_taraf_dir` and must not inherit this ear pick.
- **The radiation FIR** — shipped inside `sarangi_coupled.json` at **both
  rates**: `N_rfir` (44.1 kHz — what Starpad's engine uses) and `N_rfir_48k`;
  `CoupledConfig.rfirTaps(sr:)` picks by rate. There are **no Starpad‑side FIR
  bakes** any more. Followed by the fitted **`E_lp`** radiation low‑pass.
- **Drone** (`DroneGen`, `mix_drone` + `D_*`): the sustained tonic/4 laraj bed,
  injected into the bridge force. The v57/Pilu fit ships **`mix_drone` = 0**
  (session ground truth: no drone); the block stays playable live.
- **Room** (`Reverb.processMono`, `F_rt60`/`F_mix`/`F_predelay`): the v57
  ear‑law is **no reverb** — the ringing taraf IS the room — so the preset
  ships `F_mix` = 0; the slider stays for taste.
- **Output user EQ** (`VoiceEQBand`, on `InstrumentState.eqBands`): applied at
  the output. **Default FLAT** — the fitted W valley superseded the old de‑horn
  cuts (`VoiceEQBand.dehornA`, −3.5/−3.2/−7.5 dB at 540/690/860 Hz, remains
  available as a constant). *(Renamed from upstream `EQBand` — Starpad's FX
  rack already has an `EQBand` type.)*
- **Output**: `gout · main_gain`, then the `softClip` backstop (linear below
  0.9).

**Arming.** The engine **requires the bundled `sarangi_coupled.json`**
(`Presets.coupledConfig()`, `N_junction "passive"` + the two impedance scalars
`N_Z_taraf`/`N_Z_played`). Unarmed (missing/mis‑typed artifact) ⇒
`renderSample` outputs **silence** (`SarangiEngine.isArmed`); hosts should
check `isArmed` at load and surface a configuration error.

On top of the upstream network, Starpad keeps its **2‑stage FX rack** — see
*FX rack* below. Both stages default **OFF**, so the default sound is the
upstream chain exactly.

### Excitation

The chain is driven by the base voice's **audio**, not by note events. On the
audio thread (`AudioEngine`), the `SarangiProcessorAU` effect's
`internalRenderBlock` pulls the summed drive stereo (the model source or dry
SWAM) synchronously, forms the mono drive `x = 0.5·(L+R)` (lifted by
`sarangiDriveGain`), calls `engine.beginBuffer()` once, then
`renderSample(x)` per sample. There is **no `setPlayedNotes`** and no amp
follower — the network rings from whatever the drive contains.

## Sympathetic strings (the Tarab tab, ⌘4)

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
the physical sarangi behaviour. With the model base voice, a tarab rebuild also
re‑arms the source's `SympatheticWeb`/`SourceFMBank` to the same tuning.

**Note:** a re‑sync **replaces the fitted Pilu string table** (see the
string‑table law under *Presets*) — turn auto‑sync off to keep the fit exact.

Editing a string, toggling a choir, picking a **raga** (the *Manual tuning*
fallback — three ship in `RagaTuning.ragas`: E♭ harmonic minor, Bhairav, and
**Pilu**, id 3, the 9‑note mixed/thumri scale `[0,2,3,4,5,7,9,10,11]` with
tonic hint 328.9 Hz), or setting the tonic there flips `autoSyncToScale`
**off** (manual mode, so edits stick); the tab's "Follow the Pitch Pad scale"
switch / "Re-sync" button re-engages it (`AppController.setTarabAutoSync`).
`RagaTuning.buildStrings(intervals:) -> [ResolvedString]` is unchanged in
shape (golden parity); `buildChoirs` / `buildGroupedSpecs` are the
group-tagged builders.

## The model parameters

`ParamSpec.all` (`Model/ParamSpec.swift`) defines every tweakable (**22** since
the v57‑only simplification), with a range, default, group, label, and a
**`structural`** flag. Structural params (filter/comb designs) rebuild the
engine off the audio thread; the rest are **live scalars** the render thread
reads per buffer. Groups:

| Group | Params |
|---|---|
| **Bank** | `B_gain`, `B_t60_scale`*, `B_bright`, `B_lp`*, `B_pol_split`*, `B_pol_gain`*, `B_pol_t60`*, `B_inharm`*, `B_damp`*, `B_spread`, `N_taraf_dir`*, `N_taraf_dir_lp`* |
| **Drone** | `mix_drone`, `D_t60`*, `D_level`*, `D_nharm`*, `D_floor`* |
| **Body** | `E_lp`* |
| **Reverb** | `F_rt60`*, `F_mix`, `F_predelay`* (the model's own room — the FX rack is separate, on `InstrumentState.fx`) |
| **Mix** | `main_gain` |

(`*` = structural.) `gin`/`gout` are non‑grouped input/output gains on
`SarangiParams`. The legacy params — the jawari exciter `C_*`, the
`mix_dry`/`mix_bank`/`mix_jaw` mixes, `sym_gain`, `sym_bow_follow`, `H1`–`H5`,
`B_chorus`, `B_jawari`/`B_jawari_rel`, `B_couple`, `E_body`/`E_low_shelf_*`/
`dry_lp`, `F_width` — are **gone**: none are read by the passive coupled
render (preset JSONs still carrying them load leniently; unknown keys are
ignored).

**`main_gain`** is a playback level at the output mix *only* — the strings are
driven by the raw input computed before it, so it never changes how hard the
network rings.

### Drive level

**`AudioEngine.sarangiDriveGain`** (the **"Drive (source→model)"** slider in
the FX tab's Pre‑drive section) scales the drive into the network. Default
**1×**. With the **model source**, level calibration is inside the preset
instead: `gin = 2.6` lifts the synth level to the fit reference, and
`gout = 0.45` leaves headroom so the soft‑clip backstop
(`SarangiEngine.softClip`, linear below 0.9) never engages at fitted levels.
With a SWAM base voice, raise the drive for presence (in‑app SWAM is far
quieter than the fit reference).

## FX rack (the FX tab, ⌘5)

Starpad's **FX rack** (`FXRack`) has **two stages** since the v57 re‑vendor —
the passive coupled network has ONE output stream, so the old per‑voice
Violin/Sym stages had nothing separate to process and were removed:

1. **`violinPre`** ("Pre‑drive (voice → network)") processes the drive
   *before* it excites the bridge / taraf web (mono→stereo collapsed to mid;
   **OFF → exact passthrough**).
2. **`global`** applies to the network's stereo output in **mid/side** (the
   side is re‑injected around the processed mid, so **OFF → exact
   passthrough**).

Each stage = **low‑pass** (cutoff + resonance) → **variable‑length graphical
EQ** → **reverb** (mix + width). DSP `VoiceFX` (`SarangiKit/DSP/VoiceFX.swift`);
params `EQBand` / `VoiceFXParams` / `FXRack` (`Model/VoiceFXParams.swift`),
stored on `InstrumentState.fx` (tolerant decode — a document missing a stage
loads it OFF). **Defaults: BOTH stages OFF** (the fitted v57 chain is the
sound — "the ringing taraf is the room"). `SarangiStore.persistKey` is **v7**.

**Graphical EQ.** An editable list of `EQBand`s — each
`{ id, freq, gainDB, q, type, enabled }`, `type` ∈ `peaking` / `lowShelf` /
`highShelf` / `highPass` / `lowPass` (0…12; default 3 flat peaking bands). Bands
map to biquads via the shared **`Biquad.forBand(_:sr:)`** /
**`Biquad.stageLowpass`** — the SAME designs the UI draws
(`Biquad.magnitude(atHz:sr:)`), so the curve is the exact running response.
Edited with `GraphicalEQView` (drag = freq+gain, ⌘ = lock freq, scroll = Q,
click empty = add, right‑click = remove, double‑click = zero, header
type‑picker), the stage low‑pass as the right‑edge node, a **live pre/post
spectrum** behind the curve (`SarangiEngine` writes two pre‑EQ rings —
`fxRingLength` = 4096; the input ring doubles as the Harmonics tab's
played‑note window — snapshotted via `fxSpectrumRawSnapshot()` →
`FXSpectrumSnapshot` with `violinPre` + `global` rings).

**Live vs structural** (`SarangiStore.FXUpdate`). Enable + reverb mix/width are
**live scalars** (`applySarangiFXScalars`); filter (cutoff/resonance) + EQ bands
are **live filter** — in‑place biquad coefficient swaps
(`applySarangiFXFilters` → `SarangiEngine.setVoiceFXFilters` →
`VoiceFX.updateFilters`, click‑free); only **reverb rt60** is structural.

**Audition.** `voiceParam` paths:
`sarangi.fx.<violinPre|global>.<enabled|reverbMix|reverbWidth|reverbRT60|filterCutoff|filterResonance>`
and `sarangi.fx.<stage>.eq<N>.<freq|gainDB|q>`
(parsed in `SarangiStore.setAuditionParam` / `setFXAudition`).

## Presets & resources

**One fitted preset** ships as a `SarangiKit` resource, loaded via `Presets`:

- **sarangi_pilu** — *Sarangi — v57 (Pilu, fitted)* — the v57 Pilu‑session
  fit and the first‑launch default. Raga **Pilu** (id 3, the 9‑note thumri
  scale), Sa = 328.9 Hz, live gains `gin 2.6` / `gout 0.45`, flat output EQ,
  `F_mix` 0 / `mix_drone` 0, taraf direct tap `N_taraf_dir` 0.02 @ 900 Hz.
  Pair with the **Sarangi (model)** base voice.

The additive‑era presets (`pair1`/`pair2`/`sarangi_eb`/`sarangi_d`) were
removed with the legacy render paths.

**The string‑table law.** The preset ships the **exact offline string table**
(`sarangi_pilu_strings.json`, 39 strings): the offline detunes are
PCG64‑seeded while `StringSpec.bank` uses the Swift RNG — the tables differ
~5 cents rms *per string*, which moves every taraf resonance relative to the
voice's harmonics (measured upstream: a −3.7 dB 125–250 Hz lean + audibly
weaker ring vs the offline render; the exact table closed it to −0.5 dB). A
live twin of a fitted bank must **load** the fitted table, never regenerate
it. (Starpad's tarab auto‑sync REPLACES this table when the Pitch Pad scale
differs — turn auto‑sync off to keep the fit exact.) Rows are tagged with
their `StringGroup` positionally using the same choir segmentation
`RagaTuning.buildChoirs` emits (15 chromatic + |ratios|+2 scale + 7 low +
6 upper).

Bundled resources: `sarangi_pilu.json` (params) · `sarangi_pilu_strings.json`
(the exact table) · **`sarangi_coupled.json`** (the coupled network config —
modes/residues, junction impedances, radiation FIR at both rates; REQUIRED,
the engine is silent without it) · **`sarangi_model_v57.json`** (the fitted
source model) · **`live_comp.json`** (the live loudness calibration).

With tarab auto‑sync ON (default), a loaded preset's strings are immediately
re‑tuned to the Pitch Pad scale; the preset still supplies the timbre.

## Starpad divergences from upstream

`SarangiKit` is vendored wholesale; the deliberate local differences (re‑apply
these on a re‑vendor):

- **`VoiceEQBand`** — renamed from upstream `EQBand` (Starpad's FX rack owns
  that name).
- **`StringGroup`** `groups` + `freqs` threading through `ResonatorBank.build`
  (choir tags for the Tarab tab + Harmonics display).
- **`CombString.period` / `bufferCopy()`** — display accessors for the
  Harmonics‑tab per‑string DFT.
- The **FX‑rack files** (`DSP/VoiceFX.swift`, `Model/VoiceFXParams.swift`) and
  the MARKED "Starpad" sections in `SarangiEngine` (the 2‑stage FX rack, the
  FX spectrum rings, `bankRawSnapshot`).
- **`BankSnapshot`/`BankAnalyzer`** (`DSP/BankSnapshot.swift`) and
  **`FXSpectrumSnapshot`** (`DSP/FXSpectrumSnapshot.swift`).

## Mac side: state, editor, persistence

- **`SarangiStore`** (`StarpadMac/SarangiStore.swift`) owns the editable
  `InstrumentState`. A param change routes to a **live‑scalar** update
  (`AudioEngine.applySarangiScalars`) or a **debounced structural rebuild**
  (`AudioEngine.rebuildSarangi(params:strings:tonic:fx:eqBands:groups:coupled:)`),
  keyed off `ParamDescriptor.structural`. It parses `sarangi_coupled.json`
  once (`Presets.coupledConfig()`) and passes it to every rebuild — coupled is
  mandatory (the old topology toggle + stability readout are gone). Auto‑saves
  to UserDefaults (`persistKey` **v7** — a stale v6 doc carries params the
  engine no longer reads); export/import `.sarangi` JSON.
- **Setup tab**: the **Base voice** picker (Sarangi model / 4 × SWAM / sitar)
  + the model voice's four axis sliders (expr/press/pos/tilt).
- **Sarangi tab (⌘3)** (`SarangiEditorView`): the preset + the grouped
  param sliders (Bank/Drone/Body/Reverb/Mix) + master output (`gout`).
- **Tarab tab (⌘4)** (`TarabView`): the sympathetic strings + scale sync.
- **FX tab (⌘5)** (`FXView`): the 2‑stage FX rack + **Drive (source→model)**.

## Audio graph

`AudioEngine` (`Packages/StarpadCore/Sources/StarpadCore/AudioEngine.swift`):

```
Sarangi model source (48 kHz) ─┐  (OR N × SWAM (dry), OR voiceSitar in-block)
                               ▼
                      hostedDriveTap → SarangiProcessorAU → symGain ────────► mainMixerNode → output
                        (sums, SRC)     beginBuffer() + renderSample(x)              ▲
                                        (coupled network + FX rack inside)           │
   tanpuraSource → tanpuraGain ────────────────┐                                     │
   sitarSource   → sitarGain   ────────────────┤                                     │
                       preReverbMixer → masterFilter → reverb → postReverbEQ ────────┘
```

The chain is rendered **inline** by `SarangiProcessorAU` — a custom in‑process
AUv3 effect spliced after `hostedDriveTap` — so it adds **~0 ms latency**. The
model source is an `AVAudioSourceNode` at the model's native 48 kHz; the drive
mixer's input converter resamples to the engine's 44.1 kHz. MIDI reaches it via
`AudioEngine.sendHostedMIDI` → `routeSarangiModelMIDI` →
`SarangiModelVoiceControl` (the same path that would feed SWAM). The chain goes
`symGain → mainMixerNode` **directly, bypassing Starpad's master FX** (the
master chain is the tanpura/sitar room only). The now‑dangling
`hostedInstrumentGain` / `hostedMakeupGain` / `sarangiMixer` / `violaBodyEQ`
nodes stay **attached but disconnected** so their property setters remain valid.

## Harmonic display (the Harmonics tab)

The **Harmonics tab** (⌘2) draws a live **harmonic heatmap** of the sarangi voice —
the sympathetic strings ringing in and out of resonance as the played pitch
slides (see [UI layout — Harmonics tab](ui-layout.md#harmonics-tab-2)).
The data path is cheap and lock-light:

- Each `CombString` exposes its delay ring (`period` + `bufferCopy()` — the most
  recent one‑period window, time‑ordered; the web form's true period also has a
  fractional part, display‑only approximation). A DFT at integer bins k=1…K
  yields the string's per‑harmonic amplitudes directly — **no audio-thread FFT**.
- `ResonatorBank` carries a `groups: [StringGroup]` array parallel to its
  voices (expanded in lockstep with the polarization doubling) for the
  choir grouping. `bankRawSnapshot()` reports each string's
  `outWeight = choirGain · relOverSqrtN` (the same weight the junction uses).
- The **FX input ring** (the recent drive, 4096 samples ≈ 93 ms) doubles as
  the **Played note** column's window; `bankRawSnapshot()` copies buffers + meta under the
  lock, and the DFT runs off‑lock in `BankAnalyzer.analyze`
  (`DSP/BankSnapshot.swift`). The view polls at ~30 Hz.

Display-only and pre-FX. Verified by `BankAnalyzerTests` and
`EngineTests.testBankSnapshotAndAnalyze`.

## Tests

`Packages/SarangiKit/Tests/SarangiKitTests/` (45 tests): DSP parity against
Python goldens (`Biquad`, `Resonator`, `CombString` — legacy and web+damp
forms, `ResonatorBank`, `FIRFilter`), **`CoupledParityTests`**
(`testPassiveJunctionParity` — the passive junction vs the upstream
`coupled_passive.json` golden), **`CoupledTapTests`** (the taraf direct tap:
identity when off, centred ring, LP magnitude), **`ViolinParityTests`** (the
ViolinSynth harmonic path vs Python at float64), engine tests
(`testBundledArtifactArms`, `testUnarmedIsSilent`, `testPiluPresetLoads`,
`testBankRings`, `testStereoSpread` — pan image + sum invariance,
`testStability`, `testAllFXStable`, `testVoiceFXBypass`,
`testDisabledFXIsExactPassthrough`, `testPreDriveShapesExcitation`,
`testBankCount`, `testBankSnapshotAndAnalyze`), the harmonic-display
`BankAnalyzerTests`, `VoiceFXTests`, and model tests (`buildStrings` parity,
the 22‑param spec, fitted‑model load regression, voice‑EQ python schema
round‑trip, voice‑mechanism smoke). Run with
`cd Packages/SarangiKit && swift test`.

## Calibration notes

- **Sample rates.** The chain runs at Starpad's `Config.sampleRate = 44100` and
  every rate‑dependent design (combs, body sections, drone, room, `E_lp`) is
  parametric in `sr`. The **radiation FIR** ships inside `sarangi_coupled.json`
  at both rates (`N_rfir` 44.1 kHz / `N_rfir_48k`), picked by
  `rfirTaps(sr:)` — no Starpad‑side bakes. The **source model** is the
  exception: `sarangi_model_v57.json` is a 48 kHz fit, so `ViolinSynth` runs at
  48 kHz in its own source node and the drive mixer resamples — pitch‑exact,
  parity preserved.
- The fitted preset's `gin 2.6` lands the model source at the fit's reference
  level; with SWAM, `sarangiDriveGain` is the trim. Tune by ear.
