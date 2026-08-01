# UI Layout

Two devices, two layouts. The iPad is the controller (touchscreen Fret Pad + tilt). The Mac is the sound module (the String-voice physics + tarab editor + the Fret Pad / Controls tabs).

## iPad

The iPad's playing surface is the **Fret Pad** (full screen), replacing
the old piano keyboard. It is the same free-fret surface as the Mac Fret
Pad tab — see [Fret Pad](fret-pad.md) for the fret field, onset-only
snapping, drag assist, tap legato, drone buttons, and octave-repeat
ghosts, all of which live in shared `StarpadCore` code
(`FretPadGeometry.swift`, `PitchPadEngine.swift`).

### Layout

- **Slim toolbar (top)**: PANIC, a **Rec** toggle (records play strokes for
  drag-assist fitting), a scale-sync indicator,
  the calibrated **tilt pad** (an X-Y square fed by `NoteManager.currentTilt`:
  tilt 1 on x, tilt 2 on y (up = positive), the dot colored purple → cyan →
  orange as tilt 3 goes `-1 → 0 → +1`), a live `Hz (note ±cents)` readout
  tinted in the sounding pitch's hue, a read-only Tonic readout, and
  Recalibrate. (No SCALE button and no editable tonic — scale, layout, and
  Snap are set on the Mac and synced over. There is no MAP button: the
  iPad's parameter mapping was deleted 2026-07-24.)
- **Fret Pad (rest of screen)**: the playing/rendering surface. The iPad
  is **always in perform mode** — band gridlines/labels/handles hidden,
  just the fret lines, the field, and the live sounding glow. Touching a
  fret sounds its pitch (onset snap); dragging glides continuously;
  multiple fingers play polyphonically, each on its own MPE channel. Drone
  buttons sit inside the right edge.

The pad is **perform-only** on iPad — there's no editor. The scale + fret
layout are designed on the Mac Fret Pad tab and synced to the iPad over
USB-MIDI SysEx (see [Scale sync](midi-and-audio.md#scale-sync-mac--ipad)).

### Touch → pitch → MIDI

`TouchOverlayView` (UIKit multitouch) reports per-finger `(xFraction,
yFraction)` over the pad's logical area. `FretPadSurfaceIOS` maps each to
a pixel point, resolves the fret field / onset snap, then drives
`PitchPadEngine`: `noteOn` on touch-down (pins a MIDI note and bends to
the pitch), `glide` on move (bend only), `noteOff` on lift. The pitch
tracks the finger directly. See [Fret Pad](fret-pad.md).

### Tilt expression

On top of position→pitch, the iPad keeps its signature tilt expression —
but since 2026-07-24 it only *reports* the tilts. A 60 Hz loop samples the
three calibrated axes and streams them as the **raw tilt report**
(`TiltAxisWire`, CCs 16/17/18 on channel 0, change-gated). The iPad knows
nothing about parameters, composites, or slots; StarpadMac evaluates its
own bindings (`AppController.applyTiltAxis`) and drives the voice. Bind a
tilt to a composite or to any single parameter in the Mac's **Controls**
tab — see [Sensors](sensors.md).

### Scale sync (Mac → iPad)

The iPad has no scale editor. The Mac's Fret Pad tab edits the scale + fret
layout and pushes them to the iPad over USB-MIDI SysEx (live, debounced, and
on connect); a `ScaleSyncReceiver` on the iPad applies them. See
[MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).

### Parameter mapping — REMOVED

The iPad's full-screen matrix panel (rows = parameters, columns =
dimensions) and its curve editor were **deleted on 2026-07-24** with the
rest of the iPad-side parameter machinery (`NoteManager`'s binding caches,
`MappingMatrixPanel`, `CurveEditorView`, the tilt-mapping SysEx). Mapping
now lives entirely on the Mac, where a tilt binds to a composite or to a
single parameter — see [Sensors](sensors.md) and the **Controls tab**
below.

## System UI (iPad)

- Status bar: hidden
- System overlays: hidden (`.persistentSystemOverlays(.hidden)`)
- System gestures: deferred on all edges (`.defersSystemGestures(on: .all)`)
- Orientation: locked to landscape right via AppDelegate + Info.plist

## Mac

A single window with a top bar and six tabs.

### Typography

Small text — captions, table columns, row labels, pad labels, graph annotations — comes from **`Typography`** (`Packages/StarpadCore/.../Typography.swift`), not from SwiftUI's stock styles. It carries **one constant, `smallScale` (1.2)**, and exposes the platform's own stock sizes scaled by it: `Font.padCaption` / `.padCaption2` / `.padSubheadline` / `.padCallout`, plus `Font.padSmall(_:weight:design:)` for the handful of places that size text to a drawn shape. macOS stock captions are 10 pt, which is too fine for the dense tables this UI is mostly made of; the whole app reads at 12. Fixed-width label and value columns pass their width through `Typography.scaledWidth(_:)` so the columns grow with the text instead of clipping it. **Display text is deliberately unscaled** — titles, headlines, the Live tab's big readouts, the iPad calibration numerals — it is already legible and growing it would reflow the panels. Both platforms use the file, each scaled off its own stock sizes.

### Top bar

- **ConnectionPill** — shows USB-MIDI input status (`MIDI: N src` when sources are visible, `no MIDI in` otherwise). Click to pop a detailed status panel.
- **KeyboardPlayPill** — toggles computer-keyboard note input (off by default). The pill reads `Keys` (green) when on, `Keys off` otherwise; clicking opens a popover with the enable toggle, an **Octave shift** stepper (−3…+3), and a legend of the key layout. See **Computer keyboard** below.
- **Tab picker** — segmented control: Live / Tarab / Fret Pad / Controls / Parameters / FX / Setup. ⌘1…⌘7 jump to each. (The Sarangi tab was removed in the 2026-07-24 parameter unification — its physics sliders and preset toolbar moved into **Parameters**. The FX tab is the 2026-08-01 four-insert rack — see [FX](fx.md).)

### Computer keyboard

The Mac can play notes from the **computer keyboard** (`KeyboardNotePlayer`, owned by `AppController` as `keyboard`; toggled from the top-bar KeyboardPlayPill, persisted). It plays through the **playing engine** (`controller.pitchPad`) — the same in-process MPE path the on-screen Fret Pad uses — so keyboard notes share the **scale, tonic, and Velocity**, sound identical to played notes, and feed the String voice like any other note.

- **Mapping = scale degrees, not 12-TET.** The three letter rows form one ascending ribbon (low→high): `Z X C V B N M , . /` then `A S D F G H J K L ;` then `Q W E R T Y U I O P`. Ribbon position `k` plays the `(k mod N)`-th enabled scale degree raised `floor(k / N)` octaves (`N` = enabled-degree count), so any scale size / JI tuning works and the keys play the scale exactly as drawn.
- **`[` / `]`** shift the whole ribbon down / up an octave (clamped −3…+3); shifting releases any held notes.
- **App-wide while enabled** via one local `NSEvent` monitor (key down/up). It **steps aside while a text field is being edited** (first responder is an `NSText`) and **ignores any key pressed with ⌘/⌃/⌥** so the ⌘1–9 tab shortcuts and menu commands still work. Auto-repeat is swallowed; held notes are released on app-focus loss so nothing sticks. Keys use **physical key codes** (`kVK_ANSI_*`), so the row shapes survive non-QWERTY layouts. Keyboard touches use a distinct touchId namespace (`1_000_000 + index`) so they never collide with mouse-played notes on the same engine. (`PitchPadEngine.clampRatio` is widened to ±5 octaves to cover the multi-octave ribbon.)

### Live tab

MIDI input status (source count + status message), an audio render-time readout, and two live **time-series graphs** of the currently-played voice: **PITCH** (log-frequency, y-axis fixed to the Fret Pad's playable range — labelled with the nearest note name + Hz) and **VOLUME** (the commanded CC11 Expression, 0–100%). Traces are drawn as smooth Catmull-Rom curves (rounding the sample-to-sample steps). Both read `AudioEngine.performanceReadout()` — derived at the single MIDI choke point, so they reflect every source (the USB iPad, the Mac Fret Pad, the simulator). The graphs show a fixed **6-second** window and scroll **smoothly**: a 60 Hz timer appends timestamped samples to a ring buffer and a `TimelineView(.animation)` redraws every display frame, placing each sample at an x set by its age, so the trace slides left continuously instead of stepping at the sample rate.

### Tarab tab (⌘2)

The sarangi's **sympathetic strings** (`TarabView`) — the rows tune the String voice's in-kernel taraf. Every string is a **scale degree + octave** of the centralized Pitch Pad scale, so pitches always follow the scale and the tonic — there is no follow toggle (removed 2026-07-25). The header holds a **"Regenerate from scale"** button (rebuild the default layout, discarding hand edits — the layout also regenerates itself when the scale's degree count changes) and a tonic readout (read-only — the tonic is set on the Fret Pad tab, in Hz). Below, the strings are **one flat table**: an **Enable all / Disable all** toggle, an add (+) button, and per-string rows (**Pitch** dropdown (the scale's degrees under the scale's own labels) / **Octave** dropdown (−2…+2) / read-only **Hz** / editable **Gain / t60 / On** + delete — no ratio or Hz inputs). Below the table, the **Drone buttons** section maps each of the 3 Fret Pad drone buttons to one of the strings. (The **Manual tuning** raga/tonic fallback was removed 2026-07-25.)

### Fret Pad tab (⌘3)

The sole playing surface on the Mac, and the editor for the surface the iPad mirrors (`FretPadView`). Free-fret segments, onset-only snapping, drag assist, tap legato, drone buttons, and — since the 2026-07-23 simplification — the **scale selector + list editor + the tonic** (`ScaleListEditor`), moved here off the old Pitch Pad tab. The tonic is a **Hz field** (2026-07-25) with a note-name ± cents readout — **the app's one Hz input**; every other pitch (frets, tarab strings, drones) is a scale degree relative to it, and the fractional part rides the iPad sync blob so both devices agree to the cent. It edits `controller.pitchPad.scale`, the ONE centralized scale the frets / tarab / iPad-sync all read from. Full treatment: [Fret Pad](fret-pad.md).

### Controls tab (⌘4)

The **tilt bindings** + **composite parameters** (`TiltControlsView`). Per tilt 1/2/3, bind an arbitrary set of targets with configurable endpoints — a target is a **composite** *or* **any single parameter** (`MapTarget`), and endpoints are in the target's own units (0–1 for a composite, the parameter's native range otherwise). The Mac evaluates these itself; nothing is pushed to the iPad, which streams only its raw tilt report. **Composite parameters** are named 0–1 controls built from parameter members each sweeping lo→hi; ships with Taraf Purity / Taraf Decay / Tone Tilt / Expression on slots 1–4. The Add menus group every parameter exactly as the Parameters tab does. Composites and tilt bindings save **with the preset** — one `.starpad` file from the Parameters tab (⌘5); the separate `.starpadmap` save was folded in 2026-07-30 (old `.starpadmap` files still load there). See [Sensors](sensors.md) and [Parameters](parameters.md).

### Parameters tab (⌘5) — the whole parameter list

**Every** parameter of the String instrument in one place (`ParametersView` over `ParamRegistry`), including the physics scalars that used to live in a separate Sarangi tab. Groups are collapsible — Bow stroke / Body / Bow & string / Playing ranges / Jawari taraf / Taraf / Articulation / Radiation & output — and **all of them start open**, since the tab is a reference surface and a knob behind a collapsed header costs more to find than the scroll costs; a filter box searches names, keys, and help text. Each row is a labelled slider in **native units** (out-of-range artifact values widen the slider rather than clamping), a numeric readout, a **mapping button** (bind to Tilt 1/2/3, add to a composite, or spin up a new composite from this parameter), chips showing what currently drives it, and a reset. Clicking a row label shows the parameter's description inline under the row (the hover tooltip carries the same text, but macOS shows tooltips unreliably); double-clicking a row label resets it. Rows tagged **"rebuild"** re-apply through a debounced off-main `BowEngine` rebuild; everything else is instant.

The header carries the **preset toolbar** (`PresetToolbar`) — ONE preset covering the whole rig (2026-07-30), and **no file panels**. The **Load preset** menu lists the shipped **"Default (Sarangi Live)"** (a full-rig factory reset: bank + untouched physics + default composites and tilt bindings), then every saved preset by name, then a **Delete preset** submenu. **Save preset…** pops a name field — the preset lands in the app-managed library (`Application Support/Starpad/Presets/`) and appears in the menu immediately; saving an existing name overwrites it (the popover says so). A preset carries everything: the sarangi document (tarab table + tonic + model params), the physics overrides, every parameter's resting value, the composites and the tilt bindings. The 2026-07-24 instrument/controls split (`.starpad` + `.starpadmap` from separate tabs) is folded back together; dropping a split-era or legacy `.sarangi`-content file into the library folder (as `.starpad`) lists it, and loading applies only the sections it carries.

**Reset all** clears both the physics overrides (`starpad.stringOverrides.v1`) and every resting value (`starpad.controlDefaults.v1`).

See [Parameters](parameters.md) for the generated per-key table and [Sarangi](sarangi.md) for what the physics mean.

### FX tab (⌘6) — the four-insert rack

One panel per insert point — **Voice → Taraf** (what the sympathetic strings hear), **Voice** (the main bus post-taraf-tap), **Taraf** (the web's own radiation), **Global** (the final stereo out) — each with a **graphic EQ** (10 vertical ±12 dB faders, octave centres 31.5 Hz–16 kHz, double-click a fader to zero it) and a **reverb** (Bigverb/Room segmented picker + mix/size/cutoff sliders, double-click a label to reset). Toggles glide, so switching FX in and out never clicks. A dot by the panel title marks an active point; **Reset** returns the point to all-off. Every control is a plain `fx_*` registry parameter (`FXView` drives `paramValue`/`setParamValue`), so the Parameters tab, presets, tilts and composites all see the same knobs. See [FX](fx.md).

### Setup tab (⌘7)

Audio output device picker, MIDI status, system info.
