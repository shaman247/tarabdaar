# Fret Pad

The **Fret Pad** is a fourth Mac-side playing surface (StarpadMac tab, after
String Pad — no ⌘ shortcut, use the picker). Where the
[String Pad](string-pad.md) spaces its strings evenly by index, the Fret Pad
puts every pitch **where it actually is**: each scale degree is a vertical
**line segment (fret)** whose **x-position is `log2(ratio)`** mapped linearly
across the surface — the same x-axis as the [Pitch Pad](pitch-pad.md). The
surface is a continuous fretless ribbon with visual frets on it.

## Playing model — onset-only snapping

- **Start a touch within the Snap distance (px) of a fret AND inside its
  vertical extent** → the note snaps to that fret's exact pitch. If more than
  one qualifies, the nearest (in x) wins.
- **Start above or below the fret's extent, or in open space** → no snap; the
  note plays the raw x-mapped pitch. This is the approach path: begin slightly
  flat/sharp beside a fret (outside its height) and slide into the note.
- **Drags never re-snap.** After onset the pitch follows the cursor x
  continuously, offset by the constant `log2` delta captured at a snapped onset
  (`snapOffsetLog`), so a snapped note is exact at the onset point and
  vibrato/meend move relative to it with no discontinuity. The offset is
  bounded by the snap distance and clears on note-off.
- **Snap = 0** disables snapping entirely (a pure fretless ribbon).

The Snap slider is backed by `engine.marginPixels` (0–64 px), the same
repurposing trick the String Pad uses for its Sharpness slider. The Fret
Pad's default is **24 px** (set in `AppController.init`, not the engine's
shared 16) — fitted to real iPad onsets: in the 2026-07-16 phrase recording
the worst onset was 14.9 px off, so 16 left zero headroom; 24 ≈ 43¢ keeps
~60% headroom while staying under the 40 px minimum fret gap.

## Drag assist (magnetic inflections)

Onset snap handles note starts; **`FretDragAssist`**
(`Packages/StarpadCore/Sources/StarpadCore/FretDragAssist.swift`) handles the
rest of the stroke. Musical premise: when the player **stops or changes
direction** near a scale pitch, that inflection was intended to be *on* the
pitch; while moving quickly they're gliding and must be left alone.

It's a **gated magnetic correction**, continuous by construction. Each touch
carries one slew-filtered `correction` (log2 units);
`played = raw + onsetOffset + correction`, and the correction eases toward
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
  `radiusScale` × Snap (fitted 1.75× ≈ 75¢ at the 24 px default Snap — fast
  landings are far sloppier than onsets; the onset snap stays at 1×),
  measured in
  log-pitch from the *uncorrected* pitch, and its vertical extent must
  contain the touch: above/below a segment stays free, Snap = 0 disables
  assist. Pull is full inside half the radius, fading to 0 at the edge
  (continuous in space).
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
carried on `FretArrangement.legato` → store doc v3 / SysEx blob v3 flags
byte), consecutive taps become **one continuous voice** (`FretLegato`,
StarpadCore):

