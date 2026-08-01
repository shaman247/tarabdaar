# Scales and Tuning

## Overview

Starpad is a just-intonation instrument. There is **one configured scale** — the set of exact frequency ratios the Fret Pad is laid out from — and the tarab can follow it.

- **Playing scale**. A `PitchScale` of JI ratios (`num/den` over the tonic). **Edited on StarpadMac** (the Fret Pad tab's scale list editor) and **synced to the iPad** over USB-MIDI SysEx, where it's performed — the iPad has no editor of its own. The scale spans the half-open octave `[1, 2)` and repeats up and down. Persisted as JSON via `ScaleStore` on both sides. See [Fret Pad](fret-pad.md) and [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).
- **Sympathetic-string tuning** (Mac). The sarangi *tarab* is an editable `[StringSpec]` table (the **Tarab tab**) whose every row is a **scale degree + octave** of the playing scale — pitches ALWAYS follow the scale and the tonic (2026-07-25: the scale is fully centralized; there is no per-string ratio or Hz). There is no follow toggle — following is unconditional; the row *layout* regenerates when the scale's degree count changes (or via the tab's "Regenerate from scale" button), and hand edits to gains/decays/rows otherwise stand. See [Sound Design — Sympathetic strings](sound-design.md#sympathetic-strings--the-editable-bank) and [Sarangi](sarangi.md).

## Scale Editors

### Playing scale (StarpadMac Fret Pad tab → iPad)

The playing scale is the set of `PitchPoint` ratios edited in the Fret Pad
tab's scale list editor (`ScaleListEditor`): add/remove pitches, snap to
"simple" fractions, retune, disable, and a sidebar with text fields.

Edits are pushed to the connected iPad live (debounced) and on connect, so
the performer always plays the current scale — see [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).
The default scale is 12 just-intonation degrees (1/1 … 15/8), named in
**sargam** — `S r R g G m M P d D n N` (2026-07-25; they read `1 · 2- · 2 …`
before). A point's label is its name **everywhere** the app shows that pitch
— frets, drone buttons, the Tarab tab's degree dropdown — so renaming a
degree here renames it across the app; see [Fret Pad — naming](fret-pad.md).
Both copies of the default carry these labels: the bundled
`StarpadMac/Default.json` that actually loads, and `PitchScale.defaultJI`,
the in-code fallback for a missing resource (and the iPad's scale before the
first sync) — **keep them in step**. Disabled pitches drop from the fret
layout but stay listed to toggle back in.

### The tonic (StarpadMac Fret Pad tab)

The tonic is the app's ONE absolute pitch — every other pitch (frets, tarab
strings, drones) is a scale degree relative to it — and the Fret Pad toolbar
is the only place it's set. Two controls, both writing the same value
(`PitchPadEngine.tonicMidi` + `tonicCents`, an integer note anchor plus a
±50 ¢ remainder):

- **Hz field** (a `ScrollableField`) — type an absolute frequency
  (`setTonic(hz:)`, 20 … 4000 Hz); this is the app's only Hz input.
  **Scroll it** to micro-adjust in cents (`nudgeTonic(cents:)`): **1 ¢** per
  detent, **⌥ = 0.1 ¢**, **⇧ = 10 ¢**. Deltas roll over into the note anchor
  so `tonicCents` stays inside ±50, the range the
  [scale-sync blob](midi-and-audio.md#scale-sync-mac--ipad) encodes (0.01 ¢
  resolution).
- **Note menu** — the pitch label ("D4") as a dropdown listing only the notes
  **within half an octave** of the current tonic (a tritone either side, 13
  semitones, clipped to `PitchPadEngine.tonicNoteRange` = MIDI 24 … 107 =
  C1 … B7). The window **re-centers on each pick**, so walking further is
  repeated picks; the Hz field covers a jump. Picking a note **keeps the
  current cents offset** (`setTonic(midi:)`), so a fine tuning against a
  reference survives a change of note.

A "+12.0¢" readout follows the two fields whenever the tonic sits off its note
anchor (blank when exact). The iPad's tonic is read-only, mirrored over SysEx.

**The tonic ALWAYS starts at D4** (`PitchPadEngine.defaultTonicMidi` = MIDI 62,
293.665 Hz — the sarangi tonic this instrument is voiced around), every Mac
launch. It is **deliberately not persisted**: the session tonic is a
per-sitting decision, and a stale restored one silently retunes the whole
instrument, since the frets, the tarab and the drones all resolve against it.
(A `starpad.tonicHz` UserDefaults key used to restore it — removed 2026-07-30;
don't reinstate it.) Everything else about the scale — the degrees, their
labels, the layout — *is* persisted, so a session opens on your scale at D4.
The iPad is unaffected: it opens on the last state the Mac pushed
(`SyncedScaleStore`, a one-way mirror, not a preference of its own) and takes
the Mac's D4 on the next connect.

### Sympathetic tuning (Mac)

The sympathetic strings are the editable `[StringSpec]` tarab table (Tarab tab). Every string is a scale degree + octave, so the bank always sounds pitches of the playing scale; the string layout — one string per enabled scale pitch plus doublings and octave repeats — regenerates when the scale's degree count changes. See [Sarangi](sarangi.md).

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
