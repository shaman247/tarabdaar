# Sensors

The iPad streams raw motion; the Mac evaluates every binding. This page covers the iPad's motion pipeline, the Strike envelope and its scopes, the Mac-side tilt calibrations, the control dimensions, and the binding model. The wire that carries the sensor fields is described in [MIDI & Audio](midi-and-audio.md); the binding UI and parameter model in [Parameters](parameters.md).

## Joy-Con controller input (Mac)

BLE discovery selects the left controller: Nintendo manufacturer data carries vendor `057E` and product `2067` for Joy-Con 2 (L), while `2066` identifies the right half and is ignored. Name fallback also excludes right controllers. This keeps a charging or nearby right half from occupying the instrument's single controller connection.

The Mac accepts GameController profiles, classic Joy-Con raw HID, and Joy-Con 2 vendor BLE. Nintendo's standard BLE input and the Mobacon alternate report retain their own decoders. Discovery selects the left controller, including the manufacturer-data product ID when the advertised name is empty; a nearby right half cannot win the connection.

The **NYXI Hyperion 3 Ultra (left controller)** requires a console-session handshake before it sends sensor reports. `JoyCon2BLE` discovers both the vendor input service and `00C5AF5D-1964-4E30-8F51-1956F96BD280`, then writes `01 00` with response to the latter's `…D282` characteristic for NYXI devices. This opens a runtime input session without changing Bluetooth pairing. The existing feature-mask/enable sequence requests buttons, stick and IMU, and subscribes the standard report-0x05 characteristic last. A live standard stream suppresses the alternate-report fallback; disconnect clears the session state before reconnecting.

`JoyCon2ReportDecoder` decodes the standard report's left buttons, packed 12-bit stick, signed accelerometer values at bytes 48–53 and gyro values at 54–59. These feed the existing `JoyConFusion`, wrist calibration, shared tilt bindings and Joy-Con acceleration bindings. NYXI reports duplicate the rear paddle in GL/GR; the left GL bit becomes **Z (rear)**, which shares the Down button’s continuous drone toggle: press to start immediately and advance every two seconds, press again to stop; release leaves it running. Zero magnetometer data is unavailable rather than a heading measurement. NYXI's sensor timestamp at bytes 42–45 counts **milliseconds**; the decoder unwraps it and uses sample intervals rather than batched BLE arrival intervals. Duplicate sensor timestamps do not advance fusion, and a reconnect or long gap reanchors the clock.

Before that handshake, NYXI sends button/stick telemetry on command-response characteristic `C765A961-D9D8-4D36-A20A-5315B111836A`, interleaved with command acknowledgements. `JoyConNYXIReport` recognizes its `EA 01 00 8B 00 78 00 00 0C` envelope: byte 9 maps Up/Down/Left/Right to `08/04/02/01`, L/ZL to `80/40`, Minus to `20`, and stick click to `10`; byte 10 maps Capture/SL/SR/rear Z to `04/01/02/08`. Signed little-endian stick X/Y at bytes 11–14 are scaled into the shared raw calibration units. The standard stream takes priority once available, with the same mapper source so the switch cannot leave buttons held. The telemetry payload is not interpreted as motion. T produces no standalone input in the captured stream. Recalibrate the stick and wrist after changing controllers.

Captured-packet tests pin both NYXI formats, their button mapping, signed stick/motion decoding, acknowledgement separation and sensor-clock continuity. For third-party protocol investigation, launching with `TARABDAAR_JOYCON_CAPTURE=1` logs complete received BLE packets; normal launches omit this wire capture.

## MotionManager (iPad)

`MotionManager` wraps CoreMotion's `CMMotionManager` at 200 Hz (`Config.motionUpdateRate`) and publishes on the main thread.

| Field | Meaning |
|---|---|
| `pitch`, `roll`, `yaw` | attitude in radians (yaw is the raw CoreMotion value; the wire uses the corrected form below) |
| `normalizedTilts` | the three angles at a FIXED ±90° full scale, each clamped to −1…+1 — the raw tilt report the wire carries (tilt 1 = pitch, 2 = roll, 3 = corrected yaw) |
| `userAccelX/Y/Z`, `accelMagnitude` | gravity-removed acceleration in g |
| `strikeLevel` | the strike envelope (below) |

