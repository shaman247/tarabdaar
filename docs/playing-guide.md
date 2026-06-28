# Playing Guide

## Physical Setup

1. Hold the iPad in landscape orientation (home button / USB-C on the right)
2. Rest the iPad on your inner forearm, screen facing up
3. The **Pitch Pad** fills the screen below the slim toolbar; your fingers play it from above
4. Tilting your arm controls whatever expression you've mapped (aftertouch, CCs)

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

Touch a cell on the Pitch Pad to sound its pitch. Each cell is one degree
of your JI scale; the cell's color and label identify it. The x-axis is
log-frequency: the base octave (1/1 … 2/1) sits in the middle, and the pad
extends half an octave past each end where the scale's notes repeat
(read-only ghost cells), so you can reach a tritone below the tonic up to
a tritone above the octave. The y-axis is layout-only — it doesn't change
pitch, it just spreads the cells out vertically.

Multiple fingers play polyphonically — each touch is an independent voice
on its own MPE channel. See [Pitch Pad](pitch-pad.md) for the full surface.

## Gliding

Drag a finger across the pad for a continuous pitch slide. Crossing a cell
boundary doesn't retrigger — the held note bends, so the pitch glides
smoothly from one degree to the next.

The boundary between two cells is a soft margin (set by the Mac's **Margin**
slider, default 16 px): inside a cell's inner polygon the exact ratio
sounds; in the strip between two cells the pitch is a log-frequency blend
of the two, hitting their geometric mean on the shared bisector; at a
three-cell junction it blends all three. The sounding cell(s) fill with
their hue, cross-faded by the same weights that drive the pitch, so you can
see exactly where you are between degrees.

There is no stop-snapping — the pad always plays your exact finger
position (or the soft blend), so microtonal inflection between degrees is
on tap. Lift the finger to release that voice.

## Vibrato & tilt expression

Vibrato is a **playing technique**, not an automatic LFO: the pitch tracks
your finger directly, so wiggling left/right — rocking across a cell
boundary into the soft margin — bends the pitch with the motion. (The old
automatic vibrato LFO and its Vibrato Depth/Rate/Intensity mapping params
have been removed.)

Other expression comes from **tilt** (and the sliders / pressure if you map
them). In the **MAP** matrix, bind a tilt axis to **Aftertouch** or a **CC**
to drive SWAM's own expression — including its built-in vibrato. The pad's
60 Hz loop overlays this on every held touch.

## Expression Dimensions

Parameters can have multiple **dimensions** bound to them simultaneously. Configure mappings via the **MAP** button in the toolbar. Each binding defines a Catmull-Rom spline curve (2–4 control points) that maps the dimension's input range to the parameter's output range. When multiple dimensions are bound, sliders (when touched) override tilts, and the dimension with the highest deviation from center wins among same-type inputs.

On the Pitch Pad, expression is driven by the **global** dimensions — Tilt 1/2/3 and Slider 1/2. The per-note dimensions (Pressure, Key Y) are inherited from the old keyboard and currently read their idle value on the pad, so map aftertouch/CCs to a tilt or slider.

**Internal parameters**: Velocity, Glide Speed, Compression, Amplitude, Drag Smoothing, Glide Curve.

**MIDI output parameters**: Aftertouch (channel pressure), CC74 Slide, CC1 Modwheel, CC11 Expression, CC71 Resonance, CC73 Attack, CC75 Decay. MIDI CCs are only sent when mapped to a dimension (not "None"), and are sent per-voice on each voice's MPE channel.

**Available dimensions**:
- **Tilt 1/2/3**: Arm orientation axes from calibration (global, same for all voices)
- **Pressure**: Accelerometer strike intensity at note onset (per-note). When no parameter uses Pressure, the velocity capture delay is skipped for zero-latency note onset.
- **Key Y**: Finger's vertical position on the key (0 = bottom, 1 = top; normalized to key height for black keys). Updated continuously as you slide.
- **Slider 1/2**: Horizontal sliders in the channel readout, operated by the non-dominant hand. Value snaps back to a default when released.
- **None**: Fixed at midpoint

**Defaults**: Velocity → Pressure, Glide Speed/Compression/Amplitude/Aftertouch → Tilt 1. All others → unbound. Each binding starts as a linear 2-point curve matching the parameter's default range.

The tilt values are based on your calibration, so "neutral" is wherever you calibrated your rest position.

## MIDI Setup

1. Connect the iPad to the Mac via USB.
2. On the Mac: open **Audio MIDI Setup** > **Window > Show MIDI Studio** > Enable iPad.
3. Launch StarpadMac. The top-bar pill turns green when it sees the iPad as a MIDI source. The first Note On from the iPad triggers SWAM Viola on the Mac immediately — no settings sync, just MPE on the wire.

The iPad also appears as a standard MPE MIDI source to any other host on the Mac (Ableton, Logic, etc.). To route to those:

1. In Ableton: **Preferences > Link, Tempo & MIDI** > enable the iPad as MIDI input.
2. Set your instrument's pitch bend range to **±48 semitones**.
3. Enable **MPE mode** on the track.

Starpad sends:
- Note on/off with accelerometer-derived velocity
- Pitch bend (continuous; glides + finger-driven pitch movement)
- Channel pressure / aftertouch (dimension-mapped)
- MIDI CCs 1, 11, 71, 73, 74, 75 (dimension-mapped, only sent when mapped to a dimension)

## Scale Editing (on the Mac)

The iPad is **perform-only** — there's no scale editor on it. Scales are
designed on **StarpadMac**'s Pitch Pad tab (drag handles, add/remove/disable
pitches, snap to simple fractions) and **synced to the iPad over the USB
cable** automatically: edit a pitch on the Mac and the iPad's pad re-lays-out
within a moment. The iPad opens on the last scale it received (and on the
built-in default if it has never been synced). See
[Scales & Tuning](scales-and-tuning.md) and
[MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad). The
Pitch Pad always plays exact ratios, so all tuning is just intonation.

## Polyphony

The pad is always polyphonic — there's no mono/poly toggle. Each finger
sounds an independent voice on its own MPE channel, glides on its own as
you drag, and releases when you lift. Tilt expression (aftertouch / CCs)
applies to all held voices.

## PANIC Button

If a note gets stuck, tap the red **PANIC** button in the toolbar. This
sends all-notes-off on all 16 MIDI channels and clears all touch state.
