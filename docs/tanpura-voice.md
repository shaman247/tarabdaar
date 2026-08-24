# Tanpura Voice

The **Tanpura** is Tarabdaar's second voice (ported 2026-08-04 from the Sarangi
Live app's tanpura campaign): the r7 **modal-contact tanpura model** with the
SAV energy-stable jawari contact — a physical model of strings settling onto
the curved bone with the jiva thread, fitted offline against real tanpura
recordings. By default it is **the drone voice** (the Fret Pad drone buttons
pluck it); the **Live tab's Instrument picker** can also make it the **main
instrument**, turning fret notes into plucks.

(It is unrelated to the TarabdaarDSP tanpura deleted in the 2026-07-23
simplification — that was a different, older model with its own fitting
pipeline. This one is a fresh port of a fresh instrument; the CLAUDE.md
"deleted — do not revive" list still stands for the old one.)

## What was ported, from where

Upstream: `~/Desktop/sarangi` (the port cut its own copy — like the rest of
SarangiKit there is **no upstream link**; change the DSP here). The port
manifest is upstream commit `414682f` ("tanpura live: SAV contact kernel,
playable instrument, polyphony engine"):

| Tarabdaar file | Origin | Divergence |
|---|---|---|
| `Packages/SarangiKit/Sources/CBowKernel/tanpura_kernel.c` + `include/tanpura_kernel.h` | verbatim, then extended | **2026-08-05: live pitch bend + note-off release** (`tanpura_bend` / `tanpura_release` / `tanpura_event2` — see the main-instrument section); the unused FD-continuum entry points ride along, uncalled |
| `Packages/SarangiKit/Sources/SarangiKit/Tanpura/TanpuraTables.swift` | verbatim | none — the LOCKSTEP builder; `TanpuraEngineTests.testTablesLockstepGolden` pins it at 1e-9 rel against the upstream python golden |
| `Packages/SarangiKit/Sources/SarangiKit/Tanpura/TanpuraEngine.swift` | adapted | **JI slot mounting** (below); the FD path was not ported (upstream retired it by ear, round 23) |
| `Packages/SarangiKit/Sources/SarangiKit/Resources/tanpura_live.json` | verbatim | the fitted artifact (roles, bridge geometry, polarization, per-note pitch cents, 1025-tap body FIR, room). **RECAL LAW**: cents + role t60s are secanted at this exact physics — regenerate with the upstream exporter after any physics change, never hand-edit |

The engine's only Swift dependency is `DSP/Reverb.swift`, which Tarabdaar's
SarangiKit already vendors (a superset of upstream's). The kernel builds in
the existing `CBowKernel` target — **`-O3` ALWAYS** applies to it too (an
explicit `module.modulemap` now exposes both headers).

## The Tarabdaar divergence: JI slots, not a 12-TET keyboard

Upstream mounts one slot per 12-TET MIDI note 33–81. Tarabdaar's pitches are
**JI scale degrees against one tonic**, so the port's `TanpuraEngine` mounts
**caller-supplied exact frequencies**: `TanpuraVoiceSource.slotFrequencies`
builds the grid — every scale degree ratio in octaves **×¼ … ×4 of the tonic**
(the drone-ratio wire range; a 12-degree scale ≈ 49 slots, upstream's count).
The artifact's per-note `pitchCents` wrap correction (the static jawari wrap
pulls pitch sharp; the builder pre-compensates) is **interpolated in log-pitch
space** (`TanpuraEngine.centsCorrection`) — the curve spans +5…+9 ¢ smoothly,
so interpolation error is sub-cent. `TanpuraEngineTests.testCentsInterpolation`
pins exact-note reproduction and end-clamping.

`pluck(slot:velocity:scale:)` keeps the upstream amplitude law (role pluck ×
high-note softening × the velocity curve with its 0.3 floor) times a caller
scale; `nearestSlot(toHz:toleranceCents:)` is the log-space lookup the drone
buttons and the main-instrument routing use.

## Audio graph & lifecycle

`TanpuraVoiceSource` (TarabdaarCore) is a second `AVAudioSourceNode` **beside**
the String voice's — `node → symGain → mainMixerNode` — at the artifact's
native 48 kHz (same as the String voice; the mixer input converts; the
recording tap on the main mixer captures both). Same engine-swap discipline as
`StringVoiceSource`: `os_unfair_lock`-published engine, equal-power ~300 ms
crossfade so ringing strings decay across a swap, `recentEngines` keeps
swapped-out engines off the audio-thread dealloc path.

**Builds are ~seconds of CPU** (every slot is mounted and settled onto its
static wrap through the kernel), far heavier than a String rebuild — so:

- its own serial queue (`tarabdaar.tanpura.build`, `.utility` QoS),
- the scale/tonic pipeline debounces **750 ms** and skips unchanged tunings
  (`AppController.syncTanpuraFromScale`),
- a newer build supersedes an in-flight one (`tanpuraBuildGen`),
- held drone buttons re-pluck onto the fresh engine after the swap.

The kernel renders through its **async worker pool** (the jt live law: the
callback never computes, one block of latency ≈ 32 ms on this path only —
inaudible on a plucked drone). Telemetry: `AudioEngine.tanpuraStats()`
(underruns / divergence resets / ringing strings).

## Drone mode (default)

CC 102–104 → `AudioEngine.setDronePressed` → tanpura branch:

- **press** = one pluck at the mapped pitch (velocity 100 × `tp_drone_level`),
- **hold** = re-pluck every `tp_drone_cycle` s (default 2.5; 0 = off; read
  each hop, so a live edit applies mid-hold),
- **release** = the cycle stops; the string **rings out** (no damp).

The button's pitch still comes from the Tarab-tab mapping
(`InstrumentState.droneStringIds` → `droneStringFreqs`) — the tanpura grid
carries every scale pitch, so the mapped Hz always has a slot (50 ¢ lookup
tolerance guards a mid-rebuild mismatch). Switching the drone voice
(Tarab tab → Voice) releases/damps everything and the buttons start clean in
the new mode. The legacy sympathetic mode is unchanged and stays calibrated
by its own `bow_drone_*` scalars ([fret-pad.md](fret-pad.md)).

## The taraf coupling (`tp_taraf`, 2026-08-21)

The tanpura also **charges the sarangi taraf** — as though the tanpura
were strung into the bowed instrument: the tanpura node's render
callback taps its finished output (mono mixdown) into the String
kernel's **jt inject ring** (`bow_poly_jt_inject_write`), the same
mechanism the sitar's halo uses ([sitar-voice.md](sitar-voice.md) has
the ring/kernel details). Drone-button plucks — and main-instrument
tanpura notes — ring the Strings-tab rows sympathetically, and the
web answers through the String voice's body/tone/stereo chain, shaped
by the voice→taraf FX insert like any drive.

Because the sitar and the tanpura share the ONE ring, each voice's
level scales **at its own tap** (`TanpuraVoiceSource.setInjectGain`:
`tp_taraf` here, `st_taraf` there; gain 0 skips the tap — nothing is
written), and the kernel-side gain is just the shared arm
(`AudioEngine.updateJtInjectArm`). `tp_taraf` defaults **4.0** (range
0–8): the two artifacts' output trims are pluck-peak-matched, so the
sitar's audition-calibrated drive transfers. 0 = no coupling — the
byte-null String parity path (`TarafInjectTests` pins the pre-gain
scaling and the gain-0 skip). The String voice stays armed under
tanpura drones, so the web is always there to ring; note the coupling
keeps the jt web awake (quiescence gate) for as long as the tanpura
actually sounds — that is the physics, not a leak.

## Main-instrument mode

Live tab → **Instrument** (`AppController.mainInstrument`, NOT persisted —
every launch starts on the String bowed voice (2026-08-20); presets can
still switch it; `AudioEngine.setMainInstrument`). When the tanpura is the played voice,
`routeSarangiModelMIDI` gates note messages away from the String mapper and
turns each note-on into a **pending pluck** that fires on the **pitch bend
immediately following it** — the pad's note-on carries only the nearest
semitone; the bend carries the exact fret pitch (CC11 is the fallback trigger
for senders that skip the bend). The pluck lands on the nearest mounted slot
(60 ¢ tolerance) **bent to the exact Hz** (pitch-exact, not slot-quantized),
scaled by `tp_pluck_level`, and the slot is recorded per MPE channel
(`tanpuraChannelSlot`).

**The note then plays like the String voice (2026-08-05):**

- **Glides retune the ringing string.** Every later per-channel pitch bend
  becomes `TanpuraEngine.bend` — a kernel-side **live retune**
  (`tp_apply_bend`): each mode's rotation angle is rescaled from mount-time
  base tables (the damping envelope, and so every t60, is preserved) and the
  SAV contact-response tables refreshed to match, so the jawari stays
  consistent through the bend. Ratio clamps to ×0.25…×4 of the slot; modes
  bent past the output Nyquist are silenced rather than aliased and re-grow
  from contact on the way back down.
- **Note-off = fast release, not a hard damp** (`tanpura_release`). A held
  note decays at the string's natural rate; on release the string is
  **demoted immediately** (linearized about the settled wrap — the demotion
  is load-bearing: with contact live, the per-sample pull toward equilibrium
  excites a sustained limit cycle ~26 dB under the ring that never dies) and
  its deviation decays with t60 = **`tp_rel_t60`** (default 0.4 s).
  Musically it is a finger stop: the buzz cuts at note-off, the pitch rings
  down fast. A re-pluck promotes the string and clears both the release and
  any leftover bend.

CC121 (sent before every pad note-on) never damps anything; CC123
fast-releases every tracked main-instrument note. The channel↔slot binding
clears on instrument switch and engine rebuild (slots change; the next
note-on rebinds). Drone-button strings are untouched by all of this —
their release still rings out. The String voice stays armed and silent
(no note messages), so switching back is instant.

## Scale-shaped overtones (2026-08-05)

A real tanpura's overtones sit where string physics puts them; the
electronic one is free to bend the cascade toward the raga. The
**`tp_shape_*` trio** ("scale-shape" in the Tanpura registry group) does
this per mode at table build (`TanpuraShaping`, applied inside
`TanpuraTables.buildNote` between the modal-frequency law and everything
derived from it — rotations, horizontal bank and the kernel's SAV
response tables all see the shaped frequencies consistently):

- **`tp_shape_align`** — retunes each partial toward the nearest scale
  pitch class (octave-circular, log space). Full pull inside an **80 ¢
  capture window**, smoothstepped to zero by 160 ¢ — so the flagship
  corrections land (harmonic 5 → komal ga, ~71 ¢; harmonic 7 → n where
  the scale has one) while a partial in a pentatonic gap stays at its
  harmonic position instead of being dragged into no-man's-land.
- **`tp_shape_focus`** — scales each mode's t60 by its **post-retune**
  proximity to the scale (30 ¢ gaussian, floored at 5%). Because the
  jawari keeps re-pumping every mode, this makes the cascade *evolve
  toward the scale* over the note's life, not a static EQ.
- **`tp_shape_quiet`** — turns down the **radiated** level of
  misaligned partials (same post-retune 30 ¢ kernel as focus), scaling
  each mode's output projection `phiO` toward silence — at 1 an
  off-scale partial is inaudible. Unlike focus it changes **no
  dynamics**: the mode still rings at full energy and keeps trading
  energy through the jawari contact (`phi_o` is readout-only in the
  kernel — the output dot product). A per-partial fader, where focus
  is a per-partial damper.
- **`tp_shape_spread`** — deterministic per-string/per-mode jitter of
  the pull fraction (seeded by the slot frequency, reproducible across
  rebuilds). 0 = every string corrected identically, so shared partials
  lock to exact 0-beat (can go organ-static); 1 = pulls vary 0–100%,
  restoring slow shimmer. Inert unless align > 0.

**Modes 1–2 are never touched** — they pin the perceived pitch and the
`pitchCents` wrap calibration (RECAL LAW stays valid; the correction was
secanted with the low modes at their fitted places). All three default
to 0 = the physical tanpura, byte-identical tables (the lockstep golden
runs the nil path).

**They are `.live` in the registry but parameterize the table build**:
an edit schedules a **debounced (750 ms) full tanpura rebuild** —
seconds of CPU, the same reasoning as the scale pipeline — with the
usual generation-guard supersession and held-drone re-pluck. The
startup default push and spread-alone edits schedule nothing. Bends
transpose a shaped mount rigidly (`tanpura_bend` is one ratio across
modes), so "aligned" strictly holds at the mount pitch — the feature's
home is the drone. Guards: `TanpuraShapingTests` (SarangiKit),
`TanpuraVoiceTests` (registry shape).

## Parameters

The **"Tanpura" registry group** — all `.live` (`AudioEngine.setTanpuraParam`
via the `tp_` prefix branch of `setStringControlParam`; they never rebuild):

- `tp_gain` — output trim; the 0.02 default **is** the artifact's fitted
  `gain` (`TanpuraVoiceTests` pins them equal — the unified apply pushes every
  live default at startup, so a drifted default would silently retrim).
- `tp_drone_level`, `tp_drone_cycle`, `tp_pluck_level` — see above.
- `tp_rel_t60` — the main-instrument note-off release t60 (2026-08-05);
  drone strings never read it.
- `tp_pluck_touch`, `tp_pluck_drive` — the pluck consistency and
  character knobs (next section).
- `tp_taraf` — the sympathetic taraf drive (its own section above).
- `tp_jiva_comp`, `tp_cascade` — the per-pitch register calibration
  and its cascade-slowing companion (their own sections below); like
  the `tp_shape_*` trio they are registry-`.live` but ride the
  debounced tanpura rebuild.

- `tp_shape_align` / `tp_shape_focus` / `tp_shape_quiet` /
  `tp_shape_spread` — the scale-shaped overtones (previous section):
  registry-`.live` but applied through their own debounced tanpura
  rebuild.

## Pluck touch & pluck drive (2026-08-15)

The kernel is fully deterministic — no noise source anywhere — yet
repeated plucks vary wildly. Measured through the audition pipeline:
re-plucking a ringing string **accumulates +7 dB** over ~5 dense plucks,
and at the plateau the 1.5–6 kHz buzz share swings **5×** pluck-to-pluck
(30× across a realistic 3-button sequence). Mechanism: `tanpura_pluck`
adds the pluck displacement **on top of the live modal state**, so
ms-scale timing decides per-mode constructive/destructive interference —
unplayable precision, so it reads as random — and the SAV contact's
power-law (`kc·em^α`) converts the level lottery into a timbre lottery.
Two per-pluck controls parameterize this (both `.live`, applied at the
next pluck, riding the same kernel event stream as the pluck itself —
ops 3/4 — so they are sample-synchronous with it):

- **`tp_pluck_touch`** (0–1), "pluck isolation" — how isolated each
  pluck is from the string's ringing past. 0 = the legacy
  ride-the-ring pluck. Above 0, **every pluck is a separate string**
  (the STRING-BANK rework, latest 2026-08-15 revision): at the pluck
  the primary slot's ringing string **migrates to a history clone** —
  a full jawari simulation continuing at its own pitch (the clone
  freezes copies of the 11 bend-mutable tables and aliases the rest,
  so glides retune only the live note, never the history), its ring
  scaled by this value (1 = it rings on in full) — and the pluck
  lands on settled state: attacks always consistent. A
  note-off-**released** string never resurrects. The decay tiers
  below the live clones (see `tp_poly`): the oldest clone is evicted
  into its owner's **linear ghost bank** (a deviation state rotating
  through the same per-mode envelopes — natural decay minus the
  jawari's re-pumping; handoffs superpose, so unbounded history costs
  one bank), and anything below ~−86 dBFS auto-idles.
