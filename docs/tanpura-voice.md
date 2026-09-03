# Tanpura Voice

The **Tanpura** is Tarabdaar's second voice: a **modal-contact tanpura
string** with the SAV energy-stable jawari contact — strings settling onto
the curved bone with the jiva thread, fitted offline against real tanpura
recordings. By default it is **the drone voice** (the Fret Pad drone buttons
pluck it); the **Live tab's Instrument picker** can make it the **main
instrument**, turning fret notes into plucks. The same engine, mounted from
a different artifact, is the [Sitar voice](sitar-voice.md). (Port and
fitting history: not present — see `docs/history/`.)

## The model and its files

- `Packages/SarangiKit/Sources/CBowKernel/tanpura_kernel.c` +
  `include/tanpura_kernel.h` — the C kernel: modal string + SAV contact
  solve; `tanpura_pluck` / `tanpura_bend` / `tanpura_release`, and
  `tanpura_event2`, the sample-synchronous event stream the async pool path
  MUST use. Builds in `CBowKernel` — **`-O3` ALWAYS** (the
  `module.modulemap` exposes both headers).
- `SarangiKit/Tanpura/TanpuraTables.swift` — the LOCKSTEP table builder
  (roles → per-note modal tables); `TanpuraEngineTests.testTablesLockstepGolden`
  pins it at 1e-9 rel against `Goldens/tanpura_live_golden.json`.
- `SarangiKit/Tanpura/TanpuraEngine.swift` — slot mounting, pluck / bend /
  release, the history bank, rendering.
- `SarangiKit/Resources/tanpura_live.json` — the fitted artifact: roles,
  bridge geometry, polarization, per-note `pitchCents`, the 1025-tap body
  FIR, the room. Output chain: body FIR → `tp_gain` → calibration room
  (`DSP/Reverb.swift`, the engine's only Swift dependency).

**RECAL LAW.** `pitchCents` and the role t60s are secanted at the artifact's
exact physics. Physics edits (roles, contact, polarization, room) are
**artifact edits**: regenerate `tanpura_live.json` with its exporter
(`scripts/export_tanpura_live.py` in the fitting project) after ANY physics
change; never hand-edit. There is no override/rebuild path for the physics —
the rebuild-timed `tp_*` params below are shaping layered on it.

## JI slot mounting

Pitches are **JI scale degrees against one tonic**, so `TanpuraEngine` mounts
**caller-supplied exact frequencies**: `TanpuraVoiceSource.slotFrequencies`
builds every scale-degree ratio in octaves **×¼ … ×4 of the tonic** (the
drone-ratio wire range; a 12-degree scale ≈ 49 slots). The per-note
`pitchCents` wrap correction (the static jawari wrap pulls pitch sharp; the
builder pre-compensates) is **interpolated in log-pitch space**
(`TanpuraEngine.centsCorrection`; the +5…+9 ¢ curve is smooth, error
sub-cent, ends clamped). `pluck(slot:velocity:scale:)` applies role pluck ×
high-note softening × the velocity curve (0.3 floor) × a caller scale;
`nearestSlot(toHz:toleranceCents:)` is the log-space lookup the drone
buttons and the main-instrument routing use.

## Audio graph and lifecycle

`TanpuraVoiceSource` (TarabdaarCore) is a second `AVAudioSourceNode` beside
the String voice's — `node → symGain → mainMixerNode` — at the artifact's
native 48 kHz. Same engine-swap discipline as `StringVoiceSource`:
`os_unfair_lock`-published engine, equal-power ~300 ms crossfade so ringing
strings decay across a swap, `recentEngines` keeps swapped-out engines off
the audio-thread dealloc path.

**Builds are ~seconds of CPU** (every slot is mounted and settled onto its
static wrap through the kernel), so: its own serial queue
(`tarabdaar.tanpura.build`, `.utility`); the scale/tonic pipeline debounces
**750 ms** and skips unchanged tunings (`AppController.syncTanpuraFromScale`);
a newer build supersedes an in-flight one (`tanpuraBuildGen`); held drone
buttons re-pluck onto the fresh engine. The kernel renders through its
**async worker pool** (the callback never computes; one block ≈ 32 ms of
latency on this path only). Telemetry: `AudioEngine.tanpuraStats()`
(underruns / divergence resets / ringing strings).

## Drone mode (default)

CC 102–104 → `AudioEngine.setDronePressed` → tanpura branch: **press** = one
pluck at the mapped pitch (velocity 100 × `tp_drone_level`); **hold** =
re-pluck every `tp_drone_cycle` s (default 2.5; below 0.1 = off; read each
hop, so a live edit applies mid-hold); **release** = the cycle stops and the
string **rings out**. The pitch comes from the Strings-tab mapping
(`InstrumentState.droneStringIds` → `droneStringFreqs`); the grid carries
every scale pitch, so the mapped Hz always has a slot (50 ¢ lookup tolerance
guards a mid-rebuild mismatch). Switching the drone voice (Strings tab →
Voice) releases everything and the buttons start clean; the legacy
sympathetic mode keeps its own `bow_drone_*` calibration
([fret-pad.md](fret-pad.md)).

## The taraf coupling (`tp_taraf`)

The tanpura **charges the sarangi taraf**, as though strung into the bowed
instrument: the node's render callback taps its finished mono output into
the String kernel's **jt inject ring** (`bow_poly_jt_inject_write`; ring
details in [sitar-voice.md](sitar-voice.md)). Drone plucks and
main-instrument notes ring the Strings-tab rows, and the web answers through
the String voice's body/tone/stereo chain, shaped by the voice→taraf FX
insert like any drive. The sitar and the tanpura share the ONE ring, so each
scales **at its own tap** (`TanpuraVoiceSource.setInjectGain`: `tp_taraf` /
`st_taraf`; gain 0 skips the tap) and the kernel-side gain is the shared arm
(`AudioEngine.updateJtInjectArm`). `tp_taraf` defaults **4.0** (0–8): the
two artifacts' trims are pluck-peak-matched, so the sitar's calibrated drive
transfers. 0 = the byte-null String parity path. The coupling keeps the jt
web awake (quiescence gate) for as long as the tanpura sounds — physics,
not a leak.

