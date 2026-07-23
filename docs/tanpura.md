# Tanpura Drone

A physically-informed, **harmonic-resolved** tanpura model built into
StarpadMac, with its own Tanpura tab, an offline renderer for
autonomous sound-matching, and a measurement pipeline that fits the model
to a reference recording (`tanpura.mp3`).

## Why harmonic-resolved

The tanpura's defining characteristic is the **jawari bridge effect**: a
pluck splits into harmonics that *peak at different times*. The fundamental
speaks first, then energy blooms upward through the partials over hundreds
of milliseconds — the famous shimmering cascade. Instead of modeling the
bridge mechanically (a waveguide nonlinearity whose per-harmonic behavior
is only emergent), Starpad models the *behavior itself*: every harmonic is
synthesized individually with its own bloom envelope, so each harmonic's
gain, peak time, and decay can be measured from a reference, fitted, and
hand-edited.

## Synthesis model (`Packages/StarpadDSP`)

Per string (×4), per harmonic k (1…`harmonicCount`, max 64 — raised from
32 because the reference has tonal harmonic sheen all the way to 8 kHz+
that a 24-harmonic stack cannot produce):

- **Oscillator** — rotation oscillator (no per-sample `sin`) at
  `f_k = k·f0·√(1 + B·k²)` (B = `inharmonicity`).
- **Bloom envelope** — `gain_k · (attackLevel·e_a + e_d − e_r)` where
  e_a/e_d/e_r are one-pole exponential states:
  - `gain_k = max(0.05, |sin(πk·pluckPos)|) · k^(−falloff) · 10^(gainTrimDB[k]/20)`
  - `τd_k = decay · k^(−dampTilt) · decayTrim[k]`
  - peak time `tp_k = bloomDelay · k^bloomSkew · peakTrim[k]` (clamped to
    0.8·τd_k); the rise constant τr is solved by bisection so the
    envelope's maximum lands exactly at tp_k.
  - The states are **linear**: a pluck *adds* velocity into them, so
    re-plucking a ringing string superposes click-free (verified by a
    superposition unit test).
- **Jiva** — per-harmonic slow amplitude LFO (`jivaDepth`, `jivaRate`,
  `jivaTilt` weights it toward mid harmonics). Two shape controls added
  to fix the isolated-pluck "wah-wah" (independent per-harmonic LFOs that
  pump the summed envelope — masked in dense strumming, naked on a single
  pluck): `jivaConserve` rescales each block's jiva gains so the string's
  total modulated power matches its unmodulated power (harmonics swell
  and fade *against* each other instead of pumping the sum), and
  `jivaRateSpread` sets the width of the per-harmonic rate scatter — 1 =
  the original 0.5–1.5× jitter, 0 = every harmonic shares one rate, which
  concentrates the modulation at a single frequency. A real tanpura's
  isolated-pluck jiva is a TIGHT ~2 Hz pulsation; independent random
  rates instead smear pump energy across 1.5–7 Hz, which is what the ear
  hears as wah. See the `modspec` loss term.
- **Pluck variation** — every pluck gets a fresh random per-harmonic gain
  jitter (`pluckVariationDB`) so successive plucks are never clones.
- **Pitch drift** — per-string filtered random walk (`pitchDriftCents`,
  `pitchDriftRate`), block-rate, mirrors the sym pool's drift style.
- **Attack noise** — short bandpassed noise burst per pluck (`noiseLevel`,
  `noiseDecay`, `noiseFreq`, `noiseQ`).
- **Cross-excitation** — plucking one string leaks `crossExcite·velocity`
  into other strings' harmonics within `crossTolCents` of a sounding
  harmonic (coincidence table rebuilt on retune).
- **Half-integer sub-bank** (`subLevelDB`, −60 = off; `subFalloff`) — a
  second bank of partials at `(k+0.5)·f0` sharing the string's decay and
  bloom laws (evaluated at h = k+0.5, no per-harmonic trims), with its
  own spectral falloff (the reference's half-integer partials die off
  faster with k than its integer ones) and one dB level knob.
  This is the jawari bridge's **period-2** signature: the reference
  recording has loud inter-harmonic partials on exactly this grid
  (sa·3.5 = 918 Hz at −7 dBpk is among its strongest components;
  Pa·1.5 = 295 Hz, SA·0.5 = 65.6 Hz, Pa·3.5 = 689 Hz…), and before this
  bank existed the four worst residual regions of the run-6 match were
  all half-integer slots, 20–36 dB deficient.

