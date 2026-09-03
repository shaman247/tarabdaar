# Glide System

The instrument has TWO glide layers today:

1. **Direct finger glide** — the Fret Pad's native behavior: the touch
   position resolves to a pitch (the fret field / onset snap) and
   `PitchPadEngine` writes it into the outbound state at full
   resolution. Dragging glides smoothly without retriggering, and the
   pitch always tracks the finger. Since the TLP cutover (2026-08-14)
   there is no bend re-send loop, and since 2026-08-24 there is no
   Mac-side meend smoother — the String voice's filter ramps log2 f0
   linearly to the latest wire target within one render block, so all
   dragged meend is the finger's own trajectory at wire rate. See
   [Fret Pad](fret-pad.md).
2. **The GLIDE QUEUE (2026-08-31)** — queued glissandi across
   *overlapping touches*, below. **Off by default** (`ctl_glide_on` 0 =
   pure pass-through).

## The Glide Queue (2026-08-31)

`GlideSequencer` (`Packages/TarabdaarCore/.../GlideSequencer.swift`) is
a control layer in front of the voice routing: `AudioEngine` funnels its
public `touchOn`/`touchGlide`/`touchOff` through one instance, so every
touch source — iPad wire, Mac pads, the keyboard player, audition
`touchOn` scores — obeys the same law. The in-process MIDI path
(`sendHostedMIDI`, auditions' `noteOn`/`glide`, external controllers)
bypasses it entirely, so the parity substrate is untouched.

**The law — the OVERLAP rule.** With `ctl_glide_on` armed, a new onset
that **overlaps the sounding chain in time** — some member of the chain
(its resting owner, or a queued note) is still physically down — does
**not** mount a fresh string: it is queued as a waypoint, and the
sounding voice **glides** to it. Every overlapping onset joins the
queue and the trajectory hits each queued pitch **in sequence**. Once
every chained touch has lifted, the chain is over: the next tap is an
ordinary fresh attack, and **releases are never deferred** — a lone
tap's note-off lands the instant the finger lifts, so staccato
articulation is exactly the historic one. (The first cut gated
chaining on a `ctl_glide_thresh` time window with a release-grace
deferral; that sustained every staccato tap for the whole window and
was replaced by the overlap rule the same day — do not resurrect the
window.) Note the flip side: with the toggle armed, a second finger
landing while another is held always chains — overlapping-touch
polyphony is what the toggle trades away; switch it off (or bind it)
to play polyphonically.

- **Speed** — `ctl_glide_rate` semitones/second per segment,
  × `ctl_glide_held` (< 1, slower) while the touch being left is still
  held (deliberate expressive meend; lifting mid-glide snaps back to
  the full rate), × `ctl_glide_catchup` (> 1, faster) while the current
  target is not the **end** of the queue — the trajectory hurries
  through intermediate pitches to catch the player up.
- **Shape** — each segment runs through `fretWarp(progress,
  ctl_fret_warp)` in log-pitch space: linear at warp 0, logistic at 1 —
  exactly the curve a finger tracing between two adjacent frets would
  play on the warped field, so the pad's warp knob shapes queued glides
  and dragged glides with one law.
- **Overshoot & correction** — the run's *final* approach (nothing
  further queued) aims `ctl_glide_over` × the glide distance **past**
  the target (capped ±50 ¢), then settles back onto the exact pitch at
  a gentler rate (~0.3× the approach, floored at 60 ms) — the human
  player's land-and-correct, glide-backs included. Mid-queue arrivals
  never overshoot (the trajectory is hurrying and hits its waypoints
  dead-on), and a note queued mid-correction abandons the settle and
  glides onward from wherever the pitch is. The waypoint is consumed
  only at the settle, so ownership/release/glide-back semantics are
  untouched. Default 0.08; 0 = every glide lands exactly.
- **Releases** — a queued note released before the trajectory reaches
  it stays queued (the glide still hits its pitch), it just no longer
  holds the chain open; arriving on an already-lifted waypoint with
  nothing further queued releases the voice **on arrival**. A repeat
  tap at the chain's current pitch (±25 ¢, nothing queued) passes
  through as a real re-attack — a second finger can re-strike the
  sounding note.
- **Ownership** — after arriving at a waypoint, that waypoint's
  physical touch owns the sounding voice: its drags meend it and its
  release ends it, mapped onto the voice's original wire id (the voice
  layer never learns the queued ids). A queued finger dragging *before*
  the glide arrives retargets its waypoint live — the trajectory lands
  where the finger is.
