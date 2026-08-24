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

`peakAccelSince(timestamp:)` returns the peak magnitude and its timestamp from all samples after the given time. Used by the fret-pad onset's strike-velocity estimate (`MotionSource.strikeVelocity01`, below) to find the impact spike in the trailing window at touch delivery.

## Velocity Detection — revived 2026-08-19, backward-looking

iPads have no pressure-sensitive touch. Tarabdaar estimates strike
velocity from the accelerometer. The mechanism was deleted 2026-07-24
with the keyboard's mapping machinery (its only consumer had died) and
**revived 2026-08-19 on the Fret Pad path** as the drive for the String
voice's `bow_attack_vel` velocity→attack-sharpness law (tap hard =
martelé bite, place gently = legato draw — see
[sarangi.md](sarangi.md)):

1. The fret-pad onset handler (`FretPadSurfaceIOS.began`) calls
   `MotionSource.strikeVelocity01(at: now)` — no timer, no delay.
2. That scans the **trailing** `Config.velocityLookback` (50 ms) window
   of the 200 Hz accel ring buffer via `peakAccelSince`. Backward, not
   forward: UIKit delivers a touch ~10–25 ms after the physical impact,
   so the chassis spike is usually already buffered and **the note-on
   never waits** (the deleted design delayed the note 20 ms instead —
   do not bring that back on the latency-critical fret path).
3. The peak magnitude maps log-scale to 0…1:

```
clamped = clamp(peakG, velocityMinG, velocityMaxG)  // 0.01g to 0.5g
vel01 = log(clamped / minG) / log(maxG / minG)      // below minG → 0
```

The logarithmic mapping gives better dynamic range than linear. Typical
values (as the old 1–127 scale): very soft ~0.01-0.02g → ~1-30, medium
~0.05-0.1g → ~50-80, hard ~0.2-0.5g → ~100-127.

**The player can SEE the law (2026-08-20/23).** Every onset draws its
reading on the touch indicator — an impact ripple sized by the estimate
plus the number itself (0–127), which survives release as a ~1 s fading
ghost so staccato taps stay readable. And the toolbar carries the
**persistent strike scope**: the live accelerometer magnitude run
through the SAME law (`MotionSource.strikeScale01` — the shared g→0…1
map both consumers call, so trace and tap can never disagree), drawn as
a scrolling ~4 s trace on the 0–127 scale with the current value at the
right and an amber tick holding the last onset's reading. The trace is
**colored by what the player was doing at each moment** (2026-08-23):
bright white at a note onset fading to cyan over the next second while
the note sounds, faded gray while nothing plays — the surface reports
melody-note begins/ends into `MotionManager.noteBegan/noteEnded`
(id-keyed, so drone presses and out-of-band touches never unbalance
it) and the scope walks that timeline per bin. **The trace IS the envelope** (2026-08-23, final form): the scope draws
only the fast-attack/~150 ms-decay `strikeLevel` — the smoothed control
signal the `.strike`/`.acceleration` dimensions actually consume — and
the live number reads it too. The RAW magnitude trace was retired: its
rectified zero-crossings and the log-floor magnification made smooth
playing read as spikes, while the envelope is the truth the bindings
see. Coloring is playing state at each moment: bright white at a note
onset fading to cyan over the blend window (full cyan = the note has
fully handed over to Acceleration), DARK gray while nothing plays, and
note-active frames carry a lighter backdrop so phrases read as blocks
at a glance. The trace's buckets are anchored to a
TIME-QUANTIZED grid — bucketing against the moving `lastT − window`
origin re-rasterized every sample on every redraw and the whole trace
shimmered; on the quantized grid a sample keeps its bucket and the
trace scrolls by whole bins.

