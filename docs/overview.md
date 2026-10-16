# Overview

Tarabdaar is an expressive electronic music instrument, loosely inspired by the [Ondes Martenot](https://en.wikipedia.org/wiki/Ondes_Martenot). The player places an iPad on a flat surface, plays notes on a touchscreen **Fret Pad** (a surface of freely-placed fret segments with continuous glide), and uses Joy-Con wrist motion and the stick for expression. The same three tilt dimensions automatically use the iPad when no controller is connected, with separate arm and wrist calibrations. The iPad links to a Mac over USB or BLE-MIDI; the Mac renders the sound — the **sarangi String voice**, a pure-physics bowed gut string with a sympathetic (tarab) web fused into the kernel, plus a plucked **Tanpura** and **Sitar**. It is designed for music with complex glissandi, such as Indian classical music.

## Design philosophy

- **Two devices, one link.** The iPad captures touches and raw motion; the Mac owns sound, glide sequencing, calibration, tuning and bindings. The Mac synchronizes the playing surface and controller state to the iPad. Ownership and synchronization are described in [Architecture](architecture.md) and [MIDI & Audio](midi-and-audio.md).
- **Physical voices.** The String voice models bowed gut strings and sympathetic steel strings; Tanpura and Sitar provide plucked voices. The Mac's Live tab selects the played instrument. See [Sound Design](sound-design.md) for the sound and effects paths.
- **Continuous and expressive.** Pitch is a position on a surface, not a discrete key, so microtonal inflection between scale degrees is always on tap. Every parameter that can vary continuously does, and any of them can be bound to a tilt.
- **Glissandi first.** Dragging across the Fret Pad bends a held note continuously; onset-only snapping lands you on a fret, drags glide freely from there, and the optional glide queue turns overlapping or closely spaced onsets into glissandi. Vibrato and meend are played, never synthesized.

## Capabilities

### iPad (controller)
- Full-screen **Fret Pad**: freely-placed vertical fret segments; touch position = pitch via the continuous fret field, onset-only snapping, per-touch glide, a gated drag assist that lands stops on frets, and the **chord bar** strip, hidden for now (see [Fret Pad](fret-pad.md))
- Multitouch polyphony — each finger is an independent string on the Mac
- Raw tilt and the accelerometer Strike envelope in every state frame
- Sync and link indicators appear only while unsynced or disconnected
- Playing scale + fret layout edited on the Mac and synced over; the iPad is perform-only

### Mac (sound module)
- Renders the **String voice** (`BowEngine` + `CBowKernel`, 96 kHz → 48 kHz) as the default played voice, and the plucked **Tanpura** (default drone voice, optional main instrument) and **Sitar** (main instrument only) — see [Sarangi](sarangi.md), [Tanpura Voice](tanpura-voice.md), [Sitar Voice](sitar-voice.md)
- Two sympathetic (tarab) banks edited in the **Strings tab**, with scale-reference or fixed chromatic pitches — see [Sarangi](sarangi.md#two-bridges-two-sets)
- A raga taraf strip above the Mac fret band for direct sympathetic-string plucks and strumming; the Joy-Con controls the drone sequence
- **Live tab** performance graphs and motion meters; **Rec** on the Fret Pad tab records strokes from both pads into Mac files
- **Parameters tab** — every parameter in one grouped, searchable list, applied live; **Controls tab** — tilt bindings (to a composite or straight to a parameter) and composite macros; **FX tab** — the four-insert rack; **Scope** and **Taraf** tabs — the performance and the sympathetic rows at a glance
- Joy-Con primary motion input (stick, wrist tilt, strum, octave shift)
