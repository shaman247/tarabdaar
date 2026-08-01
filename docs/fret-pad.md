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

A candidate the touch is **actively receding from** (moving away, smoothed
speed above the stationary floor) exerts **no pull** — the magnet corrects
approaches and rests, never fights an escape from a fret. (2026-08-01: it
used to — a slow glide off a fret kept re-anchoring to it across the whole
basin, then the residue froze at the basin edge and carried, so a
below-extent approach to the next fret landed ~+97 ¢ sharp of it and only
snapped true on entering its extent.) When **no pull qualifies**, motion
decides the correction's fate: a **stationary** touch keeps it **frozen** (a
deliberate microtonal hold doesn't drift — and the movement gate's floor
keeps touch jitter frozen too), while a **moving** touch **sheds it with
distance travelled** (1/e per `correctionDecayPx` = 12 px, under the same
slew cap), so a glide away from an assisted landing converges on the raw
field pitch however slow the tempo and the next approach lands true.
Because the output is always the slewed state, no event (candidate switch,
zone entry/exit, speed spike) can produce a pitch discontinuity. Guard:
`FretDragAssistTests`.

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
`xcrun devicectl device copy from … --domain-type appDataContainer`. **Note
(2026-08-01): the escape/decay rules (receding candidates pull nothing;
moving touches shed the carried correction) postdate every recording to
date — pre-change recordings replay under the new rules and show elevated
parity, so re-record before trusting a fit.** Findings
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

- **S and P** (pc 0, 7): centered segments (y 0.324–0.676)
- **shuddha** degrees (pc 2 4 5 9 11 → R G m D N): lower middle
  (y 0.588–0.892, center 0.74)
- **komal/tivra** (pc 1 3 6 8 10 → r g M d n): upper middle
  (y 0.108–0.412, center 0.26)

(These are sized for the **half-height surface band** (below) — on screen
they render at the same absolute position/size as the pre-crop full-height
layout's 0.412–0.588 / 0.544–0.696 / 0.304–0.456 bands. A 0.176 gap
separates the paired frets, leaving open approach space toward the pad edges. Segments are drawn thin,
1.5 px base / 1 px ghost, with a 2.5 px-half-width sounding glow — the same
thin rectangles are the field's resolver cells.)

A fret's pitch is a `degreeIndex` into the enabled Pitch Pad scale degrees,
looked up live (`fretRatio`), so re-tuning the scale re-tunes the pad (fret
positions stay put — they're free); a degree that disappears skips its fret
rather than deleting it. **A fret is named by the scale**: its label is the
scale point's own `label` (`PitchPoint.displayLabel` — the text you typed in
the scale editor, or the ratio when blank), read through
`scaleLabel(degree:octave:degrees:)`, with `'`/`,` octave marks on the ghost
repeats. The default scale reads `S r R g G m M P d D n N` on the pad —
exactly as it reads in the scale editor, because the pad has no names of its
own. Before 2026-07-25 the pad ran a fixed 12-tone sargam table
(`sargamName`) alongside a default scale labelled `1 · 2- · 2 · 3- …`, so
the same pitch was called two things (`2-` drawn as `r`); the table was
deleted and the default scale took the sargam names itself, which is why
they survive — as the scale's labels, editable and replaceable like any
other scale's. Load a preset (Major, Dorian, …) or a saved scale and the pad
speaks THAT scale's labels instead.

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
- The scale-label helpers (`scaleDegrees`, `scaleLabel`, `octaveMarked` in
  `ScaleDegrees.swift`) and the mouse-capture / readout patterns from the
  String-Pad era.

## Drone buttons (2026-07-23)

Three **press-to-sound drone buttons** (4 → 3 on 2026-07-25) sit along the
surface's right edge around the upper quarter — the 3-button stack keeps the
same button size and spacing as the original 4-button top-to-center column
and starts half a button pitch lower, so its **vertical center is unchanged**
— on **both** the Mac tab and the iPad surface — the free hand plays them
while the other plays melody. The buttons live **inside the playing surface**
(`droneButtonRects` in StarpadCore — one shared rect function for both
platforms' visuals and hit-tests, count from `FretArrangement.droneCount`):
a touch/click is claimed as a drone press only when its **onset**
lands inside one of the 3 rectangles, hit-tested in the surface's own touch
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

- **Mapping (2026-07-25 — no dedicated drone strings)**: each button plucks
  **ONE sympathetic string**, mapped in the **Tarab tab's "Drone buttons"
  section** (`InstrumentState.droneStringIds`, 3 × optional `StringSpec.id`,
  persisted with the instrument document; nil = unmapped, button inert).
  All sympathetic strings are the same — a mapped string sounds exactly as
  its tarab row is tuned (ratio · gain · t60), and if the row is disabled
  or the jawari selection doesn't pick it up (e.g. gain below
  `bow_jt_gmin`), the button is silent, same as the row itself. The whole
  dedicated-drone-row machinery from 2026-07-23…25 is deleted: the
  ±6 ¢ reuse-if-covered check, the appended rows with median gain/t60, the
  per-slot `DroneStringSpec` voice, the `bow_drone_comp_cents`
  requested-pitch compensation and the pitch-class-nearest press matching
  — a press is an **identity lookup** on the mapped row's nominal Hz
  (`BowEngine.droneRow(forExactHz:)`). **Auto-mapping**: fresh documents
  and every bank regeneration map each slot to the highest-gain enabled
  string within ±100 ¢ of its target (low Sa · low Pa · Sa) — gain-first
  so the loud doubling strings win over quiet rows; manual
  mappings otherwise stick (a deleted row's mapping prunes to nil on
  decode). Mapping changes don't rebuild the engine — the jt web is
  untouched; the buttons just retarget (`AudioEngine.setDroneMappedFreqs`,
  which first releases any held button so its old row can't drone on).
- **Button labels**: `FretArrangement.droneRatios` is now **display-only**
  — the Mac derives the mapped strings' sounding pitches vs the PLAYED
  tonic and writes them into the arrangement (`AppController`), so the
  labels/colors on both surfaces ride the ordinary autosave + iPad sync.
  A button is named like a fret — `scaleLabel(forRatio:degrees:)` picks the
  scale degree nearest the ratio, in any octave, and marks the octave — so
  the drones speak the scale's vocabulary too (the iPad names them the same
  way: the scale blob carries the labels). An unmapped slot keeps its last ratio and is simply inert. The
  toolbar's Drones menu (the JI ratio picker) is gone — pitch is the
  mapped string's own tuning, edited like any tarab row.
- **Signal path**: on press/release both surfaces call
  `PitchPadEngine.setDrone(_:pressed:)`, which emits **CC 102–104 on
  channel 0** (value 127/0). Multi-finger safe on iPad: a second finger on
  a held button is refcounted, and the release fires when the last one
  lifts. The Mac pad
  delivers it in-process; the iPad sends it over USB like every other
  message. `AudioEngine.sendHostedMIDI` **intercepts** those CCs (never
  forwarded to the mapper) → `setDronePressed` → `BowEngine.
  dronePress/droneRelease` → the kernel's `bow_poly_jt_pluck` (sets the
  decaying onset boost) / `bow_poly_jt_drone` (sets the hold level) /
  `bow_poly_jt_drone_env` + `bow_poly_jt_drone_tone` (attack/release/
  boost-decay times + the drive band-pass corners, pushed at engine
  build). Per-row control-scalar writes; the excitation is applied
  inside `jt_tick_string`, so serial/pool/async paths all get it and the
  unused path stays byte-null. Held drones are re-armed after a structural
  rebuild (`reapplyHeldDrones`); a release skips rows another held button
  still maps to (two buttons mapped to the same string share its row).
