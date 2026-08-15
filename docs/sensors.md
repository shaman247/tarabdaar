# Sensors

## MotionManager

Wraps CoreMotion's `CMMotionManager` at 200Hz (`motionUpdateRate`). Publishes on the main thread.

### Attitude (Orientation)

- `pitch`: tilt forward/back (radians)
- `roll`: tilt left/right (radians)
- `yaw`: rotation around vertical axis (radians)
- `normalizedTilts`: the three angles at a FIXED ±90° full scale, each clamped to -1…+1 — the raw tilt report

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

iPads have no pressure-sensitive touch. Tarabdaar estimates strike velocity from the accelerometer:

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

## Calibration — ONE step, on the Mac, arm-only (2026-08-13)

**The iPad performs no calibration.** The legacy 7-point iPad capture
(1 rest + 2 endpoints per axis, `CalibrationData`, key
`tarabdaar_calibration_v2`) was deleted 2026-08-13 — its per-axis 3D
projection was an affine map of (pitch, roll, yaw), and the Mac's guided
calibration solve learns its own linear map from the same inputs, so
calibrating twice added a step without adding information. The iPad now
streams **raw attitude** at a fixed ±90° full scale
(`MotionManager.normalizedTilts`, tilt 1 = pitch, 2 = roll, 3 = yaw)
and there is no first-launch wizard and no recalibrate button.
**Tilt 3 is HIGH-PASSED, BIAS-CORRECTED yaw (2026-08-14):** pitch/roll
are anchored by gravity, but yaw is unreferenced gyro integration and
drifts unboundedly (a resting iPad wandered tens of degrees over
minutes). Two-stage fix: (1) wrap-safe yaw increments leak toward zero
with a 60 s time constant — but a leak alone passes a constant drift
RATE through and plateaus at rate × τ (measured ~0.08°/s → a visible
~5° crawl), so (2) the drift rate itself is learned while quiescent
(observed rate < ~0.57°/s, ~10 s learning constant) and subtracted
from every increment. Gestures pass untouched; a twist held motionless
re-centres over ~a minute (ZL re-zero stays instant); the ±π wrap can
no longer rail the axis. End-to-end verification 2026-08-14: sensor
(GYRO overlay) and wire agree at Δ≈0.02–0.03° on pitch/roll over 10 s.
The Mac's Setup tab mirrors the iPad overlay one-for-one ("Received
motion (3D)": same trail, same Δ° readouts, fed from the transmitted
values, redrawn at 60 Hz off the live unthrottled trace) — the
standing sensor-vs-transmission A/B; only yaw is allowed to differ
(raw on the iPad, high-passed on the wire). Both views draw at a
FIXED ±30° scale (frame edge = 30° from the trail mean; only the
centring follows the data) — the same motion is the same size on
both screens, the zoom doesn't pump with trail extent, and sub-degree
noise reads as the near-stillness it is, with the Δ° labels carrying
the magnitude. The GYRO overlay and the Mac tab each pair the
attitude view with an **accelerometer twin** (2026-08-14): raw
per-axis `userAcceleration` as the same turntable trail, but
origin-centred (acceleration has a natural zero — taps read as jabs
from the centre) at a fixed ±0.5 g scale. The Mac's copy is fed by
the PERF_STATE accel fields (TLP v2, ±4 g wire scale, display-only)
— the same A/B, for the strike axis.

The app's **single tilt calibration** is the Mac's **arm calibration**
(Setup tab ⌘7): 1 rest pose + 3 arm sweeps (↕, ↔, rotation) over the
iPad's 3-dim raw tilt report, fitted by per-sweep PCA + a joint
least-squares solve with a robust 7-reading rest merge, producing the
three arm control axes (rest = 0.5, sweep extremes = 0/1). It runs
entirely on the tilt stream — no Joy-Con needed (the 2026-08-12
arm+wrist variant that fused Joy-Con gravity was cut back to arm-only
the next day). Mechanics, discard conditions and the
`tarabdaar.armCal.v1` persistence:
[midi-and-audio.md](midi-and-audio.md). Without an arm calibration the
iPad's three raw axes pass straight through to control axes 0–2 —
usable, but uncentered (rest sits wherever the iPad happens to rest,
not at 0.5).

