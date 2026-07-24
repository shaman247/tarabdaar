# Sarangi — the played voice

> **2026‑07‑24 SWAM strip — read this first.** The **String voice is now the
> ONLY voice.** The SWAM / hosted‑AU host, the base‑voice picker
> (`BaseVoice`/`SwamInstrument`), the coupled bridge–body network
> (`SarangiProcessorAU`, `SarangiEngine.renderSample`), the FX rack + FX tab,
> the 25 network params, the body/viola EQ, and the master reverb/filter are
> all **deleted from Starpad**. `SarangiEngine`, `Violin/`, and
> `sarangi_model_v57.json` stay vendored in SarangiKit for **upstream parity
> tests only** — Starpad's `AudioEngine` never instantiates them. The Mac
> tabs are Live ⌘1 · Sarangi (String physics) ⌘2 · Tarab ⌘2 · Fret Pad ⌘3 ·
> Controls ⌘4 · Setup ⌘6. **Sections below that describe the coupled network,
> the source model as a "base voice", the FX tab, or SWAM are historical /
> describe vendored‑but‑unused code — the String voice (below) is what plays.**

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
  ~24% cheaper). **2026‑07‑23 warmth knobs** (Starpad‑local; every default =
  the previously hardcoded value, so untouched artifacts sound byte‑identical):
  `bow_jt_hcb` (contact hysteresis damping, legacy 8 — more = rounder buzz
  pulses), `bow_jt_fhf` (the per‑mode f² damping‑law corner, legacy 4000 Hz —
  lower = the top decays faster = warmer), `bow_jt_bst` (stiffness
  inharmonicity, legacy 2e‑4 — lower = more harmonic top, less bell‑metallic;
  all three are builder‑side, `buildJawariTables`), and `bow_jt_lp` (one‑pole
  low‑pass on the radiated jt sum only, ≥ 20 kHz = bypass — the ONE kernel
  divergence: state + `bow_jt_set_lp`/`bow_poly_jt_set_lp` setters outside
  the load ABI, so the python‑parity `bow_*_jt_test` entries and every golden
  stay bit‑exact; mirrors the coupled network's `N_jaw_lp` 6 kHz precedent).
  All four are rows in the Parameters tab's "Jawari taraf" group / audition
  `string.<key>`; a re‑vendor from `~/Desktop/sarangi` must re‑apply them
  unless landed upstream,
- **runtime parameters (2026‑07‑23/24; composite rework, then the
  2026‑07‑24 unification)** — four RUNTIME playing controls (no rebuild),
  reached now as ordinary `ParamRegistry` entries: `bow_jt_lp`,
  `bow_jt_damp`, `bow_tone_tilt` are `.live`, and the jawari‑buzz scaler is
  the live half of the `.hybrid` parameter `bow_taraf_jawari` (it is NOT a
  parameter of its own any more — the old `bow_jaw_gain` row was exactly
  this scaler, duplicating the build scalar under a second name). Path:
  composite or direct tilt binding → `AppController.applyParamToVoice` →
  `AudioEngine.setStringControlParam` / `setStringHybridScaler` →
  `setStringJawGain`/`setStringJtToneLp`/`setStringTarafDamp`/
  `setStringToneTilt` → `StringVoiceSource` (stores, re‑applies on every
  engine rebuild in `setEngine`) → `BowEngine` chunk‑rate smoothers;
  audition `voiceParam`s `stringPurity`/`stringTarafDecay`/`stringToneTilt`
  drive the default composites, `composite1..8` the slots directly). The
  shipped composite defaults reproduce the former hardcoded axes:
  1. **Taraf purity** (CC71: 0 = the fitted buzzy jawari, 127 = clean
     ring) — TWO mechanisms (final form, 2026‑07‑23 night; two earlier
     cuts documented for the record below): (a)
     `bow_[poly_]set_jaw_gain` scales the formula‑taraf web's buzz
     sources (`jn` in‑loop contact/fold, `jw` output‑tap grazing —
     where the audible jangle lives) linearly to zero across the
     throw — the `jl` in‑loop LOSS deliberately stays full (it
     self‑limits hot rings; un‑damping it made half‑purity buzz HARDER
     than base). (b) the modal‑jt buzz brightness fades through the
     radiated‑jt **tone‑LP corner sweep** (build corner → 
     `bow_tilt_pure_lp` 1500 Hz, log in p; `bow_[poly_]jt_set_lp` is
     runtime‑safe since this rework: state preserved on coefficient
     moves + warm‑tracked bypass, both kernels incl. the stereo side
     state `jtLpYS`). Measured (bowed note): hi‑band buzz falls
     MONOTONICALLY −24 → −34.5 dB over the full throw, RMS eases
     0.120 → 0.100 — no loudness bloom, no tuning change.
     **The jt bones NEVER move at runtime.** Cut 1 (bone lift over the
     whole throw) read as loudness/fullness, not purity — the jangle
     is in the web. Cut 2 (lift deferred to the top quarter) still
     STRUMMED: releasing the static‑wrap energy of every row at once
     is an unavoidable "strummed modal jawari" transient (measured
     2.4× ring peaks through a lift sweep — smoothing cannot fix a
     physical energy release), a partially lifted bone buzzes HARDER
     than the fitted wrap (opened‑jawari regime, +17 dB), and full
     lift detuned the rows ~15 c. `bow_[poly_]jt_set_lift` +
     `bow_tilt_pure_lift` remain in the kernel for offline
     sound‑design use only.
  2. **Taraf decay** (CC73: 0 = natural ring, 127 = choked):
     `bow_[poly_]jt_set_damp_t60` — per‑tick momentum damping in the jt
     tick (static wrap untouched), amplitude t60 log‑interpolated
     `bow_tilt_damp_max_t60` 20 s → `bow_tilt_damp_min_t60` 0.25 s
     (axis 0 = off). All kernel axes are plain scalar writes (the
     drone‑setter contract) — kernel divergences beside `bow_jt_lp`;
     unused they are byte‑null (goldens and python‑parity untouched,
     82/82 green). **Click‑free by construction (2026‑07‑23 night):**
     `BowEngine.updateTarafAxes` smooths purity/decay at chunk rate
     (~40 ms) on the render thread and pushes the kernel scalars only
     when they move (the tone‑tilt pattern). **Settle pre‑roll (same
     night):** a fresh kernel's jt web relaxes off the builder's q0
     with an audible ~200 ms jawari chime (measured idle peak ~0.004 ≈
     −37 dBFS) — every UI‑edit rebuild "strummed" on publish, and
     debounced rebuilds landing near the first note read as onset
     clicks. `StringVoiceSource.buildEngine` now renders and discards
     ~0.5 s off‑main before returning (chime −26 dB, below the tail
     floor; also primes the async‑jt FIFO). Deliberately NOT in
     `BowEngine.init` — parity fixtures need renders from t = 0.
  3. **Tone tilt** (CC72: 0 = bass bias, 64 = flat, 127 = treble bias):
     a complementary low/high shelf pair (∓/± `bow_tilt_eq_db` 9 dB at
     `bow_tilt_eq_lo` 300 Hz / `bow_tilt_eq_hi` 2400 Hz) over the whole
     voice in `BowEngine.postChain` AND `postChainStereo` (the stereo
     side path runs side twins of the shelves — same coefficients,
     independent state; EQing mid and side identically = EQing L/R, so
     the image never narrows), pre‑room so the wet follows; target
     smoothed ~50 ms on the render thread with in‑place coefficient
     swaps (click‑free); flat = exact bypass.
  All six range keys are bp scalars, overridable via `string.<key>`.
  Verified offline (drone‑row harness 2026‑07‑23): purity 1 → mid‑band
  +17 dB ring, 2.8× tail; damp 1 → post‑release tail RMS 0.014 → 0.0002;
  EQ ±1 → ~±13 dB complementary band tilt. A re‑vendor must re‑apply the
  kernel + BowEngine sections,
