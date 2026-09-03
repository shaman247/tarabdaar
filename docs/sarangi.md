# Sarangi — the played voice

The **String voice** is Tarabdaar's default played instrument: a pure‑physics
bowed gut string in **`SarangiKit`** (`Packages/SarangiKit/`) — **`BowEngine`**
(`Bow/BowEngine.swift`) driving the **C friction kernel** (`CBowKernel`,
`bow_kernel_poly.c`, built `-O3` always) at 96 kHz, half‑band‑decimated to
48 kHz. The kernel is the whole instrument — played strings, the two‑bridge
modal‑jawari taraf, the formula body, radiation and room — and needs only
**`bowed_string.json`** (`Resources/`). SarangiKit is Tarabdaar's own code:
the DSP is edited here, and `TarafRemovalParityTests` pins a SHA‑256 of the
shipped render so an accidental edit fails loudly.

The plucked voices are [Tanpura](tanpura-voice.md) and [Sitar](sitar-voice.md);
levels, rebuild cost and in‑place application are in
[Sound Design](sound-design.md); every knob is in [Parameters](parameters.md).
Development history lives in `docs/history/`, not here. Files: `Bow/`
(`BowEngine`, `BowTables`, `BowControls`), `Model/`, `Presets.swift`; Mac side
`TarabdaarCore/StringVoiceSource.swift`, `TarabdaarMac/SarangiStore.swift`,
`StringParamStore.swift`, `Views/StringsView.swift`.

## Signal path

```
touch / MIDI ► BowControlMapper ► bow_live_poly gut strings on ONE bridge (delay‑free junction)
              ► formula body (modal resonators) ► voice bus ─┐
              ► modal‑jawari rows (raga bridge + chromatic bridge, async pool)
                  ► bridge‑force radiation ► per‑row cap ► [body mix] ► tone LP/HP ► taraf bus ─┤
              ► balance · taraf comp · FX rack (fx_*) · room · width · master gain · limiter
              ► StringVoiceSource ► symGain ► mainMixerNode
```

- **Polyphony is physics.** `bow_live_poly` (8) strings share one bridge.
  Every note‑on mounts a fresh string (an unused slot, else the
  longest‑released, else the oldest sounding); note‑off lifts the bow and the
  string rings on at its frozen pitch. Within a note the filter ramps log2 f0
  linearly to the latest wire target each render block, so all meend is the
  finger's own movement at wire rate — no glide shaping, no vibrato LFO.
- **Two buses.** `bow_poly_process3` renders voice and taraf as separate
  mid/side streams; FX rack, balance and bus meter act on
  the split, and the sum is bit‑identical to a single‑bus render.
- **Rates.** Kernel 96 kHz → 48 kHz; `StringVoiceSource` is an
  `AVAudioSourceNode` at 48 kHz, converted by the mixer input to
  `Config.sampleRate` 44.1 kHz. In‑process MIDI arrives via
  `AudioEngine.sendHostedMIDI` → `routeSarangiModelMIDI` ([MIDI & Audio](midi-and-audio.md)).

## The kernel and its host

- **`StringVoiceSource`** pulls `BowEngine.render` under its own lock; engine
  swaps publish under a brief unfair lock and retain the outgoing engine so an
  in‑flight buffer never reads freed memory.
  `buildEngine(tonicHz:strings:mapper:overrides:)` builds tables + kernel +
  jt pool off‑main (tarab TUNING = the enabled strings, taraf PHYSICS = the
  `bow_jt_*` / `bow_jtc_*` keys).
- **Rebuilds.** `AudioEngine.rebuildSarangi(strings:tonic:)` handles every
  structural change (tarab edit, tonic move, scale push): built on a serial
  queue, generation‑checked, crossfaded in; the mapper keeps held notes and
  axes. **Settle pre‑roll:** a fresh web relaxes off its initial state with a
  jawari chime, so `buildEngine` chokes the taraf (`setJtSettleDamp` t60
  50 ms), renders and discards `settleBlocks` (5 × 4096 frames) and restores
  the natural ring byte‑exactly before publishing — publish peak ≈ −87 dBFS
  under the −80 dBFS bar `RebuildCostTests` holds. Not in `BowEngine.init`:
  parity renders start at t = 0.
