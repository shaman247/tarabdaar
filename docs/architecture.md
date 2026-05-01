# Architecture

## Module Overview

```
StarpadApp.swift
  |
  +--> ContentView.swift (main UI, wires everything together)
         |
         +--> NoteManager.swift    (pitch pipeline orchestrator)
         |      |
         |      +--> Scale.swift         (scale model, tuning, frequency calc)
         |      +--> TiltMapping.swift   (dimension → parameter mapping)
         |      +--> AudioEngine.swift   (modal-synthesis voice bank: played + sympathetic ModalBanks)
         |      +--> MIDIEngine.swift     (CoreMIDI MPE output)
         |      +--> MotionManager.swift  (accelerometer + gyro)
         |
         +--> TouchOverlayView.swift  (multi-touch capture)
         +--> CalibrationView.swift   (first-launch calibration)
         +--> ScaleEditorView.swift   (scale/tuning configuration)
```

## Three-Stage Pipeline

### Stage 1: Touch Input
`TouchOverlayView` captures raw touch events and reports `touchBegan`, `touchMoved`, and `touchEnded` with normalized (0-1) x/y positions and timestamps.

`NoteManager.touchBegan` starts a 20ms velocity capture timer. When the timer fires (`fireNote`), it reads the peak accelerometer magnitude from `MotionManager` and maps it to MIDI velocity.

`NoteManager.touchMoved` handles vibrato (y position) and drag glides (x position with smoothing and reversal correction).

### Stage 2: Glide Engine (60Hz)
A `Timer` fires 60 times per second (`glideUpdate`). Each tick:

1. **Drag mode**: If active, smoothly chase `dragTargetFreq` using exponential smoothing in log-frequency space
2. **Tap glide mode**: Advance `glideProgress` through the sigmoid easing curve, interpolating between `startFrequency` and `targetFrequency` in log-frequency space
3. **Glide completion**: Pop next waypoint from the queue via `advanceQueue`
4. **Vibrato**: Advance LFO phase, compute pitch offset from intensity
5. **Tilt modulation**: Read calibrated up/down tilt, modulate amplitude and send aftertouch
6. **Pitch history**: Record sample for the graph display
7. **UI throttle**: Send `objectWillChange` every 4th tick (~15Hz)

### Stage 3: Output
- **AudioEngine**: `setFrequency(channel:frequency:)` and `updateVoiceParams(...)` are called from the glide loop. The audio thread's render callback runs a two-pass modal-synthesis render — played banks into a scratch buffer, then sympathetic banks driven by that buffer × kernel-derived coupling gain. Silent sympathetic banks skip their inner mode loop. See [Sound Design](sound-design.md) and [MIDI & Audio](midi-and-audio.md) for details.
- **MIDIEngine**: `sendPitchBend`, `sendChannelPressure`, `sendNoteOn/Off` are called from the glide loop on the main thread.

## Threading Model

| Thread | Component | Responsibility |
|--------|-----------|----------------|
| Main | NoteManager (Timer) | 60Hz glide loop, touch handling, MIDI sends |
| Main | SwiftUI | UI rendering (~15Hz, throttled) |
| Audio (real-time) | AudioEngine (AVAudioSourceNode callback) | Modal-bank synthesis (coupled-form resonators), excitation generation, two-pass render, silent-bank skip |

The audio callback reads `Voice.frequency`, `Voice.targetFrequency`, and `Voice.amplitude` which are written by the main thread. Thread safety is via `NSLock` (locked for the duration of each voice iteration in the render callback, and around each `noteOn`/`noteOff`/`setFrequency`/`setAmplitude` call).

## Dependency Injection

Managers are created as `@StateObject` in `ContentView` and wired together in `onAppear`:

```swift
noteManager.motionManager = motion
noteManager.midiEngine = midi
noteManager.audioEngine = audioEngine
midi.start()
```

## Polyphonic Mode

Starpad supports a toggleable polyphonic mode (up to `Config.maxPolyVoices` simultaneous voices). The voice pool is an array of `PitchChannel` structs. In monophonic mode, only index 0 is used.

### Voice Model

Each touch gets its own voice. Tapping a key activates an idle voice on that note. Lifting the finger releases that voice. Glides in poly mode only happen via drag — sliding a finger across the keyboard drags that voice's pitch continuously.

### Glide Loop

The 60Hz `glideUpdate` iterates all active voices in poly mode, calling `updateVoiceGlide` and `updateVoiceExpression` per voice. Vibrato uses a single shared LFO across all voices.

### Per-Touch Drag State

Each touch tracks its own drag direction, zone, and snap origin via `polyDragState: [Int: PolyDragInfo]`, enabling independent drag glides per voice. Each voice has its own snap timer via `polySnapTimers: [Int: Timer]`.

### Audio Gain

`AudioEngine` applies equal-power gain normalization (`1/sqrt(voiceCount)`) when multiple voices are active to prevent clipping.

## Key Design Decisions

- **Monophonic/Polyphonic**: Six `PitchChannel` structs exist in the array. In monophonic mode only channel 0 is used. In polyphonic mode, up to 6 are active simultaneously.
- **MPE per note**: Each `activateChannel` call rotates through MIDI channels 1-15, so old notes' reverb tails don't get pitch-bent by new notes.
- **No AudioWorklet**: The synthesizer uses `AVAudioSourceNode` with standard `OscillatorNode`-style per-sample rendering. AudioWorklet has reliability issues on mobile Safari (the project started as a web app concept).
- **Config.swift**: System-level constants (timing, audio, MIDI, display) live in Config.swift. Dimension-mappable parameter ranges (glide speed, amplitude, vibrato, etc.) are defined in `TiltMapping.swift` via `MappableParameter.defaultRange` and configured at runtime.
- **Scale.swift**: Frequency calculations live in the Scale model, not AudioEngine. NoteManager always calls `scale.frequency(for:)` — never uses hardcoded 12-TET formulas directly.
- **3-axis calibration**: 7 capture points (rest + 2 endpoints × 3 axes) in (pitch, roll, yaw) 3D space. Values normalized to -1..+1 per axis.