## Main-instrument mode

Live tab → **Instrument** (`AppController.mainInstrument`, NOT persisted —
every launch starts on the String voice; presets can switch it;
`AudioEngine.setMainInstrument`). With the tanpura as the played voice:

- **Wire touches** (`touchOnDirect`): onset and exact pitch arrive in one
  TLP frame, so the pluck fires immediately — the nearest mounted slot
  (60 ¢ tolerance) **bent to the exact Hz**, scaled by `tp_pluck_level`,
  recorded per touch id (`tanpuraTouchSlot`).
- **In-process MIDI** (auditions, controllers): `routeSarangiModelMIDI`
  gates note messages away from the String mapper and holds each note-on as
  a **pending pluck** that fires on the pitch bend immediately following it
  (the note number is only the nearest semitone; CC11 is the fallback
  trigger); the slot is recorded per MPE channel (`tanpuraChannelSlot`).
- **Glides retune the ringing string** — `TanpuraEngine.bend`, a
  kernel-side live retune (`tp_apply_bend`): each mode's rotation angle is
  rescaled from mount-time base tables (damping, so every t60, preserved)
  and the SAV contact-response tables refreshed to match. Ratio clamps to
  ×0.25…×4 of the slot; modes bent past the output Nyquist are silenced
  rather than aliased and re-grow from contact on the way down.
- **Note-off = fast release, not a hard damp** (`tanpura_release`): the
  string is **demoted immediately** (linearized about the settled wrap —
  load-bearing: with contact live, the per-sample pull toward equilibrium
  excites a limit cycle ~26 dB under the ring that never dies) and its
  deviation decays with t60 = **`tp_rel_t60`** (0.4 s). A finger stop: the
  buzz cuts, the pitch rings down. A re-pluck promotes the string and clears
  the release and any bend.

CC121 never damps anything; CC123 fast-releases every tracked
main-instrument note. Slot bindings clear on instrument switch and engine
rebuild. Drone strings are untouched — their release rings out. The String
voice stays armed and silent, so switching back is instant.

## Pluck touch, the string bank, and pluck drive

The kernel is deterministic, yet repeated plucks vary: `tanpura_pluck` adds
the displacement **on top of the live modal state**, so ms-scale timing
decides per-mode interference (+7 dB build-up over ~5 dense re-plucks, the
1.5–6 kHz buzz share swinging 5×), and the contact's power law (`kc·em^α`)
turns the level lottery into a timbre lottery. Three `.live` controls,
applied at the next pluck through the kernel event stream (ops 3/4 —
sample-synchronous with it):

- **`tp_pluck_touch`** (0–1, default 0), "pluck isolation". 0 = the
  ride-the-ring pluck. Above 0, **every pluck is a separate string**: the
  slot's ringing string **migrates to a history clone** — a full jawari
  simulation at its own pitch (it freezes copies of the 11 bend-mutable
  tables and aliases the rest, so glides retune only the live note), its
  ring scaled by this value — and the pluck lands on settled state. A
  released string never resurrects. Below the clones sits the owner's
  **linear ghost bank** (deviation state on the same per-mode envelopes —
  natural decay minus the jawari's re-pumping; handoffs superpose, so
  unbounded history costs one bank); below ~−86 dBFS it auto-idles.
- **`tp_poly`** (0–16, default 6), "history string bank" — how many
  previous plucks stay alive as REAL strings before eviction to the ghost
  tier, each about one contact solve. Same-pitch strings sum in the air, so
  repeated-note level breathes ±3–6 dB as their phases beat — jodi-like,
  not steady. `tp_poly 0` skips clones: the old ring goes straight to the
  ghost with its **low partials restarted by the fresh pluck** (spectral
  split above 2×f0) — the most consistent-volume mode and the cheapest.
