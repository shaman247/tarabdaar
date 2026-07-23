# UI Layout

Two devices, two layouts. The iPad is the controller (touchscreen Pitch Pad + tilt). The Mac is the sound module (hosted-AU host + the sarangi-model editor + the tanpura/sitar tabs).

## iPad

The iPad's playing surface is the **Pitch Pad** (full screen), replacing
the old piano keyboard. It is the same 2D Voronoi-cell JI surface as the
Mac Pitch Pad tab — see [Pitch Pad](pitch-pad.md) for the cell geometry,
soft-margin glide, octave-repeat ghosts, and OKLCH colors, all of which
live in shared `StarpadCore` code (`PitchPadGeometry.swift`,
`PitchPadEngine.swift`).

The iPad can also show the **Chord Pad** (hex grid) instead — it follows the
Mac's **active tab** (switch the Mac to the Chord Pad or Pitch Pad tab and
the iPad follows), pushed over the synced state (`ContentView` swaps on
`pad.layout`). See [Chord Pad](chord-pad.md). The toolbar and tilt/MAP
behavior below are the same on both surfaces.

### Layout

- **Slim toolbar (top)**: PANIC, MAP (open the dimension-mapping matrix),
  the three calibrated **tilt bars** (T1/T2/T3, center-zero `-1…+1` meters
  fed by `NoteManager.currentTilt`), a live `Hz (note ±cents)` readout
  tinted in the sounding pitch's hue, a read-only Tonic readout, and
  Recalibrate. (No SCALE button and no editable tonic — scale, tonic, and
  margin are all set on the Mac and synced over.)
- **Pitch Pad (rest of screen)**: the playing/rendering surface. The iPad
  is **always in perform mode** — no control discs and no octave boundary
  lines, just the cell outlines, the black field, and the live sounding
  fills (the Mac tab keeps a PERFORM toggle for its editing chrome).
  Touching a cell sounds its ratio; dragging glides through cells
  (soft-margin blend); multiple fingers play polyphonically, each on its
  own MPE channel. Inner-cell borders are tinted by pitch; the sounding
  cell(s) fill with their hue, cross-faded by the same weights that drive
  the pitch.

