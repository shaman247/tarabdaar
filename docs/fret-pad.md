# Fret Pad

The **Fret Pad** is the **sole playing surface** (Mac tab ⌘4 + the iPad's
only surface). Each enabled scale degree appears as one or more vertical
**line segments (frets)** that are **freely positioned** — since the
2026-07-23 free-fret change a fret's `x` (0..1 across the base band) is its
own layout state, **unrelated to its pitch**. The playable pitch is a
continuous **field** interpolated from the frets:

- A **column** = the frets sharing an x position (within `fretColumnEps`
  ≈ 0.5 px) — stack two frets by hand and they form one (the default C
  Keyboard layout stacks each komal/tivra fret over its shuddha partner;
  C Equal Freq stacks none — each degree sits at its own pitch-derived x). A
  column's pitch at the touch's y (`fretColumnLog`): **inside** a member
  fret's vertical extent → exactly that fret's pitch; **between** two
  stacked frets → a linear y-interpolation across the gap; **above/below**
  all of them → clamped to the nearest one.
- The field at the touch = the **log-pitch x-interpolation between the two
  closest columns horizontally** — the nearest at-or-left and the nearest
  right of the touch (`fretFieldLog`). Beyond the outermost columns the
  line through the outermost **pair extrapolates**, so the edges keep the
  local slope instead of going flat (a single-column layout holds its
  pitch everywhere).

So dragging right of S plays S at S's line, r at r's line, and the
log-pitch curve between them in the gap — pitch always moves toward the
neighbor you're dragging at. Continuous
everywhere: both sides of a column agree on the column's own pitch, and the
y-resolution is continuous in y. (Earlier revisions used global
inverse-distance blends over every fret — the far tail collectively
outweighed the nearest fret and dragged gaps toward the layout's mean pitch,
audible as pitch bending the wrong way beside an edge fret. Two-column
interpolation removes the whole failure class.)

There are no discontinuities anywhere: onset snapping only ever adds a
constant offset, drags follow the continuous field, and the drag assist is
slew-limited/additive on top.

## Pitch warp — frets bend the space around them (2026-08-24; live param 2026-08-25)

