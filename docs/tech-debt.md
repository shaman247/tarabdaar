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

## Altitude — special cases on shared mechanisms

3. **Two tonics on the Mac.** `pitchPad` and `fretPad` are two
   `PitchPadEngine`s each with `tonicMidi`/`tonicCents`, mirrored by Combine,
   with five separate `(scale, tonic)` subscriptions at four debounce times
   (400/250/750/300 ms) plus `pushCurrentState`'s own rate limiter. Change:
   one `Tuning` value (scale + tonic Hz) owned once, one change publisher.
6. **Knob neutrals re-declared outside the registry**
   (`StringVoiceSource.ControlKnob` neutrals and clamps, 157 literal
   `bp.v(key, default)` fallbacks in the SarangiKit builders) and
   `ParamUnificationTests` pins a third copy. Change: `spec.def` and
   `ParamSpec.clamp(_:)` as the single source (the glide queue already
   clamps by the registry).
7. **Resting values live in three stores selected by apply strategy**
   (`paramValue` / `setParamValue` / `resetParam` each branch three ways).
   Change: one value store; `apply` decides only how a value reaches the
   engine.
8. **The voices are not behind one protocol**: `inst != .string` at every
   touch entry point, `switch inst` in the scope, `mode ==` for drones, and
   the UI repeats it. Change: a `PlayedVoice` protocol both sources adopt.
10. **`ScaleSync` is a second self-versioned 7-bit codec inside TLP**
    (`version = 4`/`6` on the scale and arrangement blobs). Change: the
    blobs carry TLP's version.
## Reuse — the same thing written twice

14. **Three fractional-MIDI carriers still spelled out** instead of
    `SarangiKit.Pitch`: `AudioEngine+Scope.swift`, `ScopeView.swift`, and
    `BowControls.swift:252` (hash-pinned; the same expression).
15. **Modal-string table math** (the HF t60 law, σ = 6.91/t60, the rotation
    coefficients at dt and dt/4, the `√(2/L)·sin` shapes) is duplicated
    between `BowTables` and `TanpuraTables`. Change: a `ModalString` helper.
16. **The two C kernels share hot helpers by copy**: `jt_fastpow` ==
    `tp_fastpow` (deleted 2026-09-04 as unused), `jt_zone` vs `tp_zone`,
    `dup_f` vs `tp_dup`, and the worker-pool/dispatch scaffolding with the
    same ring sizes. Change: `kernel_common.h` with static inlines.
19. **The one-pole coefficient** `1 − exp(−2π·f/sr)` and `1 − exp(−dt/τ)`
    are spelled out ~35× across Swift and C, mixing `M_PI` with a literal
    π. Change: `onepole_hz`/`onepole_tau` inlines and a Swift twin. Renders
    are hash-pinned: consolidate as a mechanical move that reproduces the
    same expression order.
20. **xorshift64** appears four times with three different word→float
    normalisations. Change: one `XorShift64`, keeping each site's exact
    normalisation.
21. **The bow scope level law** in `AudioEngine+Scope` re-derives
    `TLPVolume.level01`. Change: call it.
22. **Sample rate** is `Config.sampleRate` 44100 for the graph and a 48000
    literal default in both sources, `BowEngine.init` and the tanpura
    kernel's cost budget. Change: pass `Config.sampleRate` explicitly.
24. **Minor:** `ParametersView.row` hand-rolls `ParamSliderRow`'s shape; 138
    inline `min(max())` clamps; the fret-line stroke loop in both pad
    canvases; `ParametersView`/`FXView` compose FX keys by string prefix.

## Simplification — dead paths and seams

26. **Dead two-component pitch-correction path** (`pitchKnotsRel/CentsRel/
    KnotsAbs/CentsAbs/CentsPress` in `BowConfig`, the branch in
    `BowControls`): the shipped artifact carries only `pitch_knots_oct`.
28. **Definition-only API still resident** (files the audit could not touch
    at the time): `Biquad.butterBandpass`, `Biquad.modeAllpass`,
    `Cx.expMinusJ`, `BowEngine.liveLevelTrim`.
31. **`bow_kernel_poly.c`** (3200 lines): the jt/taraf half is separable
    into `bow_jt.c` with a private header; today every taraf edit means
    reading past the friction solver.
32. **`tlpsim`** (`Packages/TarabdaarCore/Sources/tlpsim`) is referenced by
    nothing and undocumented — keep deliberately or delete.
## Efficiency — wasted work by thread

35. **`tp_sav_contact`** does two `pow`s per contact point (`pow(em, α+1)`
    and `pow(em, α)`) where one and a multiply suffice — not bit-exact, so
    it waits for a tanpura lockstep re-bless.
36. **Render-chunk lock hygiene:** seven `tiltLock` acquisitions per chunk
    across the BowEngine extensions; `TanpuraVoiceSource` sums squares under
    its lock every callback whether or not `outputLevel()` is polled; the
    kernel `malloc`s scratch per block when the jt pool is < 2 threads.
37. **`applyLiveParams` rebuilds every open-string table** (body filter
    design, 6×6 loops) when only a scalar moved; `TanpuraVoiceSource.
    isAvailable` decodes a 25 KB artifact to test non-nil.
39. **Per-frame heap traffic on the 120 Hz sender**: `touches.map` →
    `encode()` → `pack` → `envelope` → a `MIDIPacketList` allocation, five
    buffers per frame. Change: pooled scratch per stage (the send runs on
    more than one queue, so the scratch needs an owner per queue).
40. **String-dispatched bindings per wire frame** (`ParamRegistry.spec`
    hash, four `==` and a `hasPrefix`, a string `switch`, `knobByKey`,
    `FXPoint.allCases` scan). Change: `ParamSpec` carries a pre-resolved
    apply target (falls out of item 1).