# DSP documentation audit — 2026-10-12

These passages were moved out of the runtime reference during the documentation
audit. They preserve the original measurements and design history; they are not
current performance claims or a plan to restore retired code. Current contracts
live in [Sarangi](../sarangi.md), [Sound Design](../sound-design.md), and the
[open backlog](../tech-debt.md).

The audit checked the production two-direction raga and distributed quadratic
chromatic paths, `StringSpec.followsScale`, the plucked-voice touch interface,
`EngineCrossfader`, and the current validation suites. It did not rerun the
historical listening comparisons or the numerical-loss research. In particular,
the old 34-row coupling study and rebuild timings predate the current bank.
The production coupling gain is 0.04 at knob full scale when physical raga rows
are mounted; the retained unbanked fixture scale is 0.4.
At the initial audit, the old assertion that a failed replacement retained the
current engine was incorrect: the host published nil and silenced the source.
The subsequent publication fix distinguishes a failed replacement from an
intentionally empty bank and preserves the working engine on failure. References
to retired standalone test suites in these excerpts are historical, not current
coverage.

## Follow-up consolidation

The next twelve-item pass removed several assumptions that had escaped the
earlier cleanup:

- Process-local four-bit touch namespaces could collide with another device.
  Input lanes now share a host identity allocator; the wire format is unchanged.
  A lifted identity remains reserved while the glide sequencer still references it.
- The Tanpura FIR moved history using the incoming block size, corrupting the
  tail after a callback-size change. It now preserves each completed block's tail.
- Instrument changes discarded plucked release ownership, and reselecting the
  current voice reset the glide queue. Switching now releases the outgoing voice
  normally, and slot remounts displace the prior controlling touch.
- Scale and layout saves used a fixed staging filename and deleted the old file
  before moving its replacement. Both now use Foundation's atomic write.
- The accent grid reread properties during `@Published`'s pre-assignment delivery.
  Its shared publisher now constructs grids from the incoming values.
- Body diagnostics read initialization tables after live edits. They now snapshot
  adopted coefficients and expose a revision for the Body tab.
- Contradictory playing and tuning guidance was reconciled. The gesture memory's
  original text was archived before limiting its prohibition to unsolicited
  direct-finger humanization; the optional Glide Queue remains supported.
- The native research audit depended on an unmanaged temporary dylib. Each run
  now compiles an isolated current-source snapshot and records its provenance.
- Async String builds retained packed jawari arrays already copied into the C
  kernel. Hosts now discard those arrays after initialization; explicit exporters
  retain their existing default access to builder tables.
- The unused `tiltPureLiftMax` field and release script's `SIGN_IDENTITY` setting
  were removed. Neither controlled runtime or signing behavior.
- Documentation link tests incorrectly depended on the ignored HTML output
  directory already existing. They now resolve targets before rendering too.

## Archived modelling roadmap

The completed and rejected entries below are historical. The proposed bone,
damping and tanpura-port experiments are not requirements for the shipping
instrument; its raga rows now have their own fitted two-direction contact model.

The standalone single-row equilibrium probe (local research: `tools/experiments/jawari_equilibrium/README.md`)
compares initial wraps, contact solvers and timesteps using the production
table builder and row tick, without changing the instrument. Measurements and
limitations: equilibrium experiment (local research: `docs/history/Codex-2026-09-08-jawari-equilibrium.md`).

Improvements proposed for the modal‑jawari rows, in the order worth doing.

1. **Radiate the bridge contact force — done.** Rows radiate the DC‑blocked
   contact force, unit‑matched per row (`rowForceScale`); every mode radiates
   flat and the Taraf tab's modal spectrum is the radiated one.
1b. **Add the termination (pin) force — done (baked in).** Every row's
   radiated sample is the bone contact force plus the pin force
   `rowPinScale`·Σ(−1)^k·k·q_k, ahead of the DC blocker; no knob (the
   `bow_jt_rad_pin` mix it shipped as was judged at 1 and folded in).
2. **Drive from the termination too — tried, rejected.** The pin's
   mode‑slope drive shape was built as a 0…1 morph and normalised two ways
   (mode‑1 match, then an energy match); by ear neither changed the
   character — it read as a taraf loudness knob and 0 sounded best.
   Removed: the knob, its `phiDT` table and its ABI are gone and the fitted
   0.90 L tap is the only drive (git history carries both measurements).
3. **Two‑way coupling among the rows — shipped as a KNOB, default off.**
   `bow_jt_couple` (above) feeds the rows' summed, DC‑blocked bridge force
   back into `F` one post‑pass block out (the deferred web forbids a literal
   one‑sample return). The first cut returned the UN‑blocked load, whose
   static‑wrap DC term made the instrument ring forever at a low strumming
   floor; blocked, normalized by the bank's Σ gout and expressed as 0…1 of
   half the measured divergence gain, the loop is bounded and the ring ends.
   Not baked: taking it means re‑fitting levels around it.
