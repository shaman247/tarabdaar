# Sarangi — next steps / open work

Roadmap for the decomposition → `g_h` bow target → live-match work. See
[sarangi-decompose.md](sarangi-decompose.md) (the model + tool) and
[sarangi.md](sarangi.md) (the deployed voice) for background.

## Status (where we are)

- **Decomposition tool** (`tools/sarangi_decompose.py`) built + validated on two
  ragas — E♭ harmonic minor (`sarangi4`) and D Bhairav (`sarangi11`). Per-note
  residual ~1.6 dB; cross-raga `g_h` agreement ~0.3–1 dB.
- **`g_h` bow target** extracted (`target` subcommand → `auditions/sarangi/gh_target.json`)
  and **wired into the live match** as the `gh` loss term in `sarangi_iterate.py`
  (`_gh_shortfall`, weight `gh`=1.5, single-note refs only, body-radiated target).
- **Live-validated through the running app** (real SWAM): the `gh` term computes,
  has the correct gradient (brighter bow ⇒ lower gh), and discriminates (ideal→0,
  real sarangi→2–5, sine→30).
- **Honest finding**: the deployed bow is **already at the SWAM-violin `gh` floor**
  (~7 at Eb4 vs the real recording's ~4.6 → ~2.4 dB headroom that is **NOT
  bow-addressable**). Local, gh-prioritized, and directed bright-bow searches
  cannot beat it beyond render noise. The residual is the violin-vs-sarangi
  harmonic difference — which the halo exists to fill, not the bow. (The
  `SarangiExciter` is no longer part of this: it was a distorted violin
  pass-through onto the halo bus, not sympathetic resonance, and is disabled in
  the shipping preset — brightness now comes from the resonators' falloff.)

---

## A. Realize the `g_h` term in the live match

The term is wired but its value (steering the bow from the start) can only show in
a **from-scratch run**, which couldn't be completed in the dev harness (see §E1).

- **A1 — From-scratch match with `gh` on.** `python3 tools/sarangi_iterate.py --gens 25`.
  Back up `auditions/sarangi/live_best.json` first; ensure only ONE instance runs
  (§E1). Watch the `gh` column in `auditions/sarangi/live_trials.jsonl`. Compare
  the final `gh` to the deployed's ~7. *Effort: ~1–1.5 h compute. Value: high — the
  real test of the term.*
- **A2 — Controlled gh-off vs gh-on (the clean A/B).** Run the same config twice
  (same `--gens`, same CMA seed 1234), once with `gh`:0 and once with `gh`:1.5 (set
  via `auditions/sarangi/loss_weights.json`). The *difference* isolates the term's
  effect on the chosen bow, free of "more optimization helps" confounds. *Effort:
  2× a run. Value: high — the scientifically clean demonstration.*
- **A3 — Tune the `gh` weight** (default 1.5). The bow can't lower `gh` without
  raising `specres` (demonstrated live), so keep it gentle (≈1–2.5). Watch the
  `gh` vs `specres`/`centroid` balance in the trial log; raise it only if the bow
  drifts away from the sarangi profile, lower/zero it if it dulls or over-brightens.

## B. Cleaner `g_h` signal (if the full-render term proves noisy)

- **B1 — SWAM-solo-dry calibration.** The full-render `gh` reads the candidate's
  comb at `h·f0`, which is bow-dominated (~95 %) but still slightly halo-
  contaminated at collisions. For a *pure* bow comb, render SWAM with the halo
  muted (`voiceMix`=1) and dry (no `violaBody`/reverb), measure that against the
  body-corrected `g_h` (no body to radiate). *Cost: one extra render per eval —
  wire as an optional path in `render_and_score`. Value: medium — only if A1/A3
  show the term is too noisy.*
- **B2 — Render noise.** ~0.5 dB on `gh`, ~2 dB on total loss. Average ≥3 renders
  before trusting any small change (a single render's "win" is usually noise).

## C. Re-bake the TARAB from the bowed data — DONE (v6), live re-balance pending

The bow is already at its floor; the residual character is in the sympathetic halo.
The pluck bake (`sarangi1.wav`) is fundamental-strong (falloff ~2.0); the **bowed**
tarab's clean between-harmonic modes are far flatter (**falloff ~1.0** — modes 1–7
nearly flat, then dropping). Shipped via the new **`sarangi_decompose.py
bake-tarab`** → `init_bowed.json` → `sarangi_bake_defaults.py --bump` →
**`SarangiParams.swift` v6** (offline A/B approved by ear — fuller, more authentic
sympathetic wash).

- **C1 — deconvolution: TRIED, found unreliable → use the radiated SHAPE.** "Divide
  `t_m` by the drive" doesn't survive the data: the between-harmonic drive is bow
  **noise** (not measurable — the full-recording Welch there over-boosts the high
  modes by tens of dB), and the empirical fix (render driven by the real bow, match)
  is **degenerate** (the recording already contains the tarab → the loop just makes
  gain cancel the body). The fair A/B is the radiated shape itself (both bakes are
  radiated through the same chain). `bake-tarab --deconv gentle` keeps a small capped
  high-mode boost for experiments (default `none`).
- **C2 — DONE.** `bake-tarab` renders the bowed-vs-pluck halo A/B
  (`decompose/<name>/bake_tarab/{halo_bowed,halo_pluck}.wav`, `ab.png`); decay stays
  the measured pluck `tau_symp_s` (re-bake changes GAIN only).
- **C3 — DONE.** Live re-balance run (`sarangi_iterate.py --gens 25`, 300 trials)
  on the v6 tarab → the macros re-optimized around the fuller profile (the halo
  went **brighter + more prominent**: `symHarmonicFalloff` 1.36→0.61, partials
  28→40, `voiceMix` 0.63→0.54, reverb 14→31), ear-approved on the 8-ref A/B, baked
  to `SoundPreset.swamViola` (`sarangi_bake_preset.py`). The v6 tarab voice is now
  the shipping sarangi.

## D. Tighten the decomposition

- **D1 — Pool same-raga takes — DONE.** `extract` now accepts **`--refs`** (comma
  list / space-separated; first is primary) and pools note instances across files.
  Used for the v6 tarab (Eb set: `sarangi4,3,5,6,7,8`). Caveat learned: pooling
  sharpens the *observed* modes' medians but adds **no new tarab-mode coverage** when
  the extra takes play notes ⊂ the primary's set. For Bhairav, pool `sarangi9/10/11`.
- **D2 — More ragas/recordings** → tighter, more instrument-intrinsic `g_h`
  (each new raga is a fresh cross-validation; run `target` to re-pool).
- **D3 — The Eb4-vs-F4 `gh` gap** (deployed ~7.0 at Eb4 vs ~3.5 at F4). Investigate
  the pitch-specific `violaBody` EQ near Eb4's harmonics — the body radiation in
  the target may be off there, or the deployed body has a dip/peak at Eb4 partials.
- **D4 — Extend the reliable `g_h` range.** High harmonics (h13+) are unconstrained
  (the `target` subcommand truncates to ~h1–11). A smoothness prior on `G_h` in
  the `decompose` solver (penalize 2nd differences, like the body) would pull the
  high harmonics onto the falloff and extend the usable range.

## E. Infra / operational gotchas (learned the hard way)

- **E1 — This dev harness KILLS long background python** (~minutes). Run the match
  in a stable foreground session (Terminal / `tmux` / `caffeinate -i`). Run **ONE**
  instance at a time — two matches share `auditions/inbox/` and corrupt each other
  (this caused the apparent "crashes": it was an inbox conflict, not a code bug).
  Detect completion by polling the process AND `live_best.json`'s mtime, not a
  flaky `ps | grep PID`.
- **E2 — The app must have SWAM loaded and be able to render** (smoke-check first:
  `python3 tools/sarangi_iterate.py --smoke` → expect "OK — SWAM is producing
  sound", not "silent"). A freshly-launched background instance came up silent;
  the user's foreground rebuild rendered fine.
- **E3 — Always back up `live_best.json`** before a run — the loop overwrites it
  and auto-materializes the winner.

## Priority order

The v6 bowed-tarab effort (C1/C2/C3 + D1) is **DONE and shipping**. Remaining:

1. **D2** — more ragas/recordings → tighter, more instrument-intrinsic `g_h`/tarab
   (run `bake-tarab` on a Bhairav pool to cross-check the v6 profile).
2. **A1 + A3 / A2** — the `gh` bow match, only if there's appetite; the bow is at
   its floor (low perceptual upside), so this is a science/completeness exercise.
3. **B / D3 / D4** — refinements once the above are settled.
