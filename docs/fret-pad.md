# Fret Pad

The **Fret Pad** is the **sole playing surface** (Mac tab ⌘4 + the iPad's
only surface). Each enabled scale degree appears as one or more vertical
**line segments (frets)** that are **freely positioned** — since the
2026-07-23 free-fret change a fret's `x` (0..1 across the base band) is its
own layout state, **unrelated to its pitch**. The playable pitch is a
continuous **field** interpolated from the frets:

- A **column** = the frets sharing an x position (within `fretColumnEps`
  ≈ 0.5 px) — e.g. the default layout's R-over-r pair. A column's pitch at
  the touch's y (`fretColumnLog`): **inside** a member fret's vertical
  extent → exactly that fret's pitch; **between** two stacked frets → a
  linear y-interpolation across the gap (between r and R you get their
  blend); **above/below** all of them → clamped to the nearest one.
- The field at the touch = the **linear log-pitch x-interpolation between
  the two closest columns horizontally** — the nearest at-or-left and the
  nearest right of the touch (`fretFieldLog`). Beyond the outermost columns
  the line through the outermost **pair extrapolates**, so the edges keep
  the local slope instead of going flat (a single-column layout holds its
  pitch everywhere).

So dragging right of S plays S at S's line, the r/R column's y-resolved
pitch at that line, and the straight log-pitch line between them in the gap
— pitch always moves toward the neighbor you're dragging at. Continuous
everywhere: both sides of a column agree on the column's own pitch, and the
y-resolution is continuous in y. (Earlier revisions used global
inverse-distance blends over every fret — the far tail collectively
outweighed the nearest fret and dragged gaps toward the layout's mean pitch,
audible as pitch bending the wrong way beside an edge fret. Two-column
interpolation removes the whole failure class.)

There are no discontinuities anywhere: onset snapping only ever adds a
constant offset, drags follow the continuous field, and the drag assist and
tap legato are slew-limited/additive on top.

## Playing model — onset-only snapping

- **Start a touch within the Snap distance (px) of a fret AND inside its
  vertical extent** → the note snaps to that fret's exact pitch. If more than
  one qualifies, the nearest (in x) wins.
- **Start elsewhere** (above/below a fret's extent, or in open space) → no
  snap; the note plays the **field** pitch. This is the approach path: begin
  slightly off beside/between frets and slide into the note.
- **Drags never re-snap.** After onset the pitch follows the field at the
  cursor continuously, offset by the constant `log2` delta captured at a
  snapped onset (`snapOffsetLog`), so a snapped note is exact at the onset
  point and vibrato/meend move relative to it with no discontinuity. The
  offset is bounded by the snap distance and clears on note-off.
- **Snap = 0** disables snapping entirely (pure field playing).

The Snap slider is backed by `engine.marginPixels` (0–64 px), the same
repurposing trick the String Pad used for its Sharpness slider. The Fret
Pad's default is **24 px** (set in `AppController.init`, not the engine's
shared 16) — fitted to real iPad onsets: in the 2026-07-16 phrase recording
the worst onset was 14.9 px off, so 16 left zero headroom; 24 keeps ~60%
headroom while staying under the default layout's fret gap.

## Drag assist (magnetic inflections)

Onset snap handles note starts; **`FretDragAssist`**
(`Packages/StarpadCore/Sources/StarpadCore/FretDragAssist.swift`) handles the
rest of the stroke. Musical premise: when the player **stops or changes
direction** near a scale pitch, that inflection was intended to be *on* the
pitch; while moving quickly they're gliding and must be left alone.

It's a **gated magnetic correction**, continuous by construction. Each touch
carries one slew-filtered `correction` (log2 units);
`played = field + onsetOffset + correction`, and the correction eases toward
the nearest qualifying fret at a rate = **gate × proximity × settle**:

- **gate = min(1, max(stationarity, turnGain·impulse))** — stationarity is
  smoothed |dx/dt| through a smoothstep (fitted: 1 below 59 px/s, 0 above
  375 px/s; τ 26 ms) and handles stops and slow turns. Fast connected
  playing turns in ~30 ms — no speed average can dip in time — so a
  causally-detected **direction flip** (deadbanded dx sign change, ~one
  event of latency) fires an impulse that holds the gate open while it
  decays (fitted: turnGain 2.0, turnTau 26 ms → gate pinned at 1 for ~18 ms
  then decaying).