- **In‑place push.** A `.live`/`.hybrid` edit recomputes the kernel's scalar
  vector and hands it to `BowEngine.setLiveParams` — no reset, no pre‑roll,
  no crossfade (`inPlaceKeys`; see [Sound Design](sound-design.md)).
- **Overrides.** The bundled artifact is read‑only; Parameters‑tab edits
  persist as an override dict (`tarabdaar.stringOverrides.v1`,
  `StringParamStore`) applied over `bowed_string.json` at build time; one that
  lands on the artifact value is dropped (*dirty* = differs from default).
  Audition path `string.<key>`. Registry defaults for keys the artifact does
  not carry must equal the engine fallbacks (`ParamUnificationTests`).
- **Controls — `BowControlMapper`**, long‑lived across rebuilds: CC11
  expression · CC1 press · CC74 position · CC2/75 tilt · aftertouch · CC120/123
  all‑off; slots keyed `.touch` (wire) and `.midi` (in‑process) under identical
  laws (`TouchMapperTests`). The Mac pads hold CC11 = 32 (the fitted
  expression median).
- **Telemetry.** `StringVoiceSource.jtStats()` (async‑web dropped‑job /
  flat‑fill counters) and `renderStats()` (callbacks timed against 90 % of
  budget — a LATE callback glitches at the device while an audition tap
  records a clean WAV); `AppController`'s 5 s watchdog logs "jt OVERLOAD" /
  "render OVERRUN" when they grow. Check these first for clicking.
- **Scope (⌘8) and Taraf (⌘9) tabs** draw display‑only kernel meters:
  `bow_poly_scope_arm` turns on, per jt row, a peak envelope of its radiated
  (post‑cap) sample and per‑mode peak envelopes of the first 16 modes' |p_k|
  (worker‑owned, telemetry‑grade racy reads); `bow_poly_scope_jt` reads them
  with the row's current f0 and asleep flag, `bow_poly_scope_slots` each
  played string's ring envelope. Armed only while a tab shows; the armed
  render is byte‑identical. Drawing: [UI Layout](ui-layout.md).

## Articulation and sustain

- **Attack sharpness has two drives:** the press law (onset press above
  `bow_attack_thresh`; the pads hold press ≈ 0.56, so a lower threshold
  sharpens every onset) and the onset strike velocity (`bow_attack_vel`:
  sharpness = max(press law, key × velocity) — a hard tap gives martelé bite,
  the `bow_draw_min_ms` fast draw and the `bow_attack_fms` velocity‑leads‑force
  ramp). Velocity is the iPad's accelerometer estimate ([Sensors](sensors.md))
  or MIDI velocity; the key's 0 default keeps the press‑only law bit‑exact.
  Articulation acts on fresh attacks only; finger glides never re‑articulate.
- **Liveness layer:** a post‑onset settle (`bow_settle_db`; `bow_settle_sharp`
  exempts a sharp attack, depth × (1 − key × sharpness)), three seeded
  Ornstein–Uhlenbeck walks (`bow_drift_*`) for slow pitch/level/timbre wander,
  and a glide‑rate bow lightening (`bow_glide_dip_db`) that articulates meend.
- **Register damping** (`bow_loss_reg`, shipped 0.7): the nut/bridge/gut loss
  corners scale by (f0/tonic)^γ below the tonic only, so low notes are not
  relatively brighter and hollower than the tonic.
- **Slide realism:** the body's diffuse tail is a 32‑mode formant forest
  (`bow_body_tail_*`, 280–6500 Hz); slide dulling follows finger slew, slide
  noise is acceleration‑driven (scrapes at gesture starts/stops, quiet at
  constant rate); steady notes stay byte‑exact.

## The modal‑jawari taraf

