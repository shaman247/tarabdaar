# Sitar Voice

The **Sitar** is Tarabdaar's third instrument: a plucked main voice built
from **the tanpura model plus the sarangi taraf** — a **scale-model role
ladder** of the fitted C3 tanpura string as the played voice
([tanpura-voice.md](tanpura-voice.md) has the engine, the pluck / bend /
release path and the string bank), with the String voice's modal-jawari web
(`bow_jt_*`, the Strings-tab rows) as its sympathetic strings.
Main-instrument only (Live tab → Instrument → Sitar; the **String bowed
voice stays the default**); the drone buttons keep their tanpura/sympathetic
choice. (Earlier fits and prototypes: not present — see `docs/history/`.)

## The physics: a geometrically scaled string

A real sitar note is a played string plus a sympathetic halo whose partials
*grow* during the note — hence the taraf coupling. The played string is the
fitted C3 tanpura string under a similarity transform: every length ÷s, same
materials (model space, s = f0/130.81):

| quantity | law | physical reading |
|---|---|---|
| R (gauge) | ÷s (MU ÷s²) | thinner strings up the register |
| B | constant | same relative geometry |
| t60 (every mode) | ÷s (`t600/s`, `t60hf/s`, `fhf·s`) | same materials → constant loss factor; the whole Q(f) curve shifts |
| apex, threadH, pol_rt | ÷s; bone radius ×s | the scaled jawari + jiva |
| kc | ×s^(α−1) | contact-force similarity (model-space ODE algebra) |
| pluck | ÷s | scaled displacement; the radiated velocity tap is scale-INVARIANT — no output compensation |
| hcB, alpha | invariant | material constants (hcB rides a velocity) |
| radiation per mode k | `radByMode[k] = |H_anchor(k·130.81)|` | the BODY scales too: each register string radiates through its own smaller body, pinning each mode INDEX to the anchor's weighting (one fixed body would sit ±12 dB off — its 392 Hz notch on h3 of every register) |

## The role ladder

Encoded with **no builder law switches**: per-third-octave roles (`s0`…`s11`,
centers 131→1661 Hz), each a real string spec with OPTIONAL per-role
physical fields (`t60hf, fhf, radius, kc, polRt, zoneW, mDyn, mCap` — nil
falls back to the artifact globals, so the tanpura's build is byte-identical
and its lockstep golden runs the nil path). Within a band the standard
tension laws apply (fretting that string); below the anchor, notes fret the
anchor string down (the ladder only ascends — scaling geometry UP is
stability-marginal).

### Simulability bounds (bench-set invariants)

