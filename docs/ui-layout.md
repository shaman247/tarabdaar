# UI Layout

Two devices, two layouts. The iPad is the controller (touchscreen Fret Pad + tilt). The Mac is the sound module (the voices' physics, the tarab editor, and the Fret Pad / Controls / Parameters / FX / Scope tabs).

## iPad

The iPad's playing surface is the **Fret Pad** (full screen) — the same fifteen-row surface as the Mac's Fret Pad tab. All fifteen rows have equal height and independent pitch assignments. The fret field, onset-only snapping, drag assist and octave-repeat ghosts live in shared `TarabdaarCore` code (`FretPadGeometry.swift`, `PitchPadEngine.swift`); see [Fret Pad](fret-pad.md).

### Layout

- **Status overlay (top)** (`PadToolbarIOS`): shown only for a problem. **no sync** remains until the current live connection has supplied both scale and arrangement; USB/Bluetooth icons appear only while the TLP link is unavailable or stale. The antenna opens BLE-MIDI advertising. Cached layouts do not count as a fresh sync. A healthy connection hides the entire overlay, without moving or resizing the frets.
- **Fret Pad (full screen)**: always in perform mode, with colored fret lines on pure black and no vertical or horizontal gridlines. Touches have no rings, radius arcs, numeric readouts or sounding glow. The **chord bar** below the band is hidden for now (`Config.chordBarShown`).

The iPad has no taraf pluck or strumming buttons. The taraf strip lives on the Mac's Fret Pad tab.

The scale and fret layout are designed on the Mac's Fret Pad tab and synced over as TLP events (see [Scale sync](midi-and-audio.md#scale-sync-mac--ipad)).

The iPad has no recording button, performance readouts, diagnostic graphs, Panic button or Gyro button. **Rec** on the Mac Fret Pad tab records both pads into the Mac recordings folder and shows **Saving** while completed iPad strokes finish transferring. The Mac's Live tab holds the performance graphs and motion meters; Setup holds the received-motion diagnostics.

### Touch → pitch → wire

`TouchOverlayView` (UIKit multitouch) reports per-finger `(xFraction, yFraction)` over the pad's logical area. `FretPadSurfaceIOS` maps each to a pixel point, resolves the fret field / onset snap / drag assist, then drives `PitchPadEngine`: `noteOn` on touch-down, `glide` on move, `noteOff` on lift — each touch a wire identity with full-resolution pitch. A 60 Hz loop samples the three raw attitude axes into the same outbound state, so tilt rides every frame. The iPad knows nothing about parameters, composites or bindings; the Mac evaluates its own (`AppController.applyTiltAxis`).

### System UI

Status bar hidden; system overlays hidden (`.persistentSystemOverlays(.hidden)`); system gestures deferred on all edges; orientation locked to landscape right via AppDelegate + Info.plist.

## Mac

A single window with a top bar and eleven tabs.

### Typography

Small text — captions, table columns, row labels, pad labels, graph annotations — comes from **`Typography`** (`Packages/TarabdaarCore/.../Typography.swift`), not SwiftUI's stock styles. It carries **one constant, `smallScale` (1.2)**, and exposes the platform's stock sizes scaled by it: `Font.padCaption` / `.padCaption2` / `.padSubheadline` / `.padCallout`, plus `Font.padSmall(_:weight:design:)` for the places that size text to a drawn shape. macOS stock captions are 10 pt, too fine for the dense tables this UI is mostly made of; the whole app reads at 12. Fixed-width label and value columns pass their width through `Typography.scaledWidth(_:)` so columns grow with the text instead of clipping. **Display text is deliberately unscaled** — titles, headlines, the Live tab's big readouts. Both platforms use the file, each scaled off its own stock sizes.

### Top bar

- **ConnectionPill** — the iPad link: the bearer's icon (cable or antenna) and `USB 1.2 ms` / `Bluetooth 14 ms` in green when the handshake is up, `USB · stale` orange, `No iPad` yellow, `Link off` red. Click for the detailed link panel (the same one as the Setup tab's Connection section).
- **KeyboardPlayPill** — toggles computer-keyboard note input (off by default): `Keys` (green) when on, `Keys off` otherwise; the popover holds the enable toggle, an **Octave shift** stepper (−3…+3) and a key-layout legend.
- **Tab picker** — Live / Strings / Fret Pad / Controls / Parameters / FX / Setup / Scope / Taraf / Body / Transforms; ⌘1…⌘9 jump to the first nine, ⌘0 to Body.

