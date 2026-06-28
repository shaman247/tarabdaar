# Sitar

A plucked **sitar** voice built from the **same harmonic-resolved
plucked-string model as the tanpura** (`Packages/StarpadDSP`,
`TanpuraParams`/`TanpuraModel`/`TanpuraString`), fitted to a reference
recording (`sitar1.wav`) by an autonomous matching loop and exposed in
StarpadMac's own **Sitar tab** (no ⌘ shortcut).

The model is **not forked or refactored** — the sitar reuses `TanpuraModel`
unmodified, just with a different matched parameter set
(`TanpuraParams.sitar`). The eventual goal is to drive the **sympathetic
strings** with this same fitted voice, so the fit is **one pitch-invariant
string timbre** (mirrored onto all four model strings at the matched tonic),
not a per-note patch.

## The reference

`sitar1.wav` (44.1 kHz stereo, 3.53 s) is **three plucks of a single note**.
The user's call: treat **all three as the same note, C#4 = 280.4 Hz**
(measured +20¢; the dominant loud partials — 561 / 1120 / 1680 / 2240 Hz —
are exactly its even harmonics; the sitar's bright jawari emphasizes the
upper/even partials so the fundamental is weak). Measured by
`tools/sitar_match.py`:

- **Onsets** 0.05, 1.415, 3.026 s (HF spectral-flux; the third pluck's tail
  is truncated by the file end ≈ 0.5 s in).
- **Velocities** ≈ 0.82, 1.0, 0.94 (post-onset peak envelope).
- **Spectrum** strong even harmonics, weak odd (h2/h4 ≈ 0 dB, odd 20–40 dB
  down) — no single `pluckPos` comb makes that, so it's carried by a
  **measured per-harmonic `gainTrimDB`** (fit-init), like the tanpura.

The model is a single C#4 string re-plucked three times (linear envelope
states superpose click-free). The reference's sub-200 Hz content (a low
drone, a ~258 Hz sympathetic string, pluck-1's fifth-below fundamental at
186 Hz) is **not** something a single 280.4 Hz string makes, so the loss
grid deliberately starts at 200 Hz (see below).

## Matching pipeline (`tools/sitar_match.py`, `tools/sitar_iterate.py`)

Reuses tanpura_match's signal-agnostic **specres / tune / attack** machinery
(the acceptance-bar loss) and tanpura_iterate's **CMA-ES** core. Artifacts
live in `auditions/sitar/`.

1. `sitar_match.py fit-init` — measure the per-harmonic gain profile of the
   280.4 Hz note (heterodyne, averaged over the 3 plucks) and **iteratively
   calibrate `gainTrimDB`** so the *rendered* model spectrum matches the
   reference's (accounts for the bloom envelope's per-harmonic peak that a
   static gain law can't predict); set `decayTrim` from the measured
   per-harmonic decay time (floor 0.05 so the sitar's **fast HF decay**,
   τ ≈ 0.05 s at h24, is representable). Starts from the tanpura SA string's
   matched timbre as a plucked-string prior, retuned to 280.4 Hz. Writes
   `init.json`.