The pad is **perform-only** on iPad — there's no scale editor. Scales are
designed on the Mac Pitch Pad tab and synced to the iPad over USB-MIDI
SysEx (see [Scale sync](midi-and-audio.md#scale-sync-mac--ipad)).

### Touch → pitch → MIDI

`TouchOverlayView` (UIKit multitouch) reports per-finger `(xFraction,
yFraction)` over the pad's logical area. `PitchPadSurfaceIOS` maps each to
a pixel point and calls the shared `pitchAt(...)` soft-Voronoi solver to
get a ratio + per-cell fill weights, then drives `PitchPadEngine`:
`noteOn` on touch-down (pins the nearest semitone to the tonic and bends
to the ratio), `glide` on move (bend only), `noteOff` on lift. The pitch
tracks the finger directly. See
[Pitch Pad — MIDI signal path](pitch-pad.md#midi-signal-path).

### Tilt expression

On top of position→pitch, the iPad keeps its signature tilt expression.
`PitchPadEngine` runs a 60 Hz loop (iPad init only) that reads the bound
`DimensionMapping` values via the still-resident `NoteManager` (kept alive
purely as the tilt sampler + mapping host — its keyboard/glide voice paths
stay idle) and, per held touch, re-sends a pitch bend tracking the
position ratio, plus channel pressure (aftertouch) and any mapped CCs.
Map a tilt axis to aftertouch / a CC in the MAP matrix to engage it.

### Scale sync (Mac → iPad)

The iPad has no scale editor. The Mac's Pitch Pad tab edits the scale and
pushes it to the iPad over USB-MIDI SysEx (live, debounced, and on connect);
a `ScaleSyncReceiver` on the iPad applies it. See
[MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad).

### Parameter Mapping Panel (MAP button)

A full-screen matrix panel (rows = parameters, columns = dimensions) with
a curve editor on the right third. Opened via the MAP button, dismissed by
its header. The matrix and curve editor are unchanged from before; only
the way it's reached moved (the old top-half swipe is gone).

**Matrix (left 2/3):**
- Each cell is a possible dimension→parameter binding. Tap to connect /
  select, long-press to disconnect. Connected cells show a mini curve.
- Cells can be dragged to move bindings; many:many is allowed.

**Curve editor (right 1/3):**
- The selected binding's transfer curve with 2–4 draggable control points
  (Catmull-Rom). X = dimension input, Y = parameter output.

**Performance:** opening MAP sets `NoteManager.paused`, which freezes tilt
sampling while editing.

## System UI (iPad)

- Status bar: hidden
- System overlays: hidden (`.persistentSystemOverlays(.hidden)`)
- System gestures: deferred on all edges (`.defersSystemGestures(on: .all)`)
- Orientation: locked to landscape right via AppDelegate + Info.plist

## Mac

A single window with a top bar and twelve tabs.

### Top bar

- **ConnectionPill** — shows USB-MIDI input status (`MIDI: N src` when sources are visible, `no MIDI in` otherwise). Click to pop a detailed status panel.
- **PresetMenu** — dropdown of `SoundPreset` cases. Picking one runs `AppController.applyPreset(_:)`, which loads the hosted AU + its dry-SWAM params and FX in one go. Only **SWAM Violin** ships today; the menu is kept so future hosted-AU presets can drop in without re-plumbing. (The sarangi model itself is not part of the preset — it's edited and persisted independently in the Sarangi tab.)
- **HostedAUPill** — shows MIDI events forwarded + the AU's output peak, with buttons to open the AU's own view (SWAM's configuration UI), reset CCs, and reload the AU instance.
- **KeyboardPlayPill** — toggles computer-keyboard note input (off by default). The pill reads `Keys` (green) when on, `Keys off` otherwise; clicking opens a popover with the enable toggle, an **Octave shift** stepper (−3…+3), and a legend of the key layout. See **Computer keyboard** below.
- **Tab picker** — segmented control: Live / Harmonics / Sarangi / Tarab / FX / Simulator / Pitch Pad / Chord Pad / String Pad / Tanpura / Sitar / Setup. ⌘1…⌘9 jump to the first nine — Live…String Pad (Tanpura, Sitar, and Setup have no shortcut — ⌘ stops at String Pad = ⌘9).

### Computer keyboard

The Mac can play notes from the **computer keyboard** (`KeyboardNotePlayer`, owned by `AppController` as `keyboard`; toggled from the top-bar KeyboardPlayPill, persisted). It plays through the **Pitch Pad engine** (`controller.pitchPad`) — the same in-process MPE path the on-screen pad uses — so keyboard notes share the Pitch Pad **scale, tonic, and Velocity**, sound identical to clicked notes, and feed the sarangi/SWAM chain like any other note.

- **Mapping = scale degrees, not 12-TET.** The three letter rows form one ascending ribbon (low→high): `Z X C V B N M , . /` then `A S D F G H J K L ;` then `Q W E R T Y U I O P`. Ribbon position `k` plays the `(k mod N)`-th enabled scale degree raised `floor(k / N)` octaves (`N` = enabled-degree count), so any scale size / JI tuning works and the keys play the scale exactly as drawn.
- **`[` / `]`** shift the whole ribbon down / up an octave (clamped −3…+3); shifting releases any held notes.
- **App-wide while enabled** via one local `NSEvent` monitor (key down/up). It **steps aside while a text field is being edited** (first responder is an `NSText`) and **ignores any key pressed with ⌘/⌃/⌥** so the ⌘1–9 tab shortcuts and menu commands still work. Auto-repeat is swallowed; held notes are released on app-focus loss so nothing sticks. Keys use **physical key codes** (`kVK_ANSI_*`), so the row shapes survive non-QWERTY layouts. Keyboard touches use a distinct touchId namespace (`1_000_000 + index`) so they never collide with mouse-played notes on the same engine. (`PitchPadEngine.clampRatio` is widened to ±5 octaves to cover the multi-octave ribbon.)

### Live tab

MIDI input status (source count + status message), an audio render-time readout, and two live **time-series graphs** of the currently-played voice: **PITCH** (log-frequency, y-axis **fixed to the String Pad's lowest and highest playable pitches** — base strings plus their octave-repeat ghosts, via `stringPadRatioRange` — labelled with the nearest note name + Hz) and **VOLUME** (the commanded CC11 Expression, 0–100%). Traces are drawn as smooth Catmull-Rom curves (rounding the sample-to-sample steps). Both read `AudioEngine.performanceReadout()` — derived at the single MIDI choke point, so they reflect every source (the USB iPad, the Mac pads, the simulator). The graphs show a fixed **6-second** window and scroll **smoothly**: a 60 Hz timer appends timestamped samples to a ring buffer and a `TimelineView(.animation)` redraws every display frame, placing each sample at an x set by its age, so the trace slides left continuously instead of stepping at the sample rate. No keyboard rendering, because the Mac has no scale concept to map MIDI notes against.

### Harmonics tab (⌘2)

The **Harmonics tab** (⌘2) shows a live **harmonic heatmap** (`HarmonicHeatmap`) of which harmonics are ringing in the sarangi voice and how loud — the sympathetic strings flaring in and out of resonance as the played pitch slides. **X-axis = columns**: a leading **Played note** column (the bowed SWAM violin — the exciter) then the **sympathetic strings grouped by choir** (Chromatic / Scale-tuned / Low octave / Upper octave, with separators + group headers), each sorted by ascending pitch; per-string labels run rotated along the bottom. **Y-axis = log frequency** (lowest string up to 8 kHz). Each harmonic is a colored band at its effective pitch (k·f₀); **color = intensity** (dB → indigo→magenta→orange→yellow heat, relative to a slow-decaying 0 dB reference so quiet stays dark). A sidebar lists the **10 loudest harmonics** (column · harmonic # · effective pitch in Hz + note name).

The data comes from `AudioEngine.sarangiBankSnapshot()` — a brief lock-held copy of each `CombString`'s one-period delay buffer (its DFT yields that string's harmonic amplitudes directly) plus a short input ring for the played note; the heatmap caption notes it is **bank energy, pre-FX**. The (off-lock) DFT runs in `BankAnalyzer.analyze`; the view polls at ~30 Hz, one-pole-smooths each (column, harmonic) magnitude to quell single-period jitter, and weights each string by its audible mix contribution (`relOverSqrtN·gChoir·symGain·mixBank`; the played note by `mainGain·mixDry`). See [Sarangi — harmonic display](sarangi.md).

### Sarangi tab (⌘3)

The sarangi model's **timbre** (`SarangiEditorView`, backed by `SarangiStore`) — a single column:
- **Toolbar**: a **Load preset** menu (`Sarangi — E♭ (fitted)` / `Sarangi — D Bhairav (fitted)` / `pair1` / `pair2`), **Reset params** (48 params → defaults, keeps tuning), and **Save…/Load…** (export/import a `.sarangi` JSON document).
- **Model parameters**: the 48 `SarangiKit` params as sliders in collapsible groups — **Bank / Jawari / Body / Reverb / Mix** (each from `ParamSpec`, labelled and ranged) — plus an **Output** (`gout`) slider in the header. See [Config Reference](config-reference.md#sarangi-model-mac).

Reverb / filter / EQ for the sarangi are no longer here — they're the per-voice FX rack in the **FX tab** (⌘5) below. Param edits route through `SarangiStore`: a live-scalar push (gains/mixes) or a debounced structural rebuild. Open SWAM's own UI (via the HostedAUPill) to edit the bowed-violin timbre. The **sympathetic strings + tuning live in the Tarab tab** below.

### Tarab tab (⌘4)

The sarangi's **sympathetic strings** (`TarabView`). By default the bank **auto-tunes to the Pitch Pad scale** (the tonic + notes you play) — the physical sarangi behaviour. A header **"Follow the Pitch Pad scale"** switch + **"Re-sync"** button control this; a tonic readout shows the current pitch. Below, the strings are grouped into the four physical choirs, one collapsible section each:
- **Chromatic** — 15 fixed JI-chromatic strings, always present.
- **Scale-tuned** — the scale degrees (+ Sa/Pa doublings), following the current scale.
- **Low octave** / **Upper octave** — octave repeats of the tonic / fifth / scale degrees.

Each section has a count, an **Enable all / Disable all** toggle, an add (+) button, and per-string rows (editable **Note / Freq (Hz) / Gain / t60 / Bright / On** + delete). Editing a string, toggling a choir, or using the **Manual tuning** fallback (a **Raga** picker + **Tonic**/Set/Transpose/Regenerate) detaches auto-sync so your edits stick; the switch / Re-sync button re-engages it.

### FX tab (⌘5)

The sarangi's **per-voice FX rack** (`FXView`) — three sections, one per stage:

- **Violin** — the bowed voice (dry + jawari). Also hosts **Drive (SWAM→model)** (moved here from the old Master-FX section). **On by default** (a touch of reverb + an open filter).
- **Sympathetic** — the sympathetic bank. **Off by default** (dry).
- **Global** — applied to the summed voices (mid/side, so off is an exact passthrough). **Off by default.**

Each section has an **enable** toggle, a **reverb** (mix + width), a **filter** (cutoff + resonance), and a **3-band parametric EQ**. The model splits its output into the two voices, applies the per-voice stages, sums, then applies the Global stage. Enable + reverb mix/width are live; filter / EQ / reverb rt60 trigger a debounced rebuild. The defaults intentionally drop the old block-F Sarangi-Live reverb match. See [Sarangi — FX rack](sarangi.md#fx-rack-the-fx-tab-5).

### Pitch Pad / Chord Pad / String Pad tabs

Three Mac playing surfaces. The **Pitch Pad** (⌘7) is the scale design +
playing surface shared with the iPad — see [Pitch Pad](pitch-pad.md). The
**Chord Pad** (⌘8) is a hex grid for playing chords off the same scale
(columns are diatonic chords, rows are chord tones) — see
[Chord Pad](chord-pad.md). The **String Pad** (⌘9) is a box-plot / abacus
where pitch shapes are dragged and resized along vertical gridlines, with the
same fixed-inside / interpolated-between behavior generalized to arbitrary 2D
polygons — see [String Pad](string-pad.md). All three are Mac-only-edited and
read the scale/tonic from the Pitch Pad.

The Pitch Pad scale is the configured *playing* scale, and the sarangi's
sympathetic strings (the **Tarab tab**, ⌘4) **auto-tune to it by default** — the
tarab resonates with the notes you play. You can detach the tarab (hand-edit or
the raga fallback) for independent tuning. See [Scales and Tuning](scales-and-tuning.md) and
[Sound Design — Sympathetic strings](sound-design.md#sympathetic-strings--the-editable-bank).

### Setup tab

Audio output device picker, MIDI status, system info.
