# Sensors

The iPad streams raw motion; the Mac evaluates every binding. This page covers the iPad's motion pipeline, the strike estimate and its scopes, the Mac-side tilt calibrations, the control dimensions, and the binding model. The wire that carries the sensor fields is described in [MIDI & Audio](midi-and-audio.md); the binding UI and parameter model in [Parameters](parameters.md).

## MotionManager (iPad)

`MotionManager` wraps CoreMotion's `CMMotionManager` at 200 Hz (`Config.motionUpdateRate`) and publishes on the main thread.

| Field | Meaning |
|---|---|
| `pitch`, `roll`, `yaw` | attitude in radians (yaw is the raw CoreMotion value; the wire uses the corrected form below) |
| `normalizedTilts` | the three angles at a FIXED ±90° full scale, each clamped to −1…+1 — the raw tilt report the wire carries (tilt 1 = pitch, 2 = roll, 3 = corrected yaw) |
| `userAccelX/Y/Z`, `accelMagnitude` | gravity-removed acceleration in g |
| `strikeLevel` | the strike envelope (below) |

### Accelerometer ring buffer

A timestamped ring buffer (`accelBuffer`) holds the last 100 ms (`Config.accelBufferDuration`) of magnitude samples. `peakAccelSince(timestamp:)` returns the peak magnitude and its time from all samples after the given time — the onset strike estimate's input.

### Yaw: high-passed, bias-corrected

Pitch and roll are anchored by gravity; yaw is unreferenced gyro integration and drifts without bound. Tilt 3 is therefore a corrected RELATIVE yaw (`updateYaw`):

1. Wrap-safe yaw increments leak toward zero with a 60 s time constant (`yawLeakTau`).
2. The drift RATE is learned while the device is quiescent (observed rate under ~0.57°/s, ~10 s learning constant) and subtracted from every increment — a leak alone passes a constant rate through and plateaus at rate × τ.

Gestures pass untouched; a twist held motionless re-centres over about a minute; the ±π wrap cannot rail the axis. The Mac's ZL re-zero stays instant.

### Motion views

The iPad's GYRO overlay and the Mac Setup tab's "Received motion (3D)" draw the same attitude trail at a fixed ±30° scale centred on the trail mean — the standing sensor-vs-transmission A/B; only yaw may differ (raw on the iPad, corrected on the wire). Each pairs with an **accelerometer twin** (raw `userAcceleration`, origin-centred, fixed ±0.5 g); the Mac's copy reads the PERF_STATE accel fields (±4 g wire scale, display only).

## Strike velocity (iPad)

iPads have no pressure-sensitive touch; the strike is estimated from the accelerometer. Two consumers share ONE law, `StrikeLaw.scale01` (`MotionSource.strikeScale01`):

```
clamped = clamp(peakG, velocityMinG, velocityMaxG)   // 0.01 g … 0.5 g
vel01   = log(clamped / minG) / log(maxG / minG)      // at or below minG → 0
```

Typical readings on the 0–127 display scale: gentle placement ~1–30, medium (~0.05–0.1 g) ~50–80, hard (~0.2–0.5 g) ~100–127.

### Per-onset estimate

The fret-pad onset handler (`FretPadSurfaceIOS.began`) calls `MotionSource.strikeVelocity01(at: now)`, which scans the TRAILING `Config.velocityLookback` window (50 ms, must stay under `accelBufferDuration`) of the ring buffer via `peakAccelSince`. Backward-looking: UIKit delivers a touch ~10–25 ms after the physical impact, so the chassis spike is usually already buffered and **the note-on never waits** (never add an onset delay on the fret path). The result rides the touch's `velocity` byte in every PERF_STATE frame; the Mac mapper stores it per slot for the String voice's `bow_attack_vel` velocity→attack-sharpness law (0 default = inert — see [Sarangi](sarangi.md)). Producers without an accelerometer (the Mac pads) send a flat constant.

Known limit: a tap whose spike lands later than the lookback window under-reads toward legato — a playable failure mode; widen `velocityLookback` before resorting to onset delays.

### The strike envelope

`MotionManager.strikeLevel` is `strikeScale01(magnitude)` through a fast-attack / ~150 ms-decay tracker (`StrikeLaw.envelopeTau`), evolved at the full 200 Hz so a tap between 60 Hz report ticks still registers at height. It streams as the PERF_STATE `strike` byte (0–255 ↔ 0…1) and is the measurement behind the `.strike`/`.acceleration` dimension pair (below).

### The player can see the law

