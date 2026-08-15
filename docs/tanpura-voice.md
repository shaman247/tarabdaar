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

## Main-instrument mode

Live tab → **Instrument** (`AppController.mainInstrument`, persisted;
`AudioEngine.setMainInstrument`). When the tanpura is the played voice,
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

- `tp_shape_align` / `tp_shape_focus` / `tp_shape_quiet` /
  `tp_shape_spread` — the scale-shaped overtones (previous section):
  registry-`.live` but applied through their own debounced tanpura
  rebuild.

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