The sympathetic strings are **modal‑contact rows inside the kernel**: each row
is a modal string (up to `bow_jt_mcap` 64 modes) grazing a parabolic jawari
bone, ticked at a divided jt rate (~1.3 ms) on an **async worker pool**
(`bow_jt_threads` 8) one block late, so the audio callback never waits. It is
the instrument's entire radiated sympathetic response.

**Threading contract.** Exactly ONE dispatcher computes the web at a time: the
async dispatcher's `jt_run_job` and `bow_poly_process3`'s offline‑pull
fallback (taken when the web ring underruns — constantly under
faster‑than‑realtime test pulls) share the string states and pool rendezvous
under the `jtDispMx` dispatch‑owner mutex (taken only when a pool exists — the
serial parity path never locks), with a broadcast completion and waits that
break on `jtQuit` so teardown never strands a dispatcher. Live jt setters are
plain scalar writes slewed in the tick (the drone‑setter contract); row state
is worker‑owned, resets lazy.

### Two bridges, two sets

Every `StringSpec` carries a `set`: **raga** strings (scale‑degree pitches on
the `bow_jt_*` bridge — "Jawari taraf (modal contact)") and the **chromatic
set** (15 semitone strings, low Ga … tivra Ma, on its own bridge —
"Chromatic bridge (jawari taraf)"; gain 0.6 / t60 3.0, above the selection's
`bow_jt_gmin` so they sound). A chromatic `degree` is a semitone (0…11) into
the fixed JI chromatic grid (`RagaTuning.chromaticRatio`) off the same tonic —
retuned by a tonic move, deliberately NOT by a scale edit. The chromatic
bridge carries exactly the three knobs that genuinely differ per bank —
**level** (`bow_jtc_gain`), **level norm** (`bow_jtc_norm`) and its own
**evolution axis** (`bow_jtc_evolve`). The contact GEOMETRY (drive, graze
depth, contact zone / bone radius, contact law, contact damping, damping
corner, inharmonicity) is DERIVED from the raga bridge's `bow_jt_*` values,
so the two bridges are one jawari shape; the web‑wide controls (tone LP/HP,
body, damping, cap, recruitment, register tilt) are shared as before.
`BowTables.buildJawariTables(rows:…:chromatic:)` bakes the chromatic level
and norm per row. The chromatic bridge's resting values equal the raga
bridge's
(`BowTables.chromaticBridgeDefaults` == the registry defaults, `TarabSetTests`;
the artifact never carries the keys — DEFAULT = ENGINE TRUTH), so the split
adds strings, not a new sound. Kernel row order: raga selection, chromatic
selection, follower (`StringVoiceSource.jawariRowPlan`, the ONE plan builds and
live reloads share); a pitch on both bridges resolves drone presses to its
raga row. **CPU:** ~9 % of a core per awake row (Pilu = 19 + 15 = 34); the
pool starves past ~40 rows, showing as taraf drop/flatten, not overruns.

### Row selection and the jawari knobs

`jawariRowPlan` applies the selection rule per bridge: playing‑register rows
first, one 60‑cent pitch class each keeping the row nearest the class median,
remaining `bow_jt_max` slots by gain; rows under `bow_jt_gmin` are skipped.
Contact config: `bow_jt_J` 8 with `bow_jt_zone` 0.006 m — the contact lives in
~6 mm around the apex, so the narrow zone concentrates the modes there.
`bow_jt_hcb` (contact hysteresis damping — more = rounder buzz), `bow_jt_fhf`
(the per‑mode f² damping corner — lower = warmer) and `bow_jt_bst` (stiffness
inharmonicity — lower = more harmonic top) are builder‑side. `bow_jt_lp`
(one‑pole LP on the radiated sum, ≥ 20 kHz = bypass) and `bow_jt_hp` (HP after
it, 0 = byte‑null) are kernel scalars, state preserved on coefficient moves.

### Bridge‑force radiation