- **proximity** — the fret must be within the **assist basin** =
  `radiusScale` × Snap (fitted 1.75× = 42 px at the 24 px default Snap —
  fast landings are far sloppier than onsets; the onset snap stays at 1×),
  measured in **screen px** as distance to the fret line's x (frets are
  freely positioned, so screen distance is the natural metric, matching the
  onset snap), and its vertical extent must contain the touch: above/below a
  segment stays free, Snap = 0 disables assist. Pull is full inside half the
  radius, fading to 0 at the edge (continuous in space).
- **settle** — fitted τ 5 ms, but the rate that actually governs is the hard
  **slew cap ≈ 1500 ¢/s** on the correction (inside natural meend speeds):
  **smoothness is guaranteed by construction**, whatever the constants.

When **no fret qualifies the correction freezes** (never decays): a
deliberate microtonal hold doesn't drift, and each assisted landing becomes
the new tuning anchor — a relative frame exactly like the onset offset,
bounded by the snap radius, re-anchored at the next inflection. Because the
output is always the slewed state, no event (candidate switch, zone
entry/exit, speed spike) can produce a pitch discontinuity.

Since stops emit **no move events**, a ~60 Hz timer runs while touches are
down (both surfaces), feeding `tick(time:)` → `engine.glide`; move events
feed `move(...)`. The assisting fret glows with the gate (brightening as the
magnet engages). Fully per-touch on the iPad.

## Tap legato (fast phrases)

For very fast phrases, dragging one finger doesn't work — the natural gesture
is **tapping** the notes. With **Legato** on (toolbar toggle, default on,
carried on `FretArrangement.legato` → store doc / SysEx blob flags byte),
consecutive taps become **one continuous voice** (`FretLegato`, StarpadCore):

- A tap that lands while the previous note is still sounding — held, or
  within the **release grace window** (~120 ms; fast taps overlap or leave
  tiny gaps) — takes the voice over instead of retriggering:
  `PitchPadEngine.transferTouch` moves ownership with **no MIDI events**, so
  the held note keeps sounding on its channel and the new touch bends it —
  true legato for the String voice (one articulation, bends only).
- The pitch **glides** from the previous note to the new tap's onset-snapped
  pitch over ~50 ms (smoothstepped). The glide is an additive offset that
  starts at exactly the old pitch and decays to zero, so it composes with the
  drag assist and cannot produce a discontinuity.
- Releases of the voice owner are deferred by the grace window (notes ring
  ≤120 ms past the finger — inaudible under a bowed release); the surface's
  60 Hz timer sends the real note-off if no tap follows, and keeps running
  while a release is pending.
- Legato mode is **mono, last-note priority**: a new tap steals the voice and
  the older finger goes inert (its note-off no-ops after the transfer). Turn
  Legato off for the polyphonic per-touch behavior.

