# Config Reference

System-level tunable parameters live in `Armpad/Armpad/Config.swift`. Dimension-mappable parameter ranges (glide speed, amplitude, vibrato, etc.) are defined in `TiltMapping.swift` via `MappableParameter.defaultRange` and configured at runtime in the MAP editor. See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping) for the full parameter table.

## Keyboard

Keyboard range (`startNote`, `noteCount`, `octaveCount`) is now configured via the **Scale Editor**, not Config.swift. See [Scales and Tuning](scales-and-tuning.md).

## Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| `velocityDelay` | 200ms | Time to wait after touch for accelerometer spike. Skipped entirely when no parameter uses the Pressure dimension. |

**Tuning**: Lower = faster response but may miss the spike. Higher = more reliable velocity but adds latency.

## Glide

| Parameter | Value | Description |
|-----------|-------|-------------|
| `glideDistanceExponent` | 0.6 | Sublinear distance scaling. 1.0 = linear, 0.5 = sqrt |
| `releaseGracePeriod` | 50ms | Window after all touches lift to connect next tap as glide |
| `glideMidpoint` | 0.6 | Sigmoid midpoint `m`. Lower = faster onset |

**Tuning**:
- `glideDistanceExponent`: Lower = larger intervals complete faster relative to small ones. At 0.6, an octave (12 semitones) takes ~4.4x a single semitone rather than 12x.
- `releaseGracePeriod`: Increase if notes are disconnecting when you intend them to be legato.
- `glideMidpoint`: 0.5 = symmetric. Lower values shift the fast phase earlier (faster onset, gentler landing).
- Glide speed and compression ranges are dimension-mappable (defaults: 20–200 ms/st and 15–40 ms).
- Glide curve steepness (k) is dimension-mappable (default range 3–12).

## Drag Glide

| Parameter | Value | Description |
|-----------|-------|-------------|
| `dragSnapDelay` | 60ms | How long the finger must be still before snapping to a scale tone |

**Tuning**:
- `dragSnapDelay`: Lower = snaps sooner when finger pauses. Higher = more tolerance for brief pauses mid-slide.
- Drag smoothing is dimension-mappable (default range 0.1–0.5). Snap smoothing is 2× the base value, clamped to 1.0.

## MIDI

| Parameter | Value | Description |
|-----------|-------|-------------|
| `midiPitchBendRange` | ±48 semitones | Must match the receiving synth's pitch bend range |

**Tuning**: Must exactly match the receiving instrument. Ableton MPE default is ±48. Other synths may use ±2, ±12, or ±24. Mismatched values cause pitch bend to be scaled incorrectly.

## Audio

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sampleRate` | 44100 Hz | Audio sample rate |
| `frequencySmoothing` | 0.002 | Per-sample smoothing coefficient (~11ms time constant) |
| `attackCoefficient` | 0.05 | Envelope attack speed (~2ms to reach full amplitude) |
| `releaseCoefficient` | 0.9993 | Envelope release speed (~50ms to fade out) |
| `maxAmplitude` | 0.3 | Maximum amplitude at velocity 127 (headroom for clipping) |

**Tuning**:
- `frequencySmoothing`: Lower = smoother glides on audio thread, but more latency. Higher = tighter tracking but potential zipper noise.
- `attackCoefficient`: Higher = snappier attack. Lower = softer onset. Keep below 0.1 to avoid clicks.
- `releaseCoefficient`: Closer to 1.0 = slower release. Must be < 1.0. Voices are removed when envelope < 0.001.
- `maxAmplitude`: Increase for louder output (may clip with amplitude boost). Decrease if distortion occurs.

## Motion

| Parameter | Value | Description |
|-----------|-------|-------------|
| `motionUpdateRate` | 200 Hz | CoreMotion sample rate |
| `accelHistoryLength` | 200 | Display buffer size (~1 second at 200Hz) |
| `accelBufferDuration` | 100ms | Ring buffer for velocity correlation |
| `peakDecayRate` | 0.95 | Peak indicator decay per sample |

**Tuning**: Generally don't change these. `motionUpdateRate` above 200Hz gives diminishing returns. `accelBufferDuration` must be > `velocityDelay`.

## Velocity Mapping

| Parameter | Value | Description |
|-----------|-------|-------------|
| `velocityMinG` | 0.01g | Accelerometer reading for softest playable tap |
| `velocityMaxG` | 0.5g | Accelerometer reading for hardest tap |

**Tuning**: Adjust based on the player's touch and the specific iPad model. Narrower range = more sensitive. `velocityMinG` too low may trigger from ambient vibration. These only apply when Pressure is in use.

## Sliders

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sliderWidth` | 150pt | Slider track length (~1.5 inches on iPad) |
| `sliderHeight` | 66pt | Slider track height (1.5× finger-width) |
| `slider1Default` | 0.5 | Value Slider 1 returns to when released |
| `slider2Default` | 0.5 | Value Slider 2 returns to when released |

**Tuning**: Adjust defaults to match the most common resting value for the parameter they're mapped to. `sliderWidth`/`sliderHeight` can be adjusted for ergonomics.

## Polyphonic Mode

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maxPolyVoices` | 6 | Maximum simultaneous voices in poly mode |

## Display

| Parameter | Value | Description |
|-----------|-------|-------------|
| `pitchHistoryLength` | 120 | Pitch graph buffer (~2 seconds at 60Hz) |
| `peakDelayHistory` | 20 | Rolling window for velocity delay instrumentation |

**Tuning**: Increase `pitchHistoryLength` for a longer graph (more memory, wider view). Decrease for a more zoomed-in, responsive view.
