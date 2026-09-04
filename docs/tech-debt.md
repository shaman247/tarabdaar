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

16. **The two kernels' worker pools** (`jt_pool_run`/`jt_dispatch_run`
    vs `tp_worker_run`/`tp_dispatch_run`) are the same gen/condvar
    handshake, 1 ms `pthread_cond_timedwait` backstop and job ring over
    two different structs. Change: one pool primitive in
    `kernel_common.h` both instantiate.
19. **Five one-pole spellings that are not the shared form**: the bow
    kernel's jt radiation blocker (`-2·M_PI·8·jtDiv/sr`, a different
    association), the drone-noise band-pass pair and its live setter
    (`-2·3.14159265358979·f·dt`, a truncated π), the biquad body poles,
    `Reverb`'s `exp(-1/(sr·tauMs/1000))`, and the block-rate forms in the
    LiveParams slews. Each would change bits under the helper; leave or
    re-bless deliberately.
24. **Minor:** `ParametersView.row` hand-rolls `ParamSliderRow`'s shape; 138
    inline `min(max())` clamps; the fret-line stroke loop in both pad
    canvases; `ParametersView`/`FXView` compose FX keys by string prefix.

## Simplification — dead paths and seams

## Efficiency — wasted work by thread

36. **Render-chunk lock hygiene:** seven `tiltLock` acquisitions per chunk
    across the BowEngine extensions; `TanpuraVoiceSource` sums squares under
    its lock every callback whether or not `outputLevel()` is polled; the
    kernel `malloc`s scratch per block when the jt pool is < 2 threads.
39. **Per-frame heap traffic on the 120 Hz sender**: `touches.map` →
    `encode()` → `pack` → `envelope` → a `MIDIPacketList` allocation, five
    buffers per frame. Change: pooled scratch per stage (the send runs on
    more than one queue, so the scratch needs an owner per queue).
40. **String-dispatched bindings per wire frame** (`ParamRegistry.spec`
    hash, four `==` and a `hasPrefix`, a string `switch`, `knobByKey`,
    `FXPoint.allCases` scan). Change: `ParamSpec` carries a pre-resolved
    apply target (falls out of item 1).