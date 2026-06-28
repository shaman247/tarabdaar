# Pitch Pad

The **Pitch Pad** is Starpad's 2D pitch-design and playing surface. The
user lays out a JI scale as points across one octave of x-space (the pad
shows half an octave more on each side, where the scale repeats), then
plays it by touching and dragging — the pad partitions itself into
Voronoi cells, one per pitch, so every position resolves to "the cell I'm
in" → "that pitch sounds."

It runs on **both devices**, sharing the same geometry and engine:

- **iPad** — the Pitch Pad is the instrument's full-screen playing surface
  (it replaced the piano keyboard), with multitouch and tilt expression.
  See [UI Layout — iPad](ui-layout.md#ipad). Perform-only: it has no scale
  editor — the scale is edited on the Mac and synced over USB-MIDI SysEx
  (see [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)).
- **Mac** — the Pitch Pad **tab** (⌘4) is the design surface, where mouse +
  keyboard modifiers add the full editing toolkit described below.

The sections below describe the full (Mac) feature set; the snap-drag /
shift-click / scroll-wheel editing gestures are Mac-only, but the layout,
octave repeats, soft-margin glide, colors, and MIDI path are identical on
both sides.

This page covers:

- [What the Pitch Pad is](#what-the-pitch-pad-is)
- [Layout & visuals](#layout--visuals)
- [Mouse interactions](#mouse-interactions)
- [Snap system](#snap-system)
- [Inner & outer polygons](#inner--outer-polygons)
- [Sidebar editor](#sidebar-editor)
- [Enabling & disabling notes](#enabling--disabling-notes)
- [Saving & loading scales](#saving--loading-scales)
- [Toolbar controls](#toolbar-controls)
- [MIDI signal path](#midi-signal-path)

## What the Pitch Pad is

A surface for designing, auditioning, and playing JI scales. The shared
code lives in `StarpadCore` so both targets use one implementation:

- [`Packages/StarpadCore/.../PitchPadEngine.swift`](../Packages/StarpadCore/Sources/StarpadCore/PitchPadEngine.swift) — `PitchPoint`, `PitchScale`, the per-touch MPE engine, the iPad tilt-expression loop, and the snap-target / complexity / best-fraction helpers
- [`Packages/StarpadCore/.../PitchPadGeometry.swift`](../Packages/StarpadCore/Sources/StarpadCore/PitchPadGeometry.swift) — the platform-independent geometry: Voronoi solver + caches, soft-margin `pitchAt`, octave-ghost seeds, OKLCH colors, `CellFillsView`
- [`Packages/StarpadCore/.../ScaleStore.swift`](../Packages/StarpadCore/Sources/StarpadCore/ScaleStore.swift) — JSON save/load of scales
- [`StarpadMac/Views/PitchPadView.swift`](../StarpadMac/Views/PitchPadView.swift) — the Mac UI (toolbar, sidebar editor, AppKit mouse capture + snap gestures)
- [`Starpad/Starpad/PitchPadView_iOS.swift`](../Starpad/Starpad/PitchPadView_iOS.swift) — the iPad UI (full-screen surface, multitouch, toolbar; perform-only)
- [`Packages/StarpadCore/.../ScaleSync.swift`](../Packages/StarpadCore/Sources/StarpadCore/ScaleSync.swift) — `PitchScaleSysEx` (SysEx codec) + `ScaleSyncReceiver` (iPad), for Mac→iPad scale sync

**MIDI delivery differs by side.** On the Mac, the engine constructs its
`MIDIEngine` with `publishToCoreMIDI: false` and delivers MPE bytes
in-process to `AudioEngine.sendHostedMIDI(...)` (like the
[Simulator tab](simulator.md)) — so it coexists with a real iPad plugged
in over USB. On the iPad, the engine is handed the app's shared
`MIDIEngine` (`publishToCoreMIDI: true`) and emits real USB-MPE.

Switch to the tab with **⌘4** (Mac).

## Layout & visuals

The pad is a horizontal rectangle. **X** is log-frequency. The base
octave `[0, 1]` (1/1 … 2/1) occupies the middle of the width, and the
pad extends **half an octave past each end** (`log2 ∈ [-0.5, 1.5]`),
so the x-axis runs from a tritone below the tonic to a tritone above
the octave. The scale is still defined only over the base octave; the
flanking half-octaves show the scale's notes **repeated** an octave
down (left flank) and up (right flank) — see [Octave repeats](#octave-repeats).
**Y** is layout-only — it has no effect on the played pitch; it exists
purely to give each pitch a vertical position so handles don't pile on
top of each other.

Each pitch is a `PitchPoint(num, den, y)`. The scale spans the
half-open octave `[1, 2)` — 2/1 is **not** a member; the octave shows
up on the pad as the upper-octave repeat (ghost) of 1/1 at the right
boundary of the base region. The default scale is 12-tone just
intonation laid out like a piano keyboard:

- White-key pitch classes at y = 5/6 (lower part of the pad)
- Black-key pitch classes at y = 2/6 (upper part)
- 12 degrees, 1/1 … 15/8 (no explicit 2/1)
- Each degree carries a scale-degree label (`1`, `2-`, `2`, `3-`, `3`, `4`, `4+`, `5`, `6-`, `6`, `7-`, `7`)

The rectangle is partitioned into the Voronoi cells of those points.
Color comes from an OKLCH-derived hue mapped from
`log2(ratio) ∈ [0, 1] → 0..360°`, so the chromatic walk reads as a
smooth perceptually-uniform gradient and the octave wraps the hue
wheel. Only the inner polygons are drawn — each is outlined in its
pitch's bright hue, and the outer cells are implied by the gaps
between them. Nothing is filled at rest; an inner polygon fills with
its hue **while its pitch is sounding** (in a soft margin the
neighboring cells' fills cross-fade — see [Inner & outer polygons](#inner--outer-polygons)),
so the playing pitch is the splash of solid color on the pad.

Each base-octave pitch's control point is a disc filled with that
pitch's own hue, with its `label` (a freeform name set in the sidebar
— the default scale uses scale-degree names; falls back to the ratio
string when unset) centered inside. The disc is a draggable handle and
gets a white ring when hovered or dragged. **Octave-repeat ghosts get
no disc** — only their cells render, so the flanks stay playable but
visually quiet (no control point, no label). The base-octave fraction
(`num/den`) floats in a small capsule above the disc **only while that
control point is being clicked or dragged**.

## Octave repeats

The Voronoi seeds aren't just the base scale points — each base point
also spawns **ghost** repeats one octave down and up, and any ghost
whose position lands inside the extended `[-0.5, 1.5]` range becomes a
playable cell in a flanking half-octave. Mechanically (`DisplaySeed`
in `PitchPadView.swift`):

- A base point at log-x `f` spawns ghosts at `f − 1` and `f + 1`,
  carrying ratio `÷2` / `×2`.
- Ghosts outside `[-0.5, 1.5]` are dropped; a ghost that coincides
  (within ~5 cents) with an existing base point is dropped too, which
  avoids a degenerate duplicate seed at the octave boundary when a
  scale lists both 1/1 and 2/1.
- Ghost cells play their octave-shifted ratio (the engine's safety
  clamp is widened to `[2^-1, 2^2]` to allow it) and light up
  independently of their base cell, since each `DisplaySeed` has a
  stable id of the form `"<basePointID>#<octaveShift>"`.

Ghosts are **read-only**: their labels render dimmed and they get no
drag handle. Editing happens only on the base-octave handles and the
sidebar; because the ghost set is recomputed from the base points
every render, moving a base handle moves its ghosts with it. Adding a
pitch by shift-clicking inside a flank folds the click back into the
base octave (its pitch class) rather than creating an out-of-octave
point, and dragging a base handle is clamped to `[0, 1]` in log-x.

A live readout in the toolbar shows `<Hz> (<nearest 12-TET note name>
<±cents>)` for whatever ratio is currently sounding, tinted in the
active pitch's color. Frequencies are computed from `tonicMidi +
12 · log2(ratio)`, so the readout stays correct as either side is
retuned.

## Mouse interactions

| Gesture | Effect |
|---------|--------|
| Click in empty space | Begin sounding the cell's pitch (or a margin-interpolated pitch — see [Inner & outer polygons](#inner--outer-polygons)). |
| Drag in empty space | Glide between pitches as the cursor crosses cell boundaries. |
| Hover a handle | Cyan halo. |
| Click a handle | Begin dragging the handle (move the pitch). Also sounds the pitch so it can be fine-tuned by ear. |
| Right-click a disc | Disable that note (drops it from the scale; re-enable from the editor's Disabled section). See [Enabling & disabling notes](#enabling--disabling-notes). |
| Shift+click a handle | Pending remove. If released without dragging → remove the pitch. If dragged at all → reinterpreted as a snap-drag (next row). |
| Shift+click empty space | Add a pitch at the cursor (Stern-Brocot best-fraction approximation, denominator ≤ 256), then enter drag mode on the new pitch — keep shift held to snap it to a simple fraction. |
| Shift+drag a handle | **X-snap**. Vertical gridlines appear at "simple" snap targets (see [Snap system](#snap-system)). The handle locks to the nearest gridline whose drawn extent reaches the cursor's y; with no eligible gridline, dragging is free. |
| Cmd+drag a handle | **Y-snap + pitch lock**. Horizontal gridlines appear at the seven equally-spaced rungs (0, 1/6, …, 6/6). The handle's y locks to the nearest rung; the pitch (num/den) is held fixed. |
| Release | Stops sounding; the dragged handle commits in place. Row order in the sidebar is left as-is — hit **Sort** in the panel header to reorder by pitch. |

Modifier flags are re-evaluated every drag tick **and** at every
AppKit `flagsChanged` event, so tapping shift or command mid-drag
engages / disengages snap immediately. Command takes priority over
shift — while command is held, x-snap gridlines hide.

## Snap system

A "snap target" is a fraction the dragged handle can lock to.

The set for a given prime-limit cap is computed by:

1. Enumerating all `maxPrime`-smooth positive integers ≤ 8192 (every
   prime factor ≤ `maxPrime`)
2. Taking every coprime pair (n, d) in that set with `1 ≤ n/d ≤ 2`
3. Collapsing within-10-cent neighborhoods to the simplest fraction,
   where "simplest" = lowest `complexity(num, den)` and
   `complexity = Ω(n) + Ω(d) + largestPrime(n) + largestPrime(d)`
4. Dropping 2/1 — the scale spans the half-open octave `[1, 2)`, so
   the octave isn't a snappable degree (`snapTargets()` filters it)

The set is memoized per `primeLimit` value and only recomputed when
the user moves the **Prime ≤** picker.

Gridline length scales with complexity:

```
heightFrac = max(0.15, 1.0 - (complexity - 2) * 0.05)
```

Each gridline is drawn as two equal-length strips — one from the top,
one from the bottom. At `heightFrac > 0.5` the strips overlap and the
line reads as continuous; below that the center stays open, so
complex ratios only catch the cursor near the pad's edges while 1/1
(lowest complexity, full height) is eligible everywhere.

The dragged pitch's **original fraction** is always a valid snap
target, even when the prime-limit filter would exclude it. Its
gridline takes the pitch's OKLCH hue and a thicker stroke, matching
the highlight on the gridline currently being snapped to.

## Inner & outer polygons

Each Voronoi cell has two boundaries:

- **Outer polygon** — the standard cell (region of pixels nearest to
  that seed)
- **Inner polygon** — the outer polygon inset by `marginPixels`
  (toolbar slider, default 16 px, range 0…64) along every
  per-neighbor bisector. Rect edges are **not** inset, so the inner
  polygon reaches the top, bottom, and left/right walls of the pad —
  the soft margin only exists between adjacent pitches, not at the
  boundary. At `marginPixels = 0` the inner polygon coincides with
  the outer one and the pad reverts to rigid Voronoi behavior.

What sounds at a cursor position is a weighted blend of the
surrounding cells, computed as a **soft Voronoi** (`pitchAt`):

- Inside an inner polygon → weight 1 on that one cell (its exact ratio).
- In a 2-cell margin strip (the quadrilateral between two inner
  polygons) → two non-zero weights, a linear blend that hits the
  geometric mean on the shared bisector.
- In a 3-cell triangle (the gap at a Voronoi triple junction) → three
  non-zero weights (⅓ each at the vertex itself).

The weights come from per-seed penetration past each cell's inner
edge. For seeds `s, s'`, the signed distance from the cursor to their
bisector (positive on `s`'s side) is

```
h(s, s') = (|cursor − s'|² − |cursor − s|²) / (2 · |s − s'|)
raw_s    = max(0, marginPixels + min_{s'} h(s, s'))
w_s      = raw_s / Σ raw            log2(played) = Σ w_s · log2(ratio_s)
```

`min_{s'} h(s, s')` is the cursor's distance to the *most-binding*
bisector of `s`. The cell owner's `raw ≥ marginPixels > 0`, so the
sum is always positive and the weights are continuous **everywhere** —
including across the interior bisectors of a triple-junction triangle,
where the previous "pick the single closest bisector" scheme jumped.
In the 2-cell strip this reduces exactly to the old linear
`(marginPixels ± h)/(2·marginPixels)` blend.

Performance. Gliding through a soft region changes the played pitch
and fill weights every mouse tick. The expensive trap is letting that
re-render the whole pad (toolbar sliders/pickers, all cell borders,
all 12 control discs) at that rate. It's avoided on several fronts:

- **Isolated observation.** The fast-changing ratio + fill weights
  live on a separate `SoundingState` observable (`engine.sounding`),
  not on `PitchPadEngine`. Only two tiny views observe it — the Hz
  readout and a `CellFillsView` overlay that draws *only* the fills.
  The static layer (octave boundaries, cell borders, snap gridlines),
  the control discs, and the toolbar observe the engine, which
  doesn't change during a glide, so none of them re-render.
- **No per-tick `@State` churn on the surface.** The drag handlers
  keep the last cursor point in a non-observed scratch object and
  guard the `snapping` / `snappingY` / weight writes behind equality
  checks, so a cell-glide writes no surface `@State` at all.
- **Memoized geometry.** `VoronoiCache` and `SeedsCache` key the cell
  solve and the seed list on the scale + size + margin, so when those
  views *do* re-render the cells/seeds are reused, not recomputed.
- **Idempotent glide.** `PitchPadEngine.glide` early-returns when the
  ratio is unchanged (cursor moving within one inner polygon), so it
  neither resends the bend nor touches `SoundingState` there.

Net: inside an inner polygon, motion does nothing; in a soft region,
each tick re-renders only the fills overlay (drawing the ≤3 weighted
cells) and the readout.

The inner polygon's edge is always drawn tinted with its pitch's
sounding (highlight) hue, so the "exact pitch" zone reads at a glance.
Its interior fills with that same hue at opacity `w_s` — the fills
**cross-fade by the same weights that drive the pitch**, so a single
cell is solid inside an inner polygon, two share the fill across a
margin strip, and three share it inside a triple-junction triangle.

## Sidebar editor

The right-hand panel lists each pitch. Rows stay in insertion / edit
order; the **Sort** button (↕) in the header re-orders them by pitch
(low → high) on demand. New pitches added via shift-click or `+`
land at the end of the list. The columns are:

| Field | Notes |
|-------|-------|
| Color chip | OKLCH dot at the pitch's hue; also the enable / disable toggle — solid when enabled, a hollow hue ring when disabled. See [Enabling & disabling notes](#enabling--disabling-notes). |
| `label` | Text field. A freeform name shown on the pad cell (e.g. the default scale's scale-degree labels `1`, `2-`, `2`, …). Leave it empty to fall back to the ratio string. |
| `num/den` | Text field. Accepts `n/d`, or a decimal (auto-fitted via continued-fraction best approximation, denominator cap 256). A value outside the half-open octave `[1, 2)` is folded into it by ×/÷ 2 (e.g. `3/1` → `3/2`, `1/4` → `1/1`) and reduced; in-range input is kept exactly as typed. |
| `y` (user-y) | Text field. User-facing y is `[-3, 3]` with 0 at center (one unit per command-snap rung). Stored internally as `[0, 1]` with 0 at top. |
| `×` | Remove the pitch entirely. |

The `num/den` and `y` fields support **scroll wheel** (the `label`
field is freeform text and ignores scroll):

- Scroll over `num/den` → walk to the next / previous snap-target
  fraction (deduped at 10 cents, filtered by prime limit)
- Scroll over `y` → ±0.2 user-y units per detent (clamped to ±3)

Scroll deltas accumulate so a trackpad's many small events still emit
one step per "click worth" of motion (`threshold = 1.0` matches a
typical mouse-wheel detent).

The `+` button in the panel header adds a pitch at the **largest x-gap**
in the current scale (appended to the end of the row list).

### Enabling & disabling notes

Clicking a row's color chip toggles the note in/out of the **active
scale** without deleting it (solid chip = enabled, hollow ring =
disabled); right-clicking a disc on the pad disables it directly. A
disabled note (`PitchPoint.enabled == false`)
contributes no cell, disc, ghost, or sound on the pad — it's simply
skipped when the seeds are built — but it stays in the scale array and
moves to a dimmed **Disabled** section at the bottom of the panel,
where its toggle adds it straight back. The header count (`Scale (N)`)
and the `+` button's gap search both reflect only enabled notes.

This makes a larger vocabulary the source for smaller scales: lay out,
say, all 12 just-intonation degrees once, then disable five of them to
get a 7-note scale, and re-enable / swap to reshape it instantly
without re-entering ratios. `×` still deletes a note for good.

## Saving & loading scales

Scales persist as JSON, handled by
[`StarpadMac/ScaleStore.swift`](../StarpadMac/ScaleStore.swift):

- **Default scale.** The 12-TET JI layout ships as a read-only
  `Default.json` bundled in the app. `PitchPadEngine.scale` is seeded
  from it at launch via `ScaleStore.loadDefault()`, so the opening
  scale is loaded from disk rather than hard-coded. If the bundled
  resource is missing/unreadable, the loader falls back to the in-code
  `PitchScale.defaultJI` — that constant is now a fallback only.
  **Reset to Default** in the Scale menu reloads it.
- **User scales** live in
  `~/Library/Application Support/Starpad/Scales/<name>.json`. **Save
  As…** prompts for a name and writes one; **Save "name"** overwrites
  the loaded scale in place. Writes are atomic (`*.json.tmp` → move),
  matching the audition-runner convention so a reader never sees a
  half-written file. `Default` is a reserved name the Save dialog
  rejects, so a user file can't shadow the bundled default.
- **On-disk format** is a versioned `ScaleDocument` — `{ "version": 1,
  "points": [...] }`. Each point carries `num`, `den`, `y`, `label`,
  `enabled`. The point's `id` is **not** persisted (it's per-process
  identity for SwiftUI diffing / gesture targeting); a fresh `id` is
  minted on decode, so loading a scale never collides ids with what
  was on the pad before.
- **Loading** stops any sounding touches first (`panic()`) — the old
  scale's cells are about to vanish — then swaps `engine.scale` and
  records the loaded name. Deleting the loaded scale leaves the
  working scale in place but clears its name (it becomes unsaved).

This is Mac-only persistence with no iPad coupling, like presets and
audition scores — scale files live entirely on this side.

## Toolbar controls

| Control | Effect |
|---------|--------|
| Panic | All-notes-off on every channel; clear all touch state. |
| **Scale** | Menu for [saving & loading scales](#saving--loading-scales). Shows the loaded scale's name (or "Scale" when on the default / an unsaved working scale). Holds **Save As…**, **Save "name"** (only when a named scale is loaded), **Reset to Default**, a **Scales** submenu of common presets (modes, major/minor, pentatonics — `ScalePreset`, shared with the [Chord Pad](chord-pad.md)), a **Load** section listing every saved scale (a checkmark marks the loaded one), and a **Delete** submenu. |
| **Prime ≤** | Prime-limit picker for snap targets. 2 = octaves only; 5 = classical 5-limit JI; 7 brings in septimal ratios (7/4, 7/5, 7/6); 11+ enters xenharmonic territory. Changing this invalidates the snap-targets cache. |
| **Perform** | Performance-mode toggle. Hides the per-pitch control discs and the 1/1 / 2/1 octave boundary lines, leaving the cell outlines, the black field, and the live sounding fills — a cleaner playing surface once a scale is dialed in. Editing gestures (drag a handle, shift-click to add/remove, snap-drag) still work; they just have no visible handles to aim at. |
| Sounding readout | Live `<Hz> (<note> <cents>)` for the active touch, tinted in the pitch's hue. The capsule reserves its height even when silent to avoid nudging the pad on toggle. |
| Margin | Half-width of the soft interpolation zone between cells, in pixels (0…64). 0 = rigid Voronoi (no interpolation, exact cell ratios only). See [Inner & outer polygons](#inner--outer-polygons). |
| Velocity | 1…127. Applied to every Note On the pad emits. |
| Tonic MIDI | The MIDI note that corresponds to 1/1. Default D4 (62); range 24…96. |

## MIDI signal path

`PitchPadEngine` is a per-touch MPE allocator that owns no synthesis
— it just emits MPE bytes that route to whatever hosted AU is loaded.

For each new touch:

1. Allocate the next round-robin MPE member channel (1…15). If all
   are busy, reuse the oldest with a Note Off first.
2. On first use of a channel, send the RPN sequence configuring the
   bend range to `Config.midiPitchBendRange` (currently **48
   semitones**). Cached per channel after that — the iPad shares the
   same channel pool and re-asserts the same value on every Note On,
   so nothing else can drift this number out from under us.
3. Send CC 121 (Reset All Controllers) on the channel — clears any
   residual bend left on the AU's internal channel state from a
   prior touch that reused this channel number.
4. Pin a MIDI note number at the **closest semitone** to the starting
   ratio (so SWAM picks the right register for its body model on
   the initial attack), Note On at the toolbar's velocity, then send
   the initial pitch bend for the fractional residue.
5. From then on, `glide(touchId:ratio:)` only updates the pitch bend
   on that channel. The held note number stays fixed for the touch's
   lifetime, so SWAM doesn't re-articulate as the cursor crosses
   cell boundaries.

The 48-semitone bend range is what lets a touch starting at 1/1 glide
to 2/1 (a full octave) without retriggering. PitchPad's bend math
**must** use the same range value as the iPad — if they disagree, the
side acting second silently misinterprets the other's range and bends
rendered for the smaller range play at the wider one's scale (or
vice-versa). That's why `bendRangeSemis` reads from
`Config.midiPitchBendRange` rather than a local constant.

Ordering matters at note-on: the Mac `AudioEngine` only routes a
channel to a hosted-AU slot when it sees a Note On, so pitch bend on
an un-slotted channel is silently dropped. Note On comes before the
initial bend; CC 121 comes before Note On so a reused channel starts
clean.

MIDI bytes are delivered in-process: `MIDIEngine.onLocalEvent` →
`PitchPadEngine.deliver(bytes:)` →
`AudioEngine.sendHostedMIDI(status:data1:data2:)`. CoreMIDI is never
touched.