### Final output strip

A persistent strip below every tab holds **Output gain** (−60…+24 dB, default 0), a slider and numeric dB entry, and two **Output peak · dBFS** meters for the complete stereo mix. Double-clicking the gain label restores 0 dB. L/R bars hold peaks briefly before falling, with readings below the display floor shown as ≤−60 dBFS; each channel also shows its maximum since reset. The meters follow the linked stereo limiter (default −1 dBFS sample ceiling); **LIMIT** shows its attenuation in dB and turns amber when active. **CLIP** latches red at digital full scale or invalid audio, and **Reset meters** clears output peaks, bus RMS maxima, the gain-reduction hold and the clipping indicator. Meter snapshots are nondestructive, so changing tabs cannot lose an overload. The gain is the ordinary `output_gain_db` parameter and includes all three voices, drones, effects and tails. **Parameters → Output · Final** also exposes **limiter ceiling (dBFS)**, **limiter lookahead (ms)** and **limiter release (ms)**, defaulting to −1, 5 and 120 respectively. All four output controls save with presets.

The second row, **Bus RMS · dBFS · Pre-output gain**, shows **Main** (orange), **Chromatic taraf** (cyan) and **Raga taraf** (purple). Each has a current interval-RMS bar/value and its maximum RMS since **Reset meters**. The existing 60 Hz meter relay retains maxima even between display frames and while other tabs are open; UI reads never consume an audio interval. These are source-bus measurements before final output gain and limiting. The bank taps also precede shared taraf FX, and Main excludes the separate drone voice. They diagnose sustained bus bloom; the L/R meters above continue to show the complete protected output’s sample peaks.

### Computer keyboard

`KeyboardNotePlayer` (owned by `AppController` as `keyboard`, persisted) plays through the **playing engine** (`controller.pitchPad`) — the same in-process path the on-screen Fret Pad uses — so keyboard notes share the scale and tonic and sound identical to played notes.

- **Mapping = scale degrees, not 12-TET.** The three letter rows form one ascending ribbon (low → high): `Z X C V B N M , . /`, then `A S D F G H J K L ;`, then `Q W E R T Y U I O P`. Ribbon position `k` plays the `(k mod N)`-th enabled degree raised `floor(k / N)` octaves (`N` = enabled-degree count), so any scale size works.
- **`[` / `]`** shift the ribbon down / up an octave (clamped −3…+3); shifting releases held notes.
- **App-wide while enabled** via one local `NSEvent` monitor. It steps aside while a text field is being edited and ignores keys pressed with ⌘/⌃/⌥, so the tab shortcuts and menus still work. Auto-repeat is swallowed; held notes release on focus loss. Keys use **physical key codes** (`kVK_ANSI_*`), so the row shapes survive non-QWERTY layouts. Keyboard touches use a distinct touchId namespace (`1_000_000 + index`) so they never collide with mouse-played notes.

### Live tab (⌘1)

The **Instrument picker** — String (bowed) / Tanpura (plucked) / Sitar (plucked) — and link status lead a scrollable monitor. Wrist tilt, rate and acceleration bars, the Joy-Con stick square and the arm square appear above the graphs. The arm square uses calibrated axes when available and received raw tilt otherwise.

Four graphs share a **6-second** window, sampled at 60 Hz and redrawn at display rate:

- **PITCH**: held pitch in log-frequency, with the Fret Pad's playable range and note-name/Hz readout.
- **VOLUME**: separate Main (orange), Chromatic (cyan) and Raga (purple) traces and dB readings on the −60…0 dBFS scale, including released tails.
- **STRIKE**: the received iPad strike envelope before Mac binding smoothing, displayed on the 0–127 scale.
- **FINGER ACCEL**: the newest held finger's signed pitch acceleration, −1…+1, using a display-only `FingerAccelTracker` over the Mac's wire/local touch registry. It works without a binding.

