# Config Reference

System-level constants live in `Packages/TarabdaarCore/Sources/TarabdaarCore/Config.swift`. Every **instrument** parameter lives in `ParamRegistry.swift` instead — one `ParamSpec` per knob, rendered as the generated [Parameters](parameters.md) table — and tilt-binding endpoint ranges come from the target itself (`MapTarget.defaultRange` in `TiltMapping.swift`: 0–1 for a composite, the parameter's own range otherwise). See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping).

## Where each kind of value lives

| Kind | Home | Edited in |
|------|------|-----------|
| Voice parameters (`bow_*`, `tp_*`, `st_*`, `ctl_*`, `fx_*`) | `ParamRegistry` — `.rebuild` values persist as the `StringParamStore` override dict (`tarabdaar.stringOverrides.v1`), `.live`/`.hybrid` resting values as `AppController.paramValues` (`tarabdaar.controlDefaults.v1`) | Parameters tab ⌘5, FX tab ⌘6 |
| The tarab | the `[StringSpec]` table + chromatic set + follower on `InstrumentState` (`tarabdaar.sarangiState.v8`) | Strings tab ⌘2 |
| Composite parameters | `CompositeParam` on `AppController.composites` (`tarabdaar.compositeParams.v1`) — named 0–1 macros of parameter members each sweeping lo→hi; defaults Taraf Purity / Taraf Decay / Tone Tilt / Expression on slots 1–4; audition names `stringPurity` / `stringTarafDecay` / `stringToneTilt` + `composite1`–`composite8` | Controls tab ⌘4 |
| Tilt bindings | `tiltMapping` (`MapTarget` per dimension) | Controls tab ⌘4 |
| Arm / wrist calibration | `tarabdaar.armCal.v2` / `tarabdaar.wristCal.v1` | Setup tab ⌘7 |
| The playing scale | `PitchScale` via `ScaleStore`; the tonic is not persisted | Fret Pad tab ⌘3 |
| The whole rig | one `TarabdaarPreset` document per `.tarabdaar` file in `Application Support/Tarabdaar/Presets/` | Parameters tab preset toolbar |

Audition scores reach any parameter via `voiceParam` name `param.<key>` or `string.<key>` ([Simulator](simulator.md)). The registry groups are Bow stroke · Body (formula modes) · Bow & string · Playing ranges · Jawari taraf (modal contact) · Chromatic bridge (jawari taraf) · Taraf coupling (bridge load) · Liveness · Articulation · Radiation & output · Tanpura · Sitar · Glide · Controller · Strike blend · Fret pad · the four FX points. See [Sound Design](sound-design.md), [Sarangi](sarangi.md) and [FX](fx.md).

## Audio

| Constant | Value | Description |
|----------|-------|-------------|
| `sampleRate` | 44100 Hz | The nominal engine rate reported in Setup (the String kernel renders 96 → 48 kHz at its artifact's native rate) |
| `preferredOutputBufferFrames` | 128 | Output IO buffer on solid transports (built-in, USB, Thunderbolt) ≈ 2.7 ms — the play-latency floor; clamped to the device's range |
| `jitterProneOutputBufferFrames` | 512 | Output IO buffer for DisplayPort/HDMI, Bluetooth and AirPlay outputs, which cannot hold the ~3 ms cadence (`preferredBufferFrames(for:)`) |
| `frequencySmoothing`, `attackCoefficient`, `releaseCoefficient`, `maxAmplitude` | 0.002 / 0.05 / 0.9993 / 0.3 | Legacy envelope constants; unreferenced |

## Motion and strike

| Constant | Value | Description |
|----------|-------|-------------|
| `motionUpdateRate` | 200 Hz | CoreMotion sample rate |
| `accelHistoryLength` | 200 | Display buffer (~1 s at 200 Hz) |
| `accelBufferDuration` | 100 ms | Ring buffer the strike estimate scans; must exceed `velocityLookback` |
| `peakDecayRate` | 0.95 | Peak indicator decay per sample |
| `velocityMinG` / `velocityMaxG` | 0.01 g / 0.5 g | Softest / hardest tap on the shared strike law (`StrikeLaw`, log-scale 0…1) — the per-touch strike velocity, the strike envelope, the Joy-Con accel dimension and the audition velocity range all use it |
| `velocityLookback` | 50 ms | The TRAILING window a fret-pad onset scans for its strike spike (`MotionSource.strikeVelocity01`) — backward-looking, so the onset never waits |
| `velocityDelay` | 20 ms | Unreferenced |

## Fret Pad geometry

| Constant | Value | Description |
|----------|-------|-------------|
| `iPadScreenSize` | 1366 × 1024 | Logical landscape size of the reference iPad |
| `iPadToolbarHeight` | 34 pt | Toolbar + safe area subtracted to get the playing surface |
| `iPadSurfaceAspect` | ≈ 1.38 | Playing-surface aspect the Mac Fret Pad tab letterboxes to, so both surfaces draw the same picture |
| `fretPadHeightFraction` | 0.5 | The playable band's share of the surface height, vertically centered (`fretPadBandRect`) |

The Snap distance (24 px default, `AppController.init`) and the fret warp are not here — Snap rides the synced arrangement, the warp is the `ctl_fret_warp` registry parameter.

## In-process MIDI vocabulary

These serve the in-process paths only — audition scores, external controllers, the headless simulator's `NoteManager`. Nothing on the TLP wire reads them.

| Constant | Value | Description |
|----------|-------|-------------|
| `midiPitchBendRange` | ±48 semitones | Bend range of the in-process MPE vocabulary (`sendHostedMIDI`, `MIDIInput`, the simulator) |
| `maxPolyVoices` | 16 | Voice-slot capacity of `NoteManager.pitchChannels` and the pitch-history graph — a capacity, not a mode; the played voice's polyphony is `bow_live_poly` strings on one bridge |
| `glideDistanceExponent` / `glideMidpoint` / `releaseGracePeriod` / `dragSnapDelay` | 0.6 / 0.6 / 50 ms / 60 ms | `NoteManager`'s scripted glide and drag-snap shaping for audition `glide` events |
| `slider1Default` / `slider2Default` | 0.5 | Rest values of the simulator's two slider dimensions |
| `sliderWidth` / `sliderHeight` | 150 / 66 pt | Unreferenced |

## Display

| Constant | Value | Description |
|----------|-------|-------------|
| `pitchHistoryLength` | 120 | `NoteManager` pitch graph buffer (~2 s at 60 Hz) |
| `peakDelayHistory` | 20 | Unreferenced |
