# Scales and Tuning

## Overview

Starpad supports custom scales (subsets of the 12-tone chromatic scale) and two tuning systems: 12-tone equal temperament (12-TET) and just intonation (JI). The keyboard always displays the standard piano layout, but disabled notes are grayed out and cannot be played.

Starpad maintains **two independent scales**:

- **Playing scale** — what pitches appear on the keyboard and their tuning.
- **Sympathetic-string scale** — what pitches have always-on sympathetic voices. Each enabled MIDI note in this scale gets its own pure-sine voice whose amplitude is modulated by how "related" its pitch is to the base voice currently being played (see [MIDI & Audio](midi-and-audio.md#sympathetic-excitation)).

They can diverge freely: you can play in one key while the sympathetic strings ring in another, span different ranges, or use different tuning systems. On first run the sympathetic scale is initialised from the playing scale; after that the two persist separately.

The two scales also differ in how "enabled" is interpreted:

- **Playing scale**: octave-invariant. Enabling C turns on every C across the keyboard.
- **Sympathetic scale**: per-MIDI-note. Enabling C4 adds exactly one "string" at 261.63 Hz. Enabling C5 would add a separate string at 523.25 Hz.

This matters because each enabled sympathetic MIDI note becomes one continuously-running sine voice at that specific frequency, so two "same-pitch-class-different-octave" notes produce two independent voices rather than one voice echoed across octaves.

Internally this is a `specificNoteMode` flag on `Scale`. The Strings tab in the editor activates it; the Playing tab leaves it off.

## Scale Editor

Tap the **SCALE** button in the status bar to enter scale editing mode. The keyboard area transforms into an interactive editor.

The top-left toolbar has a **Playing / Strings** tab pair (pink when selected). It picks which scale every other control in the editor acts on. Switching tabs does not touch the other scale.

### Controls
- **Tap a key**: Toggle that pitch class on/off (yellow = enabled, dim = disabled). At least one note must remain enabled. In JI mode, the root note cannot be disabled.
- **Drag left/right**: Pan the keyboard range (shifts start and end notes together).
- **Pinch**: Zoom in/out to change the keyboard range (arbitrary semitone ranges, min 5, max 48).
- **Long press** (JI only): Set that key as the just intonation root (shown in green).
- **Toolbar**: Tuning system picker (12-TET / JI), range display, reset button.
- **SCALE/DONE button**: The same button in the status bar toggles between play and edit modes. Shows "SCALE" (purple) in play mode, "DONE" (blue) in edit mode.

### Ratio Band
When scale editor mode is active, a band above the keyboard shows the interval ratio for each enabled note relative to the JI root (e.g., "3/2" for a perfect fifth). In equal temperament mode, it shows the pitch class number (0-11).

### Visual Indicators
- **Yellow keys**: Enabled notes
- **Green keys**: JI root note
- **Dim keys**: Disabled notes
- **Note labels**: Shown at the bottom of each white key

Changes take effect immediately and persist across app launches.

## Tuning Systems

### Equal Temperament (default)

Standard Western tuning where each semitone has an equal frequency ratio of 2^(1/12):

```
frequency = 440 * 2^((midiNote - 69) / 12)
```

### Just Intonation

Uses pure frequency ratios relative to a base note, producing intervals that align with the harmonic series. The ratios for each pitch class are:

| Degree | Name | Ratio | Cents from ET |
|--------|------|-------|---------------|
| 0 | Unison | 1/1 | 0 |
| 1 | Minor 2nd | 16/15 | -12 |
| 2 | Major 2nd | 9/8 | +4 |
| 3 | Minor 3rd | 6/5 | +16 |
| 4 | Major 3rd | 5/4 | -14 |
| 5 | Perfect 4th | 4/3 | -2 |
| 6 | Tritone | 45/32 | -10 |
| 7 | Perfect 5th | 3/2 | +2 |
| 8 | Minor 6th | 8/5 | +14 |
| 9 | Major 6th | 5/3 | -16 |
| 10 | Minor 7th | 16/9 | -4 |
| 11 | Major 7th | 15/8 | +12 |

The base note determines which MIDI note corresponds to the 1:1 ratio. For example, with base = C4 (MIDI 60), C4 is the reference and all other notes are tuned relative to it.

### MIDI with Just Intonation

MIDI note numbers are still sent as standard 12-TET values. The pitch bend is used to achieve the JI detuning. This means:
- The receiving synth receives standard MIDI note events
- Pitch bend adjusts the actual sounding frequency to match the JI ratio
- The pitch bend range (default ±48 semitones) must be large enough to cover the JI deviations

## Implementation Details

### Scale Model (`Scale.swift`)

```swift
struct Scale {
    var tuning: TuningSystem          // .equalTemperament or .justIntonation
    var baseNote: Int                 // MIDI note for JI root (default: 60 = C4)
    var enabledDegrees: Set<Int>      // pitch classes 0-11 (default: all)
    var startNote: Int                // lowest MIDI note on keyboard (default: 55 = G3)
    var endNote: Int                  // highest MIDI note on keyboard (default: 79 = G5)
    var noteCount: Int                // computed: endNote - startNote + 1
}
```

Key methods:
- `frequency(for: Int)` / `frequency(for: Double)` — convert MIDI note to Hz using the active tuning
- `isEnabled(_ midiNote: Int)` — whether a note's pitch class is in the enabled set
- `nearestEnabledNote(to: Double, whiteOnly: Bool)` — snap to nearest playable note
- `enabledNotesInRange()` / `whiteNotesInRange()` — for keyboard layout

### Keyboard Behavior with Disabled Notes

- **Visual**: Disabled white keys are darker (70% white vs 95%). Disabled black keys are dimmer (6% vs 12%).
- **Tap**: Hitting a disabled key plays the nearest enabled note instead.
- **Drag snap**: Direction reversals and stop-snaps only land on enabled notes.
- **Glide**: Pitch glides pass through disabled note frequencies smoothly (they don't skip); only the waypoint targets are restricted to enabled notes.

### Persistence

Scale settings are encoded as JSON and stored in UserDefaults under `starpad_scale`. They load automatically when NoteManager initializes.