- **`tp_pluck_drive`** (0.25–4, default 1) — the mellow↔buzzy axis at
  constant loudness: pluck displacement × drive, slot output gain ÷ drive,
  both at the pluck (`tp_apply_drive`; the kernel keeps `gain0` and rides
  `gain = gain0/drive`). Engagement depth is the buzz conversion: cleaner
  and darker below 1, brighter with a faster cascade above; 1 is bit-exact.
  Editing drive between re-plucks steps the old tail's level by the ratio
  (with touch active the tail sits in the ghost bank at its frozen gain).

None has RECAL impact. A stroke-angle pluck rotation is INERT under the
fitted polarization (`pol.g` 0; the lateral bank reaches the output only
through `pol.rt` 0.0015) — not present.

## Register calibration — `tp_jiva_comp` and `tp_cascade`

With the fitted geometry only the LOW register (~65–131 Hz, the fitted band)
sits in the **sustained-graze regime** that makes the jawari — buzz share
~15%, harmonics laddering in over seconds. An octave up the string falls off
the bone: buzz <1% at any pluck, and more drive skips the graze into a slam
(the whole cascade inside ~0.2 s).

The regime is set by the **height of the jiva thread's top above the bone
apex** (fitted: 9.75 μm for every role, `threadH − threadDx²/2·radius`).
Raising it lifts the string away (buzz *drops* — the "open jiva" clean
position); lowering it too far drops the string onto bare bone (the
no-thread sound plus a −5…−7 ¢ shift — the **lower window**; avoid it).
Between sits the **upper graze window**; `TanpuraTables.registerCompThreadMul`
carries the bench-measured thread-top heights that land every pitch in it:
9.75 → 9.15 → 8.25 → 7.95 → 7.80 → 6.75 μm at 104/140/156/176/208/262 Hz,
log-frequency interpolated, flat below 104 Hz, −2.25 μm/oct above 262 Hz,
floored at 5.5 μm. Buzz share 11–19% across 104…350 Hz, pitch cost < 1 ¢
(the upper window barely moves the settled wrap, so `pitchCents` survives).
**`tp_jiva_comp`** (0–1, **default 1**) blends fitted → calibrated heights;
0 = the fitted geometry, byte-identical.

**`tp_cascade`** (0–1, default 1) slows the higher slots' ladder, which
otherwise runs faster in wall-clock terms (the jawari converts on every
graze pass, and passes come at f0: mid harmonics in 0.1–0.2 s at 208 Hz vs
~2 s at low Sa). Two levers graded by `log2(f0/104)` (zero at and below the
anchor): a further **thread lift** toward the fitted height
(`cascadeThreadLift`, +0.75 μm/oct, composed with the comp law, clamped at
the fitted height — the instant jump becomes a ~1 s bloom) and an
**HF-sustain stretch** (`cascadeHFT60Mul`, ×(1+log2(f0/104)) on `t60hf` via
`buildNote(hfT60Mul:)` — recovers the brightness the gentler graze costs).
At cascade 1 the h6 onset sits at 1.0–2.0 s across 104–262 Hz, pitch cost
< 0.9 ¢; **156 Hz is the honest residual** (its window is narrow).
Pluck-draw stretch and drive reduction are not cascade levers.

Both parameterize the TABLE BUILD (the debounced 750 ms full rebuild).

**TRAP — `tp_pluck_drive` masks both.** A drive well above 1 slams through
the graze regardless of thread height: instant broadband attack, fast
cascade. With comp/cascade on, drive belongs at ~1 — a character knob, not
a register fix.

**RECAL note:** the thread-height targets are measured at the current
artifact's thread/bone geometry. If `tanpura_live.json` regenerates with
different constants, re-measure the graze window per pitch and refresh the
table in `registerCompThreadMul`.

## Parameters and presets

The **"Tanpura" registry group** — all registry-`.live`
(`AudioEngine.setTanpuraParam` via the `tp_` branch of
`setStringControlParam`); [parameters.md](parameters.md)'s Timing column
marks the table-build ones (`tp_jiva_comp`, `tp_cascade`) that
ride the debounced rebuild. `tp_gain`'s 0.02 default **is** the artifact's
fitted `gain` — keep them in step when the artifact regenerates (the unified
apply pushes every live default at startup; a drifted default would silently
retrim). `tp_rel_t60` is `.perNote`; drones never read it.

Presets: `TarabdaarPreset.mainInstrument` / `.droneVoice` (optional
sections); `tp_*` resting values ride `paramValues`. The factory preset
resets to String main + tanpura drones.

## Tests

`SarangiKitTests/TanpuraEngineTests` — the **lockstep golden** (note 57 at
its calibrated cents, 1e-9 rel) and the JI-slot engine smoke.
`ByteNullContractTests` — inject gain 0 (and every "0 = off" path) is
bit-null at rest. `TarafRemovalParityTests` is untouched — a separate source
node; the String render path is byte-identical.
