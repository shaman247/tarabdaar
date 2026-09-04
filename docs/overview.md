# Overview

Tarabdaar is an expressive electronic music instrument, loosely inspired by the [Ondes Martenot](https://en.wikipedia.org/wiki/Ondes_Martenot). The player rests an iPad on their inner forearm, plays notes on a touchscreen **Fret Pad** (a surface of freely-placed fret segments with continuous glide), and tilts the device to modulate expression. The iPad links to a Mac over USB or BLE-MIDI; the Mac renders the sound — the **sarangi String voice**, a pure-physics bowed gut string with a sympathetic (tarab) web fused into the kernel, plus a plucked **Tanpura** and **Sitar**. It is designed for music with complex glissandi, such as Indian classical music.

## Design philosophy

- **Two devices, one link, almost no shared state.** The iPad is a silent controller — capacitive touchscreen for the Fret Pad, gyroscope and accelerometer for tilt and strike. It streams touches and raw sensor axes over the **TLP** protocol (see [MIDI & Audio](midi-and-audio.md)); it owns glide and the playing surface, and nothing else. The Mac owns all the sound: the voices, the tarab tuning, the physics, the composite and tilt bindings. The one exception to "no shared state" is **pad sync**: the Mac edits the playing scale + fret layout and pushes them to the iPad (which performs them and has no editor of its own).
- **The whole instrument in the kernel.** The String voice (`SarangiKit.BowEngine` + the `CBowKernel` C friction kernel) renders the played strings, the taraf, the body, the radiation and the room in one pass. No hosted plugins, no base-voice picker.
- **Continuous and expressive.** Pitch is a position on a surface, not a discrete key, so microtonal inflection between scale degrees is always on tap. Every parameter that can vary continuously does, and any of them can be bound to a tilt.
- **Glissandi first.** Dragging across the Fret Pad bends a held note continuously; onset-only snapping lands you on a fret, drags glide freely from there, and the optional glide queue turns overlapping onsets into glissandi. Vibrato and meend are played, never synthesized.

## Capabilities

### iPad (controller)
- Full-screen **Fret Pad**: freely-placed vertical fret segments; touch position = pitch via the continuous fret field, onset-only snapping, per-touch glide, a gated drag assist that lands stops on frets, and the **chord bar** strip (see [Fret Pad](fret-pad.md))
- Multitouch polyphony — each finger is an independent string on the Mac
- Drone buttons inside the surface's right edge (hidden while a Joy-Con is attached)
- Raw tilt, the accelerometer strike envelope and per-touch strike velocity in every state frame; a toolbar of scopes (arm / wrist / stick tilt, strike, finger acceleration, the Mac's radiated volume)
- Playing scale + fret layout edited on the Mac and synced over; the iPad is perform-only

### Mac (sound module)
- Renders the **String voice** (`BowEngine` + `CBowKernel`, 96 kHz → 48 kHz) as the default played voice, and the plucked **Tanpura** (default drone voice, optional main instrument) and **Sitar** (main instrument only) — see [Sarangi](sarangi.md), [Tanpura Voice](tanpura-voice.md), [Sitar Voice](sitar-voice.md)
- Sympathetic (tarab) strings as modal-jawari rows fused into the kernel, tuned from the **Strings tab** (every string a degree of the centralized scale)
- **Parameters tab** — every parameter in one grouped, searchable list, applied live; **Controls tab** — tilt bindings (to a composite or straight to a parameter) and composite macros; **FX tab** — the four-insert rack; **Scope** and **Taraf** tabs — the performance and the sympathetic rows at a glance
- Joy-Con supplemental input (stick, wrist tilt, strum, octave shift)