## Dimension System (Parameter Mapping)

Parameters are driven by **dimensions** — configurable input sources. Each parameter can be mapped to any dimension via the **MAP** button which opens a configuration sheet. The mapping is persisted in `DimensionMapping` (stored in UserDefaults).

### Available Dimensions

| Dimension | Type | Description |
|-----------|------|-------------|
| Arm ↕ | Global | arm calibration axis 1 (raw passthrough: iPad pitch) |
| Arm ↔ | Global | arm calibration axis 2 (raw passthrough: iPad roll) |
| Arm ⟲ | Global | arm calibration axis 3 (raw passthrough: iPad yaw) |
| Pressure | Per-note | Accelerometer pressure at note onset (same as velocity capture) |
| Key Y | Per-note | Finger y-position on the key (0 = bottom, 1 = top), normalized to key height for black keys |
| Slider 1 | Global | Horizontal slider in top-right panel (0 at right edge, 1 at left) |
| Slider 2 | Global | Second horizontal slider below Slider 1 |
| None | — | Fixed at midpoint (0.5) |

**Global** dimensions have a single value shared across all voices. **Per-note** dimensions have independent values per voice. When a per-note dimension is mapped to a global parameter (glide speed, compression), the most recently activated voice's value is used as a fallback.

### Mappable Parameters

Each binding uses a Catmull-Rom spline defined by 2–4 control points, replacing the previous linear interpolation. The spline output is clamped to the endpoint min/max. Tilt dimensions are normalized from -1..+1 to 0..1 via `(tilt + 1) / 2`. Per-note dimensions are already 0..1. Multiple dimensions can be bound to a single parameter (many:many mapping).

The dimension matrix on the iPad covers only the iPad's responsibilities — MIDI emission and glide. iPad sensors **only ever drive MIDI** (pitch bend, channel pressure, CCs); the Mac's String voice consumes those MIDI bytes downstream (the tilt axes map to the taraf purity/decay/tone CCs + expression), but no iPad sensor maps directly into Mac-side DSP state. Voice timbre lives in the one parameter list (Parameters tab) + the tarab (Strings tab).

**Internal parameters — DELETED (2026-07-24).** Velocity, Glide Speed,
Compression, Amplitude, Drag Smooth, and Glide Curve were consumed only by
the legacy keyboard/glide pipeline (the Fret Pad tracks the finger
directly), so they were removed along with the iPad's whole mapping
machinery (`NoteManager` binding caches, the MAP editor, the accelerometer
velocity capture). The legacy glide engine (audition `noteOn`/`glide`
events) runs on fixed constants: 110 ms/st, 27.5 ms compression, curve
k 7.5, drag smoothing 0.3, velocity 92.

**MIDI output parameters** (sent to whichever MPE receiver is downstream — TarabdaarMac, Ableton, etc.):

