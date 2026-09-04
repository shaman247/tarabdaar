# Tech Debt

The live backlog from the 2026-09-04 whole-tree audit (reuse, simplification,
efficiency, altitude). Present tense, like every other page: each entry says
what the code does now and what it should do. An entry is DELETED when its
change lands — git holds the story, this page holds only what is still open.
Items are ordered by value within each section; the **Decisions** are the
owner's, taken 2026-09-04, and bound the work.

**Decisions.** Migrations: delete all four (single developer, one device
each; a stale install re-defaults). `ctl_strum_thresh`: becomes 0…1 with
saved values migrated (÷127) on load. Kernel: hash-changing efficiency work
is re-blessed with a before/after render for an A/B by ear.

## Altitude — special cases on shared mechanisms

1. **`applyParamToVoice` has five name-keyed escape hatches** ahead of the
   registry's `apply` switch (`ctl_strike_window`, `ctl_strum_expr`,
   `ctl_strum_thresh`, `ctl_glide_*`, `ctl_fret_warp`), each hand-routing to
   the axes, the strummer or the glide queue. The registry declares them
   `.live` but has no notion of *where* a live value goes. Change: a routing
   `target` on `ParamSpec` (`.stringVoice`, `.strike`, `.strum`, `.glide`,
   `.fretWarp`) so the apply is a pure switch.
2. **The bow axes still speak CC numbers** (`cc: 11/1/74/75` in
   `AudioEngine+StringVoice`, switched back into `mapper.setAxis`), and
   `ctl_strum_thresh` is 1…127 with ≥126.5 = off, `macExpressionLevel` is a
   `UInt8` /127, and velocity goes ×127 → clamp → /127 into `TanpuraEngine`.
   Change: name the four axes, 0…1 everywhere the wire byte is not involved.
3. **Two tonics on the Mac.** `pitchPad` and `fretPad` are two
   `PitchPadEngine`s each with `tonicMidi`/`tonicCents`, mirrored by Combine,
   with five separate `(scale, tonic)` subscriptions at four debounce times
   (400/250/750/300 ms) plus `pushCurrentState`'s own rate limiter. Change:
   one `Tuning` value (scale + tonic Hz) owned once, one change publisher.
4. **Six hand-rolled debounces** beside `DebouncedParamFlush`
   (`StringParamStore` 60 ms, `SarangiStore` 50 ms + 400 ms, the tanpura
   table 750 ms, `pushCurrentState` 300 ms, the MIDI retry). The rebuild path
   is debounced twice in series (250 ms → 60 ms). Change: one `Debouncer`.
5. **The `force:` pacing bypass** threaded `AppController` → `LinkRelays` →
   `TarabLink` lets callers decide whether a `JOYCON_STATE` is state or
   display. Change: the relay compares the acted-on fields against the last
   emitted frame and sends immediately on change.
6. **Knob clamps and neutrals re-declared outside the registry**
   (`StringVoiceSource.ControlKnob`, `GlideSequencer` clamps that disagree
   with the registry ranges, 157 literal `bp.v(key, default)` fallbacks) and
   `ParamUnificationTests` pins a third copy. Change: `ParamSpec.clamp(_:)`
   and `spec.def` as the single source.
7. **Resting values live in three stores selected by apply strategy**
   (`paramValue` / `setParamValue` / `resetParam` each branch three ways).
   Change: one value store; `apply` decides only how a value reaches the
   engine.
8. **The voices are not behind one protocol**: `inst != .string` at every
   touch entry point, `switch inst` in the scope, `mode ==` for drones, and
   the UI repeats it. Change: a `PlayedVoice` protocol both sources adopt.
9. **The iPad shapes tilt and strike before the wire** (`MotionManager`'s
   yaw high-pass with a 60 s leak and drift learner, the peak-hold strike
   envelope) and the Mac re-envelopes the same byte. Change: stream raw
   attitude/acceleration; the Mac owns every time constant.
10. **`JOYCON_STATE` fields decoded by hand in `ContentView`** (`b/255·2−1`,
    `strikeWin == 0 ? 2.0 : ·0.05`, `Int8(bitPattern:)`) with the inverse in
    `TarabLink`; `ScaleSync` is a second self-versioned 7-bit codec inside
    TLP. Change: the codec exposes encode/decode pairs; the blobs carry TLP's
    version.
11. **Tests that pin setter pass-through**: `LinkRelayTests` "each setter
    pushes"; `BowedStringEngineTests` asserts six table coefficients to
    1e-14 outside `Goldens/`. Change: drop the first; move the second to a
    golden or drop it.