- **Kin spread (mellow-drone rev, 2026-07-26)**: a press drives not just
  the mapped row but its **kin rows** — `BowEngine.dronePress` scores
  every row's harmonic kinship to the held row through the same
  `recruitAffinity` lattice/width the recruitment axis (`bow_jt_sel`)
  uses, and sets each row's drive to `bow_drone_level ×` that weight
  (held row = 1, octaves/fifths/twelfths fall off by `(p·q)^-kin`,
  scaled by `bow_drone_spread` 0..1; the melody-follower row never takes
  spread drive). Multiple held drones soft-OR (misses multiply, so a shared
  kin row takes the survivors' weight on release). This is what makes a
  drone tap wake the taraf the way *playing that note* does — before
  this rev only the single mapped row sounded, which read as a harsh
  isolated whine.
- **Pitched drive (same rev)**: each driven row's drive is
  `bow_drone_tone_mix` (0.5) sine **at the row's own mode-1 frequency**
  + the remainder band-passed noise (`bow_drone_lp_hz` 1600 /
  `bow_drone_hp_hz` 25). A played note hands a sympathetic string a
  PITCHED bridge force; pure noise (the first rev) rings the row's high
  modes far above their played-note balance — measured ring H4 ≈ H1
  against the played tap's H4 −29 dB, which is exactly the "harsh,
  sharp" report. With the sine drive the drone ring's harmonic profile
  matches the played tap's (H1-dominant, buzz filling H2/H3 naturally).
- **Levels & envelope** (`bow_drone_level` 0.026 · `bow_drone_onset`
  0.052 · `bow_drone_attack_ms` 150 · `bow_drone_release_ms` 350 ·
  `bow_drone_onset_decay_ms` 500 — read from bp in `BowEngine.init`,
  overridable via the audition `string.<key>` path): the mellow-drone
  rev slowed the first rev's fast swell/fall (40/60/200 ms, onset 0.3
  over level 0.08 — "rises and falls too quickly"; rise-to-90% is now
  ~310 ms) and recalibrated the level for the resonant sine drive
  (drive AT mode-1 resonance builds ~20 dB more ring per unit drive
  than noise; the level–ring curve turns superlinear past ~0.008 as
  the bone-buzz regime adds radiation). A first calibration at level
  0.006 / mix 0.85 / lp 450 (tap = 57 % of the pad tap, ring centroid
  ~300 Hz) came back "far too quiet", and a second at 0.016 was still
  short of the played note — the calibration TARGET is **loudness
  parity: a drone tap = a fret tap at the same pitch** (2026-07-27,
  user-specified). Raw RMS undersells the gap: the pad tap's energy is
  brighter, so match on an A-WEIGHTED short-window peak, not RMS.
  Calibrated single-instance against a tapped fret note at CC11 32 —
  **drone tap 46.5 dB(A) / 0.0437 peak RMS vs the pad tap's 46.9 /
  0.0424** with the ring centroid just under the played tap's (467 vs
  504 Hz; the first-rev noise drive rang at ~1280 Hz), and a hold
  sustains at ≈ 0.014 RMS. (Reference levels moved when the jawari
  graze-depth work landed the same week — recalibrate against a fresh
  pad tap, not stored numbers.) **Calibrate with ONE app instance
  running** — a second instance doubles the audio (+6 dB, chorus
  wobble) and its competing jt pools cause steady flat-fill overload
  logs. Audition hooks: `voiceParam` names `drone1`–`drone3`
  (value > 0.5 = press). **A drone mapped to a DISABLED tarab string is
  inert by design** (no jt row exists) — press `drone3` (Sa, enabled by
  default) when auditioning, and check the mapped string first when a
  button seems dead.