A row radiates the **contact force it exerts on its bone**: the tick sums the
contact solve's zone force densities × spacing, DC‑blocks it (~8 Hz one‑pole,
primed to the first sample) and scales it per row by `JtTables.rowForceScale`
= gout·π·wj/(mu·L·wd1), so a unit mode‑1 ring maps to the fitted level law.
Every mode radiates flat in those units, so the Taraf tab's modal‑energy
spectrum is also the radiated one. The pulse train carries a large
low‑frequency swing, so `bow_jt_gain` glides ~40 ms inside the kernel
(`jtGainCur`) and so does each row's radiation scale (`jtRadScaleCur`; the
chromatic level rides `bow_jtc_gain / bow_jt_gain` — a stepped scale would
splash impulses ~10× the signal, `ZipperTests`' fast flick), both bit‑null
when constant; an instant bone move radiates a real thump, which the 40 ms
bone slew keeps out of tilt sweeps. The observable is contact‑only — the
linear pin force at the termination is not yet radiated (roadmap 1b), so the
quiet grazing haze under‑radiates (force ∝ η^1.3) and an opened graze reads
~8 dB quieter while its cascade doubles. The 0.90 L velocity pickup is not
present — see `docs/history/`.

### Evolution and register

- **`bow_jt_evolve`** (0…1, `.live`, 0.5 = bit‑exact): the tanpura/sitar
  **twang** is the energy cascade up the partials that runs while the ring
  amplitude GRAZES the bone — a narrow band around the graze knee. The knob
  spans graze margin ×4 … ×¼ around the fitted bone: 1 = ×¼ — the cascade is
  fast (tap‑ring centroid rise 1.2 s → 0.27 s), runs at any drive level and
  rings ~8 dB hotter (trim with `bow_jt_gain`); 0 = ×4 — pressed past the
  knee, harmonics static, slightly choked. A kernel‑slewed SIGNED bone lift
  (`bow_poly_jt_set_evolve`, ~40 ms one‑pole, advanced per jt sample so serial
  and pool replays match) — the ONE runtime bone move, and it GLIDES: a
  stepped lift strums every row's static‑wrap energy at once, a physical
  release no smoothing fixes. Pitch shifts stay ≤ 16 ¢. `BowEngine.setJtEvolve`
  keeps a cumulative 0.005 dead‑band against the last APPLIED value so a bound
  axis's jitter never pumps the bone (which would hold every row awake).
- **`bow_jt_ev_reg`** (−1…1, `.live`, 0 = byte‑null): evolve units per OCTAVE
  from the tonic, evaluated per row on the same margin map
  (e_row = clamp(e + reg·log2(tonic/f_row), 0, 1), offset = lift(e_row) −
  lift(e), so every row stays on the calibrated span) and pushed as per‑row
  bone offsets added to the global lift (`bow_poly_jt_set_evolve_ofs`,
  row‑slewed ~40 ms; a sleeping row wakes on a material move of its own
  target). Positive opens the below‑tonic anchors toward the cascading band
  (the low‑string drone bloom on demand) while pressing the above‑tonic web
  closed, so the bloom comes without web‑wide buzz; negative reverses it.
  Evolve × register is a 2‑D jawari surface, both tilt‑bindable.
  `bow_jtc_evolve` rides the same path, each chromatic row evaluating the map
  on the shared apex minus the raga bridge's lift
  (`BowEngine.pushJtEvolveOffsets`).
- **Body mix** `bow_jt_body` (0…1, `.live`, 0 = byte‑exact) blends the
  radiated jt sum through the SAME formula‑body radiation bank the played
  strings use, before the tone LP/HP (`bow_poly_jt_set_body`, slewed ~30 ms)
  — otherwise only the melody carries the body formants and the taraf reads
  as a separate chorus.

### Recruitment (`bow_jt_sel`)

