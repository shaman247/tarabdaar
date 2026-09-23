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
   mechanical timing intact.
