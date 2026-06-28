# Sarangi decomposition (`tools/sarangi_decompose.py`)

A mathematical model that decomposes a bowed sarangi recording into the
**independent (incoherent) sum of the main bowed string + each sympathetic
(tarab) string**, plus a body/room EQ, and *solves* for the harmonic profile of
each component from a single scale recording. This is an analysis/measurement
tool — it does **not** bake into the running synth (see the bake handoff below).

The reference is an ascending+descending scale run over the 8 distinct notes of
one octave, with the tarab tuned to that raga (fixed pitches). Across the notes
the sympathetic partials sit at the **same** frequencies while the main-string
partials **move** with the played fundamental — that is the separation handle.

The raga, tonic, tarab range, and reference file are **configurable** (CLI args),
so the same model fits any scale:

| reference | raga | tonic | played | notes |
|---|---|---|---|---|
| `sarangi4.wav` | E♭ harmonic minor | E♭ | Eb4–Eb5 | 8, ~2× each |
| `sarangi9/10/11.wav` | Bhairav (♭2 ♭6 major) | D | D4–D5 | 8 (9=ascent, 10=descent, 11=both ×2) |

E♭ harmonic minor matches the authoritative deployed tarab in
`StarpadMac/SympatheticStringSet.sarangiTarab()` (15 strings, MIDI 51–75).

## The model

Per played note `i` (fundamental `F_i`), in **log-power** every measured partial
is a linear equation:

```
  main:  2·log O = ℓ_i + G_h + B(f)          f = h·F_i   (G_h = log g_h²)
  symp:  2·log O = Lc_ij + T_m + B(f)         f = m·f_j   (Lc_ij = log c_ij·s_j², T_m = log t_m²)
```

| symbol | meaning |
|---|---|
| `g_h`  | main bowed-string harmonic profile (pitch-invariant) — **the headline deliverable** |
| `ℓ_i`  | per-note bow level (the 8 notes are bowed >20 dB apart) |
| `t_m`  | shared tarab modal profile |
| `c_ij` | how strongly note `i` excites tarab string `j` (the coupling matrix) |
| `B(f)` | body/room transfer (broad formant envelope) |

It is **one joint weighted least-squares solve** (`scipy`/`numpy`, IRLS-robust),
not an iterative loop, so it cannot diverge.

### What is and isn't identifiable (the load-bearing facts)

These were learned the hard way and the gauges encode them:

1. **`ℓ_i` (per-note level) is required.** Each scale note is bowed at its own
   loudness; the fundamental amplitude varies >20 dB across the 8 notes. Without
   `ℓ_i` a shared body cannot fit the fundamentals and the whole solve collapses.

