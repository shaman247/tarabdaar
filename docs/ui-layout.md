# UI Layout

## Screen Split

The screen is divided into three horizontal regions:
- **Top (~42%)**: Information displays (dimension values, pitch graph), with a debug overlay and sliders
- **Middle strip (~13%)**: Full-width voice-stem plot — shows the current base-voice pitch and every sympathetic voice's pitch + amplitude as vertical stems on a log-frequency axis
- **Bottom (~45%)**: Interactive piano keyboard with touch overlay

## Top Half

### Left Side: Dimension & Controls Panel

- **Dimension rows**: Shows current values for each active dimension (Tilt 1/2/3 always shown; Pressure, Key Y, Slider 1/2 shown only when mapped to a parameter). Each row has a label, numeric value, visual bar (-1 to +1), and the names of parameters mapped to it.
- **Control buttons**: MONO/POLY toggle, SCALE editor toggle, PANIC button, MAP button (opens matrix mapping panel), Recalibrate link.

### Right Side: Pitch Graph (540pt wide)

- Y axis: MIDI note range (startNote to startNote + noteCount)
- X axis: time (~2 seconds, scrolling)
- Horizontal grid lines at each C note with labels
- **Spectrogram (background)**: scrolling FFT magnitude heatmap of the synth output, aligned to the same MIDI-semitone y-axis. Purple → magenta → orange → yellow with intensity-scaled alpha so pitch lines remain readable on top.
- **Cyan line**: tap glide pitch (non-dragging samples)
- **Green line**: drag glide pitch (dragging samples)
- **Yellow line**: snap pitch (snapping samples)
- **White dots**: currently held touch target notes
- Current note names shown in the header

## Middle Strip: Voice-Stem Plot (full width)

A full-width plot sitting between the top half and the keyboard, ~13% of the screen height. It shows the current pitch and amplitude of every audible voice — both the (single) base voice and every always-on sympathetic voice — as vertical stems on a log-frequency axis.

- **X axis**: log-frequency, ~50 Hz to 10 kHz (8+ octaves)
- **Y axis**: voice amplitude (0 at baseline, 1.0 amplitude = full stem height)
- **Cyan stem**: the base voice, positioned at its current (possibly gliding) pitch; height = its current envelope amplitude
- **Pink stems**: each sympathetic voice, positioned at its fixed pitch; height = its current amplitude (driven by the excitation formula — see [MIDI & Audio](midi-and-audio.md#sympathetic-excitation))
- **Faint vertical lines**: octave boundaries

Drag the base voice across the keyboard and watch which sympathetic stems rise/fall. Stems at simple-ratio intervals from the base (unison, fifth, fourth, octave) grow tall; unrelated stems stay short.

### Channel Readout (bottom overlay)

Floats as an overlay on the bottom of the top half (does not affect layout of elements beneath).

For each active channel:
- Channel number, target note name, current frequency (Hz), velocity
- Glide progress percentage (during active glide)
- Touch count

**Glide debug line**:
- `t`: current calibrated tilt values (3 axes, -1 to +1)
- `ms/st`: current glide time per semitone
- `maxWait`: current mid-glide compression threshold
- `dur`: active glide duration in ms
- `q`: waypoint queue depth

**Status and sliders** (bottom row):
- MIDI status message (green if active, red if error)
- Audio status
- Two horizontal sliders (S1, S2) stacked vertically on the right side

### Sliders
- Each slider is 150pt wide × 66pt tall (1.5× finger-width)
- **0** at right edge, **1** at left edge (inward toward the center)
- Cyan fill shows current value; brighter when touched
- White marker shows the configured default value
- When released, value snaps back to its default (`Config.slider1Default`, `Config.slider2Default`)
- Designed for the non-dominant hand's index and middle fingers

### Parameter Mapping Panel (MAP button or swipe-right)

A full-screen matrix panel (rows = parameters, columns = dimensions) with a curve editor on the right third. Opened via the MAP button or swiping right on the top half. Dismissed by swiping left or tapping MAP again.

**Matrix (left 2/3):**
- Each cell represents a possible dimension→parameter binding. Tap to connect/select, long-press to disconnect.
- Connected cells show a mini Catmull-Rom curve preview.
- Cells can be dragged to move bindings across rows and columns.
- Multiple dimensions can be bound to the same parameter (many:many).

**Curve editor (right 1/3):**
- Shows the selected binding's transfer curve with 2–4 draggable control points.
- X axis = dimension input (0..1, or -1..+1 for tilts). Y axis = parameter output (full default range).
- Endpoint Y values shown as dashed lines if they differ from the parameter bounds.
- Tap graph to add points (up to 4). Long-press or drag off graph to remove interior points.
- Point coordinates shown below the graph as draggable text fields.
- Catmull-Rom spline interpolation; output clamped to endpoint min/max.

**Performance:** The 60Hz glide loop is paused while the panel is open (`NoteManager.paused`).

## Bottom Half: Keyboard

### Layout

All keys have a black background. White keys have shaped outlines with cutouts for adjacent black keys (matching real piano key shapes). Black keys overlay the upper 60% at 65% of white key width.

### Dimensions

For a 25-note range with ~15 white keys:
- White key width: `screenWidth / whiteKeyCount`
- Black key width: `whiteKeyWidth * 0.65`
- Black key height: `keyboardHeight * 0.6`

### Hit Testing

Touch y position determines which keys are available:
- `y < 0.6`: Both black and white keys (black key zone). Black keys are tested first by checking if the x position falls within the black key's bounds.
- `y >= 0.6`: White keys only (bottom portion)

### Color Coding

| State | Fill | Outline |
|-------|------|---------|
| Inactive white key | Dark gray (0.12) | Black |
| Inactive black key | Black | Black |
| Active (any key) | Gradient: gray at top → highlight color at bottom (30% opacity), with blurred glow | Black |

Highlight colors: **cyan** for tap, **green** for drag, **yellow** for snap.

During drag, the highlighted key is the one physically under the finger (`displayNote` from `hitTest`), not the sounding pitch. This means dragging from C to D highlights only C or D — never C#.

### Touch Dots

Colored circles (44pt diameter) follow each active touch:
- Cyan: tap mode
- Green: drag mode
- Yellow: snapping
- Gray: touch not yet assigned to a channel

### Note Labels

White keys have note name labels (e.g., "C4", "D4") at the bottom in monospaced gray text.

## System UI

- Status bar: hidden
- System overlays: hidden (`.persistentSystemOverlays(.hidden)`)
- System gestures: deferred on all edges (`.defersSystemGestures(on: .all)`)
- Orientation: locked to landscape right via AppDelegate + Info.plist