- **Modal budget** (`mDyn` 43 kHz, `mCap` 160): each rung mounts every mode
  the 96 kHz sim can represent, capped at the anchor's count. Modes past the
  sim Nyquist alias in the rotation tables and DRAIN the cascade
  (−17…−23 dB on the upper rungs) — so ladder roles have **no mMin floor**;
  only the `mF` (21 kHz) band radiates (`phiO` zeroed above — the bend
  path's anti-alias law).
- **Zone law** (`zoneW` per rung): the modal blur 1/M must stay under the
  contact zone or the under-resolved contact **self-oscillates** (a
  sustained inharmonic ~11 kHz tone at 784 Hz; divergence at 880). Upper
  rungs (n7+) widen the normalized zone to 1.15/M(center) — the bridge does
  not shrink with the string. Don't widen past ~2/M at J 16: the thread
  footprint spatially aliases between zone nodes and the solve diverges.
- **The draw is a stability lever**: `rampCycles` 1.0 (the full-period law).
  A 0.6-cycle draw diverges rungs 9–11 outright; at these pitches a period
  is 1–2 ms, so the draw is not the attack lever anyway (`st_pluck_drive` is).
- **Mount cap 1.5 kHz** (`TanpuraVoiceSource.buildEngine`, sitar branch):
  above it the sim cannot hold enough sub-Nyquist modes to resolve the
  contact at any zone width (1760 Hz diverges zone-widened); a real sitar
  tops out ~1.4 kHz. Slots above the cap don't mount; a fret up there finds
  no slot within the 60 ¢ pluck tolerance.
- **Cascade thread compensation** (baked per rung): native-pitch mounting
  under-pumps the jawari cascade relative to the true scale model — the
  graze spans ~1/s as many samples per period, so the discrete contact
  converts less per pass (uncompensated, h6–h8 bloom +2…6 dB over 2 s
  where the source blooms +12 — a "ringing telephone" only
  envelope-over-time metrics see). The jiva thread therefore sits a
  bench-set fraction BELOW the similarity height per rung (0.8–1.0 —
  cliffy/bistable landscape, **never hand-interpolate**; re-run the
  exporter's cascade bench). Rungs 7+ saturate ~−40 dB rel regardless — the
  top register cannot cascade in this discretization (honest residual).

Known residuals: buzz pockets ~1.1–1.5 kHz (+1…+5 dB, stable extra rasp)
from the discretized contact up top; h2 ~7 dB hot at both registers (the
pluck-comb notch fills faster than a scaled tape's — the hcB velocity term).

## The artifact

`Packages/SarangiKit/Sources/SarangiKit/Resources/sitar_live.json`, written
by the fitting project's `scripts/export_sitar_live.py`: the 12-rung ladder
(thread comp baked per rung), `radByMode`, identity `bodyFIR`, per-note
`pitchCents`, `rampCycles` 1.0, and `gain` calibrated so a velocity-100
sitar pluck peaks like a tanpura drone pluck (`st_gain`'s registry default
equals it — keep the two in step). t60s sit at their similarity values
(halving them starves the cascade — the bloom modes lie below the shifted
`fhf` corner, so `t600` dominates their damping); played notes shorten via
`st_rel_t60`, attack via the live `st_pluck_drive`. **RECAL LAW applies
unchanged** — re-run the export after ANY physics change; never hand-edit.

Exporter traps: `tanpura_model.run_string` reads the `RAMP_S` seconds
global (set `rampCycles/f0` per note or you render with NO draw — a jangly
HF bed); autocorrelation halves an even-dominant spectrum (search near
nominal); numpy-on-Accelerate emits benign matmul FP warnings on every
`build_tables` call.

## Wiring

`AudioEngine.MainInstrument.sitar`; `sitarVoice` is a second `PluckedVoice`
— the SAME mount as the tanpura, parameterized by key prefix (`st_`/`tp_`)
and artifact — holding a `TanpuraVoiceSource` built with `artifact: .sitar`
(`Presets.sitarParams()`), third node into `symGain`, armed lazily on first
switch. One path serves both voices (`setPluckedVoiceEnabled` /
`rebuildPlucked` / `setPluckedParam`); the asymmetric parts are explicit
hooks — the tanpura's drone buttons and its debounced table-shaping rebuild
(`tp_jiva_comp` / `tp_cascade`). As a played voice each mount is a
`PlayedVoice` (`PlayedVoice.swift`): exact-pitch wire plucks, live bends
and `tp_rel_t60` releases, with its own touch→slot map (cleared when a
fresh engine publishes and on a main-instrument switch); the String bow
is the third `PlayedVoice`, so `AudioEngine`'s touch entry points speak one
protocol and never branch on the instrument. Scale/tonic changes rebuild the sitar's JI grid on
the tanpura's queue and debounce (`rebuildSitar` from
`AppController.syncTanpuraFromScale`). `TanpuraTables.buildNote` carries
per-note contact stiffness and transverse curvature
(`TanpuraNoteTables.kc` / `.polRt`) — the engine mounts those, not the
globals.

### The taraf coupling (`st_taraf`)

`bow_poly_jt_inject_write` / `bow_poly_jt_inject_gain` (CBowKernel): an SPSC
ring the sitar node's render callback fills with its mono output
(`TanpuraVoiceSource.setInjectSink` → `StringVoiceSource.jtInjectWrite`),
mixed into the **recorded jt drive** right before the drive-FX hook — the
voice→taraf insert and everything downstream (recruitment, gate, jt
tone/body/stereo) apply to the sitar's drive exactly as to the bow's. The
String voice stays armed and silent under sitar play, so the web is always
there to ring. The consumer drains the ring on dropped-drive blocks and
realigns after a gross backlog.

The ring is **shared with the tanpura** (`tp_taraf`): each foreign voice
scales its drive **at its own tap** (`TanpuraVoiceSource.setInjectGain`, on
the mono mixdown before the sink; gain 0 skips the tap — nothing is
written), and the kernel-side `bow_poly_jt_inject_gain` is the shared
**arm** (`AudioEngine.updateJtInjectArm`: 1.0 while either `st_taraf` or
`tp_taraf` is above 0, else 0; republished across bow rebuilds by
`StringVoiceSource`). Zero gain, an empty ring, or never calling the API is
**byte-null** — `TarafRemovalParityTests` passes untouched;
`ByteNullContractTests` pins the gain-0 kill. Calibration: `st_taraf`
**4.0** puts the post-release halo ~33 dB under the pluck — a sitar's
sympathetic zone; 1.0 is ~12 dB too subtle.

## Parameters

The **"Sitar" registry group** — all `.live`, via the `st_` prefix branch of
`setStringControlParam` → `setSitarParam`: `st_gain` (= the artifact trim),
`st_pluck_level`, `st_rel_t60` (0.15 s, `.perNote` — sitar lines
articulate), `st_pluck_touch` (default 1: fret runs re-pluck at new pitches;
isolation keeps the old tail at its own pitch), `st_poly` (4),
`st_pluck_drive` (1 = the fitted contact; **the attack-bite knob**),
`st_taraf` (above — a per-source tap gain; the String-side kernel gain is
the shared arm and survives bow rebuilds).

## Tests

Give the first sitar note a few seconds after the instrument switch (the
engine builds on arming). Plucks land only within 60 ¢ of a mounted JI slot.

Guards: `TanpuraEngineTests.testTablesLockstepGolden` (the nil-fields path
is byte-identical with the ladder fields in the schema),
`ByteNullContractTests` (inject gain 0 is bit-null), `TarafRemovalParityTests`
(the String render path with the ring unused is unchanged).