### Yaw: high-passed, bias-corrected

Pitch and roll are anchored by gravity; yaw is unreferenced gyro integration and drifts without bound. Tilt 3 is therefore a corrected RELATIVE yaw (`updateYaw`):

1. Wrap-safe yaw increments leak toward zero with a 60 s time constant (`yawLeakTau`).
2. The drift RATE is learned while the device is quiescent (observed rate under ~0.57°/s, ~10 s learning constant) and subtracted from every increment — a leak alone passes a constant rate through and plateaus at rate × τ.

Gestures pass untouched; a twist held motionless re-centres over about a minute; the ±π wrap cannot rail the axis. The Mac's ZL re-zero stays instant.

### Motion views

The iPad's GYRO overlay and the Mac Setup tab's "Received motion (3D)" draw the same attitude trail at a fixed ±30° scale centred on the trail mean — the standing sensor-vs-transmission A/B; only yaw may differ (raw on the iPad, corrected on the wire). Each pairs with an **accelerometer twin** (raw `userAcceleration`, origin-centred, fixed ±0.5 g); the Mac's copy reads the PERF_STATE accel fields (±4 g wire scale, display only).

## Strike (iPad)

`StrikeLaw.scale01` maps gravity-removed acceleration magnitude to 0…1
on a logarithmic scale between `Config.strikeMinG` (0.01 g) and
`Config.strikeMaxG` (0.5 g), clamped at both ends. The iPad Strike envelope
and the Joy-Con Accel dimension use this same law.

The iPad sends the continuous Strike envelope, including its current
value when a fret touch begins. There is no separate per-touch velocity
measurement or trailing-window estimate. On the Mac, `LinkIngest` applies
the frame's sensor values, then anchors each onset's Strike blend window
before mounting its string. Repeated Strike bytes still re-evaluate on
new touches and retriggers. This lets `bow_attack_sharpness` capture the
current bound value at onset without waiting for a timer or engine rebuild.
Joy-Con Accel can drive the same parameter through its ordinary binding.

### The strike envelope

`MotionManager.strikeLevel` is `strikeScale01(magnitude)` through a fast-attack / ~150 ms-decay tracker (`StrikeLaw.envelopeTau`), evolved at the full 200 Hz so a tap between 60 Hz report ticks still registers at height. It streams as the PERF_STATE `strike` byte (0–255 ↔ 0…1) and is the measurement behind the `.strike`/`.acceleration` dimension pair (below).

### The player can see the law

- The toolbar's strike scope is the readout. (The per-touch indicator's onset ripple + 0–127 number were removed 2026-09-04 when the overlay became the fingertip-radius display — see [Fret Pad](fret-pad.md).)
- The toolbar's **strike scope** (`StrikeScopePane`) draws the envelope — the exact signal the bindings consume — as a scrolling ~4 s trace on the 0–127 scale, the current value at the right. Buckets sit on a TIME-QUANTIZED grid (a moving origin shimmers); decimation is per-pixel PEAK-HOLD, never a sample stride (a stride aliases the 200 Hz stream). It polls the unpublished history at 30 Hz, so motion samples never re-render the toolbar.
- Colour is playing state: pale yellow at onset fading down the magma ramp to violet over the strike blend window (violet = fully handed over to Acceleration), dark gray while nothing plays, a lighter backdrop on note-active frames. The surface reports melody-note begins/ends into `MotionManager.noteBegan/noteEnded` (id-keyed, so drone presses never unbalance it); the window length arrives as the JOYCON_STATE `strikeWin` byte.

## Control dimensions (Mac)

`ControlAxes.dims` lists the axis slots in index order; `bindableDims` omits retired slots and groups the four stick directions together in the UI. The three generic tilt dimensions use the controller while connected and the iPad otherwise. The Controls tab and binding menus list tilt first, then Joy-Con acceleration and stick, followed by touch dimensions.

