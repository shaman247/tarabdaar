# Fret Pad

The **Fret Pad** is the **sole playing surface** — the Mac's Fret Pad tab
(⌘3) and the iPad's only surface. A layout is a list of `(degreeIndex, row)`
pairs. Rows count upward from **1 bottom to 15 top**. Fifteen adjacent rows fill
the playable band without overlapping; every fret has height `1 / 15`
of the band. Both surfaces use pure black row backgrounds. The Mac shows
horizontal row separators and vertical scale-pitch guides; the iPad shows only
the colored frets, without gridlines. The x coordinate is always `log2(ratio)`,
resolved from the scale degree. Each row has its own horizontal pitch field,
snapping and correction.
Existing layouts retain their assignments in rows 1–9; the six additional
rows above them start unassigned. The band expands upward with its bottom
edge fixed, reserving space above for the Mac's taraf strip.

## Taraf pluck strip

A 64-point strip immediately above the playable fret band shows only the
running raga taraf strings on the Mac, low pitch to high pitch. The iPad
has no taraf pluck or strumming strip.
The strip aligns with the fret band's left edge inside the pad surface and
spans its full width. Each orange
target carries its scale-derived name and one-based kernel row number;
chromatic rows are omitted. Tap for a single pluck;
drag either way to strum every
crossed string. A fast drag visits intermediate cells even when input events
skip them. Holding still does not re-pluck; reversing direction plucks strings
again as they are crossed. The strip remains available with a Joy-Con attached.
Melody touches on the pad remain independent.

These gestures directly call the row pluck path, regardless of the selected
main or drone voice. They need no drone-slot assignment. Each target is a
running raga kernel row, retaining its identity in the full bank snapshot.
An engine rebuild publishes a new bank identity and cancels the old gesture;
late plucks for that old bank are ignored. Mac gestures use the revision-checked
pluck entry point directly. The TLP bank snapshot and `TARAF_PLUCK` event remain
in the wire contract, but the iPad has no UI that emits plucks. Guards:
`TarafStripTests`, `TLPCodecTests`.

## The pitch field

Each of the fifteen regions interpolates log-pitch between its own adjacent
assigned frets, with linear extrapolation beyond its outermost pair. Warp,
onset snapping and drag correction use that same fret set. Assignments in
one row do not add or remove anchors in another row.

Onset offsets and slew-filtered corrections are independent per region. Near
each boundary, the complete pitches of the two touching regions blend in
log-frequency, including their onset offsets and carried corrections. The
blend follows `t²(3−2t)`, with zero slope at both ends. Its width is 15% of one
row's height, centred on the boundary: 7.5% lies on either side. Each row retains its own field outside these boundary blends. The blend adds no time delay or new snap on crossing.
Mac fret highlights follow the same spatial blend.
At warp zero with no snap offset
or correction, regions with at least two pitches share the uniform log-frequency
axis. An empty row follows that unwarped axis and has no snap or correction.
A region with one visible pitch holds it outside the boundary blends. An entirely empty layout has no
playable field. Vertical drags beyond the pad retain the outermost region.

## Pitch warp