2. **The body `B(f)` is only partially identifiable.** With `ℓ_i`, `G_h`, `T_m`,
   `Lc_ij`, the body's overall **tilt and offset** trade freely with the source
   falloff (the classic source–filter degeneracy) — so they are gauge-fixed (a
   penalty on the body polynomial's linear-tilt term). The body's **formant
   curvature** *is* identifiable and matters: keeping it drops the `g_h`
   cross-note spread from ~10 dB to ~3 dB. `g_h`/`t_m` are therefore reported as
   **body-corrected source profiles**; `body_db` is the fitted body (curvature
   meaningful, absolute level not); `body_ltas_db` is the raw recording LTAS for
   reference.

3. **Played in its own scale, the loud low harmonics collide with tarab modes.**
   A played harmonic and a tarab mode land on the same frequency *by design*
   (sympathetic reinforcement). Those collisions are attributed to **main** (the
   bow dominates its own harmonic); the tarab is read only from the **clean
   between-harmonic modes** — the audible halo. Octave-collision tarab modes
   (m=2,4,6… fall on other tarab fundamentals) are unobservable and get a
   falloff-law fill.

Gauges: `g_1=1`, `Σℓ_i=0`, `Σt-mode T_m=0`, `max_m t_m=1`, `max_i c_ij=1`/string.

## Subcommands

```bash
# default = E♭ harmonic minor / sarangi4.wav
python3 tools/sarangi_decompose.py extract     # segment + measure partials
python3 tools/sarangi_decompose.py decompose   # solve g_h, ℓ_i, t_m, c_ij, B(f)
python3 tools/sarangi_decompose.py report       # validation + spectrograms + heatmap
python3 tools/sarangi_decompose.py audition --drive sarangi2.wav   # hear the fitted tarab
python3 tools/sarangi_decompose.py bake-tarab   # bowed-derived tarab init.json + A/B

# another raga — D Bhairav, tarab D3–D5:
python3 tools/sarangi_decompose.py extract   --ref sarangi11.wav --tonic D --raga bhairav --tarab-range 50-74
python3 tools/sarangi_decompose.py decompose --ref sarangi11.wav --tonic D --raga bhairav --tarab-range 50-74
python3 tools/sarangi_decompose.py report    --ref sarangi11.wav --tonic D --raga bhairav --tarab-range 50-74
```

Shared config args (all subcommands): `--ref` (scale WAV) or **`--refs` (D1: pool
several same-raga takes — the first is primary and drives the timeline)**, `--tonic`
(note or pitch class), `--raga` (`harmonic_minor`/`bhairav`/`major`/`minor`) or
`--scale` (explicit semitone offsets, e.g. `0,1,4,5,7,8,11`), `--tarab-range` (MIDI
lo-hi), `--name` (output subdir). Outputs land in
`auditions/sarangi/decompose/<name>/` (default `<name>` = the primary ref basename).
Pooling sharpens the **observed** modes' medians but adds NO new tarab-mode
coverage when the extra refs play notes ⊂ the primary's set (every Eb sample does).

- `extract` → `auditions/sarangi/decompose/observations.json` (per-note pooled
  main + symp partial amplitudes, collision-classified). Pure measurement.
- `decompose` flags: `--coupling {hybrid,physics,free}`, `--cover-min`, `--sigma`
  (driven-resonance half-width, cents). Writes `decomposition.json`.
- `report` → `reconstruction.png` (real / full / main-only / symp-only
  spectrograms), `coupling.png` (8×15 heatmap), `recon_full.wav`/`recon_symp.wav`.
- `audition` drives `sym-render` with the fitted tarab profile → `audition.png`,
  `audition_halo.wav`.
- `target` pools `g_h` across **every** decomposition run (cross-raga → instrument-
  intrinsic) and writes `auditions/sarangi/gh_target.json` — the SWAM bow-timbre
  target the live match consumes (below). Also prints the bowed-vs-pluck tarab and
  fitted-vs-baked body comparison. No raga args (reads all runs).
- `bake-tarab` builds a **bowed-derived tarab resonator voicing** →
  `auditions/sarangi/init_bowed.json` (a `TanpuraParams`, byte-compatible with
  `sarangi_bake_defaults.py`) and renders a **bowed-vs-pluck halo A/B** on the same
  drive (`decompose/<name>/bake_tarab/{halo_bowed.wav,halo_pluck.wav,ab.png}`). See
  [Tarab re-bake](#tarab--body-re-bake) below for the method and its honest limits.

Reuses `tanpura_match` (heterodyne, specres, PNG/IO) and `sarangi_match`
(`f0_track`/`segment_notes`, `pool_profile` for the pluck-decay τ and fallback,
`body_formants_multi`, `build_params`).

## Validation (current result)

- **Partial-domain residual ≈ 1.6 dB** (clean) / 2.1 dB (held-out collisions) —
  the model reproduces the measured spectra. This is the real model-fit metric.
- **`g_h` cross-note spread ≈ 3 dB** — the main profile is consistently
  pitch-invariant across the 8 notes.
- **Energy budget ≈ 95 % main / 5 % halo** — the bowed string dominates; the
  sympathetic shimmer is a 5 % between-harmonic halo (physically sensible).
- The **holistic reconstruction specres (~32) is high only because the
  additive-sine resynthesis is steady-state** (no meend/vibrato/bow-noise) vs.
  the real performance — it is not a model failure; trust the partial residual.
- The **coupling matrix** shows harmonic-lattice structure (the lower tarabs are
  selectively excited by harmonically-related notes); the upper octave saturates
  because the played notes *are* the played octave.
- **Cross-raga validation (the strongest check):** the main `g_h` fitted from
  D Bhairav (`sarangi11`) matches the one from E♭ harmonic minor (`sarangi4`) to
  a **median ≈1 dB** over harmonics 1–16 (loud low harmonics within ~1 dB) — two
  different ragas, same instrument, independent recordings. The bow timbre is an
  instrument property and the model recovers it consistently, which it could not
  if it were overfitting one recording. (D Bhairav's halo reads ~1 % vs E♭'s 5 %
  and its lowest two notes have higher residuals — `sarangi11` is bowed more
  directly; the headline `g_h` agreement is unaffected.)

## Honest caveats

- The **tarab `t_m` rises** toward the mid/high modes: the low tarab fundamentals
  (155–300 Hz) are weakly driven by the high played notes and radiate poorly,
  while the mid modes ring loudest — this is the *driven*-resonator profile, not
  a plucked one. Low modes are the least reliable (body-confounded + weakly
  excited); reconstruction therefore uses the **measured** halo, not the per-mode
  `c_ij·t_m²` extrapolation (which is unreliable for un-observed modes).
- The decomposition is **steady-state, incoherent, single-recording**. It cannot
  separate the absolute body level, capture bow noise / attack transients /
  jawari buzz, or model the meend. It is excellent for *timbre targets*.

## The `g_h` bow target in the live match (wired)

`python3 tools/sarangi_decompose.py target` writes `gh_target.json`: the pooled
main bow profile (11 reliably-falling harmonics, cross-raga agreement ~0.3 dB) +
the median body curve. `sarangi_iterate.py` adds a `gh` loss term
(`_gh_shortfall`, weight `gh`, default 1.5): it measures the candidate render's
harmonic comb at `h·f0` (the bow is ~95 % of the comb at the loud harmonics, per
the decomposition) and scores it against the target **radiated to the candidate's
pitch** — `target[h] = g_h[h] + B(h·f0) − B(f0)` — so the body formants are
accounted for and the term purely drives SWAM's bow SOURCE toward the real
sarangi's, decontaminated from the sympathetic halo that `specres` conflates it
with. Single-note refs only (multi-note refs skip it). Sanity: an ideal candidate
scores ~0; a real sarangi ~2–5 dB (performance variation around the pooled
average); a pure tone ~30 dB.

**Why this is the highest-value use** (vs. re-baking): the current match scores
SWAM against the *whole* recording (main + halo + body mixed), so the bow timbre
is conflated with the tarab. `g_h` isolates the bow. It's **EXPERIMENTAL** — watch
the `gh` component in the trial log on a live run and tune/zero its weight; single
performances vary several dB around the pooled target, so keep it gentle.

What did NOT pan out (and why): a per-harmonic target is only clean at the **loud
low harmonics** — high harmonics are halo-contaminated (tarab collisions) and the
decomposition leaves them unconstrained (so `target` truncates them); and a single
recording's raw comb varies 10–18 dB (bowing + meend smear), which is exactly why
the **pooled, joint-solved** `g_h` is the right target, not any one ref.

## Tarab / body re-bake (`bake-tarab`)

`bake-tarab` turns the bowed analysis into a tarab resonator voicing. The headline
difference it captures: the deployed bake is **pluck-derived** (`sarangi1.wav`,
falloff ~2.0 → fundamental-strong), but the real **bowed** tarab's clean
between-harmonic modes radiate a **much flatter** per-mode profile (**falloff ~1.0**
— modes 1–7 nearly flat, then dropping). It pools the real recording's clean
radiated modes (from `observations.json`), fits a robust falloff law + clamped
per-mode trims (law-filling the unobservable octave-collision modes 2/4/6/12), keeps
the **measured pluck decays** (`tau_symp_s` → ring time is unchanged; the re-bake is
about GAIN only), and writes `init_bowed.json` for `sarangi_bake_defaults.py`.

**Why it does NOT "deconvolve the drive" (the honest finding).** In principle the
resonator wants a *resonance* gain and the recording gives a *radiated* amplitude
(resonance × drive × body), so you'd divide out the drive. But:
- the drive at a **between-harmonic** tarab mode is bow **noise**, NOT measurable —
  the full-recording Welch there is the tarab itself + leakage, and dividing it out
  over-boosts the high modes by tens of dB (mode 11 → +31 dB);
- the obvious empirical fix (render the halo driven by the real bow, match it) is
  **degenerate** — the real recording already *contains* the tarab, so the rendered
  halo at `m·f_j` is dominated by the drive's own tarab content and the loop just
  makes gain cancel the body.

So the fair A/B is the **radiated shape itself**: both the pluck and bowed bakes are
radiated profiles through the same chain, so the comparison isolates the *shape*
difference. (`--deconv gentle` applies a small *capped* high-mode boost for
experimentation; default `none`.) **body:** the 3-band `body_formants_multi` fit
(used only for the offline halo render; deployment bypasses the sym body and shares
`violaBodyEQ`). The decomposition is **steady-state, incoherent**: it cannot
separate the absolute body level, capture bow noise / attack / jawari buzz, or
model the meend.

**Handoff:** `bake-tarab` → A/B by ear → `sarangi_bake_defaults.py init_bowed.json
--bump` (`SarangiParams.swift`, bumps `sarangiMatchedVersion`) → re-run the live
full-chain match (`sarangi_iterate.py`) to re-balance the sym macros around the new
per-mode profile. See [sarangi.md](sarangi.md).

See [sarangi.md](sarangi.md) for the deployed sym layer this informs, and
[sarangi-next-steps.md](sarangi-next-steps.md) for the prioritized open work
(from-scratch `gh` match, tarab re-bake, tightening `g_h`, + the live-validation
findings and infra gotchas).