- Every onset draws its reading on the touch indicator: an impact ripple sized by the estimate plus the number (0–127), surviving release as a ~1 s fading ghost.
- The toolbar's **strike scope** (`StrikeScopePane`) draws the envelope — the exact signal the bindings consume — as a scrolling ~4 s trace on the 0–127 scale, the current value at the right, an amber tick holding the last onset. Buckets sit on a TIME-QUANTIZED grid (a moving origin shimmers); decimation is per-pixel PEAK-HOLD, never a sample stride (a stride aliases the 200 Hz stream). It polls the unpublished history at 30 Hz, so motion samples never re-render the toolbar.
- Colour is playing state: pale yellow at onset fading down the magma ramp to violet over the strike blend window (violet = fully handed over to Acceleration), dark gray while nothing plays, a lighter backdrop on note-active frames. The surface reports melody-note begins/ends into `MotionManager.noteBegan/noteEnded` (id-keyed, so drone presses never unbalance it); the window length arrives as the JOYCON_STATE `strikeWin` byte.

## Control dimensions (Mac)

`ControlAxes.dims` lists the bindable axes in index order. Every axis has exactly one source.

| Axis | Dimension | Source | Polarity |
|---|---|---|---|
| 0–2 | Arm ↕ / ↔ / ⟲ (`tilt1–3`) | the iPad tilt report through the arm calibration; raw pitch/roll/yaw passthrough (uncentred) when uncalibrated | bipolar, rest 0 |
| 3–4 | Stick X / Y | the Joy-Con stick, per-axis 0.1 deflection gate, rescaled 0.1 → 0, full → ±1; centre pinned exactly at rest | bipolar, rest 0 |
| 5–6 | Strike / Acceleration | the PERF_STATE `strike` envelope byte, blended per target by time since note onset (below) | UNIPOLAR, silence at curve x 0 |
| 7 | Finger Accel (`fingerAccel`) | the playing finger's signed pitch acceleration (below) | bipolar, rest 0 |
| 8–10 | Wrist ↕ / ↔ / ⟲ (`tilt4`, `wrist2`, `wrist3`) | the Joy-Con's fused attitude through the wrist calibration; silent until calibrated | bipolar, rest 0 |
| 11 | Joy-Con Accel (`jcAccel`) | the Joy-Con's gravity-removed acceleration magnitude through `StrikeLaw` (same log map + 150 ms envelope), every IMU packet, change-gated at 1/256, 0 on detach; no calibration needed | UNIPOLAR |

`InputDimension` also carries `accelPressure`, `keyY`, `slider1`, `slider2` — retired cases kept so saved bindings decode; nothing emits them (see docs/history/).

Every tilt value is −1…+1 with rest 0, in process and on the wire (s16). Binding curves keep a 0…1 x-domain and map at evaluation: bipolar axes via `(v + 1) / 2`, unipolar axes read rest at x 0.

### Strike / Acceleration — one measurement, two axes

Both ride the strike envelope byte; what separates them is **time since the note started** (`StrikeBlendWindow`, `AppController.evaluateStrikeBlend`). Per bound target the applied value is (1−w)·Strike + w·Acceleration, w ramping linearly 0→1 over the window:

- **`ctl_strike_window`** (Parameters tab, "Strike blend" group, 0.25–8 s, default 2) — a control-layer `.live` key intercepted in `applyParamToVoice`; rides presets; relayed to the iPad scope as the JOYCON_STATE `strikeWin` byte (50 ms units).
- A side without a binding evaluates to the target's DEFAULT (registry default for a parameter, 0 for a composite): "expression [0, 1] on Strike, unbound on Acceleration (default 0.4)" reads at w = 0.5 as [0.2, 0.7].
- Windows are **per note** (wire touch id; retriggers re-anchor). While notes overlap the NEWEST sounding note's age drives the weight — a fresh tap always gets full Strike, even mid-legato; releasing it falls back to the survivor's own un-reset age; with nothing sounding the last onset keeps aging, so the pair rests on the Acceleration side.
- Delivery is `LinkIngest.onStrike` + the note-edge `onTouchGate` — deliberately NOT `applyTiltAxis` (that would double-apply the pair) — with a 30 Hz Mac-side timer moving the weight between change-gated wire events while bindings exist. Guard: `StrikeBlendTests`.

Strike is the onset's voice, Acceleration the sustained gesture's: bind accent-flavoured mappings to the first, aftertouch-flavoured ones to the second.

### Finger Accel

The SIGNED second derivative of the newest sounding touch's pitch trajectory, soft-saturated to −1…+1 (`FingerAccelTracker`):

