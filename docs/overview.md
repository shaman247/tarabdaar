# Overview

Starpad is an expressive electronic music instrument, loosely inspired by the [Ondes Martenot](https://en.wikipedia.org/wiki/Ondes_Martenot). The player rests an iPad on their inner forearm, plays notes on a touchscreen **Pitch Pad** (a 2D just-intonation surface), and tilts the device to modulate expression. The iPad is plugged into a Mac over USB; the Mac hosts a SWAM Viola Audio Unit for the played voice and layers a tanpura-style sympathetic-string pool over it. It is designed for genres with complex glissandi, such as Indian classical music.

## Design Philosophy

- **Two devices, one cable, almost no shared state.** The iPad is a pure MPE-MIDI controller — capacitive touchscreen for the Pitch Pad, gyroscope for tilt expression. It owns its vibrato settings and MIDI mappings; its playing scale is edited on the Mac and synced over (see the scale-sync exception below). The Mac is a pure MIDI-driven sound module — it hosts the SWAM Viola Audio Unit (which produces the played voice), owns the sympathetic-string pool, the master FX bus, and the preset state. The two communicate over a single USB cable; no Wi-Fi, no Bonjour. The one exception to "no shared state" is **scale sync**: StarpadMac edits the playing scale and pushes it to the iPad as a MIDI SysEx blob on that same cable (the iPad performs it, and has no scale editor of its own). Everything else is just MPE notes on the wire.
- **Continuous and expressive.** Pitch is a position on a surface, not a discrete key, so microtonal inflection between scale degrees is always on tap. Every parameter that can vary continuously does.
- **Glissandi first.** Pitch glide is the core feature: dragging across the Pitch Pad bends a held note through the cells, so transitions slide instead of jumping.
- **MIDI-native.** All expression (pitch bend, velocity, aftertouch, CCs) is standard MPE MIDI. The Mac synth is one possible receiver; the iPad works equally well into Ableton, Logic, or any other MPE-aware host.

## Current Capabilities

### iPad (controller)
- Full-screen **Pitch Pad**: a 2D just-intonation surface where each scale degree is a Voronoi cell; touch position = pitch (see [Pitch Pad](pitch-pad.md))
- Glides: drag across cells to bend a held note continuously; soft margins between cells blend pitch (and microtonal inflection) instead of snapping
- Multitouch polyphony — each finger is an independent MPE voice
- Tilt-controlled aftertouch / MIDI CCs (3 calibrated tilt axes)
- Playing scale (JI ratios) edited on StarpadMac and synced to the iPad over USB-MIDI SysEx; the iPad is perform-only
- MPE MIDI output over USB (per-note pitch bend isolation via channel rotation)
- Seven-point device orientation calibration (3 axes, each with positive/negative endpoints)

### Mac (sym-strings + FX + hosted-AU host)
- Hosts SWAM Viola via AVAudioUnit — N parallel instances (one per MPE channel) since each SWAM is monophonic
- Tanpura-style sympathetic-string pool layered over the SWAM audio (tap → SPSC ring → modal sym render)
- Asynchronous per-partial amp LFOs ("jiva") and per-bank pitch random walk give the sym pool its alive, slowly-shimmering character
- Sympathetic strings track the configured Pitch Pad scale automatically (same tonic, extended ½ octave each way) — no separate editor
- Sliders panel for every sym / tanpura-modulation / FX param
- Master reverb + master resonant LPF (AVAudioUnitReverb + AVAudioUnitEQ on the mixer chain)
- AU plugin window — open SWAM's UI in-app for articulation / MIDI-mapping configuration
- Preset menu (currently SWAM Viola only) — kept as scaffolding for future hosted-AU presets
- **Simulator tab** for iPad-free sound-design iteration: mouse + computer keyboard play the same MPE pipeline an iPad would, with on-screen tilt sliders and a strike-force knob standing in for the gyro/accelerometer. Post-FX recording lands in `~/Music/Starpad-Recordings/`.
- **Pitch Pad tab** — a 2D Voronoi-cell pitch surface for designing and auditioning JI scales. Click/drag plays the cell's exact ratio inside its inner polygon and log-frequency-interpolates between two pitches in the soft margin between them. Handles drag with shift-snap to "simple" fractions (filtered by prime limit and complexity), and a sidebar editor lists each pitch with scroll-wheel increment. See [Pitch Pad](pitch-pad.md).
- **Tanpura tab** — a four-string modeled tanpura drone with traditional just tuning (Pa sa sa SA), an auto-strum cycle, and per-harmonic editing of every string's bloom (the model synthesizes each harmonic individually so the signature staggered harmonic peaks are directly controllable). Matched against a real tanpura recording by an autonomous offline loop. See [Tanpura](tanpura.md).
- **Autonomous audition pipeline** — `<repo>/auditions/inbox/` is a watched folder; drop a JSON score and `AuditionRunner` plays it through the simulator while recording to `<repo>/auditions/outputs/<name>.wav`. Events can drive notes, tilts, sliders, strike force, and Mac-side voice/FX parameters (`voiceParam`), so a script can sweep sound-design space without a human in the loop. See [Simulator & Audition Loop](simulator.md) for the schema and the target-replication workflow (analyze → render → compare → refine).
