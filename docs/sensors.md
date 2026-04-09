# Sensors

## MotionManager

Wraps CoreMotion's `CMMotionManager` at 200Hz (`motionUpdateRate`). Publishes on the main thread.

### Attitude (Orientation)

- `pitch`: tilt forward/back (radians)
- `roll`: tilt left/right (radians)
- `yaw`: rotation around vertical axis (radians)
- Convenience properties: `pitchDegrees`, `rollDegrees`, `yawDegrees`

### User Acceleration

Gravity-removed acceleration in g's:
- `userAccelX`, `userAccelY`, `userAccelZ`: per-axis
- `accelMagnitude`: `sqrt(x^2 + y^2 + z^2)`
- `recentPeakAccel`: peak with fast attack / slow decay (`peakDecayRate = 0.95`)

### Accelerometer Buffer

A timestamped ring buffer (`accelBuffer`) stores the last 100ms (`accelBufferDuration`) of acceleration samples for velocity correlation:

```swift
struct AccelSample {
    let timestamp: TimeInterval  // CMMotionManager timestamp
    let magnitude: Double        // acceleration magnitude in g's
}
```

`peakAccelSince(timestamp:)` returns the peak magnitude and its timestamp from all samples after the given time. Used by NoteManager to find the impact spike in the 20ms window after a touch.

## Velocity Detection

iPads have no pressure-sensitive touch. Armpad estimates strike velocity from the accelerometer:

1. `touchBegan` records the touch timestamp and starts a 20ms timer
2. After 20ms, `fireNote` calls `motionManager.peakAccelSince(touchTimestamp)`
3. The peak acceleration magnitude is mapped to MIDI velocity:

```
clamped = clamp(peakG, velocityMinG, velocityMaxG)  // 0.01g to 0.5g
normalized = (log(clamped) - log(min)) / (log(max) - log(min))
velocity = int(normalized * 126) + 1  // 1-127
```

The logarithmic mapping gives better dynamic range than linear. Typical values:
- Very soft tap: ~0.01-0.02g → velocity ~1-30
- Medium tap: ~0.05-0.1g → velocity ~50-80
- Hard tap: ~0.2-0.5g → velocity ~100-127

## Calibration

### Seven-Point Capture

The user captures 7 arm positions: 1 rest + 2 endpoints for each of 3 tilt axes.

1. **Rest**: neutral playing position
2. **Tilt 1 positive**: forearm up
3. **Tilt 1 negative**: forearm down
4. **Tilt 2 positive**: iPad tilted towards player
5. **Tilt 2 negative**: iPad tilted away
6. **Tilt 3 positive**: arm rotated inward
7. **Tilt 3 negative**: arm rotated outward

Each position records a `CalibrationPoint3D` with pitch, roll, and yaw in radians.

### 3D Vector Projection

Each axis defines a direction vector in (pitch, roll, yaw) space from its negative endpoint to its positive endpoint. The midpoint of each axis is calculated, and the current orientation's offset from rest is projected onto each axis direction:

```
axisVec = positiveEnd - negativeEnd
axisMid = (positiveEnd + negativeEnd) / 2 - rest
offsetFromMid = currentOffset - axisMid
projection = dot(offsetFromMid, axisVec) / dot(axisVec, axisVec) * 2
```

Result: 3 values, each -1 to +1 where -1 = negative endpoint, 0 = rest, +1 = positive endpoint. Asymmetric ranges are supported (e.g., you can tilt further up than down).

### Persistence

Calibration data is `Codable` and saved to `UserDefaults` under key `armpad_calibration_v2`. It loads automatically on `MotionManager.init()`.

## Dimension System (Parameter Mapping)

Parameters are driven by **dimensions** — configurable input sources. Each parameter can be mapped to any dimension via the **MAP** button which opens a configuration sheet. The mapping is persisted in `DimensionMapping` (stored in UserDefaults).

### Available Dimensions

| Dimension | Type | Description |
|-----------|------|-------------|
| Tilt 1 | Global | Forearm up/down (calibrated axis 0) |
| Tilt 2 | Global | iPad towards/away (calibrated axis 1) |
| Tilt 3 | Global | Arm rotation (calibrated axis 2) |
| Pressure | Per-note | Accelerometer pressure at note onset (same as velocity capture) |
| Key Y | Per-note | Finger y-position on the key (0 = bottom, 1 = top), normalized to key height for black keys |
| Slider 1 | Global | Horizontal slider in top-right panel (0 at right edge, 1 at left) |
| Slider 2 | Global | Second horizontal slider below Slider 1 |
| None | — | Fixed at midpoint (0.5) |

