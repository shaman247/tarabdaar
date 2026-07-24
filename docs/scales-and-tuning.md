# Scales and Tuning

## Overview

Starpad is a just-intonation instrument. There is **one configured scale** — the set of exact frequency ratios the Fret Pad is laid out from — and the tarab can follow it.

- **Playing scale**. A `PitchScale` of JI ratios (`num/den` over the tonic). **Edited on StarpadMac** (the Fret Pad tab's scale list editor) and **synced to the iPad** over USB-MIDI SysEx, where it's performed — the iPad has no editor of its own. The scale spans the half-open octave `[1, 2)` and repeats up and down. Persisted as JSON via `ScaleStore` on both sides. See [Fret Pad](fret-pad.md) and [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).
- **Sympathetic-string tuning** (Mac). The sarangi *tarab* is a separately editable `[StringSpec]` table (the **Tarab tab**), which **can** follow the playing scale but **auto-sync starts OFF** by default (the String-era default) so the fitted Pilu table sticks. Turn on "Follow the Pitch Pad scale" to have the tarab retune to the tonic + scale degrees. See [Sound Design — Sympathetic strings](sound-design.md#sympathetic-strings--the-editable-bank) and [Sarangi](sarangi.md).

## Scale Editors

### Playing scale (StarpadMac Fret Pad tab → iPad)

The playing scale is the set of `PitchPoint` ratios edited in the Fret Pad
tab's scale list editor (`ScaleListEditor`): add/remove pitches, snap to
"simple" fractions, retune, disable, and a sidebar with text fields.

Edits are pushed to the connected iPad live (debounced) and on connect, so
the performer always plays the current scale — see [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).
The default scale is 12 just-intonation degrees (1/1 … 15/8). Disabled
pitches drop from the fret layout but stay listed to toggle back in.

### Sympathetic tuning (Mac)

The sympathetic strings are the editable `[StringSpec]` tarab table (Tarab tab). By default it does **not** follow the playing scale (auto-sync off, so the fitted table stays exact); opting in retunes one string per enabled scale pitch, octave-replicated over the tonic. See [Sarangi](sarangi.md).

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