| Parameter | CC# | Default Range | Default Dimension | Description |
|-----------|-----|--------------|-------------------|-------------|
| Vibrato | — | 0–127 | Tilt 1 | Player vibrato depth (channel pressure) |
| Brightness | (74) | 0–127 | None | Bow position: sul ponticello ↔ sul tasto |
| Bow Pressure | (1) | 0–127 | None | Bow force inside the playable wedge |
| Expression | (11) | 0–64 | Tilt 1 | Loudness: rest (0.5) sends the fitted median; tilt down fades toward silence, up ≈ +8 dB |
| Taraf Purity | (71) | 0–127 | Tilt 1 | Composite slot 1 (default members: jt tone LP 16 k→1.5 kHz, recruitment profile `bow_jt_sel` 0.5→0 — fitted chorus down to the played note's kin at held loudness) |
| Taraf Decay | (73) | 0–127 | Tilt 2 | Composite slot 2 (default member: taraf damping 0→1) |
| Tone Tilt | (72) | 0–127 | Tilt 3 | Composite slot 3 (default member: tone tilt −1→1) |
| Composite 4–8 | (20–24) | 0–127 | None | Free composite-parameter slots, defined in the Mac's Controls tab |
| Bow Tilt | (75) | 0–127 | None | Bow-stroke harmonic color (`BowControlMapper`) — don't rebind to a new meaning |

**Raw tilt wire (2026-07-24; TLP state-frame field since 2026-08-14):**
the iPad does NOT evaluate or send any of the MIDI parameters above — its
60 Hz tick writes the three raw tilt values (fixed-scale attitude) into
the outbound `OutboundPlayState`, and they ride EVERY `PERF_STATE` frame
as **16-bit fields, atomic with pitch** (no more torn CC pairs; ~0.005°
steps). The link's 250 ms heartbeat keeps a still iPad distinguishable
from a dead one, and `LinkIngest` change-gates per axis before the Mac's
bindings. The **Mac evaluates its own tilt bindings**
(`AppController.handleRawTilt` → `applyTiltAxis`): composites via
`applyComposite`, parameters through the unified apply. (The iPad-side
tilt-mapping evaluation and its SysEx were deleted 2026-07-24; the
in-process CC pair decode — CC 16/17/18 + 48/49/50 — survives in
`AudioEngine` for audition scores only.)

**Tilt performance axes (2026-07-23):** the three tilts default-bind to the
String voice's taraf/tone controls (CC71/73/72, consumed on the Mac in
`AudioEngine.routeSarangiModelMIDI` — see [sarangi.md](sarangi.md)). The
purity/decay default curves are 3-point (`(0,0) (0.5,0) (1,127)`): the
resting device (body-calibration neutral = 0.5 normalized) stays at 0 = the
current default sound, and the axis sweeps only past neutral; tone tilt is
linear so neutral lands on ~64 = flat. Existing installs adopt these
bindings once (flag `tarabdaar.tiltAxes.defaultBindings.v1`; the CC11
expression default adopts under `.v2`); unbinding afterwards sticks.

**Mac-side editor (2026-07-24):** the TarabdaarMac **Controls tab (⌘4,
`TiltControlsView`)** edits, per tilt, an arbitrary set of **targets**
with Lo/Hi endpoints and the "From center" rest-zero shape. A target
(`MapTarget`) is a **composite parameter** or **any single parameter** —
"Taraf Purity" and "vibrato depth (¢)" bind the same way — and endpoints
are in the target's native units (0–1 for a composite). The same bindings
can be made from the Parameters tab's per-row mapping button. Nothing
syncs: the Mac evaluates every binding itself (`applyTiltAxis`), so edits
take effect immediately. Bindings persist under
`tarabdaar_dimensionMapping_v6` (a v5 document migrates, rescaling its old
0–127 composite endpoints to 0–1).

When set to "None", the parameter uses 0.5 (midpoint of its range).

### ParameterMapping Model

Each target's mapping is a `ParameterMapping` struct containing an array of `DimensionBinding` objects (many:many support). Each `DimensionBinding` holds an `InputDimension` and 2–4 `ControlPoint` values defining a Catmull-Rom spline curve, with output clamped to the endpoint min/max. The `DimensionMapping` struct holds all mappings in a dictionary keyed by the target's `storageKey`, persisted to UserDefaults under `"tarabdaar_dimensionMapping_v6"`.

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
Sarangi-tab build scalar, so they became single `hybrid` parameters with
the scaler as an implementation detail. One of those pairs has since gone
entirely: the **linear sympathetic web was deleted on 2026-07-24**, taking
`bow_taraf_jawari` (and every other `bow_taraf_*`/`bow_open_*` key) with
it, so `bow_vib_cents` is the only hybrid left. The web's `bow_taraf_damp`
went the same way; `bow_jt_damp`, the modal jawari rows' runtime damping,
is a different bank and remains.