Model-level: per-string equal-power pan (`panSpread`), a body filter
(`bodyDry` + 3 parallel bandpass resonators `body[i]{freq,gain,q}` +
first-order `tiltDB` shelf at 1.5 kHz), `masterGain`, and a soft safety
limiter (linear below ±0.85, smooth ceiling at ±1.0).

Everything is deterministic for a given seed — renders are reproducible
and the optimizer sees no evaluation noise.

Files: `TanpuraParams.swift` (schema + `set(path:value:)`),
`TanpuraString.swift` (per-string engine), `TanpuraModel.swift`
(strings + body + pluck queue). Tests in
`Tests/StarpadDSPTests/TanpuraTests.swift` (determinism, boundedness,
tuning accuracy, decay ordering, **staggered-peak**, superposition,
sub-bank on/off, path-setting, spec decode).

## Audio graph integration

`AudioEngine` owns a `TanpuraModel` behind a dedicated `tanpuraLock` on its
own source node:

```
tanpuraSource → tanpuraGain → preReverbMixer → masterFilter → reverb → out
```

It is deliberately **not** summed into the sym render: the sym path runs
through `symGain`, whose volume is the `voiceMix` crossfade (0 at the
default `voiceMix = 1`), and the sarangi voice (the `SarangiProcessorAU`
inline effect) is silent without a hosted AU loaded (its upstream
`hostedDriveTap` has no input). `tanpuraGain` is an `AVAudioUnitEQ(numberOfBands: 0)` makeup
stage (same trick as `hostedMakeupGain` — mixer `outputVolume` clamps to
[0, 1]) so the drone can be boosted above unity without touching the
peak-normalized `masterGain` inside the matched params. API:
`setTanpuraParams(_:)`, `tanpuraParams`, `tanpuraPluck(index:velocity:)`,
`clearTanpuraState()`, `setTanpuraGainDB(_:)` (clamped ±24 dB).

`AppController` holds `@Published var tanpuraParams` (persisted to
UserDefaults as JSON, pushed to the engine on change, independent of
`applyPreset`), `tanpuraGainDB` (output gain, default **+12 dB**), the
auto-drone timer (`tanpuraAutoDrone`, `tanpuraStepSeconds`,
`tanpuraPattern` — tokens 1–4 or `-` for rest), and `tanpuraVelocity`.
Audition scores set params via `voiceParam` names `tanpura.<path>` (plus
top-level `tanpuraGainDB`) and pluck via the `tanpuraPluck` event kind.

## Tanpura tab (Mac-only)

- **4 string buttons** (Pa sa sa SA) with note name + live Hz; click or
  keys 1–4 to pluck; per-string level sliders.
