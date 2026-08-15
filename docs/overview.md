# Overview

Tarabdaar is an expressive electronic music instrument, loosely inspired by the [Ondes Martenot](https://en.wikipedia.org/wiki/Ondes_Martenot). The player rests an iPad on their inner forearm, plays notes on a touchscreen **Fret Pad** (a surface of freely-placed fret segments with continuous glide), and tilts the device to modulate expression. The iPad is plugged into a Mac over USB; the Mac renders the **sarangi String voice** — a pure-physics bowed gut string with a sympathetic (tarab) web fused into the kernel. It is designed for genres with complex glissandi, such as Indian classical music.

## Design Philosophy

- **Two devices, one cable, almost no shared state.** The iPad is a pure MPE-MIDI controller — capacitive touchscreen for the Fret Pad, gyroscope for tilt expression. It owns its vibrato settings and tilt bindings; its playing scale and fret layout are edited on the Mac and synced over (see the scale-sync exception below). The Mac is a pure MIDI-driven sound module — it renders the sarangi String voice (`SarangiKit.BowEngine` + the `CBowKernel` C friction kernel), owns the tarab tuning and the physics/composite parameters. The two communicate over a single USB cable; no Wi-Fi, no Bonjour. The one exception to "no shared state" is **pad sync**: TarabdaarMac edits the playing scale + fret layout + tilt bindings and pushes them to the iPad as MIDI SysEx blobs on that same cable (the iPad performs them, and has no editor of its own). Everything else is just MPE notes on the wire.
- **One voice, played every way.** There is a single voice — the String model. No hosted plugins, no base-voice picker; the whole instrument (played strings + taraf + body + radiation + room) lives in the kernel.
- **Continuous and expressive.** Pitch is a position on a surface, not a discrete key, so microtonal inflection between scale degrees is always on tap. Every parameter that can vary continuously does.
- **Glissandi first.** Pitch glide is the core feature: dragging across the Fret Pad bends a held note continuously; onset-only snapping lands you on a fret, drags glide freely from there.
- **MIDI-native.** All expression (pitch bend, velocity, aftertouch, CCs) is standard MPE MIDI. The Mac synth is one receiver; the iPad works equally well into Ableton, Logic, or any other MPE-aware host.

## Current Capabilities

### iPad (controller)
- Full-screen **Fret Pad**: freely-placed vertical fret segments; touch position = pitch via the continuous fret field, with onset-only snapping and per-touch glide (see [Fret Pad](fret-pad.md))
- Glides: drag to bend a held note continuously; a gated drag-assist magnetically lands stops on frets without warping fast transit or vibrato
- Multitouch polyphony — each finger is an independent MPE voice
- Drone buttons inside the surface's right edge drive the jawari-taraf rows
- Tilt-controlled performance (3 calibrated arm axes from the iPad + Joy-Con stick X/Y, bound on the Mac to composites or single parameters)
- Playing scale + fret layout + tilt bindings edited on TarabdaarMac and synced to the iPad over USB-MIDI SysEx; the iPad is perform-only
- MPE MIDI output over USB (per-note pitch bend isolation via channel rotation)
- One tilt calibration, Mac-side: the guided arm calibration (rest + 3 sweeps over the iPad's raw attitude stream; no Joy-Con needed)

### Mac (the sarangi String voice)
- Renders the **String voice** (`BowEngine` + `CBowKernel`, 96 kHz → 48 kHz), the only voice — the audio graph is just `StringVoiceSource → symGain → mainMixerNode → output`
- Sympathetic (tarab) strings + modal-jawari taraf fused into the kernel, tuned from the **Strings tab** (every string a degree of the centralized scale — the tarab always follows the scale)
- **Parameters tab** — every parameter of the instrument in one grouped, searchable list (physics scalars and live axes alike), applied live
- **Controls tab** — tilt bindings (to a composite or straight to a parameter) + composite parameters (named 0–1 macros)
- **Autonomous audition pipeline** — `<repo>/auditions/inbox/` is a watched folder; drop a JSON score and `AuditionRunner` plays it through the headless simulator while recording to `<repo>/auditions/outputs/<name>.wav`. Events can drive notes, tilts, drones, and String-voice parameters (`voiceParam` / `string.<key>`), so a script can sweep sound-design space without a human in the loop. See [Simulator & Audition Loop](simulator.md).
