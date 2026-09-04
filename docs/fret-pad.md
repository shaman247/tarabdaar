# Fret Pad

The **Fret Pad** is the **sole playing surface** — the Mac's Fret Pad tab
(⌘3) and the iPad's only surface. Each enabled scale degree appears as one
or more vertical **line segments (frets)** that are **freely positioned**:
a fret's `x` (0..1 across the base band) is its own layout state, unrelated
to its pitch. The playable pitch is a continuous **field** interpolated
from the frets.

## The pitch field

- A **column** = the frets sharing an x position (within `fretColumnEps`
  ≈ 0.5 px) — stack two frets and they form one. A column's pitch at the
  touch's y (`fretColumnLog`): **inside** a member fret's vertical extent →
  exactly that fret's pitch; **between** two stacked frets → a
  y-interpolation across the gap; **above/below** all → clamped to the
  nearest one.
- The field at the touch = the **log-pitch x-interpolation between the two
  closest columns** (`fretFieldLog`). Beyond the outermost columns the line
  through the outermost **pair extrapolates**, so the edges keep the local
  slope (a single-column layout holds its pitch everywhere).

Dragging right of S plays S at S's line, r at r's line, and the log-pitch
curve between them — pitch always moves toward the neighbour you're
dragging at. The field is continuous everywhere: onset snapping only adds a
constant offset, drags follow the field, and the drag assist is
slew-limited and additive on top.

## Pitch warp