- **Toolbar** — auto-drone toggle, step seconds, pattern field, velocity,
  output gain (dB, default +12), Reset, Silence. **Reset** restores the
  matched bake: `TanpuraParams()` defaults (including the baked f0s with
  their matched unison detune — the tuning `onChange` is suppressed for
  one shot so it can't recompute them) and the measured reference tuning.
- **Tuning** — tonic (note + octave + cents trim) and per-string just
  intervals (Pa 3/4, Ma 2/3, Ni 15/16, sa 1/1, SA 1/2) + fine cents;
  "Apply measured reference tuning" restores the tuning measured from
  `tanpura.mp3` (C4 +4¢ tonic). Persisted separately from the params.
- **Harmonics editor** — the fine-grained control: pick a string and a
  mode (Gain dB / Peak time / Decay), then drag bars to edit that trim for
  every individual harmonic; double-click a bar to reset it.
- **Model** disclosure — sliders for the selected string's bloom laws
  (incl. sub-bank level/falloff/knee) and all global params: jiva
  (depth, rate, tilt, **energy conserve**, **rate spread**), drift,
  variation, noise, cross-excite, body (q to 300), room (wet/decay/
  damp/predelay — the *in-model* Schroeder room), tilt, master.
- **Room (tanpura + sitar)** — the shared **master FX** that the
  tanpura *and* sitar buses ride (`AVAudioUnitEQ` resonant low-pass →
  `AVAudioUnitReverb(.mediumHall)` → `postReverbEQ`): **Reverb mix**,
  **Filter cutoff**, **Filter resonance**. These moved here from the old
  Sarangi-tab Master-FX section now that the **sarangi bypasses them**
  (it has its own per-voice FX rack — see [sarangi.md](sarangi.md)); they
  shape only the tanpura/sitar tail. Audition names `reverbMix` /
  `filterCutoff` / `filterResonance`.

The tab does not touch `ipadLayout` — the drone is Mac-local.

## Offline renderer (`tanpura-render`)

```bash
swift build -c release --package-path Packages/StarpadDSP
Packages/StarpadDSP/.build/release/tanpura-render spec.json [-o out.wav] [--mono]
Packages/StarpadDSP/.build/release/tanpura-render --print-defaults
```

Spec JSON: `{sampleRate?, durationSeconds, seed?, params?, plucks:
[{at, string, velocity}], out?}` (`TanpuraRenderSpec` in StarpadDSP, so
decoding is unit-tested). Renders ~50× real time — the autonomous loop
never needs the app.

## Matching pipeline (`tools/tanpura_match.py`, `tools/tanpura_iterate.py`)

Artifacts live in `auditions/tanpura/`.

1. `tanpura_match.py decode-ref` — `tanpura.mp3` → `reference.wav`
   (afconvert, 44.1 kHz mono).
2. `tanpura_match.py calibrate` — measures per-string f0 (harmonic-comb
   sweep ±60¢; C4-vs-C3 octave collisions resolved via odd/unique
   harmonics), detects the 60 s pluck schedule, and measures
   **per-harmonic envelope matrices** A[k,t] by pluck-synchronous
   stacking: every onset's heterodyned envelopes, truncated at the next
   event of any string, nan-median across instances. Writes
   `reference_model.json` + `reference_harmonics.npz`.

   **Schedule detection** (redesigned after the first version matched only
   17/86 true attacks): onset TIMES come from high-frequency spectral
   flux (sharp attack transients, ±12 ms); LABELS come from
   fundamental-frequency envelope jumps — 131 Hz is unique to SA, 197 Hz
   unique to Pa, and a sa (C4) call requires the 262 Hz jump to dominate
   the 131 Hz jump because C4's fundamental sits on SA's h2. No evidence
   gate: every flux attack is a pluck (a re-pluck of an already-loud
   string shows only a small jump). Verify with
   `tanpura_match.py schedule-check` — it writes a spectrogram overlay
   PNG with events marked at their string's fundamental and prints
   coverage against an independent flux detector (expect ~100% matched,
   0 orphans). The reference fades in for ~3.4 s before its first clear
   pluck.
3. `tanpura_match.py rematrix` — recomputes the per-string matrices from
   the EXISTING schedule with **bed subtraction** (each instance's
   pre-onset per-harmonic level power-subtracted) and a deeper measured
   count (48). This is the attribution fix: without it the sa (C4)
   matrices inherit SA's always-ringing even-harmonic bed, and a loss fed
   by them rewards loud constant sa strings (the v4 failure). The raw
   matrices are backed up as `*_prebed.*`. Caveat: constant-bed
   subtraction over-subtracts decaying tails, so bed-subtracted **taus are
   junk** — only gains/attribution are trustworthy.
4. `tanpura_match.py fit-init` — hybrid: GAINS (falloff, pluckPos comb,
   gainTrimDB, levels) from the bed-subtracted summary; TIME laws
   (decay/bloom) from the raw `_prebed` summary (see the caveat above),
   reliability-gated (a tau fit counts only if its window actually saw
   ≥8 dB of drop) and clipped → `measured_init.json`. In practice the
   measured time laws are still noisy — production inits splice fit-init
   gains onto the previous winner's time laws.
5. `tanpura_match.py loss <cand.wav> [--windows t0:t1,…] [--iso iso.wav]` —
   loss components (run-6 redesign; every term exists because an optimizer
   exploited its absence):
   - **specres** (w 3.0, THE primary term — the acceptance bar made
     differentiable): per-cell |ΔdB| between ABSOLUTE log-frequency grids
     (112 bands, 90 Hz–16 kHz, ~70 ms smear) of reference and candidate on
     the aligned schedule, audibility-weighted (cells quiet on both sides
     don't count; loud-anywhere cells can't hide). Both sides RMS-matched
     on in-grid (90 Hz–16 kHz bandpassed) content so out-of-band energy
     can't deflate the grid. Split into **slow** (~0.7 s-smoothed mean
     structure) + **std** (per-band fast-component modulation DEPTH as a
     statistic) — per-cell residual on stochastic texture would reward
     flattening the modulation (regression to the mean). Unlike the
     retired mean-removed `spec`/`ltas`/`env` terms it sees WHICH string's
     energy fills a shared band at each moment, because the schedule
     forces when each band is re-fed.
   - **harm** (w 0.3): candidate through the identical bed-subtracted
     stacking operator; per-harmonic log-envelope L1 + peak-time error,
     first 1.2 s. Low weight: the operator's noise floor dominates its
     scale; it shapes per-string bloom, it no longer drives.
   - **tune** (w 1.0): mean cents from the reference's strongest spectral
     peaks to the candidate's nearest top peak (≤60¢), /8. The ~80-cent
     specres bands can't see sourness; the detune/inharmonicity dims can
     create it. Self-test exactly 0 (symmetric peak extraction).
   - **attack** (w 0.75): paired per-onset 2–8 kHz transient (rise dB +
     rise-time log-ratio at 5 ms resolution) — the chik lives below
     specres' 70 ms smear.
   - **pulse** (w 1.0): paired per-event decay drops (post-onset peak →
     pre-next-onset trough), wideband + 800–3200 + 3200–8000 Hz.
   - **ring** (w 6.0, constraint): single-pluck slope-extrapolated T20
     bracket on a dedicated isolated-pluck render, **rendered with
     crossExcite forced to 0** — with coupling on, the other strings'
     sympathetic ringing dominates the tail and run 6 "violated" every
     bracket while its decay laws were fine. Brackets: [2.0, 6.5] s
     wideband, [0.6, 4.0] s in 800–3200, [0.2, 2.5] s in 3200–8000.
   - **clip** (w 300, a wall): fraction of raw samples at/over the
     limiter knee (|x| > 0.84); masterGain is pinned during optimization
     and peak-normalized at bake time rather than searched.
   - **mod** (w 0.5): per-octave-band envelope-fluctuation depth.
   - **smooth** (w 2.0): paired isolated-pluck envelope smoothness
     (RMS deviation from a straight-line decay, wideband + 500–3200 Hz)
     on references with ≥1.8 s inter-pluck gaps. The first half of the
     "wah-wah" guard — but it measures total deviation, which a smooth
     bloom and a periodic pump share, so it needs `modspec` beside it.
   - **isosmooth** (w 2.0): the same smoothness but ABSOLUTE, on the iso
     render at the model's own tuning, above a 1.2 dB allowance (the
     paired `smooth` term only constrains the aux tunings; the wah was
     heard at ours).
   - **modspec** (w 3.0, THE wah-wah term): on the iso render, the
     envelope's modulation-RATE profile (Hilbert envelope → cubic-detrend
     → Welch). One-sided penalty for pump energy in 2.5–7 Hz beyond the
     reference single-plucks' measured falloff (tight ~2 Hz peak,
     0.052 at 2.5–4 Hz, 0.021 at 4–7 Hz). This is what `smooth`/
     `isosmooth` miss: they see the *magnitude* of envelope deviation,
     `modspec` sees its *rate* — a smooth bloom (DC) passes, a periodic
     1.5–7 Hz pump (independent per-harmonic LFOs) is penalized. Fixed by
     `jivaConserve` + low `jivaRateSpread`.
   - **spec/ltas/env** (w 0): subsumed by specres; revivable for
     diagnostics via `loss_weights.json`. Zero-weight components are
     skipped entirely.
   Weights are user-editable in `auditions/tanpura/loss_weights.json`.
   `loss(reference, reference) ≡ 0` is the pipeline self-test — re-verify
   it after ANY metric change.

   **Multi-reference generalization (8 samples).** Matching only
   `tanpura.mp3` overfits — the wah-wah hid because that one reference is
   densely strummed. Seven more samples (`tanpura1–7.wav`, different
   tanpuras / tonics / playing density, several with isolated plucks)
   are calibrated by `calibrate-aux <wav>` into
   `auditions/tanpura/refs/<name>/` (tonic-agnostic `detect_tuning`:
   harmonic-comb SA scan 85–175 Hz with a fifth/octave-down guard, then
   the 4th string from classical ratios; `detect_plucks` with a sparse
   re-detect; writes `model.json` + a verification `overlay.png`). The
   optimizer's `evaluate` renders the main reference PLUS an
   auxiliary minibatch — the single-pluck anchor (`tanpura1`) every eval
   plus two rotating by generation seed — each retuned to that
   reference's measured f0s via `tuned_params` (timbre is SHARED across
   references, tuning is per-reference). The aux mean total is added at
   `AUX_WEIGHT` (1.2). Aux scoring uses `floor_db=50` and `mod` off
   (quiet recordings put their noise floor inside those statistics).
   **Generation totals are minibatch-noisy** — after a run, rescore all
   `top/` elites on the FULL 8-reference set at two fixed seeds and pick
   the true winner there, not from the optimizer's reported best.
