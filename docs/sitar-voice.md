# Sitar Voice

The **Sitar** is Tarabdaar's third instrument (2026-08-19, physics
finalized 2026-08-20): a plucked main voice built from **the tanpura
model plus the sarangi taraf** — a **scale-model role ladder** of the
fitted C3 tanpura string as the played voice, with the String voice's
modal-jawari web (`bow_jt_*`, the Strings-tab rows) as its sympathetic
strings. Main-instrument only (Live tab → Instrument → Sitar; the
**String bowed voice stays the default played instrument**); the drone
buttons keep their tanpura/sympathetic choice.

(Unrelated to the StarpadDSP sitar deleted 2026-07-23 and to
`bow_twang`, the String voice's sitar-morph bridge fold.)

## How the sound was found — three versions in two days

- **v1** — a fresh bare-bone fit to `sitar1.wav`'s strong 561 Hz
  series. Rejected by ear ("synth-y trumpet, jangly metallic"; two
  causes found later: it threw away the jiva thread, and its fit
  renders had NO pluck draw — the RAMP_S trap below). What survives:
  sitar1 decomposes into a played string plus a sympathetic halo whose
  partials *grow* during the note — the reason the taraf coupling
  exists.
- **v2** — the varispeed prototype: the octave-grid cells
  `~/Desktop/sarangi/reports/tanpura_octave_grid/` C3→C4 and C3→C5
  (the fitted C3 tanpura pluck tape-transposed) were the ear-picked
  target, encoded as a `tapeRefF` flag switching builder laws.
  Right sound, wrong mechanism — varispeed is a transform, not an
  instrument.
- **v3 (current)** — the principled physics behind the same sound.

## The physics: varispeed IS a scale model

Tape-transposing a mechanical system by s is the similarity transform
of a **geometrically scaled instrument**: every length ÷s, same
materials. For the modal-contact string (model space, s = f0/130.81):

| quantity | law | physical reading |
|---|---|---|
| R (gauge) | ÷s (MU ÷s²) | thinner strings up the register |
| B | constant | same relative geometry |
| t60 (every mode) | ÷s (`t600/s`, `t60hf/s`, `fhf·s`) | same materials → constant loss factor; the whole Q(f) curve shifts |
| apex, threadH, pol_rt | ÷s; bone radius ×s | the scaled jawari + jiva |
| kc | ×s^(α−1) | contact-force similarity (model-space ODE algebra) |
| pluck | ÷s | scaled displacement; the radiated velocity tap is then scale-INVARIANT — no output compensation |
| hcB, alpha | invariant | material constants (hcB rides a velocity — v3 is truer to the tape than v2, which ran velocities ×s through it) |
| radiation per mode k | the anchor's mode-k weighting (`radByMode[k] = |H_anchor(k·130.81)|`) | the BODY scales too: each register string radiates through its own proportionally smaller body, which pins each mode INDEX to the same weighting. One fixed-frequency body was measured ±12 dB off the prototype on single harmonics — the anchor body's 392 Hz notch lands on h3 of every cell |

## The role ladder

Encoded with **no builder law switches**: per-third-octave roles
(`s0`…`s11`, centers 131→1661 Hz), each a real string spec carrying
new OPTIONAL per-role physical fields (`t60hf, fhf, radius, kc, polRt,
zoneW, mDyn, mCap` — nil falls back to the artifact globals, so the
tanpura's build is byte-identical; its lockstep golden passed
unchanged). Within a band the standard tension laws apply (physically:
fretting that string); below the anchor, notes fret the anchor string
down (the ladder only ascends — scaling geometry UP was
stability-marginal and the audited register is the upper one).

**Simulability bounds** (all bench-measured, 2026-08-20):

- **Modal budget** (`mDyn` 43 kHz, `mCap` 160): each rung mounts every
  mode the 96 kHz sim can represent, capped at the anchor's count (the
  varispeed source's energy budget). Modes past the sim Nyquist alias
  in the rotation tables and DRAIN the cascade (C5 uppers measured
  −17…−23 dB with them mounted) — so ladder roles have **no mMin
  floor**; only the `mF` (21 kHz) band radiates (`phiO` zeroed above —
  the same anti-alias law the bend path applies).
- **Zone law** (`zoneW` per rung): the modal blur 1/M must stay under
  the contact zone or the under-resolved contact **self-oscillates**
  (a sustained inharmonic ~11 kHz tone at 784 Hz; divergence at 880).
  Upper rungs (n7+) widen the normalized zone to 1.15/M(center) —
  physically the bridge does not shrink with the string. Don't widen
  past ~2/M at J 16: the thread footprint spatially aliases between
  zone nodes and the solve diverges.
- **The draw is a stability lever**: rampCycles 1.0 (the r29
  full-period law). A 0.6-cycle draw diverges rungs 9–11 outright —
  and at these pitches one period is 1–2 ms, so the draw was never the
  attack lever anyway.
- **Mount cap 1.5 kHz** (`TanpuraVoiceSource.buildEngine`, sitar
  branch): above it the sim cannot hold enough sub-Nyquist modes to
  resolve the contact at any zone width (1760 Hz diverges
  zone-widened). A real sitar tops out ~1.4 kHz. Grid slots above the
  cap simply don't mount; a fret up there finds no slot within the
  60 ¢ pluck tolerance.
- Buzz pockets ~1.1–1.5 kHz (harm/inharm +1…+5 dB — stable, extra
  rasp) are a known residual of the discretized contact up top.

- **Cascade thread compensation** (`THREAD_COMP` per rung,
  `sitar_cascade_bench.py`): native-pitch mounting under-pumps the
  jawari cascade vs the true varispeed — the graze event spans ~1/s as
  many samples per period, so the discrete contact converts less per
  pass (measured: the C3 source blooms h6–h8 by +12 dB over 2 s;
  uncompensated native mounts by only +2…6, leaving h1+h2 ringing
  alone — **the "ringing telephone" regression**, invisible to 0.16 s
  peak metrics; only envelope-over-time metrics see it). The lever is
  the register-comp one: the jiva thread sits a bench-set fraction
  BELOW the similarity height per rung (0.8–1.0 — the landscape is
  cliffy/bistable, never hand-interpolate; re-run the bench). Rungs 7+
  saturate ~−40 dB rel regardless — the top register cannot cascade in
  this discretization (honest residual).

Validation vs the prototype cells: per-harmonic peaks ≈ 4 dB rms at
C4/C5 (`sitar_varispeed.py`), and — the metric that actually matters —
the **envelope targets**: h6–h8 bloom (0.1→2 s) and settled level rel
h1, matched at the audited rungs (C4 +4.9/−8.9 vs cell +5.4/−13.3; C5
−0.0/−25.2 vs −7.3/−17.9, the best the top of the audited register
reaches).

## The artifact

`Packages/SarangiKit/Sources/SarangiKit/Resources/sitar_live.json`,
written by `~/Desktop/sarangi/scripts/export_sitar_live.py`: the
12-rung ladder (thread comp baked per rung), `radByMode`, identity
`bodyFIR`, per-note `pitchCents`, `gain` calibrated so a velocity-100
sitar pluck peaks like a tanpura drone pluck (`st_gain`'s registry
default is pinned equal, `SitarVoiceTests`). Voicing: **T60MUL is
back at 1.0** — halving the t60s starved the cascade (the bloom modes
sit below the shifted fhf corner, so t600 dominates their damping; the
2026-08-19 "less decay" voicing was half of the telephone). Played
notes still shorten via `st_rel_t60`; "more attack" is the **live
`st_pluck_drive` knob** (the short-draw route measured unstable).
**RECAL LAW applies unchanged** — re-run the export after ANY physics
change; never hand-edit.

Exporter traps: `tanpura_model.run_string` reads the `RAMP_S` seconds
global (set `rampCycles/f0` per note or you render with NO draw — the
jangly HF bed that helped sink v1); autocorrelation halves an
even-dominant spectrum (search near nominal); numpy-on-Accelerate
emits benign matmul FP warnings on every `build_tables` call.

## Wiring

- `AudioEngine.MainInstrument.sitar`; `sitarSource` is a second
  `TanpuraVoiceSource` built with `artifact: .sitar`
  (`Presets.sitarParams()`), third node into `symGain`, armed lazily
  on first switch. The whole tanpura main-instrument path is shared
  (pending plucks, exact-pitch bends, `tanpura_release` note-offs) via
  `pluckSourceLocked(inst)` / `pluckTrimsLocked(inst)`; slot maps are
  shared (one main instrument at a time, cleared on switch).
- Scale/tonic changes rebuild the sitar's JI grid on the tanpura's
  queue and debounce (`rebuildSitar` from
  `AppController.syncTanpuraFromScale`).
- `TanpuraTables.buildNote` carries per-note contact stiffness and
  transverse curvature in the tables (`TanpuraNoteTables.kc` /
  `.polRt`) — the engine mounts `t.kc` / `t.polRt`, not the globals.

### The taraf coupling (`st_taraf`)

`bow_poly_jt_inject_write` / `bow_poly_jt_inject_gain` (CBowKernel): an
SPSC ring the sitar node's render callback fills with its mono output
(`TanpuraVoiceSource.setInjectSink` →
`StringVoiceSource.jtInjectWrite`), mixed into the **recorded jt
drive** right before the drive-FX hook — the voice→taraf insert and
everything downstream (recruitment, governor, gate, jt
tone/body/stereo) apply to the sitar's drive exactly as to the bow's.
The String voice stays armed and silent under sitar play, so the web
is always there to ring.

Parity: zero gain, an empty ring, or never calling the API is
**byte-null** — `TarafRemovalParityTests` passes untouched;
`TarafInjectTests` pins the positive path and the gain-0 kill. The
consumer drains the ring on dropped-drive blocks (alignment) and
realigns after a gross backlog. Calibration (headless audition A/B):
`st_taraf` **4.0** puts the post-release halo ~33 dB under the pluck —
sitar1's sympathetic zone; 1.0 measured ~12 dB too subtle.

**2026-08-21 — the ring is shared with the tanpura** (`tp_taraf`, see
[Tanpura Voice](tanpura-voice.md)): both foreign voices scale their
drive **at their own tap** (`TanpuraVoiceSource.setInjectGain`, applied
to the mono mixdown before the sink; gain 0 skips the tap — nothing is
written), and the kernel-side `bow_poly_jt_inject_gain` is now just the
shared **arm** (`AudioEngine.updateJtInjectArm`: 1.0 while either
`st_taraf` or `tp_taraf` is above 0, else 0, republished across bow
rebuilds by `StringVoiceSource`). Same magnitudes as the old
kernel-side scaling; the byte-null contract is unchanged.

## Parameters

The **"Sitar" registry group** — all `.live`, routed via the `st_`
prefix branch of `setStringControlParam` → `setSitarParam`:
`st_gain` (default = the artifact trim, pinned), `st_pluck_level`,
`st_rel_t60` (0.15 s — sitar lines articulate), `st_pluck_touch`
(default 1: fret runs re-pluck at new pitches; isolation keeps the old
tail at its own pitch), `st_poly` (4), `st_pluck_drive` (1 = the
fitted contact; **the attack-bite knob**), `st_taraf` (above; a
per-source tap gain since 2026-08-21 — the String-side kernel gain is
the shared arm and survives bow rebuilds).

## Auditions

`voiceParam` name `instrument` (0 = String, 1 = Tanpura, 2 = Sitar);
give the first sitar note a few seconds after the switch (engine
build). Plucks land only within 60 ¢ of a mounted JI slot — use exact
scale ratios in `padOn` events.

## Tests

- `SitarVoiceTests` — registry shape/defaults, `st_gain` = artifact
  gain, the ladder's shape (role count, per-role physical fields
  present, constant-B / 1/s-t60 / 1/s-gauge similarity spot checks,
  jiva thread kept), mount + pluck + render smoke.
- `TarafInjectTests` — injected drive rings the jt web; gain 0 dead.
- `TanpuraEngineTests.testTablesLockstepGolden` — the nil-fields
  legacy path is byte-identical (passed without re-blessing).

## Known residuals / next steps

- **User listening verdict pending** (the first v3 cut was rejected:
  "a ringing telephone" — the missing cascade, fixed by the thread
  comp + the T60MUL revert; `testSitarCascadeBlooms` guards it) —
  A/Bs:
  `~/Desktop/sarangi/out/sitar_model/ab_cell_vs_sitar_C4.wav` /
  `_C5.wav` (cell, gap, artifact — the artifact half deliberately
  rings shorter) and `phrase_sitar_v2.wav`; in-app halo balance
  (`st_taraf`), `st_rel_t60`, and the voicing (T60MUL — one export
  away; attack via `st_pluck_drive` live).
- h2 sits ~7 dB hotter than the cells at both registers (the model's
  pluck-comb notch fills faster than the tape's — the hcB velocity
  term; small next to the voicing deltas).
- The 1.1–1.5 kHz buzz pockets and the 1.5 kHz mount cap, above.