Combined with the 24 px onset snap, a fast tapped run comes out as snapped
scale pitches connected by short glides — a played phrase, not retriggers.
(Note: tap-legato sessions will show parity drift in `fretpad_fit.py report`
— the fitter's replica models the drag assist only, not the takeover ramps.)

### Fitting the assist to real playing

The four constants can be **fitted to recorded movements** instead of tuned
by hand:

1. Toggle **Rec** (Mac Fret Pad toolbar) or **REC** (iPad Fret Pad toolbar)
   and play naturally — glides into stops, direction changes near notes,
   vibrato, fast runs, approaches. Each play stroke is appended to a JSONL
   session file (`FretGestureRecorder`, StarpadCore; record **v2** since the
   free-fret change): raw events `[t, x, y, u, o, tick]` (`u` = uncorrected
   log2 pitch — field + onset offset — the assist's input; `o` = the pitch
   actually played) plus a context snapshot (fret pixel x + pitches +
   extents, Snap, band extent, the live assist params). Files land in
   `~/Library/Application Support/Starpad/FretRecordings/` on the Mac; on the
   **iPad** in the app's `Documents/FretRecordings/` — user-visible
   (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`), so copy
   them to the Mac via Finder's device browser (iPad → Files → Starpad) or
   the Files app / AirDrop. **The iPad fit is the one that matters** — finger
   dynamics on glass differ from mouse strokes; fit each surface from its own
   recordings.
2. `python3 tools/fretpad_fit.py report <files>` — stroke stats and a
   **parity check**: the script's causal Python replica replayed under the
   recorded params vs the recorded `o`. Only trust fits when parity is tight.
3. `python3 tools/fretpad_fit.py fit <files>` — labels intent with
   **hindsight** (true dwells ≥ 90 ms and velocity reversals, each labeled
   with the nearest in-zone fret), then grid + coordinate-descent fits the
   causal constants to minimize: dwell-end error + 15·settle-lag +
   0.7·reversal error + 2·transit transparency (all in cents/seconds).
   Prints values to bake into `FretDragAssist.swift`.

**Protocol mode** (`--phrase "p n d n p d m p g"`): when the recording
repeats a KNOWN phrase, pass it — detected inflections are aligned to the
svara sequence by monotonic DP (skip penalties; case-insensitive letters
constrain pitch class, komal/shuddha variants and octaves resolved by
nearest; auto-tiled for multi-repetition strokes). Order + svara identity
correct labels that nearest-fret would pin to a sloppy landing's wrong
neighbor — strictly better ground truth for a scripted session.

`fretpad_fit.py selftest` validates the pipeline on synthetic strokes,
including a connected 9-note phrase through the aligner. The hindsight
thresholds define "truth" and are deliberately not fitted.

**Fit provenance (2026-07-16, iPad):** 8 repetitions of the connected phrase
*p n d n p d m p g* (~145 ms/note), pulled off the device with
`xcrun devicectl device copy from … --domain-type appDataContainer`. Findings
baked into the current constants: raw landings were 29¢ mean / 62¢ p90 off
(overshooting past the note 45/64 times), half beyond the old 1× radius —
hence `radiusScale`; the speed gate never opened at this tempo — hence the
flip impulse; scoring is perceptual (error weighted by inverse *output*-pitch
velocity around each turn; transparency = per-segment std of the correction,
excluding a 120 ms post-turn guard). Result: landing error 39.7¢ → 29.3¢,
transit warping ≈ 2¢. Caveats: the recording covers fast connected playing
only — slow-glide/vibrato feel is extrapolated (the high fitted
`speedCeiling` makes slow glides sticky near frets) — **and it was made on
the old pitch-mapped ribbon** (the assist basin was ≈75¢ in log-pitch; it's
now the same 42 px in screen space). Old (v1) recordings still load — the
fitter derives fret x from the old mapping — but record fresh sessions on
the free-fret surface and refit.

## Layout

The editable **base** frets live in a central **band**; the surface extends
`ghostExtentOctaves` band-widths (fractional; default **0.5**; 0–2 in 0.25
steps, toolbar "Octave ±") past the base band on each side, tiled with
read-only **octave-repeat ghost copies of the whole base layout** — the left
flank plays an octave down, the right an octave up — clipped to the visible
range, sharing each base fret's x-within-band and vertical extent, drawn
faint in edit mode. The surface spans `1 + 2·extent` band-widths; a fret's
pixel x is `(x + shift + extent) / span · width` (`fretPixelX(forBandX:)`).

The **default arrangement** (`FretArrangement.defaultArrangement`, "Reset to
Scale") mirrors the (now removed) String Pad: **7 evenly-spaced columns**,
one per svara — `x = (col + 0.5)/7` for columns S · R/r · G/g · m/M · P ·
D/d · N/n — with the vertical svara split:

- **S and P** (pc 0, 7): centered segments (y 0.39–0.61)
- **shuddha** degrees (pc 2 4 5 9 11 → R G m D N): lower middle
  (y 0.565–0.755, center 0.66)
- **komal/tivra** (pc 1 3 6 8 10 → r g M d n): upper middle
  (y 0.245–0.435, center 0.34)

(The off-center bands sit at the String Pad's paired-key centers 0.66 / 0.34,
leaving open approach space toward the pad edges. Segments are drawn thin,
1.5 px base / 1 px ghost, with a 2.5 px-half-width sounding glow — the same
thin rectangles are the field's resolver cells.)

A fret's pitch is a `degreeIndex` into the enabled Pitch Pad scale degrees,
looked up live (`fretRatio`), so re-tuning the scale re-tunes the pad (fret
positions stay put — they're free); a degree that disappears skips its fret
rather than deleting it. Names are sargam (`sargamName(forRatio:)`, `'`/`,`
octave marks on ghosts).

## Editing

Edit mode (the default; **Perform** toggles it off and hides the band
gridlines, labels, and endpoint handles, styling ghosts like base frets):

- **drag an endpoint handle** — set that end of the fret's vertical extent
  (its snap zone); minimum height 0.02
- **drag the line** — move the whole segment **in any direction** (height
  preserved; x clamped to the base band)
- **shift-click empty space** — add a fret at the click position, on the
  degree whose pitch is nearest the field pitch there (circular within the
  octave), 0.15 tall, centered on the click y — multiple segments per degree
  are allowed (separate positions/snap zones)
- **right-click** — delete
- **drag empty space** — play (audible while arranging; grabbing a fret also
  sounds its exact pitch)

## What it reuses

- A `PitchPadEngine` (`AppController.fretPad`) is the MPE emitter
  (in-process `init(audio:)`, tonic kept in step with `pitchPad` by the
  `start()` sink, `macExpressionLevel` set at startup).
- `pitchColor`, `SoundingState`, and `CellFillsView` — each fret is wrapped as
  a thin-rectangle `VoronoiCell` (`fretFillCells`) so the snapped fret glows;
  during a glide the assist's candidate fret glows with gate-shaped weight
  (display only — pitch never re-snaps).
- The sargam helpers and the mouse-capture / readout patterns from the
  String-Pad era.

## Drone buttons (2026-07-23)

Four **press-to-sound drone buttons** sit along the surface's right edge,
from the top to the vertical center (the lower half stays open), on **both**
the Mac tab and the iPad surface — the free hand plays them while the other
plays melody. The buttons live **inside the playing surface** (`droneButtonRects`
in StarpadCore — one shared rect function for both platforms' visuals and
hit-tests): a touch/click is claimed as a drone press only when its **onset**
lands inside one of the 4 rectangles, hit-tested in the surface's own touch
handler (`began` on iPad, `handleDown` on Mac) — never via SwiftUI gestures.
Everything around and **below** the buttons plays normally, and melody drags
that wander across a button keep gliding. (The first layout put the buttons
in a separate side column — that made the whole right edge dead space and
swallowed touches aimed at the rightmost fret.) While pressed, a **String-voice jawari-taraf string** sings.
The excitation is entirely a **slewed band-passed-noise drive** (no impulse
anywhere): the drive envelope swells over the attack time toward
`level + onset boost`, the boost decays over ~200 ms so the onset relaxes
into the sustain, and release drops the drive so the row rings out on its
own t60. The noise is band-passed **~25 Hz–2 kHz in the kernel** — sub-audio
drive content would push the string quasi-statically against the jawari bone
and pump the buzz (an audible slow tremolo; the 2026-07-23 fix). Other base
the String voice's jt web carries them.

- **Pitches**: `FretArrangement.droneRatios` — 4 ratios, default
  **,Sa · ,Ma · ,Pa · Sa** (1/2, 2/3, 3/4, 1 — an octave below the tonic
  octave), edited from the Mac toolbar's **Drones** menu (chromatic JI
  svaras across the lower + base octaves, plus S′). The ratios are relative
  to the **PLAYED tonic** (`pitchPad.tonicMidi` — pushed by `AppController`
  as `AudioEngine.setDroneConfig(ratios:tonicHz:)`), NOT the tarab/sarangi
  tonic: the drones must harmonize with the melody, which is tuned
  independently of the fitted string table. **Every configured pitch is
  guaranteed a jawari row at engine build** (`buildEngine(droneHz:)`): a jt
  row **rings ~15.5 ¢ sharp of its nominal table frequency** (the grazing
  jawari bone stiffens the termination — measured +13.5…+19 ¢ across rows,
  `bow_drone_comp_cents`), so the target nominal is the request compensated
  down by that shift; an existing row within ±6 ¢ of the target is reused
  (true unison — the fitted table's strings keep priority), otherwise a
  dedicated jawari string is appended at the target (median gain/t60).
  Presses map through the same compensation
  (`BowEngine.droneRow(forRequestedHz:)`, pitch-class first). Verified
  2026-07-23: all four drones sound within ~±4 ¢ of the requested pitches.
  A ratio or tonic change triggers a (debounced) String-engine rebuild.
  (First-revision stored/synced Sa·Ma·Pa·Sa′ defaults migrate to the
  lowered default on read.)
- **Signal path**: on press/release both surfaces call
  `PitchPadEngine.setDrone(_:pressed:)`, which emits **CC 102–105 on
  channel 0** (value 127/0). Multi-finger safe on iPad: a second finger on
  a held button is refcounted, and the release fires when the last one
  lifts. The Mac pad
  delivers it in-process; the iPad sends it over USB like every other
  message. `AudioEngine.sendHostedMIDI` **intercepts** those CCs (never
  forwarded to the mapper) → `setDronePressed` → `BowEngine.
  dronePress/droneRelease` → the kernel's `bow_poly_jt_pluck` (sets the
  decaying onset boost) / `bow_poly_jt_drone` (sets the hold level) /
  `bow_poly_jt_drone_env` (attack/release/boost-decay times, pushed at
  engine build). Per-row control-scalar writes; the excitation is applied
  inside `jt_tick_string`, so serial/pool/async paths all get it and the
  unused path stays byte-null. Held drones are re-armed after a structural
  rebuild (`reapplyHeldDrones`); a release skips rows another held button
  still maps to.