Pitch and all three volume traces read the nondestructive `AudioEngine.performanceReadout()` cache. The existing `VolumeMeterRelay` remains the sole reader of the audio meters. Touch release clears pitch without hiding ringing tails. The graphs use timestamped samples and Catmull-Rom curves; monitoring does not feed the control or audio path.

### Strings tab (⌘2)

The sympathetic strings (`StringsView`) appear in matching **Raga taraf**
and **Chromatic taraf** tables, each with its own count, Enable/Disable all,
add button and reset action. Raga has **Regenerate from scale**; chromatic has
**Reset chromatic set**. Each table stays pitch-sorted with one string per
pitch. Rows show Pitch, Octave, Hz, Gain, t60 and On. Raga pitches follow the
scale; chromatic rows retain either scale references or fixed-JI semitones.
The header shows the shared tonic. Raga natural physical decay is fitted;
its row t60 enters level normalization. See [Sarangi](sarangi.md).

Below the tables, **Drone buttons** selects the drone Voice (Tanpura /
Sympathetic strings), maps the three Fret Pad buttons and edits the drone
sequence (the bundled Strings Default uses 1 → 2 → 3). Tanpura octave shows −1 or 0. The controller
strum section selects the strings used by the main voice's held chord.

The top of Strings has a preset menu with **Save As…**, save to the current
name, **Save as Default**, **Load** and **Delete**. One setup includes both
banks, drone/strum mappings, drone voice and sequence.
Loading preserves the active scale and tonic. **Default** is always available;
existing working edits remain autosaved independently.

### Fret Pad tab (⌘3)

In Edit mode, every scale pitch appears in all fifteen rows. Left-click toggles the pitch in that row; unassigned frets are gray. This edits the layout independently of sympathetic strings. The Default layout has 39 assignments in rows 1–9; rows 10–15 start empty. The surface spans 2.8 octaves; Pilu remains a separate built-in alternative.

Each pitch column has one scale label centred below the playable band. Labels use the pitch color if any row in the column is assigned and gray otherwise; Perform mode hides them.

Vertical scale-pitch gridlines remain visible on the Mac in both Edit and Perform modes, with slightly brighter tonic lines. All row backgrounds are pure black, with thin horizontal gridlines between rows and no enclosing border. The iPad keeps the black background and hides both sets of gridlines.

The sole playing surface on the Mac and the editor for the surface the iPad mirrors (`FretPadView`): fifteen adjacent rows of equal-height, frequency-aligned frets, the Snap distance, drag assist, the chord bar, and the **scale selector + list editor + the tonic** (`ScaleListEditor`). The tonic is a **Hz field** with a note menu and a ± cents readout — **the app's one Hz input**; every other pitch is a scale degree relative to it. It edits `controller.pitchPad.scale`, the ONE centralized scale the frets / tarab / iPad sync all read. See [Fret Pad](fret-pad.md) and [Scales & Tuning](scales-and-tuning.md).

The pluckable **raga taraf strings** form one row immediately above the playable fret band, inside the Mac surface and aligned to its left edge. It spans the full band width regardless of Joy-Con connection. Chromatic strings are omitted. Click to pluck or drag across the row to strum.

### Controls tab (⌘4)

The joystick has four separately bindable dimensions: **Stick Left**, **Stick Right**, **Stick Up**, and **Stick Down**. They also appear separately in the Parameters tab's mapping menu.

Binding sliders show signed offsets, with the base value in amber above the zero tick on the offset track. There is no separate base slider in binding rows or explanatory section copy. Edit a composite's base with its Rest control, or a parameter's base in the Parameters tab. All rows for the same target share the base; changing it leaves the offsets fixed. Bipolar mappings anchor zero at the gesture's centre; one-way mappings linearly interpolate between two independently editable offsets. Composite-member sliders continue to show absolute member values.

