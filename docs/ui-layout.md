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

### Top bar

- **ConnectionPill** — shows USB-MIDI input status (`MIDI: N src` when sources are visible, `no MIDI in` otherwise). Click to pop a detailed status panel.
- **KeyboardPlayPill** — toggles computer-keyboard note input (off by default). The pill reads `Keys` (green) when on, `Keys off` otherwise; clicking opens a popover with the enable toggle, an **Octave shift** stepper (−3…+3), and a legend of the key layout. See **Computer keyboard** below.
- **Tab picker** — segmented control: Live / Tarab / Fret Pad / Controls / Parameters / Setup. ⌘1…⌘6 jump to each. (The Sarangi tab was removed in the 2026-07-24 parameter unification — its physics sliders and preset toolbar moved into **Parameters**.)

### Computer keyboard

The Mac can play notes from the **computer keyboard** (`KeyboardNotePlayer`, owned by `AppController` as `keyboard`; toggled from the top-bar KeyboardPlayPill, persisted). It plays through the **playing engine** (`controller.pitchPad`) — the same in-process MPE path the on-screen Fret Pad uses — so keyboard notes share the **scale, tonic, and Velocity**, sound identical to played notes, and feed the String voice like any other note.

- **Mapping = scale degrees, not 12-TET.** The three letter rows form one ascending ribbon (low→high): `Z X C V B N M , . /` then `A S D F G H J K L ;` then `Q W E R T Y U I O P`. Ribbon position `k` plays the `(k mod N)`-th enabled scale degree raised `floor(k / N)` octaves (`N` = enabled-degree count), so any scale size / JI tuning works and the keys play the scale exactly as drawn.
- **`[` / `]`** shift the whole ribbon down / up an octave (clamped −3…+3); shifting releases any held notes.
- **App-wide while enabled** via one local `NSEvent` monitor (key down/up). It **steps aside while a text field is being edited** (first responder is an `NSText`) and **ignores any key pressed with ⌘/⌃/⌥** so the ⌘1–9 tab shortcuts and menu commands still work. Auto-repeat is swallowed; held notes are released on app-focus loss so nothing sticks. Keys use **physical key codes** (`kVK_ANSI_*`), so the row shapes survive non-QWERTY layouts. Keyboard touches use a distinct touchId namespace (`1_000_000 + index`) so they never collide with mouse-played notes on the same engine. (`PitchPadEngine.clampRatio` is widened to ±5 octaves to cover the multi-octave ribbon.)

### Live tab

