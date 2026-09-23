# Sarangi — the played voice

The **String voice** is Tarabdaar's default played instrument: a pure‑physics
bowed gut string in **`SarangiKit`** (`Packages/SarangiKit/`) — **`BowEngine`**
(`Bow/BowEngine.swift`) driving the **C friction kernel** (`CBowKernel`,
built `-O3` always: `bow_kernel_poly.c` is the played strings, the body and
the render loop, `bow_jt.c` the taraf, `bow_poly_internal.h` the state and
the per-sample inlines both share) at 96 kHz, half‑band‑decimated to
48 kHz. The kernel is the whole instrument — played strings, the two‑bridge
modal‑jawari taraf, the formula body, radiation and room — and needs only
**`bowed_string.json`** (`Resources/`). SarangiKit is Tarabdaar's own code:
the DSP is edited here, and `TarafRemovalParityTests` pins a SHA‑256 of the
shipped render so an accidental edit fails loudly.

The plucked voices are [Tanpura](tanpura-voice.md) and [Sitar](sitar-voice.md);
levels, rebuild cost and in‑place application are in
[Sound Design](sound-design.md); every knob is in [Parameters](parameters.md).
Development history lives in `docs/history/`, not here. Files: `Bow/`
(`BowEngine`, `BowTables`, `BowControls`), `DSP/` (the laws both voices
share, spelled once: `OnePole`, `XorShift64`, `ModalString`; the C twin is
`CBowKernel/include/kernel_common.h` — one-pole forms, the xorshift step,
the zone matvecs, table copies), `Model/`, `Presets.swift`; Mac side
`TarabdaarCore/StringVoiceSource.swift`, `TarabdaarMac/SarangiStore.swift`,
`StringParamStore.swift`, `Views/StringsView.swift`.

## Signal path