**`ctl_fret_warp`** ("pitch warp", the "Fret pad" registry group; the Mac
Fret Pad toolbar's **Warp** slider edits the same value, 0…100 %)
reshapes every fret-to-fret interpolation — the x-blend between columns AND
the y-blend across a stacked column's gap — through a **normalized
logistic** (`fretWarp`):

```
w(t) = (σ(g·(t−½)) − σ(−g/2)) / (σ(g/2) − σ(−g/2)),   g = 14 · warp
```

At 0 it is exactly the identity (the historic linear field, bit for bit);
as it rises, pitch **plateaus around each fret and transitions quickly
through the middle of the gap** — a straight constant-rate slide between
two adjacent frets traces a logistic pitch curve, arriving early and
leaving late. The law is fixed at w(0)=0 / w(1)=1 (frets stay exact),
symmetric (w(t)+w(1−t)=1 — the **midpoint between two frets never moves**,
so the territory boundary is warp-invariant), and strictly monotone, so
the field keeps all its continuity guarantees. Beyond the outermost
columns the extrapolation stays linear (the warp is only defined between
frets). At the top (g = 14) the center slope is ≈ 3.5× linear and the
quarter-gap point sounds ≈ 3 % of the interval instead of 25 %.

The amount is a **live control param** (`ctl_fret_warp`, `.live`, def 0),
not layout state — like `ctl_strike_window` it never reaches the voice:
`AppController.applyParamToVoice` intercepts the key, publishes the live
value for the Mac surface (`AppController.fretFieldWarp`), and relays it
to the iPad over the **JOYCON_STATE frame (TLP v10)**, where
`FretPadSurfaceIOS` resolves every touch onset/move through it
(`scaleSync.joyConTilt.fieldWarp`; 0 = linear while the link is down —
moot, since a linkless iPad makes no sound anyway). That makes it
**performable**: it sits on the Parameters tab with a mapping button like
every param, so binding it to a tilt/stick axis (e.g. the Joy-Con stick)
morphs the pad mid-phrase — stick at rest = the linear meend-friendly
field, stick pushed = a near-quantized field for fast runs on one
string. The relay rides the link's paced, latest-wins state lane, so a
stick wiggling at input rate costs at most one frame per 120 Hz tick.
Because touch pitch is evaluated iPad-side at event rate, a warp change
retunes a MOVING finger continuously (both position and warp enter the
same continuous field); a finger holding perfectly still simply keeps its
pitch until it next moves. The resting value persists with the other
control defaults and in presets; it is deliberately NOT in the
arrangement blob or the layout files. Guards: `FretWarpTests`.

### Contour overlay (Mac, edit mode)

Out of Perform mode the Mac surface draws the field's **iso-pitch
contours** (`fretFieldContours`): the **territory boundaries** — the
log-midpoints between adjacent sounding pitches, the line where the field
crosses from one pitch's territory into the next — brighter (white 0.28),
plus fainter quarter-pitch minor contours (white 0.10). Between two plain
columns a boundary is a straight vertical line; through a stacked column's
blend zone it **curves** (the column's own pitch slides r → R with y, so
the halfway line bows toward the neighbor). The minors are what make the
warp visible: at 0 they sit at the linear quarter positions, and as the
Warp rises they bunch against the boundaries — plateaus around the frets,
a cliff in the middle. The solve is exact, not sampled in x: per scanline
and column pair the crossing is `x = a + w⁻¹((c−l)/(r−l))·(b−a)` via
`fretWarpInverse`, one crossing per pair (the warp is monotone). Perform
mode and the iPad draw no contours — clean playing surface.

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
(`Packages/TarabdaarCore/Sources/TarabdaarCore/FretDragAssist.swift`) handles the
rest of the stroke. Musical premise: when the player **stops or changes
direction** near a scale pitch, that inflection was intended to be *on* the
pitch; while the finger is moving — at **any** tempo — they're gliding and
must be left alone.

It's a **gated magnetic correction**, continuous by construction. Each touch
carries one slew-filtered `correction` (log2 units);
`played = field + onsetOffset + correction`, and the correction eases toward
the nearest qualifying fret at a rate = **gate × proximity × settle**:

- **gate = min(1, max(stopped, turnGain·impulse))** — "stopped" is a
  genuine **stop detector** (2026-08-17): the touch must dwell within
  `stillRadiusPx` (2 px) of a still anchor for `stopDwellMin` (100 ms)
  before the gate starts opening, ramping to 1 over `stopDwellRamp`
  (150 ms). A sustained drag — however slow — keeps leaving the still disc
  and restarting the dwell clock, so the magnet never touches a glide and
  pitch simply follows the finger; jitter wanders inside the disc, so rests
  still engage it. (The original gate was smoothed |dx/dt| through a fitted
  59/375 px/s smoothstep — it read a ~120 px/s glide as ~90% *stationary*
  and pulled slow glides toward every approaching fret. The fitted speed
  estimate survives, but only bounding the receding check and the
  correction shed below.) Fast connected playing turns in ~30 ms — too
  fast for any dwell — so a causally-detected **direction flip**
  (deadbanded dx sign change, ~one event of latency) fires an impulse that
  holds the gate open while it decays (fitted: turnGain 2.0, turnTau 26 ms
  → gate pinned at 1 for ~18 ms then decaying).
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

**Every touch is born stopped** (2026-08-18; legato-only the day before): a
fresh finger isn't moving until it actually moves, so the dwell gate starts
fully open at onset — a sloppy landing, staccato tap and legato strike
alike, snaps onto the fret immediately (still slew-capped, ~30–50 ms for a
typical 30 ¢ landing error) instead of waiting out the stop dwell. The
first ≥`stillRadiusPx` of movement re-anchors and shuts the gate, so a
touch that turns into a glide is left alone from its first events — and the
documented approach-path starts (above/below a fret's extent, or in open
space) have no magnet candidate at all, so nothing pulls them.

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

### Fitting the assist to real playing

The four constants can be **fitted to recorded movements** instead of tuned
by hand:

1. Toggle **Rec** (Mac Fret Pad toolbar) or **REC** (iPad Fret Pad toolbar)
   and play naturally — glides into stops, direction changes near notes,
   vibrato, fast runs, approaches. Each play stroke is appended to a JSONL
   session file (`FretGestureRecorder`, TarabdaarCore; record **v2** since the
   free-fret change): raw events `[t, x, y, u, o, tick]` (`u` = uncorrected
   log2 pitch — field + onset offset — the assist's input; `o` = the pitch
   actually played) plus a context snapshot (fret pixel x + pitches +
   extents, Snap, band extent, the live assist params). Files land in
   `~/Library/Application Support/Tarabdaar/FretRecordings/` on the Mac; on the
   **iPad** in the app's `Documents/FretRecordings/` — user-visible
   (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`), so copy
   them to the Mac via Finder's device browser (iPad → Files → Tarabdaar) or
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
(2026-08-01/2026-08-17): the escape/decay rules (receding candidates pull
nothing; moving touches shed the carried correction) and the stopped-gate
change (dwell inside a still disc opens the magnet, not smoothed speed)
postdate every recording to date — pre-change recordings replay under the
new rules and show elevated parity, so re-record before trusting a fit.** Findings
baked into the current constants: raw landings were 29¢ mean / 62¢ p90 off
(overshooting past the note 45/64 times), half beyond the old 1× radius —
hence `radiusScale`; the speed gate never opened at this tempo — hence the
flip impulse; scoring is perceptual (error weighted by inverse *output*-pitch
velocity around each turn; transparency = per-segment std of the correction,
excluding a 120 ms post-turn guard). Result: landing error 39.7¢ → 29.3¢,
transit warping ≈ 2¢. Caveats: the recording covers fast connected playing
only — slow-glide/vibrato feel is extrapolated (the fitted speed-smoothstep
gate made slow glides sticky near frets, which the 2026-08-17 stopped gate
removed structurally) — **and it was made on
the old pitch-mapped ribbon** (the assist basin was ≈75¢ in log-pitch; it's
now the same 42 px in screen space). Old (v1) recordings still load — the
fitter derives fret x from the old mapping — but record fresh sessions on
the free-fret surface and refit.

## Touch indicator & onset strike display

Each touch draws a per-touch **indicator ring** — cool cyan while the
finger glides, warming to amber as the drag assist's stop detector
engages — plus the "original → corrected" pitch readout whenever the
sounding pitch differs from the raw field pitch under the finger.

(A 2026-08-18 **fret-linger / y-depth auto-vibrato** layer — expression
decay on lingering notes shown as a shrinking arc on this ring, an
auto-vibrato grown toward the fret's outer end marked by wavy fret
tails, the `bow_linger_*`/`bow_avib_*` parameter group, the TLP v4/v5
`posY`/`fretY` touch bytes and the Mac→iPad `LINGER_STATE` display
stream — was **removed on 2026-08-23** (TLP v8). Fret lines draw plain
again, the ring is a plain circle, and held notes hold their
expression. Do not revive without a fresh design.)

**Onset strike ripple (2026-08-20).** The indicator also receipts
the accelerometer strike estimate ([sensors.md](sensors.md)): at every
onset a white impact ring expands from the touch ring and fades over
~0.5 s, its reach, brightness and stroke weight all scaled by the
estimate — a hard tap throws a bright wide wave, a gentle placement
barely whispers (a faint ripple at estimate 0 still confirms "read:
soft"). **The number (2026-08-20, same day):** the estimate is also
printed beside the ring for the note's whole life — MIDI scale 0–127,
the vocabulary sensors.md's typical-tap table speaks (soft ~1–30,
medium ~50–80, hard ~100–127; `bow_attack_vel` sees value/127) — and on
release it survives as a **fading ghost for ~1 s**, so a staccato tap's
reading doesn't vanish with the finger: the display exists to calibrate
one's strike, and staccato is exactly where that matters. This is the
LOCAL estimate drawn at capture time (the exact
value that rode the wire's velocity byte into `bow_attack_vel`), not a
Mac round-trip — there is nothing Mac-side to
drift from, since the byte is consumed as sent. Because a staccato
touch may never move again after its onset, the indicator model runs a
short ~15 Hz redraw ticker (`.common` runloop mode) while a ripple or
ghost is decaying; it dies with them. No motion source (previews) = no
ripple, no number. The Mac preview pad has no such overlay (play it
with sound up).

## Layout

The editable **base** frets live in a central **band**; the surface extends
`ghostExtentOctaves` band-widths (fractional; default **0.5**; 0–2 in 0.25
steps, toolbar "Octave ±") past the base band on each side, tiled with
read-only **octave-repeat ghost copies of the whole base layout** — the left
flank plays an octave down, the right an octave up — clipped to the visible
range, sharing each base fret's x-within-band and vertical extent, drawn
faint in edit mode. The surface spans `1 + 2·extent` band-widths; a fret's
pixel x is `(x + shift + extent) / span · width` (`fretPixelX(forBandX:)`).

### C Equal Freq — the other built-in

The **C Equal Freq** built-in (`FretArrangement.defaultArrangement` — the
name is historic; it was the default 2026-08-02 → 2026-08-11, and is now
reached only from the Layout menu's Built-in submenu) is
**pitch-aligned** (2026-08-02): a
fret's `x` is `log2(ratio)` —
its horizontal position IS its frequency, in the app's log-pitch space — so
the base band spans exactly one octave, the tonic sits at the band's left
edge and the octave ghosts at `x ± 1` tile the ribbon continuously. (Frets
stay **free** — this is only where the built-in puts them; drag one
anywhere and the field follows.) Vertically there are **two separated
tiers** — komal/tivra above, everything else below — with the ordinary frets
all the **same height** (0.352) and **S and P as the long keys**:

- **komal/tivra** (pc 1 3 6 8 10 → r g M d n): the upper tier
  (y 0.108–0.460)
- **shuddha** degrees (pc 2 4 5 9 11 → R G m D N): the lower tier
  (y 0.540–0.892)
- **P** (pc 7): lower tier, longer — y 0.510–0.912
- **S** (pc 0): lower tier, longer still — y 0.470–0.912

With the default 12-degree scale this reads like a **piano keyboard with the
tonic on C**: the komal/tivra frets are the black keys, standing higher and
falling between their neighbours at their own pitch, while S and P run a
little lower than the naturals and the tonic reaches highest of the lower
tier. The field along any horizontal line is a straight log-pitch ramp —
position = pitch everywhere, since the frets it interpolates between are
themselves at their pitch.

(The tiers share **no endpoint**: the upper ends at 0.460, the lower starts
at 0.540, and S's tip (0.470) pokes into that gap without touching the tier
above — so no y belongs to two tiers, and the band 0.460–0.470 / 0.510–0.540
is open approach space between the black-key row and the white-key row.
Sized for the **half-height surface band** (below). Nothing stacks here —
each degree has its own pitch-derived x — with two consequences: on the
default 12-degree JI scale the fret spacing is 35–56 px rather than the old
uniform ~85 (35 px = the 70 ¢ komal→shuddha third and sixth, g→G and d→D —
but those pairs are in different tiers, so no y sees both), and adjacent
**assist basins** (42 px) overlap within a tier — the assist takes the
nearest qualifying fret, so this only means the magnet is live nearly
everywhere along a tier. Segments are drawn thin, 1.5 px base / 1 px ghost,
with a 2.5 px-half-width sounding glow — the same thin rectangles are the
field's resolver cells.)

### C Keyboard — the default

`FretLayoutPreset.keyboard` (`FretArrangement.keyboardArrangement`) is the
**default layout** (2026-08-11 — it was also the default until 2026-08-02):
a fresh install's starter arrangement on the Mac and the never-synced iPad's
fallback, and what the toolbar's **"Reset to Scale"** button builds from the
current scale (2026-08-12). It plays like
a **piano keyboard**: **7 evenly-spaced columns**, one per svara —
`x = (col + 0.5)/7` for S · R/r · G/g · m/M · P · D/d · N/n — so the naturals
are equally spaced like white keys and each komal/tivra fret **stacks above**
its shuddha partner in the same column (the black key over the white one)
instead of taking a position of its own:

- **S and P** (pc 0, 7): centred (y 0.324–0.676)
- **shuddha** (R G m D N): lower middle (y 0.588–0.892)
- **komal/tivra** (r g M d n): upper middle (y 0.108–0.412)

The 0.176 gap inside a stacked pair is the column's **y-interpolation zone**
(sliding down the column bends r → R — see the field rules at the top);
the space toward the pad's top/bottom edges is open approach room. This is
the layout the drag-assist constants were fitted on.

### Saving layouts

Fret layouts are **their own saved state**, independent of the scale that
names and tunes them — a layout loads onto whatever scale is active, and a
degree the scale doesn't have simply skips its fret. The Fret Pad toolbar's
**Layout** menu mirrors the Scale menu: *Save As…* (a name prompt, no file
panel), *Save "name"*, a **Built-in** submenu (C Equal Freq · C Keyboard,
generated from the current scale), the saved layouts with a checkmark on the
loaded one, and a *Delete* submenu. Loading panics the fret engine first —
the frets a held note was resolved against are about to be replaced. (The
Scale menu's **Reset to Default** is the full factory reset: it reloads the
bundled default scale AND rebuilds the **C Keyboard** layout from it.)

Saved layouts are one `<name>.json` each in
`Application Support/Tarabdaar/FretArrangements/`, the same folder and format
as the live autosave `_Current.json` (which is filtered out of the menu, and
whose name is refused when saving). Copy a file in and it appears in the
menu; the built-ins are code, not files, so they can't be deleted. Guard:
`FretLayoutTests`.

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
speaks THAT scale's labels instead (the 12-TET Chromatic preset keeps the
sargam names — see [Scales & Tuning](scales-and-tuning.md#playing-scale-tarabdaarmac-fret-pad-tab--ipad)).

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
(`droneButtonRects` in TarabdaarCore — one shared rect function for both
platforms' visuals and hit-tests, count from `FretArrangement.droneCount`):
a touch/click is claimed as a drone press only when its **onset**
lands inside one of the 3 rectangles, hit-tested in the surface's own touch
handler (`began` on iPad, `handleDown` on Mac) — never via SwiftUI gestures.
Everything around and **below** the buttons plays normally, and melody drags
that wander across a button keep gliding. (The first layout put the buttons
in a separate side column — that made the whole right edge dead space and
swallowed touches aimed at the rightmost fret.)

**Hidden while a Joy-Con is attached (2026-08-13, BOTH surfaces):** with a
controller attached the player plays the drones from it (**↓** = drone
button 2 — since 2026-08-27 **← / →** step the playing-range **octave
shift** instead of pressing drones 1/3 (±3, `AppController.shiftOctave` →
`PitchPadEngine.octaveShift`, relayed as the JOYCON_STATE `octave` byte,
TLP v11 — the toolbars show the offset; onset-captured per touch, so a
sounding note keeps its birth octave through every glide; drones, the
tarab and the strum deliberately do not shift); **L = the configurable strum**, 2026-08-27, reworked
2026-08-28 to a held chord — holding it sounds the Strings tab's own strum
SET all at once as a **held chord in the MAIN voice**
(`AppController.strum(pressed:)` → the shared `pitchPad` engine, the same
in-process touch path as the Mac pad/keyboard — so the notes follow the
Live tab's instrument picker, allocate fresh strings, charge the taraf,
and carry a firm 0.9 strike velocity for `bow_attack_vel`). The chord
sustains while L is held and note-offs on release. **`ctl_strum_expr`
(2026-08-28) is the chord's own expression** — a per-note scale on the
chord notes' bow-expression axis (Tanpura/Sitar mains: the pluck level,
onset-only), bound to the **Joy-Con stick Y** by default and pushed live
to the held notes, so the stick swells the ringing chord without touching
the melody's expression. **`ctl_strum_thresh` (2026-08-28) adds an accel
trigger**: the iPad's strike envelope (the Strike dimension's own
measurement) crossing the threshold strikes the chord exactly as an L
press does, releasing the moment it falls back below the SAME threshold —
a 100 ms retrigger cooldown after each release (2026-08-29, replacing the
original ~60% release hysteresis) keeps a jittery envelope hovering at
the threshold from machine-gunning the chord (default 127 = off; the L
button ignores the cooldown). Default set low Sa · low Pa, remappable to raga chords since
members are scale-degree string references. The first 08-27 version swept the set as staggered
staccato notes (`ctl_strum_stagger`/`ctl_strum_gate`, both retired);
earlier same-day it strummed through the drone voice, and before
2026-08-27 it pressed the three drone buttons), so both surfaces hide the on-screen
buttons —
visual *and* hit-test; their area falls through to the band / dead space
like any other point, and they reappear on disconnect. Mac: the surface
reads `JoyConInput.connectedName != nil`, tapping only the `$connectedName`
publisher (observing the whole `JoyConInput` would re-run the surface at
stick-input rate). iPad: the `connected` bit (bit 2) of the `0x05` tilt
relay's flags byte — the one field of that message the iPad acts on, so the
Mac sends the message on attach/disconnect and with every scale-sync state
push (iPad plug-in included), not just while axes move
(`ScaleSyncReceiver.joyConTilt.connected` → `FretPadSurfaceIOS.dronesHidden`).
The two surfaces therefore always agree, one push-latency apart. A drone
held at the moment of attach still releases normally (the release path
doesn't consult the flag).

**Which voice sounds (2026-08-04, the tanpura port):** the buttons drive the
**Tanpura voice by default** — a press *plucks* the mapped pitch on the ported
tanpura (`TanpuraEngine`; see [tanpura-voice.md](tanpura-voice.md)), holding
re-plucks it every `tp_drone_cycle` seconds (the strumming hand), and release
lets the string ring out on its own t60 (no damp — the instrument's nature).
The **Strings tab's "Drone buttons" section has the Voice picker**
(`AppController.droneVoice` → `AudioEngine.setDroneVoiceMode`); switching to
**Sympathetic strings** restores the legacy jt-row swell documented below.
Everything in this section about *mapping, labels, and the CC path* applies to
both modes — the mapping sets the button's pitch either way; the paragraphs
about the jt excitation/kin-spread/level calibration describe the legacy mode.

While pressed in the legacy sympathetic mode, a **String-voice jawari-taraf string** sings.
The excitation is entirely a **slewed band-passed-noise drive** (no impulse
anywhere): the drive envelope swells over the attack time toward
`level + onset boost`, the boost decays over ~200 ms so the onset relaxes
into the sustain, and release drops the drive so the row rings out on its
own t60. The noise is band-passed **~25 Hz–2 kHz in the kernel** — sub-audio
drive content would push the string quasi-statically against the jawari bone
and pump the buzz (an audible slow tremolo; the 2026-07-23 fix). Other base
the String voice's jt web carries them.

- **Mapping (2026-07-25 — no dedicated drone strings)**: each button plucks
  **ONE sympathetic string**, mapped in the **Strings tab's "Drone buttons"
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
  `PitchPadEngine.setDrone(_:pressed:)`, which flips a **held-state bit
  (`droneMask`) in the outbound TLP state frame** (2026-08-14 — latest-wins
  and stuck-drone safe by construction; the legacy CC 102–104 path survives
  in-process for audition scores). Multi-finger safe on iPad: a second
  finger on a held button is refcounted, and the release fires when the
  last one lifts. `LinkIngest` diffs the mask edges (the Mac pads pump the
  same path in-process) → `setDronePressed` → `BowEngine.
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

## Chord bar (2026-08-28)

The dead strip **below the playable band** is the **chord bar**: the same
horizontal layout as the frets, but each fret column carries a **chord
label** — the roman numeral of a 3-tone chord rooted on that fret's
degree, derived from the configured scale (`ChordBar.swift` in
TarabdaarCore, shared by both surfaces — geometry, labels and hit-tests
can never disagree). **Tapping a cell selects that chord as what the
controller strum plays** (Joy-Con L / the accel trigger — see
[Sound Design](sound-design.md)); tapping any cell of the selected degree
deselects it, and with nothing selected the strum falls back to the
Strings tab's configured set (default low Sa · low Pa).
**Chords are OCTAVE-AGNOSTIC (2026-08-30)**: a chord is a pitch-class
object — a I chord sounds the same from any Sa cell, every octave copy of
the selected degree highlights, and the tapped cell's octave normalizes
to 0 at selection (`toggleChordSelection` / `AppController.tapChord`).
The sounding register is fixed by the **Shepard register law**
(`shepardChordNotes`): each chord tone's octave copies are weighted by a
raised-cosine window over log2 frequency, two octaves wide, centered on
the middle of the **octave below the tonic** — the two copies inside the
support get complementary weights summing to exactly 1 (octave spacing
shifts the cos² window by π/2), so total chord energy is root-independent
and as a progression walks up the scale the upper copy fades out while
the lower fades in: a VII chord sits no higher than a I chord, Shepard
style. Weights drive the notes' per-slot expression scale (multiplied
with `ctl_strum_expr`); flanks under 0.02 are dropped for polyphony
(≤ 6 notes per chord). Guard: `ChordBarTests` Shepard cases.
**A selection change lands
immediately (2026-08-29)**: if the strum chord is ringing at the edge,
its held notes switch to the new chord in place
(`AppController.retuneStrumChord` — members glide to the new pitches
and take their new Shepard weights live with no new attack, a shrinking
chord releases the surplus, a growing one strikes the extra members;
deselecting mid-hold retunes to the configured fallback set the same
way). Selection is performance state
— never persisted, cleared at launch, and exempt from the playing-range
octave shift like every anchor gesture.

**Chord derivation** (`scaleChords`): for each enabled degree the root is
joined by the scale's own best **third** — any pitch class folding to
250–450 ¢ above the root, "close to or between" the just minor (316 ¢)
and major (386 ¢) thirds, classified to whichever it sits nearer — and
best **fifth** (perfect 650–750 ¢ — the pentatonic's 40/27 wolf at 680 ¢
counts — diminished 550–650 ¢, augmented 750–850 ¢). Quality priority is
**major > minor > diminished > augmented**, which is why the full
12-tone scale offers all major chords. A missing member is omitted
rather than faked: the major-pentatonic II is just root + fifth, and a
lone root still gets a cell.

**Numerals** are harmony's own vocabulary, not the scale labels (chord
function is a different naming axis, like the concert note names): each
degree maps to the chromatic table I ♭II II ♭III III IV ♯IV V ♭VI VI
♭VII VII by nearest semitone class, and the accidental is DROPPED when
the scale holds no other class in that ordinal family — natural minor
reads **i ii° III iv v VI VII**, the 12-tone scale keeps ♭II beside II.
Case is quality (upper = major, lower = minor, ° diminished, + augmented;
third-less chords stay plain uppercase). Guard: `ChordBarTests`.