**Global** dimensions have a single value shared across all voices. **Per-note** dimensions have independent values per voice. When a per-note dimension is mapped to a global parameter (glide speed, compression), the most recently activated voice's value is used as a fallback.

### Mappable Parameters

Each binding uses a Catmull-Rom spline defined by 2–4 control points, replacing the previous linear interpolation. The spline output is clamped to the endpoint min/max. Tilt dimensions are normalized from -1..+1 to 0..1 via `(tilt + 1) / 2`. Per-note dimensions are already 0..1. Multiple dimensions can be bound to a single parameter (many:many mapping).

**Internal parameters** (affect the built-in synth and glide engine):

| Parameter | Default Min | Default Max | Unit | Default Dimension |
|-----------|-----------|-----------|------|-------------------|
| Velocity | 1 | 127 | (MIDI) | Pressure |
| Glide Speed | 20 | 200 | ms/st | Tilt 1 |
| Compression | 15 | 40 | ms | Tilt 1 |
| Amplitude | 0.3 | 1.5 | x | Tilt 1 |
| Vib Depth | 0 | 0.5 | st | None |
| Vib Rate | 4 | 10 | Hz | None |
| Vib Intensity | 0 | 1 | — | Key Y |
| Drag Smooth | 0.1 | 0.5 | (coeff) | None |
| Glide Curve | 3 | 12 | (k) | None |

**MIDI output parameters** (sent to external synths via MPE):

| Parameter | CC# | Default Range | Default Dimension | Description |
|-----------|-----|--------------|-------------------|-------------|
| Aftertouch | — | 0–127 | Tilt 1 | Channel pressure |
| CC74 Bright | 74 | 0–127 | None | MPE slide / filter cutoff |
| CC1 Mod | 1 | 0–127 | None | Mod wheel |
| CC11 Expr | 11 | 0–127 | None | Expression / secondary dynamics |
| CC71 Reso | 71 | 0–127 | None | Filter resonance |
| CC73 Atk | 73 | 0–127 | None | Envelope attack |
| CC75 Dec | 75 | 0–127 | None | Envelope decay |

MIDI CC parameters are only sent when their dimension is not "None". Each is sent per-voice on the voice's MPE channel at 60Hz.

When set to "None", the parameter uses 0.5 (midpoint of its range).

### ParameterMapping Model

Each parameter's mapping is a `ParameterMapping` struct containing an array of `DimensionBinding` objects (many:many support). Each `DimensionBinding` holds a `Dimension` and 2–4 `ControlPoint` values defining a Catmull-Rom spline curve, with output clamped to the endpoint min/max. The `DimensionMapping` struct holds all mappings in a dictionary keyed by parameter `storageKey`, persisted to UserDefaults under `"armpad_dimensionMapping_v5"`.

`TiltMapping.swift` defines the `Dimension` enum, `MappableParameter` enum (Int-backed for fast array indexing), `ControlPoint`, `DimensionBinding`, `ParameterMapping`, and `DimensionMapping` structs. NoteManager caches all binding arrays (`cachedBindings`) rebuilt only when the mapping changes, and reads values via `cachedParamValue(for: .amplitude, voiceIndex: i)` which resolves multiple bindings with priority (per-note > sliders when touched > tilts, highest deviation wins among same type).

The MAP button or a swipe-right gesture on the top half opens a matrix panel for editing mappings.

### Pressure Optimization

When no parameter is mapped to the Pressure dimension (`pressureInUse == false`), the velocity capture delay is skipped entirely — notes fire immediately on touch with zero latency. The accelerometer peak detection logic is also skipped.

## Vibrato

A sine wave LFO modulates pitch. Rate, depth, and intensity are all dimension-mapped:

```
vibratoOffset = sin(phase) * cachedParamValue(for: .vibratoDepth) * vibIntensity
phase += 2pi * cachedParamValue(for: .vibratoRate) * dt
vibIntensity = cachedParamValue(for: .vibratoIntensity, voiceIndex: i)
```

- Default vibrato rate range: 4–10 Hz (dimension-mappable)
- Default vibrato depth range: 0–0.5 semitones (dimension-mappable)
- Vibrato intensity defaults to Key Y dimension with range 0–1 (bottom of key = no vibrato, top = max)
- All three can be remapped to any dimension (e.g., Slider 1 for manual vibrato control)
- Multiple dimensions can drive the same vibrato parameter simultaneously
