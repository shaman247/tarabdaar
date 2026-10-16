# Scales and Tuning

## Overview

Tarabdaar has **one configured playing scale** and **one tonic**. Frets and
chord-bar triads resolve scale degrees against the tonic. Each sympathetic row
independently chooses its bridge and pitch source: the playing scale or a fixed
chromatic JI grid. Drones reference those rows. See [Sarangi](sarangi.md) for the
row model and bank invariants.

- **Playing scale.** A `PitchScale` of JI ratios (`num/den` over the tonic) spanning the half-open octave `[1, 2)` and repeating up and down. **Edited on the Mac** (the Fret Pad tab's scale list editor) and **synced to the iPad** as a TLP event, where it is performed — the iPad has no editor. Persisted as JSON via `ScaleStore` on the Mac; the iPad keeps a one-way mirror (`SyncedScaleStore`). See [Fret Pad](fret-pad.md) and [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).
- **Sympathetic-string tuning** (Mac). The Strings tab edits `[StringSpec]` rows by degree and octave, with a separate bridge set and `followsScale` choice. Scale-following rows retune with the playing scale; fixed rows retain their chromatic JI ratio over the tonic. Cross-bank unisons are valid; duplicates collapse only within a bridge set. See [Sarangi](sarangi.md) for the complete row contract and [Fret Pad](fret-pad.md) for fret coloring and row toggles.

## The playing scale (Fret Pad tab → iPad)

The scale is the set of `PitchPoint` ratios edited in `ScaleListEditor`: add/remove pitches, type exact ratios or decimal values, retune, disable, and edit labels and vertical positions in the sidebar. Ratio fields accept typed edits; vertical-position fields also support scroll stepping. Edits push to the connected iPad live (debounced) and on connect. Disabled pitches drop from the fret layout but stay listed to toggle back in.

Named scales and fret arrangements encode completely before atomically replacing
their JSON files. A failed save leaves the previous document intact; autosaved
arrangements use the same replacement operation.

**The default scale** is 12 just-intonation degrees (1/1 … 15/8) named in **sargam** — `S r R g G m M P d D n N`. Two copies carry these labels: the bundled `TarabdaarMac/Default.json` that loads, and `PitchScale.defaultJI`, the in-code fallback for a missing resource (and the iPad's scale before its first sync) — **keep them in step**.

**One naming.** A point's `label` is its name **everywhere** the app shows that pitch — frets, drone mappings, the Strings tab's degree dropdown, the Scope tab's gridlines — so renaming a degree here renames it across the app (`scaleLabel(degree:octave:degrees:)` / `scaleLabel(forRatio:degrees:)` in `ScaleDegrees.swift`; octave repeats add `'`/`,`). Concert note names (`Scale.noteName`) are a different axis: they label absolute Hz in the tuning readouts, never scale degrees. Guard: `ScaleLabelTests`.

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

The Scale menu's **Scales** submenu holds the built-in presets (`ScalePreset`, `ScaleDegrees.swift`): the modes, major/minor variants and pentatonics, each rendered from the same 12-tone JI ratio table as the default and labelled by degree number — plus **Just Intonation (Default)**, **Pythagorean Chromatic**, their **Ma-rotated** variants and **12-TET Chromatic**. All five chromatic presets keep the default scale's twelve sargam labels and keyboard rows; only the ratios differ. **Just Intonation (Default)** loads `PitchScale.defaultJI` through the ordinary preset path, preserving the current fret arrangement. **Reset to Default** also restores the Pilu arrangement.

**Pythagorean Chromatic** builds its twelve pitches from pure 3/2 fifths, five below and six above the tonic, reduced into one octave and sorted. In `S r R g G m M P d D n N` order the exact ratios are `1/1, 256/243, 9/8, 32/27, 81/64, 4/3, 729/512, 3/2, 128/81, 27/16, 16/9, 243/128`. The lowered degrees use their flat forms, and tivra `M` uses the augmented fourth `729/512`. These [Pythagorean intervals](https://math.ucr.edu/home/baez/tuning_book/) use only factors of 2 and 3 and fit the scale-sync blob exactly. `ScalePresetTests` checks the fifth-chain tuning, default labels/layout and exact ratio round-trip for both chromatic variants. Loading either preserves the row layout and retunes scale-following rows; fixed rows retain their chromatic JI ratios regardless of bridge set.

**Just Intonation (Ma-rotated)** and **Pythagorean Chromatic (Ma-rotated)** tune the other notes relative to shuddha Ma as the base scale tunes them relative to Sa. Sa remains the tonic at `1/1`, and Ma (`m`) remains `4/3` of Sa. Each variant multiplies its base ratios by `4/3`, folds them into `[1, 2)`, reduces the fractions and sorts them back into Sa-relative degree order, retaining the original labels and layout. Thus the base scale's `S r R …` intervals measured above Ma belong to `m M P …` in the resulting scale. These presets load through the ordinary scale path and preserve the current tonic and fret arrangement.

Only these pitches differ from their respective base scales; every other ratio stays the same:

| Variant | Degree | Base ratio | Ma-rotated ratio |
|---------|--------|------------|------------------|
| Just Intonation | R | 9/8 | 10/9 |
| Just Intonation | g | 6/5 | 32/27 |
| Just Intonation | M | 45/32 | 64/45 |
| Pythagorean | M | 729/512 | 1024/729 |

`ScalePresetTests` checks every rotated interval relative to Ma with exact rational arithmetic, the Sa/Ma anchors, default labels/layout and exact ratio round-trip through scale sync.

**How a tempered scale fits a rational model.** Every scale pitch is a `num/den` rational — in the JSON on disk and as two 14-bit integers in the [scale-sync blob](midi-and-audio.md#scale-sync-mac--ipad) — and a tempered semitone is irrational, so the preset ships each `2^(k/12)` as its best rational approximation with both terms under the blob's 16383 bound (`ScalePreset.equalTemperedRatios`, e.g. 11011/10393 for the semitone). The residual is below 0.0001 ¢, three orders of magnitude under the tonic's 0.01 ¢ wire resolution, so nothing in the app can tell it from true equal temperament, and the wire format, the persisted scale, the iPad's decode and the tarab's `(degree, octave)` references are all untouched. `ScalePresetTests` pins the bound and the accuracy. The editor shows the exact fractions in its ratio fields; typing a new ratio retunes that degree. Loading the preset keeps the tarab's row layout and retunes scale-following rows to the tempered pitches. Fixed rows keep their chromatic JI ratios, placing them up to ~16 ¢ from the played pitches under this scale.

## The tonic (Fret Pad tab)

The tonic is the app's ONE absolute pitch, and the Fret Pad toolbar is the only place it is set. Two controls write the same value (`PitchPadEngine.tonicMidi` + `tonicCents`, an integer note anchor plus a ±50 ¢ remainder):

- **Hz field** — type an absolute frequency (`setTonic(hz:)`, 20 … 4000 Hz); this is the app's only Hz input and the way to tune off a 12-TET note (0.01 Hz ≈ 0.06 ¢ at D4). It splits into the anchor plus a remainder inside ±50 ¢, the range the scale-sync blob encodes at 0.01 ¢ resolution. It is a plain `TextField` — no scroll-wheel stepping.
- **Note menu** — the pitch label ("D4") as a dropdown listing only the notes **within half an octave** of the current tonic (13 semitones, clipped to `PitchPadEngine.tonicNoteRange` = MIDI 24 … 107). The window re-centers on each pick; the Hz field covers a jump. Picking a note **keeps the current cents offset** (`setTonic(midi:)`), so a fine tuning survives a change of note.

A "+12.0¢" readout follows the fields whenever the tonic sits off its note anchor (blank when exact). The iPad's tonic is read-only, mirrored over the sync.

**The tonic starts at E4 on every Mac launch** (`PitchPadEngine.defaultTonicMidi` = MIDI 64, 329.628 Hz). It is **deliberately not persisted**: the session tonic is a per-sitting decision, and a stale restored one would silently retune the whole instrument, since the frets, the tarab and the drones all resolve against it. Everything else about the scale — the degrees, their labels, the layout — *is* persisted, so a session opens on your scale at E4. The iPad opens on the last state the Mac pushed and takes the Mac's tonic on the next connect.

## Pitch on the wire and in the engine

Every touch travels as an f32 fractional-MIDI pitch (`tonicFractionalMidi + 12·log2(ratio)`) — no note + bend split. All pitch interpolation runs in `log2(freq)`. `SarangiKit.Pitch` is the ONE fractional-MIDI ↔ Hz conversion (`hz(fractionalMidi:)` / `fractionalMidi(hz:)`) and `NoteName` the one concert-name table (`Scale.noteName` reaches it from TarabdaarCore) — never hardcode a 12-TET formula, and never name a scale degree by a concert note.

The bowed String kernel tunes its complete traveling-wave loop to that requested
frequency by compensating the current loss-filter and dispersion phase delays.
Register damping and live loss edits therefore update the correction along with
the sound. This does not change the scale ratios: a JI degree retains its intended
offset from an equal-tempered tuner. Heavy bow pressure can still pull the
physical oscillation slightly from the requested pitch. See
[Sarangi — signal path](sarangi.md#signal-path).

The older keyboard-model `Scale` (tuning system, enabled pitch classes, key range) is not on the playing path — see `docs/history/`.