**Layout** mirrors the frets (`chordBarCells`): one cell column per fret
column, repeated across the octave ghosts; a lone fret (S, P in the
keyboard layout) takes the bar's full height while stacked frets split it
in their own band order — so the default 12-tone keyboard layout reads as
a komal/tivra top row over a shuddha bottom row with I and V spanning
both. Cell taps are claimed at ONSET only, in the surface touch handlers
(like the drone buttons); nothing sounds until the strum plays.

**The selection crosses the wire as held state** (TLP v12): the pad's
active chord rides every PERF_STATE frame as the `chordDegree`/
`chordOctave` bytes (0xFF = none; since the 2026-08-30 octave-agnostic
rework `chordOctave` is always 0 — a reserved field, still decoded), and
the Mac acts on the CHANGE edges
(`LinkIngest.onChordSelect` — heartbeat repeats are silent, so an idle
iPad never clobbers a Mac-local selection). The Mac's own bar taps travel
the identical in-process path (`AppController.tapChord` → the shared
`pitchPad` → the local pump), so `AppController.strumChord` — what the
Mac bar highlights — is always literally what the next strum sounds; the
iPad highlights its own outbound selection. Audition route: `voiceParam`
name `chord`, value = degree index (octave 0), negative = deselect.

## On the iPad