4. **Bone profile.** A real jawari is an asymmetric arc with a gentler slope
   toward the nut, lengthening the cascade rather than deepening it.
   Build‑time table, cheap to try.
5. **Damping law.** Per‑mode loss is a constant plus an f² roll‑off around
   `bow_jt_fhf`; real strings add an air term ∝ f — how long the high cluster
   survives the cascade.
6. **Port the tanpura contact string** under the sarangi web — costly
   (~9 %/core/row); only if 1–3 don't get there.

## Original coupling measurements

**The pickup must be DC‑BLOCKED, and that was the whole never‑silent bug.**
The raw per‑row load carries the row's static wrap preload as a constant
term, so the first cut of this knob parked a DC force on the played strings'
bridge — which then fed the drive record and charged every row with it. It
self‑excited from silence: a web nobody played, gate disarmed, settled to a
tail RMS of **2.6e‑1** at the top of the range (DC‑blocked: **5.7e‑3**, all
of it the wrap's contact micro limit‑cycle, DC offset 1.3e‑5 → 1.0e‑6). With
the gate armed and a real note it read as the instrument never going quiet: a
bowed Sa's 12 s ring parked at a constant **−42 dBFS with 0 of 34 rows
asleep**. Blocked, the same ring reads −49 / −65 / −87 dBFS at 3 / 5 / 7 s and
then truncates as the gate closes, **34 of 34 asleep** — the uncoupled ring's
own curve (−49 / −66 / −87). A row the gate puts to sleep also FADES its last
returned value out on the blocker's own rate instead of stepping to 0 (a step
on the shared bridge strums every other row); with the DC term gone that step
is small, so this is continuity insurance, not the fix.

**The bank normalization.** The kernel SUMS the rows into one return, so the
loop gain scales with how many rows the document holds and how loud they are —
the shipped Pilu bank is 34 rows. `rowCplScale` is therefore divided by the
bank's total row gain **Σ gout**, and one knob position means one loop gain
whatever the bank. Without it the knob's stable range was a property of the
document, which is why real playing diverged at ~0.04 where a single‑note
bench sweep said 0.2.

**The range is 0…1 of a MEASURED safe range** (`BowEngine.jtCoupleFullScale`
= 0.4 kernel gain — half the divergence gain). Measured on the HEAVY case,
because one note is far more forgiving than a chord: shipped Pilu bank, serial
jt, **Sa + Pa + Sa′ at full expression** held 1 s then a 4 s ring, output trim pulled
60 dB so the safety limiter cannot mask growth. The ring's fall from +1 s to
+4 s: **31 dB** uncoupled, 31 / 27 / 28 / 18 / 23 dB at 0.2 / 0.3 / 0.4 / 0.5
/ 0.6 — and at **0.8** it stops decaying and GROWS +6 dB through the last
second. Above that it only flattens (2.0 and up hold a plateau for the whole
ring; the kernel clamps the gain at 4). So 0.8 is the divergence gain, full
scale is 0.4, and the knob's top still decays 28 dB over that ring.

Not baked, deliberately: this is a sound‑design lever and it is judged by
ear. It is LOUD well before the top — the web bloom is the point — so pull
`bow_jt_gain` / `bow_bal` / `bow_jt_cap` with it.

## Original rebuild and continuity measurements

Parameters that are engine-build values (`rebuild`, and `hybrid` pushed above its built value) cannot be poked into a running kernel — they require constructing a fresh `BowEngine`. `RebuildCostTests` keeps the numbers honest:

| | |
|---|---|
| Neutral full-bank rebuild | **~34–36 ms** in the initialization benchmark (off-thread) |
| Deeply pressed low bank | **~324 ms** in the same benchmark; uses damped fallback |
| Published idle level | Below **−100 dBFS** in the measured banks; usually exactly zero |

**The settle path** uses a residual-checked continuous wrap and, for a neutral bank, a stationary state matched to the existing discrete contact step. Successful preparation starts with **one** 4096-frame warmup block. A failed solve or moved bone retains at least **five** blocks with 50 ms momentum damping. The setup renderer uses an empty control snapshot; held touches stay on the shared mapper and mount when the engine is published. After warmup, natural decay is restored and the output filters and room are reset, preserving the physical kernel state. This discards the synthetic setup chime's room tail rather than waiting for it to die. Each subsequent verification block checks both channels and their sum against **−100 dBFS**; up to 24 verification blocks are allowed, after which a still-noisy build returns nil and the host retains its existing engine. No limiter or gain fade substitutes for the silence check. The gate remains enabled under its normal contract.

