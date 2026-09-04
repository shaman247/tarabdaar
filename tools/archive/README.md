# Archived tools

Tooling for pipelines the instrument no longer has, kept for reference
(git history has their full story; none of these run against the current
code):

- `swamhost.swift` — headless AU host for SWAM Violin 3 captures (the SWAM
  voice was removed 2026-07-24).
- `sarangi_match.py`, `sarangi_iterate.py`, `sarangi_decompose.py`,
  `sarangi_bake_defaults.py`, `sarangi_bake_preset.py` — the sound-matching
  pipeline for the coupled bridge–body network (removed 2026-07-24).
- `liveness_analyze.py` — the SWAM-capture analysis behind the fitted
  sustain-liveness layer (the fit is baked into `bowed_string.json`).
- `gen-harmonic-graphs.py`, `gen-sym-graphs.py`, `sym_lag_probe.py`,
  `sym-harmonics.html`, `sym-envelopes.html` — the Harmonics-tab graph
  pipeline (tab removed 2026-07-23).
- `audition_analyze.py`, `audition_compare.py`, `audition_iterate.py` —
  the headless audition loop's score writer / WAV comparer / refine
  driver. The pipeline they drove (the `IPadSimulator` + `AuditionRunner`
  inbox→WAV path) was removed 2026-09-03; nothing watches
  `auditions/inbox/` any more, so these scripts have no runner.

Live tools stay in `tools/`: `build-mac.sh`, `release-mac.sh`,
`test-full.sh`, `gen_docs_html.py` and `fretpad_fit.py` (the drag-assist
refit).
