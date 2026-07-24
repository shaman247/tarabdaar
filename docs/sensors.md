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

iPads have no pressure-sensitive touch. Starpad estimates strike velocity from the accelerometer:

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

Calibration data is `Codable` and saved to `UserDefaults` under key `starpad_calibration_v2`. It loads automatically on `MotionManager.init()`.

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

The dimension matrix on the iPad covers only the iPad's responsibilities — MIDI emission and glide. iPad sensors **only ever drive MIDI** (pitch bend, channel pressure, CCs); the Mac's String voice consumes those MIDI bytes downstream (the tilt axes map to the taraf purity/decay/tone CCs + expression), but no iPad sensor maps directly into Mac-side DSP state. Voice timbre lives in the one parameter list (Parameters tab) + the tarab (Tarab tab).

**Internal parameters — DELETED (2026-07-24).** Velocity, Glide Speed,
Compression, Amplitude, Drag Smooth, and Glide Curve were consumed only by
the legacy keyboard/glide pipeline (the Fret Pad tracks the finger
directly), so they were removed along with the iPad's whole mapping
machinery (`NoteManager` binding caches, the MAP editor, the accelerometer
velocity capture). The legacy glide engine (audition `noteOn`/`glide`
events) runs on fixed constants: 110 ms/st, 27.5 ms compression, curve
k 7.5, drag smoothing 0.3, velocity 92.

**MIDI output parameters** (sent to whichever MPE receiver is downstream — StarpadMac, Ableton, etc.):

| Parameter | CC# | Default Range | Default Dimension | Description |
|-----------|-----|--------------|-------------------|-------------|
| Vibrato | — | 0–127 | Tilt 1 | Player vibrato depth (channel pressure) |
| Brightness | (74) | 0–127 | None | Bow position: sul ponticello ↔ sul tasto |
| Bow Pressure | (1) | 0–127 | None | Bow force inside the playable wedge |
| Expression | (11) | 0–64 | Tilt 1 | Loudness: rest (0.5) sends the fitted median; tilt down fades toward silence, up ≈ +8 dB |
| Taraf Purity | (71) | 0–127 | Tilt 1 | Composite slot 1 (default members: jawari buzz 1.3→0, jt tone LP 16 k→1.5 kHz) |
| Taraf Decay | (73) | 0–127 | Tilt 2 | Composite slot 2 (default member: taraf damping 0→1) |
| Tone Tilt | (72) | 0–127 | Tilt 3 | Composite slot 3 (default member: tone tilt −1→1) |
| Composite 4–8 | (20–24) | 0–127 | None | Free composite-parameter slots, defined in the Mac's Controls tab |
| Bow Tilt | (75) | 0–127 | None | Bow-stroke harmonic color (`BowControlMapper`) — don't rebind to a new meaning |

**Raw tilt wire (2026-07-24):** the iPad does NOT evaluate or send any of
the MIDI parameters above — it streams only its three calibrated tilt
values on fixed axis messages (`TiltAxisWire`, 0…127 normalized,
change-gated at 60 Hz while playing), and the **Mac evaluates its own tilt
bindings** (`AppController.applyTiltAxis`): composites via
`applyComposite`, performance parameters as synthesized control-mapper
messages. Tilt bindings to iPad-internal parameters (glide, amplitude, …)
still evaluate on the iPad (they ride the tilt-mapping SysEx).

**Tilt performance axes (2026-07-23):** the three tilts default-bind to the
String voice's taraf/tone controls (CC71/73/72, consumed on the Mac in
`AudioEngine.routeSarangiModelMIDI` — see [sarangi.md](sarangi.md)). The
purity/decay default curves are 3-point (`(0,0) (0.5,0) (1,127)`): the
resting device (calibrated-neutral tilt = 0.5 normalized) stays at 0 = the
current default sound, and the axis sweeps only past neutral; tone tilt is
linear so neutral lands on ~64 = flat. Existing installs adopt these
bindings once (flag `starpad.tiltAxes.defaultBindings.v1`; the CC11
expression default adopts under `.v2`); unbinding afterwards sticks.

**Mac-side editor (2026-07-24):** the StarpadMac **Controls tab (⌘4,
`TiltControlsView`)** edits, per tilt, an arbitrary set of **targets**
with Lo/Hi endpoints and the "From center" rest-zero shape. A target
(`MapTarget`) is a **composite parameter** or **any single parameter** —
"Taraf Purity" and "vibrato depth (¢)" bind the same way — and endpoints
are in the target's native units (0–1 for a composite). The same bindings
can be made from the Parameters tab's per-row mapping button. Nothing
syncs: the Mac evaluates every binding itself (`applyTiltAxis`), so edits
take effect immediately. Bindings persist under
`starpad_dimensionMapping_v6` (a v5 document migrates, rescaling its old
0–127 composite endpoints to 0–1).