- **Parked fingers & glide-back** — past chain members still down are
  *parked*: only the current owner's drags drive the voice, and a
  parked finger's movements are remembered **silently** (without this,
  the held first finger's wire id — the voice's own downstream id —
  fell through to pass-through and every wiggle yanked the pitch back:
  the two-finger oscillation bug, fixed same day). Releasing the owner
  while fingers are parked glides **back** to the most recent one, at
  that finger's *current* position, at the full released rate; parked
  fingers cascade most-recent-first, and only when every member has
  lifted does the bow come up. A parked finger lifting is silent — it
  just leaves the chain.
- **Exemptions** — the controller strum chord's members carry an
  in-process `glideExempt` flag (`TLPTouch`, like `exprScale`: never on
  the wire) so near-simultaneous chord onsets can never chain into a
  glissando. Drones are a different path entirely.

**Voice-agnostic.** The sequencer sits above the instrument routing, so
the plucked mains get it too: on the Tanpura/Sitar a queued onset
becomes a kernel-side bend of the ringing string instead of a fresh
pluck — a glissando without re-plucks.

**Not a legato revival.** The 2026-08-24 removal of the legato/steal
allocation laws stands: this is a queue *above* allocation. A captured
onset never becomes a note-on at all; every note that actually mounts
still gets a fresh string, and with the toggle off the sequencer is
byte-for-byte pass-through (the inert-default contract — parity guards
unaffected).

The five knobs live in the Parameters tab's **Glide** group (all
`.live`, per-note scope, tilt-bindable — a tilt on `ctl_glide_rate` is
the legacy keyboard's tilt-driven glide speed, reborn). Guards:
`GlideSequencerTests`.

---

> **Note.** The waypoint-queue / sigmoid system below is the **legacy
> keyboard** glide, which is no longer on the playing path (`NoteManager`
> runs only as the tilt/mapping host — see [Architecture](architecture.md)).
> It is the historical ancestor of the Glide Queue above (waypoint queue,
> sigmoid easing, tilt-driven speed) but none of its code is shared.

The glide system below controls pitch transitions on the **legacy
keyboard**. It operated in two modes: **tap glides** (waypoint queue with
sigmoid easing) and **drag glides** (continuous finger tracking with
exponential smoothing).

## Tap Glides: Waypoint Queue

Every note the player taps is added to an ordered **waypoint queue** (`PitchChannel.queue: [GlideWaypoint]`). The pitch visits each waypoint in sequence.

### GlideWaypoint

```swift
struct GlideWaypoint {
    let note: Int               // MIDI note number
    let timestamp: TimeInterval // when this waypoint was created
}
```

### Queue Operations

**`startGlide`** (called from `fireNote` when a new note arrives):
- Appends a waypoint to the queue
- If the pitch is at rest (progress = 1.0): calls `advanceQueue` to start gliding immediately
- If mid-glide: compresses the current glide's remaining duration to `glideMaxWait` so the queued note is reached promptly

**`advanceQueue`** (called when a glide completes or when starting from rest):
- Pops the first waypoint from the queue
- Sets `startFrequency` = current frequency, `targetFrequency` = waypoint frequency
- Resets `glideProgress` to 0
- Calculates duration: `glideTimePerSemitone * semitones^glideDistanceExponent`

**`touchEnded`** (when a finger lifts while others remain):
- If the remaining touch's note differs from the current target: appends a return waypoint
- If the remaining note IS the current target: no action (avoids redundant compression)
- Compresses current glide if a waypoint was added

### Mid-Glide Compression

When a new waypoint arrives while the pitch is still gliding to a previous target, the current glide is compressed so it finishes within `glideMaxWait`:

```
remaining_progress = 1.0 - glideProgress
time_left = remaining_progress * glideDuration
if time_left > glideMaxWait:
    glideDuration = glideMaxWait / remaining_progress
```

This ensures each waypoint is reached promptly without being skipped.

## Sigmoid Easing Curve

Each glide segment uses an asymmetric logistic (sigmoid) function for easing:

```
raw = 1 / (1 + exp(-k * (t - m)))
eased = normalize(raw, from=[sigmoid(0), sigmoid(1)], to=[0, 1])
```