MIDI input status (source count + status message), an audio render-time readout, and two live **time-series graphs** of the currently-played voice: **PITCH** (log-frequency, y-axis fixed to the Fret Pad's playable range — labelled with the nearest note name + Hz) and **VOLUME** (the commanded CC11 Expression, 0–100%). Traces are drawn as smooth Catmull-Rom curves (rounding the sample-to-sample steps). Both read `AudioEngine.performanceReadout()` — derived at the single MIDI choke point, so they reflect every source (the USB iPad, the Mac Fret Pad, the simulator). The graphs show a fixed **6-second** window and scroll **smoothly**: a 60 Hz timer appends timestamped samples to a ring buffer and a `TimelineView(.animation)` redraws every display frame, placing each sample at an x set by its age, so the trace slides left continuously instead of stepping at the sample rate.

### Tarab tab (⌘2)

The sarangi's **sympathetic strings** (`TarabView`) — the rows tune the String voice's in-kernel taraf. **Auto-sync to the scale starts OFF** (the String-era default) so the fitted Pilu table sticks — a re-sync would replace it with regenerated detunes and audibly weaken the ring. A header **"Follow the Pitch Pad scale"** switch + **"Re-sync"** button opt in; a tonic readout shows the current pitch. Below, the strings are grouped into the four physical choirs, one collapsible section each:
- **Chromatic** — 15 fixed JI-chromatic strings, always present.
- **Scale-tuned** — the scale degrees (+ Sa/Pa doublings), following the current scale.
- **Low octave** / **Upper octave** — octave repeats of the tonic / fifth / scale degrees.

Each section has a count, an **Enable all / Disable all** toggle, an add (+) button, and per-string rows (editable **Note / Freq (Hz) / Gain / t60 / Bright / On** + delete). Editing a string, toggling a choir, or using the **Manual tuning** fallback (a **Raga** picker + **Tonic**/Set/Transpose/Regenerate) keeps auto-sync off; the switch / Re-sync button engages it.

### Fret Pad tab (⌘3)

The sole playing surface on the Mac, and the editor for the surface the iPad mirrors (`FretPadView`). Free-fret segments, onset-only snapping, drag assist, tap legato, drone buttons, and — since the 2026-07-23 simplification — the **scale selector + list editor + editable tonic** (`ScaleListEditor`), moved here off the old Pitch Pad tab. It edits `controller.pitchPad.scale`, the shared scale model the frets / tarab / iPad-sync read from. Full treatment: [Fret Pad](fret-pad.md).

### Controls tab (⌘4)

The **tilt bindings** + **composite parameters** (`TiltControlsView`). Per tilt 1/2/3, bind an arbitrary set of targets with configurable endpoints — a target is a **composite** *or* **any single parameter** (`MapTarget`), and endpoints are in the target's own units (0–1 for a composite, the parameter's native range otherwise). The Mac evaluates these itself; nothing is pushed to the iPad, which streams only its raw tilt report. **Composite parameters** are named 0–1 controls built from parameter members each sweeping lo→hi; ships with Taraf Purity / Taraf Decay / Tone Tilt / Expression on slots 1–4. The Add menus group every parameter exactly as the Parameters tab does. At the bottom, **Save controls… / Load controls…** store the composites and tilt bindings as a `.starpadmap` file, independently of the instrument. See [Sensors](sensors.md) and [Parameters](parameters.md).

### Parameters tab (⌘5) — the whole parameter list

**Every** parameter of the String instrument in one place (`ParametersView` over `ParamRegistry`), including the physics scalars that used to live in a separate Sarangi tab. Groups are collapsible — Bow stroke / Body / Bow & string / Playing ranges / Jawari taraf / Taraf / Articulation / Radiation & output — and a filter box searches names, keys, and help text. Each row is a labelled slider in **native units** (out-of-range artifact values widen the slider rather than clamping), a numeric readout, a **mapping button** (bind to Tilt 1/2/3, add to a composite, or spin up a new composite from this parameter), chips showing what currently drives it, and a reset. Double-clicking a row label also resets it. Rows tagged **"rebuild"** re-apply through a debounced off-main `BowEngine` rebuild; everything else is instant.

The header carries the **instrument preset toolbar**: the shipped **"Default (Sarangi Live)"** reset, plus **Save instrument… / Load instrument…** — the sarangi document (tarab table + tonic + model params), the physics overrides, and every parameter's resting value, as a `.starpad` file. The old separate `.sarangi` save is folded in here, and older `.sarangi` files still open.

The **controls** half — composites and tilt bindings — saves separately from the [Controls tab](#controls-tab-4) as a `.starpadmap` file. The split is deliberate: a sound and the way you map your tilts are independent, so loading a new instrument never costs you a mapping tuned to your playing. Loading is scope-filtered, so an older combined `.starpad` can be opened from either place and applies only that half; if a file has nothing for the half you asked for, the toolbar says so (including "it is a controls preset") rather than silently doing nothing.

**Reset all** clears both the physics overrides (`starpad.stringOverrides.v1`) and every resting value (`starpad.controlDefaults.v1`).

See [Parameters](parameters.md) for the generated per-key table and [Sarangi](sarangi.md) for what the physics mean.

### Setup tab (⌘6)

Audio output device picker, MIDI status, system info.