6. `tanpura_match.py report <cand.wav> [--floor cand_seed2.wav]
   [--diff-audio]` — the acceptance-bar artifact: stats per window
   (specres total/slow/std, p90, quiet-cell residual, tune cents) plus a
   3-panel PNG (reference grid / candidate grid / weighted residual map —
   the bar is "residual panel near-black"). `--floor` takes a SECOND
   render of the same params at a different seed and prints the
   **stochastic floor** — the specres below which only seed luck differs
   (~2.6 dB); compare the headline number against it, not against 0.
   `--diff-audio` writes `diff_missing.wav` / `diff_extra.wav`
   (magnitude-spectrogram difference resynthesized as audio — the honest
   stand-in for "the diff sounds like noise", since a waveform null is
   impossible for a random-phase resynthesis; both fall to silence as the
   match approaches the bar).
7. `tanpura_iterate.py` — always rebuilds the renderer (a stale binary
   silently truncates new-schema params), asserts the schema handshake
   (init harmonicCount == binary trim length), then:
   - **Stage 0**: 1-D sweeps → `stage0.csv` (flat-metric sanity check);
     does NOT touch `best_params.json`/`top/`,
   - **Stage A**: per-string CMA-ES (kept, but largely superseded by the
     full-mix specres),
   - **Stage B**: joint CMA-ES on the full loss (~52 dims: jiva, drift,
     noise, variation, cross-excite, body, tilt, levels ≤1.8, per-string
     decay/dampTilt/bloomDelay/falloff/bloomSkew/attackLevel/
     inharmonicity/subLevelDB, saDetuneCents; masterGain excluded).
   Hand-rolled numpy CMA-ES; parallel workers. **The render seed
   alternates per generation** — thousands of evals on one frozen noise
   realization let CMA-ES align that realization with the reference's
   (loss gains that evaporate on any other seed); alternation keeps
   within-generation ranking comparable while making seed-fitting
   unrankable. Verify any winner cross-seed (two seeds should agree on
   specres within a few tenths of a dB; run-6's winner: 11.60 vs 11.72).
   Note the printed "best" is biased low by generation-seed luck — score
   the winner explicitly at fixed seeds for honest numbers. Every eval →
   `trials.jsonl` (now including the searched dim values); the running
   best is checkpointed to `best_params.json.partial` each improvement;
   top-10 candidates kept as WAV + params + spectrogram PNG in
   `auditions/tanpura/top/`; winner → `best_params.json`.
8. `tanpura_match.py make-score [--params best.json]` — emits an
   AuditionScore (`tanpuraPluck` events on the measured schedule, with the
   ENTIRE master chain pinned — `reverbMix 0`, `filterCutoff 20000`,
   `filterResonance 0`; a persisted filterCutoff once cost 10 dB of
   specres in "verification" — plus `tanpura.*` voiceParams if `--params`
   given) into `auditions/inbox/` for end-to-end in-app verification
   through the real audio graph. Keys starting with `_` (optimizer
   bookkeeping such as `_saF0Center`) are skipped. Omit `--params` once
   the winner is baked — the defaults ARE the match. After the `.done`
   marker (written to the INBOX dir), wait for the output WAV to be
   size-stable before reading it (AVAudioFile flushes after the marker);
   the in-app WAV is at the device rate (48 kHz) — resample before
   scoring. Expect the in-app render to score ~1–2 dB worse on
   specres/pulse than the CLI render of the same params: the
   AuditionRunner schedules plucks with main-thread timers (±tens of ms
   jitter against the reference-aligned grid) while the CLI render is
   sample-accurate. Verification passes when the EQ-pinned in-app score is
   within that margin and `harm` is in family — it checks the signal
   path, not the match quality.
9. `tanpura_bake_defaults.py [--bump]` — bakes `best_params.json` into the
   `TanpuraParams` Swift defaults: renders the measured schedule, scales
   `masterGain` for a 0.6 peak (the optimizer never sets meaningful
   absolute gain — see `clip` above), and rewrites the default literals
   in place. `--bump` increments `TanpuraParams.matchedVersion`, which
   keys AppController's UserDefaults persistence so stale persisted
   params never shadow a fresh bake. Then `swift test` (the model tests
   are bake-independent) and `./tools/build-mac.sh`.

**Listening is the arbiter, and the acceptance bar is high:** the
ref-vs-model spectrograms should look visually identical, and the
time-aligned audio difference should sound like noise — not like missing
or extra musical content. (Set 2026-06-10 after the v4 listening verdict;
no run has met it yet.) Quantitatively: `report`'s specres should approach
the `--floor` stochastic floor (~2.6 dB), its residual panel should be
near-black, and `diff_missing.wav`/`diff_extra.wav` should approach
silence. The metric exists to drive iteration; the top-N WAVs,
report PNGs and diff audio exist so a human can veto it. If ear and
metric disagree, re-weight `loss_weights.json` and re-run Stage B (cheap).

**Resolved (run 6) — energy attribution between strings.** The v4 loss
was indifferent to WHICH string produced energy in shared bands, and the
sa (C4) matrices inherited the always-ringing C3-even bed; the optimizer
exploited it (sa pair at ~2.3× levels, a dominant constant high-sa band).
Fixed by making the acceptance bar the loss (specres on absolute grids)
plus bed-subtracted matrices: run 6's winner inverted the balance to
sa ≈ SA ≈ Pa, found ~6¢ of unison detune, and moved a body band onto the
formant the diagnosis flagged, unprompted.

**Resolved (run 7) — half-integer partials.** Run 6's four worst residual
regions all sat on the `(k+0.5)·f0` grid — the jawari's period-2
partials, which an integer-harmonic model cannot make (the reference has
sa·3.5 = 918 Hz at −7 dBpk). The half-integer sub-bank (`subLevelDB`)
addresses this structurally; enabling it cut specres by ~2 dB in a single
sweep before any re-optimization.

**Run 9 (sideways) → run 10 (room) — the diffuse plateau was the room.**
After run 8, parameter search converged at specres ≈ 6.8 vs the
~2.5–3 dB stochastic floor. Run 9 added body-mode Q (to 300 — the
reference has a real body resonance near 307 Hz that rises +5.5…+7.7 dB
after EVERY string's pluck, on no partial grid), a sub-bank knee
(`subKneeH`), and group HF trims (`hfTrimDB` pseudo-dims in the
optimizer); the optimizer used all three but the headline stayed flat —
it traded low-weight HF cells for midband. The remaining residual was
diffuse across all bands and windows, pointing at a GLOBAL missing
ingredient: the reference's room. Run 10 added the in-model **Schroeder
room** (`roomWetDB/roomDecayS/roomDamp/roomPredelayMs`, predelay → 4
damped combs → 2 allpasses per channel, wet-added before the limiter)
and the optimizer drove it hard (wet −6.9 dB at the cap, decay 1.8 s,
damp 0.93 — a dark tail): specres 6.8 → **6.4** cross-seed, tune
4.7→3.7¢, baked as **matchedVersion 6**. The wet and damp dims sit at
their caps — widening them is the first knob for any future round; the
run-9/10 winners are parked in `auditions/tanpura/run{9,10}_winner.json`.

**Runs 11–13 — generalize to 8 tanpuras + kill the wah-wah.** The
isolated-pluck "wah-wah" (the summed envelope pumps up and down) was
masked in the single densely-strummed `tanpura.mp3`; 7 more samples
(`tanpura1–7`, varied tonics/density, several with isolated plucks) made
it visible and guarded against overfitting. Runs 11–12 added the
multi-reference loss (per-reference tuning, shared timbre, aux
minibatch + rotation) and improved held-out generalization (full-set
combined 100.4 → 96.0) but did NOT fix the wah: the loss was blind to
the modulation RATE. The model pumps across 1.5–7 Hz (independent
per-harmonic LFOs, `jivaRate` scattered ×0.5–1.5) where the reference
single-plucks have a tight ~2 Hz peak that falls off sharply. Run 13
added the fix — `jivaConserve` (power-conserving jiva), `jivaRateSpread`
(tightens the rate scatter toward one frequency), and the **`modspec`**
loss term that finally sees the rate profile — and re-optimized from the
run-11 generalizer. Winners parked in `auditions/tanpura/run1{1,2,3}_winner.json`.

## Workflow recipes

**If you (or an agent) launch a second StarpadMac instance for automated
verification while one is already running (e.g. under Xcode): don't.**
Two instances contend for the SWAM license daemon and both AuditionRunners
grab the same inbox score and record to the same WAV — symptoms range from
hangs to truncated recordings. Launch the automation instance with
`STARPAD_AUDITIONS_DIR=<isolated dir>` to split the inboxes, and terminate
it by its own PID (never `pkill -f StarpadMac`, which also kills an Xcode
debug session with a SIGTERM).

Re-match after changing the model or the reference:

```bash
python3 tools/tanpura_match.py decode-ref
python3 tools/tanpura_match.py calibrate
python3 tools/tanpura_match.py schedule-check   # VERIFY before anything else:
#   expect ~100% flux-onset coverage, 0 orphans; eyeball schedule_overlay.png
python3 tools/tanpura_match.py rematrix         # bed-subtracted matrices
python3 tools/tanpura_match.py fit-init
# splice fit-init GAINS onto the previous winner's TIME laws for the init
# (see step 4 above), then:
python3 tools/tanpura_iterate.py --stage B --init <init.json> --gens-b 100
# Verify the winner cross-seed + against the floor, and LOOK at the PNG:
python3 tools/tanpura_match.py report <winner render> --floor <seed2 render> --diff-audio
# LISTEN: auditions/tanpura/top/*.wav vs reference.wav — the metric only
# proposes; ears decide. Then bake the winner:
python3 tools/tanpura_bake_defaults.py --bump
(cd Packages/StarpadDSP && swift test) && ./tools/build-mac.sh
```

Add an auxiliary reference (generalization set) and re-fit across all:

```bash
python3 tools/tanpura_match.py calibrate-aux tanpuraN.wav --name tanpuraN
#   eyeball auditions/tanpura/refs/tanpuraN/overlay.png — events ticked at
#   their string's fundamental row; check the tonic/role detection
python3 tools/tanpura_iterate.py --stage B --init <prev winner> --gens-b 100
#   evaluate() auto-discovers refs/*/ ; aux minibatch is rotated per gen
# Generation totals are minibatch-noisy — rescore top/ elites on the FULL
# reference set at 2 fixed seeds and pick the winner THERE before baking.
```

Re-polish only the joint stage (after re-weighting `loss_weights.json` or
tightening `RING_BRACKETS`):

```bash
python3 tools/tanpura_iterate.py --stage B --init auditions/tanpura/best_params.json --gens-b 40
```

Quick A/B of a params file:

```bash
python3 tools/tanpura_match.py loss render.wav --windows "8:18,20:30"
python3 tools/tanpura_match.py spectrogram render.wav -o pair.png
```

Known sharp edges, learned the hard way (full history in the project
memory): the optimizer will exploit anything the loss cannot see —
ring-out beyond the stacking truncation (→ `ring`), absolute gain under
RMS normalization (→ `clip` + pinned masterGain), and a wrong pluck
schedule corrupts every downstream measurement (→ `schedule-check` FIRST).
Loss totals are only comparable within one schedule + weight set.