Acceleration smoothing + motion bindings + composite parameters (`TiltControlsView`). Three shared **Tilt ↕/↔/⟲** dimensions automatically use a connected controller, otherwise the iPad; each device retains its separate calibration in Setup. Binding rows and menus put tilt, Joy-Con acceleration and stick first, then touch dimensions. The top panel exposes independent iPad and Joy-Con smoothing times (0–1000 ms), using the registry values and preset store. Per dimension, bind any set of targets with configurable endpoints — a target is a **composite** *or* **any single parameter** (`MapTarget`), endpoints in the target's own units (0–1 for a composite, the parameter's native range otherwise). Several dimensions may bind one target: each adds its evaluated **offset** to the target's base value, and the sum is clamped once — see [Sensors](sensors.md#binding-model). The Mac evaluates these itself; the iPad streams only raw axes. **Composite parameters** are named 0–1 controls built from parameter members each sweeping lo→hi, with a **Rest** slider (the base value before binding offsets); the defaults are Taraf Purity / Taraf Decay / Tone Tilt / Expression on slots 1–4. The Add menus group parameters as the Parameters tab does. Composites and bindings save with the preset. See [Sensors](sensors.md) and [Parameters](parameters.md).

### Parameters tab (⌘5)

**Every** parameter in one place (`ParametersView` over `ParamRegistry`), in collapsible groups that all start open, with the group header pinned while you scroll; a header shows the group's row count and how many rows sit off their default, and a click collapses it (**Collapse all / Expand all** in the filter bar). The list is lazy — only the rows on screen exist — and each row redraws only when its own value, default or mappings change, so the tab opens instantly and a slider drag touches one row. The filter bar holds the search box (⌘F; matches names, groups, keys and help text) and an **All / Changed / Mapped** picker (rows moved off their default; rows driven by a tilt or a composite). Each row is a labelled slider in **native units** (out-of-range values widen the slider rather than clamping), a numeric readout (**click it to type an exact value** — Return commits, Escape cancels; a changed value reads brighter than a default one), chips showing what drives it, a **mapping button** that opens a popover of checkboxes (every dimension, every composite, and *New composite from this*), and a reset. Clicking a row label shows the raw key (e.g. `bow_jt_body`) and its effect, separately labelled **Low** and **High** descriptions, scope and timing inline; hovering it shows the description; double-clicking resets it. The timing field distinguishes **onset**, **live**, **in-place**, **rebuild** and **hybrid** updates; in-place edits are debounced without losing the existing ring, while rebuild edits replace the engine. The **FX rack** group is the one exception to "one row per parameter": it is ONE insert definition instantiated at four points, so it lists **four collapsible inserts** (each header showing the point's name, what it is currently doing — `off`, `EQ 3 pts`, `Bigverb 20% wet` — and what it processes) with that point's 7 knobs inside, closed by default; the filter box opens them and searches the knobs as usual. The EQ curve's points are edited on the FX tab, not here.

