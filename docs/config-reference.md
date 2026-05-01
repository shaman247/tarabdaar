# Config Reference

System-level tunable parameters live in `Starpad/Starpad/Config.swift`. Dimension-mappable parameter ranges (glide speed, amplitude, vibrato, etc.) are defined in `TiltMapping.swift` via `MappableParameter.defaultRange` and configured at runtime in the MAP editor. See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping) for the full parameter table.

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

## Modal Synth

Starpad's synth is a modal-synthesis voice bank. Each played or sympathetic string is a collection of decaying sinusoidal resonators (one per partial), excited by a pluck/bow generator. Mode decay is independent of excitation — so notes ring after release and sympathetic strings continue humming after the played note has stopped. See [Sound Design](sound-design.md) for the full architecture.

All parameters below are dimension-mappable.

### Played-string timbre

| Parameter | Default Range | Description |
|-----------|---------------|-------------|
| `harmonicFalloff` | 0–5 | Exponent for initial partial amplitudes: `g_k ∝ 1/k^falloff`, RMS-normalized. 0 = flat (all partials equal, buzzy); 1 = saw-like; 2 (midpoint) = lightly rounded; 4+ approaches pure sine. Shared between played and sympathetic banks. |
| `noteAttack` | 5–500 ms | Excitation envelope attack time. Short (~5 ms) = percussive pluck; long (300+ ms) = slow bow onset. Controls how fast `bowForce` ramps in at noteOn. |
| `bowForce` | 0–0.3 | Continuous noise-drive level into the modal bank. 0 = pure pluck excitation; 0.15+ = sustained bow. Scales with the excitation envelope so it fades with the note. |
| `pluckPosition` | 0–0.5 | Comb filter position for the pluck impulse (fraction of fundamental period). 0 = center-struck, fundamental-dominant; 0.2+ = bright, sitar-like. The comb `y = x − x[n−P]` creates a classic position-dependent spectral shape. |
| `stringDecay` | 0.5–8 s | Mode T60 (time for amplitude to fall 60 dB, ≈ audible tail length) for played strings. A 3 s setting gives roughly a 3 s tail. Per-mode decay uses `T60_k = stringDecay / k^dampingTilt`. |
| `dampingTilt` | 0–2 | Frequency-dependent damping exponent α. 0 = all partials decay at the same rate (bell-like). 1 = natural-string behavior (high partials decay k× faster). 2 = notes start bright and darken sharply into the fundamental. Shared across played + sym. |
| `inharmonicity` | 0–0.03 | Stiffness factor B. Partial frequencies follow `f_k = k·f₀·√(1+B·k²)`. 0 = pure harmonics. 0.001–0.003 = piano-like. 0.01–0.025 = sitar jawari clang. |

### Sympathetic strings

| Parameter | Default Range | Description |
|-----------|---------------|-------------|
| `sympatheticVolume` | 0–1 | Overall multiplier on per-bank coupling gain. Scales how strongly the kernel-derived drive affects sympathetic banks. |
| `symCoupling` | 0–1 | Global scalar on the sympathetic drive bus. Multiplies kernel output uniformly. 0 = sym strings silent; 1 = full harmonic bleed from played audio. |
| `symDecay` | 2–20 s | Mode T60 for sympathetic banks — time to fall 60 dB. Should be longer than `stringDecay`: sym strings are the halo that lingers after you release. |
| `sympatheticWidth` | 0.3–4 st | Gaussian σ in semitones for the excitation kernel. Small = only near-exact ratios excite; large = broader response. |
| `sympatheticSpread` | 0–2 | Multiplier on every **non-unison** kernel weight. 0 = proximity-only (unison Gaussian); 1 = default harmonic/proximity balance; 2 = harmonic intervals emphasized. |
| `sympatheticConsonance` | 0–10 | Exponent on each **non-unison** weight. 0 = all intervals equal; 1 = default; higher widens the gap between consonant and dissonant intervals. |
| `sympatheticDetune` | 0–15 cents | Unison detune between the ±pair of banks spawned per enabled sympathetic scale note. They beat to produce a natural shimmer. |

### Bus

| Parameter | Default Range | Description |
|-----------|---------------|-------------|
| `reverbMix` | 0–60 % | Wet/dry mix of the reverb bus (`AVAudioUnitReverb.mediumHall`). Post-mix insert. Higher values place everything in a larger virtual room. |

**Tuning**:

- Start with `symCoupling` around 0.6 and `sympatheticVolume` 0.5 for a clear halo. Push `symCoupling` → 1 and `symDecay` → 15 s for full sarangi-like overtones.
- `dampingTilt` at 0.8–1.2 gives natural decay behavior; near 0 gives a bell-like quality (all partials ring equally long).
- For sitar: push `inharmonicity` to 0.015+, `pluckPosition` around 0.2, `noteAttack` under 20 ms, `bowForce` to 0.
- For sarangi: `inharmonicity` near 0, `pluckPosition` 0, `noteAttack` ~150 ms, `bowForce` around 0.18.
- `sympatheticWidth` ≈ 2 st is the default; drop to 0.3 st for piano-like selectivity (only just-intonation pitches excite); push to 4 st for a wash.

Configure *which* sympathetic strings exist via the **Strings** tab in the Scale Editor — each enabled MIDI note becomes one nominal f₀ (rendered as two ±detune banks). See [MIDI & Audio](midi-and-audio.md#sympathetic-excitation-kernel) for the kernel formula.

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