- an **analytic Schelleng press envelope** (wedge‑relative force mapping),
  place‑then‑draw articulation with attack bite, aftertouch vibrato, and
  **self‑calibrated intonation** (two‑stage pitch‑correction tables),
- **polyphony as physics**: `bow_live_poly 8` gut strings on ONE shared
  bridge (delay‑free junction) — chords are extra strings, a single line is
  mono meend on one string (9 Hz glide smoother).

The whole instrument — played strings + taraf + body + radiation + room — is
the kernel; it needs ONLY **`bowed_string.json`** and renders **straight to
the mix** (in Starpad: `StringVoiceSource` → `symGain` → `mainMixerNode`).
It **is the only voice** — the base‑voice picker and the SWAM/sitar sources
are deleted.

**What remains of the v57 era in Starpad (vendored, but NOT in the audio
path):** `SarangiEngine.renderSample` — the passive coupled bridge–body
network — is still vendored (upstream keeps it for its offline tools), but
since the 2026‑07‑24 SWAM strip Starpad **never instantiates it** —
`SarangiProcessorAU` and the FX rack / 25 network params / Harmonics rings
that fed it are all deleted. The 2026‑07‑21 re‑vendor brought the network the
upstream **per‑class taraf‑jawari buzz** (`N_jaw_raga`/`N_jaw_chrom`/
`N_jaw_lp`) and the refreshed fitted JSONs (`sarangi_model_v57.json`,
`sarangi_coupled.json`, `sarangi_pilu.json`); these still ship for parity but
color nothing in‑app.

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
- **The parameter list (Parameters tab, ⌘5)** — `ParametersView`
  (`StarpadMac/Views/ParametersView.swift`) over **`ParamRegistry`**
  (`Packages/StarpadCore/…/ParamRegistry.swift`), backed for physics rows by
  **`StringParamStore`** (`StarpadMac/StringParamStore.swift`). Eight
  groups: **Bow stroke · Body (formula modes) · Bow & string · Playing
  ranges · Jawari taraf (modal contact) · Taraf (sympathetic) ·
  Articulation · Radiation & output** — the physics rows are
  `bowed_string.json` scalars, applied live via a debounced off‑main
  String‑engine rebuild; the bow/taraf/tone rows apply instantly.
  (Before the 2026‑07‑24 unification this list was a separate **Sarangi
  tab** and the live axes had their own Parameters tab, which is how
  buzz/vibrato/damping ended up with two knobs each.) Starpad cannot rewrite the
  bundled artifact, so edits persist as an **override dict**
  (`starpad.stringOverrides.v1` in UserDefaults) applied over the artifact
  at build time; an override that lands back on the artifact value is
  dropped, so *dirty* means "differs from the Sarangi Live default".
  Double‑click a row label to reset that value; the header's **"Default
  (Sarangi Live)"** button clears everything. Slider ranges are authoring
  hints — an artifact value outside the range widens the slider rather than
  being clamped. (The coupled‑network 25‑param section that used to sit below
  this editor was deleted 2026‑07‑24 — the network no longer runs.)
