# Playing Guide

## Physical setup

1. Hold the iPad in landscape orientation (USB-C port on the right).
2. Rest the iPad on your inner forearm, screen facing up.
3. The **Fret Pad** fills the screen below the slim toolbar; your fingers play it from above.
4. Tilting your arm drives whatever the Mac's Controls tab binds to the arm axes.

## Connecting

Plug the iPad into the Mac over USB, or pair it over Bluetooth (BLE-MIDI — see [MIDI & Audio](midi-and-audio.md)). On the Mac, **Audio MIDI Setup › Window › Show MIDI Studio** must show the iPad enabled. Launch TarabdaarMac; the top-bar pill reads `MIDI: N src` once it sees the iPad, and the first touch sounds immediately — no settings to sync.

## Calibration: one step, on the Mac

The iPad needs no calibration — it streams raw orientation continuously. The app's tilt calibration is the **arm calibration** on the Mac's **Setup tab (⌘7)**, which fits the three arm control axes from the iPad on your forearm:

1. **Rest** — hold the arm still in playing position
2. **Sweep the arm up and down**
3. **Sweep the arm inward and outward**
4. **Rotate the arm inward and outward**

Start each sweep from rest and end near rest if you can. Advance with the panel's Next button or the Joy-Con's dpad-up; dpad-down redoes the previous phase; ZL re-zeroes the rest pose any time. The calibration persists across launches. Without one, the iPad's raw axes drive the tilts directly — playable, but uncentered. With a Joy-Con, the **wrist calibration** (same procedure over the Joy-Con's attitude) and the **stick calibration** live on the same tab. See [Sensors](sensors.md).

## Playing notes

Touch a fret on the Fret Pad to sound its pitch. Each fret is a vertical segment placed freely across the surface; a touch that starts within the Snap distance of a fret (and inside its vertical extent) snaps to that fret's exact pitch, while starting in open space plays the continuous fret field — the approach path into a note. The base layout sits in a central band and repeats up and down as read-only octave-ghost copies. Press-to-sound **drone buttons** sit inside the right edge, and the **chord bar** strip below the band selects a triad for the Joy-Con strum. See [Fret Pad](fret-pad.md).

Multiple fingers play polyphonically — every touch mounts its own fresh string on the Mac. There is no mono/poly toggle.

## Gliding

Drag a finger for a continuous pitch slide: the held note bends through the fret field, and the pitch follows your finger at wire rate — every meend is your own movement. A gated **drag assist** lands stops on frets without warping fast transit or vibrato. The **fret warp** parameter (`ctl_fret_warp`, bindable to a tilt or stick axis) morphs the field between fretless-linear and near-quantized mid-phrase.

With the **glide queue** armed (`ctl_glide_on`), a new touch that overlaps a sounding one becomes a waypoint instead of a new note: the sounding voice glides through the queued pitches, and releasing the owner glides back to the most recent parked finger. Off by default. See [Glide System](glide-system.md).

## Vibrato and expression

Vibrato is a **playing technique**, not an automatic LFO: the pitch tracks your finger, so rocking it bends the pitch with the motion.

Everything else comes from the **dimensions** the Mac's **Controls tab (⌘4)** binds to composites (Taraf Purity, Taraf Decay, Tone Tilt, Expression) or to any single parameter, with a curve per binding:

- **Arm ↕/↔/⟲** — the iPad's tilt axes through the arm calibration (bipolar, rest = 0)
- **Wrist ↕/↔/⟲** and the **Joy-Con stick** X/Y — with a Joy-Con attached
- **Strike / Acceleration** — the accelerometer strike envelope, blended per note from attack to sustain over `ctl_strike_window`
- **Finger accel** — the playing finger's signed pitch acceleration (rest and constant-rate meend = 0)
- **Joy-Con accel** — the controller's own acceleration magnitude

The iPad toolbar shows each source live (arm/wrist/stick squares, the strike and finger-accel scopes, the Mac's radiated volume). See [Sensors](sensors.md).

## Octave shift and strum (Joy-Con)

Dpad ←/→ shift the playing range by whole octaves (±3; the toolbars read "Oct +1"); a sounding note keeps its octave, the next onset takes the new one. Drones, the tarab and the strum do not shift. The strum plays the configured chord — or the chord-bar selection — on the sympathetic strings.

## Scale editing (on the Mac)

The iPad is **perform-only**. Scales are designed on the Mac's Fret Pad tab (⌘3): the scale list editor (add/remove/disable pitches, snap to simple fractions, the Scales presets including 12-TET Chromatic) and the tonic in Hz. Edits sync to the iPad within a moment; the iPad opens on the last scale it received. See [Scales & Tuning](scales-and-tuning.md).

## Instruments

The Live tab (⌘1) picks the played voice: **String** (bowed, the default), **Tanpura** or **Sitar** (plucked — a fret touch plucks at the exact bent pitch, drags retune the ringing string). The Strings tab's drone Voice picker chooses the Tanpura or the sympathetic strings for the drone buttons.

## PANIC

If a note sticks, tap the red **PANIC** button in the iPad toolbar: it clears every touch, and the Mac releases all strings.
