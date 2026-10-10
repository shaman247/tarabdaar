# Tech Debt

The live backlog from the 2026-09-04 whole-tree audit (reuse, simplification,
efficiency, altitude). Present tense, like every other page: each entry says
what the code does now and what it should do. An entry is DELETED when its
change lands — git holds the story, this page holds only what is still open.
Items are ordered by value within each section; the **Decisions** are the
owner's, taken 2026-09-04, and bound the work.

**Decisions.** One-shot migrations are deleted, not kept (single developer,
one device each; a stale install re-defaults). Hash-changing efficiency work
is re-blessed with a before/after render for an A/B by ear.

## Open items

### Numerical accuracy

1. **Modal taraf contact integration adds excess damping.** The split
   rotation/contact step in `bow_jt.c` contracts the small-signal state even
   with physical loss and contact damping disabled. In the selected sarangi
   fit, the roughly 2 kHz Sa mode decays at 33.94 dB/s instead of the explicit
   modal loss of 2.28 dB/s. The precontact stage velocity also biases the
   contact-damping clamp at equilibrium. Four quarter steps reduce the error
   but remain unconverged and regress parts of the full recording comparison.
   Correct the integration and its stationary initializer together, preserving
   the physical contact law; verify energy/loss convergence, finite-amplitude
   stability, realtime cost and complete auditions before replacing the
   selected model. Evidence and reproductions:
   selected-model refinement (local research: `docs/history/Codex-2026-10-04-selected-refinement.md`)
   and energy-consistent research step (local research: `docs/history/Codex-2026-10-04-discrete-gradient-taraf.md`).
   The isolated research step removes the excess loss and passes core energy
   and fixed-instrument stability checks. It remains an offline prototype:
   recording agreement, live coefficient-cache invalidation, moving-contact
   work and realtime cost still need resolution before production replacement.

### Efficiency

1. **Reuse fixed raga model data across rows.** Each physical row rebuilds the
   same reference geometry, equilibrium, modal coefficients and radiation
   transforms. Share immutable tables while retaining separate motion,
   excitation, converter and filter histories. This primarily targets rebuild
   time and memory, so measure those separately from sustained rendering CPU.

2. **Factorization reuse and row batching remain unmeasured.** Guarded reuse
   of a local Newton factorization and SIMD batching across independent rows
   may reduce remaining contact work. Both need evidence: extra nonlinear
   iterations can erase factorization savings, and differing row clocks and
   contact states complicate batching. Keep Newton's convergence check and
   mechanical timing intact. Details and the retained implementation:
   repeated-equation opportunities (local research: `docs/history/Codex-2026-09-20-taraf-reduced-newton.md`).