The Fret Pad **runs on the iPad** — TarabdaarMac edits, Tarabdaar performs. The
Mac pushes `AppController.ipadLayout = .fretPad` with the synced state, and
the iPad shows `FretPadViewIOS` (in `Tarabdaar/Tarabdaar/PitchPadView_iOS.swift`).

The segment layout is **its own state** (fret positions and snap zones aren't
derivable from the scale), so it's pushed as a **third SysEx message**
(`F0 7D 03 …`, `FretArrangementSysEx`, blob **v6**
`[ver][ghostQuarterOctaves][flags][count]` then
`[degreeIndex][x14: 2×7-bit][topY][bottomY][enabled]` per segment, then the
3 drone ratios as 14-bit cents-above-−1200 — x quantized to 14 bits, y to 7;
`flags` is RESERVED, always 0 since tap legato was deleted 2026-08-02 and
decoded ignored; v6 = the 4 → 3 drone reduction; the fret pitch warp is
deliberately NOT here — it is the live `ctl_fret_warp` param, relayed
over JOYCON_STATE) alongside the scale
message, sent whenever the arrangement changes while the Fret Pad is the
active layout. Pre-v6 blobs / pre-v4 stored docs are
rejected and fall back to the default. `ScaleSyncReceiver` decodes it into
its `@Published fretArrangement` (persisted via `FretArrangementSyncStore`
for offline relaunch; if the iPad has never synced, `ContentView` falls back
to `FretArrangement.defaultArrangement` built from the synced scale so the
surface is playable, not blank). The synced `marginPixels` carries the Mac
Fret Pad's **Snap** distance while this layout is active.