Groups identify the affected voice or stage, then function: String bow/attack/recovery/sustain/slide/physics groups, Body resonances/formants/bridge interaction, the three Taraf groups, Tanpura and Sitar voice controls, Output mix/tone/room, Controls gesture groups and the FX rack. The [configuration reference](config-reference.md#parameter-organization-and-descriptions) lists the full grouping. Descriptions state dependencies and explain zero, neutral and selector values; the same registry text appears in the generated reference and search. Outside a group, ordinary parameter labels include their full group name; FX labels include their insert point.

Taraf parameters have three peer groups: **Taraf · Shared**, **Taraf · Raga**,
and **Taraf · Chromatic**. Both bank groups start with **level** and **decay
normalization**; their remaining controls describe their respective models. Searching
"raga", "chromatic" or "shared" finds the corresponding group. Gesture
bindings, composite members and mapping popovers retain the group-qualified
name, so the two level controls remain distinguishable outside their sections.
The inactive legacy `bow_jt_evolve` knob is not offered. [Parameter ownership](sarangi.md#parameter-ownership)
lists the exact keys and effects.

The header carries the **preset toolbar** — ONE preset covering the whole rig, **no file panels**. **Load preset** lists the shipped default (a full-rig factory reset: bank + untouched physics + default composites and bindings), then every saved preset by name, then a **Delete preset** submenu. **Save preset…** pops a name field; the preset lands in the app-managed library (`Application Support/Tarabdaar/Presets/`, one `.tarabdaar` file each) and appears in the menu at once; saving an existing name overwrites. A preset carries the sarangi document, the physics overrides, every resting value, the composites and the tilt bindings; every section is optional, so a file carrying only some of them loads what it has. **Reset all…** asks for confirmation, then clears the physics overrides (`tarabdaar.stringOverrides.v1`), every resting value (`tarabdaar.controlDefaults.v1`) and the FX curves; composites and tilt bindings stay. See [Parameters](parameters.md) and [Sound Design](sound-design.md).

### FX tab (⌘6)

One panel per insert point — **Voice → Taraf**, **Voice**, **Taraf**, **Global** — each with an **EQ curve** and a **reverb** (Bigverb/Room picker + mix/size/cutoff; double-click a label to reset). The EQ is a curve editor: log frequency 20 Hz–20 kHz across, ±14 dB up. **Single-click empty space to add a point** (up to 12), **drag a point** to move it in frequency and gain (it cannot cross its neighbours; a readout follows it), **single-click a point to remove it**. The drawn line is the insert's realised response through the points, flat beyond the outermost ones; the **amount** slider beside the toggle scales the whole curve (the one bindable handle). Toggles and curve edits crossfade, so nothing clicks. A dot by the title marks an active point; **Reset** returns the point to all-off and clears its curve. The knobs are plain `fx_<point>_<knob>` registry parameters — derived from the registry's ONE insert definition (`ParamRegistry.fxPoints` drives this tab's panels), so the Parameters tab (four collapsible inserts), presets, tilts and composites see the same knobs; the curve's points are carried by presets as their own section. See [FX](fx.md).

### Setup tab (⌘7)

Four stacked panels: **Joy-Con**, **Audio** (output device picker), **MIDI** (TLP transport status), and **Connection** (the iPad link: bearer, endpoint, handshake, round trip and peer TLP version; sources and their received frames). The Joy-Con section leads with connection status and **wrist calibration**, followed by controller inputs, stick calibration and motion diagnostics. **Arm fallback** is a collapsed disclosure containing arm calibration. Received motion/acceleration views show the iPad sensor stream on the Mac. See [Sensors](sensors.md).

### Scope tab (⌘8)

`ScopeView.swift`. One **pitch field** — time along x (a fixed **8-second** window scrolling smoothly on the Live tab's timestamped-ring + `TimelineView` law, sampled at 60 Hz, redrawn at display rate in a `Canvas`; every trace is ONE stroke per contiguous run, a Catmull-Rom spline for pitch lines / a polyline for lanes, filled with a gradient of the per-sample colours), log-frequency along y with the **scale's own degree labels as gridlines** (every enabled degree in every octave inside the axis, `octaveMarked`, tonic lines brighter; the axis = the scale's compass ± an octave, widened to cover every taraf row and current pitch) — carrying three layers:

- **Touched pitches** (white halo lines, ○ at the right edge): every finger currently down, from the finger registry the `.fingerAccel` dimension keeps (`AppController.currentTouches` — wire AND local lanes). It sits **above the glide queue**, so a parked or queued finger shows here even while the voice sounds elsewhere; on a plucked instrument the touch line is the finger while the sounding line is the string.
- **Sounding pitches of the main voice** (**magma** by level — `ScopeColor.level`, the shared level ramp; ● + `label Hz` readouts at the right edge): one trajectory per **physical string** — the bowed slots' target pitch + ring envelope (the kernel's per-string bridge-wave chunk peak, `bow_poly_scope_slots`), or the plucked instrument's strings at their **bent** pitch (`TanpuraEngine.scopeSlots`) with the kernel's auto-idle envelope. Held strings draw thick, released-but-ringing ones thin. Identity is slot + generation, so a remount starts a new trajectory. A held bowed string's readout also carries its **regime**: `f2.8` = the kernel's fundamental dominance (Helmholtz motion ≈ 2.5–3.5, an overtone lock under 1) and a `grip` tag, in orange, while the regime grip is correcting the bow ([Sarangi](sarangi.md)).
- **Taraf lanes**: every modal-jawari row as a horizontal line at its pitch whose **luminance is the row's radiated level** (its own peak envelope after the per-string cap, in output units, on the 60 dB scale) and whose **hue is its harmonic character** (amber = fundamental-heavy … blue = the high jawari cluster: the energy-weighted spectral centroid of the kernel's per-mode radiated envelopes, modes 1–16, on a log mode axis, EMA-smoothed ~150 ms). A silent row draws only a faint dotted resting line. Ringing rows are labelled in the right gutter.

A legend explains the three encodings.

### Taraf tab (⌘9)

`TarafScopeView.swift`, sharing `ScopeModel` with the Scope tab. Every modal-jawari row, pitch-sorted, one strip each: the scale label (`scaleLabel(forRatio:)`; `·c` for a chromatic-bridge row, a moon glyph + dimming for a row asleep under the quiescence gate), Hz, the radiated level (bar coloured on the lane hue + dB on the 60 dB scale), the **modal energy** spectrum — p_k² over modes 1–16 on 40 dB under the row's own peak, bars coloured by mode index on the taraf hue law (the rows radiate their bridge contact force, which weighs every mode flat, so this is also the row's radiated spectrum up to a constant — the jawari's upward cascade as it happens) — and the spectral centroid (mode units, EMA-smoothed like the lane hue).
The termination (pin) force the rows also radiate needs no change here: it
contributes k·q_k per mode, which is p_k up to the row's ω_1, so the displayed
modal energy is already that weighting too — the strip reads as the radiated
spectrum.

### Body tab (⌘0)

`BodyView.swift`. The formula body's frequency response **as built into the running String engine** (`BowEngine.bodyResponse`, evaluated from the engine's own modal tables and radiation-chain sections — nothing is measured, nothing feeds the physics), on a 40 Hz–20 kHz log axis: **radiation** (bridge force → radiated pressure through the modal bank plus the flat `bow_body_c0` term; thin) with its **±⅙-octave envelope** (thick), **at the ear** (the same after the radiation LP/HP sections and the bridge hill — what leaves the instrument before the room), and the **bridge admittance** (bridge force → bridge velocity, the loop side the string feels; dim). A lane under the floor ticks every mode (height = its radiation residue), and the tonic's harmonics are faint verticals, so you can read where Sa's partials sit on the peaks and nulls. The header reports the mode count, the 300–6000 Hz ripple std and range, local peaks per octave and the capped bridge return. Hover for a readout at any frequency. `BodyModel` polls `AudioEngine.stringVoiceEngineIdentity()` at 2 Hz on the main actor while the tab is visible and recomputes only when the engine was rebuilt, so a Body-group edit on the Parameters tab redraws after its debounced rebuild.

**Plumbing.** `AudioEngine.scopeSnapshot()` (voices on whichever main instrument is armed + `BowEngine.ScopeRow`s) is polled at 30 Hz on the main queue by `ScopeModel`. The taraf meters live in the kernel (`bow_poly_scope_arm` / `_scope_jt`; per-row peak envelope every tick + per-mode envelopes every 4th tick, worker-owned, telemetry-grade racy reads) and are **armed only while a scope tab is showing** (`setScopeArmed` on appear/disappear, re-applied across rebuilds by `StringVoiceSource`); disarmed, the jt tick is the exact production code path, and `ScopeTelemetryTests` pins the armed render byte-identical to the unarmed one — nothing here feeds the physics.

### Transforms tab

Expression, Position and Pressure each have a graphical input/output curve.
Click empty graph space or **Add point** to add a point, drag a point to move it,
and use **Remove point** to delete the selection. Selected points also expose
numeric Input and Output fields. Endpoints stay at input 0 and 1 and have
editable output values; interior points stay ordered. There can be up to 64
points per curve. **Identity** restores a diagonal; **Factory curve** restores
the fitted default for that axis. The graph and audio use the same bounded
linear interpolation. Edits apply to held notes in place and persist across
launches, presets and engine rebuilds. Curves are separate from the Parameters
tab and from gesture/composite binding targets. Existing tab shortcuts stay
unchanged; Transforms follows Body in the tab picker.
