# MIDI & Audio

Starpad's iPad target emits MPE MIDI over USB and produces no sound of its own. The Mac target (or any other USB-MIDI-aware host) receives the MIDI and synthesizes it with the sarangi **String voice** — the only voice. The two share only standard MIDI on the wire (plus one-way pad-sync SysEx).

## Mac MIDI input (MIDIInput.swift)

`MIDIInput` creates a CoreMIDI input port and `MIDIPortConnectSource`s every visible source on launch — and re-runs the connect pass whenever CoreMIDI fires a setup-changed notification, so plugging the iPad in mid-session brings it online automatically.

**Every incoming MPE channel-voice byte funnels through `AudioEngine.sendHostedMIDI(...)`** (the name is kept for continuity), which routes it to the String voice via `routeSarangiModelMIDI` → the long-lived `BowControlMapper` (per-finger note identity + bend keyed by the status byte's channel nibble — the Starpad MPE divergence). All note sources funnel through `sendHostedMIDI` — real-iPad MPE (here), the Mac in-process Fret Pad, and the headless simulator — so this one hook captures everything. It also tracks the played note/bend and the latest CC11 per channel and publishes a thread-safe `performanceReadout()` (played pitch in Hz + commanded loudness 0–1) that the **Live tab** graphs poll — see [UI Layout — Live tab](ui-layout.md#live-tab).

One class of CCs never reaches any voice: **CC 102–105** are the Fret Pad's
**drone buttons** (value ≥ 64 = pressed). `sendHostedMIDI` intercepts them at
the top and calls `AudioEngine.setDronePressed`, which drives the String
voice's jawari-taraf drone rows (see [Fret Pad](fret-pad.md#drone-buttons-2026-07-23));
they arrive identically from the iPad's buttons (over USB) and the Mac's own
strip (in-process).

A side observer runs alongside the forwarding: the **`onCC` callback** delivers every CC to `AppController`, which drives the composite-parameter slots (see the composites in the Controls tab). Composite-slot CCs are also consumed inside `sendHostedMIDI` (routed to `onCompositeCC` → `AppController.applyComposite`).

## String-voice tilt axes

**String-voice tilt axes (2026-07-23):**
`routeSarangiModelMIDI` consumes three global CCs before the mapper —
**CC71** taraf purity (0 buzzy … 127 pure), **CC73** taraf decay (0 natural
… 127 choked), **CC72** tone tilt (0 bass … 64 flat … 127 treble). The iPad
tilts emit them by default (see [sensors.md](sensors.md)); the values land
on `StringVoiceSource` → `BowEngine` and survive engine rebuilds. Details
in [sarangi.md](sarangi.md).

## Audio graph

The played voice is the String kernel, rendered by `StringVoiceSource` (an `AVAudioSourceNode` at 48 kHz wrapping `SarangiKit.BowEngine`). The kernel is the **complete** instrument — played strings + modal-jawari taraf + formula body + radiation + room — so its node connects **directly** to `symGain → mainMixerNode`. There is no hosted AU, no drive tap, no coupled-network effect, and no master filter/reverb bus (all removed 2026-07-24).

```
MPE in ► routeSarangiModelMIDI ► StringVoiceSource ► symGain ► mainMixerNode ► output
                                  (BowEngine + CBowKernel, 96 kHz → 48 kHz)
```

- `StringVoiceSource`: attached + connected to `symGain` in `setSarangiModelVoiceEnabled(true)` (called unconditionally at startup). The kernel runs 96 kHz internally and half-band-decimates to 48 kHz; the mixer input converts to the engine rate. Its async jawari worker pool renders one block late so the callback never waits.
- `symGain`: the String voice's output gain (`outputVolume = 1`), feeding `mainMixerNode` directly.

On macOS the output IO buffer is requested down to
`Config.preferredOutputBufferFrames` (128 frames ≈ 2.7 ms, was the 512-frame
device default) at engine start via `AudioEngine.setOutputBufferFrames(_:)` — Mac
has no per-app IO buffer (no AVAudioSession), so this sets the device's CoreAudio
HAL buffer, clamped to its allowed range (`AudioEngine.outputBufferFrames` reads it
back; `logAudioLatencyReport(_:)` is a diagnostic). The engine + all fitted models
run at `Config.sampleRate` (44100); to avoid an output resampler, `AudioEngine`
sets the **output device** to 44.1 kHz at start (and on `setOutputDevice`) via
`matchOutputDeviceToEngineRate` when the device supports it, and restores the prior
rate on quit (`restoreOutputDeviceRate`, wired to `willTerminate` + `deinit`). A
device that lacks 44.1 kHz keeps AVAudioEngine's converter (best-effort). The engine sample rate itself is `Config.sampleRate` (44100); the String kernel's own 48 kHz output is converted at the mixer input.

See [Sound Design](sound-design.md) for the String voice's DSP details.

## Parameter update cadence

`AppController`'s `@Published` setters push to `AudioEngine` via `didSet` hooks — slider drags fire immediately, with no 60 Hz timer involved. The **String voice** routes through `StringParamStore` / `SarangiStore`: the runtime taraf axes (purity/decay/tone) and composite members are pushed live (chunk-rate smoothed in `BowEngine`); a **structural** edit (tarab tuning, a `bow_*` physics scalar) schedules a debounced off-thread `BowEngine` rebuild, swapped in lock-free — so rapid slider drags coalesce into one rebuild.

## MIDI Engine (MIDIEngine, iPad)

### Initialization

MIDI setup is deferred to `onAppear` (not `init`) because the iOS MIDI server may not be ready at app launch. The engine retries up to 3 times with increasing delays.

Two endpoints are created:
- **Virtual source** ("Starpad Output"): for on-device apps to receive from
- **Output port**: for direct send to all external destinations (Mac over USB)

Every MIDI message is sent through both paths simultaneously.

### MPE Configuration

At startup, the engine sends an MPE Zone configuration on the master channel (channel 0):
- RPN 0x0006 with value 15 = 15 member channels (1-15)

### Per-Note Channel Rotation

Each `activateChannel` call in NoteManager allocates the next MIDI channel via round-robin (1 → 2 → ... → 15 → 1). This ensures:
- Pitch bends on a new note don't affect reverb tails of previous notes
- Each note has independent aftertouch

On first use of a channel, a pitch bend range RPN is sent to set ±48 semitones (`Config.midiPitchBendRange`). `NoteManager` caches per-channel after that. On the Mac, the String voice's `BowControlMapper` reads `Config.midiPitchBendRange` directly (per-channel bend, the Starpad MPE divergence), so a ±48 bend maps correctly with no AU-parameter round-trip.

### Pitch Bend Calculation

```
baseSemitone = MIDI note number of the original noteOn
currentSemitone = 12 * log2(currentFreq / 440) + 69
offset = currentSemitone - baseSemitone
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
| Pitch Bend | 0xE0 | Continuous pitch (glide + finger movement) |
| Channel Pressure | 0xD0 | Tilt expression |
| Control Change | 0xB0 | RPN setup, dimension-routed CCs, all-notes-off (panic) |

## Connecting iPad to Mac over USB

1. Connect the iPad to the Mac via USB cable.
2. On the Mac: open **Audio MIDI Setup → Window → Show MIDI Studio**, double-click the iPad icon, and enable it.
3. Launch the Starpad app on the iPad and the StarpadMac app on the Mac. The Mac's top-bar pill should turn green and show `MIDI: N src` once it sees the iPad as a source. The first MIDI Note On from the iPad plays the String voice on the Mac immediately.

That's it — no Bonjour pairing, no IP addresses. Each side keeps its own settings; only MIDI flows between them (plus the one scale-sync SysEx below).

## Scale sync (Mac → iPad)

StarpadMac is the scale **editor**; the iPad is the **performer**. The Mac
pushes the playing scale to the iPad over the same USB cable as a MIDI
**SysEx** message — plus the **Fret Pad's fret arrangement** as its own SysEx
message (`F0 7D 03` `FretArrangementSysEx` — see [Fret Pad](fret-pad.md)).
These two are the only non-MPE, cross-device data Starpad sends.

(A fourth message, `F0 7D 04 TiltMappingSysEx`, briefly pushed tilt
bindings to the iPad; it was **deleted 2026-07-24** when the iPad stopped
evaluating parameters altogether. Tilt bindings are now purely Mac-local —
the iPad streams only its raw tilt report and the Mac evaluates. Subtype
`0x02`, the old String-Pad arrangement, is likewise unused.)

- **Encoding** (`PitchScaleSysEx`, StarpadCore, blob `version 3`): `F0 7D 01
  <payload> F7`, where `7D` is the non-commercial SysEx ID, `01` the "scale"
  subtype, and the payload is base64 (7-bit-safe) of a **compact binary** blob
  (`[ver][tonic][margin][layout][count]` then per point `num/den` as 14-bit
  pairs, `y`, `enabled`, and a length-prefixed UTF-8 label) — kept small so it
  clears the iOS USB-MIDI SysEx bridge comfortably. The synced state is a
  `SyncedScaleState` = the scale plus `tonicMidi`, `marginPixels`, and
  `layout` (`PadLayout` — always `.fretPad` now; the enum keeps its other
  cases for blob compatibility but only the Fret Pad exists on either side).
- **iPad receive** (`ScaleSyncReceiver`, StarpadCore): a virtual CoreMIDI
  **destination** named "Starpad Scale" so the Mac sees the iPad as a MIDI
  destination. It reassembles SysEx across packets (`F0`…`F7`), decodes, and
  calls `PitchPadEngine.applySyncedState` — which panics on a scale or
  layout change (so a note isn't stranded on a vanishing cell), swaps the
  scale/tonic/margin/layout, and persists the state to `SyncedScaleStore`
  (UserDefaults) so it survives an offline relaunch.
- **Mac send** (`AppController` + `MIDIEngine.sendSysEx`): Combine
  subscriptions push on every `pitchPad.scale` / `tonic` / `margin` / `layout`
  edit (debounced ~300 ms) and whenever a destination appears (iPad connect).
  `sendSysEx` targets only destinations whose name contains "Starpad Scale",
  so the blob doesn't hit other gear.

One-way Mac→iPad; the iPad has no scale editor. The synced state includes
the **tonic** (which MIDI note 1/1 maps to) and the **margin** (the Fret
Pad's Snap distance), both set on the Mac (the iPad's tonic readout is
read-only). The iPad performs the Fret Pad. The iPad persists the last synced
state (`SyncedScaleStore`, UserDefaults) and opens on it after an offline
relaunch.

### Routing iPad MIDI to other hosts (Ableton, etc.)

The iPad acts as a standard USB-MIDI controller, so the same cable can drive any MPE-aware DAW alongside the Mac. In Ableton, for example:

1. Open **Preferences → Link, Tempo & MIDI** and enable the iPad MIDI input (Track on).
2. Set the destination instrument's pitch bend range to ±48 semitones.
3. Enable MPE on the track so per-note pitch bend works.

If using Ableton's "Note PB" mode, pitch bends are automatically per-note when MPE is enabled.