- **Levels & envelope** (`bow_drone_level` 0.08 · `bow_drone_onset` 0.3 ·
  `bow_drone_attack_ms` 40 · `bow_drone_release_ms` 60 ·
  `bow_drone_onset_decay_ms` 200 — read from bp in `BowEngine.init`,
  overridable via the audition `string.<key>` path): calibrated single-
  instance against a tapped fret note at CC11 32 — **a drone tap matches
  the note tap's taraf response** (both peak ≈ 0.022 RMS with the same
  ~2.5 s ring contour; "the fret tap minus the main voice"), and a hold
  sustains at ≈ 0.012 RMS, sitting under the melody. **Calibrate with ONE
  app instance running** — a second instance doubles the audio (+6 dB,
  chorus wobble) and its competing jt pools cause steady flat-fill
  overload logs. Audition hooks: `voiceParam` names `drone1`–`drone4`
  (value > 0.5 = press).

## On the iPad

The Fret Pad **runs on the iPad** — StarpadMac edits, Starpad performs. The
Mac pushes `AppController.ipadLayout = .fretPad` with the synced state, and
the iPad shows `FretPadViewIOS` (in `Starpad/Starpad/PitchPadView_iOS.swift`).

The segment layout is **its own state** (fret positions and snap zones aren't
derivable from the scale), so it's pushed as a **third SysEx message**
(`F0 7D 03 …`, `FretArrangementSysEx`, blob **v5**
`[ver][ghostQuarterOctaves][flags][count]` then
`[degreeIndex][x14: 2×7-bit][topY][bottomY][enabled]` per segment, then the
4 drone ratios as 14-bit cents-above-−1200 — x quantized to 14 bits, y to 7;
flags bit0 = legato) alongside the scale
message, sent whenever the arrangement changes while the Fret Pad is the
active layout. Pre-v5 blobs / pre-v4 stored docs are
rejected and fall back to the default. `ScaleSyncReceiver` decodes it into
its `@Published fretArrangement` (persisted via `FretArrangementSyncStore`
for offline relaunch; if the iPad has never synced, `ContentView` falls back
to `FretArrangement.defaultArrangement` built from the synced scale so the
surface is playable, not blank). The synced `marginPixels` carries the Mac
Fret Pad's **Snap** distance while this layout is active.

