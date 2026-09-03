# UI Layout

Two devices, two layouts. The iPad is the controller (touchscreen Fret Pad + tilt). The Mac is the sound module (the String-voice physics + tarab editor + the Fret Pad / Controls tabs).

## iPad

The iPad's playing surface is the **Fret Pad** (full screen), replacing
the old piano keyboard. It is the same free-fret surface as the Mac Fret
Pad tab — see [Fret Pad](fret-pad.md) for the fret field, onset-only
snapping, drag assist, drone buttons, and octave-repeat
ghosts, all of which live in shared `TarabdaarCore` code
(`FretPadGeometry.swift`, `PitchPadEngine.swift`).

### Layout

- **Slim toolbar (top)**: PANIC, a **Rec** toggle (records play strokes for
  drag-assist fitting), a **GYRO** toggle (2026-08-14: floats a
  diagnostic overlay over the pad — a rotating 3D trail of RAW
  CoreMotion attitude with per-axis Δ° readouts, plus an
  accelerometer twin (raw `userAcceleration`, origin-centred, fixed
  ±0.5 g scale) beside it, both pre-high-pass and pre-wire, directly
  comparable against the Mac Setup tab's "Received motion (3D)" and
  "Received acceleration (3D)" views to split sensor noise from
  transmission artifacts), a scale-sync
  indicator,
  the raw **tilt pad** (an X-Y square fed by `NoteManager.currentTilt`:
  tilt 1 on x, tilt 2 on y (up = positive), the dot colored purple → cyan →
  orange as tilt 3 goes `-1 → 0 → +1`), a live `Hz (note ±cents)` readout
  tinted in the sounding pitch's hue, and a read-only Tonic readout.
  (No SCALE button and no editable tonic — scale, layout, and
  Snap are set on the Mac and synced over. There is no MAP button — the
  iPad's parameter mapping was deleted 2026-07-24 — and no Recalibrate:
  the iPad-side calibration was deleted 2026-08-13; the tilt axes run
  raw, and the Mac's body calibration is parked.)
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
three raw attitude axes and streams them as the **raw tilt report**
(`TiltAxisWire`, CCs 16/17/18 on channel 0, change-gated). The iPad knows
nothing about parameters, composites, or slots; TarabdaarMac evaluates its
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

Small text — captions, table columns, row labels, pad labels, graph annotations — comes from **`Typography`** (`Packages/TarabdaarCore/.../Typography.swift`), not from SwiftUI's stock styles. It carries **one constant, `smallScale` (1.2)**, and exposes the platform's own stock sizes scaled by it: `Font.padCaption` / `.padCaption2` / `.padSubheadline` / `.padCallout`, plus `Font.padSmall(_:weight:design:)` for the handful of places that size text to a drawn shape. macOS stock captions are 10 pt, which is too fine for the dense tables this UI is mostly made of; the whole app reads at 12. Fixed-width label and value columns pass their width through `Typography.scaledWidth(_:)` so the columns grow with the text instead of clipping it. **Display text is deliberately unscaled** — titles, headlines, the Live tab's big readouts — it is already legible and growing it would reflow the panels. Both platforms use the file, each scaled off its own stock sizes.

### Top bar

- **ConnectionPill** — shows USB-MIDI input status (`MIDI: N src` when sources are visible, `no MIDI in` otherwise). Click to pop a detailed status panel.
- **KeyboardPlayPill** — toggles computer-keyboard note input (off by default). The pill reads `Keys` (green) when on, `Keys off` otherwise; clicking opens a popover with the enable toggle, an **Octave shift** stepper (−3…+3), and a legend of the key layout. See **Computer keyboard** below.
- **Tab picker** — segmented control: Live / Strings / Fret Pad / Controls / Parameters / FX / Setup / Scope. ⌘1…⌘8 jump to each. (The Scope tab is the 2026-09-01 performance scope — see below.) (The Sarangi tab was removed in the 2026-07-24 parameter unification — its physics sliders and preset toolbar moved into **Parameters**. The FX tab is the 2026-08-01 four-insert rack — see [FX](fx.md).)

### Computer keyboard

The Mac can play notes from the **computer keyboard** (`KeyboardNotePlayer`, owned by `AppController` as `keyboard`; toggled from the top-bar KeyboardPlayPill, persisted). It plays through the **playing engine** (`controller.pitchPad`) — the same in-process MPE path the on-screen Fret Pad uses — so keyboard notes share the **scale, tonic, and Velocity**, sound identical to played notes, and feed the String voice like any other note.

- **Mapping = scale degrees, not 12-TET.** The three letter rows form one ascending ribbon (low→high): `Z X C V B N M , . /` then `A S D F G H J K L ;` then `Q W E R T Y U I O P`. Ribbon position `k` plays the `(k mod N)`-th enabled scale degree raised `floor(k / N)` octaves (`N` = enabled-degree count), so any scale size / JI tuning works and the keys play the scale exactly as drawn.
- **`[` / `]`** shift the whole ribbon down / up an octave (clamped −3…+3); shifting releases any held notes.
- **App-wide while enabled** via one local `NSEvent` monitor (key down/up). It **steps aside while a text field is being edited** (first responder is an `NSText`) and **ignores any key pressed with ⌘/⌃/⌥** so the ⌘1–9 tab shortcuts and menu commands still work. Auto-repeat is swallowed; held notes are released on app-focus loss so nothing sticks. Keys use **physical key codes** (`kVK_ANSI_*`), so the row shapes survive non-QWERTY layouts. Keyboard touches use a distinct touchId namespace (`1_000_000 + index`) so they never collide with mouse-played notes on the same engine. (`PitchPadEngine.clampRatio` is widened to ±5 octaves to cover the multi-octave ribbon.)

### Live tab

MIDI input status (source count + status message), an audio render-time readout, and two live **time-series graphs** of the currently-played voice: **PITCH** (log-frequency, y-axis fixed to the Fret Pad's playable range — labelled with the nearest note name + Hz) and **VOLUME** (the commanded CC11 Expression, 0–100%). Traces are drawn as smooth Catmull-Rom curves (rounding the sample-to-sample steps). Both read `AudioEngine.performanceReadout()` — derived at the single MIDI choke point, so they reflect every source (the USB iPad, the Mac Fret Pad, the simulator). The graphs show a fixed **6-second** window and scroll **smoothly**: a 60 Hz timer appends timestamped samples to a ring buffer and a `TimelineView(.animation)` redraws every display frame, placing each sample at an x set by its age, so the trace slides left continuously instead of stepping at the sample rate.

### Scope tab (⌘8) — the performance at a glance (2026-09-01)

`ScopeView.swift`. One **pitch field** — time along x (a fixed **8-second** window scrolling smoothly, the Live tab's timestamped-ring + `TimelineView` law: sampled at 60 Hz, redrawn at display rate in a `Canvas`; **2026-09-02 de-jitter** — every trace is ONE stroke per contiguous run, a Catmull-Rom spline for pitch lines / a polyline for lanes, filled with a linear gradient whose stops are the per-sample colours, so neither colour nor geometry is quantized into flickering runs), log-frequency along y with the **scale's own degree labels as gridlines** (every enabled degree in every octave inside the axis, `octaveMarked`; the tonic lines brighter; the axis = the scale's compass ± an octave, widened to cover every taraf row and every current pitch) — carrying three layers:

- **Touched pitches** (white halo lines, ○ at the right edge): every finger currently down, from the finger registry that the `.fingerAccel` dimension keeps (`AppController.currentTouches` — wire AND local lanes). It sits **above the glide queue**, so a parked or queued finger shows here even while the voice sounds elsewhere; on a plucked main instrument the touch line is the finger while the sounding line is the string.
- **Sounding pitches of the main voice** (**magma** by level — `ScopeColor.level`, the ONE level ramp shared with the iPad strike scope since 2026-09-02; ● + `label Hz` readouts at the right edge): one trajectory per **physical string** — the bowed slots' target pitch (mapper snapshot) + ring envelope (the kernel's per-string bridge-wave chunk peak, `bow_poly_scope_slots`), or the plucked instrument's strings at their **bent** pitch (`TanpuraEngine.scopeSlots` — mounted × last commanded bend) with the kernel's auto-idle envelope (`tanpura_slot_env`). Held strings draw thick, released-but-ringing ones thin. String identity is slot + generation, so a remount starts a new trajectory.
- **Taraf lanes**: every modal-jawari row as a horizontal line at its pitch whose **luminance is the row's radiated level** (its own peak envelope AFTER the per-string cap, in output units, on the iPad volume scope's 60 dB scale; 2026-09-02 — was opacity) and whose **hue is its harmonic character** (amber = fundamental-heavy … blue = the high jawari cluster: the energy-weighted spectral centroid of the kernel's per-mode radiated envelopes |φO_k·p_k|, modes 1–16, on a log mode axis, EMA-smoothed ~150 ms so the hue doesn't breathe with the mode beats). A silent row draws only a faint dotted resting line; the **melody follower's** lane moves with the played note (the kernel reports its slewed retune pitch). Ringing rows are labelled in the right gutter.

A legend explains the three encodings. The per-row panel moved to its own tab on 2026-09-02 (below).

### Taraf tab (⌘9) — the sympathetic rows, one strip each (2026-09-02)

`TarafScopeView.swift`, sharing `ScopeModel` with the Scope tab. Every modal-jawari row, pitch-sorted: the scale label (`scaleLabel(forRatio:)`; `follow` for the melody follower, `·c` for a chromatic-bridge row, a moon glyph + dimming for a row asleep under the quiescence gate), Hz, the radiated level (bar coloured on the lane hue + dB on the 60 dB scale), then two 16-mode spectra on 40 dB under the row's own peak, bars coloured by mode index on the taraf hue law:

- **Modal energy** — p_k² (the kernel's per-mode velocity envelopes squared): the string's energy per mode. Since 2026-09-03 the rows radiate their bridge contact force, which weighs every mode flat in these units, so this is also the row's radiated spectrum up to a constant — the jawari's upward cascade as it happens and as it is heard. (On 2026-09-02, for one day, the panel showed a "radiated vs modal" pair with the 0.90 L pickup's |sin(k·π·0.9)| comb overlaid — humps at modes 5/15, a NULL at mode 10, the "two clusters" every row showed; that comb was the pickup, not the body, and the pickup is gone.)
- The spectral centroid (mode units, EMA-smoothed like the lane hue).

The kernel read behind it is `bow_poly_scope_jt`'s per-mode modal envelopes; `ScopeTelemetryTests` pins the meters and `JtForceRadiationTests` the radiation.

**Plumbing.** `AudioEngine.scopeSnapshot()` (voices on whichever main instrument is armed + `BowEngine.ScopeRow`s) is polled at 30 Hz on the main queue by `ScopeModel`. The taraf meters live in the kernel (`bow_poly_scope_arm` / `_scope_jt`; per-row peak envelope every tick + per-mode envelopes every 4th tick, worker-owned, telemetry-grade racy reads like the gate probe) and are **armed only while the tab is showing** (`setScopeArmed` on appear/disappear, re-applied across rebuilds by `StringVoiceSource`); disarmed, the jt tick is the exact legacy code path and `ScopeTelemetryTests` pins the armed render byte-identical to the unarmed one — nothing here feeds the physics, and the parity hash is untouched.

### Strings tab (⌘2)

The sarangi's **sympathetic strings** (`StringsView`) — the rows tune the String voice's in-kernel taraf. Every string is a **scale degree + octave** of the centralized Pitch Pad scale, so pitches always follow the scale and the tonic — there is no follow toggle (removed 2026-07-25). The header holds a **"Regenerate from scale"** button (rebuild the default layout, discarding hand edits — the layout also regenerates itself when the scale's degree count changes) and a tonic readout (read-only — the tonic is set on the Fret Pad tab, in Hz). Below, the strings are **one flat table**: an **Enable all / Disable all** toggle, an add (+) button, and per-string rows (**Pitch** dropdown (the scale's degrees under the scale's own labels) / **Octave** dropdown (−2…+2) / read-only **Hz** / editable **Gain / t60 / On** + delete — no ratio or Hz inputs). Below the table, the **Drone buttons** section maps each of the 3 Fret Pad drone buttons to one of the strings. (The **Manual tuning** raga/tonic fallback was removed 2026-07-25.)

### Fret Pad tab (⌘3)

The sole playing surface on the Mac, and the editor for the surface the iPad mirrors (`FretPadView`). Free-fret segments, onset-only snapping, drag assist, drone buttons, and — since the 2026-07-23 simplification — the **scale selector + list editor + the tonic** (`ScaleListEditor`), moved here off the old Pitch Pad tab. The tonic is a **Hz field** (2026-07-25) with a note-name ± cents readout — **the app's one Hz input**; every other pitch (frets, tarab strings, drones) is a scale degree relative to it, and the fractional part rides the iPad sync blob so both devices agree to the cent. It edits `controller.pitchPad.scale`, the ONE centralized scale the frets / tarab / iPad-sync all read from. Full treatment: [Fret Pad](fret-pad.md).

### Controls tab (⌘4)

The **tilt bindings** + **composite parameters** (`TiltControlsView`). Per tilt 1/2/3, bind an arbitrary set of targets with configurable endpoints — a target is a **composite** *or* **any single parameter** (`MapTarget`), and endpoints are in the target's own units (0–1 for a composite, the parameter's native range otherwise). The Mac evaluates these itself; nothing is pushed to the iPad, which streams only its raw tilt report. **Composite parameters** are named 0–1 controls built from parameter members each sweeping lo→hi; ships with Taraf Purity / Taraf Decay / Tone Tilt / Expression on slots 1–4. The Add menus group every parameter exactly as the Parameters tab does. Composites and tilt bindings save **with the preset** — one `.tarabdaar` file from the Parameters tab (⌘5); the separate `.tarabdaarmap` save was folded in 2026-07-30 (old `.tarabdaarmap` files still load there). See [Sensors](sensors.md) and [Parameters](parameters.md).

### Parameters tab (⌘5) — the whole parameter list

**Every** parameter of the String instrument in one place (`ParametersView` over `ParamRegistry`), including the physics scalars that used to live in a separate Sarangi tab. Groups are collapsible — Bow stroke / Body / Bow & string / Playing ranges / Jawari taraf / Taraf / Articulation / Radiation & output — and **all of them start open**, since the tab is a reference surface and a knob behind a collapsed header costs more to find than the scroll costs; a filter box searches names, keys, and help text. Each row is a labelled slider in **native units** (out-of-range artifact values widen the slider rather than clamping), a numeric readout, a **mapping button** (bind to Tilt 1/2/3, add to a composite, or spin up a new composite from this parameter), chips showing what currently drives it, and a reset. Clicking a row label shows the parameter's raw key (e.g. `bow_jt_body` — the audition/registry name) and its description inline under the row (the hover tooltip carries the same text, but macOS shows tooltips unreliably); double-clicking a row label resets it. Rows tagged **"rebuild"** re-apply through a debounced off-main `BowEngine` rebuild; everything else is instant.

The header carries the **preset toolbar** (`PresetToolbar`) — ONE preset covering the whole rig (2026-07-30), and **no file panels**. The **Load preset** menu lists the shipped **"Default (Sarangi Live)"** (a full-rig factory reset: bank + untouched physics + default composites and tilt bindings), then every saved preset by name, then a **Delete preset** submenu. **Save preset…** pops a name field — the preset lands in the app-managed library (`Application Support/Tarabdaar/Presets/`) and appears in the menu immediately; saving an existing name overwrites it (the popover says so). A preset carries everything: the sarangi document (tarab table + tonic + model params), the physics overrides, every parameter's resting value, the composites and the tilt bindings. The 2026-07-24 instrument/controls split (`.tarabdaar` + `.tarabdaarmap` from separate tabs) is folded back together; dropping a split-era or legacy `.sarangi`-content file into the library folder (as `.tarabdaar`) lists it, and loading applies only the sections it carries.

**Reset all** clears both the physics overrides (`tarabdaar.stringOverrides.v1`) and every resting value (`tarabdaar.controlDefaults.v1`).

See [Parameters](parameters.md) for the generated per-key table and [Sarangi](sarangi.md) for what the physics mean.

### FX tab (⌘6) — the four-insert rack

One panel per insert point — **Voice → Taraf** (what the sympathetic strings hear), **Voice** (the main bus post-taraf-tap), **Taraf** (the web's own radiation), **Global** (the final stereo out) — each with a **graphic EQ** (10 vertical ±12 dB faders, octave centres 31.5 Hz–16 kHz, double-click a fader to zero it) and a **reverb** (Bigverb/Room segmented picker + mix/size/cutoff sliders, double-click a label to reset). Toggles glide, so switching FX in and out never clicks. A dot by the panel title marks an active point; **Reset** returns the point to all-off. Every control is a plain `fx_*` registry parameter (`FXView` drives `paramValue`/`setParamValue`), so the Parameters tab, presets, tilts and composites all see the same knobs. See [FX](fx.md).

### Setup tab (⌘7)

Audio output device picker, MIDI status, system info.