Sweeps each row's CONTRIBUTION at held loudness. **0.5 = the fitted taraf**
(all weights 1, bit‑exact): unison rows dominate, octaves a few dB down,
fifths faint, unrelated rows only haze. **Below:** per‑row bridge‑drive
weights — the render thread scores every row's harmonic kinship to the gated
pitches (kin lattice: unison 1, octaves/twelfth/fifth/fourth fading as
(p·q)^−`bow_jt_sel_kin` [0.7, shared with the drone spread], Gaussian cents
corridor `bow_jt_sel_width` [30 ¢]; squared at the endpoint) and pushes them
via `bow_poly_jt_drive_weights`; the tick slews each row ~30 ms and scales its
incoming bridge force. **Above:** the profile flattens — resonant rows are
CUT toward the common haze level (w → √(haze/(haze+kin²)); cuts, because
extra drive is drained by the graze contact) until at 1 every row contributes
equally, independent of the played note. **Loudness compensation:**
`BowEngine.recruitGainMul` (an incoherent power sum over the kin scores plus a
per‑row haze floor `recruitHazeFloor` 0.05, blending above 0.5 to one common
level rows·haze + `recruitKinNominal` 1.75, capped ×`bow_jt_sel_comp` [4])
drives `bow_poly_jt_set_gain_mul`. The follower and held‑drone rows count as
fully ringing (drone noise adds AFTER the weight — a held drone is never
pumped or ducked); chords combine soft‑OR; with no gated note the last weights
hold. With the chromatic set mounted every semitone has a unison row, so
kin‑only still rings it. The **Taraf purity** composite sweeps 0.5 → 0 (1
would park the instrument on the note‑independent flat wash).

### The quiescence gate (`bow_jt_gate`)

The web is a constant‑cost simulation — every row ticks its whole mode stack
whether ringing or silent (~350 % CPU idle without the gate). `bow_jt_gate` is
a **bp scalar, not a registry parameter**, always on at **40 dB** below the
graze apex (`bow_poly_jt_set_gate`; a 0 override in tests/auditions is the
raw‑physics escape hatch). A row whose peak LOW‑mode momentum rests below the
floor (10^(−gate/20) × apex × mode‑1 rate) for ~30 ms of consecutive ticks,
with no bridge drive above its wake bound and no drone drive, sleeps **in
place**: its state is FROZEN, never zeroed — `jtQ` holds the settled static
wrap; zeroing it would strum the re‑settle on wake — and the tick is skipped
(output truncates to exact 0). Only the low modes (first ≤ 6) can meter
quiescence: the wrap is a tick‑rate micro limit‑cycle against the bone, so
contact‑zone velocity (~0.6) and the raw radiated sample (~5e‑3) sit on
standing baselines while the audible ring lives in the first modes, 3+
decades lower. 40 dB because a bone pressed past the knee (evolve → 0)
sustains a low‑mode limit cycle ~3–7× above a 60 dB floor, so deeper floors
never close on pressed rigs. Wake: bridge drive above the per‑row bound or
ANY drone drive resumes the frozen state instantly, so the first note of a
phrase meets a live taraf; a MATERIAL bone move (2 % of jtDeep) wakes
everyone. Held drones never sleep. `bow_poly_jt_gate_asleep` counts sleepers.

### The voice‑relative cap (`bow_jt_cap*`)

The runaway‑bloom lever: at high evolve the web feeds itself past the voice.
`bow_jt_cap` (hardness 0…1, 0 = byte‑null, 1 = a hard relative limiter) holds
the taraf at or below `bow_jt_cap_ratio` × the voice bus's own decaying peak
(~1.2 s‑τ ceiling release — the taraf may decay more slowly but never peak
above the voice). It runs **per string inside the jt tick**
(`bow_poly_jt_set_cap`): the voice envelope is recorded beside the jt drive,
each row runs its own 150 ms peak envelope + gain (3 ms attack, 120 ms
recovery) on its radiated output, and the strings sum after the cap — one
blooming anchor is held without ducking its neighbours. A pure output gain —
physics and gate untouched.
**Threading law:** per‑row envelope state is worker‑owned and reset lazily by
generation — **never zero row arrays from the control thread** while the pool
may be ticking.

### Damping, balance, norm

- **Taraf decay** (`bow_jt_damp`, `bow_poly_jt_set_damp_t60`): per‑tick
  momentum damping (static wrap untouched), t60 log‑interpolated
  `bow_tilt_damp_max_t60` 20 s → `bow_tilt_damp_min_t60` 0.25 s (0 = off). A
  bound Taraf Decay tilt overrides the slider.