## On the iPad

The Fret Pad **runs on the iPad** — StarpadMac edits, Starpad performs. The
Mac pushes `AppController.ipadLayout = .fretPad` with the synced state, and
the iPad shows `FretPadViewIOS` (in `Starpad/Starpad/PitchPadView_iOS.swift`).

The segment layout is **its own state** (fret positions and snap zones aren't
derivable from the scale), so it's pushed as a **third SysEx message**
(`F0 7D 03 …`, `FretArrangementSysEx`, blob **v6**
`[ver][ghostQuarterOctaves][flags][count]` then
`[degreeIndex][x14: 2×7-bit][topY][bottomY][enabled]` per segment, then the
3 drone ratios as 14-bit cents-above-−1200 — x quantized to 14 bits, y to 7;
flags bit0 = legato; v6 = the 4 → 3 drone reduction) alongside the scale
message, sent whenever the arrangement changes while the Fret Pad is the
active layout. Pre-v6 blobs / pre-v4 stored docs are
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
coexist. The playable frets live in a **band** (`fretPadBandRect`): a
full-width strip spanning `Config.fretPadHeightFraction` (0.5) of the
surface height, vertically centered and marked by a hairline border. The
arrangement's normalized y spans just the band; the space above/below it is
dead — except the **drone buttons**, which keep their FULL-surface position
(right edge, top → vertical center, same as before the band crop). Both
surfaces draw the whole picture — band, border, dead space, buttons — and
the Mac tab letterboxes to the full `iPadSurfaceAspect`, so **what you see
on the iPad is exactly what the Fret Pad tab shows**.

## Code map

- `Packages/StarpadCore/Sources/StarpadCore/FretPadGeometry.swift` — model
  (`FretSegment` = degreeIndex + free `x` + topY/bottomY + enabled;
  `FretArrangement` = segments + ghostExtentOctaves + legato +
  droneRatios), the playable band rect (`fretPadBandRect`), band↔pixel
  mapping (`fretPixelX(forBandX:)` / `fretBandX(atPixelX:)`), per-frame
  `fretPlacements`, the pitch field (`fretFieldLog` + `fretColumnLog` —
  two-column x-interpolation, y-resolved columns), onset `fretSnap`, edit
  hit-testing `fretGrab`, `fretFillCells`.
- `Packages/StarpadCore/Sources/StarpadCore/FretArrangementStore.swift` —
  `_Current.json` debounced autosave (atomic writes), ids minted on decode;
  doc **v4** (free x; pre-v4 rejected → default rebuilt; `droneRatios`
  optional — absent falls back to the default; 4-slot-era sets migrate,
  see *Drone buttons*).
- `Packages/StarpadCore/Sources/StarpadCore/ScaleSync.swift` —
  `PadLayout.fretPad`, `FretArrangementSysEx` (subtype `0x03`, blob v6),
  `FretArrangementSyncStore`, and `ScaleSyncReceiver.fretArrangement`.
- `StarpadMac/Views/FretPadView.swift` — the Mac tab: toolbar (Panic / Scale
  menu / Reset / Octave ± / Legato / Perform / Drones / Rec / readout /
  Snap / Velocity / Prime / Tonic — the tonic being a `ScrollableField` of Hz
  (scroll = cents) plus a note menu of the half-octave around it; see
  [Scales & Tuning — The tonic](scales-and-tuning.md#the-tonic-starpadmac-fret-pad-tab)),
  Canvas surface, AppKit mouse capture,
  interactions, the drone button strip, and the scale list editor.
- `Starpad/Starpad/PitchPadView_iOS.swift` — `FretPadViewIOS` +
  `FretPadSurfaceIOS` (perform-only surface, per-touch snap offsets) +
  `DroneStripIOS` (the 3 drone buttons, right edge, upper quarter).

Editing and Mac-side persistence stay Mac-only
(`FretArrangements/_Current.json` under Application Support); the iPad only
receives and performs.