**`ctl_fret_warp`** ("pitch warp", the "Fret pad" registry group; the Mac
toolbar's **Warp** slider edits the same value, 0…100 %) reshapes each region’s horizontal fret-to-fret interpolation through a **normalized logistic** (`fretWarp`):

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

Every assigned fret participates in warp, snapping and correction, independently
of sympathetic-string membership. Unassigned gray candidates in the Mac editor
are display and hit-test targets only; they never enter a playing region.

The amount is a **live control param** (`.live`, def 0), not layout state.
Like `ctl_strike_window` it never reaches the voice:
`AppController.applyParamToVoice` intercepts the key, publishes it for the
Mac surface (`AppController.fretFieldWarp`) and relays it to the iPad in
the **JOYCON_STATE frame** (`fieldWarp`), where `FretPadSurfaceIOS`
resolves every touch onset/move through it (0 = linear while the link is
down). It is **performable**: bind it to a tilt/stick axis and the pad
morphs mid-phrase — stick at rest = the linear meend-friendly field, stick
pushed = a near-quantized field for fast runs. Both surfaces re-evaluate
every held touch at its latest position whenever warp changes, including
stationary fingers at glide endpoints. The update glides the existing note
through the new field, preserving its onset offsets, octave and the drag
assist's correction and motion history; it never triggers another attack.
Subsequent settle ticks use the refreshed field pitch. The
resting value persists with the control defaults and in presets; it is
deliberately NOT in the arrangement blob or the layout files. The glide
queue's segments are shaped by the same law — [Glide System](glide-system.md).
Guard: `FretWarpTests`.

## Pitch accent

**`ctl_fret_accent`** ("pitch accent", the "Fret pad" registry group, def
0) is the warp's sounded counterpart: the played **expression dips between
frets** and returns as the finger lands on one, so a glided run keeps its
notes distinct even where the field is linear. The grid is the **frets on
the pad** — the arrangement's segments resolved against the one
scale and folded into an octave, so it covers every octave copy — and not
the whole scale: dragging D → E → F♯ across three frets dips once per gap
and never spikes at a D♯ or F the scale holds but the pad does not show.
The law (`FretPitchGrid`, `PitchAccent.swift`) takes the touch pitch's
position `t` (0…1) in the gap between its two neighbouring frets, the
pad's own uneven gaps and never a 12-TET grid, and scales the commanded
expression by

```
1 − accent · sin²(π·t)
```

0 on every fret, `1 − accent` midway, flat at both ends (a vibrato around
a note barely dips). It only ever attenuates: a note ON a fret sounds
exactly as the player's expression commands at every amount, and at 1 the
bow fades out through the middle of a gap.

It is a live control param that never reaches the wire or the iPad:
`applyParamToVoice` hands it to `AudioEngine.setPitchAccent`, and the
engine folds the accent at the touch's current pitch into the **per-touch
expression scale** the strum chord already uses (`effectiveExprScale` =
strum scale × accent). On the String voice a pitch move delivers the new
scale in the same mapper update as the pitch (`BowControlMapper.touchGlide`
with `exprScale`), so the dip rides the finger at wire rate and the
control filter ramps it across each block; the plucked mains consume it at
the onset as a pluck-level scale. The fret grid follows the arrangement
and tuning undebounced: `FretPitchGrid.publisher` combines the emitted
arrangement, scale, tonic and tonic-cents values directly, so each edit
rebuilds the grid from the new values immediately. Both a grid move and
a knob move re-deliver the scale to every held
note, so a bound tilt/stick axis works mid-phrase. Guard: `PitchAccentTests`.

**Scale-pitch grid (Mac only).** Faint vertical lines span the playable
band at every enabled scale pitch, including all visible octave copies and
pitches with no assigned frets. Their x positions follow the scale's exact
log-frequency coordinates. The grid is visible in both Edit and Perform modes.
Ordinary lines use opaque 10% gray; tonic octave lines use slightly brighter
13% gray. Horizontal separators between rows use the same 10% gray over
the pure black band. Colored fret segments draw over the grid. The playable
band has no enclosing border.

## Onset snapping

- At onset, each region snaps to its nearest assigned fret within the Snap
  distance. Outside that distance it uses its field pitch.
- Overlaps snap against the union. Near a boundary the touch blends the two
  adjacent regions' snapped pitches.
- **Drags never re-snap.** Each region keeps its own onset offset; horizontal
  motion follows its field and vertical motion blends into another region's result.
  All offsets clear on note-off.
- **Snap = 0** disables snapping.

The Snap slider is `engine.marginPixels` (0–64 px); the Fret Pad's default
is **24 px** (set in `AppController.init`, not the engine's shared 16) —
~60 % headroom over real iPad onset errors, under the default layout's fret
gap.

## Drag assist (magnetic inflections)

**`FretTouchPlayer`** (TarabdaarCore) is the touch pipeline both surfaces play through — onset (snap or field), drag, release and the 60 Hz settle tick, with the per-touch snap offsets, the assist and the stroke recorder behind it; a surface keeps only its pointer model and its overlays. **`FretDragAssist`** (TarabdaarCore) handles the stroke after onset.
Premise: when the player **stops or changes direction** near a scale pitch,
that inflection was intended to be *on* the pitch; while the finger is
moving beyond the pause radius before its delay elapses, they're gliding
and the pause gate stays closed.

A **gated magnetic correction**, continuous by construction. Each touch
carries one slew-filtered `correction` per region (log2 units);
`pitch = regionField + regionOnsetOffset + regionCorrection`. Each correction
eases toward that region’s nearest qualifying fret at a rate = **gate × proximity × settle**:

- **gate = min(1, max(stopped, turnGain·impulse))** — "stopped" is a
  genuine **stop detector**: the touch must dwell within `stillRadiusPx`
  (2 px) of a still anchor for `stopDwellMin` (100 ms) before the gate
  opens, ramping to 1 over `stopDwellRamp` (150 ms). A sustained drag —
  that leaves the disc within the delay keeps restarting the clock, so
  the pause gate stays closed; jitter stays inside the disc, so rests
  engage it. Fast connected playing turns in ~30 ms — too fast for any
  dwell — so a causally-detected **direction flip** (deadbanded dx sign
  change) fires an impulse that holds the gate open while it decays
  (`turnGain` 2.0, `turnTau` 26 ms → pinned at 1 for ~18 ms). A smoothed
  speed estimate (`speedFloor` 59 / `speedCeiling` 375 px/s, `speedTau`
  26 ms) serves only the receding check and the shed below.
- **proximity** — the fret must be within the **assist basin** =
  `radiusScale` × Snap (1.75× = 42 px at the default Snap — landings are
  far sloppier than onsets), measured in **screen px** to the fret line's
  x, using only assigned frets in that region (Snap = 0 disables assist). Pull is full inside half the radius, fading to 0 at
  the edge.
- **settle** — `settleTau` 5 ms, but the governing rate is the hard **slew
  cap ≈ 1500 ¢/s** on the correction: smoothness is guaranteed by
  construction, whatever the constants.

**Every touch is born stopped**: the gate starts fully open at onset, so a
sloppy landing, staccato tap and legato strike alike snap onto the fret
immediately (slew-capped, ~30–50 ms for a typical 30 ¢ error). The first
≥`stillRadiusPx` of movement re-anchors and shuts the gate, so a touch that
becomes a glide is left alone from its first events. Each region’s assist runs independently even while the touch is elsewhere,
so vertical travel blends between the regions' own correction histories.

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
The Mac assisting fret glows with the gate; the iPad draws no touch feedback. The assist remains fully per-touch. Guard:
`FretDragAssistTests`.

### Tunable assist

The **Controls · Fret assist** parameter group exposes the correction through
the usual sliders, direct axis bindings and composites. All ten controls
are live and per-note: each touch keeps its own correction, pause clock and
turn impulse. Existing defaults preserve the fitted behavior above.

| Parameter | Range | Default |
|---|---|---|
| `ctl_fret_assist_amount` — correction amount | 0–1 | 1 |
| `ctl_fret_assist_radius` — capture radius, × Snap | 0–4 | 1.75 |
| `ctl_fret_assist_still_px` — pause radius | 0.1–12 px | 2 px |
| `ctl_fret_assist_dwell_ms` — pause delay | 0–1000 ms | 100 ms |
| `ctl_fret_assist_ramp_ms` — pause ramp | 1–1000 ms | 150 ms |
| `ctl_fret_assist_settle_ms` — settle time constant | 1–500 ms | 5 ms |
| `ctl_fret_assist_slew` — correction speed limit | 50–6000 ¢/s | 1500 ¢/s |
| `ctl_fret_assist_turn` — turn pull | 0–4 | 2 |
| `ctl_fret_assist_turn_ms` — turn decay time constant | 1–500 ms | 26 ms |
| `ctl_fret_assist_release_px` — release distance constant | 1–96 px | 12 px |

Amount scales the target correction: 0.5 corrects half the error, 1 can
reach the fret exactly. At 0, a fresh touch passes through unchanged; any
carried correction on a held touch eases to zero under the settle time and
slew cap, even outside a capture zone. Onset snapping remains independently
controlled by Snap. Capture radius 0 admits no new target; it retains the
normal stationary-hold/moving-release behavior for an existing offset.
Turn pull 0 disables reversal capture while retaining pause capture.

The Mac owns parameter rests, persistence and all mapping evaluation.
`ParamTarget.fretAssist` updates the local pad and relays the resolved
`FretAssistSettings` in TLP's paced `JOYCON_STATE` frame. The iPad receives
only these values, with no bindings or editable copy of the parameters.
Both surfaces read the latest settings at every move and 60 Hz settle tick,
so a mapping can change a held finger's correction without another move.
Capture radius is recomputed from the current settings on each integration.
A stale/disconnected link restores the fitted defaults; a resync restores
the Mac's resolved controls. Both devices must use the same TLP version.

**Fitting.** The constants are fitted to recorded strokes, not hand-tuned.
**Rec** on the Mac Fret Pad toolbar records both the iPad and the Mac pad into one
JSONL session (`FretGestureRecorder`, record v7: events
`[t, x, y, u, o, tick, region1U, …, region15U]` — `u` the uncorrected log2 pitch, `o` the pitch
played; regions are the fifteen independent rows ordered bottom to top — plus a context snapshot of fret rows, pixels, pitches, extents, Snap and
the live params), in `~/Library/Application Support/Tarabdaar/FretRecordings/`
on the Mac. The iPad has no recording button and writes no recording files.
**The iPad fit is the one that matters** — glass differs from mouse.
The Mac owns the session even when another tab is selected. While armed,
`FretGestureCapture` on the iPad buffers each stroke's original pixel geometry,
move samples and settle ticks. Completed v7 records are compressed losslessly
and sent over TLP in paced chunks; the Mac reassembles and appends them to
`fret-strokes-<timestamp>-<UUID>.jsonl`. The count reports saved strokes.
Stopping Rec drops still-held partial strokes, then shows **Saving** until
completed transfers drain. A disconnect drops incomplete transfers, closes a
stopping session and clears iPad capture; an active Mac session rearms on
reconnection. Old session tokens, gaps and duplicate records cannot enter the
current file. Capture and transfer limits are documented in
[MIDI & Audio](midi-and-audio.md#fret-recording-events).

Version 7 replays fifteen equal-height rows and their boundary blends;
version 6 retains its nine-row geometry. For older
five-row recordings, replay derives overlap width from recorded fret heights.
Version 5 retains its overlap-union fields and boundary blends; older v4 recordings retain hard region
switches and v3 recordings retain three-row gap interpolation.
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
fitted. The context includes amount, slew limit and release distance as well
as the pause/turn controls. Fitting expects settings to stay fixed within
each recorded stroke; disable assist and warp mappings when recording fitting data.
Fitting rounds: `docs/history/`.

## Fret position mapping

The **Fret Position** control dimension runs from 0 at each fret’s inner
end to 1 at its outer end. Upper frets increase upward; lower frets increase
downward, normalized to each fret’s own height. Values clamp beyond the
ends and blend linearly between neighboring frets. The newest held finger
drives the mapping, including vertical movement at constant pitch; releasing
it falls back to the newest survivor, then to 0 when no touches remain.
See [Sensors](sensors.md) for the mapping path.

## Playing display

The iPad draws the static fret field without touch rings,
radius numbers, size arcs, sounding highlights or performance readouts.
Touch radius still travels over TLP and drives the Mac's Touch Size bindings.
Performance graphs and motion meters live on the Mac's Live tab; received
motion trails live in Setup. See [UI Layout](ui-layout.md).

## Layout

The editable **base** frets live in a central **band**; the surface
extends `ghostExtentOctaves` band-widths (default **0.9**) past it on each
side, tiled with read-only
**octave-repeat ghost copies of the whole base layout** — left an octave
down, right an octave up — drawn faint in edit mode. The surface spans
`1 + 2·extent` band-widths; pixel x is `(log2(ratio) + shift + extent) / span · width`
(`fretPixelX(forBandX:)`).

The Mac toolbar's **Octaves** slider controls the total span from **1 to 5
octaves**, in **0.1-octave** steps. The factory span is **2.8 octaves**;
increasing it fits more octave copies into the same surface width. The
setting is part of the arrangement, autosaved and synced to the iPad over
`FRET_ARRANGEMENT`, with the same range on both surfaces. Saved layouts
retain their explicit range; new built-ins, Reset to Scale and the
never-synced iPad fallback use the factory span.

### Factory layouts

**Default** is the active playing layout captured as the factory choice for a
fresh install, Reset to Scale and a never-synced iPad. It spans **2.8 octaves**
and has 39 independent assignments in rows 1–9. Rows 10–15 start empty in
every built-in layout:

| Row | Pitches |
|---|---|
| 9 | M d n |
| 8 | r M d n |
| 7 | r g d n |
| 6 | S r g P d n |
| 5 | S g P n |
| 4 | S R m P n |
| 3 | S R m P |
| 2 | R G m D N |
| 1 · bottom | G m D N |

**Pilu** remains a separate built-in alternative:

| Row | Pitches |
|---|---|
| 9 | r M d |
| 8 | r M d |
| 7 | empty |
| 6 | S g P n |
| 5 | S g P n |
| 4 | S g P n |
| 3 | empty |
| 2 | S R G m P D N |
| 1 · bottom | S R G m P D N |

Pitches resolve against the active scale; the usual chromatic classes assign
factory rows while the scale supplies the exact frequencies and labels.
C Keyboard, C♯ Keyboard and C Equal Freq retain their row-1 and row-9 assignments
and copy them into the adjacent rows 2 and 8. Every row is independently editable.
Retuning the scale updates each fret's pitch and x position.

### Saving layouts

Layouts are **their own saved state**, independent of the scale — a layout
loads onto whatever scale is active, and a degree the scale lacks skips its
fret. The **Layout** menu mirrors the Scale menu: *Save As…* (name prompt,
no file panel), *Save "name"*, **Built-in** (Default · Pilu · C Equal Freq · C Keyboard · C♯ Keyboard,
generated from the current scale), the saved layouts with a checkmark, and
*Delete*. Loading panics the fret engine first. (The Scale menu's **Reset
to Default** is the full factory reset: bundled default scale AND Default layout rebuilt from it.) Layouts are one `<name>.json` each in
`Application Support/Tarabdaar/FretArrangements/`, the same format as the
autosave `_Current.json` (hidden from the menu, refused as a name); copy a
file in and it appears. Version 9 stores only `degreeIndex` and `row` (1…15)
per assigned fret; absence means disabled. The octave span and drone display
ratios are arrangement metadata. Version 8 retains its row-1…9 assignments.
Version 7 maps its five rows to 1/3/5/7/9,
then fills rows 2/4/6/8 with the unions of adjacent odd rows. Version 6 first
maps its three rows to 1/5/9; versions 4 and 5 resolve their vertical
coordinates to those rows. Disabled entries are discarded. Formats older than
version 8 materialize the unions once; all older layouts leave rows 10–15 empty.
Complete `.tarabdaar` preset surfaces include `fretRowCount: 15`; older counts
and surfaces without that marker use the same migration. Built-ins are code,
not files. Guard: `FretLayoutTests`.

Named saves and `_Current.json` autosaves encode the complete JSON first,
then atomically replace the destination. They never remove the previous
file before writing its replacement.

### Naming

A fret's pitch is a `degreeIndex` into the enabled scale degrees, looked up
live (`fretRatio`), so re-tuning the scale re-tunes the pad; a degree that
disappears skips its fret. **A fret is named by the scale**: the scale
point's own `label` (`PitchPoint.displayLabel`, or the ratio when blank)
via `scaleLabel(degree:octave:degrees:)`, with `'`/`,` octave marks on the
ghosts. The default scale reads `S r R g G m M P d D n N`; another scale
speaks its own labels ([Scales & Tuning](scales-and-tuning.md#the-playing-scale-fret-pad-tab--ipad)).

## Editing

Edit mode is the default. It displays every enabled scale degree in all fifteen
rows, including octave copies. Assigned frets use their pitch color; unassigned
candidates are gray. **Perform** hides unassigned frets, labels and the scale
editor; the scale-pitch grid remains visible.

Pitch colors share an OKLCH hue wheel on Mac and iPad: S (`1/1`) is red at
30°, and each octave spans 360° in `log2(ratio)`, so octave copies keep the
same hue. Lightness and chroma are set by each display element.

The Mac shows one scale label per pitch column below the playable band,
centred under its frets. A label uses the pitch color when any row in its
column is assigned, otherwise gray; octave-copy labels retain their octave
marks and dimming.

- **Left-click a fret** in Edit mode toggles that pitch's assignment to that
  row. Clicking an octave copy changes the same base assignment.
- A click on a row boundary selects the nearer row centre; an exact tie
  selects the lower row.
- **Drag empty space** to audition the playing field. In Perform mode every
  left press plays and dragging glides.

Assignment changes autosave and sync to the iPad. They do not toggle or create
sympathetic strings. The Strings tab and instrument presets own those strings.
Right-click and modifier-click have no separate fret-editing behavior.

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
through every glide; only the next onset takes the new range. The Mac
toolbar shows the offset ("Oct +1", dim at 0). Drones, the tarab and the
strum deliberately do NOT shift. Not persisted.

## Drones (Joy-Con)

The Joy-Con controls three mapped drone slots. Both Fret Pad surfaces have
no on-screen drone buttons; the Mac's raga taraf pluck strip spans the full band
width regardless of controller connection.

**Drone sequence (Down / GL).** Joy-Con ↓ and rear GL share an on/off toggle.
Switching on plays the next configured drone slot immediately,
wrapping after the last step. The default is slots **1 → 2 → 3 → 3**:
Sa → Pa → high Sa → high Sa relative to the lowest drone (the bank labels
these low Sa · low Pa · Sa). In **Strings → Drones → Drone sequence (Down / GL)**, each step selects one of the three mapped drones; steps can be
added, removed, or reset. The step labels follow the mapped strings and scale.
While switched on, the sequence advances every **2 seconds**, even after the button is released. Each
step releases the previous slot and presses the next, including consecutive
steps on the same slot. Controller sequencing bypasses the Tanpura same-slot
`tp_drone_cycle` timer. The next fresh press of either button switches the sequence off, cancels
the timer and releases the current slot; button releases do not change it.
Switching on again resumes at the next step. Disconnecting also cancels
the timer and releases the current slot. A delayed
timer plays one step without a burst of missed notes. Calibration ↓ presses still
redo the previous phase and do not toggle or advance the sequence. Edits, preset
sequence loads and launch start at the first step. The Mac saves the pattern
across launches and in the optional `droneSequence` preset section; older
presets leave the current pattern alone. No sequence state crosses TLP.

Tanpura drones sound **one octave below** their mapped strings by default.
Joy-Con **↑** toggles to the original mapped octave and back; the next pluck
uses the selected register while ringing notes keep their pitch. It does not
advance or restart the sequence. The Strings tab shows **Tanpura octave −1 / 0**.
The register starts low each launch and is not saved in presets. During
calibration, ↑ still advances the capture. Sympathetic drones retain their
mapped row pitch.

**Voice.** The sequence drives the **Tanpura voice by default** — a press
*plucks* the mapped pitch in the selected drone register (`TanpuraEngine`, [tanpura-voice.md](tanpura-voice.md)),
each sequence step plucks once and release rings out on the
string's t60. The **Strings tab's "Drones" section holds the Voice
picker** (`AppController.droneVoice` → `AudioEngine.setDroneVoiceMode`);
**Sympathetic strings** swells the mapped String-voice jawari-taraf row
instead. Mapping, labels and signal path apply to both modes.

- **Mapping**: each drone slot plucks **ONE sympathetic string**, mapped in the
  Strings tab (`InstrumentState.droneStringIds`, 3 × optional
  `StringSpec.id`, persisted with the instrument document; nil = inert). It
  supplies the reference pitch; Tanpura applies the selected octave offset.
  In sympathetic mode it sounds exactly as its tarab row is tuned; a disabled
  row, or one below the jawari selection's `bow_jt_gmin`, is silent. That press
  is an identity lookup on the row's nominal Hz (`BowEngine.droneRow(forExactHz:)`).
  **Auto-mapping**: fresh documents and every bank regeneration map each
  slot to the highest-gain enabled string within ±100 ¢ of low Sa · low Pa
  · Sa; manual mappings otherwise stick (a deleted row's mapping prunes to
  nil). Mapping changes don't rebuild — the slots retarget
  (`AudioEngine.setDroneMappedFreqs`, releasing any held button first).
- **Labels**: the Strings tab names each mapped drone from its string and
  the scale's degree labels. The legacy `FretArrangement.droneRatios` and
  TLP `droneMask` fields remain compatible, but the pad UI does not display
  drone labels or emit drone presses.
- **Signal path**: `AppController.sequenceDroneButton` and its timer call
  `AudioEngine.setDronePressed` directly. The Joy-Con sequence bypasses the
  same-slot `tp_drone_cycle` timer. Sympathetic-mode presses resolve the
  mapped row through `BowEngine.dronePress` / `droneRelease`; held drones
  re-arm after a structural rebuild, and a release skips rows another held
  slot maps to.
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
  scaled by `bow_drone_spread` (0..1); multiple held drones soft-OR. A drone tap wakes the taraf
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
strings, charge the taraf, and capture the current
`bow_attack_sharpness`). It sustains while L is held and releases with it.
**`ctl_strum_expr`** is the chord's own expression — a per-note scale on the
chord notes' bow-expression axis (Tanpura/Sitar mains: the pluck level,
onset-only), bound to **Stick Up / Stick Down** by default and pushed live, so
the stick swells the ringing chord without touching the melody.
**`ctl_strum_thresh`** adds an accel trigger: the iPad's strike envelope
crossing the threshold strikes the chord exactly as L does and releases
below the SAME threshold, with a 100 ms retrigger cooldown against jitter
(default 1 = off; L ignores the cooldown). The configured set defaults to
low Sa · low Pa, remappable since members are scale-degree references. The
strum is exempt from the glide queue (`TLPTouch.glideExempt`).

## Chord bar

**Hidden for now** (`Config.chordBarShown = false`): `chordBarCells`
resolves to no cells, so neither surface draws or hit-tests it and the
strum plays the configured set. The rest of this section describes the
bar when it is on.

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
`FRET_ARRANGEMENT` event (`FretArrangementSysEx`):
`[ghostTwentiethOctaves][flags=80][columnCount]`, then `[degreeIndex][rowMask u16 LE]`
per assigned pitch, followed by three 14-bit drone display ratios. Mask bits
0–14 select rows 1–15; this fits every pitch/row assignment in one event without
truncating dense layouts. Flag bit 6 selects row masks and bit 4 selects
twentieth-octave flank units. The receiver derives x and the equal row height.
Cached nine-row blobs retain their assignments. Cached five-row, three-row and coordinate
blobs migrate their assignments and materialize the former overlap unions;
retired raga masks are ignored. Both live
peers must use the current matching protocol from [MIDI & Audio](midi-and-audio.md).
The arrangement travels beside `SCALE_STATE` whenever it changes.
`ScaleSyncReceiver` decodes it into `fretArrangement`
(persisted by `FretArrangementSyncStore` for offline relaunch; a
never-synced iPad falls back to the Pilu layout built from the synced
scale). The synced `marginPixels` carries the Mac's **Snap**. The pitch
warp, octave shift, strike blend window and Joy-Con `connected` flag ride
JOYCON_STATE; the chord selection is the one iPad → Mac member of the
family. Wire: [MIDI & Audio](midi-and-audio.md).

The iPad surface is **always perform mode** and **fully multitouch** — each
finger gets its own onset snap decision and keeps its own onset offset per region.
The frets live in a **band** (`fretPadBandRect`): a full-width strip
spanning up to `Config.fretPadHeightFraction` (0.7) of the surface height with
its preferred top at `Config.fretPadBandTopFraction` (0.1), without an enclosing
border. Short surfaces move the top down enough to reserve the 64-point taraf
strip; the bottom stays at 80% of the surface height. Both devices use the same
geometry. The space above/below
is dead except the **chord bar** when it is shown. The Mac tab letterboxes to
`iPadSurfaceAspect`, matching the iPad fret geometry; the Mac also shows the
taraf pluck strip, editing and sounding feedback.

**iPad status overlay** (`PadToolbarIOS`): “no sync” appears until the live link receives both scale and arrangement. Transport icons appear only while the link is unavailable or stale; the antenna opens BLE-MIDI advertising. Everything in this overlay disappears while synced and connected. Its visibility never resizes the playable surface. Recording, graphs, touch readouts, Panic and Gyro are absent.

**Mac toolbar** (`FretPadView.swift`) uses two rows. The first holds Panic ·
Scale menu · Layout menu · Reset to Scale · Perform · Rec · sounding
readout. The second holds Octaves · Snap · Warp · Tonic (a typed Hz field
and a note menu of the surrounding half-octave — see
[Scales & Tuning](scales-and-tuning.md#the-tonic-fret-pad-tab)).

## Code map

- `Packages/TarabdaarCore/Sources/TarabdaarCore/FretPadGeometry.swift` —
  `FretSegment` / `FretLayoutPreset` / `FretArrangement`, `fretPadBandRect`,
  band↔pixel mapping, `fretPlacements`, the field
  (`fretFieldLog`, `fretWarp`),
  `fretOnset`, `fretAssignment`, `fretFillCells`.
- `.../ChordBar.swift` — chord derivation, numerals, cells, the Shepard law.
- `.../FretTouchPlayer.swift` — the touch pipeline (onset · drag · settle · release).
- `.../FretPadSharedViews.swift` — row backgrounds, scale-pitch grid, fret strokes and shared overlays.
- `.../FretDragAssist.swift` — the drag assist.
- `.../FretArrangementStore.swift` — `_Current.json` debounced atomic
  autosave, doc **v9** (v4–v8 migrate; older rejected → default); the named layouts (`savedNames` / `save` / `load` / `delete`) with
  menu actions on `AppController` (`loadFretLayout(preset:)` /
  `saveFretLayout(name:)` / `loadFretLayout(name:)` /
  `deleteFretLayout(name:)`).
- `.../ScaleSync.swift` — `PadLayout.fretPad`, the `FretArrangementSysEx`
  blob codec, `FretArrangementSyncStore`, `ScaleSyncReceiver.fretArrangement`,
  `JoyConTiltDisplay` (`fieldWarp`, `octaveShift`, `connected`,
  `strikeWindowS`, the volume readout).
- `TarabdaarMac/Views/FretPadView.swift` — the Mac tab: toolbar, Canvas
  surface, AppKit mouse capture, chord bar, `ScaleListEditor`.
- `Tarabdaar/Tarabdaar/PitchPadView_iOS.swift` — `FretPadViewIOS`,
  `FretPadSurfaceIOS` and the connection-warning overlay.

Editing and Mac-side persistence stay Mac-only; the iPad only receives and
performs.
