# Glide System

The instrument has two glide layers:

1. **Direct finger glide** — the Fret Pad's native behaviour: a dragged
   touch's pitch tracks the finger; the String voice adds no shaping.
2. **The Glide Queue** — queued glissandi across *overlapping or closely spaced touches*
   (`GlideSequencer`). **Off by default** (`ctl_glide_on` 0 = pure
   pass-through).

## Direct finger glide

The touch position resolves to a pitch (the fret field / onset snap —
[Fret Pad](fret-pad.md)) and `PitchPadEngine` writes it into the
outbound state at full resolution: f32 fractional MIDI in every
`PERF_STATE` frame at ~120 Hz, no bend re-send loop
([MIDI & Audio](midi-and-audio.md)). Dragging glides without
retriggering.

On the Mac, every note-on mounts a **fresh string** (snap, fresh attack)
and within a note the String voice's filter ramps log2 f0 linearly to
the latest wire target across each render block. All dragged meend is
therefore the finger's own trajectory at wire rate; a steady pitch
renders bit-exactly, and the slide-texture / glide-dip trackers
([Sound Design](sound-design.md)) read the finger's true rate. There is
no Mac-side meend smoother, legato steal, mono-meend re-bow or note-off
glide-back (not present — see docs/history/). Vibrato is a playing
technique: move the finger.

## The Glide Queue

`GlideSequencer` (`Packages/TarabdaarCore/.../GlideSequencer.swift`) is
a control layer in front of the voice routing: `AudioEngine` funnels its
public `touchOn`/`touchGlide`/`touchOff` through one instance, so every
touch source — the iPad wire, the Mac pads, the Joy-Con strum — obeys
the same law. It is the only note path there is.

### Overlap and release grace

With `ctl_glide_on` armed, a new onset joins the sounding chain while
any member is physically held, or within `ctl_glide_grace` milliseconds
of the last physical lift. The grace defaults to **150 ms** and is
adjustable from 0 to 500 ms in the Glide parameter group. Zero accepts
only overlapping touches.

**Release is immediate.** The last finger lifts the bow at once, even
mid-trajectory. Grace remembers the released string and its last sounded
pitch; it does not sustain the note. A following onset inside the window
reopens the same string and glides from that pitch through the waypoints,
without resetting its waveguide or restarting its attack envelope.
Pending waypoints pause while released and are discarded when grace
expires. Expiry produces no additional sound or note-off.

An onset outside the window mounts a fresh string. A repeated pitch
(±25 ¢ with no queued waypoint) also re-attacks, including during grace.
Switching glide off or setting grace to zero forgets released chains;
Panic and link loss clear the entire queue. Exempt strum touches release
and re-attack directly. Overlapping-touch polyphony remains available
with glide disabled.

### The trajectory

- **Speed** — `ctl_glide_rate` semitones/second per segment,
  × `ctl_glide_held` (< 1, slower) while the touch being left is still
  held (deliberate expressive meend; lifting mid-glide snaps back to the
  full rate), × `ctl_glide_catchup` (> 1, faster) while the current
  target is not the **end** of the queue — the trajectory hurries
  through intermediate pitches to catch the player up.
- **Shape** — each segment runs through `fretWarp(progress,
  ctl_fret_warp)` in log-pitch space: linear at warp 0, logistic at 1 —
  the curve a finger tracing between two adjacent frets plays on the
  warped field, so the pad's warp knob shapes queued and dragged glides
  with one law.
- **Overshoot and correction** — the run's *final* approach (nothing
  further queued) aims `ctl_glide_over` × the glide distance **past** the
  target (capped ±50 ¢), then settles back onto the exact pitch at a
  gentler rate (~0.3× the approach, floored at 60 ms) — the human
  land-and-correct, glide-backs included. Mid-queue arrivals hit their
  waypoints dead-on; a note queued mid-correction abandons the settle
  and glides onward from wherever the pitch is. The waypoint is consumed
  only at the settle, so ownership/release/glide-back semantics are
  untouched. Default 0.08; 0 = every glide lands exactly.

### Ownership, releases and parked fingers

- **Ownership** — after arriving at a waypoint, that waypoint's
  physical touch owns the sounding voice: its drags meend it and its
  last physical release ends it immediately, mapped onto the voice's original wire id (the voice
  layer never learns the queued ids). A queued finger dragging *before*
  the glide arrives retargets its waypoint live — the trajectory lands
  where the finger is.
- **Releases** — a queued note released while other members remain held
  stays queued, and the trajectory still visits it. When every member
  lifts, the voice releases immediately and the queue pauses for grace.
- **Parked fingers and glide-back** — past chain members still down are
  *parked*: only the current owner's drags drive the voice, and a parked
  finger's movements are remembered **silently** (following them is the
  two-finger oscillation bug — the held first finger's wire id is the
  voice's own downstream id, so its wiggles would yank the pitch back).
  Releasing the owner while fingers are parked glides **back** to the
  most recent one, at that finger's *current* position, at the full
  released rate; parked fingers cascade most-recent-first, and only when
  every member has lifted does the bow come up. A parked finger lifting
  is silent — it just leaves the chain.
- **Exemptions** — the controller strum chord's members carry an
  in-process `glideExempt` flag (`TLPTouch`, like `exprScale`: never on
  the wire), so near-simultaneous chord onsets can never chain into a
  glissando. Drones are a different path entirely.

### Voice-agnostic, above allocation

The sequencer sits above the instrument routing, so the plucked mains
get it too: on the Tanpura/Sitar a queued onset becomes a kernel-side
bend of the ringing string — a glissando without re-plucks. Resuming a
released plucked string removes its extra release damping; its remaining
energy rings naturally, with no new excitation. It is a
queue *above* allocation, not a legato law: a captured onset never
becomes a note-on, every note that mounts still gets a fresh string, and
with the toggle off the sequencer is byte-for-byte pass-through (the
inert-default contract — parity hashes unaffected). The six knobs live
in the Parameters tab's **Glide** group (all `.live`, per-note scope,
tilt-bindable). Guards: `GlideSequencerTests`.
