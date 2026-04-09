# MIDI & Audio

## Built-in Synthesizer (AudioEngine)

### Voice Model

Each voice is a struct with:
- `frequency` / `targetFrequency`: current and target pitch (smoothed per-sample)
- `amplitude`: target amplitude from velocity
- `phase`: oscillator phase (0-1 cycle)
- `envelope`: current amplitude (ramped toward target)
- `releasing`: flag for release envelope

Voices are keyed by **channel index** (0 or 1), not touch ID, since the instrument is monophonic.

### Render Callback

`AVAudioSourceNode` runs on the audio thread at 44100 Hz. Per sample:

1. Smooth frequency toward target: `freq += (target - freq) * frequencySmoothing`
2. Compute envelope: attack ramp (`attackCoefficient`) or release decay (`releaseCoefficient`)
3. Generate sample: `sin(phase * 2pi) * envelope`
4. Advance phase: `phase += freq / sampleRate`
5. Remove voice when envelope falls below 0.001

Thread safety: `NSLock` protects the voices dictionary. The lock is held for the entire voice iteration in the render callback, and around each public method call.

### Frequency Smoothing

Per-sample exponential smoothing (`frequencySmoothing = 0.002`) eliminates zipper noise from the 60Hz glide loop updates. At 44100Hz, this gives ~11ms smoothing time constant.

## MIDI Engine (MIDIEngine)

### Initialization

MIDI setup is deferred to `onAppear` (not `init`) because the iOS MIDI server may not be ready at app launch. The engine retries up to 3 times with increasing delays.

Two endpoints are created:
- **Virtual source** ("Armpad Output"): for on-device apps to receive from
- **Output port**: for direct send to all external destinations (Mac over USB)

Every MIDI message is sent through both paths simultaneously.

### MPE Configuration

At startup, the engine sends an MPE Zone configuration on the master channel (channel 0):
- RPN 0x0006 with value 15 = 15 member channels (1-15)

### Per-Note Channel Rotation

Each `activateChannel` call in NoteManager allocates the next MIDI channel via round-robin (1 → 2 → ... → 15 → 1). This ensures:
- Pitch bends on a new note don't affect reverb tails of previous notes
- Each note has independent aftertouch

At activation, a pitch bend range RPN is sent on the new channel to set ±48 semitones.

### Pitch Bend Calculation

```
baseSemitone = MIDI note number of the original noteOn
currentSemitone = 12 * log2(currentFreq / 440) + 69
vibratoSemitones = sin(phase) * maxDepth * intensity
offset = (currentSemitone - baseSemitone) + vibratoSemitones
normalizedBend = clamp(offset / pitchBendRange, -1, 1)
midiValue = 8192 + int(normalizedBend * 8191)
```

The `baseNote` is set once at channel activation and never changes during the note's lifetime. All pitch movement is expressed as pitch bend relative to this base.

### Channel Pressure (Aftertouch)

Tilt expression is sent as channel pressure (0xD0):
```
pressure = clamp(tiltUp * 127, 0, 127)
```

This is the MPE standard for per-note continuous expression.

### Message Types Sent

| Message | Status | Usage |
|---------|--------|-------|
| Note On | 0x90 | Channel activation |
| Note Off | 0x80 | Channel release |
| Pitch Bend | 0xE0 | Continuous pitch (glide + vibrato) |
| Channel Pressure | 0xD0 | Tilt expression |
| Control Change | 0xB0 | RPN setup, all-notes-off (panic) |

## Connecting to Ableton over USB

1. Connect iPad to Mac via USB cable
2. On Mac: **Audio MIDI Setup** > **Window > Show MIDI Studio** > Enable iPad
3. In Ableton: **Preferences > Link, Tempo & MIDI** > Enable iPad MIDI input (Track on)
4. Set instrument pitch bend range to ±48 semitones
5. Enable MPE on the track (so per-note pitch bend works)

If using Ableton's "Note PB" mode, pitch bends are automatically per-note when MPE is enabled.
