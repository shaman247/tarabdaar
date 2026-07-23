# String Pad

The **String Pad** is a third Mac-side playing surface (StarpadMac tab, ⌘9),
a box-plot / abacus. Where the [Pitch Pad](pitch-pad.md) lays one pitch per
Voronoi cell along a log-frequency x-axis and the [Chord Pad](chord-pad.md) is a
fixed hex grid, the String Pad is a row of discrete vertical **strings** (evenly
spaced columns) carrying stacked **notes** the user drags and resizes.

A **note** is a single **hexagon** — a rectangular middle (configurable
**centre-y** + **height**) with a **fixed-length tip** tapering to a point top
and bottom — plus a **name** and a **pitch**. The pitch is **constant throughout
the whole hexagon** (tips included); interpolation happens only in the empty
space *between* hexagons. A note belongs to a string by its `stringIndex`; its
pitch is a **scale degree** of the shared Pitch Pad scale (plus an octave),
looked up live, and its **name** is sargam, mapped from the pitch (see below).

**Strings repeat across octaves.** The arrangement holds `stringCount` editable
base strings (default 7 svaras) plus `ghostStringsPerSide` (default 4) read-only
**octave-repeat** strings on each side — copies continuing the ascending svara
sequence into the octave below (left) and above (right). So the centre shows the
base octave, the left flank the upper svaras of the octave below, the right flank
the lower svaras of the octave above (the faint side columns). Playing a ghost
sounds the octave-shifted pitch.