2. `sitar_match.py loss <wav>` — the perceptual loss:
   - **specres** (w 3.0, primary) — per-cell |ΔdB| on absolute log-frequency
     grids, but **focused on 200 Hz–13 kHz** (`sitar_specres_grids`): below
     200 Hz the reference has the unmodelable low drone / sympathetic /
     pluck-1 fundamental, which otherwise dominates the audibility-weighted
     residual (18 dB bands) and steers the fit toward faking content it
     shouldn't. Split into slow (decay structure) + std (modulation depth),
     exactly as the tanpura's.
   - **tune** (w 1.0) — partial-alignment cents (guards within-band sourness
     specres' ~80¢ bands can't see).
   - **attack** (w 0.6) — paired per-onset 2–8 kHz transient (the mizrab chik
     below specres' 70 ms smear).
   - **decay** (w 2.0) — per-pluck wideband RMS-envelope L1 in dB; nails the
     gross decay rate (a sitar pluck decays much faster than a tanpura
     drone). Weighted up because the ringout is perceptually load-bearing.
   - **pulse** (w 0.6) — per-event decay drop.
   `loss(ref, ref) ≡ 0` self-test.
3. `sitar_iterate.py` — CMA-ES over **one string-0 timbre** + globals + body
   + room (masterGain pinned, peak-normalized at bake). The low per-harmonic
   `gainTrimDB` (k<4) are frozen from fit-init; CMA-ES reshapes the rest
   through **group dims**: `gtrim0/1/2` (additive dB on harmonic bands
   4–12 / 12–20 / 20–32), `hfTrimDB` (32+), and `dtrim0/1/2` (multipliers on
   the decay-time profile of harmonic bands 1–8 / 8–20 / 20–40 — these gave
   the optimizer the freedom to fix the too-slow HF ringout). Jiva is bounded
   energy-conserving (conserve ≥ 0.85) so a fast rate reads as **jawari
   shimmer**, not an envelope pump (the tanpura wah-wah lesson). The loop is
   restart-robust (IPOP-style restart from the running best on a numerical
   blowup or every 45 gens). Winner → `best_params.json`, top-10
   WAV+PNG → `top/`.
4. `sitar_match.py report <wav> [--floor <seed2 wav>]` — specres stats + a
   3-panel spectrogram PNG (reference / model / weighted residual) and the
   stochastic floor (the specres only seed luck separates; ≈ 2.1 dB).
5. `sitar_bake_defaults.py [--bump]` — bakes `best_params.json` into
   `Packages/StarpadDSP/Sources/StarpadDSP/SitarParams.swift`
   (`TanpuraParams.sitar`, JSON-embedded), peak-normalizing `masterGain`,
   stripping the optimizer's `_`-prefixed keys, mirroring the single voice
   onto all four strings at 280.4 Hz, and bumping `sitarMatchedVersion` (keys
   AppController's UserDefaults persistence). Then `swift test` +
   `./tools/build-mac.sh`.

**Listening is the arbiter:** the ref/model spectrograms should look alike
and the model shouldn't be visibly *busier* than the reference (the jiva /
sub-bank can over-texture the sustain). The metric drives iteration; the
top-N WAVs and the report PNG let a human veto.

## Audio graph integration

`AudioEngine` owns a second `TanpuraModel` (`sitar`) behind a dedicated
`sitarLock` on its own source node, identical wiring to the drone:

```
sitarSource → sitarGain → preReverbMixer → masterFilter → reverb → out
```

API: `setSitarParams(_:)`, `sitarParams`, `sitarPluck(index:velocity:)`,
`clearSitarState()`, `setSitarGainDB(_:)`. `AppController` holds
`@Published var sitarParams` (persisted to UserDefaults, pushed to the engine
on change, independent of `applyPreset`), `sitarGainDB` (default +18 dB), and
`sitarVelocity`. Audition scores can set params via `voiceParam` names
`sitar.<path>` (same paths as `tanpura.<path>`) and `sitarGainDB`.

## Sitar tab (Mac-only, no ⌘ shortcut)

- **Pluck pads** — one octave of 12-TET pads (sargam labels) from the matched
  Sa (280.4 Hz, C#4 +20¢). Plucking a pad retunes string 0 to that pitch
  (the timbre is pitch-invariant) and plucks it.
- **Play phrase** — reproduces the three measured plucks for A/B against
  `sitar1.wav`.
- **Toolbar** — velocity, output gain (dB), Reset (to `TanpuraParams.sitar`),
  Silence.
- **Harmonics editor** — per-harmonic gain / peak-time / decay trims of the
  fitted voice (the same `HarmonicBarEditor` as the Tanpura tab).
- **Model** disclosure — bloom laws, jiva/drift/variation, attack noise,
  body & output, room.

The tab does not touch `ipadLayout` — the sitar is Mac-local (like the
tanpura).

## The sympathetic-string voice

The fit is a single pitch-invariant plucked-string timbre precisely so it can
drive the sym layer — and it now **does**: `OfflineEngine` voices every
sympathetic string from `SitarSymVoice` (← `TanpuraParams.sitar.strings[0]`)
instead of the old tanpura SA string. The sym path is **continuously excited
(never plucked)** and its envelope follows the main voice (`bbEnv`), so it
borrows only the sitar's *steady* timbre — the pluck-only **chik** / attack /
bloom never fire. `SitarSymVoice` is the single source for the `sym*` timbre
defaults (DSPParams / AppController / SoundPreset), so re-baking the sitar
re-voices the sym layer automatically; `exciteBase` is recalibrated (730) for
this quieter timbre — re-run `SymVsTanpuraC3.testAbsoluteLevels` after any
re-bake. See [sound-design.md](sound-design.md).