When set to "None", the parameter uses 0.5 (midpoint of its range).

### ParameterMapping Model

Each target's mapping is a `ParameterMapping` struct containing an array of `DimensionBinding` objects (many:many support). Each `DimensionBinding` holds an `InputDimension` and 2–4 `ControlPoint` values defining a Catmull-Rom spline curve, with output clamped to the endpoint min/max. The `DimensionMapping` struct holds all mappings in a dictionary keyed by the target's `storageKey`, persisted to UserDefaults under `"starpad_dimensionMapping_v6"`.

`TiltMapping.swift` defines the `InputDimension` enum, the **`MapTarget`** struct (`.composite(slot:)` or `.param(key:)` — it replaced the old `MappableParameter` enum, which could only name the 8 composite slots), `ControlPoint`, `DimensionBinding`, `ParameterMapping`, and `DimensionMapping`. Composite storage keys keep their legacy spellings (`midiCC71`, `midiCC73`, `midiCC72`, `composite4`…`composite8`) so saved bindings survive; parameter targets store as `param:<key>` and are dropped on load if the key no longer exists.

The Mac keeps a lock-protected per-axis snapshot of the bound targets (`tiltEvalByAxis`) because raw tilt reports arrive on the CoreMIDI thread.

### Pressure — REMOVED

The accelerometer velocity capture (and its `pressureInUse` fast-path) went
with the 2026-07-24 dead-parameter deletion: the Fret Pad tracks the finger
directly and never used it, so notes always fire immediately on touch. The
`accelPressure` / `keyY` / slider dimensions still exist in
`InputDimension` but nothing emits them — only the three tilts are wired.

## Vibrato

There is **no automatic vibrato LFO**. The old sine-LFO-on-the-pitch-bend
(the `vibratoDepth` / `vibratoRate` / `vibratoIntensity` dimension params)
has been removed. Vibrato is primarily a **playing technique**: the pitch
tracks your finger directly (see [Fret Pad](fret-pad.md)), so wiggling your
finger left/right across the surface bends the pitch with the motion.

The kernel also has its own finger-vibrato, exposed since the 2026-07-24
unification as the single parameter **`bow_vib_cents`** ("vibrato depth
(¢)", Articulation group) — bind a tilt to it to add vibrato depth by
leaning. It is a `hybrid` parameter: the kernel scales its built depth by
the aftertouch axis, which is what the deleted `bow_vibrato` parameter used
to expose separately.

**Parameter language (2026-07-24 unification):** CC numbers
(parenthesized above) are a transport detail — no user-facing surface
shows them. There is **one parameter list** (`ParamRegistry`, the
Parameters tab ⌘5): every knob of the String instrument, in native units,
each with an apply strategy — `live` (instant engine setter), `rebuild`
(a `bowed_string.json` build scalar, applied as a persisted override with
a debounced off-main rebuild), or `hybrid` (a build scalar that also has a
live 0–1 scaler in the kernel: instant at or below its built value,
rebuild above). **Composite parameters** are named 0–1 macros built from
those parameters, edited in the Controls tab, occupying 8 transport slots.

A tilt binds to a composite **or straight to a single parameter** — there
is no "mappable" subset. `AppController.applyParamToVoice` is the one
apply path for the Parameters tab, composite members, tilt bindings and
audition scripts alike; whatever cannot apply instantly is funnelled into
one debounced rebuild flush.

**What the unification removed:** the same perceptual knob used to exist
twice, in two tabs, under two names — `bow_jaw_gain` "web buzz amount"
next to `bow_taraf_jawari` "jawari buzz", and `bow_vibrato` "vibrato
depth" next to `bow_vib_cents` "vibrato depth (¢)". In both cases the
Parameters-tab knob was literally the kernel's 0–1 **scaler** for the
Sarangi-tab build scalar. They are now single `hybrid` parameters
(`bow_taraf_jawari`, `bow_vib_cents`), and the scalers are an
implementation detail. `bow_jt_damp` (the modal jawari rows' runtime
damping) and `bow_taraf_damp` (the sympathetic web's f² HF damping) were
never the same thing — they damp different string banks — and are now
labelled and grouped so they can't be confused.
