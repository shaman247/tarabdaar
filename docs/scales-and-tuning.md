# Scales and Tuning

## Overview

Tarabdaar is a just-intonation instrument with **one configured scale** and **one tonic**. Every pitch the app plays — Fret Pad frets, tarab strings, drones, chord-bar triads — is a degree of that scale resolved against that tonic.

- **Playing scale.** A `PitchScale` of JI ratios (`num/den` over the tonic) spanning the half-open octave `[1, 2)` and repeating up and down. **Edited on the Mac** (the Fret Pad tab's scale list editor) and **synced to the iPad** as a TLP event, where it is performed — the iPad has no editor. Persisted as JSON via `ScaleStore` on the Mac; the iPad keeps a one-way mirror (`SyncedScaleStore`). See [Fret Pad](fret-pad.md) and [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).
- **Sympathetic-string tuning** (Mac). The tarab is an editable `[StringSpec]` table (the **Strings tab**) whose every raga row is a **scale degree + octave** of the playing scale — there is no per-string ratio or Hz, and following the scale is unconditional. The row *layout* regenerates when the scale's degree count changes (or via the tab's "Regenerate from scale" button); hand edits to gains, decays and rows otherwise stand. The **chromatic set** sits on its own bridge as semitones of a fixed JI grid off the tonic. See [Sound Design — Sympathetic strings](sound-design.md#sympathetic-strings--the-editable-bank) and [Sarangi](sarangi.md).

## The playing scale (Fret Pad tab → iPad)

The scale is the set of `PitchPoint` ratios edited in `ScaleListEditor`: add/remove pitches, snap to "simple" fractions, retune, disable, and a sidebar with text fields. Edits push to the connected iPad live (debounced) and on connect. Disabled pitches drop from the fret layout but stay listed to toggle back in.

**The default scale** is 12 just-intonation degrees (1/1 … 15/8) named in **sargam** — `S r R g G m M P d D n N`. Two copies carry these labels: the bundled `TarabdaarMac/Default.json` that loads, and `PitchScale.defaultJI`, the in-code fallback for a missing resource (and the iPad's scale before its first sync) — **keep them in step**.

**One naming.** A point's `label` is its name **everywhere** the app shows that pitch — frets, drone buttons, the Strings tab's degree dropdown, the Scope tab's gridlines — so renaming a degree here renames it across the app (`scaleLabel(degree:octave:degrees:)` / `scaleLabel(forRatio:degrees:)` in `ScaleDegrees.swift`; octave repeats add `'`/`,`). Concert note names (`Scale.noteName`) are a different axis: they label absolute Hz in the tuning readouts, never scale degrees. Guard: `ScaleLabelTests`.

| Degree | Label | Ratio | Cents from 12-TET |
|--------|-------|-------|-------------------|
| 0 | S | 1/1 | 0 |
| 1 | r | 16/15 | −12 |
| 2 | R | 9/8 | +4 |
| 3 | g | 6/5 | +16 |
| 4 | G | 5/4 | −14 |
| 5 | m | 4/3 | −2 |
| 6 | M | 45/32 | −10 |
| 7 | P | 3/2 | +2 |
| 8 | d | 8/5 | +14 |
| 9 | D | 5/3 | −16 |
| 10 | n | 16/9 | −4 |
| 11 | N | 15/8 | +12 |

### Scale presets

The Scale menu's **Scales** submenu holds the built-in presets (`ScalePreset`, `ScaleDegrees.swift`): the modes, major/minor variants and pentatonics, each rendered from the same 12-tone JI ratio table as the default and labelled by degree number — plus **12-TET Chromatic**, the full equal-tempered scale for playing alongside equal-tempered instruments. It keeps the default scale's sargam labels; only the ratios differ.

**How a tempered scale fits a rational model.** Every scale pitch is a `num/den` rational — in the JSON on disk and as two 14-bit integers in the [scale-sync blob](midi-and-audio.md#scale-sync-mac--ipad) — and a tempered semitone is irrational, so the preset ships each `2^(k/12)` as its best rational approximation with both terms under the blob's 16383 bound (`ScalePreset.equalTemperedRatios`, e.g. 11011/10393 for the semitone). The residual is below 0.0001 ¢, three orders of magnitude under the tonic's 0.01 ¢ wire resolution, so nothing in the app can tell it from true equal temperament, and the wire format, the persisted scale, the iPad's decode and the tarab's `(degree, octave)` references are all untouched. `ScalePresetTests` pins the bound and the accuracy. The editor shows the big fractions in its ratio fields, which is honest: retune one and it is that rational; "snap to simple fractions" pulls it back to JI. Loading the preset keeps the tarab's row layout (twelve degrees) and retunes every raga row to the tempered pitch; the **chromatic taraf set** stays on its fixed JI grid by design, so under the tempered scale its strings sit up to ~16 ¢ from the played pitches, as a sarangi's fixed tarab would.

## The tonic (Fret Pad tab)

The tonic is the app's ONE absolute pitch, and the Fret Pad toolbar is the only place it is set. Two controls write the same value (`PitchPadEngine.tonicMidi` + `tonicCents`, an integer note anchor plus a ±50 ¢ remainder):

- **Hz field** — type an absolute frequency (`setTonic(hz:)`, 20 … 4000 Hz); this is the app's only Hz input and the way to tune off a 12-TET note (0.01 Hz ≈ 0.06 ¢ at D4). It splits into the anchor plus a remainder inside ±50 ¢, the range the scale-sync blob encodes at 0.01 ¢ resolution. It is a plain `TextField` — no scroll-wheel stepping.
- **Note menu** — the pitch label ("D4") as a dropdown listing only the notes **within half an octave** of the current tonic (13 semitones, clipped to `PitchPadEngine.tonicNoteRange` = MIDI 24 … 107). The window re-centers on each pick; the Hz field covers a jump. Picking a note **keeps the current cents offset** (`setTonic(midi:)`), so a fine tuning survives a change of note.

A "+12.0¢" readout follows the fields whenever the tonic sits off its note anchor (blank when exact). The iPad's tonic is read-only, mirrored over the sync.

**The tonic starts at D4 on every Mac launch** (`PitchPadEngine.defaultTonicMidi` = MIDI 62, 293.665 Hz). It is **deliberately not persisted**: the session tonic is a per-sitting decision, and a stale restored one would silently retune the whole instrument, since the frets, the tarab and the drones all resolve against it. Everything else about the scale — the degrees, their labels, the layout — *is* persisted, so a session opens on your scale at D4. The iPad opens on the last state the Mac pushed and takes the Mac's tonic on the next connect.

## Pitch on the wire and in the engine

Every touch travels as an f32 fractional-MIDI pitch (`tonicFractionalMidi + 12·log2(ratio)`) — no note + bend split. All pitch interpolation runs in `log2(freq)`. `Scale.swift` owns the 12-TET frequency and note-name helpers used on both sides (`scale.frequency(for:)`, `Scale.noteName`); never hardcode a 12-TET formula. `Config.midiPitchBendRange` (±48 semitones) applies only to the in-process MIDI vocabulary (auditions, external controllers).

The older keyboard-model `Scale` (tuning system, enabled pitch classes, key range) is not on the playing path — see `docs/history/`.