- **`tp_poly`** (0–16, default 6), "history string bank" — how many
  previous plucks stay alive as REAL strings before eviction to the
  ghost tier. Each live history string costs about one string's
  contact solve. **The physics trade to know** (all three measured on
  irregular re-pluck intervals): same-pitch strings sum in the air,
  so real history strings make repeated-note level *breathe* by
  ±3–6 dB as their contact-drifting phases beat — alive, jodi-like,
  but not steady. `tp_poly 0` skips clones entirely: the old ring
  goes straight to the ghost with its **low partials restarted by the
  fresh pluck** (spectral split above 2×f0) — the most
  consistent-volume mode (0.8–2.3 dB spread) and the cheapest; the
  old note's shimmer still rings out, only its fundamental is
  seamlessly replaced by the new note's. Legacy touch-0 merge:
  3.6–4.1 dB with random buzz swings. Pick by ear: bank for living
  fullness, 0 for steadiness.
- **`tp_pluck_drive`** (0.25–4, default 1) — the mellow↔buzzy axis at
  constant loudness: the pluck displacement scales by the drive and
  the slot's output gain by its inverse, both applied
  sample-synchronously at the pluck (`tp_apply_drive`; the kernel
  keeps the mount gain as `gain0` and rides `gain = gain0/drive`).
  The contact's power law makes engagement depth the buzz conversion,
  so the same-loudness note rings cleaner and darker below 1, buzzes
  brighter with a faster-developing cascade above it. Drive 1 is a
  strict no-op (`gain0/1.0 == gain0` — bit-exact). Editing drive
  between re-plucks of a still-ringing slot steps the old tail's
  level by the ratio at the pluck instant; with touch active the
  tail is in the ghost bank at its own frozen gain, unaffected.

  (A **stroke-angle** rotation of the pluck into the lateral
  polarization was tried first and measured INERT as a character axis
  under the fitted config: `pol.g` is 0, so the lateral bank reaches
  the output only through the contact's transverse coupling
  (`pol.rt` 0.0015) — a fully lateral pluck sits −30 dB with no
  bloom, and holding the vertical drive constant while varying the
  lateral reservoir changed the render by <0.1 dB / <0.1% buzz share.
  Don't re-add it without changing the polarization physics.)

Both default to the calibrated instrument (touch 0, drive 1) with
byte-identical plucks, and neither has RECAL impact — touch is a
state operation, drive an amplitude/gain pair; the wrap physics and
`pitchCents` are untouched. Guard:
`TanpuraEngineTests.testPluckTouchAndDrive` (touch-1 re-plucks carry
the previous note's ring through the pluck — no truncation — and the
superposed ghost decays; legacy re-plucks vary; drive-1 is bit-exact;
high drive brightens and low drive darkens at compensated ring level).

## Register calibration — `tp_jiva_comp` (2026-08-15)

Drive alone cannot fix the register problem it exposed: with the
fitted geometry only the LOW register (the ~65–131 Hz band the
artifact was fitted on) sits in the **sustained-graze regime** that
makes the jawari — buzz share ~15%, harmonics laddering in over
seconds, and drive changing brightness *without* touching the ladder
rate. An octave up the string falls off the bone: buzz <1% at any
reasonable pluck ("too clean/dark"), and raising drive skips the graze
entirely into a slam — the whole cascade inside ~0.2 s ("too fast").

The regime is set by the **height of the jiva thread's top above the
bone apex** (the fitted geometry puts it at 9.75 μm for every role,
via `threadH − threadDx²/2·radius`). The thread is the string's
resting point; the graze gap it leaves toward the apex must shrink as
f0 rises. Raising the thread only lifts the string away (buzz *drops*
— the real-tanpura "open jiva" clean position), and lowering it too
far drops the string onto bare bone (the no-thread plain sound, plus a
−5…−7 ¢ pitch shift — the **lower window**; avoid it). In between
sits the **upper graze window**, and `TanpuraTables.
registerCompThreadMul` carries the bench-measured targets that land
every pitch in it: thread-top heights 9.75 → 9.15 → 8.25 → 7.95 →
7.80 → 6.75 μm at 104/140/156/176/208/262 Hz, interpolated in
log-frequency, flat below 104 Hz, extended at −2.25 μm/oct above
262 Hz and floored at 5.5 μm. Validated: buzz share 15.3/18.6/15.8/
15.9/15.4/11.4 % at 104…350 Hz (vs <1% uncalibrated above 140), pitch
cost < 1 ¢ everywhere (the upper window barely moves the settled
wrap, so the `pitchCents` calibration survives).

**`tp_jiva_comp`** (0–1, **default 1**) blends fitted → fully
calibrated thread heights. It parameterizes the TABLE BUILD, so edits
ride the same debounced (750 ms) full-rebuild path as the `tp_shape_*`
trio. Shipping it at 1 deliberately changes the high register's
default sound (user-requested: every pitch defaults to low Sa's
buzziness and cascade); comp 0 restores the fitted geometry
byte-identically.

### Cascade slowing — `tp_cascade` (0–1, default 1)

Even calibrated, higher slots develop their overtone ladder faster in
wall-clock terms (the jawari converts on every graze pass, and passes
come at f0): at 208 Hz the mid harmonics arrived in 0.1–0.2 s where
low Sa takes ~2 s. Two bench-validated levers slow it while holding
buzziness, both graded by `log2(f0/104)` (zero at and below the
anchor, whose cascade is the reference):

- a further **thread lift** toward the fitted height
  (`TanpuraTables.cascadeThreadLift`, +0.75 μm/oct at cascade 1;
  composed with the comp law and clamped at the fitted height) — the
  gentler graze turns the instant harmonic jump into a ~1 s bloom;
- an **HF-sustain stretch** (`cascadeHFT60Mul`, ×(1+log2(f0/104)) on
  the `t60hf` reference per slot via `buildNote(hfT60Mul:)`) — the
  longer-ringing top recovers the brightness the gentler graze costs.

Validated at cascade 1 (drive 1): h6 onset across 104/140/156/208/262
Hz = 1.98/1.38/0.37/1.29/1.01 s (was 1.98/0.46/0.28/0.23/0.37 with
calibration alone), buzz share 10.6–21.5%, pitch cost < 0.9 ¢.
**156 Hz is the honest residual** — its early mids resist every probed
lever (gap, HF-sustain, drive; the window there is narrow). Probed
and REJECTED as cascade levers: pluck-draw stretch (even a 2-period
draw cancels the note — the free-rotation draw law) and drive
reduction (falls off the graze knee, buzz dies before the cascade
slows). Rebuild param like `tp_jiva_comp`.

**TRAP — `tp_pluck_drive` masks all of this.** A drive well above 1
slams the pluck through the graze regardless of thread height:
instant broadband attack, fast cascade, both calibrations inaudible
(a persisted drive of 3.8 — the pre-calibration workaround for the
dead high register — made an in-app cascade A/B measure as a no-op).
With `tp_jiva_comp`/`tp_cascade` on, drive belongs back at ~1; it
remains a character knob, not a register fix.

**RECAL note:** the targets were measured at the current artifact's
thread geometry (`TanpuraCascadeBench`, kept skip-gated in
SarangiKitTests). If `tanpura_live.json` regenerates with different
thread/bone constants, re-run the bench (TANPURA_BENCH_LIFT sweep →
TANPURA_BENCH_LAW validation) and refresh the table in
`registerCompThreadMul`. Guard: `testRegisterCompLaw` (fitted below
104 Hz and at comp 0, the measured 156 Hz node, monotonicity + floor,
linear blending).

Physics edits (roles, contact, polarization, room) are **artifact edits** —
regenerate `tanpura_live.json` upstream-style (RECAL LAW); there is no
override-dict/rebuild path for the tanpura (the `tp_shape_*` rebuild is
scale shaping layered on the fitted physics, not a physics override).

Presets: `TarabdaarPreset.mainInstrument` / `.droneVoice` (optional sections —
old files load unchanged); the `tp_*` resting values ride `paramValues` like
every live param. The factory preset resets to String main + tanpura drones.

## Tests

- `SarangiKitTests/TanpuraEngineTests` — the **lockstep golden**
  (`Goldens/tanpura_live_golden.json`, note 57 at its calibrated cents,
  1e-9 rel), cents interpolation, a JI-slot engine smoke (silent before
  pluck, ringing 2 s after, finite, sync path), and **bend + release**
  (`testBendAndRelease`: a ringing 110 Hz string bent ×1.5 measures 165 Hz
  by autocorrelation, note-off release decays it >34 dB past the room
  tail, re-pluck restores pitch and level).
- `TarabdaarCoreTests/TanpuraVoiceTests` — the slot grid covers every degree ×
  octave and the default drone ratios (through the document's millihertz
  quantization); the registry group's shape and defaults.
- `TarafRemovalParityTests` is untouched — the tanpura is a separate source
  node; the String render path is byte-identical.