- **The default preset = the Sarangi Live default.** Fresh installs (and the
  preset menu's **"Default (Sarangi Live) — Pilu, fitted"** entry, via
  `SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`)
  give exactly the upstream default instrument: the untouched
  `bowed_string.json` physics (zero overrides), the EXACT fitted Pilu string
  table, Sa = 328.9 Hz, and — NEW since the String era — **tarab auto‑sync
  starts OFF** so the fitted table sticks (the Tarab tab's "Follow the Pitch
  Pad scale" switch opts back in; `SarangiStore.persistKey` bumped v7→**v8**
  so stale documents don't shadow the new default).
- **What lives elsewhere**: the Tarab tab IS the String voice's taraf tuning;
  room/level live in the physics panel (Radiation & output). The coupled‑network
  params, the FX rack, the output user‑EQ, and the drive gain are all deleted
  (they acted on the removed coupled network).
- **Stereo (2026‑07‑23 immersive rev).** The poly kernel renders a second
  **SIDE stream** (`bow_poly_process2`/`bow_poly_set_stereo`,
  `bow_kernel_poly.c`) carrying only the **direct radiation** — the taraf
  strings' direct tap (through its own copy of the tdir shaping bank), the
  modal‑jawari rows' own radiation (**drone buttons included**), and the
  bow‑contact noise at its string's position. Everything that reaches the
  listener **via the bridge** (played‑string force, driven web resonance)
  radiates from the ONE body — a fixed central radiator — and stays
  mid‑only, so the image is a spread sympathetic halo around a centred
  voice that never leans with the melody. Pans are **per pitch class around
  the tonic** (`spread·sin(2π·pc)`: tonic centre‑stage, svaras at fixed
  symmetric places, octaves share a place — a plain low→high rank map was
  tried and rejected: the ring concentrates in the playing register + the
  low drones and parked the energy centroid 6–10 dB off‑centre). The host
  forms `L = mid + side, R = mid − side`; the side (and the room's
  decorrelated width tank, `Reverb.processMonoStereo`) cancel in L+R, so
  the **mono fold‑down is bit‑identical to the legacy mono output**
  (`BowStereoTests` asserts all three invariants). Scalars — **not in the
  artifact**; seeded by `StringVoiceSource.liveParamSeeds` (also merged
  into `StringParamStore`'s baseline so editor default/reset semantics
  agree): `bow_st_spread` 0.7 (taraf/jt spread) · `bow_st_played` 0.15
  (bow‑noise spread) · `bow_rev_width` 0.6 (room decorrelation). 0 = the
  bit‑exact mono path (also the case for every parity golden — the keys
  are absent from `bowed_string.json`, and the mono kernel / fixture /
  `renderFixture` paths never arm it). Measured (audition `stereo_on5`):
  balance ±0.6 dB while playing, side/mid ≈ 0.26 under melody → ≈ 0.5 on
  the bare halo, L/R coherence 0.91 (lows) → 0.59 (highs).

The sections below describe the **coupled‑network chain** — removed from
Starpad on 2026‑07‑24 (it colored the deleted SWAM / sitar base voices) and
kept in SarangiKit for upstream parity tests only.

## The source model (`Violin/`) — REMOVED from Starpad

Removed 2026‑07‑24 with the SWAM strip. The v57 additive source
(`ViolinModel`/`ViolinSynth`/`ExprEqualizer` + `sarangi_model_v57.json`) and
its base‑voice wiring are gone from Starpad; `Violin/` stays vendored in
SarangiKit for upstream parity tests only. See git history for the full
description.

## The chain — the passive coupled bridge–body network — REMOVED from Starpad; vendored in SarangiKit for parity only

> The coupled network is no longer instantiated by Starpad (the base voices it
> colored are deleted). It remains in SarangiKit for upstream parity tests; the
> physics below document that vendored code, not the Starpad audio path.

`SarangiEngine.renderSample(_ input: Double) -> (Double, Double)`, after
`beginBuffer()` **once per buffer** (pushes the live scalars and recomputes the
junction impedance tables). `input` is one dry source sample; there is **no
`amp` argument** — the network is driven purely by the audio. The
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
L,R = ½(rad ± W(Σ pan_i·f_i)) + taraf tap → radiation FIR → E_lp → room → user EQ
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
  rates**: `N_rfir` (44.1 kHz) and `N_rfir_48k`;
  `CoupledConfig.rfirTaps(sr:)` picks by rate. Followed by the fitted **`E_lp`**
  radiation low‑pass.
- **Drone** (`DroneGen`, `mix_drone` + `D_*`): the sustained tonic/4 laraj bed,
  injected into the bridge force. The v57/Pilu fit ships **`mix_drone` = 0**.
- **Room** (`Reverb.processMono`, `F_rt60`/`F_mix`/`F_predelay`): the v57
  ear‑law is **no reverb** — the ringing taraf IS the room — so the preset
  ships `F_mix` = 0.
- **Output user EQ** (`VoiceEQBand`, on `InstrumentState.eqBands`): applied at
  the output. **Default FLAT** — the fitted W valley superseded the old de‑horn
  cuts. *(Renamed from upstream `EQBand`.)*
- **Output**: `gout · main_gain`, then the `softClip` backstop (linear below
  0.9).

**Arming.** The engine **requires the bundled `sarangi_coupled.json`**
(`Presets.coupledConfig()`, `N_junction "passive"`). Unarmed ⇒ `renderSample`
outputs **silence** (`SarangiEngine.isArmed`).

### Excitation

*(Historical — the coupled network is no longer instantiated in Starpad.)* When
it ran, the chain was driven by the base voice's **audio**, not by note events:
the render block formed a mono drive `x = 0.5·(L+R)`, called `beginBuffer()`
once, then `renderSample(x)` per sample — the network rang from whatever the
drive contained.

## Sympathetic strings (the Tarab tab, ⌘2)

The tarab live in their own **Tarab tab** (`TarabView`), split into the four
physical **choirs** — a `StringSpec` (`Model/StringSpec.swift`) is `freq, gain,
weight, t60, bright, enabled, group`, where `group: StringGroup` is one of
`chromatic / scale / lowOctave / upperOctave`. The editor shows one collapsible
section per choir (count + Enable-all + add + per-string rows). **`weight`**
(the "Wt" column) is a per-string loudness weight in **[0, 1]**, default 1 (=
the fitted/generated level): it multiplies onto `gain` at resolve time
(`StringSpec.resolved`), so it scales the string's level in the String voice's
in-kernel taraf (linear web rows / jt-subset selection) without touching the
fitted `gain` value itself. 0 silences the string while keeping its row.

**Auto‑sync starts OFF** (`autoSyncToScale` false since the String‑era default)
so the fitted Pilu table sticks. When opted in (the tab's "Follow the Pitch Pad
scale" switch), an `AppController` sink on `pitchPad.$scale`/`$tonicMidi` calls
`syncTarabFromScale` → `SarangiStore.syncTarabToScale` →
`InstrumentState.regenerateFromScale(tonicHz:ratios:)`, which rebuilds the
choirs from the tonic Hz + the scale's degree ratios
(`scaleDegrees(from:).map(\.ratio)`) via `RagaTuning.buildGroupedSpecs`. The
chromatic choir stays the fixed 15 JI ratios; the scale / low / upper choirs
follow the degrees, so the strings resonate with the notes you play. The rows
tune the String voice's in‑kernel taraf (linear web + modal‑jawari subset).

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

## The model parameters — REMOVED from Starpad; vendored in SarangiKit for parity only

> These are the coupled‑network's parameters. Since the 2026‑07‑24 SWAM strip
> Starpad has **no UI for them and never applies them** (the Sarangi‑tab 25‑param
> section is deleted). The table documents the vendored physics; the audition
> `sarangi.<paramId>` path now reaches only the tarab table, not these.

`ParamSpec.all` (`Model/ParamSpec.swift`) defines every tweakable, with a range,
default, group, label, and a **`structural`** flag. Groups:

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

**`main_gain`** is a playback level at the output mix *only* (of the coupled
network) — it never changes how hard the network rings.

### Drive level — REMOVED

Removed 2026‑07‑24 with the SWAM strip: `AudioEngine.sarangiDriveGain` (the
"Drive (source→model)" slider) scaled the drive into the coupled network. There
is no drive stage now — the String voice's level lives in its `bow_live_trim` /
`bow_rev_*` scalars. See git history.

## FX rack — REMOVED (the FX tab is deleted)

Removed 2026‑07‑24 with the SWAM strip: the two‑stage FX rack
(`violinPre` pre‑drive + `global` mid/side, each filter + graphical EQ +
reverb), the FX tab (`FXView`/`GraphicalEQView`), the live spectrum
(`SpectrumProvider`/`SpectrumAnalyzer`), and the `sarangi.fx.*` audition paths
are all deleted. `FXRack`/`VoiceFX` stay vendored in SarangiKit but nothing in
Starpad applies them. See git history for the full description.

## Presets & resources

**One fitted preset** ships as a `SarangiKit` resource, loaded via `Presets`:

- **sarangi_pilu** — *Sarangi — v57 (Pilu, fitted)* — the v57 Pilu‑session
  fit and the first‑launch default. Raga **Pilu** (id 3, the 9‑note thumri
  scale), Sa = 328.9 Hz, live gains `gin 2.6` / `gout 0.45`, flat output EQ,
  `F_mix` 0 / `mix_drone` 0, taraf direct tap `N_taraf_dir` 0.02 @ 900 Hz.
  (The `gin`/`gout`/`F_*`/`N_taraf_dir` scalars are coupled‑network fields, now
  inert; the live String voice uses the exact Pilu string table + `bow_*`.)

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
- **Tarab tab (⌘2)** (`TarabView`): the sympathetic strings + optional scale sync.
- **Controls tab (⌘4)** (`TiltControlsView`): the tilt bindings (to a
  composite or straight to a parameter) + the composite parameters.
- **Parameters tab (⌘5)** (`ParametersView`): every parameter of the
  instrument + the preset toolbar / "Default (Sarangi Live)" reset.

## Starpad-local divergences from upstream SarangiKit

`SarangiKit` is vendored wholesale from `~/Desktop/sarangi`, so a re-vendor
**overwrites these**. Re-apply them, or the listed capability silently
disappears (the code still compiles — that is what makes this dangerous).

| Divergence | Where | What is lost without it |
|---|---|---|
| MPE per-channel bend (`chBend`, slot `ch`, CC75 tilt) | `Bow/BowControls.swift` | per-finger pitch bend |
| jt warmth knobs `bow_jt_hcb` / `_fhf` / `_bst` | `BowTables.buildJawariTables` | those three parameters (defaults = legacy) |
| `bow_[poly_]jt_set_lp` | both kernels | the live jawari tone LP |
| Tilt axes `bow_[poly_]jt_set_lift` / `_set_damp_t60` / `bow_[poly_]set_jaw_gain` + the `updateTarafAxes` smoother and the shelf-pair tilt EQ in `postChain`/`postChainStereo` | both kernels + `BowEngine` | taraf purity / decay / tone tilt |
| **`bow_[poly_]set_scalars`** | both kernels | every `.live`/scalar parameter falls back to a 218 ms rebuild |
| **`bow_[poly_]set_body`, `bow_[poly_]jt_set_coeffs`** | both kernels | the body bank + jawari tables fall back to a rebuild |
| **`BowControlFilter` `let`→`var` + `updateLiveParams(bp:)`** | `Bow/BowControls.swift` | playing ranges / articulation / vibrato stop being live |
| **`setLiveParams` / `applyPendingLive` / `reloadCoefficients`, the live-ramp state, the 256-frame render chunk cap** | `BowEngine` | the in-place path, and the zipper ramp with it |
| **Per-sample `outGain` interpolation (`gainPrev`)** | `postChain` + `postChainStereo` | a large gain jump clicks (measured 17.9× the signal's own motion) |
| **`Biquad.copyCoefficients(from:)`** | `DSP/Biquad.swift` | radiation filters can't retune without resetting state |
| Stereo side path (pitch-class pans) | `bow_kernel_poly.c` | the stereo image |
| `VoiceEQBand` rename, `StringGroup` threading, `CombString.period`, FX-rack files, marked `SarangiEngine` sections | model + `SarangiEngine` | compile errors / parity-test scaffolding |

None of the new C entry points is called by any parity fixture, so the
goldens stay bit-exact with them present.

## Audio graph

`AudioEngine` (`Packages/StarpadCore/Sources/StarpadCore/AudioEngine.swift`) — one path:

```
MPE in ► routeSarangiModelMIDI ► StringVoiceSource ► symGain ► mainMixerNode ► output
                                  (BowEngine + CBowKernel, 96 kHz → 48 kHz)
```

The played voice is `StringVoiceSource`, an `AVAudioSourceNode` at the kernel's
native 48 kHz (the mixer input converts to the engine's 44.1 kHz), connected
**directly** to `symGain → mainMixerNode`. The kernel is the whole instrument,
so there is no coupled-network effect, no drive tap, and no master FX bus. MIDI
reaches it via `AudioEngine.sendHostedMIDI` → `routeSarangiModelMIDI` →
`BowControlMapper`.

## Harmonic display

*(The Harmonics tab was removed in the 2026‑07‑23 simplification.)* The
sympathetic strings still ring in and out of resonance as the played pitch
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

- **Sample rates.** The **String voice** kernel runs at 96 kHz internally and
  half‑band‑decimates to 48 kHz (`StringVoiceSource`'s `AVAudioSourceNode`); the
  engine runs at `Config.sampleRate = 44100`, so the mixer input converts the
  48 kHz source. The physics are the byte‑exact twin of the offline C render.
- **Levels** live in the artifact / overrides — `bow_live_trim` and `bow_rev_*`
  set the output level, and the Mac pads hold a flat per‑note CC11 = 32 (the
  fitted expr median). Loud peaks are backstopped inside the kernel.