- `k` (Glide Curve parameter): controls the steepness of the S-curve, dimension-mappable (default 3–12)
- `m` (`Config.glideMidpoint`): shifts the inflection point left for faster onset

The eased value is applied in **log2-frequency space** so equal musical intervals correspond to equal perceptual distances:

```
logCurrent = logStart + (logTarget - logStart) * eased
frequency = 2^logCurrent
```

## Glide Duration

Duration is a function of pitch distance and tilt:

```
semitones = |12 * log2(targetFreq / currentFreq)|
scaledDistance = semitones^glideDistanceExponent
duration = glideTimePerSemitone * scaledDistance
```

- `glideDistanceExponent` (0.6): sublinear scaling. A 12-semitone glide takes less than 12x a 1-semitone glide.
- `glideTimePerSemitone`: dimension-mapped (Glide Speed parameter, default 20–200 ms/st).
- `glideTimePerSemitone`: interpolated from tilt. At full tilt down: 20ms/st (fast). At full tilt up: 200ms/st (slow).

## Release Grace Period

When all touches lift, the channel doesn't immediately go idle. A 50ms grace period (`releaseGracePeriod`) allows a new touch to connect as a glide rather than starting a fresh note. If no touch arrives within the window, the channel sends noteOff and goes idle.

## Drag Glides

When a single finger slides horizontally across the keyboard (past a 1/3 key-width threshold), drag mode activates.

### Continuous Tracking

The drag target frequency is set directly from the finger's x position (mapped to a continuous fractional MIDI note). The glide loop smoothly chases this target using exponential smoothing in log-frequency space:

```
logCurrent += (logTarget - logCurrent) * dragSmoothing
```

`dragSmoothing` is a dimension-mappable parameter (default 0.1–0.5). Snap smoothing uses 2× the base value, clamped to 1.0. This runs at 60Hz, producing smooth pitch curves that follow the finger without discontinuities.

### Direction Reversal Correction

When the finger changes horizontal direction (e.g., sliding up then back down), the system corrects the peak/trough to land on the nearest scale tone:

1. Detect direction change by comparing `dx` sign to previous `dragDirection`
2. Set `dragTargetFreq` to the nearest scale tone at the reversal point
3. Skip overwriting the target with the finger position for this tick
4. On subsequent ticks, the finger (now moving the other way) sets the target normally

The smoothing handles the correction naturally - no instant frequency jumps.

### White-Key Zone

When the finger is in the bottom 40% of the keyboard (`yFraction >= 0.6`), reversal corrections and stop-snaps only use white keys. In the upper 60%, all 12 semitones are available.

### Stop Snapping

When the finger stops moving (60ms idle, `dragSnapDelay`), the drag target is set to the nearest scale tone (white key or semitone depending on zone). The smoothing glides there naturally using `dragSnapSmoothing`.

Once snapped, the pitch stays locked until the finger moves at least 1/3 of a key width from the snap position. This dead zone prevents small finger jitter from breaking the snap, and matches the threshold used for entering drag mode in the first place.

### Snap on Release

When the finger lifts mid-drag, the pitch snaps to the nearest scale tone before the voice is released. The `releaseAfterSnap` flag on `PitchChannel` tells the glide loop to keep the voice alive until the snap converges (within 1 cent of the target), then release it. This ensures notes always end on a clean pitch.

The release grace period cooperates with snap-on-release: the grace timer skips its release if `releaseAfterSnap` is pending, deferring to the glide loop.

### Exiting Drag Mode

Drag mode clears when:
- The snap-on-release convergence completes (glide loop releases the voice)
- A tap-based glide takes over (`startGlide` sets `dragging = false`)

## Polyphony

`NoteManager` is **monophonic**, and always has been in practice: the
`polyphonicMode` toggle it carried had no UI and no writer anywhere in either
app, so its per-touch voice-allocation branches (`polyTouchEnded` /
`polyTouchMoved` / `polyDragState` / `polySnapTimers`) were unreachable. They
were deleted 2026-08-02 along with the flag.

Polyphony on the instrument is `PitchPadEngine`'s, not this class's — the Fret
Pad gives every `touchId` its own MPE channel with no mode switch at all (see
[Architecture — Polyphony](architecture.md#polyphony-ipad)). `NoteManager`
itself now only drives the 60 Hz tilt report plus the audition scripts'
`noteOn`/`glide` path.
