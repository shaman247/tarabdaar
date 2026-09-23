# Playing Guide

## Physical setup

1. Place the iPad on a flat surface in landscape orientation (USB-C port on the right).
2. Play the **Fret Pad** from above and hold the Joy-Con in your playing grip for wrist motion, stick, strum and octave controls.
3. The Mac's **Controls tab (⌘4)** provides three shared **Tilt ↕/↔/⟲** dimensions. A connected controller supplies them through its wrist calibration.
4. When the controller disconnects, the same tilt bindings automatically use the iPad through its separate arm calibration. Move the iPad onto your inner forearm to use that calibration. Reconnecting the controller switches back automatically.

## Connecting

Plug the iPad into the Mac over USB, or pair it over Bluetooth (BLE-MIDI — see [MIDI & Audio](midi-and-audio.md)). On the Mac, **Audio MIDI Setup › Window › Show MIDI Studio** must show the iPad enabled. Launch TarabdaarMac; the top-bar pill reads `MIDI: N src` once it sees the iPad, and the first touch sounds immediately — no settings to sync.

## Calibration (Mac)

In **Setup (⌘7)**, the Joy-Con panel comes first. **Wrist calibration** captures the Joy-Con in the playing grip:

1. **Rest** — hold the Joy-Con still in a neutral playing pose.
2. **Sweep the wrist up and down.**
3. **Sweep the wrist inward and outward.** Rotation is inferred from these two sweeps.

Start each sweep from rest and end near rest if you can. Advance with Next or dpad-up; dpad-down redoes the previous phase. **ZL** re-zeroes both calibrated rest poses. Controller tilt input requires wrist calibration; the stick and Joy-Con acceleration have independent paths. Calibrations persist across launches.

The collapsed **Arm fallback** section holds the iPad's arm calibration: rest, arm up/down, arm inward/outward, then arm rotation. Set it up with the iPad on your forearm before relying on it as a backup. Without an arm calibration, the tilt input uses raw, uncentred iPad angles. The iPad itself only streams raw motion. See [Sensors](sensors.md).

Factory bindings pair the wrist and arm directions with matching curves: up/down controls Taraf Purity and Expression, inward/outward controls Taraf Decay, and rotation controls Tone Tilt. Existing saved mappings retain their own bindings; edit the wrist and arm rows independently in Controls.

## Playing notes

Touch a fret on the Fret Pad to sound its pitch. Each fret is a vertical segment placed freely across the surface; a touch that starts within the Snap distance of a fret (and inside its vertical extent) snaps to that fret's exact pitch, while starting in open space plays the continuous fret field — the approach path into a note. The base layout sits in a band across the lower-middle of the surface and repeats up and down as read-only octave-ghost copies. Press-to-sound **drone buttons** sit inside the right edge; the **chord bar** strip below the band (hidden for now) selects a triad for the Joy-Con strum. See [Fret Pad](fret-pad.md).

Multiple fingers play polyphonically — every touch mounts its own fresh string on the Mac. There is no mono/poly toggle.

## Gliding

Drag a finger for a continuous pitch slide: the held note bends through the fret field, and the pitch follows your finger at wire rate — every meend is your own movement. A gated **drag assist** lands stops on frets without warping fast transit or vibrato. The **fret warp** parameter (`ctl_fret_warp`, bindable to a tilt or stick axis) morphs the field between fretless-linear and near-quantized mid-phrase. The **pitch accent** (`ctl_fret_accent`, also bindable) dips the bow between the pad's frets and brings it back as you land on each one, so a slow glide through a phrase still reads as separate notes and a gap with no fret in it is one dip, not two.

With the **glide queue** armed (`ctl_glide_on`), a new touch that overlaps a sounding one or arrives within the 150 ms release grace becomes a waypoint instead of a new note: the sounding voice glides through the queued pitches, and releasing the owner glides back to the most recent parked finger. Off by default. See [Glide System](glide-system.md).

## Vibrato and expression

Vibrato is a **playing technique**, not an automatic LFO: the pitch tracks your finger, so rocking it bends the pitch with the motion.