**Per-touch indicator (2026-08-17, iPad only):** every play touch draws a
ring around the finger — amber at onset (every touch is born stopped) and
whenever the drag assist's stop detector holds (`FretDragAssist.Output.
stopGate`), cooling to cyan while the finger glides —
and, whenever the sounding pitch differs ≥1 ¢ from the raw field pitch
under the finger (onset snap and/or magnet correction), a readout above the
ring shows `original → corrected`, both named in the scale's own vocabulary
with signed cents offsets (e.g. `R−18¢ → R`). Display-only
(`TouchIndicatorModel` + `TouchIndicatorLayerIOS` in
`PitchPadView_iOS.swift`, fed from the touch handlers and the 60 Hz settle
timer; publishes stop once a hold settles).

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

- `Packages/TarabdaarCore/Sources/TarabdaarCore/FretPadGeometry.swift` — model
  (`FretSegment` = degreeIndex + free `x` + topY/bottomY + enabled;
  `FretLayoutPreset` = the two built-in layouts;
  `FretArrangement` = segments + ghostExtentOctaves + droneRatios), the
  playable band rect (`fretPadBandRect`), band↔pixel
  mapping (`fretPixelX(forBandX:)` / `fretBandX(atPixelX:)`), per-frame
  `fretPlacements`, the pitch field (`fretFieldLog` + `fretColumnLog` —
  two-column x-interpolation, y-resolved columns, `fretWarp` logistic
  reshaping), the edit-mode contour solver (`fretFieldContours` +
  `fretWarpInverse`), onset `fretSnap`, edit
  hit-testing `fretGrab`, `fretFillCells`.
- `Packages/TarabdaarCore/Sources/TarabdaarCore/FretArrangementStore.swift` —
  `_Current.json` debounced autosave (atomic writes), ids minted on decode;
  doc **v4** (free x; pre-v4 rejected → default rebuilt; `droneRatios`
  optional — absent falls back to the default; 4-slot-era sets migrate,
  see *Drone buttons*; the retired v3 `legato` key decodes away, no bump).
  Also the **named layouts** — `savedNames` / `save` / `load` / `delete` /
  `sanitized` over the same folder (`_Current` reserved), with the built-ins
  in `FretLayoutPreset` (`FretPadGeometry.swift`) and the menu actions on
  `AppController` (`loadFretLayout(preset:)` / `saveFretLayout(name:)` /
  `loadFretLayout(name:)` / `deleteFretLayout(name:)` + `fretLayoutName`).
- `Packages/TarabdaarCore/Sources/TarabdaarCore/ScaleSync.swift` —
  `PadLayout.fretPad`, `FretArrangementSysEx` (subtype `0x03`, blob v6),
  `FretArrangementSyncStore`, and `ScaleSyncReceiver.fretArrangement` —
  plus `JoyConTiltDisplay.fieldWarp`, the live warp's Mac→iPad carrier.
- `TarabdaarMac/Views/FretPadView.swift` — the Mac tab: toolbar (Panic / Scale
  menu / Layout menu / Reset / Octave ± / Perform / Drones / Rec / readout /
  Snap / Warp / Velocity / Prime / Tonic — the tonic being a typed Hz field plus a
  note menu of the half-octave around it; see
  [Scales & Tuning — The tonic](scales-and-tuning.md#the-tonic-tarabdaarmac-fret-pad-tab)),
  Canvas surface, AppKit mouse capture,
  interactions, the drone button strip, and the scale list editor.
- `Tarabdaar/Tarabdaar/PitchPadView_iOS.swift` — `FretPadViewIOS` +
  `FretPadSurfaceIOS` (perform-only surface, per-touch snap offsets) +
  `DroneStripIOS` (the 3 drone buttons, right edge, upper quarter).

Editing and Mac-side persistence stay Mac-only
(`FretArrangements/_Current.json` under Application Support); the iPad only
receives and performs.