- **`bow_bal`**: voice↔taraf balance as a pure attenuator pair (−1 … +1,
  0 = byte‑null). **`bow_jt_norm`** evens kin‑note hot spots at the cause
  (long‑ring anchors charge hotter; 0.6 ≈ even).

### The melody follower

One special row sits pinned above the raga pool: its pitch is not a scale
degree — it **live‑retunes to the highest note being played** (glides
included). Same Gain / t60 / On as any row; no octave, no Hz, not a drone
target. **Default off** — disabled it adds no row and the render is
byte‑identical. Built at tonic/2 (generous mode allocation), appended after
both bridge selections, retuned in place by the kernel
(`bow_poly_jt_track_config` / `_target`): the render thread pushes the highest
gated slot's `f0Target` once per chunk, the row's tick slews toward it
(~15 ms) and rewrites only the f0‑dependent mode tables — mode shapes, bone
profile and radiation scale never move (retune‑by‑tension); the active mode
count trims to the builder's 18 kHz corner as the pitch rises (an
under‑resolved contact mode limit‑cycles into static). With no note held the
target stays put, so the string rings out where the melody left it.

### Drone excitation

The three Fret Pad drone buttons pluck **mapped tarab rows** — no
drone‑specific pitch, gain or t60 (`InstrumentState.droneStringIds`, 3 ×
optional `StringSpec.id`; nil = inert). The kernel drive is a pitched
(sine‑at‑mode‑1) kin‑spread drive plus a pluck boost — pure noise rings the
high modes as loud as the fundamental and no LP fixes it; level → ring is
superlinear past ~0.008. A press is an identity lookup on the row's nominal
Hz (`BowEngine.droneRow(forExactHz:)`); a disabled or unselected row is
silent; mapping changes never rebuild. **Auto‑mapping** (fresh documents +
every regeneration): per slot the highest‑gain enabled raga string within
±100 ¢ of low Sa / low Pa / Sa. The plucked voices charge the web through the
**inject ring** (`bow_poly_jt_inject_write` / `_gain`; `st_taraf` /
`tp_taraf`; byte‑null when unused) — see [Sitar](sitar-voice.md).
`DroneStringTests` pins that builds and live reloads pick the same rows.

## Runtime axes and composites

The shipped composites (Controls tab) reproduce three playing axes; their
range keys are bp scalars (`string.<key>`). Path: binding →
`AppController.applyParamToVoice` → `AudioEngine` → `StringVoiceSource`
(re‑applied on every `setEngine`) → `BowEngine` chunk‑rate smoothers (~40 ms).

1. **Taraf purity** (CC71): the radiated‑jt tone‑LP corner sweeps from the
   build corner to `bow_tilt_pure_lp` 1500 Hz (hi‑band buzz falls ~10 dB, no
   loudness bloom) and `bow_jt_sel` sweeps 0.5 → 0. The bones never move.
2. **Taraf decay** (CC73): `bow_jt_damp`, natural ring → choked.
3. **Tone tilt** (CC72, `bow_tone_tilt`): a complementary low/high shelf pair
   (∓/± `bow_tilt_eq_db` 9 dB at `bow_tilt_eq_lo` 300 Hz / `bow_tilt_eq_hi`
   2400 Hz) over the whole voice, mid and side alike (so the image never
   narrows), pre‑room; smoothed ~50 ms with in‑place coefficient swaps; flat
   = exact bypass.

## Output stage

- **Instrument width** (`bow_st_width`, shipped 0.2,
  `bow_poly_set_stereo_width`): one small instrument heard from two
  observation points — identical at low frequency, diffusely decorrelated
  above the Schroeder crossover. A **diffuse‑field difference bank** (16
  random‑sign side‑only modes, 700 Hz – 6.5 kHz, Q ≈ 12, directivity ramp
  300 Hz → 3 kHz) runs once per bus (voice mid and jt wash), slewed ~30 ms.
  Not a pan, not Haas/detune. L = mid ± side; side and the room's width tank
  cancel in L+R, so the **mono fold‑down is bit‑identical to the mono render**
  (`BowStereoTests`). At 0.2 the melody's interaural coherence is ≈ 0.99
  below 1 kHz → ~0.9 at 4–8 kHz, the bare wash ~0.3–0.4; 0.6 is very wide.
  It is the WHOLE stereo law — every source stays centred; the legacy
  per‑source pans are gone.
