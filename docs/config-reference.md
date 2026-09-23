# Config Reference

System-level constants live in `Packages/TarabdaarCore/Sources/TarabdaarCore/Config.swift`. Every **instrument** parameter lives in `ParamRegistry.swift` instead — one `ParamSpec` per knob, rendered as the generated [Parameters](parameters.md) table — and tilt-binding endpoint ranges come from the target itself (`MapTarget.defaultRange` in `TiltMapping.swift`: 0–1 for a composite, the parameter's own range otherwise). See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping).

## Where each kind of value lives

| Kind | Home | Edited in |
|------|------|-----------|
| Voice parameters (`bow_*`, `tp_*`, `st_*`, `ctl_*`, `fx_*`) | `ParamRegistry` — every resting value, whatever its apply strategy, in `AppController.paramValues` (`tarabdaar.paramValues.v2`; the two earlier stores are read once when it is absent); `StringParamStore` holds the physics subset for the engine build | Parameters tab ⌘5, FX tab ⌘6 |
| Bow-axis curves | `AppController.bowAxisCurves` (`tarabdaar.bowAxisCurves.v1`, keyed by `expr` / `pos` / `press`); presets carry `bowAxisCurves`; legacy band parameters migrate automatically | Transforms tab |
| FX EQ curves (the points per insert) | `AppController.fxEQCurves` (`tarabdaar.fxCurves.v1`, keyed by the insert's prefix); presets carry them as `fxCurves` | FX tab ⌘6 |
| The tarab | the `[StringSpec]` table + chromatic set + follower on `InstrumentState` (`tarabdaar.sarangiState.v8`) | Strings tab ⌘2 |
| Composite parameters | `CompositeParam` on `AppController.composites` (`tarabdaar.compositeParams.v1`) — named 0–1 macros of parameter members each sweeping lo→hi; defaults Taraf Purity / Taraf Decay / Tone Tilt / Expression on slots 1–4 | Controls tab ⌘4 |
| Acceleration smoothing | `ctl_ipad_accel_smooth` / `ctl_jc_accel_smooth` in the same parameter registry and preset store | Controls tab ⌘4, Parameters tab ⌘5 |
| Tilt bindings | `tiltMapping` (`MapTarget` per dimension) | Controls tab ⌘4 |
| Arm / wrist calibration | `tarabdaar.armCal.v2` / `tarabdaar.wristCal.v1` | Setup tab ⌘7 |
| The playing scale | `PitchScale` via `ScaleStore`; the tonic is not persisted | Fret Pad tab ⌘3 |
| The whole rig | one `TarabdaarPreset` document per `.tarabdaar` file in `Application Support/Tarabdaar/Presets/` | Parameters tab preset toolbar |

## Parameter organization and descriptions

The registry groups parameters by the voice or stage they affect, then by function:

| Family | Groups |
| --- | --- |
| String | Bow stroke, Bow ranges, Attack, Bow recovery, Sustain motion, Slide response, Friction, Damping, Torsion |
| Body | Resonances, Formants, Bridge interaction |
| Taraf | Shared, Raga, Chromatic |
| Tanpura | Voice, Drones, Jawari |
| Sitar | Voice |
| Output | Mix & limiter, Tone & stereo, Room — the String engine's combined voice and taraf output; Tanpura and Sitar have their own voice trims |
| Controls | Fret pad, Glide, Strum, Strike blend, Acceleration smoothing |
| FX rack | Voice → Taraf, Voice, Taraf, Global insert points |

Every `ParamSpec` and repeated `FXKnob` requires an `effect`, `low` and `high`
description. The effect identifies the affected sound or control mechanism;
the endpoints explain direction, zero/off behavior, neutral values and any
prerequisites. Selectors describe their options instead of implying that a
higher number means more intensity or better quality. Dependencies belong in
the description; scope and update timing remain separate registry fields.

The Parameters tab displays these fields inline when a label is opened.
Tooltips, search and the generated [Parameters](parameters.md) reference use
the same text. Binding and composite labels include the group outside its
section; FX labels already include the insert point. Display groups and names
do not change preset keys, ranges, defaults or parameter routing.

Tanpura and Sitar share the same ordering and vocabulary for corresponding
voice controls. Both taraf banks start with level and decay normalization;
shared excitation, damping, tone and coupling remain in **Taraf · Shared**.
See [Sound Design](sound-design.md), [Sarangi](sarangi.md) and [FX](fx.md).

## Audio

| Constant | Value | Description |
|----------|-------|-------------|
| `sampleRate` | 48000 Hz | The graph rate — the artifacts' native rate (the String kernel renders 96 → 48 kHz into it, the plucked voices render at it); the output device is matched to it |
| `preferredOutputBufferFrames` | 128 | Output IO buffer on solid transports (built-in, USB, Thunderbolt) ≈ 2.7 ms — the play-latency floor; clamped to the device's range |
| `jitterProneOutputBufferFrames` | 512 | Output IO buffer for DisplayPort/HDMI, Bluetooth and AirPlay outputs, which cannot hold the ~3 ms cadence (`preferredBufferFrames(for:)`) |

## Motion and strike

| Constant | Value | Description |
|----------|-------|-------------|
| `linkTickHz` | 120 Hz | The wire rate: link pacing, glide queue and finger-accel sampler ticks |
| `motionUpdateRate` | 200 Hz | CoreMotion sample rate |
| `strikeMinG` / `strikeMaxG` | 0.01 g / 0.5 g | Softest / hardest tap on the shared strike law (`StrikeLaw`, log-scale 0…1) — the Strike envelope and Joy-Con Accel dimension use it |

## Fret Pad geometry

| Constant | Value | Description |
|----------|-------|-------------|
| `iPadScreenSize` | 1366 × 1024 | Logical landscape size of the reference iPad |
| `iPadToolbarHeight` | 34 pt | Toolbar + safe area subtracted to get the playing surface |
| `iPadSurfaceAspect` | ≈ 1.38 | Playing-surface aspect the Mac Fret Pad tab letterboxes to, so both surfaces draw the same picture |
| `fretPadHeightFraction` | 0.5 | The playable band's share of the surface height (`fretPadBandRect`) |
| `fretPadBandTopFraction` | 0.3 | The band's top edge as a fraction of the surface height — a little below centred (0.25); 0.5 is flush with the bottom |
| `chordBarShown` | false | Whether the chord bar is laid out at all; off, `chordBarCells` resolves to no cells on either surface (hidden for now) |

The Snap distance (24 px default, `AppController.init`) and the fret warp are not here — Snap rides the synced arrangement, the warp is the `ctl_fret_warp` registry parameter.

## Display

| Constant | Value | Description |
|----------|-------|-------------|