| Axis | Dimension | Source | Polarity |
|---|---|---|---|
| 0–2 | Tilt ↕ / ↔ / ⟲ (`tilt1–3`) | connected controller through wrist calibration; otherwise iPad through arm calibration, or raw uncentred pitch/roll/yaw when uncalibrated | bipolar, rest 0 |
| 3–4 | Reserved | retired Stick X / Y slots; saved bindings migrate to direction pairs | — |
| 5–6 | Strike / Acceleration | the PERF_STATE `strike` envelope byte, blended per target by time since note onset (below) | UNIPOLAR, silence at curve x 0 |
| 7 | Finger Accel (`fingerAccel`) | the playing finger's signed pitch acceleration (below) | bipolar, rest 0 |
| 8–10 | Reserved | retired wrist slots; saved bindings migrate to `tilt1–3` | — |
| 11 | Joy-Con Accel (`jcAccel`) | the Joy-Con's gravity-removed acceleration magnitude through `StrikeLaw` (same log map + 150 ms envelope), every IMU packet, change-gated at 1/256, 0 on detach; no calibration needed | UNIPOLAR |
| 12 | Touch Size (`touchSize`) | the newest sounding touch's fingertip contact radius (the PERF_STATE `radius` byte) mapped 31.3 → 73.0 pt through the finger-motion estimator (below) | UNIPOLAR, rest at curve x 0 |
| 13–16 | Stick Left / Right / Up / Down | the calibrated Joy-Con stick with no deadzone or deflection rescale; each direction measures deflection from centre toward that edge | UNIPOLAR, rest at curve x 0 |
| 17 | Fret Position (`fretPosition`) | the newest held finger’s position along its fret, from the per-touch TLP position word | UNIPOLAR, inner end 0, outer end 1 |

Stick directions evaluate together: left = max(−x, 0), right = max(x, 0), up = max(y, 0), down = max(−y, 0). Diagonals activate two directions; centring or disconnecting clears all four. Each affected target is emitted once per stick update. X/Y remain the display and wire coordinates, with no transport change. Saved X/Y bindings split into two independent bindings that evaluate the corresponding half of the original curve, preserving nonlinear curves and the target's base across preset round trips.

`InputDimension` also carries `accelPressure`, `keyY`, `slider1`, `slider2`, `stickX`, `stickY`, `tilt4`, `wrist2`, `wrist3` — retired cases kept so saved bindings decode; nothing emits them (see docs/history/).

Every tilt value is −1…+1 with rest 0, in process and on the wire (s16). Binding curves keep a 0…1 x-domain and map at evaluation: bipolar axes via `(v + 1) / 2`, unipolar axes read rest at x 0.

### Automatic tilt source

**Tilt ↕ / ↔ / ⟲** are three shared dimensions with one set of binding curves. A connected controller supplies them through its wrist calibration. With no controller connected, the iPad supplies them through its arm calibration; without an arm calibration its raw, uncentred angles pass through. A connected controller without a wrist calibration leaves the tilts neutral. Source selection follows connection state automatically.

The arm and wrist calibrations remain independent, including their saved rest poses, ranges and reversals. Both streams continue feeding their calibration and latest-value cache while inactive. `ControlAxisEvaluator` selects all three cached axes together on a connection edge and emits each affected target once. Disconnect immediately selects the latest iPad pose; reconnect starts from neutral until a fresh controller sample arrives. Disconnect clears the wrist calibrator’s input smoothing and duplicate gate, so that first sample emits even if the pose matches the last session. The calibration itself persists. A BLE connection remains active if its GameController alias detaches. Stick, Joy-Con acceleration, touch dimensions and the iPad strike/acceleration pair keep their own input paths.

Saved arm bindings already use `tilt1–3`. Legacy wrist bindings (`tilt4`, `wrist2`, `wrist3`) migrate to the matching shared dimensions. If a target bound both devices on the same dimension, its wrist curve takes precedence; arm-only curves survive. Migration preserves curve points, edited offsets and the target's base, and saves only the shared bindings on the next save. Factory bindings provide one curve per shared tilt. Calibration storage and the wire format are unchanged.

### Strike / Acceleration — one measurement, two axes

Both ride the strike envelope byte; what separates them is **time since the note started** (`StrikeBlendWindow`, `ControlAxisEvaluator.evaluateStrikeBlend`). The pair's contribution to a bound target's sum (the swing law below) is (1−w)·swing<sub>Strike</sub> + w·swing<sub>Acceleration</sub>, w ramping linearly 0→1 over the window:

- **`ctl_strike_window`** (Parameters tab, "Strike blend" group, 0.25–8 s, default 2) — a control-layer `.live` key intercepted in `applyParamToVoice`; rides presets; relayed to the iPad scope as the JOYCON_STATE `strikeWin` byte (50 ms units).
- A side without a binding swings 0: "Expression 0 → +0.3 on Strike, unbound on Acceleration" lifts a hard hit by 0.3 (about +6 dB) at onset and lets the lift fade back into the resting expression over the window.
- Windows are **per note** (wire touch id; retriggers re-anchor). While notes overlap the NEWEST sounding note's age drives the weight — a fresh tap always gets full Strike, even mid-legato; releasing it falls back to the survivor's own un-reset age; with nothing sounding the last onset keeps aging, so the pair rests on the Acceleration side.
- Delivery is `LinkIngest.onStrike` + the note-edge `onTouchGate` — deliberately NOT `applyTiltAxis` (that would double-apply the pair) — with a 30 Hz Mac-side timer moving the weight between change-gated wire events while bindings exist. Guard: `StrikeBlendTests`.

Strike is the onset's voice, Acceleration the sustained gesture's: bind accent-flavoured mappings to the first, aftertouch-flavoured ones to the second.

### Acceleration smoothing

The Controls tab's **Acceleration smoothing** panel has independent **iPad smoothing (ms)** (`ctl_ipad_accel_smooth`) and **Joy-Con smoothing (ms)** (`ctl_jc_accel_smooth`) controls. Each is a Mac-owned low-pass time constant from 0–1000 ms, applied live and saved with the preset through the parameter registry. Zero (the default) bypasses this additional filter exactly. Both source envelopes retain their fast attack and 150 ms decay; these controls smooth the envelopes further rather than changing the sensor-side tracking.