- **Master gain** `bow_gain` (1 = bit‑exact) multiplies `bow_live_trim` as the
  performance volume of the whole radiated instrument. **Limiter**: a
  linked‑stereo safety limiter (`bow_lim_thresh` 0.8, `bow_lim_rel_ms`) at
  the very end, bit‑exact below the ceiling. **Bus meter**:
  `BowEngine.setBusMeter` meters the split buses' radiated levels (the
  `TLPVolume` bytes for the iPad toolbar scope), bit‑exact.
- **Levels** are calibrated in the artifact / overrides (`bow_live_trim`,
  `bow_rev_*`) with the pads' flat CC11 = 32; kin notes (hard‑struck Sa/Pa)
  are the hot spots — `bow_jt_norm` at the cause, the per‑string cap on the
  taraf.

## The Strings tab (⌘2) and the tarab model

- **`StringSpec`** is `degree, octave, gain, t60, enabled, set`. **The pitch
  is scale‑defined:** `degree` indexes `InstrumentState.scaleRatios` (the one
  centralized scale, mirrored from the Fret Pad), `octave` shifts it by whole
  octaves; a scale or tonic move retunes the whole bank. Hz is minted only at
  resolve time (`resolved(tonic:scaleRatios:)` = ratio × 2^octave × tonic,
  quantized to millihertz — the drone press finds its row by exact nominal
  Hz). `gain` 0 silences a row, keeping it. `TarabRatioTests`.
- **The pool invariant: sorted by pitch, one string per pitch, per bridge.**
  `InstrumentState.normalizeStrings` (sort + fold duplicates keeping the
  stronger twin — higher gain, then longer t60) runs on every entry path; an
  edit landing on another row's pitch is rejected, "+" adds at the first free
  pitch (base octave, then up, then down).
- **The scale push.** An `AppController` sink on the pad's scale/tonic calls
  `SarangiStore.syncTarabToScale`; pitches always follow, no opt‑out. The row
  LAYOUT regenerates when the scale's degree COUNT changes or via
  **"Regenerate from scale"** (raga set only); otherwise hand edits stand.
  Regeneration is `RagaTuning.buildSpecs`: one string per degree, emphasized
  Sa/Pa, low‑octave repeats and 6 upper‑octave repeats (Pa = the degree
  nearest 3/2, the vadi = the 2nd‑highest degree), pitch‑sorted (Pilu: 19
  rows); the crowd's t60s are ~×0.6 of the three drone anchors' (Sa / low Sa
  / low Pa keep 7/9/8 s) so the wash stays coupled to the playing.