```
touch / MIDI ► BowControlMapper ► bow_live_poly gut strings on ONE bridge (one‑sample −Z·V load)
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
- **Pitch.** The string loop is one period long: the nut‑side read is
  `β·T − bowWidth` and the bridge‑side read the rest, with the hair ribbon
  (`bow_width_smp`, kernel samples) between the two contacts. The nut read
  cannot go under 2 samples; when β·T is shorter than the ribbon + 2 the
  excess comes off the bridge‑side read instead (the bow moves toward the
  bridge until the hair clears the finger), so the loop stays one period
  to the top of the range — bit‑exact below that corner. The loop filters
  (nut/bridge one‑poles, dispersion allpass, interpolation) add a fixed
  phase delay of ≈2.4 samples; `pitch_cents`/`pitch_knots_oct` in
  `bowed_string.json` pre‑correct the requested f0 for it (fitted knots to
  C6, then a cents ∝ f0 fit measured to C8 — a fixed delay in samples is a
  growing error in cents). A held table above the last knot was the
  audible "flat above B6".
- **Rates.** Kernel 96 kHz → 48 kHz; `StringVoiceSource` is an
  `AVAudioSourceNode` at `Config.sampleRate` 48 kHz — the whole graph's
  rate, no converter. Touches arrive from the link
  ([MIDI & Audio](midi-and-audio.md)).

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
  axes. **Initialization:** `JawariEquilibrium` solves each row's continuous
  force balance with a checked residual; failed solves retain the legacy wrap.
  Before the first render, `bow_jt_init.c` can prepare a stationary state of
  the existing split integrator for a neutral, full-step bank. It commits only
  if every row converges; moved bones and deep-contact states use the fallback.
  `buildEngine` settles with a silent control snapshot, preserving held touches
  for publication. A prepared bank receives one 4096-frame warmup block;
  fallback banks receive at least five with 50 ms damping. The physical kernel
  state is preserved while the discarded setup transient is cleared from the
  output filters and room. Natural-decay verification blocks must stay below
  −100 dBFS in both channels and their sum before publication; a bounded failure
  returns no replacement engine. `RebuildCostTests` checks the −80 dBFS publish
  contract across tonics and bone positions. Setup remains outside
  `BowEngine.init`, so direct kernel fixtures can still start at t = 0.
- **In‑place push.** A `.live`/`.hybrid` edit recomputes the kernel's scalar
  vector and hands it to `BowEngine.setLiveParams` — no reset, no pre‑roll,
  no crossfade (`inPlaceKeys`; see [Sound Design](sound-design.md)).
- **The scalar block** is `bow_scalars_t`, a NAMED C struct of 52 doubles
  declared (and documented field by field) in `bow_kernel.h`.
  `BowTables.buildOpenString` fills it BY NAME; `bow_poly_init` takes a
  pointer to it and `bow_poly_set_scalars` replaces the whole block on a
  live state, both through the one `poly_load_scalars` helper. There is no
  positional vector and no optional tail — every field is always present, so
  adding a scalar is one field plus one assignment, with nothing to
  renumber. `BowEngine`'s live ramp walks the struct as
  `sizeof(bow_scalars_t) / sizeof(double)` contiguous doubles (declaration
  order), which is the only place the layout is relied on.
- **Overrides.** The bundled artifact is read‑only; a Parameters‑tab edit
  rests in the ONE value store (`AppController.paramValues`) and reaches
  the engine as `StringParamStore`'s override dict applied over
  `bowed_string.json` at build time; one that lands on the artifact value
  is dropped (*dirty* = differs from default).
  Registry defaults for keys the artifact does not carry must equal the
  engine fallbacks (`ParamUnificationTests`).
- **Controls — `BowControlMapper`**, long‑lived across rebuilds: the 0…1
  axes (expression · press · position · tilt · vibrato) plus
  `touchOn`/`touchGlide`/`touchOff`/`touchAllOff`, every slot keyed by its
  u16 touch id (`TouchMapperTests`). The Mac pads hold the expression axis
  at the commanded value 0.251 unless a control changes it.
- **Bow-axis transforms.** Expression, pressure and position each pass through
  an editable piecewise-linear curve before the bow law. The Transforms tab
  edits arbitrary input/output points in 0…1 (up to 64), with fixed input
  endpoints, add/remove controls, Identity and Factory curve actions.
  Interpolation never overshoots adjacent points. Curves apply after
  gesture/composite mapping and per-touch expression scaling, at the bow law's
  control rate after raw-axis interpolation. Prepared curves are staged under
  the engine lock and adopted at a render chunk boundary without remounting
  held strings; they survive ordinary live edits and engine rebuilds.
  Presets carry a structured `bowAxisCurves` section. Older fixed-band values
  migrate to points at their original inputs, inheriting missing values from
  the factory curve. The artifact retains its fitted band samples; their
  interpolation preserves the factory sound bit-for-bit. Missing maps in
  bare DSP parameters are identity. Identity bypasses arithmetic exactly;
  pressure and position ship as identity.
- **Telemetry.** `StringVoiceSource.jtStats()` (async‑web dropped‑job /
  flat‑fill counters) and `renderStats()` (callbacks timed against 90 % of
  budget — a LATE callback glitches at the device even when the render
  itself is clean); `AppController`'s 5 s watchdog logs "jt OVERLOAD" /
  "render OVERRUN" when they grow. Check these first for clicking.
- **Body (⌘0) tab** draws the formula body's frequency response as
  built into the running engine (`BowEngine.bodyResponse`, from the
  engine's own tables — radiation, at‑the‑ear, admittance, modes);
  display‑only, computed on rebuild ([UI Layout](ui-layout.md)).
- **Scope (⌘8) and Taraf (⌘9) tabs** draw display‑only kernel meters:
  `bow_poly_scope_arm` turns on, per jt row, a peak envelope of its radiated
  (post‑cap) sample and per‑mode peak envelopes of the first 16 modes' |p_k|
  (worker‑owned, telemetry‑grade racy reads); `bow_poly_scope_jt` reads them
  with the row's current f0 and asleep flag, `bow_poly_scope_slots` each
  played string's ring envelope. Armed only while a tab shows; the armed
  render is byte‑identical. Drawing: [UI Layout](ui-layout.md).

## Articulation and sustain

- **Attack sharpness** (`bow_attack_sharpness`, 0…1, default **0**) is a
  direct live binding target. Each new string captures its current value:
  0 chooses the gentle draw, 1 chooses the sharp attack. Bind it to Strike,
  Joy-Con Accel or any other dimension; it has no automatic pressure or
  accelerometer contribution. Updates require no rebuild and affect the
  next onset, leaving held notes and releases unchanged.
- **Finite bow trajectories.** The gentle draw is **180 ms**, the sharp draw
  **5 ms**, and the sharp force rise **3 ms**. Intermediate strikes interpolate
  these times logarithmically; gentle force follows the gentle draw time.
  Placement defaults to **0 ms**, beginning the draw immediately. A nonzero
  placement holds velocity before a gentle draw and shortens toward zero as
  sharpness increases. Zero placement does not bypass articulation. Contact
  smoothing runs from 25 ms for a gentle onset toward the sharp force-rise time
  (capped at 25 ms); release always retains its 25 ms lift.
- **Attack color comes from the bow.** A sharp onset starts **60% closer to the
  bridge** (`bow_attack_beta`, with β bounded below at 0.04) and with an **8 dB
  speed boost** (`bow_attack_speed_db`). Both excursions scale with sharpness
  and decay over `bow_attack_bite_ms` **60 ms**, becoming exactly zero after
  eight time constants. The force wedge follows that position and speed.
  Attack bite **0.5** adds a short force overshoot, bounded by the force cap
  before subsequent drift/grip adjustments. These controls return to the same
  sustained bow; they do not change the output EQ or add an output-level attack.
- **Force-change grain** (`bow_tnoise`, shipped **2**) uses the two-contact
  kernel's existing per-string force-change envelope, multiplied by local slip
  and injected at the bow contact. Rapid force changes excite more grain than
  gradual ones; pressure gestures and release can also excite it. Zero disables
  this grain path. The steady contact-noise law and friction solver remain.
  Articulation acts on fresh attacks only; finger glides never re‑articulate.
  The onset sharpness is captured per note; changing the binding or
  pressure while a touch is held does not recapture it. `BowAttackTests` pins this and the finite-draw,
  zero-placement, unchanged-sustain and zero-color contracts.
- **Liveness layer:** a post‑onset settle (`bow_settle_db`; `bow_settle_sharp`
  exempts a sharp attack, depth × (1 − key × sharpness)), three seeded
  Ornstein–Uhlenbeck walks (`bow_drift_*`) for slow pitch/level/timbre wander,
  and a glide‑rate bow lightening (`bow_glide_dip_db`) that articulates meend.
- **Register damping** (`bow_loss_reg`, shipped 0.7): the nut/bridge/gut loss
  corners scale by (f0/tonic)^γ below the tonic only, so low notes are not
  relatively brighter and hollower than the tonic.
- **Regime grip** (`bow_grip_*`): a low note bowed sul tasto with a light
  bow can lock on an OVERTONE instead of Helmholtz motion — the string
  vibrates on H3/H4 with the fundamental 20–40 dB down (thin, buzzy), and
  which attractor it lands in depends on the onset history, so the same
  note comes out right or wrong from one stroke to the next. The kernel
  measures the regime per string (**fundamental dominance**: Q = 3 bands
  track f0, 2f0, 3f0 and 4f0 on the bridge-side wave; dominance = P1 over
  the strongest of P2…P4, ~4 periods. Helmholtz motion keeps H1 the
  strongest low partial at any pitch or force, ≈ 2.5–3.5; an overtone lock
  reads 0.02–0.5. The plain fundamental SHARE P1/Ptotal is exported beside
  it but is NOT the criterion — a healthy pressed note at 494 Hz shares
  only ≈ 0.35, an overtone-locked low note ≈ 0.2; `bow_poly_regime_slot`,
  with slip-onset counters beside it), and `BowControlFilter` corrects the
  BOW, not the string: once the attack window (`bow_grip_wait_ms`) has
  passed and the dominance has stayed under `bow_grip_thresh` for
  `bow_grip_confirm_ms` (a one-window dip in an onset transient is not a
  lock), the bow moves `bow_grip_beta` × (1 − press) of its distance toward
  the bridge (off the quarter-point node a β ≈ 0.22 bow sits on; the
  Schelleng wedge raises the force with it, so a heavy bow is moved less —
  pulled to the bridge it chokes) and slows by `bow_grip_v_db`, in
  `bow_grip_ms`; it releases over
  `bow_grip_rel_ms` once the dominance has read above `bow_grip_release`
  for `bow_grip_hold_ms`, and a note that collapses again after a release
  latches its second grip for the note.
  Measured on the shipped physics: extra force alone (`bow_grip_db`) makes
  the overtone lock STRONGER, which is why the shipped grip is position +
  speed with the force lever at 0. All three levers at 0 = the grip never
  runs (bit-exact); a captured note is never touched
  (`ByteNullContractTests`). The Scope tab prints each held string's
  dominance and a "grip" tag while the correction is in force.
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

Every `StringSpec` carries a bridge `set` and a pitch-source `followsScale`.
The **raga bank** uses the two-direction physical contact model below. Its
twelve default Pilu strings cover all nine main-octave scale notes plus
**low Sa, low Pa and upper Sa**. Regeneration reserves those anchors (Pa is
the scale degree nearest 3/2), then fills from the main octave and upper/lower
repeats, up to twelve distinct pitches within the supported octave range.
Duplicate degrees fold under the usual one-pitch-per-bridge rule.

The **chromatic bank** uses the original modal-jawari model. It contains both
former layouts: the scale choir and the 15 fixed-JI semitone strings. Shared
pitches merge, keeping the stronger row and remapping drone/strum identities.
The default Pilu bank therefore has 27 chromatic rows plus twelve raga rows.
Migrated scale rows keep their scale-degree references, levels, decay and
identities; fixed-grid rows keep their semitone references. Both follow the
tonic. Newly added chromatic rows use the fixed JI grid. The Strings table
chooses the appropriate pitch picker for each row's pitch source.

### Parameter ownership

Parameters and binding menus use three peer groups. Existing active parameter
keys are preserved; the historical `bow_jt_` prefix does not indicate a bank.

| UI group | Parameters | Effect |
| --- | --- | --- |
| **Taraf · Shared** | `bow_jt_drive`, `bow_jt_drive_norm`, `bow_jt_sel`, `bow_jt_damp`, `bow_jt_lp`, `bow_jt_hp`, `bow_jt_body`, `bow_jt_couple`, `bow_jt_cap`, `bow_jt_cap_ratio`, `ctl_taraf_adapt` | Both banks: excitation/compensation, recruitment, extra damping, output tone/body, physical feedback, voice cap and performance adaptation. |
| **Taraf · Raga** | `bow_jt_gain`, `bow_jt_norm`, `bow_jt_dual_mm`, `bow_jt_bow_bloom`, `bow_jt_dual_lp`, `bow_jt_dual_select`, `bow_jt_sav` | Raga level/normalization, reference pluck displacement, bow bloom, radiation cleanup/selectivity and contact solver. |
| **Taraf · Chromatic** | `bow_jtc_gain`, `bow_jtc_norm`, `bow_jtc_evolve`; `bow_jt_ev_reg`, `bow_jt_apex`, `bow_jt_zone`, `bow_jt_radius`, `bow_jt_alpha`, `bow_jt_hcb`, `bow_jt_fhf`, `bow_jt_bst`; `bow_jt_pluck`, `bow_jt_pluck_decay_ms`, `bow_jt_pulse`, `bow_jt_pulse_attack_ms`, `bow_jt_pulse_decay_ms` | Chromatic level/normalization, evolution/register, contact geometry/loss and force-burst/pulse articulation. The melody follower shares this bank's level, normalization, geometry and evolution. |

Each bank has its own **level** and **decay normalization**, with matching ranges and
apply timing. Either level can reach zero while the other bank keeps ringing.
Banked tables keep the common output carrier at 0.3 and scale each row by its
bank's level / 0.3, preserving the default arithmetic and the existing 40 ms
output slews. The levels multiply audio after the physical return and before
the voice cap; they never enter contact coefficients or feedback normalization.
There is no gain ramp shared between the level knobs. The
unbanked table-builder path remains available for isolated kernel fixtures.
Coupling stays a shared physical loop; contact or excitation changes in either
bank can change the energy reaching the other, while output level edits leave
that interaction unchanged. There is no separate taraf
master knob: `bow_gain` controls the String engine’s voice, taraf and room, while `bow_bal` controls
the voice/taraf balance.

Feedback normalization uses physical row weights. Turning both banks down
cannot increase feedback gain; muting radiation leaves bridge interaction intact.

Raga contact geometry, evolution and natural loss remain the fitted physical
profile; the adjustable legacy geometry affects the chromatic model.
`bow_jt_evolve` is retained only in the legacy engine interface, not offered
as an app parameter: physical raga rows ignore its bone offset, and chromatic
rows (including the follower) use `bow_jtc_evolve`. Saved bindings to the
inactive key are pruned by the existing unknown-target handling.

Per-string pitch, gain, t60 and enable controls live in Strings. Raga t60
participates in level normalization; the physical raga decay itself is fitted.
The shared extra-damping control changes both models' decay. Tanpura/Sitar
injection controls and the Voice → Taraf / Taraf FX inserts affect both banks.

**Raga bow bloom** (`bow_jt_bow_bloom`, live, 0–1, default 1) lets a held bow
charge the physical raga strings and then recede into their natural jawari
ring. A 20 ms incoming-power follower feeds a 2.1 s adaptation memory;
new energy enters strongly, while steady forcing settles to 3% at full bloom.
The memory recovers over 60 ms when input falls, so a gap or renewed bow
energy restores the response. The slow adaptation lets the harmonic balance
unfold over several seconds. This produces one harmonic bloom that settles
during a steady hold, with a quieter raga sustain. It does not repeat plucks
or move pitch. The amount slews over 40 ms; zero bypasses the envelope exactly.
The envelope changes only bridge excitation, including injected plucked-voice
energy and coupled return. Direct row plucks from an uncoupled, silent bridge
remain byte-identical. Chromatic rows, contact geometry and radiation filters
are unchanged; the physical solver accounts for the shaped force as its input.

Kernel order is raga selection, chromatic selection, then the legacy melody
follower. Each selected raga row owns a separate contact solver; a failed
physical-row build rejects the replacement engine instead of substituting
the legacy model. The pluck strip addresses kernel rows directly and marks
all physical raga rows orange. Drone mappings carry nominal Hz **and bridge**,
so equal pitches on different bridges remain independently addressable.

### Raga computation and radiation

Each raga row retains 40 modes in each transverse direction and 24 contact
sites. The discrete contact clock is 96 kHz at the 561 Hz reference pitch;
both contact and radiation clocks advance proportionally to row pitch.
The fixed reference-coordinate contact loss is 3 s/m. Clock conversion,
plectrum motion, modal damping and the physical feedback path are independent
of radiation filtering.

At construction, `bow_contact_compress` factors the actual contact geometry
through at most six components using pivoted, reorthogonalized Gram-Schmidt.
It accepts the factors only when their measured relative Frobenius error is
at most 1e-10 and projection work decreases; other geometries retain the dense
path unchanged. Displacement projection uses the factors, while compliance,
modal force and plectrum reaction use the same reconstructed geometry to
preserve reciprocal contact work. All vibration modes and nonlinear contact
sites remain. Compression cannot be enabled after excitation or rendering
starts. `ContactCompressionTests` compares dense/compressed motion and energy
balance at both 96 and 192 kHz and pins exact fallback for unsuitable geometry.

`bow_contact.c` stores transposed compliance matrices alongside the Newton
matrices. Residual and correction updates run across contiguous contact sites,
preserving the force accumulation order at each site. Live rows disable the
diagnostic energy ledger, which otherwise reevaluates conservative contact
forces on every step. The actual dissipative contact solve and its convergence
diagnostics still run in full. Standalone contact solvers retain energy auditing
by default; disabling it is permanent and reports unavailable energy fields as
NaN. `ContactAuditTests` pins identical motion, reaction and solve diagnostics.

The complete 2049-tap fitted radiation response runs through
`bow_radiation.c`: the first 64 taps are direct, and the remaining taps use
64-sample partitions with 128-point double-precision FFTs. The direct section
provides the time needed to compute the tail, adding **no latency**. Coefficients,
phase and tails remain intact. Exactly zero input partitions skip their FFT and
spectral products; existing overlap drains before output becomes exact zero.
All storage and FFT plans are allocated at row construction and owned by that
row's worker. Apple builds use Accelerate; the portable transform follows the
same convolution law. `RadiationTests` compares against direct convolution
across partition boundaries, ring wrap, silence and restart.

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

A row radiates the **contact force it exerts on its bone plus the termination
force at its pin** — the two loads a real bridge actually feels. The contact
half sums the contact solve's zone force densities × spacing, scaled per row
by `JtTables.rowForceScale` = gout·π·wj/(mu·L·wd1), so a unit mode‑1 ring maps
to the fitted level law. The pin half is the string's own linear pull,
T·∂u/∂x|L: with the modal basis φ_k = amp2·sin(kπx/L) and T = mu·(L·wd1/π)²
that is T·amp2·(π/L)·Σ(−1)^k·k·q_k, which through the same force→radiated
match collapses to `JtTables.rowPinScale` = gout·amp2·wd1 per row — comb‑free
and flat in k, where the contact force is the buzz (∝ penetration^1.3, so a
barely grazing string barely speaks). Both per‑row scales ride the load ABI
(`radScale`, `pinScale`); the two terms are summed **before** the ~8 Hz DC
blocker (primed to the first sample), which takes the static wrap's offset on
the pin sum. There is no mix — the sum is what a row radiates; `pinScale`
just glides on the same ~40 ms law as `radScale` so a coefficient reload
does not step. Bank output levels are applied separately after this physical pickup.
Every mode radiates flat in those units, so the Taraf tab's modal‑energy
spectrum is also the radiated one. The pulse train carries a large
low‑frequency swing, so each row's radiation scale glides ~40 ms inside
the kernel (`jtRadScaleCur`; a stepped coefficient scale would
splash impulses ~10× the signal, `ZipperTests`' fast flick), both bit‑null
when constant; an instant bone move radiates a real thump, which the 40 ms
bone slew keeps out of tilt sweeps. The 0.90 L velocity pickup is not
present — see `docs/history/`.

### Where the drive enters

The played string's bridge force enters each row at the fitted **0.90 L tap**
(`phiD` = gdrv·amp2·sin(kπ·0.9)/mu) — the one drive shape, and the shape the
gate's per‑row wake bound is metered on. The force is scaled by ONE scalar,
**`bow_jt_drive`** (`.live`), before it reaches any row: the graze operating
point. It is not baked into the tables — the kernel holds it as `jtDrv` and
slews it ~40 ms at the jt tick (`bow_poly_jt_set_drive`), so a bound axis
sweeps the operating point without a strum, and the gate's wake bound sees
the scaled force, so raising the drive wakes sleeping rows by itself. A table
reload never snaps an armed drive back to the artifact value.

**Level compensation (`bow_jt_drive_norm`).** The drive is the
`tp_pluck_drive` law on a continuous web: `dn = jtDrv / jtDrvRef` (the
build's drive, the level reference) scales everything that enters a row —
the bridge force, the drone drive — and each row's DC‑blocked output is
multiplied by `comp` ahead of the coupling pickup (so the two‑way loop gain
is drive‑invariant and the `TarafCoupleTests` bound holds at any drive) and
of the cap (so it meters what is heard); the quiescence floor divides by it
so rows sleep at the same audible level. In steady state
`comp = dn^-norm`: norm 0 is the raw physics (a 46 dB level swing over the
registry range), 1 is constant loudness (flat within ~1.5 dB — the residual
is the contact's own drain at high drive), the default 0.7 leaves the top
~13 dB louder than the bottom.

`comp` is NOT the instantaneous drive: it is the drive averaged over the
energy the web holds. `jt_drive_comp_step` runs two power trackers with the
web's own ~0.7 s decay, one fed by the raw bridge force (plus the drone
envelopes) and one by the drive‑scaled force, and
`comp = (Eref/Eact)^(norm/2)`. Both see the same history, so a sweep during
ring‑out leaves the ratio — and the ring's level — where it was until new
energy arrives, and a fresh note after a sweep outweighs the faded old
content within a few ticks and lands on its own compensation. Measured: a
0.3 → 0.001 slam 0.3 s into a ring‑out moves the ring by < 2.5 dB over the
next 1.2 s. A slam UP during ring‑out does raise the ring — the played
string is still sounding and the higher drive charges the web harder with
it; that is new energy, compensated by the norm like any other. `dn` is
exactly 1.0 at the build value, the two trackers stay bit‑identical and
`comp` returns 1.0 without a `pow`, so the resting instrument is bit‑exact.

### Two‑way coupling (`bow_jt_couple`)

The drive is ONE‑WAY: the played string's bridge force charges every row and
never feels one back. On the instrument the rows sit on the SAME bridge, so
their own bridge forces load it too — energy returns to the played string,
and the rows feel each other through the shared termination.

`bow_jt_couple` (0…1, `.live`, **0 = byte‑exact**) closes that loop. Each row
already computes its whole bridge load in the tick: `radScale`·fsum (contact)
+ `pinScale`·Σ(−1)^k·k·q_k (termination), **DC‑blocked** — the same `fr − lp`
it radiates. Both halves carry the SAME force→radiated factor
gout·π/(mu·L·wd1), so ONE per‑row reciprocal, `JtTables.rowCplScale` =
mu·L·wd1/(gout·π), turns that back into NEWTONS. The rows' summed force joins
the played strings' bridge force `F` **before** the body solve, so it (a)
moves the bridge every played string takes back through its kret return, (b)
radiates through the body, and (c) lands in the drive record, which is what
charges every row on the NEXT tick — that last part is the row‑to‑row
exchange: the web feeds itself through the bridge.

**The pickup must be DC‑BLOCKED, and that was the whole never‑silent bug.**
The raw per‑row load carries the row's static wrap preload as a constant
term, so the first cut of this knob parked a DC force on the played strings'
bridge — which then fed the drive record and charged every row with it. It
self‑excited from silence: a web nobody played, gate disarmed, settled to a
tail RMS of **2.6e‑1** at the top of the range (DC‑blocked: **5.7e‑3**, all
of it the wrap's contact micro limit‑cycle, DC offset 1.3e‑5 → 1.0e‑6). With
the gate armed and a real note it read as the instrument never going quiet: a
bowed Sa's 12 s ring parked at a constant **−42 dBFS with 0 of 34 rows
asleep**. Blocked, the same ring reads −49 / −65 / −87 dBFS at 3 / 5 / 7 s and
then truncates as the gate closes, **34 of 34 asleep** — the uncoupled ring's
own curve (−49 / −66 / −87). A row the gate puts to sleep also FADES its last
returned value out on the blocker's own rate instead of stepping to 0 (a step
on the shared bridge strums every other row); with the DC term gone that step
is small, so this is continuity insurance, not the fix.

**The bank normalization.** The kernel SUMS the rows into one return, so the
loop gain scales with how many rows the document holds and how loud they are —
the shipped Pilu bank is 34 rows. `rowCplScale` is therefore divided by the
bank's total row gain **Σ gout**, and one knob position means one loop gain
whatever the bank. Without it the knob's stable range was a property of the
document, which is why real playing diverged at ~0.04 where a single‑note
bench sweep said 0.2.

**The range is 0…1 of a MEASURED safe range** (`BowEngine.jtCoupleFullScale`
= 0.4 kernel gain — half the divergence gain). Measured on the HEAVY case,
because one note is far more forgiving than a chord: shipped Pilu bank, serial
jt, **Sa + Pa + Sa′ at full expression** held 1 s then a 4 s ring, output trim pulled
60 dB so the safety limiter cannot mask growth. The ring's fall from +1 s to
+4 s: **31 dB** uncoupled, 31 / 27 / 28 / 18 / 23 dB at 0.2 / 0.3 / 0.4 / 0.5
/ 0.6 — and at **0.8** it stops decaying and GROWS +6 dB through the last
second. Above that it only flattens (2.0 and up hold a plateau for the whole
ring; the kernel clamps the gain at 4). So 0.8 is the divergence gain, full
scale is 0.4, and the knob's top still decays 28 dB over that ring.

Not baked, deliberately: this is a sound‑design lever and it is judged by
ear. It is LOUD well before the top — the web bloom is the point — so pull
`bow_jt_gain` / `bow_bal` / `bow_jt_cap` with it.

### Chromatic evolution and register

- **`bow_jtc_evolve`** (0…1, live, default 0.5) moves the chromatic rows'
  grazing margin from ×4 at zero to ×¼ at one. Pressed contact holds the
  harmonics relatively still; the open grazing band encourages the upward
  cascade. Row bone offsets slew over about 40 ms, with a cumulative 0.005
  control dead band. The melody follower uses the same chromatic setting.
- **`bow_jt_ev_reg`** (−1…1, live, default zero) offsets chromatic evolution
  by octave from the tonic: `clamp(e + reg * log2(tonic / rowHz), 0, 1)`.
  Positive opens lower rows and presses higher rows; negative reverses it.
  `BowEngine.pushJtEvolveOffsets` subtracts the legacy global lift so each
  row reaches its own chromatic target. Neither control moves physical raga
  contact geometry.
- **Body mix** `bow_jt_body` (0…1, `.live`, 0 = byte‑exact) blends the
  radiated jt sum through the SAME formula‑body radiation bank the played
  strings use, before the tone LP/HP (`bow_poly_jt_set_body`, slewed ~30 ms)
  — otherwise only the melody carries the body formants and the taraf reads
  as a separate chorus.

### Finite row plucks and evolution pulses

The chromatic taraf supports an optional plucked articulation, using its
modal rows, contact solver, drive tap and bridge-force radiation. It does not
select the separate Sitar voice. With sympathetic drones selected,
`bow_jt_pluck` above zero makes a drone press excite just its mapped row with
a decaying sine force at that row's fundamental. There is no held drive or
kin spread for that press. `bow_jt_pluck_decay_ms` sets the force envelope's
time constant; it ends after twelve time constants. The burst starts at zero
force and preserves the string's existing modal history. Zero restores the
existing drone swell exactly. `BowEngine.pluckTaraf(row:strength:)` exposes
the same onset without holding a drone.

`bow_jt_pulse` adds a row-local evolution excursion on either kind of onset:
amount 1 aims at evolution 1; smaller amounts cover that fraction of the
distance from the row's current evolution to 1. Its evolution-space amplitude
decays exponentially over `bow_jt_pulse_decay_ms`; the resulting bone lift
is smoothed by `bow_jt_pulse_attack_ms`. The pulse target becomes exactly zero
after eight decay constants, then its residual lift settles to zero. This
is separate from the existing 40 ms smoothing of ordinary evolution edits.
The pulse respects each row's chromatic/register offset and cannot open the
bone beyond the existing evolution-1 endpoint. A row already at 1 has no
available upward excursion.

These five controls are `.live` routes with **onset** timing and per-note
state. Each onset captures its settings; subsequent edits affect the next
onset. Retriggering renews the envelope without resetting the ringing string
or stepping its current bone lift. Atomic per-row mailboxes deliver complete
events to the row worker; requests arriving before the next tick coalesce
to the latest event. Active envelopes wake the row and prevent premature
quiescence. No allocation, lock or registry lookup occurs in the row tick.
The two amount controls default to zero; the default sound is byte-identical.

The excitation supplies energy; evolution controls how contact redistributes
it. Moving an uncharged bone mostly produces a low-frequency transient.
`TarafPulseTests` pins disabled-onset parity, row isolation, captured settings,
retriggering and serial/worker replay.

### Shared two-direction raga bank

The realtime implementation mounts the approved two-direction physical model on every selected raga row.
The retired `bow_jt_dual_row` selector is ignored by the app; only isolated
research fixtures retain it. `bow_jt_dual_mm` captures 0–1 reference mm of
plectrum displacement at a drone press or explicit pluck, default 0.5. At
nominal pitch ratio `r = frequency/561`, actual displacement is the control
value divided by `r`. The stronger range remains available and can produce
rougher contact motion. Saved control values are retained. Bow drive and the plectrum
act on the same persistent state; plucking never resets the sympathetic ring.

Direct plucks have a separate radiation calibration. A nonzero plectrum event
raises that row's output toward `clamp(3.5 / sqrt(frequency/561), 1, 8)` times
its normal level, with a 4 ms smoothing time and a 2 s exponential return to
unity. Retriggers refresh the envelope smoothly. The lower register receives
more boost to match the chromatic bank's stronger low strings. This gain is
after radiation filtering and outside the physical return, so displacement,
contact timbre and bridge coupling retain their existing laws. Rows that have
not been plucked stay byte-identical; during a pluck's tail, the envelope acts
on that row's shared plucked/sympathetic radiation. Saved row gains, adaptation,
cap, balance and the final limiter still apply. `DualTarafTests` pins the direct
pluck render as well as its worker replay.

The row has 40 modes in each direction. Normal motion contacts the jawari;
parallel motion has its own loss and radiation. Jawari contact uses a fixed
loss coefficient of **3 s/m in reference coordinates**: its conservative force
is multiplied by `max(0, 1 + 3 * penetrationVelocity)`. The contact energy audit
includes this dissipation. This suppresses the metallic upper-frequency
fluctuations under sustained bowing while retaining the incoming bridge
spectrum and fitted radiation response. The plectrum captures current
position and velocity, pulls over `8/r` ms, then releases over `0.4/r` ms.
The contact solve accounts for that external work. The full approved 2049-tap
radiation fit runs on the model’s reference clock, outside feedback; only DC-blocked normal bridge force returns to the existing
bridge loop. With this backend installed, `bow_jt_couple` spans kernel gain
0–0.04; its ordinary 0–0.4 calibration does not apply to this less numerically
dissipative model. Above drive 0.03, this row's return is further multiplied
by 0.03/drive so raising excitation does not raise its calibrated loop-gain
product. Audio drive-level compensation stays outside this return pickup.
The delayed bridge loop remains empirically bounded.

The full-band bridge drive reaches the mechanical solve through the bow-bloom
envelope. **Two-direction hiss
cutoff (Hz)** (`bow_jt_dual_lp`, live, default 20000 / bypass) introduces harmonic
selection on each physical row's radiated audio after the fitted FIR. Above
its 1 kHz transition, a spectral peak must lie near **an integer multiple of
that row's nominal tuned frequency** to receive protection. A strong arbitrary
inharmonic peak cannot create its own passband. Frequencies below the transition
remain unchanged. The 2000–20000 Hz range ends in exact delayed bypass at 20000.
Tuning changes rebuild the row and its harmonic lattice together; the filter
does not track an unrelated incoming bowed note or retune the physical string.

**Two-direction filter selectivity** (`bow_jt_dual_select`, live, 0–1,
default 0) raises the peak-prominence threshold, narrows harmonic eligibility
and protected shoulders, and reduces the residual floor. Peak protection
rises over 6–9 dB prominence at zero, 12–15 dB at 0.5 and 18–21 dB at one.
A log-power parabolic estimate locates peaks between FFT bins. The allowed
distance from the nearest harmonic decreases from 12% to 2.5% of fundamental
spacing (with a minimum of 0.1 FFT bin); its inner half is flat and its outer
half tapers smoothly to rejection. Width does not grow with harmonic number.
Adjacent-bin protection falls from 1 to 0.5 and outer shoulders from 0.5 to
zero. The residual floor falls from −24 dB to −44 dB. Zero is the broadest
harmonic selection, not the previous arbitrary-peak filter. Selectivity is
available to the usual parameter/composite/tilt mappings and affects only
physical raga rows; it has no effect in bypass or on chromatic rows.

The worker-owned FFT uses Hann analysis/synthesis windows, a quarter-window
hop, and overlap-add. Window length is the smallest power of two from 2048 to
16384 giving at least eight FFT bins per fundamental spacing. This prevents
low-register harmonic and half-harmonic peaks from merging in the detector.
Smoothed power is compared with a 13-bin local median. Cutoff, selectivity
and bypass slew over 40 ms. Exact bypass maintains the delay ring but skips
spectral analysis. Re-enabling cleanup fills one overlap-add window before
fading it in, avoiding a transient hole in the sound. Harmonic eligibility is
checked before the local median to avoid analyzing rejected peaks. Filtered
and bypass audio share the same delay:

| Nominal row frequency | Filter delay |
| --- | ---: |
| 375 Hz and above | 21.33 ms |
| 187.5–375 Hz (excluding 375) | 42.67 ms |
| 93.75–187.5 Hz (excluding 187.5) | 85.33 ms |
| Supported rows below 93.75 Hz | 170.67 ms |

These delays add to the bank's 64 ms audio FIFO reserve and device/output-chain
latency. Apple builds use a preplanned Accelerate FFT; other platforms use
the portable radix-two implementation. Per-row storage is sized at build time
and padded to reduce cache conflicts. There are no render-time allocations,
locks or FFT planning. Neither
the modal state nor returned bridge force passes through the filter or its
delay; direct bowed output retains its timing.

The optional harmonic filter can also remove real inharmonic string partials.
The restored physical model does not require it for its calibrated pluck.
`DualTarafTests` pins rejection of equally strong half-harmonic tones,
retention of true harmonics across registers, tuning-dependent selection,
exact delayed bypass, and unchanged coupled motion.

The raga model retains the calibrated 561 Hz geometry/evolution/loss profile in
reference coordinates. Its physical geometry scales as `1/r`, linear density
as `1/r²`, and contact integration rate as `96000*r` Hz. The shared
`BOW_JT_DUAL_CONTACT_RATE` constant sets both the builder and worker clock.
Each pitch uses the same numerical timestep per reference period. Incoming
physical bridge force scales by `r²` in reference coordinates;
the normal reaction converts back to newtons with the reciprocal factor.

`bow_jt_sav` (**SAV contact solver**, Parameters → Taraf · Raga) selects the
physical raga rows' contact solver: **0 = Newton** (default), **1 = corrected
scalar auxiliary variable solver**. The setting is saved in presets and changes
through a crossfaded engine rebuild; existing presets without the key use Newton.
Chromatic rows and the follower retain their existing solver. Both options use
the same compressed geometry, 80 modes, 24 contact sites, clock and radiation.

The SAV option replaces Newton iterations with a closed-form positive contact
update. Its aggregate damping and passive cap on excess auxiliary contact energy
add a different loss profile: listening finds it slightly muddier than Newton.
It trades that small perceived loss of clarity for lower contact-solver CPU cost.
Its energy audit balances modal plus auxiliary energy, including the energy
removed by the cap; this is not an equivalence to Newton's physical contact law.
`ContactAuditTests` checks passivity and audit-independent motion;
`DualTarafTests` checks repeated excitation, release decay and serial/worker
replay without Newton iterations.

Newton solves only the currently active contact sites and caches fixed modal
and compliance coefficients. Its force evaluator reuses the already computed
contact potential for the derivative and for the exact old-endpoint estimate,
avoiding redundant power calls. Non-normal potentials retain the original
power evaluation. The force law and convergence checks are unchanged.

A 41-tap Kaiser FIR decimates the reference contact clock from 96 to 48 kHz
before the full radiation FIR. Precomputed, interpolated polyphase sinc filters
convert the incoming 96 kHz bridge force to the row clock and the radiated
sound/normal reaction back to 96 kHz. They do not repeat or hold audio samples.
The outgoing converter has 64 taps; the incoming converter limits bandwidth
to the actual contact Nyquist and expands to at most 512 taps at low pitches
to maintain its anti-alias transition. All tables and storage are
allocated before rendering. Added global damping keeps its wall-time rate.
The fitted radiation response moves with the model clock; this reproduces the
fitted response, not an independently measured pitch-dependent instrument body.

The per-row t60 field does not retune this profile. Chromatic rows retain the
ordinary geometry, evolution and excitation controls. Row gain, normalization
and recruitment still apply. The follower is excluded. Tuning changes rebuild
the model. Supported nominal range is approximately 71–1820 Hz, with the shared
taraf bus at 96 kHz. The 96 kHz contact integration rate deliberately changes
the earlier 192 kHz discrete trajectory. The production comparison covers
silence, a 0.5 mm pluck, a 1 mm retrigger and bridge drive over five pitches;
before/after audio and numerical differences accompany the implementation note.

Banks containing physical rows use a shared work queue: each worker claims a
whole row, advances it through the job, then claims another. A construction-time
estimate of physical clock ratio and legacy mode/contact counts places likely
expensive rows first; completion timing determines how the remaining work is
shared. Each row owns its output buffers, summed in row order after all workers
finish, so scheduling cannot change accumulation order or row state. Buffers
are allocated before rendering; the render path only resets the queue counter.
Legacy-only banks retain their contiguous worker partition. For multiple physical rows, the pool expands from its
configured size by one worker per additional physical row, up to the available
CPU cores minus two reserved for audio/control and the OS (and the kernel's
16-worker cap). Serial rendering stays serial.
Short device callbacks coalesce into 512-output-frame jobs for multiple
physical rows, or 256 for the single-row diagnostic. The audio FIFO primes
with six completed jobs: 64 ms for the bank, 32 ms for the diagnostic. This
reserve absorbs worker jitter; direct bowed output has no such delay. Mechanical
return uses those jobs without the audio FIFO reserve. With no physical rows,
the original worker partition and FIFO behavior remain unchanged.

`RealtimePerformanceTests` exercises the default twelve-raga/27-chromatic
bank with simultaneous plucks, three bowed notes and full coupling.
`DualTarafTests` pins independent row state, deterministic worker replay,
serial agreement and resizing the pool. Longer paced runs also measure
asynchronous dropped jobs and missing samples; callback timing alone does
not establish capacity.

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

### Performance pitch profile and adaptive gain

The Strings tab records **pitch occupancy** in 10-second, 60-second, and
whole-performance windows. `PerformancePitchProfile` integrates the Mac's
post-glide-queue touch onsets, pitch changes and releases using monotonic
timestamps under the audio engine's control-state lock. The iPad, Mac pad
and computer keyboard share this path. The configured strum chord and
drone buttons do not contribute evidence. This measures held pitch intent,
not microphone/audio energy: expression, attack sharpness and ringing tails
do not weight it. Simultaneous fingers share each elapsed second equally.

Pitches fold into one octave relative to the centralized tonic, in 120
bins (10 cents), including pitches between scale degrees. Each chart shows
percent of its window's occupied time; all three share an automatically
scaled vertical axis. Silence adds no evidence and ages the rolling
windows; the performance distribution stays. The recent windows use a
bounded ring of 100 ms buckets, with proportional overlap at the oldest
boundary (up to 100 ms boundary uncertainty). The cumulative window is
exact for the received pitch events. A 10 Hz Mac timer publishes the view
and pushes gains even while another tab is selected. Scale-ratio or tonic
changes reset the profile; label-only changes relabel it. Profiles are
session-only and do not save with presets.

**Reset & seed** clears the profile and starts a seed capture. A note held
within 30 cents of a scale degree for at least 180 ms marks that degree;
short passages through other degrees do not mark them. **Finish seed**
replaces the capture with an equal two-second prior per recognized degree
and clears the recent windows. Subsequent playing adds actual occupancy
to this prior. During capture, recognized degrees have equal gain targets.
**Reset performance** clears all evidence and returns the gain targets to
unity. On the Joy-Con, **Minus** starts/finishes seeding and **Capture**
resets the performance, so these actions work away from the Mac.

**Adaptation** is the registry's global live `ctl_taraf_adapt` amount
(0–1, default 0). For gain inference, occupied bins within 50 cents of the
nearest scale degree contribute to that degree, with octave wrap. Each
window's assigned evidence is normalized, then mixed: performance 60%,
60 seconds 25%, 10 seconds 15%. Empty windows contribute nothing. Dividing
by the strongest mixed score gives relative salience `s`; the full-depth
gain is `0.15 + 0.85 * sqrt(s)`. The amount interpolates from unity to this
gain. No evidence means unity. Thus prominent degrees keep their saved
level while incidental or absent degrees are attenuated, never boosted.
The same octave-folded profile applies to both bridges; chromatic pitches
outside the scale's 50-cent corridors take the 15% floor at full depth
when a learned profile exists.
The melody follower always stays at unity.

This is a **radiation multiplier**, not an edit to `StringSpec.gain`:
row enablement, row selection, tuning, decay, saved gains and bridge
coupling remain governed by the existing bank. Missing or disabled rows
are not created or enabled by seeding. `StringVoiceSource` caches the
profile and reapplies it by nominal row frequency on every engine rebuild.
`bow_poly_jt_profile_gains` publishes atomic targets; each row worker slews
toward its target over 250 ms, including while asleep, and multiplies the
DC-blocked radiation **after** the coupling pickup and per-row cap, before
scope metering. Unity skips the multiplication exactly; returning the
amount to zero restores saved levels smoothly. The experiment therefore
changes the audible balance of the web without changing its charging or
feedback dynamics. `PerformancePitchProfileTests` pins timing, silence,
octave folding and seed reset; `ByteNullContractTests` pins unity and an
active attenuation render.

### The quiescence gate (`bow_jt_gate`)

The web is a constant‑cost simulation — every row ticks its whole mode stack
whether ringing or silent (~350 % CPU idle without the gate). `bow_jt_gate` is
a **bp scalar, not a registry parameter**, always on at **40 dB** below the
graze apex (`bow_poly_jt_set_gate`; a 0 override in tests is the
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
  `bow_rev_*`) with the pads' flat expression median; kin notes (hard‑struck Sa/Pa)
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
  Regeneration is `RagaTuning.buildSpecs`: twelve scale pitches including the
  low Sa/Pa and upper Sa anchors. Surviving chromatic drone/strum mappings remain.
- **UI:** two tables — "Raga strings (side bridges)" and "Chromatic strings (main bridge)"
  with the legacy follower above the chromatic rows — each
  with +, Enable/Disable all, "Reset chromatic set" / "Regenerate from scale".
  Rows: Pitch (the scale's own labels — [Scales & Tuning](scales-and-tuning.md)),
  Octave (−2…+2), read‑only Hz, Gain / t60 / On. The Drone buttons section maps
  the buttons to rows on either bridge and holds the drone Voice picker (Tanpura default).
- **Persistence.** `SarangiStore` owns the editable `InstrumentState`; edits
  funnel into a debounced structural rebuild, the scale push rebuilds
  immediately. UserDefaults `tarabdaar.sarangiState.v8`, document schema 6. Documents older
  than schema 5 migrate both existing sets onto the chromatic bridge, retain
  their pitch sources and seed the twelve raga strings once. Schema-5 documents
  with the former factory raga pitch layout gain the missing rows; existing
  identities, levels, enable flags and drone/strum mappings survive. Custom
  pitch layouts remain as saved. Reopening schema 6 preserves edited rows. Stray retired keys
  decode away. Per‑string ratio/Hz inputs and manual
  raga tuning are not present — see `docs/history/`.

## Jawari modelling roadmap

Improvements proposed for the modal‑jawari rows, in the order worth doing.

1. **Radiate the bridge contact force — done.** Rows radiate the DC‑blocked
   contact force, unit‑matched per row (`rowForceScale`); every mode radiates
   flat and the Taraf tab's modal spectrum is the radiated one.
1b. **Add the termination (pin) force — done (baked in).** Every row's
   radiated sample is the bone contact force plus the pin force
   `rowPinScale`·Σ(−1)^k·k·q_k, ahead of the DC blocker; no knob (the
   `bow_jt_rad_pin` mix it shipped as was judged at 1 and folded in).
2. **Drive from the termination too — tried, rejected.** The pin's
   mode‑slope drive shape was built as a 0…1 morph and normalised two ways
   (mode‑1 match, then an energy match); by ear neither changed the
   character — it read as a taraf loudness knob and 0 sounded best.
   Removed: the knob, its `phiDT` table and its ABI are gone and the fitted
   0.90 L tap is the only drive (git history carries both measurements).
3. **Two‑way coupling among the rows — shipped as a KNOB, default off.**
   `bow_jt_couple` (above) feeds the rows' summed, DC‑blocked bridge force
   back into `F` one post‑pass block out (the deferred web forbids a literal
   one‑sample return). The first cut returned the UN‑blocked load, whose
   static‑wrap DC term made the instrument ring forever at a low strumming
   floor; blocked, normalized by the bank's Σ gout and expressed as 0…1 of
   half the measured divergence gain, the loop is bounded and the ring ends.
   Not baked: taking it means re‑fitting levels around it.
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

The guard set is deliberately small — about 77 tests. One render hash pins the
sound; everything else pins a contract that would otherwise break silently, a
stability bound, or a lockstep with a golden. No calibration numbers live in
tests; the sound is judged by ear.

- **`TarafRemovalParityTests`** (TarabdaarCore, gated) — the SHA‑256 of one
  rendered phrase pins the whole shipped signal path. Bless deliberately.
- **`ByteNullContractTests`** (SarangiKit) — every optional path armed at its
  resting value renders bit‑identically: scope meters, bus meter, FX rack,
  cap, balance, inject, damp, tilt, body, register, master gain, tone LP
  bypass. Add a case per new "0 = off" knob.
- **Kernel lockstep** (SarangiKit) — `BowedStringEngineTests` (formula body
  against the python reference, plus the shared `stringBP()`/`testTaraf`
  scaffold and a mapper‑driven string that speaks, answers press and
  releases), `BowPolyTests` (a max‑force chord stays bounded), `BowStereoTests`
  (fold‑down invariance), `TanpuraEngineTests` (exporter golden),
  `TouchMapperTests` (the allocation law on the one note path).
- **`TarafCoupleTests`** (TarabdaarCore, gated) — two‑way coupling: a
  resting web returns no bridge load, a coupled ring at the top of the range
  goes fully silent with every row asleep, and the heavy chord still decays
  there.
- **Realtime / rebuild / in‑place** (TarabdaarCore, gated; phase 2 serial in
  `tools/test-full.sh`) — `RealtimePerformanceTests`, `RebuildCostTests`,
  `ZipperTests`, `LiveParamPushTests`.
- **Model, wire and control** (fast) — `ParamUnificationTests`,
  `FXRackTests`, `PresetCodingTests`, `TarabRatioTests`, `TarabSetTests`,
  `DroneStringTests`, `ScaleLabelTests`, `ScalePresetTests`,
  `ControlCacheConcurrencyTests`, plus the link/pad/control suites
  (`TLPCodecTests`, `TarabLinkTests`, `LinkIngestTests`, `LinkRelayTests`,
  `GlideSequencerTests`, `StrumControllerTests`, `ControlAxisEvaluatorTests`,
  `JoyConMapperTests`, `FretLayoutTests`, `FretWarpTests`, `ChordBarTests`).

Run both packages' `swift test` and `tools/test-full.sh` before committing a
kernel, builder, parameter or levels change.