The iPad filter feeds only the sustained `.acceleration` binding curves; `.strike`, the strum trigger retain their source response. The Joy-Con filter feeds `.jcAccel` bindings. The evaluator advances both held-input filters on its 30 Hz timer while either acceleration source or Strike is bound, so a change-gated source cannot freeze a ramp. Link loss/panic and Joy-Con IMU reset clear the corresponding tail immediately. The iPad strike scope and Joy-Con diagnostic bars continue to show the source signals before this Mac-side smoothing.

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
| Sweeps | rest, then arm ↕, arm ↔, arm rotation | rest, then wrist up/down and inward/outward — TWO sweeps; rotation is inferred |
| Solve | JOINT: each sweep's direction by PCA about its own mean, `c = (DᵀD)⁻¹Dᵀ(f − f0)` separates non-perpendicular sweeps, extents measured through the solve | ORTHOGONAL (`Config.orthogonal`, `sweepCount` 2): sweep 1's PCA direction IS Wrist ↕, exactly; sweep 2's direction is orthogonalized against it (the shared part dropped; under ~25° apart = redo) = Wrist ↔, the best orthogonal fit; Wrist ⟲ = ↕ × ↔, inferred, with the mean of the two measured ranges as its extents. The rows of `m` are an orthonormal frame, so the live solve is a projection — no Gram inverse, no cross-talk amplification (the joint solve turned capture cross-talk into play cross-talk and was hard to control by hand) |
| Output | control axes 0–2 | control axes 8–10 (`tilt4`, `wrist2`, `wrist3`) |
| Uncalibrated | raw axes pass through, uncentred | silent (the fused attitude's rest is arbitrary) |
| Persistence | `tarabdaar.armCal.v2` (a `.v1` record migrates exactly: f0′ = 2·f0−1, extents ×2) | `tarabdaar.wristCal.v1` |
| Panel | "Arm calibration" — no Joy-Con needed | "Wrist calibration" — appears once the Joy-Con's motion fusion is live (Joy-Con 2 over BLE, or a controller with GC motion) |

The two captures are independent. Joy-Con **dpad-up** advances and **dpad-down** steps back whichever capture is running ("Redo previous": clears the current partial capture and the previous phase's samples; everything earlier stands); **ZL re-zeroes BOTH rest poses** without re-fitting. The iPad's toolbar arm square shows the SOLVED arm axes while a calibration is driving (JOYCON_STATE `arm1–3`, flag `armLive`) and its own raw attitude otherwise; the wrist tilt bars likewise show the solved wrist axes once calibrated (and their d/dt bars differentiate whichever tilt is displayed).

Each calibrated dimension has a **Reverse** button in the calibration panel, including the inferred wrist rotation. It reverses that dimension immediately and saves the result with the calibration, preserving the rest pose and physical ranges. The other dimensions stay unchanged; pressing the button again restores the original direction. Reversal is available outside a running capture and also applies to the arm fallback calibration.

### The capture

1. **Rest** phase, then three guided sweeps, each starting from the rest pose (ending there is good practice, not enforced).
2. The rest pose is measured SEVEN times — the rest phase plus each sweep's first/last ~0.25 s windows — and merged ROBUSTLY: component-wise median, inliers within `max(0.1, 2 × median distance)`, mean of the inliers = `f0`. Off-rest readings are rejected as outliers, never a redo. The fitted detail line reports how many readings agreed and the inlier spread.
3. Each sweep's extents and both-ways check are judged against the sweep's own nearest rest reading (start or end, whichever is at rest; merged `f0` if neither), so rest wander between phases neither biases the solve nor fails the capture.
4. Live feedback: per-phase sample counts, refusal to advance an under-sampled phase, and an instant per-sweep verdict on advance (samples, both-ways with measured ± extents, and — joint mode — % alignment against every earlier sweep, or — orthogonal mode — how aligned the second sweep's raw motion was with axis 1 before the shared part was dropped). A fatal sweep — one-sided relative to rest, ≥ 95 % aligned with an earlier one (joint), or under ~25° from axis 1 (orthogonal sweep 2) — **clears itself and repeats on the spot**; 80–95 % alignment warns but advances in both modes. One-sided almost always means the rest pose sat at one END of that motion's range: restart with a mid-range rest pose.
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

The Mac evaluates every binding itself (`AppController.handleRawTilt` → `applyTiltAxis` → `ControlAxisEvaluator`; the strike pair through `evaluateStrikeBlend`): composites via `applyComposite`, parameters through the unified `applyParamToVoice`. Nothing syncs to the iPad, so edits take effect immediately.

**The swing law.** A target has ONE resting value and every binding is a swing about it:

```
value(target) = clamp( rest(target) + Σ_i offset_i(x_i) )
```

- `rest` is a composite's `ParameterMapping.defaultValue` (the Controls tab's Rest slider) or a parameter's resting store value (its Parameters-tab knob; the evaluator re-sums when the knob moves).
- `x_rest` is the dimension's own rest point (`InputDimension.restX`): 0.5 for the bipolar axes, 0 for the unipolar ones (strike pair, Joy-Con accel, touch size).
- Edited one-way bindings linearly interpolate `lo + (hi − lo) × x`; zero input contributes `lo`, which may be negative or positive. A base of 0.4 with acceleration offsets [−0.2, +0.4] produces 0.2 at input 0, 0.5 at input 0.5, and 0.8 at input 1. Bipolar bindings anchor offset zero at neutral; unbound dimensions contribute nothing. Several axes on one target add instead of overwriting each other: Expression on Tilt ↕ sets the level, Expression 0 → +0.3 on Strike lifts a hard hit on top, and the selected tilt returning to rest leaves the strike's lift alone.
- The clamp runs once, after the sum, to the target's range widened to any endpoint drawn outside it. Two full swings can saturate — two hands on one fader.
- The sum is in the target's own domain: expression units are dB-linear in the kernel (19 dB per unit), so adding expression is adding dB; a composite sums in its 0…1 domain and each member's lo→hi sweep stays the perceptual mapping.
- Documents saved before the law (no `restLaw` key) applied curves absolutely; on decode each bound target's rest becomes its first curve's reading at rest, so old presets sound identical at rest and under one axis. Guard: `ControlAxisEvaluatorTests`.

- **Editors**: the Controls tab (⌘4, `TiltControlsView`) shows signed endpoint offsets for each binding, with the base value in amber above the zero tick on the offset slider. The base is edited through the composite's Rest control or the parameter's Parameters-tab value. It is shared by every binding to the target; moving it preserves the offsets and immediately re-evaluates stationary inputs. Expression at base 0.5 can have Tilt ↕ offsets −0.5 / +0.5 and Strike offsets 0 / +0.3. Both endpoints are independently editable. One-way inputs interpolate linearly between them; bipolar edits anchor zero at the gesture's centre. Set the first offset to zero for a sweep past neutral. Existing curves display their evaluated offsets without rewriting saved bindings. Editing endpoints stores a fixed `offsetOrigin` with the curve so a nonzero first offset survives subsequent edits and save/load; older curves without that field retain `curve(x) − curve(x_rest)` evaluation until edited. The Parameters tab's per-row mapping button makes the same bindings.
- **Targets**: `MapTarget` — `.composite(slot:)` or `.param(key:)`; endpoints in the target's native units (0–1 for a composite). "Taraf Purity" and "vibrato depth (¢)" bind the same way; there is no "mappable" subset.
- **Curves**: each `DimensionBinding` holds an `InputDimension` and 2–4 `ControlPoint`s defining a Catmull-Rom spline, output clamped to the control-point min/max (including the resting anchor); `swing(atX:)` subtracts the stored `offsetOrigin`, or the rest reading for an older curve without that field. Edited one-way curves have two points and use linear interpolation. Many dimensions may bind one target.
- **Model** (`TiltMapping.swift`): `ParameterMapping` (bindings per target) inside `DimensionMapping`, keyed by the target's `storageKey`, persisted under `tarabdaar_dimensionMapping_v6`. Composite keys keep their legacy spellings (`midiCC71`, `midiCC73`, `midiCC72`, `composite4`…`composite8` — historical strings that persisted bindings depend on, nothing more); parameter targets store as `param:<key>` and drop on load if the key no longer exists.
- **Threading**: raw tilt reports arrive off-main, so `ControlAxisEvaluator` keeps a lock-protected snapshot of the bindings per target, the last curve-x per axis and a per-target change gate; a parameter target's rest is resolved on the main thread when the mapping is snapshotted or the knob moves, never read from the store on the link thread.

### Default bindings

| Axis | Target | Curve |
|---|---|---|
| Tilt ↕ | Expression (the bow's loudness axis) — rest sends the fitted median, tilt down fades toward silence, up ≈ +8 dB | linear |
| Tilt ↕ | Taraf Purity (composite slot 1: jt tone LP 16 k → 1.5 kHz, `bow_jt_sel` 0.5 → 0) | 3-point `(0,0) (0.5,0) (1,1)` — sweeps only past neutral |
| Tilt ↔ | Taraf Decay (composite slot 2: taraf damping 0 → 1) | 3-point, as above |
| Tilt ⟲ | Tone Tilt (composite slot 3: tone tilt −1 → 1) | linear, neutral = flat |

Existing installs adopt these once (flags `tarabdaar.tiltAxes.defaultBindings.v1`, `.v2` for the expression default); unbinding afterwards sticks. Composite slots 4–8 are free macros defined in the Controls tab.

## Fret position

**Fret Position** (`InputDimension.fretPosition`, raw value 21, axis 17) is
0 at a fret’s inner end and 1 at its outer end: bottom-to-top for upper
frets and top-to-bottom for lower frets. Each fret uses its own height;
positions clamp past its ends and interpolate linearly across neighboring
columns and gaps, independently of pitch warp. The pad sends this geometry
value in each touch record; the Mac evaluates the binding.

The newest held finger across the wire and local-pad lanes drives the
axis. Releasing it returns to the newest survivor, and releasing all
fingers returns the axis to 0. A link drop releases only the wire fingers.
Position reaches the
mapping before note onset and updates on vertical movement even at a
constant pitch. Producers without fret geometry send 0.

## Touch size dimension

`UITouch.majorRadius` — the fingertip's contact radius — rides every
PERF_STATE touch record as the `radius` byte (points × 4, TLP v13), and it
IS a usable continuous signal. Measured on the instrument: normal playing
reads **20.8** or **31.3** pt, and a deliberately FLATTENED finger reaches
**73.0** controllably, sometimes higher. `.touchSize` (raw value 16, axis
index 12 in `ControlAxes.dims`) is that signal as a
bindable dimension, one shared law (`TouchSizeTracker`, TarabdaarCore —
the `FingerAccelTracker` pattern):

| Stage | Law |
|---|---|
| map | `clamp((r − Config.touchSizeLoPt) / (Config.touchSizeHiPt − touchSizeLoPt), 0, 1)` — **31.3 → 73.0 pt**, so ordinary playing rests at 0 and flattening sweeps the range; both ends clamp, and an unknown radius (0, a producer with no touchscreen) reads rest |
| fix | a level TRANSITION q_old → q_new is an exact POSITION fix: the true radius crossed `(q_old + q_new) / 2`, at that instant. The bin half-width becomes `|q_new − q_old| / 2` |
| velocity | two consecutive fixes inside one gesture (`Config.touchSizeGestureGapS`, **0.4 s**) measure the finger's speed in pt/s. A gesture's FIRST crossing has no predecessor, so it assumes `Config.touchSizeDefaultVelPtS` (**83.4 pt/s** = the whole window in `touchSizeRampS`, the measured 0.5 s flatten) in the direction of the step |
| coast | between fixes the estimate runs `p += v · dt`, CLAMPED to the current bin in the direction of travel — it may not pass `q ± h`, the next midpoint, because that crossing has not been reported |
| stop | pinned against that edge, or a whole `touchSizeGestureGapS` with no crossing: the velocity decays (`Config.touchSizeVelDecayS`, **0.1 s**) and the estimate relaxes to the level's CENTRE (`Config.touchSizeSettleS`, **0.25 s**) — the best static guess when motion says nothing |
| output | a CRITICALLY DAMPED second-order tracker on the estimate (`Config.touchSizeSmoothS`, **0.08 s** settle), integrated in closed form so any control rate is stable, then mapped |
| rest | no touch relaxes toward one quantum BELOW the window (the measured curled-finger 20.9 pt), which the map clamps to exact 0; a finger arriving afterwards initialises position, level and tracker AT its own level with zero velocity, so a fresh curled finger reads 0 and a fresh flat one reads 1, neither sweeping |

**Why an estimator, not a filter or a limiter.** Apple quantises
`majorRadius` to multiples of `Config.touchRadiusQuantumPt` (**≈10.42 pt**
— 20.8, 31.3, 41.7, 52.1, 62.5, 73.0 are 2…7 quanta), so anything fed the
quantised value can only chase each step after it lands: it ramps, STALLS
at the level, ramps again — kinks and plateaus. The quanta carry more than
that. A level is only a ±half-quantum bracket, but the MOMENT it changes
is a precise measurement, and two of those give a velocity. Coasting on
that velocity, bracketed by the bin the silence proves, reconstructs the
continuous finger the sensor is too coarse to report; the critically
damped output tracker then gives the axis continuous velocity, so the
motion starts and stops as an S-curve with no corner at a crossing and no
overshoot. The estimator LEARNS the speed — the same staircase walked half
as fast tracks at half the rate, which no fixed ramp can do.

**UNIPOLAR** like `.strike`: rest is the curve's LEFT end (x 0), so a
binding reads its first offset with the finger relaxed — unlike the tilts, whose
rest is the centre. The Mac drives it as `2·level − 1` through
`ControlAxisEvaluator.applyAxis` (the `.jcAccel` convention), never
through `evaluateStrikeBlend`.

The axis follows the **newest sounding touch** (the `.fingerAccel` rule):
both ingest lanes feed one registry — `LinkIngest.onTouchRadius` for the
wire and the local pump for the Mac pads/auditions — and a release falls
back to the surviving touch. A 30 Hz tick runs while the dimension is
bound, because the estimator needs time steps between change-gated wire
frames (and after the last finger lifts). Nothing is bound = nothing is
tracked. Guard: `TouchSizeTests`.

The iPad shows it on the **per-touch indicator ring**: the ring is sized
by the raw radius with the points printed beside it, and the estimated
0…1 value is drawn as an arc just outside the ring — from its own
display-only `TouchSizeTracker`, no extra wire traffic (see
[Fret Pad](fret-pad.md)).

## Vibrato

There is **no automatic vibrato LFO**. Vibrato is a playing technique: the pitch tracks the finger directly (see [Fret Pad](fret-pad.md)), so moving the finger across the surface bends the pitch with the motion. The kernel's own finger-vibrato depth is the single `hybrid` parameter **`bow_vib_cents`** (Articulation group, shipped at **25 ¢** at **5.5 Hz**, one GLOBAL player depth) — bind an axis to the `.vibratoAmount` composite target to add depth by leaning instead. (A 2026-09-04 fingertip-flatten ease that drove a PER-NOTE depth from the radius was removed the same day — it sounded fake; the radius is a control dimension now, see Touch size above.)