- A tap that lands while the previous note is still sounding — held, or
  within the **release grace window** (~120 ms; fast taps overlap or leave
  tiny gaps) — takes the voice over instead of retriggering:
  `PitchPadEngine.transferTouch` moves ownership with **no MIDI events**, so
  the held note keeps sounding on its channel and the new touch bends it —
  true legato for SWAM / the sarangi model (one articulation, bends only).
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
   session file (`FretGestureRecorder`, StarpadCore): raw events
   `[t, x, y, u, o, tick]` (`u` = uncorrected log2 pitch incl. onset offset —
   the assist's input; `o` = the pitch actually played) plus a context
   snapshot (fret positions + extents, Snap, ribbon extent, the live assist
   params). Files land in
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
transit warping ≈ 2¢. Caveat: the recording covers fast connected playing
only — slow-glide/vibrato feel is extrapolated (the high fitted
`speedCeiling` makes slow glides sticky near frets); record those styles and
refit to regularize.

## Layout

Each enabled scale degree gets one editable **base** fret in the centre octave;
the ribbon extends `ghostExtentOctaves` (fractional; default **0.5** → a
**2-octave ribbon**, matching the Pitch Pad's half-octave flanks; 0–2 in 0.25
steps, toolbar "Octave ±") past the base octave on each side, filled with
read-only **octave-repeat** ghost copies clipped to the visible range, sharing
the base fret's vertical extent, drawn faint in edit mode. The ribbon spans
`1 + 2·extent` octaves; a fret's x is `(log2(ratio) + extent) / span · width`.

The **default arrangement** (`FretArrangement.defaultArrangement`, "Reset to
Scale") mirrors the String Pad's svara split so approaches stay open:

- **S and P** (pc 0, 7): centered segments (y 0.39–0.61)
- **shuddha** degrees (pc 2 4 5 9 11): lower middle (y 0.565–0.755, center 0.66)
- **komal/tivra** (pc 1 3 6 8 10): upper middle (y 0.245–0.435, center 0.34)

(Halved from the original bands and pulled toward the vertical center on
request — the off-center bands sit at the String Pad's paired-key centers
0.66 / 0.34, leaving open approach space toward the pad edges. Segments are
drawn thin, 1.5 px base / 1 px ghost, with a 2.5 px-half-width sounding glow.)

A fret's pitch is a `degreeIndex` into the enabled Pitch Pad scale degrees,
looked up live (`fretRatio`), so re-tuning the scale re-positions and re-tunes
the pad; a degree that disappears skips its fret rather than deleting it.
Names are sargam (`sargamName(forRatio:)`, `'`/`,` octave marks on ghosts).

## Editing

Edit mode (the default; **Perform** toggles it off and hides the octave
gridlines, labels, and endpoint handles, styling ghosts like base frets):

- **drag an endpoint handle** — set that end of the fret's vertical extent
  (its snap zone); minimum height 0.02
- **drag the line** — move the whole segment vertically (height preserved)
- **shift-click empty space** — add a fret on the degree nearest the click x
  (circular within the octave), 0.15 tall, centered on the click y — multiple
  segments per degree at different heights are allowed (separate snap zones)
- **right-click** — delete
- **drag empty space** — play (audible while arranging; grabbing a fret also
  sounds its exact pitch)

## What it reuses

- A **fourth `PitchPadEngine`** (`AppController.fretPad`) is the MPE emitter,
  identical wiring to `chordPad`/`stringPad` (in-process `init(audio:)`, tonic
  kept in step with `pitchPad` by the `start()` sink, `macExpressionLevel` set
  by `applyBaseVoice`).
- `pitchColor`, `SoundingState`, and `CellFillsView` — each fret is wrapped as
  a thin-rectangle `VoronoiCell` (`fretFillCells`) so the snapped fret glows;
  during a glide the nearest fret within the snap distance (at the cursor's
  height) glows with distance-faded weight (display only — pitch never
  re-snaps).
- The sargam helpers and the mouse-capture / readout patterns from the String
  Pad view.

## On the iPad

Like the other pads, the Fret Pad **runs on the iPad** — StarpadMac edits,
Starpad performs. Selecting the Mac's **Fret Pad** tab sets
`AppController.ipadLayout = .fretPad` (a fourth `PadLayout` case), which rides
the synced state, and the iPad swaps to `FretPadViewIOS` (in
`Starpad/Starpad/PitchPadView_iOS.swift`) on `pad.layout == .fretPad`.

Like the String Pad — and unlike the Chord Pad — the segment layout is **its
own state** (the vertical snap zones aren't derivable from the scale), so it's
pushed as a **third SysEx message** (`F0 7D 03 …`, `FretArrangementSysEx`,
blob v2 `[ver][ghostQuarterOctaves][count]` then
`[degreeIndex][topY][bottomY][enabled]`
per segment, y quantized to 7 bits) alongside the scale message, sent whenever
the arrangement changes while the Fret Pad is the active layout.
`ScaleSyncReceiver` decodes it into its `@Published fretArrangement`
(persisted via `FretArrangementSyncStore` for offline relaunch; if the iPad
has never synced, `ContentView` falls back to
`FretArrangement.defaultArrangement` built from the synced scale so the
surface is playable, not blank). The synced `marginPixels` carries the Mac
Fret Pad's **Snap** distance while this layout is active.

The iPad surface is **always perform mode** (no gridlines, labels, or
handles; ghosts styled like base frets) and **fully multitouch** — each finger
gets its own onset snap decision and keeps its own constant `snapOffsetLog`
for the life of the touch, so simultaneous snapped and approach touches
coexist.

## Code map

- `Packages/StarpadCore/Sources/StarpadCore/FretPadGeometry.swift` — model
  (`FretSegment` = degreeIndex + topY/bottomY + enabled; `FretArrangement` =
  segments + ghostOctavesPerSide), x↔pitch mapping (`fretLogRatio(atX:)` /
  `fretX(forLogRatio:)`), per-frame `fretPlacements`, onset `fretSnap`,
  edit hit-testing `fretGrab`, `fretFillCells`.
- `Packages/StarpadCore/Sources/StarpadCore/FretArrangementStore.swift` —
  `_Current.json` debounced autosave (atomic writes), ids minted on decode;
  same pattern as `StringArrangementStore`.
- `Packages/StarpadCore/Sources/StarpadCore/ScaleSync.swift` —
  `PadLayout.fretPad`, `FretArrangementSysEx` (subtype `0x03`),
  `FretArrangementSyncStore`, and `ScaleSyncReceiver.fretArrangement`.
- `StarpadMac/Views/FretPadView.swift` — the Mac tab: toolbar (Panic / Reset /
  Octave ± / Perform / readout / Snap / Velocity / Tonic), Canvas surface,
  AppKit mouse capture, interactions.
- `Starpad/Starpad/PitchPadView_iOS.swift` — `FretPadViewIOS` +
  `FretPadSurfaceIOS` (perform-only surface, per-touch snap offsets).

Editing and Mac-side persistence stay Mac-only
(`FretArrangements/_Current.json` under Application Support); the iPad only
receives and performs.
