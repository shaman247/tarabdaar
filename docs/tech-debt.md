# Tech Debt

The open backlog. Entries describe current behavior and the remaining work;
delete an entry when its change lands. Historical measurements and completed
work belong in `docs/history/`. Items are ordered by value within each section.

**Decisions.** One-shot migrations are deleted, not kept (single developer,
one device each; a stale install re-defaults). Hash-changing efficiency work
is re-blessed with a before/after render for an A/B by ear.

## Open items

### Numerical accuracy

1. **Chromatic contact integration adds numerical loss.** The distributed
   quadratic bank in `bow_jt.c` uses a split rotation/contact step with four
   coordinate passes, plus quarter steps for deep contact. The selected-model
   loss study demonstrates contraction beyond explicit modal damping; its
   figures belong to that research fit, not a current whole-bank guarantee.
   An isolated discrete-gradient replacement addresses that loss but still
   needs live coefficient invalidation, moving-bone work, recording agreement
   and realtime measurements before production use. Correct integration and
   stationary initialization together, retaining the physical contact law.
   Validate energy/loss convergence, finite-amplitude stability and complete
   auditions before changing the selected sound. This is separate from the
   physical raga solver in `bow_contact.c`, which already uses a discrete-gradient
   step with an optional SAV path. Evidence:
   selected-model refinement (local research: `docs/history/Codex-2026-10-04-selected-refinement.md`)
   and quadratic-row prototype (local research: `docs/history/Codex-2026-10-04-discrete-gradient-taraf.md`).

### Efficiency

1. **Factorization reuse and row batching remain unmeasured.** Guarded reuse
   of a local Newton factorization and SIMD batching across independent rows
   may reduce remaining contact work. Both need evidence: extra nonlinear
   iterations can erase factorization savings, and differing row clocks and
   contact states complicate batching. Keep Newton's convergence check and
   mechanical timing intact. Details and the retained implementation:
   repeated-equation opportunities (local research: `docs/history/Codex-2026-09-20-taraf-reduced-newton.md`).
