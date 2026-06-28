# Chord Pad

The **Chord Pad** is a second Mac-side playing surface (StarpadMac tab,
⌘7), built for playing chords rather than designing scales. Where the
[Pitch Pad](pitch-pad.md) lays one pitch per Voronoi cell along a
log-frequency x-axis, the Chord Pad is a fixed **hex grid** whose pitch at
each cell comes from a diatonic scale: every **column** is a stack of
diatonic thirds (a chord), every **row** is a chord tone.

It runs on **both devices**, like the Pitch Pad: the StarpadMac tab is the
design/play surface, and the iPad performs it (`ChordPadViewIOS`) when the
Mac pushes `layout == .chordPad` over the synced state — see
[On the iPad](#on-the-ipad). It reuses, rather than duplicates, the Pitch
Pad machinery:

- A **second `PitchPadEngine`** (`AppController.chordPad`, alongside
  `pitchPad`) is the MPE emitter. The grid converts each cell's pitch to
  `ratio = 2^(semitones/12)` and feeds it to `noteOn`/`glide`/`noteOff`,
  so the engine pins the nearest semitone and bends from there exactly as
  the Pitch Pad does. The engine's own `scale`/snap/`ScaleStore` features
  go unused on this instance.
- The shared OKLCH colors (`pitchColor`), `Path(closedPolygon:)`, the
  `SoundingState` observable, and `CellFillsView` are reused verbatim.
- The soft-margin glide is the same penetration-weight blend as the Pitch
  Pad's `pitchAt`, generalized to explicit hex centers in
  `chordPitchAt` (`Packages/StarpadCore/.../ChordPadGeometry.swift`).

The Chord Pad does **not** own a scale or tonic — it reads them from the
Pitch Pad (`controller.pitchPad.scale` / `.tonicMidi`). Dial a scale on
the Pitch Pad tab and the Chord Pad re-renders to match. Its tonic readout
is therefore read-only.

## Selecting a scale

The scale is **shared** with the Pitch Pad. A set of common presets —
`ScalePreset`: Major, Minor, the seven modes (Dorian, Phrygian, Lydian,
Mixolydian, Locrian), Harmonic/Melodic Minor, and Major/Minor Pentatonic —
loads into the one Pitch Pad `PitchScale` via `PitchPadEngine.loadPreset`.
The same presets are reachable from **both** UIs: the Chord Pad toolbar's
**Load Scale** menu and the Pitch Pad's **Scale → Scales** submenu. Each
preset is a just-intonation `PitchScale` (the same 12-tone JI ratio table
as `PitchScale.defaultJI`), so it reads naturally on the Pitch Pad's JI
surface; the Chord Pad maps the degrees to the nearest 12-TET semitones.
Loading a preset replaces the working scale (it becomes unsaved); the
Pitch Pad's editor and Save/Load still apply on top.

## Base scale → diatonic degrees

The grid's degrees are the Pitch Pad scale's **enabled** points, each
mapped to its nearest 12-TET semitone (`round(12·log2 ratio)`), folded
into `0..<12`, de-duplicated, and sorted ascending
(`chordDegrees(from:)`). A 7-note scale yields 7 degrees → 8 columns → the
6×8 grid. (The Pitch Pad's default is a 12-tone scale → 13 columns; disable
notes on the Pitch Pad to get a 7-note diatonic scale.)

## Grid model

- **Rows = 6** (fixed). **Columns = degreeCount + 1** (the extra column is
  the octave tonic).
- **Row visual order** top→bottom (rows 1…6) → diatonic step offset from
  the column's root degree (`ChordPadLayout.rowStepOffsets`):

  | Row | Offset | Chord tone |
  |-----|--------|------------|
  | 1 | +6 | 7th |
  | 2 | +4 | 5th |
  | 3 | +2 | 3rd |
  | 4 |  0 | root |
  | 5 | −2 | 3rd below |
  | 6 | −3 | 4th below |

- **Column `c`** (0-indexed) has root = diatonic degree `c`.
- **Pitch** (semitones from tonic) for `(col, row)`:

  ```
  step      = col + rowStepOffsets[row]
  n         = degrees.count
  octave    = floorDiv(step, n)        // true floor — Swift / truncates
  idx       = step − octave·n          // always in 0..<n
  semitones = degrees[idx] + 12·octave
  midiNote  = tonicMidi + semitones
  ```

  `floorDiv` is required because the rows below the root produce negative
  `step`s and Swift's `/` / `%` truncate toward zero.

### Worked example — D4 Dorian

Tonic D4 (MIDI 62), degrees `[0,2,3,5,7,9,10]` (n = 7). The first two
columns come out as:

- **Column 1** (root D4): C5, A4, F4, **D4**, B3, A3
- **Column 2** (root E4): D5, B4, G4, **E4**, C4, B3

(rows 1…6 top to bottom; the **bold** row 4 is each column's root).

## Layout & visuals

Hex centers sit on a sheared triangular lattice, so the Voronoi cell of
each center is a regular **pointy-top hexagon** and successive columns lean
**up-right** (the bottom-left→top-right diagonal) while rows stay
horizontal — within a column the deeper rows sit to the left and the higher
rows to the right:

```
center(col,row) = origin + (col·a − row·a/2, row·a·√3/2)
circumradius    = a / √3
```

`a` (the nearest-neighbor spacing) and `origin` come from `chordGridMetrics`,
which builds the grid in uniform (regular-hex) space, then **stretches it to
fill** the surface: an independent X/Y `scale` maps the grid's bounding box
onto the whole panel so the boundary hexes touch all four edges. The grid's
aspect rarely matches the panel's, so the cells end up slightly elongated.
The stretch is applied only at the draw boundary (`chordStretch`) and inverted
at the input boundary (`chordUnstretch`), so the soft-margin pitch math in
`chordPitchAt` still runs on exact regular hexes.

Each hexagon is drawn twice: a faint **outer** hex (the full Voronoi cell)
and an **inner** hex inset by the margin — both **pointy-top** — stroked in
the cell's pitch hue (`pitchColor(forRatio:)` — hue by pitch class, so every
octave of a note shares a hue) with the note name centered inside. A cell's
inner hexagon **fills** with its hue while sounding (cross-fading by the same
weights that drive the pitch in a soft margin — `CellFillsView`).

## Playing

- **Click a hex** → play its note.
- **Drag** → glide/bend between chord tones; inside an inner hex the exact
  pitch sounds, in the strip between two inner hexes the pitch is a
  log-frequency blend (a bend), at a triple junction three cells blend.
  Identical to the Pitch Pad's soft-margin behavior.
- **Margin** (toolbar, 0…64 px) is the half-width of the soft glide zone;
  0 = hard hex edges (exact cell pitches only). **Velocity** applies to
  every Note On. **Panic** clears all touches.

The surface is mouse-driven (one touch at a time). Per-tick glide updates
touch only `SoundingState`, so only the fills overlay and the Hz readout
re-render — the static hex grid and toolbar stay put (the same isolation
the Pitch Pad uses).

## On the iPad

The iPad performs the Chord Pad when the Mac selects it. Switching the Mac
to the **Chord Pad** tab (or **Pitch Pad** tab) sets `AppController.ipadLayout`
(`PadLayout`) — `MacMainWindow.selectTab` does this for both the segmented
picker and the ⌘-number shortcuts — which rides the synced `SyncedScaleState`
over USB-MIDI SysEx alongside the scale, tonic, and margin (see
[MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)). Other
Mac tabs leave the iPad on whatever pad it last showed.
The iPad's `ContentView` observes `pad.layout` and swaps between
`PitchPadViewIOS` and `ChordPadViewIOS`; `applySyncedState` panics any held
notes on a layout change. The synced `marginPixels` is the **active**
surface's margin — the Mac pushes `chordPad.marginPixels` while the Chord
Pad layout is selected and `pitchPad.marginPixels` while the Pitch Pad is —
so each pad's own Margin slider drives the iPad. The iPad surface
(`ChordPadViewIOS` in
`Starpad/Starpad/PitchPadView_iOS.swift`) is **multitouch** (one MPE channel
per finger — ideal for chords), perform-only, and shares the same engine,
synced scale/tonic, and tilt expression as the Pitch Pad. The iPad can't
pick its own layout; the Mac drives it.

## Temperament

12-TET only for now (`Temperament.equalTemperament`); the toolbar's tuning
picker is disabled. The `Temperament` enum is the reserved seam for a
future **just-intonation** mode where each column's chord uses perfect
intervals stacked from its root.

## MIDI signal path

Identical to the Pitch Pad's — see
[Pitch Pad — MIDI signal path](pitch-pad.md#midi-signal-path). The
`chordPad` engine uses `init(audio:)`, so its `MIDIEngine` does **not**
publish to CoreMIDI; MPE bytes are delivered in-process to the hosted AU
(`AudioEngine.sendHostedMIDI`). It coexists with the Pitch Pad and a
plugged-in iPad. Both Mac engines and the iPad share the same 48-semitone
bend range (`Config.midiPitchBendRange`). The two Mac engines round-robin
the same 15 MPE channels, so play one pad at a time.