| Stage | Law |
|---|---|
| velocity | per-sample pitch delta through a ~25 ms SIGNED smoother (signed first, so frame jitter cancels instead of rectifying) |
| acceleration | the smoothed velocity's delta through a second ~25 ms smoother |
| output | a / (\|a\| + 25 000 ¢/s²) — the same half-saturation scale as the kernel slide noise's `bow_slide_acc` default, so the dimension and the noise agree about what a strong gesture is |

Rest AND a constant-rate meend read 0; accelerating upward reads +, braking an upward slide or accelerating downward reads −. No new wire traffic: the Mac derives it from the pitch in every PERF_STATE frame (`LinkIngest.onTouchPitch`/`onTouchGate` → `AppController.fingerEvaluate`; the Mac pads feed the same tracker through the local-pump ingest) plus a 30 Hz decay tick while bound (frames are change-gated, so a resting finger would otherwise freeze the value). A tracked-finger change or a > 2-semitone per-sample jump is a snap/steal: the chain reseeds without driving. A plain `applyTiltAxis` axis — no blend. Guard: `FingerAccelTests`.

The iPad toolbar shows a matching **finger-accel scope** beside the strike scope — bipolar, centreline = rest, green trace while a note sounds — from its own display-only instance of the same law (`FingerAccelSampler`, 120 Hz off-main from `OutboundPlayState`). The data's source side draws its own readout; the Mac's evaluation stays the control truth.

## Tilt calibration (Mac)

**The iPad performs no calibration** — it streams raw attitude (`normalizedTilts`) and has no wizard or recalibrate button. (The former iPad-side 7-point calibration is not present — see docs/history/.) The Mac holds two instances of `TiltCalibrator` (TarabdaarCore; `TiltCalibratorTests` pins the solve), run from the Setup tab (⌘7):