- **UI:** two tables — "Raga strings (side bridges)" with the follower pinned
  above, "Chromatic strings (main bridge)" under a semitone dropdown — each
  with +, Enable/Disable all, "Reset chromatic set" / "Regenerate from scale".
  Rows: Pitch (the scale's own labels — [Scales & Tuning](scales-and-tuning.md)),
  Octave (−2…+2), read‑only Hz, Gain / t60 / On. The Drone buttons section maps
  the buttons to raga rows and holds the drone Voice picker (Tanpura default).
- **Persistence.** `SarangiStore` owns the editable `InstrumentState`; edits
  funnel into a debounced structural rebuild, the scale push rebuilds
  immediately. UserDefaults `tarabdaar.sarangiState.v8`, document schema 4 (a
  pre‑split document is seeded with the default chromatic set once; stray
  keys from older models decode away). Per‑string ratio/Hz inputs and manual
  raga tuning are not present — see `docs/history/`.

## Jawari modelling roadmap

Improvements proposed for the modal‑jawari rows, in the order worth doing.

1. **Radiate the bridge contact force — done.** Rows radiate the DC‑blocked
   contact force, unit‑matched per row (`rowForceScale`); every mode radiates
   flat and the Taraf tab's modal spectrum is the radiated one.
1b. **Add the termination (pin) force.** The bridge receives both the pin
   force T·∂u/∂x|L (linear, weight ∝ k, comb‑free) and the bone contact force
   (the buzz); contact alone under‑radiates the quiet grazing haze. Adding
   Σ(−1)^k·k·q_k per row per tick would restore the linear string tone under
   the buzz. Judge by ear against the contact‑only sound.
2. **Drive from the termination too.** The bridge force enters each row
   through a fixed 0.90 L tap (φD), so modes 10/20 are never charged; the end
   slope (∝ k·(−1)^k) has no null. Option first, then re‑fit recruitment.
3. **Two‑way coupling among the rows.** Feed the rows' summed bridge force
   back into the junction so the web blooms physically. Keep the one‑sample
   lag the drive uses — stability is the risk.
4. **Bone profile.** A real jawari is an asymmetric arc with a gentler slope
   toward the nut, lengthening the cascade rather than deepening it.
   Build‑time table, cheap to try.
5. **Damping law.** Per‑mode loss is a constant plus an f² roll‑off around
   `bow_jt_fhf`; real strings add an air term ∝ f — how long the high cluster
   survives the cascade.
6. **Port the tanpura contact string** under the sarangi web — costly
   (~9 %/core/row); only if 1–3 don't get there.

## Presets and resources

`Presets.state(.sarangiPilu, chromatic:)` generates the one seed document:
raga **Pilu**'s JI ratios as the scale, tonic 328.9 Hz, the generated raga
layout and the default chromatic set. On launch the Fret Pad scale is pushed
over it, so what ships is the LAYOUT and the gains/t60s. The timbre lives in
`bowed_string.json`; the "Default (Sarangi Live)" reset restores the untouched
artifact, zero overrides and the generated bank. Whole‑rig presets are
`TarabdaarPreset` documents — [Sound Design](sound-design.md). A fitted
per‑string table is not present; the taraf sits on the scale's JI grid.

## Tests

The guard set is deliberately small; the sound is judged by ear.

- **`TarafRemovalParityTests`** (TarabdaarCore, gated) — the SHA‑256 of one
  rendered phrase pins the whole shipped signal path. Bless deliberately.
- **`ByteNullContractTests`** (SarangiKit) — every optional path armed at its
  resting value renders bit‑identically: scope meters, bus meter, FX rack,
  cap, balance, inject, damp, tilt, body, register, master gain, tone LP
  bypass. Add a case per new "0 = off" knob.
- **Kernel lockstep** (SarangiKit) — `BowedStringEngineTests` (formula body,
  table shapes, the shared `stringBP()`/`testTaraf` scaffold), `BowPolyTests`
  (a chord stays bounded), `BowStereoTests` (fold‑down invariance),
  `TanpuraEngineTests` (exporter golden), `TouchMapperTests` (touch path ≡
  MIDI path — the parity substrate).
- **Realtime / rebuild / in‑place** (TarabdaarCore, gated; phase 2 serial in
  `tools/test-full.sh`) — `RealtimePerformanceTests`, `RebuildCostTests`,
  `ZipperTests`, `LiveParamPushTests`.
- **Model and wire** (fast) — `ParamUnificationTests`, `PresetCodingTests`,
  `TarabRatioTests`, `TarabSetTests`, `DroneStringTests`, `ScaleLabelTests`,
  plus the link/pad/glide suites (`TLPCodecTests`, `TarabLinkTests`,
  `LinkIngestTests`, `GlideSequencerTests`, `FretLayoutTests`, `FretWarpTests`,
  `ChordBarTests`, `LegacyMigrationTests`, `ScalePresetTests`).

Run both packages' `swift test` and `tools/test-full.sh` before committing a
kernel, builder, parameter or levels change.
