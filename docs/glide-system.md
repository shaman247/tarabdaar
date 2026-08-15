# Glide System

> **Note.** The waypoint-queue / sigmoid system below is the **legacy
> keyboard** glide, which is no longer on the playing path (`NoteManager`
> runs only as the tilt/mapping host — see [Architecture](architecture.md)).
> The active playing surface, the **Fret Pad**, glides **directly**: the
> touch position resolves to a pitch (the fret field / onset snap) and
> `PitchPadEngine` writes it into the outbound state at full resolution —
> dragging glides smoothly without retriggering, and the pitch always
> tracks the finger. Since the TLP cutover (2026-08-14) there is no bend
> re-send loop: the wire carries at most one fresh state frame per sender
> tick, and continuity between updates is the Mac-side 9 Hz meend
> smoother's job (as it always was). See [Fret Pad](fret-pad.md).

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