Behaviourally the notes are the Pitch Pad's inner polygons generalised — **fixed
pitch inside the hexagon, log-frequency interpolation between hexagons** —
blending in **2D** (across strings as well as vertically). Edited on the Mac; the
arrangement **syncs to the iPad** for play (see [On the iPad](#on-the-ipad)).

## What it reuses

- A **third `PitchPadEngine`** (`AppController.stringPad`, alongside `pitchPad`
  and `chordPad`) is the MPE emitter. The resolver hands it the played `ratio`
  and a per-shape weight map; the engine pins the nearest semitone and bends from
  there exactly as the other pads do. The engine's own `scale`/snap/`ScaleStore`
  features go unused on this instance.
- The shared OKLCH colours (`pitchColor`), `Path(closedPolygon:)`, the
  `SoundingState` observable, and `CellFillsView` are reused verbatim (each
  shape is wrapped as a `VoronoiCell` by `stringFillCells`, the same trick the
  Chord Pad uses).
- The tonic is read from `controller.pitchPad.tonicMidi` (kept in step by the
  same Combine sink that locks the Chord Pad's tonic).

The String Pad does **not** own a scale or tonic. Edit the scale on the Pitch
Pad tab and the String Pad re-renders to match; its tonic readout is read-only.

## Pitch and name (sargam)

`scaleDegrees(from:)` returns the scale's enabled degrees sorted low→high as
`(ratio, label)`. A note stores a `degreeIndex` into that list plus an `octave`
offset; the played ratio is `degrees[degreeIndex].ratio · 2^octave`, looked up
live (`noteRatio`). So re-tuning a scale degree retunes every note on it, and a
note whose degree no longer exists (the scale shrank) is simply skipped rather
than crashing.

The note's **name** is derived from its pitch (`noteName`): the ratio's nearest
chromatic semitone maps to **sargam** against the default Pitch Pad scale —

| pitch | S | r | R | g | G | m | M | P | d | D | n | N |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| degree | 1 | 2♭ | 2 | 3♭ | 3 | 4 | 4♯ | 5 | 6♭ | 6 | 7♭ | 7 |

with `'`/`,` suffixes for octaves up/down. The editor's note picker offers the
degrees by their sargam name, so you choose `r` rather than a ratio.

## The generic polygon resolver

The heart of the pad is `polyPitchAt` in
`Packages/StarpadCore/.../StringPadGeometry.swift` — **generic over arbitrary 2D
polygons** and **continuous everywhere** (no discontinuities, no dead zones):

- **Inside** a polygon → exactly that polygon's pitch (a flat fixed zone).
- **Anywhere outside** → an **inverse-distance blend** of the polygons by
  distance to each: `w_s = 1 / d_s^power` (normalised), played ratio
  `= 2 ^ Σ wₛ·log2(ratioₛ)`. Nearer polygons dominate; the influence falls off
  smoothly with distance and never cuts off, so the empty space between polygons
  interpolates continuously — there is no nearest-snap and no margin band.

As the cursor approaches a polygon, `d_s → 0` so `w_s → ∞` and the blend → that
polygon's pitch, matching the inside value — so the surface is continuous at
every boundary. The polygon a note contributes is its **whole hexagon** (the
rectangular middle *and* the tips), so the pitch is constant across the entire
hexagon and **resizing its height resizes the fixed-pitch region** — a
centre-point soft-Voronoi (like the Pitch Pad's `pitchAt` / Chord Pad's
`chordPitchAt`) cannot do that. This is layout-agnostic — the same resolver would
work for the chord hexes or any other arrangement.

The **Sharpness** slider (`engine.marginPixels`, 0–64 → `power` 1–8) controls
locality: higher locks pitch more sharply to the nearest note (→ Voronoi-like but
still continuous); lower blends more globally. Each note's tips are a **fixed
constant length** (`stringTipLength`) — they're part of the hexagon, not a
separate interpolation zone.

## Playing and editing

The surface is `StringPadView` (`StarpadMac/Views/StringPadView.swift`), layered
like the Pitch Pad: a static `Canvas` (gridlines + shape outlines + labels), the
dynamic `CellFillsView` (live fills, observing only `SoundingState` so a glide
re-renders nothing else), and an AppKit `StringPadMouseCapture` overlay for
full-resolution drags.

A **Perform** toggle (reusing `engine.performanceMode`) switches between two
modes:

**Edit mode** — editing is always on (no modifier):
- **Drag a note's body** = move it (centre-y, and snap to the nearest base
  string column).
- **Drag a note's top/bottom edge** = resize its height (the opposite edge stays
  put).
- **Drag empty space** = play (so you can hear while arranging). `polyPitchAt`
  resolves the press; dragging glides through whatever notes (and gaps) the
  cursor crosses.
- **Shift-click empty space** = add a note on the nearest base string,
  inheriting the nearest note's degree/octave/height.
- **Right-click a note** = delete it.

Editing only affects the **base** strings — the octave-repeat ghosts are
read-only (clicking one plays its octave-shifted pitch). The toolbar's **Octave
±** stepper sets `ghostStringsPerSide`.

**Perform mode** — a clean playing surface: editing is disabled, the vertical
gridlines and note labels are hidden, and the octave-repeat ghosts are styled
identically to the editable strings. Click / drag anywhere to play (a ghost
sounds the octave-shifted pitch).

The right-hand **editor** groups the notes **by string** — one card per editable
base string (shown even if empty), headed "String K" — with a colour chip
(enable/disable), the note's sargam name, a note picker (degrees by sargam name),
and an octave stepper per row. Drag a row's **grip handle** onto another string's
card to move the note (`stringIndex`). Each card can add a note or delete the
string; the header **+** adds a string. **Reset to Scale** rebuilds the default.

## Default arrangement

`StringArrangement.defaultArrangement` builds **7 base strings**, one per svara,
named in sargam. **String 1** carries a single tall key — **S**, centred at
y=0.5. Strings with a vikrit (altered) variant carry two tall keys — the
**shuddha/natural** in the **bottom** half and the **komal/tivra** in the **top**
half, pulled close to the middle (centre-y 0.66 / 0.34) so they nearly meet with
a small gap between them: string 2 = **R/r**, 3 = **G/g**, 4 = **m/M**, 6 = **D/d**,
7 = **N/n**; string 5 = **P** (single). Together these are the 12 chromatic
degrees of the default scale, with 4 octave-repeat ghost strings shown each side.

## Persistence

The arrangement (`StringArrangement` — `notes` (each `StringNote` is
`degreeIndex`, `octave`, `stringIndex`, `centerY`, `height`, `enabled`),
`stringCount`, `ghostStringsPerSide`) lives on `AppController.stringArrangement`
(`@Published`). A
debounced Combine sink auto-saves it to `_Current.json` via
`StringArrangementStore` (atomic writes, app-support dir, ids minted on decode —
the same convention as `ScaleStore`), so it survives tab switches and relaunch.
Named Save As / Load uses sibling files alongside the autosave. The
sympathetic-string pool is unaffected (it reads the Pitch Pad scale only).

## On the iPad

Like the Pitch Pad and Chord Pad, the String Pad **runs on the iPad** — StarpadMac
edits, Starpad performs. Selecting the Mac's **String Pad** tab sets
`AppController.ipadLayout = .stringPad` (a third `PadLayout` case), which rides the
synced state, and the iPad swaps to `StringPadViewIOS` (in
`Starpad/Starpad/PitchPadView_iOS.swift`) on `pad.layout == .stringPad`.

Unlike the Chord Pad — whose grid is derived entirely from the synced scale — the
String Pad's note layout is **its own state**, so it's pushed as a **second SysEx
message** (`F0 7D 02 …`, `StringArrangementSysEx`) alongside the scale message,
sent whenever the arrangement changes while the String Pad is the active layout.
`ScaleSyncReceiver` decodes it into its `@Published stringArrangement` (persisted
via `StringArrangementSyncStore` for offline relaunch); `ContentView` hands that
plus the synced scale/tonic/`marginPixels` (Sharpness) to the iPad surface. It uses
the same `PitchPadEngine` (real USB-MPE) and the shared `polyPitchAt` resolver, and
is **always in perform mode** — a clean playing surface: no gridlines or labels.
Editing stays on the Mac. There is **no top toolbar**: the surface fills the whole
screen and the controls (PANIC, MAP, recalibrate, sync indicator, tilt bars, the
live pitch readout, tonic) sit in a compact cluster in the **bottom-left corner**
(`StringPadControlsIOS`), which the rotated layout leaves empty. The surface
mirrors the Mac layout, rotated (see below).

### Rotation (iPad only)

The iPad **mirrors the Mac layout** — the *same* shared `stringPlacements`
geometry (identical note heights, the band layout, octave-repeat ghost strings),
so the two correspond — **rotated by a configurable angle**. Only the rotation
differs; the Mac editor always stays upright.

The angle is `StringArrangement.rotationDegrees` (**0–40°, default 30°**), set on
the Mac String Pad toolbar's **Rotation** slider. At **0°** the iPad is upright
(exactly the Mac axes); as it rises the strings lean toward the **top-right →
bottom-left** diagonal. This is **iPad-only** — the Mac surface ignores it. The
angle is part of the arrangement, so it auto-saves (`StringArrangementStore`, doc
version 3) and syncs to the iPad on the same second SysEx message
(`StringArrangementSysEx`, blob version 2).

`StringPadSurfaceIOS.diagonalFillCells` (`PitchPadView_iOS.swift`) calls the shared
`stringPlacements` to lay the **upright** layout out in a logical box, then rotates
every hexagon polygon about the box centre onto the screen centre — all **directly
in screen space**, so there is no `rotationEffect` and touches resolve in the same
screen space (no inverse transform, no nested-UIView hit-testing concern). To make
the strings reach across the tilted surface it keeps the Mac's column density and
adds enough octave-repeat ghost strings to span the rotated width; the box height
stays the screen height so the hexagons keep their Mac sizes (they are **not**
stretched). `Canvas`/`CellFillsView` draw the rotated polygons (overscan clipped to
the screen), and `polyPitchAt` resolves touches against them — pitch constant
inside each hexagon, blending across the gaps, tuned by the synced **Sharpness**
(`marginPixels`).