`RebuildCostTests` covers crossfaded publication at **−80 dBFS**, tuned banks and neutral/pressed/open bones, and preservation of a held touch through silent setup. The timings above are measurements on one machine, not universal budgets. The implementation record (local research: `docs/history/Codex-2026-09-08-jawari-initialization.md`) has the before/after measurements and deliberate parity update.

**Continuity.** A fresh engine has zero string/taraf/room state, so a hard swap under a held note is a step (96% of level within 43 ms) and a hard swap during the ring cuts it (4.9% of the tail survives). `StringVoiceSource.setEngine` therefore keeps the outgoing engine rendering and equal-power crossfades into the new one over `StringVoiceSource.engineCrossfadeMs` (300 ms): seamless under a note, 69% of a ring survives. That costs 2× voice CPU for the fade window only (at the 128-frame buffer: 11% of realtime for one engine, 19% for two).

**Why the distinction exists internally.** Rebuilds still construct a fresh physical state and crossfade over 300 ms; difficult contact configurations cost more than neutral banks. They are suitable for structural edits, not tilt-rate sweeps. `ParamRegistry`'s `apply` field is therefore a routing hint; the user-facing truth is `ParamSpec.timing` (live / in-place / rebuild / hybrid), rendered identically in the Parameters-tab row help and [parameters.md](../parameters.md).

**Rest fractions.** A `hybrid` parameter's `ParamSpec.restFraction` keeps the shipped sound when its live scaler is at rest: jawari buzz rests at **1.0×** the built depth (the fitted sound), vibrato depth at **0×** (silent until the player asks). Get these wrong and the instrument boots sounding different from the artifact.

## Original in-place and zipper measurements

Most parameters do not rebuild at all. `BowEngine.setLiveParams` pushes an edit onto the **running** kernel: the per-sample scalars are overwritten (`bow_poly_set_scalars`) and the Swift-side mapping constants re-read. Nothing is reset — string histories, taraf ring, jawari web, room tail and note articulation carry straight through.

`ParamLivenessTests` classifies every parameter empirically (perturb it, rebuild the tables, diff what moved) into three in-place tiers — kernel scalars; keys that move no table (mapping constants, output/room/radiation); coefficient arrays (the body modal bank via `bow_set_body`, the jawari tables via `bow_jt_set_coeffs`) — plus the genuine rebuilds: `bow_body_modes` (resizes the bank) and the keys `BowEngine` reads once at construction (`bow_rev_rt60`, the `bow_st_*` spreads). Coefficient reloads keep histories: the body resonators keep their state (retuning the body under a note is click-free, the biquad-swap trick), and the jawari web keeps its settled wrap, relaxing into the new bone geometry the way a real jawari adjustment does.

**Trap:** `bow_jt_load` is the *init-only* entry point and it **mallocs** — calling it a second time leaks and re-allocates the web. Reloading jawari coefficients onto a live kernel is `bow_[poly_]jt_set_coeffs`, which overwrites in place and refuses on a shape change.

`ParamRegistry.inPlaceKeys` is the shipped set; `StringParamStore` tries the fast path and falls back to a rebuild when a touched key needs fresh tables. A pushed value settles within **0.03 dB** of an engine built with it baked in; a held note keeps 100% of its level and a decaying ring 76%.

### Zipper

The push writes coefficients directly, so `ZipperTests` measures it rather than assuming it safe. Friction coefficients cannot click by construction — they change how the string *evolves*, not the current sample (`bow_mu_s` swept over 2 s at 60 Hz: −2 dB excess HF vs a smooth sweep). The parameters that CAN click are the ones that multiply the signal, and only on a large instantaneous jump: a +17 dB `bow_live_trim` step mid-note is a **17.9×** seam (an audible click) with no ramp, 3.4× with a 25 ms chunk-rate ramp, and **0.0×** with per-sample `outGain` interpolation on top. Both are needed — the chunk ramp alone leaves a ~20% step at the first boundary — so `postChain` interpolates the output gain **across** the chunk, and the ramp caps the render chunk to 256 frames while it runs (otherwise an offline render resolves a whole 4096-frame glide in one step, which is exactly the click being prevented).

### The chunk cap is not neutral

Chunk size sets the control-interpolation grid and the jawari web's block boundaries, so splitting a 4096-frame offline render moves a chaotic friction loop onto a different (valid, but different) trajectory — a push that changed *nothing* deviates 41% of peak for this reason alone. The ramp is therefore armed only when a ramped quantity actually moved: a no-op push is bit-identical (`testNoOpPushIsBitIdentical`), and a coefficient-only reload does not arm it at all. For a real edit the chunk still splits, which is why a pushed value settles within ~0.4 dB of a rebuilt engine rather than exactly on it.

## Numerical-loss research context

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