The iPad surface is **always perform mode** (no gridlines, labels, or
handles; ghosts styled like base frets) and **fully multitouch** — each finger
gets its own onset snap decision and keeps its own constant `snapOffsetLog`
for the life of the touch, so simultaneous snapped and approach touches
coexist.

## Code map

- `Packages/StarpadCore/Sources/StarpadCore/FretPadGeometry.swift` — model
  (`FretSegment` = degreeIndex + free `x` + topY/bottomY + enabled;
  `FretArrangement` = segments + ghostExtentOctaves + legato +
  droneRatios), band↔pixel
  mapping (`fretPixelX(forBandX:)` / `fretBandX(atPixelX:)`), per-frame
  `fretPlacements`, the pitch field (`fretFieldLog` + `fretColumnLog` —
  two-column x-interpolation, y-resolved columns), onset `fretSnap`, edit
  hit-testing `fretGrab`, `fretFillCells`.
- `Packages/StarpadCore/Sources/StarpadCore/FretArrangementStore.swift` —
  `_Current.json` debounced autosave (atomic writes), ids minted on decode;
  doc **v4** (free x; pre-v4 rejected → default rebuilt; `droneRatios`
  optional — absent falls back to Sa·Ma·Pa·Sa′).
- `Packages/StarpadCore/Sources/StarpadCore/ScaleSync.swift` —
  `PadLayout.fretPad`, `FretArrangementSysEx` (subtype `0x03`, blob v5),
  `FretArrangementSyncStore`, and `ScaleSyncReceiver.fretArrangement`.
- `StarpadMac/Views/FretPadView.swift` — the Mac tab: toolbar (Panic / Scale
  menu / Reset / Octave ± / Legato / Perform / Drones / Rec / readout /
  Snap / Velocity / Prime / Tonic), Canvas surface, AppKit mouse capture,
  interactions, the drone button strip, and the scale list editor.
- `Starpad/Starpad/PitchPadView_iOS.swift` — `FretPadViewIOS` +
  `FretPadSurfaceIOS` (perform-only surface, per-touch snap offsets) +
  `DroneStripIOS` (the 4 drone buttons, right edge top→center).

Editing and Mac-side persistence stay Mac-only
(`FretArrangements/_Current.json` under Application Support); the iPad only
receives and performs.