**And the player can BIND it (2026-08-23): the `.strike` /
`.acceleration` dimension pair.** The continuous form of the measure —
`strikeScale01(magnitude)` through a fast-attack / ~150 ms-decay
tracker (`MotionManager.strikeLevel`, evolved at the full 200 Hz so
taps between report ticks never drop) — streams as the PERF_STATE
`strike` byte (TLP v6) and lands as TWO Mac control axes, bindable
like the arm tilts and the Joy-Con stick. Both ride the SAME
measurement; what separates them is **time since the note started**
(`StrikeBlendWindow`, `AppController.evaluateStrikeBlend`): per bound
target, the applied value is (1−w)·Strike + w·Acceleration, with w
ramping linearly 0→1 over the note window — **`ctl_strike_window`**
(Parameters tab, "Strike blend" group, 0.25–8 s, default 2; a
control-layer `.live` key intercepted in `applyParamToVoice`, so it
rides presets like everything else and relays to the iPad over
JOYCON_STATE's v7 `strikeWin` byte, where the scope's white→cyan onset
fade tracks it — full cyan = the note has fully handed over to its
Acceleration bindings) — a side without a
binding evaluates to the target's DEFAULT (registry default for a
parameter, 0 = rest for a composite), so "expression [0, 1] on Strike,
unbound on Acceleration (default 0.4)" reads at t = 1 s as the
interpolated range [0.2, 0.7]. Windows are **per note** (wire touch
id; retriggers re-anchor): while notes overlap the NEWEST sounding
note's age drives the weight — a fresh tap always gets full Strike
treatment, even mid-legato — and releasing it falls back to the
survivor's own **un-reset** age; with nothing sounding the last onset
keeps aging, so the pair rests on the Acceleration side. A 30 Hz
Mac-side timer keeps the weight moving between change-gated wire
events (guard: `StrikeBlendTests`). UNIPOLAR: silence sits at the
binding curve's x 0, a hard strike at x 1 (the tilts rest at the
centre instead). Strike is the onset's voice, Acceleration the
sustained gesture's — bind accent-flavored mappings to the first and
aftertouch-flavored ones to the second. Decimation is per-pixel PEAK-HOLD,
never a sample stride — stride-2 sampled the 200 Hz stream at an
effective 100 Hz and made the trace toggle between two phase states. It polls the non-published 200 Hz
history at 30 Hz (the raw-overlay pattern), so motion samples never
re-render the toolbar.

The estimate rides the touch's `velocity` byte in the PERF_STATE frame
(it was always in the wire format; the Mac mapper discarded it until
2026-08-19) and is inert until `bow_attack_vel` is armed on the Mac.
Producers without an accelerometer (the Mac pads, the keyboard,
audition scripts) keep sending their flat constant / the score's MIDI
velocity. Known limit: if a given tap's spike lands later than the
lookback window (slow motion delivery), that onset under-reads toward
legato — a playable failure mode; widen `velocityLookback` (≤
`accelBufferDuration`) before resorting to onset delays.

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
three arm control axes (rest = 0, sweep extremes = ±1 — every tilt value is −1…+1 since 2026-08-18). It runs
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
k 7.5, drag smoothing 0.3, velocity 92. (The accelerometer velocity
ESTIMATE was revived 2026-08-19 on the Fret Pad path — see Velocity
Detection above — as a direct per-onset wire value, not as a revival of
this mapping machinery, which stays dead.)

**MIDI output parameters** (sent to whichever MPE receiver is downstream — TarabdaarMac, Ableton, etc.):

| Parameter | CC# | Default Range | Default Dimension | Description |
|-----------|-----|--------------|-------------------|-------------|
| Vibrato | — | 0–127 | Tilt 1 | Player vibrato depth (channel pressure) |
| Brightness | (74) | 0–127 | None | Bow position: sul ponticello ↔ sul tasto |
| Bow Pressure | (1) | 0–127 | None | Bow force inside the playable wedge |
| Expression | (11) | 0–64 | Tilt 1 | Loudness: rest (tilt 0) sends the fitted median; tilt down fades toward silence, up ≈ +8 dB |
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
resting device (body-calibration neutral = tilt 0, curve x 0.5) stays at 0 = the
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