| | Arm | Wrist |
|---|---|---|
| Feature stream | the iPad's raw tilt report (`feedArmTilt` → `armTick`, hopped to main) | the Joy-Con's fused attitude: gravity pitch/roll from the complementary filter + a RELATIVE yaw (wrap-safe increments, drift rate learned while quiescent, 60 s leak — the iPad's tilt-3 law ported), ±90° full scale |
| Sweeps | rest, then arm ↕, arm ↔, arm rotation | rest, then wrist up/down, inward/outward, clockwise/counter-clockwise |
| Output | control axes 0–2 | control axes 8–10 (`tilt4`, `wrist2`, `wrist3`) |
| Uncalibrated | raw axes pass through, uncentred | silent (the fused attitude's rest is arbitrary) |
| Persistence | `tarabdaar.armCal.v2` (a `.v1` record migrates exactly: f0′ = 2·f0−1, extents ×2) | `tarabdaar.wristCal.v1` |
| Panel | "Arm calibration" — no Joy-Con needed | "Wrist calibration" — appears once the Joy-Con's motion fusion is live (Joy-Con 2 over BLE, or a controller with GC motion) |

The two captures are independent. Joy-Con **dpad-up** advances and **dpad-down** steps back whichever capture is running ("Redo previous": clears the current partial capture and the previous phase's samples; everything earlier stands); **ZL re-zeroes BOTH rest poses** without re-fitting. The iPad's toolbar arm square shows the SOLVED arm axes while a calibration is driving (JOYCON_STATE `arm1–3`, flag `armLive`) and its own raw attitude otherwise; the wrist square likewise shows the solved wrist axes once calibrated.

### The capture

1. **Rest** phase, then three guided sweeps, each starting from the rest pose (ending there is good practice, not enforced).
2. The rest pose is measured SEVEN times — the rest phase plus each sweep's first/last ~0.25 s windows — and merged ROBUSTLY: component-wise median, inliers within `max(0.1, 2 × median distance)`, mean of the inliers = `f0`. Off-rest readings are rejected as outliers, never a redo. The fitted detail line reports how many readings agreed and the inlier spread.
3. Each sweep's extents and both-ways check are judged against the sweep's own nearest rest reading (start or end, whichever is at rest; merged `f0` if neither), so rest wander between phases neither biases the solve nor fails the capture.
4. Live feedback: per-phase sample counts, refusal to advance an under-sampled phase, and an instant per-sweep verdict on advance (samples, both-ways with measured ± extents, % alignment against every earlier sweep). A fatal sweep — one-sided relative to rest, or ≥ 95 % aligned with an earlier one — **clears itself and repeats on the spot**; 80–95 % warns but advances. One-sided almost always means the rest pose sat at one END of that motion's range: restart with a mid-range rest pose.
5. `CalCloudView` draws a rotating 3D scatter of the capture live (rest cluster white, sweep arcs orange/green/cyan, a ring on the rest centre, a yellow "you are here" marker with its raw values); the finished capture stays visible until the next one begins.

### The solve

- Feature vector f ∈ R³. Each sweep's dominant direction by PCA (power iteration) **about the sweep's own mean** (about rest, an off-rest average rotates the direction toward the offset and a both-ways motion projects one-sided).
- Joint least squares `c = (DᵀD)⁻¹Dᵀ(f − f0)` — non-perpendicular sweeps are separated by the solve.
- Extents measured through the same solve and applied piecewise (asymmetric lo/hi → rest 0, extremes ±1), absorbing first-order nonlinearity.
- Two near-identical sweeps (≥ 95 % alignment, with the singular-Gram inversion as backstop) discard the capture; the message names the sweeps and the percentage. After a fit the panel reports the closest pair — some alignment is expected, the arm motions overlap in attitude space.

### Input conditioning

- **Frame coalescing**: messages within `TiltCalibrator.frameGap` (4 ms) update the current frame in place, so the trail, the capture and the smoothing see atomic frames (per-message sampling records torn, staircase frames). Belt-and-braces now that TLP frames are atomic.
- **EMA per frame** (`Config.smoothAlpha`, arm 0.25) before the solve, the capture and the panel marker: quantized attitude flickers ±1–2 steps at rest and the Gram-inverse rows amplify it. ZL re-zero reads the smoothed vector.
- The link's 250 ms heartbeat keeps stillness distinguishable from disconnection; `LinkIngest` change-gates per axis before the bindings.

## Binding model

The Mac evaluates every binding itself (`AppController.handleRawTilt` → `applyTiltAxis`; the strike pair through `evaluateStrikeBlend`): composites via `applyComposite`, parameters through the unified `applyParamToVoice`. Nothing syncs to the iPad, so edits take effect immediately.

- **Editors**: the Controls tab (⌘4, `TiltControlsView`) edits, per axis, an arbitrary set of targets with Lo/Hi endpoints and the "From center" rest-zero shape; the Parameters tab's per-row mapping button makes the same bindings.
- **Targets**: `MapTarget` — `.composite(slot:)` or `.param(key:)`; endpoints in the target's native units (0–1 for a composite). "Taraf Purity" and "vibrato depth (¢)" bind the same way; there is no "mappable" subset.
- **Curves**: each `DimensionBinding` holds an `InputDimension` and 2–4 `ControlPoint`s defining a Catmull-Rom spline, output clamped to the endpoint min/max. Many dimensions may bind one target.
- **Model** (`TiltMapping.swift`): `ParameterMapping` (bindings per target) inside `DimensionMapping`, keyed by the target's `storageKey`, persisted under `tarabdaar_dimensionMapping_v6` (a v5 document migrates, rescaling 0–127 composite endpoints to 0–1). Composite keys keep their legacy spellings (`midiCC71`, `midiCC73`, `midiCC72`, `composite4`…`composite8` — historical strings that persisted bindings depend on, nothing more); parameter targets store as `param:<key>` and drop on load if the key no longer exists.
- **Threading**: raw tilt reports arrive off-main, so the Mac keeps a lock-protected per-axis snapshot of the bound targets (`tiltEvalByAxis`).

### Default bindings

| Axis | Target | Curve |
|---|---|---|
| Arm ↕ | Expression (the bow's loudness axis) — rest sends the fitted median, tilt down fades toward silence, up ≈ +8 dB | linear |
| Arm ↕ | Taraf Purity (composite slot 1: jt tone LP 16 k → 1.5 kHz, `bow_jt_sel` 0.5 → 0) | 3-point `(0,0) (0.5,0) (1,1)` — sweeps only past neutral |
| Arm ↔ | Taraf Decay (composite slot 2: taraf damping 0 → 1) | 3-point, as above |
| Arm ⟲ | Tone Tilt (composite slot 3: tone tilt −1 → 1) | linear, neutral = flat |

Existing installs adopt these once (flags `tarabdaar.tiltAxes.defaultBindings.v1`, `.v2` for the expression default); unbinding afterwards sticks. Composite slots 4–8 are free macros defined in the Controls tab.

## Vibrato

There is **no automatic vibrato LFO**. Vibrato is a playing technique: the pitch tracks the finger directly (see [Fret Pad](fret-pad.md)), so moving the finger across the surface bends the pitch with the motion. The kernel's own finger-vibrato depth is the single `hybrid` parameter **`bow_vib_cents`** (Articulation group) — bind a tilt to it to add depth by leaning.