## Reuse — the same thing written twice

12. **The engine-swap crossfade** (`State.renderMix`, `setEngine`) is
    byte-identical in `StringVoiceSource` and `TanpuraVoiceSource` except
    the engine type and the ring depth (8 vs 4 — already diverged). Change:
    `EngineCrossfader<Engine>` in TarabdaarCore.
13. **The fret-pad touch pipeline** (`fretFieldLog` → snap → `noteOn` →
    assist → recorder → 60 Hz settle timer) is written for the Mac in
    `FretPadView` and for the iPad in `PitchPadView_iOS`; the iOS copy alone
    has `radiusPt`/`velocity01`. Change: `FretTouchPlayer` in TarabdaarCore.
14. **The fractional-MIDI ↔ Hz carrier** `440·2^((m−69)/12)` is written in
    ~12 places and there are two note-name tables (`Scale.pitchClassNames`,
    `NoteName.names`). Change: `Pitch.hz(fractionalMidi:)` /
    `Pitch.fractionalMidi(hz:)` in `Scale.swift`; SarangiKit keeps
    `NoteName` only for parsing tonic strings.
15. **Modal-string table math** (the HF t60 law, σ = 6.91/t60, the rotation
    coefficients at dt and dt/4, the `√(2/L)·sin` shapes) is duplicated
    between `BowTables` and `TanpuraTables`. Change: a `ModalString` helper.
16. **The two C kernels share hot helpers by copy**: `jt_fastpow` ==
    `tp_fastpow` (deleted 2026-09-04 as unused), `jt_zone` vs `tp_zone`,
    `dup_f` vs `tp_dup`, and the worker-pool/dispatch scaffolding with the
    same ring sizes. Change: `kernel_common.h` with static inlines.
17. **The leaky relative-yaw law** is in `MotionManager.updateYaw` and
    `JoyConFusion.updateRelativeYaw` with the same three constants. Change:
    `RelativeYawTracker` (folds into item 9).
18. **The 14-bit split** `UInt8(x >> 7), UInt8(x & 0x7F)` is hand-rolled 8×
    in `ScaleSync`. Change: `put14`/`get14`.
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
23. **The UserDefaults-JSON idiom** is repeated 11×. Change:
    `DefaultsStore.load/save`.
24. **Minor:** `ParametersView.row` hand-rolls `ParamSliderRow`'s shape; 138
    inline `min(max())` clamps; the fret-line stroke loop in both pad
    canvases; `ParametersView`/`FXView` compose FX keys by string prefix.

## Simplification — dead paths and seams

25. **Migrations (decided: delete):** `DimensionMapping.load` v5→v6,
    `TiltCalibrator` `legacyKey01`, `TarabdaarPreset.decode`'s `.sarangi`
    fallback, `FretArrangementStore`'s 4-slot drone migration.
26. **Dead two-component pitch-correction path** (`pitchKnotsRel/CentsRel/
    KnotsAbs/CentsAbs/CentsPress` in `BowConfig`, the branch in
    `BowControls`): the shipped artifact carries only `pitch_knots_oct`.
27. **Unread keys in `bowed_string.json`**: `bow_jw_R`, `ctl_expr_gain`,
    `ctl_expr_off`, `ctl_pos_off`, `ctl_pos_scale`, `ctl_press_off`,
    `ctl_press_scale`.
28. **Definition-only API still resident** (files the audit could not touch
    at the time): `Biquad.butterBandpass`, `Biquad.modeAllpass`,
    `Cx.expMinusJ`, `BowEngine.liveLevelTrim`.
31. **Oversized seams:** `AppController.start()` (~300 lines of independent
    wiring); `bow_kernel_poly.c` (the jt/taraf half is separable into
    `bow_jt.c`).
32. **Leftovers:** `SarangiEditorView.swift` holds only `PresetToolbar`;
    `Preset` is a one-case `CaseIterable` driving a one-button `ForEach`;
    `tlpsim` is referenced by nothing and undocumented.
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
38. **`TiltCalibrator.tick`** allocates three arrays and does an array `!=`
    per tick at IMU rate.
39. **Per-frame heap traffic on both 120 Hz paths**: ingest builds a `Set`, a
    dictionary and an array per frame; the sender allocates five buffers per
    frame. Change: pooled scratch per stage.
40. **String-dispatched bindings per wire frame** (`ParamRegistry.spec`
    hash, four `==` and a `hasPrefix`, a string `switch`, `knobByKey`,
    `FXPoint.allCases` scan). Change: `ParamSpec` carries a pre-resolved
    apply target (falls out of item 1).