Everything else comes from the **dimensions** the Mac's **Controls tab (⌘4)** binds to composites (Taraf Purity, Taraf Decay, Tone Tilt, Expression) or to any single parameter, with a curve per binding. Several dimensions can drive one target and their swings add — the wrist sets Expression and a hard strike lifts it further:

- **Tilt ↕/↔/⟲** — calibrated controller motion while connected, otherwise calibrated iPad motion (raw angles if uncalibrated)
- **Joy-Con stick** Left/Right/Up/Down — each stick direction maps independently
- **Strike / Acceleration** — the accelerometer strike envelope, blended per note from attack to sustain over `ctl_strike_window`
- **Finger accel** — the playing finger's signed pitch acceleration (rest and constant-rate meend = 0)
- **Joy-Con accel** — the controller's own acceleration magnitude

**Attack sharpness** in Articulation is a direct 0–1 binding target: 0 gives a gentle draw, 1 a sharp bite. Its value is captured at each new note; bind it to Strike or Joy-Con Accel to shape attacks independently of expression.

The iPad toolbar shows each source live (arm/wrist/stick squares, the strike and finger-accel scopes, the Mac's radiated volume). See [Sensors](sensors.md).

## Octave shift and strum (Joy-Con)

Dpad ←/→ shift the playing range by whole octaves (±3; the toolbars read "Oct +1"); a sounding note keeps its octave, the next onset takes the new one. Drones, the tarab and the strum do not shift. The strum plays the configured chord — or the chord-bar selection — on the sympathetic strings.

Dpad **↓** or the rear **GL** button plays the next drone in a repeating **Sa → Pa → high Sa → high Sa** sequence, using the three existing drone mappings. Configure the steps in **Strings → Drone buttons → Drone sequence (Down / GL)**. Each press advances immediately; holding advances every **2 seconds**. Both buttons share the sequence, which keeps running until both are released. Tanpura drones start **one octave lower**; **↑** toggles back to the original octave and down again, taking effect on the next pluck. The octave selection starts low each launch. During calibration, ↓ still redoes the previous phase and ↑ advances it, without changing the sequence or octave.

## Scale editing (on the Mac)

The iPad is **perform-only**. Scales are designed on the Mac's Fret Pad tab (⌘3): the scale list editor (add/remove/disable pitches, snap to simple fractions, the Scales presets including 12-TET Chromatic) and the tonic in Hz. Edits sync to the iPad within a moment; the iPad opens on the last scale it received. See [Scales & Tuning](scales-and-tuning.md).

## Learn the taraf balance by playing

Open **Strings (⌘2)** to see pitch distributions over 10 seconds, 60 seconds,
and the whole performance. Notes in different octaves count toward the same
pitch class; lingering counts more than passing through, and silence ages
the two recent windows. The histograms record with Adaptation at zero.

Raise **Adaptation** to hear the taraf's gains follow the learned distribution.
Zero restores the saved levels; full amount keeps the prominent degrees at
their saved gain and lowers absent ones toward 15%. This affects existing,
enabled taraf rows on both bridges, and preserves their saved tuning,
gains and decays. It does not create or enable strings.

To establish the raga quickly, press **Reset & seed** (Joy-Con **Minus**), play
the basic notes with a brief hold on each (at least 180 ms), then press
**Finish seed** (Minus again). The recognized degrees light up and start
with equal weight; continue performing to refine the distribution. **Reset
performance** (Joy-Con **Capture**) clears everything for a new performance.
The profile resets on scale or tonic changes and on app restart.

## Instruments

The Live tab (⌘1) picks the played voice: **String** (bowed, the default), **Tanpura** or **Sitar** (plucked — a fret touch plucks at the exact bent pitch, drags retune the ringing string). The Strings tab's drone Voice picker chooses the Tanpura or the sympathetic strings for the drone buttons.

## PANIC

If a note sticks, tap the red **PANIC** button in the iPad toolbar: it clears every touch, and the Mac releases all strings.
