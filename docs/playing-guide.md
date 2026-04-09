# Playing Guide

## Physical Setup

1. Hold the iPad in landscape orientation (home button / USB-C on the right)
2. Rest the iPad on your inner forearm, screen facing up
3. The keyboard is on the bottom half of the screen; your fingers play it from above
4. Tilting your arm up/down controls volume and glide speed

## First Launch: Calibration

On first launch, the app guides you through a 7-step calibration capturing your arm's range of motion along 3 axes:

1. **Rest** — Natural, comfortable playing position
2. **Tilt 1: Up** — Move forearm up
3. **Tilt 1: Down** — Move forearm down
4. **Tilt 2: Towards** — Tilt iPad towards you
5. **Tilt 2: Away** — Tilt iPad away from you
6. **Tilt 3: Inward** — Rotate arm inward
7. **Tilt 3: Outward** — Rotate arm outward

Each step shows live pitch/roll/yaw readings. Tap Capture at each position. Calibration is saved and persists across launches. To recalibrate, tap "Recalibrate" in the orientation panel.

## Playing Notes

Tap a key on the keyboard to play a note. The note sounds after a ~20ms delay (needed to capture strike velocity from the accelerometer). Strike harder for a louder note.

The keyboard spans G3 to G5 (two octaves). White keys span the full height; black keys are in the upper 60%. Tapping the lower portion of the keyboard always plays white keys.

## Tap Glides

When you tap a second key while the first is still sounding, the pitch **glides** to the new note rather than jumping. This is the primary way to play expressively.

**Simple glide**: Play C, then E. The pitch slides smoothly from C to E.

**Staccato ornament**: Hold C, briefly tap E. The pitch glides to E, then returns to C when E is released.

**Fast ornament (C-E-D)**: Each note is queued. The system compresses the current glide so each note is reached before the next one starts.

**Connected notes**: If you release a note and play the next one within 50ms, they connect as a glide rather than triggering a new note onset.

## Drag Glides

Slide a single finger horizontally across the keyboard for a continuous pitch slide.

- Drag mode activates after the finger moves at least 1/3 of a key width
- The pitch follows your finger smoothly (with slight smoothing for naturalness)
- When your finger changes direction (e.g., sliding up to E then back to D), the peak is corrected to land exactly on the nearest scale tone
- When your finger stops, the pitch settles to the nearest scale tone (60ms delay). Once snapped, small movements are ignored — you must move at least 1/3 of a key width to break free and resume dragging
- When you lift your finger mid-drag, the pitch snaps to the nearest scale tone before the note ends, ensuring a clean final pitch
- In the white-key zone (bottom 40% of keyboard), only white keys are used for snapping

Drag glides appear in **green** on the pitch graph and keyboard. When snapped, the key highlights **yellow**. The highlighted key always matches the key under your finger, not the sounding pitch (so dragging from C to D never highlights C#).

## Vibrato

Move your finger vertically on the key to control vibrato:
- **Bottom 55%** of the key: no vibrato (clean playing zone)
- **Top 45%**: vibrato increases as you move up, reaching maximum at the very top

Black keys have their own proportional zones within their shorter height.

## Expression Dimensions

Parameters can have multiple **dimensions** bound to them simultaneously. Configure mappings via the **MAP** button or by swiping right on the top half of the screen. Each binding defines a Catmull-Rom spline curve (2–4 control points) that maps the dimension's input range to the parameter's output range. When multiple dimensions are bound, sliders (when touched) override tilts, and the dimension with the highest deviation from center wins among same-type inputs.

**Internal parameters**: Velocity, Glide Speed, Compression, Amplitude, Vibrato Depth, Vibrato Rate, Vibrato Intensity, Drag Smoothing, Glide Curve.

**MIDI output parameters**: Aftertouch (channel pressure), CC74 Slide, CC1 Modwheel, CC11 Expression, CC71 Resonance, CC73 Attack, CC75 Decay. MIDI CCs are only sent when mapped to a dimension (not "None"), and are sent per-voice on each voice's MPE channel.

**Available dimensions**:
- **Tilt 1/2/3**: Arm orientation axes from calibration (global, same for all voices)
- **Pressure**: Accelerometer strike intensity at note onset (per-note). When no parameter uses Pressure, the velocity capture delay is skipped for zero-latency note onset.
- **Key Y**: Finger's vertical position on the key (0 = bottom, 1 = top; normalized to key height for black keys). Updated continuously as you slide.
- **Slider 1/2**: Horizontal sliders in the channel readout, operated by the non-dominant hand. Value snaps back to a default when released.
- **None**: Fixed at midpoint

**Defaults**: Velocity → Pressure, Vibrato Intensity → Key Y, Glide Speed/Compression/Amplitude/Aftertouch → Tilt 1. All others → unbound. Each binding starts as a linear 2-point curve matching the parameter's default range.

The tilt values are based on your calibration, so "neutral" is wherever you calibrated your rest position.

## MIDI Setup (Ableton over USB)

1. Connect iPad to Mac via USB
2. On Mac: open **Audio MIDI Setup** > **Window > Show MIDI Studio** > Enable iPad
3. In Ableton: **Preferences > Link, Tempo & MIDI** > enable the iPad as MIDI input
4. Set your instrument's pitch bend range to **±48 semitones**
5. Enable **MPE mode** on the track

Armpad sends:
- Note on/off with accelerometer-derived velocity
- Pitch bend (continuous, includes glides + vibrato)
- Channel pressure / aftertouch (dimension-mapped)
- MIDI CCs 1, 11, 71, 73, 74, 75 (dimension-mapped, only sent when mapped to a dimension)

## Scale Editor

Tap the **SCALE** button to enter scale editing mode. The keyboard transforms into an interactive editor where you can:

- **Tap keys** to toggle notes on/off (yellow = enabled, dim = disabled)
- **Pinch** to zoom the keyboard (1-3 octaves)
- **Long press** a key to set it as the just intonation root (green)
- Switch between **12-TET** and **JI** tuning in the toolbar
- Tap **Done** to return to playing

A ratio band above the keyboard shows the interval for each note. See [Scales & Tuning](scales-and-tuning.md) for details.

## Polyphonic Mode

Tap the **MONO/POLY** button in the status bar to toggle polyphonic mode. In poly mode, each finger plays its own independent voice.

### How It Works

- **Tap** a key to play a note on a new voice
- **Slide** a finger to drag that voice's pitch across the keyboard (each finger drags independently)
- **Lift** a finger to release that voice

There are no tap-based glides in poly mode — glides only happen when you drag a finger. This avoids ambiguity about which voice should glide where.

### Differences from Mono Mode

- **Tap glides** and the **waypoint queue** are not used — each tap is a new voice
- **Drag glides** work per-voice (each finger drags its own voice independently), including stop-snapping and snap-on-release
- **Vibrato** applies equally to all voices (single shared LFO)
- **Tilt expression** applies to all voices simultaneously

## PANIC Button

If a note gets stuck, tap the red **PANIC** button in the status bar. This silences all audio, sends all-notes-off on all 16 MIDI channels, resets pitch bend, and clears all internal state.