**`ctl_fret_warp`** ("pitch warp", the "Fret pad" registry group; the Mac
toolbar's **Warp** slider edits the same value, 0…100 %) reshapes every
fret-to-fret interpolation — the x-blend between columns AND the y-blend
across a stacked gap — through a **normalized logistic** (`fretWarp`):

```
w(t) = (σ(g·(t−½)) − σ(−g/2)) / (σ(g/2) − σ(−g/2)),   g = 14 · warp
```

At 0 it is exactly the identity (bit for bit); as it rises, pitch
**plateaus around each fret and transitions quickly through the middle of
the gap**. The law is pinned at w(0)=0 / w(1)=1 (frets stay exact),
symmetric (the **midpoint between two frets never moves**, so the territory
boundary is warp-invariant) and monotone, so the field keeps its continuity
guarantees; the extrapolation beyond the outermost columns stays linear. At
the top (g = 14) the center slope is ≈ 3.5× linear and the quarter-gap
point sounds ≈ 3 % of the interval instead of 25 %.

The amount is a **live control param** (`.live`, def 0), not layout state.
Like `ctl_strike_window` it never reaches the voice:
`AppController.applyParamToVoice` intercepts the key, publishes it for the
Mac surface (`AppController.fretFieldWarp`) and relays it to the iPad in
the **JOYCON_STATE frame** (`fieldWarp`), where `FretPadSurfaceIOS`
resolves every touch onset/move through it (0 = linear while the link is
down). It is **performable**: bind it to a tilt/stick axis and the pad
morphs mid-phrase — stick at rest = the linear meend-friendly field, stick
pushed = a near-quantized field for fast runs. Touch pitch is evaluated
iPad-side at event rate, so a warp change retunes a MOVING finger
continuously; a still finger keeps its pitch until it next moves. The
resting value persists with the control defaults and in presets; it is
deliberately NOT in the arrangement blob or the layout files. The glide
queue's segments are shaped by the same law — [Glide System](glide-system.md).
Guard: `FretWarpTests`.

**Contour overlay (Mac, edit mode).** Out of Perform mode the Mac surface
draws the field's **iso-pitch contours** (`fretFieldContours`): the
**territory boundaries** — log-midpoints between adjacent sounding pitches
— at white 0.28, quarter-pitch minors at white 0.10. Between plain columns
a boundary is vertical; through a stacked column's blend zone it curves.
The minors show the warp: at 0 they sit at the linear quarter positions, as
Warp rises they bunch against the boundaries. Solved exactly per scanline
(`fretWarpInverse`). Perform mode and the iPad draw no contours.

## Onset snapping

- **Start within the Snap distance (px) of a fret AND inside its vertical
  extent** → the note snaps to that fret's exact pitch (nearest in x wins).
- **Start elsewhere** (above/below an extent, or open space) → no snap; the
  note plays the **field** pitch. This is the approach path.
- **Drags never re-snap.** The pitch follows the field at the cursor,
  offset by the constant `log2` delta captured at a snapped onset
  (`snapOffsetLog`), so vibrato/meend move relative to the exact onset
  pitch with no discontinuity. The offset is bounded by the snap distance
  and clears on note-off.
- **Snap = 0** disables snapping.

The Snap slider is `engine.marginPixels` (0–64 px); the Fret Pad's default
is **24 px** (set in `AppController.init`, not the engine's shared 16) —
~60 % headroom over real iPad onset errors, under the default layout's fret
gap.

## Drag assist (magnetic inflections)

**`FretTouchPlayer`** (TarabdaarCore) is the touch pipeline both surfaces play through — onset (snap or field), drag, release and the 60 Hz settle tick, with the per-touch snap offsets, the assist and the stroke recorder behind it; a surface keeps only its pointer model and its overlays. **`FretDragAssist`** (TarabdaarCore) handles the stroke after onset.
Premise: when the player **stops or changes direction** near a scale pitch,
that inflection was intended to be *on* the pitch; while the finger is
moving — at **any** tempo — they're gliding and must be left alone.

A **gated magnetic correction**, continuous by construction. Each touch
carries one slew-filtered `correction` (log2 units);
`played = field + onsetOffset + correction`, and the correction eases toward
the nearest qualifying fret at a rate = **gate × proximity × settle**:

- **gate = min(1, max(stopped, turnGain·impulse))** — "stopped" is a
  genuine **stop detector**: the touch must dwell within `stillRadiusPx`
  (2 px) of a still anchor for `stopDwellMin` (100 ms) before the gate
  opens, ramping to 1 over `stopDwellRamp` (150 ms). A sustained drag —
  however slow — keeps leaving the still disc and restarting the clock, so
  the magnet never touches a glide; jitter stays inside the disc, so rests
  engage it. Fast connected playing turns in ~30 ms — too fast for any
  dwell — so a causally-detected **direction flip** (deadbanded dx sign
  change) fires an impulse that holds the gate open while it decays
  (`turnGain` 2.0, `turnTau` 26 ms → pinned at 1 for ~18 ms). A smoothed
  speed estimate (`speedFloor` 59 / `speedCeiling` 375 px/s, `speedTau`
  26 ms) serves only the receding check and the shed below.
- **proximity** — the fret must be within the **assist basin** =
  `radiusScale` × Snap (1.75× = 42 px at the default Snap — landings are
  far sloppier than onsets), measured in **screen px** to the fret line's
  x, and its extent must contain the touch (above/below stays free; Snap =
  0 disables assist). Pull is full inside half the radius, fading to 0 at
  the edge.
- **settle** — `settleTau` 5 ms, but the governing rate is the hard **slew
  cap ≈ 1500 ¢/s** on the correction: smoothness is guaranteed by
  construction, whatever the constants.

**Every touch is born stopped**: the gate starts fully open at onset, so a
sloppy landing, staccato tap and legato strike alike snap onto the fret
immediately (slew-capped, ~30–50 ms for a typical 30 ¢ error). The first
≥`stillRadiusPx` of movement re-anchors and shuts the gate, so a touch that
becomes a glide is left alone from its first events; approach-path starts
have no magnet candidate at all.

A candidate the touch is **actively receding from** exerts **no pull** —
the magnet corrects approaches and rests, never fights an escape. When no
pull qualifies, a **stationary** touch keeps its correction **frozen** (a
microtonal hold doesn't drift) while a **moving** touch **sheds it with
distance travelled** (1/e per `correctionDecayPx` = 12 px, under the slew
cap), so a glide away from an assisted landing converges on the raw field
pitch however slow the tempo. The output is always the slewed state, so no
event (candidate switch, zone entry/exit, speed spike) can produce a pitch
discontinuity. Since stops emit no move events, a ~60 Hz timer runs while
touches are down (both surfaces), feeding `tick(time:)` → `engine.glide`.
The assisting fret glows with the gate. Fully per-touch on the iPad. Guard:
`FretDragAssistTests`.

**Fitting.** The constants are fitted to recorded strokes, not hand-tuned.
**Rec** (Mac toolbar) / **REC** (iPad toolbar) appends each stroke to a
JSONL session (`FretGestureRecorder`, record v2: events
`[t, x, y, u, o, tick]` — `u` the uncorrected log2 pitch, `o` the pitch
played — plus a context snapshot of fret pixels, pitches, extents, Snap and
the live params), in `~/Library/Application Support/Tarabdaar/FretRecordings/`
on the Mac and the app's user-visible `Documents/FretRecordings/` on the
iPad. **The iPad fit is the one that matters** — glass differs from mouse.
`python3 tools/fretpad_fit.py report <files>` gives stroke stats and a
**parity check** (a causal Python replica vs the recorded `o` — only trust
fits when parity is tight; recordings made under other assist rules replay
with elevated parity, so re-record before refitting); `fit <files>` labels
intent with hindsight (dwells ≥ 90 ms, velocity reversals) and fits the
constants to dwell-end error + 15·settle-lag + 0.7·reversal error +
2·transit transparency, weighted perceptually (inverse output-pitch
velocity around each turn; a 120 ms post-turn guard); `--phrase "p n d n …"`
aligns inflections to a known svara sequence by monotonic DP; `selftest`
runs synthetic strokes. The hindsight thresholds define "truth" and are not
fitted. Fitting rounds: `docs/history/`.

## Touch indicator: the fingertip radius

Each touch draws one **indicator ring**, and the ring's SIZE is the raw
fingertip radius (`UITouch.majorRadius` × 2 px, clamped 16–120 px; a ~23 pt
fingertip draws the historic 46 px circle). Beside it the radius itself is
printed in points, to one decimal — the signal in the raw, so the
`Config.touchSizeLoPt`…`touchSizeHiPt` window (31.3 → 73.0 pt) can be
judged by eye while playing. Colour is playing state: cyan while the
finger glides, amber whenever the stop detector holds
(`FretDragAssist.Output.stopGate`, and every touch is born stopped).
Outside the ring, a **violet arc** draws that finger's **`.touchSize`
axis** — the 0…1 value the Mac's bindings see, the finger the estimator
reads behind the quantised radius — clockwise from 12 o'clock: nothing at
rest, a closed circle at full. The iPad runs its own display-only
`TouchSizeTracker` for it (see [sensors.md](sensors.md)), so no wire
traffic is added.

Display-only (`TouchIndicatorModel` + `TouchIndicatorLayerIOS`); the Mac
preview pad has no such overlay. A ~30 Hz ticker advances every touch's
estimator while anything is down, because UIKit only reports a finger
that moves.

**Not on this overlay** (removed 2026-09-04): the `original → corrected`
pitch-correction readout and the accelerometer strike ripple + 0–127
number. Both signals survive in the toolbar scopes — the strike scope and
the finger-accel scope — which are unaffected.

## Layout

The editable **base** frets live in a central **band**; the surface
extends `ghostExtentOctaves` band-widths (default **0.5**; 0–2 in 0.25
steps, toolbar "Octave ±") past it on each side, tiled with read-only
**octave-repeat ghost copies of the whole base layout** — left an octave
down, right an octave up — drawn faint in edit mode. The surface spans
`1 + 2·extent` band-widths; pixel x is `(x + shift + extent) / span · width`
(`fretPixelX(forBandX:)`).

### C Keyboard — the default

`FretLayoutPreset.keyboard` is the **default layout**: a fresh install's
starter, the never-synced iPad's fallback, and what the toolbar's **"Reset
to Scale"** builds from the current scale. **7 evenly-spaced columns**, one
per svara — `x = (col + 0.5)/7` for S · R/r · G/g · m/M · P · D/d · N/n —
so the naturals are spaced like white keys and each komal/tivra fret
**stacks above** its shuddha partner:

- **S and P**: centred (y 0.324–0.676)
- **shuddha** (R G m D N): lower middle (y 0.588–0.892)
- **komal/tivra** (r g M d n): upper middle (y 0.108–0.412)

The 0.176 gap inside a stacked pair is the column's **y-interpolation zone**
(sliding down bends r → R); the space toward the edges is open approach
room. The drag-assist constants are fitted on this layout.

### C Equal Freq — the other built-in

`FretArrangement.defaultArrangement` (the name is historic; Layout menu →
Built-in) is **pitch-aligned**: a fret's `x` is `log2(ratio)` — position
IS frequency — so the base band spans one octave, the tonic sits at its
left edge, the ghosts tile the ribbon continuously and the field along any
horizontal line is a straight log-pitch ramp. Two **separated tiers**,
ordinary frets the **same height** (0.352), **S and P as long keys**:
komal/tivra upper tier (y 0.108–0.460), shuddha lower tier (0.540–0.892),
P 0.510–0.912, S 0.470–0.912. No y belongs to two tiers (0.460–0.470 /
0.510–0.540 is open approach space). Nothing stacks, so on the default JI
scale fret spacing is 35–56 px and adjacent assist basins (42 px) overlap
within a tier — the assist takes the nearest qualifying fret, so the magnet
is live nearly everywhere along a tier. Segments draw 1.5 px base / 1 px
ghost with a 2.5 px-half-width sounding glow.

### Saving layouts

Layouts are **their own saved state**, independent of the scale — a layout
loads onto whatever scale is active, and a degree the scale lacks skips its
fret. The **Layout** menu mirrors the Scale menu: *Save As…* (name prompt,
no file panel), *Save "name"*, **Built-in** (C Equal Freq · C Keyboard,
generated from the current scale), the saved layouts with a checkmark, and
*Delete*. Loading panics the fret engine first. (The Scale menu's **Reset
to Default** is the full factory reset: bundled default scale AND C
Keyboard rebuilt from it.) Layouts are one `<name>.json` each in
`Application Support/Tarabdaar/FretArrangements/`, the same format as the
autosave `_Current.json` (hidden from the menu, refused as a name); copy a
file in and it appears. Built-ins are code, not files. Guard:
`FretLayoutTests`.

### Naming

A fret's pitch is a `degreeIndex` into the enabled scale degrees, looked up
live (`fretRatio`), so re-tuning the scale re-tunes the pad; a degree that
disappears skips its fret. **A fret is named by the scale**: the scale
point's own `label` (`PitchPoint.displayLabel`, or the ratio when blank)
via `scaleLabel(degree:octave:degrees:)`, with `'`/`,` octave marks on the
ghosts. The default scale reads `S r R g G m M P d D n N`; another scale
speaks its own labels ([Scales & Tuning](scales-and-tuning.md#playing-scale-tarabdaarmac-fret-pad-tab--ipad)).

## Editing

Edit mode is the default; **Perform** hides the band gridlines, labels,
endpoint handles and the scale editor, styling ghosts like base frets.

- **drag an endpoint handle** — set that end of the extent (min height 0.02)
- **drag the line** — move the segment in any direction (height preserved;
  x clamped to the base band)
- **shift-click empty space** — add a 0.15-tall fret on the degree nearest
  the field pitch there (multiple segments per degree allowed)
- **right-click** — delete
- **drag empty space** — play (grabbing a fret sounds its exact pitch)

The Mac surface's emitter is a `PitchPadEngine` (`AppController.fretPad`,
in-process `init(audio:)`, tonic kept in step with `pitchPad`); each fret
is a thin-rectangle `VoronoiCell` (`fretFillCells`) so the snapped fret
glows.

## Octave shift

Joy-Con dpad ←/→ step `PitchPadEngine.octaveShift` ±1 (clamped ±3,
`AppController.shiftOctave`), relayed as the JOYCON_STATE `octave` byte;
the iPad mirrors it into its own pad engine — the ONE outbound-pitch point
— so touches transpose while the field, snapping and assist are untouched.
**Onset-captured per touch**: a sounding note keeps its birth octave
through every glide; only the next onset takes the new range. Both
toolbars show the offset ("Oct +1", dim at 0). Drones, the tarab and the
strum deliberately do NOT shift. Not persisted.

## Drone buttons

Three **press-to-sound drone buttons** sit along the right edge around the
upper quarter on **both** surfaces. They live **inside the playing
surface** (`droneButtonRects`, one shared rect function for both platforms'
visuals and hit-tests): a touch is a drone press only when its **onset**
lands in a rectangle, hit-tested in the surface's own touch handler — never
via SwiftUI gestures. Everything around and below plays normally; melody
drags that cross a button keep gliding.

**Hidden while a Joy-Con is attached (both surfaces):** the controller
plays the drones (**↓** = drone button 2; ←/→ = octave shift; **L** = the
strum), so the on-screen buttons vanish — visual and hit-test — and
reappear on disconnect. Mac: the surface taps only
`JoyConInput.$connectedName` (observing the whole object would re-run the
surface at stick rate). iPad: the `connected` bit (bit 2) of the
JOYCON_STATE flags byte, pushed on attach/disconnect and with every
scale-sync push (`ScaleSyncReceiver.joyConTilt.connected` →
`FretPadSurfaceIOS.dronesHidden`). A drone held at attach still releases.

**Voice.** The buttons drive the **Tanpura voice by default** — a press
*plucks* the mapped pitch (`TanpuraEngine`, [tanpura-voice.md](tanpura-voice.md)),
holding re-plucks every `tp_drone_cycle` s, release rings out on the
string's t60. The **Strings tab's "Drone buttons" section holds the Voice
picker** (`AppController.droneVoice` → `AudioEngine.setDroneVoiceMode`);
**Sympathetic strings** swells the mapped String-voice jawari-taraf row
instead. Mapping, labels and signal path apply to both modes.

- **Mapping**: each button plucks **ONE sympathetic string**, mapped in the
  Strings tab (`InstrumentState.droneStringIds`, 3 × optional
  `StringSpec.id`, persisted with the instrument document; nil = inert). It
  sounds exactly as its tarab row is tuned; a disabled row, or one below
  the jawari selection's `bow_jt_gmin`, is silent. A press is an identity
  lookup on the row's nominal Hz (`BowEngine.droneRow(forExactHz:)`).
  **Auto-mapping**: fresh documents and every bank regeneration map each
  slot to the highest-gain enabled string within ±100 ¢ of low Sa · low Pa
  · Sa; manual mappings otherwise stick (a deleted row's mapping prunes to
  nil). Mapping changes don't rebuild — the buttons retarget
  (`AudioEngine.setDroneMappedFreqs`, releasing any held button first).
- **Labels**: `FretArrangement.droneRatios` is **display-only** — the Mac
  writes the mapped strings' sounding ratios vs the played tonic into the
  arrangement, so labels ride the autosave + iPad sync. A button is named
  like a fret (`scaleLabel(forRatio:degrees:)`, nearest degree in any
  octave). An unmapped slot keeps its last ratio.
- **Signal path**: both surfaces call `PitchPadEngine.setDrone(_:pressed:)`,
  which flips a held-state bit (`droneMask`) in the outbound TLP state frame
  — latest-wins and stuck-drone safe; multi-finger safe on iPad
  (refcounted). `LinkIngest`
  diffs the mask edges → `setDronePressed` → `BowEngine.dronePress/
  droneRelease` → the kernel's `bow_poly_jt_pluck` / `bow_poly_jt_drone` /
  `_drone_env` + `_drone_tone`, applied inside `jt_tick_string` so every
  path gets it and the unused path stays byte-null. Held drones re-arm
  after a structural rebuild (`reapplyHeldDrones`); a release skips rows
  another held button maps to.
- **Excitation** (sympathetic mode): a **slewed drive**, no impulse — the
  envelope swells over the attack time toward `level + onset boost`, the
  boost decays into the sustain, release drops the drive. The drive is
  `bow_drone_tone_mix` (0.5) sine **at the row's own mode-1 frequency** +
  band-passed noise (`bow_drone_lp_hz` 1600 / `bow_drone_hp_hz` 25 —
  sub-audio content would pump the jawari buzz). The pitched drive gives
  the ring the played tap's harmonic profile; pure noise rings the high
  modes harshly.
- **Kin spread**: a press drives the mapped row AND its **kin rows** through
  the same `recruitAffinity` lattice the recruitment axis (`bow_jt_sel`)
  uses: held row = 1, octaves/fifths/twelfths fall off by `(p·q)^-kin`,
  scaled by `bow_drone_spread` (0..1); the melody-follower row never takes
  spread drive; multiple held drones soft-OR. A drone tap wakes the taraf
  the way playing that note does.
- **Levels**: `bow_drone_level` 0.026 · `bow_drone_onset` 0.052 ·
  `bow_drone_attack_ms` 150 · `bow_drone_release_ms` 350 ·
  `bow_drone_onset_decay_ms` 500 — bp constants read in `BowEngine.init`,
  overridable from the Parameters tab (rise-to-90 % ≈ 310 ms).
  Calibration TARGET: **a drone tap = a fret tap at the same pitch**,
  matched on an A-weighted short-window peak (raw RMS undersells the gap;
  the level–ring curve turns superlinear past ~0.008). **Calibrate with ONE
  app instance running**, against a fresh pad tap. **A drone mapped to a
  DISABLED tarab string is inert by design** — check the mapped string
  first when a button seems dead.

## The strum (Joy-Con L / accel trigger)

Holding **L** sounds the Strings tab's strum SET — or the chord bar's
selection — as a **held chord in the MAIN voice** (`AppController.strum(pressed:)`
→ the shared `pitchPad` engine, the same in-process touch path as the Mac
pad: the notes follow the Live tab's instrument picker, allocate fresh
strings, charge the taraf, and carry a 0.9 strike velocity for
`bow_attack_vel`). It sustains while L is held and releases with it.
**`ctl_strum_expr`** is the chord's own expression — a per-note scale on the
chord notes' bow-expression axis (Tanpura/Sitar mains: the pluck level,
onset-only), bound to the **Joy-Con stick Y** by default and pushed live, so
the stick swells the ringing chord without touching the melody.
**`ctl_strum_thresh`** adds an accel trigger: the iPad's strike envelope
crossing the threshold strikes the chord exactly as L does and releases
below the SAME threshold, with a 100 ms retrigger cooldown against jitter
(default 1 = off; L ignores the cooldown). The configured set defaults to
low Sa · low Pa, remappable since members are scale-degree references. The
strum is exempt from the glide queue (`TLPTouch.glideExempt`).

## Chord bar

The strip **below the playable band** carries, per fret column, the roman
numeral of a 3-tone chord rooted on that degree, derived from the scale
(`ChordBar.swift`, shared by both surfaces). **Tapping a cell selects that
chord as what the strum plays**; tapping any cell of the selected degree
deselects, and with nothing selected the strum plays the configured set.

**Chords are OCTAVE-AGNOSTIC**: a chord is a pitch-class object — every
octave copy of the selected degree highlights, and the tapped cell's octave
normalizes to 0 (`toggleChordSelection` / `AppController.tapChord`). The
register is fixed by the **Shepard register law** (`shepardChordNotes`):
each chord tone's octave copies are weighted by a raised-cosine window over
log2 frequency, two octaves wide, centered on the middle of the **octave
below the tonic** — the two copies inside the support get complementary
weights summing to 1 (octave spacing shifts the cos² window by π/2), so
chord energy is root-independent and, as a progression walks up the scale,
the upper copy fades out while the lower fades in: a VII chord sits no
higher than a I chord. Weights drive the notes' per-slot expression scale
(× `ctl_strum_expr`); flanks under 0.02 are dropped (≤ 6 notes).

**A selection change lands immediately**: a ringing strum chord switches in
place (`AppController.retuneStrumChord` — members glide and take their new
weights with no new attack; a shrinking chord releases the surplus, a
growing one strikes the extras; deselecting mid-hold retunes to the
fallback set). Selection is performance state — never persisted, cleared
at launch, exempt from the octave shift.

**Derivation** (`scaleChords`): each degree's root joins the scale's best
**third** — any pitch class 250–450 ¢ above the root, classified to the
nearer of the just minor (316 ¢) and major (386 ¢) — and best **fifth**
(perfect 650–750 ¢, the pentatonic's 40/27 wolf included; diminished
550–650 ¢; augmented 750–850 ¢). Priority **major > minor > diminished >
augmented**, so the 12-tone scale offers all major chords. A missing member
is omitted, not faked (a lone root still gets a cell). **Numerals** map each
degree to I ♭II II ♭III III IV ♯IV V ♭VI VI ♭VII VII by nearest semitone
class, dropping the accidental when the scale holds no other class in that
ordinal family — natural minor reads **i ii° III iv v VI VII**. Case is
quality (upper major, lower minor, ° diminished, + augmented; third-less
chords stay uppercase). Guard: `ChordBarTests`.

**Layout** mirrors the frets (`chordBarCells`): one cell column per fret
column, repeated across the ghosts; a lone fret (S, P) takes the bar's full
height, stacked frets split it in band order. Taps are claimed at ONSET
only; nothing sounds until the strum plays.

**The selection crosses the wire as held state**: the pad's active chord
rides every PERF_STATE frame as `chordDegree`/`chordOctave` (0xFF = none;
`chordOctave` always 0, reserved), and the Mac acts on the CHANGE edges
(`LinkIngest.onChordSelect` — heartbeat repeats are silent, so an idle iPad
never clobbers a Mac-local selection). The Mac's own taps travel the
identical in-process path, so `AppController.strumChord` — what the Mac bar
highlights — is literally what the next strum sounds; the iPad highlights
its own outbound selection.

## On the iPad

TarabdaarMac edits, Tarabdaar performs: the Mac pushes
`AppController.ipadLayout = .fretPad` and the iPad shows `FretPadViewIOS`
(`Tarabdaar/Tarabdaar/PitchPadView_iOS.swift`).

**What syncs (Mac → iPad, one-way).** The layout travels as the TLP
`FRET_ARRANGEMENT` event (`FretArrangementSysEx` codec, blob **v6**:
`[ver][ghostQuarterOctaves][flags][count]` then
`[degreeIndex][x14: 2×7-bit][topY][bottomY][enabled]` per segment, then the
3 drone ratios as 14-bit cents-above-−1200; `flags` reserved, always 0),
beside `SCALE_STATE` whenever the arrangement changes. Pre-v6 blobs are
rejected → default. `ScaleSyncReceiver` decodes it into `fretArrangement`
(persisted by `FretArrangementSyncStore` for offline relaunch; a
never-synced iPad falls back to the keyboard layout built from the synced
scale). The synced `marginPixels` carries the Mac's **Snap**. The pitch
warp, octave shift, strike blend window and Joy-Con `connected` flag ride
JOYCON_STATE; the chord selection is the one iPad → Mac member of the
family. Wire: [MIDI & Audio](midi-and-audio.md).

The iPad surface is **always perform mode** and **fully multitouch** — each
finger gets its own onset snap decision and keeps its own `snapOffsetLog`.
The frets live in a **band** (`fretPadBandRect`): a full-width strip
spanning `Config.fretPadHeightFraction` (0.5) of the surface height,
centered, with a hairline border. The space above/below is dead except the
**drone buttons** and the **chord bar**. Both surfaces draw the whole
picture, and the Mac tab letterboxes to `iPadSurfaceAspect`, so **what you
see on the iPad is exactly what the Fret Pad tab shows**.

**iPad toolbar** (`PadToolbarIOS`): PANIC · REC · GYRO (raw-motion
diagnostic overlay) · scale-sync indicator · three display-only tilt squares
(arm, wrist, Joy-Con stick) · the **strike scope** (accelerometer strike
envelope, 0–127, its onset fade tracking `ctl_strike_window`) · the
**finger-accel scope** (the `.fingerAccel` −1…+1 law, computed locally —
[Sensors](sensors.md)) · the **volume scope** (the Mac's radiated voice and
taraf levels from the JOYCON_STATE volume bytes; flat while the link is
down) · sounding readout · octave-shift chip · read-only tonic · transport
indicators.

**Mac toolbar** (`FretPadView.swift`): Panic · Scale menu · Layout menu ·
Reset to Scale · Octave ± · Perform · Rec · sounding readout · Snap · Warp ·
Velocity · Prime ≤ (the scale editor's prime limit) · Tonic (a typed Hz
field + a note menu of the surrounding half-octave — see
[Scales & Tuning](scales-and-tuning.md#the-tonic-tarabdaarmac-fret-pad-tab)).

## Code map

- `Packages/TarabdaarCore/Sources/TarabdaarCore/FretPadGeometry.swift` —
  `FretSegment` / `FretLayoutPreset` / `FretArrangement`, `fretPadBandRect`,
  `droneButtonRects`, band↔pixel mapping, `fretPlacements`, the field
  (`fretFieldLog`, `fretColumnLog`, `fretWarp`), the contour solver,
  `fretSnap`, `fretGrab`, `fretFillCells`.
- `.../ChordBar.swift` — chord derivation, numerals, cells, the Shepard law.
- `.../FretTouchPlayer.swift` — the touch pipeline (onset · drag · settle · release).
- `.../FretDragAssist.swift` — the drag assist.
- `.../FretArrangementStore.swift` — `_Current.json` debounced atomic
  autosave, doc **v4** (older rejected → default; retired keys decode
  away); the named layouts (`savedNames` / `save` / `load` / `delete`) with
  menu actions on `AppController` (`loadFretLayout(preset:)` /
  `saveFretLayout(name:)` / `loadFretLayout(name:)` /
  `deleteFretLayout(name:)`).
- `.../ScaleSync.swift` — `PadLayout.fretPad`, the `FretArrangementSysEx`
  blob codec, `FretArrangementSyncStore`, `ScaleSyncReceiver.fretArrangement`,
  `JoyConTiltDisplay` (`fieldWarp`, `octaveShift`, `connected`,
  `strikeWindowS`, the volume readout).
- `TarabdaarMac/Views/FretPadView.swift` — the Mac tab: toolbar, Canvas
  surface, AppKit mouse capture, drone buttons, chord bar, `ScaleListEditor`.
- `Tarabdaar/Tarabdaar/PitchPadView_iOS.swift` — `FretPadViewIOS`,
  `FretPadSurfaceIOS`, `DroneStripIOS`, the toolbar and scopes.

Editing and Mac-side persistence stay Mac-only; the iPad only receives and
performs.
