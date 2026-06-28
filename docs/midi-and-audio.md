# MIDI & Audio

Starpad's iPad target emits MPE MIDI over USB and produces no sound of its own. The Mac target (or any other USB-MIDI-aware host) receives the MIDI and synthesizes. There is **no settings sync** between the two — they share only standard MIDI on the wire. Edit a scale on the iPad and it stays on the iPad; pick a preset on the Mac and it stays on the Mac.

## Mac MIDI input (MIDIInput.swift)

`MIDIInput` creates a CoreMIDI input port and `MIDIPortConnectSource`s every visible source on launch — and re-runs the connect pass whenever CoreMIDI fires a setup-changed notification, so plugging the iPad in mid-session brings it online automatically.

**Every incoming MPE channel-voice byte is forwarded verbatim to the hosted Audio Unit** via `AudioEngine.sendHostedMIDI(...)`. The AU does its own voice allocation, pitch bending, and per-voice expression handling per the MPE spec. There is no in-house played-voice synth on the Mac — SWAM (run dry) produces the bowed-violin tone, which the **sarangi model** (`SarangiKit`) then turns into the full sarangi (see [Sound Design](sound-design.md)). The model needs no note information: it is driven purely by SWAM's tapped audio plus a signal-derived amplitude envelope. All note sources funnel through `sendHostedMIDI` — real-iPad MPE (here), the Mac in-process Pitch/Chord pads, and the simulator — so this one hook captures everything. It also tracks the played note/bend and the latest CC11 per channel and publishes a thread-safe `performanceReadout()` (played pitch in Hz + commanded loudness 0–1) that the **Live tab** graphs poll — see [UI Layout — Live tab](ui-layout.md#live-tab).

Two side observers run alongside the forwarding:

1. **RPN bend-range mirror** — `MIDIInput.handleCC` tracks the (CC 101, CC 100, CC 6) sequence so the Mac maintains a per-channel record of the agreed pitch-bend range. The AU has already received those bytes by the time the handler runs; the mirror is informational (used by any future feature that needs to know the controller-agreed range without polling the AU).
2. **`onCC` callback** — every CC is also delivered to `AppController.handleIncomingCC`, which looks the CC up in the per-preset `ccMappings` table and drives the matching Mac-side FX parameter. This routing is global (channel-agnostic) — Starpad's Mac is monolithic, not multi-timbral.

CC 123 (All Notes Off) clears the channel→slot binding so a future Note On allocates a fresh slot.

## Polyphonic hosted-AU model

SWAM Violin is monophonic. To support chord playing, `AudioEngine.loadHostedInstrument` instantiates `Config.maxHostedPolyVoices` copies (default 8) in parallel and dynamically assigns each Note On to an idle slot.

- Per-slot state is a small `(channel, age)` pair under the engine lock; a parallel `[channel: slot]` dictionary indexes the reverse direction so per-voice messages (Pitch Bend, Channel Pressure, per-voice CCs) route in O(1).
- On Note On: reuse the channel's slot if already bound (retrigger), else take the first idle slot, else steal the LRU slot (smallest `age`).
- On Note Off: release the binding so the slot becomes idle.
- Master-channel (ch 0) messages and channel-state CCs (RPN 101/100/6/38, CC 121 reset-all-controllers, CC 123 all-notes-off) **broadcast** to every loaded instance so global state stays consistent across slots.
- Newly-loaded slots are seeded by `resetHostedInstrumentControllers`: every channel gets RPN-set pitch-bend range (`Config.midiPitchBendRange`), CC 11/71/74 mid-values, and centered pitch bend, so a slot allocated to channel X plays at the right pitch even if the iPad's RPN broadcast happened during async load.
- Edits made via the AU's UI on the primary slot (slot 0) propagate to the other instances via an `AUParameterTree` observer installed once after all slots are loaded — so opening the SWAM window once configures every voice consistently. Limitation: per-parameter only — anything an AU exposes solely via `fullState` (some patch pickers, articulation menus) won't ride this path.
- Slots whose async instantiation failed stay nil; their slot is skipped in allocation.

## Mac-side CC mapping

Any incoming CC can drive any of the Mac-side FX parameters listed in [MIDICCMapping.swift](../StarpadMac/MIDICCMapping.swift). Mappings are **per-preset** — `AppController` stores a `[Int: MappableMacParam]` table keyed by CC number, and `applyPreset` swaps in whichever table was saved for the incoming preset (or an empty one if none).

UI lives in the voice-params panel: each slider row has a small **CC field**.

- The field shows the bound CC number, or is empty if unmapped.
- Type a number 0–127 and press Return (or tab away) to bind.
- Clear the field to unmap.
- Mappings are bijective by construction: rebinding a param frees its old CC, and entering a CC that was in use frees the param it pointed to. Invalid input snaps back to the current binding instead of clearing.

Persistence is via `UserDefaults` under `starpad.ccMappingLibrary` — `[presetRawValue: [ccString: paramRawValue]]`. Lost mappings on a fresh install, but stable across launches.

CoreMIDI delivers `onCC` on its high-priority thread; `AppController` hops to main before touching `@Published` state. The same CC also forwards to the AU (as above), so the AU may interpret the same CC for its own purposes — that's intentional and per MPE convention.

## Hosted AU + sarangi drive

The Mac feeds the hosted AU's dry audio into the sarangi model, whose output **is** the played voice. The model is rendered **inline** by a custom in-process AUv3 effect, `SarangiProcessorAU` (`Packages/StarpadCore/Sources/StarpadCore/SarangiProcessorAU.swift`), spliced directly into the graph right after the SWAM AUs:

```
N × SWAM AU(dry) → hostedDriveTap → SarangiProcessorAU → symGain → mainMixerNode → output
```

1. All N hosted-AU instances feed into a shared `hostedDriveTap` mixer node (at full level), which **sums the poly instances** into one stereo drive.
2. `SarangiProcessorAU.internalRenderBlock` pulls that summed stereo synchronously into a private scratch `AVAudioPCMBuffer`, then runs the installed `processBlock` closure (built by `AudioEngine.makeSarangiProcessBlock()`). The closure builds a mono drive (`0.5·(L+R)`) lifted by `sarangiDriveGain`, runs a per-sample causal `SignalAmpFollower` to get a 0..1 amplitude envelope, and calls `SarangiEngine.renderSample(input, amp:)` per sample — all under a single `AudioEngine.lock` acquisition (spanning `beginBuffer()` + the per-sample loop). The peak meter (`hostedOutputPeak`) is computed from the pulled SWAM input unconditionally. The model applies its own body (block E) and its **per-voice FX rack** (Violin/Sym/Global, each filter + EQ + reverb — replacing the old single block-F Freeverb) internally.
3. That output goes through `symGain` **straight to `mainMixerNode`**, **bypassing** Starpad's master filter / reverb / `postReverbEQ` (those now serve only the tanpura + sitar). The sarangi's room is its own FX rack, not the shared `AVAudioUnitReverb`.

Because the effect renders in the **same engine pull** as SWAM, it adds **~0 ms latency** (verified: `sarangiEffect_latency = 0.00 ms`; model compute ≈ 0.2–0.9 ms per buffer). This removed the old `installTap(4096)` → `SPSCAudioRing` → separate `AVAudioSourceNode` transport, which added ~140 ms (the 4096-frame tap accumulation ≈ 93 ms + the ring producer/consumer phase ≈ 46 ms), audible even in pass-through.

The effect must be created **synchronously before `engine.start()`** — `AVAudioUnitEffect(audioComponentDescription:)` after a one-time `registerSarangiAUOnce()` (registers the `SarangiProcessorAU` subclass for component type `kAudioUnitType_Effect`, subtype `'Srng'`, manufacturer `'Strp'`) — because connecting a custom AU into an already-running engine does NOT allocate its render resources.

## Audio graph

SWAM runs **dry** (its internal room/reverb/ambience/body are off). The sarangi
model is rendered inline by the `SarangiProcessorAU` effect (it owns its own body
(block E) + a per-voice **FX rack** — filter + EQ + reverb, replacing the old
block-F Freeverb), so it goes `symGain → mainMixerNode` **directly, bypassing** the
shared master filter / reverb / `postReverbEQ` — those are now the
**tanpura/sitar Room** only. See [sarangi.md](sarangi.md).

```
N × SWAM AU(dry) ► hostedDriveTap ► SarangiProcessorAU ► symGain ───────────────────────────────────────────────────────────► mainMixerNode ► out
                       (sums poly)   (SignalAmpFollower + SarangiEngine.renderSample —                                               ▲
                                      full sarangi: bank+jawari+body, then the per-voice FX rack)                                    │
                                                                                                                                     │
   tanpuraSource/sitarSource ──► gains ──► preReverbMixer ► masterFilter ► reverb ► postReverbEQ ────────────────────────────────────┘
```

- `hostedDriveTap`: full-level **sum** of all N AU buses; its output is pulled directly by `SarangiProcessorAU` (no tap, no ring).
- `SarangiProcessorAU`: the in-process AUv3 effect spliced right after `hostedDriveTap`. Pulls the summed SWAM stereo into a private scratch buffer and runs the model render closure inline — `~0 ms` added latency (same engine pull as SWAM).
- `symGain`: the sarangi effect's output gain (unity); the sarangi feeds **`mainMixerNode` directly**, bypassing the master FX (it has its own per-voice FX rack).
- `preReverbMixer`: where the **tanpura + sitar** sum into the shared FX chain. Its `outputVolume` is set to `1.0` once in `setupAudio`. The sarangi is **not** routed here.
- `masterFilter`: `AVAudioUnitEQ` with one band, type `.resonantLowPass`. Bypassed when cutoff is at max and resonance is zero.
- `reverb`: `AVAudioUnitReverb` factory preset `.mediumHall` — the **tanpura/sitar Room** (the sarangi has its own FX-rack reverb). `wetDryMix` driven by `AppController.reverbMix` (the Tanpura tab's "Reverb mix").
- `postReverbEQ`: 3-band parametric `AVAudioUnitEQ` after the reverb — final spectral shaping. Bypassed unless `AppController.postReverbEnabled`.

The old muted dry-SWAM passthrough branch is gone (it only existed to keep the
tap pulled). The nodes `hostedInstrumentGain` / `hostedMakeupGain` / `sarangiMixer`
/ `violaBodyEQ` remain **attached but disconnected** so that `AppController`'s
`setViolaBodyEnabled` / `setViolaBodyBand` / `setHostedMakeupGainDB` property
setters stay valid; they no longer carry signal.

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
device that lacks 44.1 kHz keeps AVAudioEngine's converter (best-effort). The
engine sample rate itself is **not** changed — the body FIR is a 44.1 kHz-measured
impulse response and would mistune ~8.8% at 48 kHz.

See [Sound Design](sound-design.md) for the sarangi model's DSP details.

## Parameter update cadence

`AppController`'s `@Published` FX setters push to `AudioEngine` via `didSet` hooks — slider drags fire immediately, with no 60 Hz timer involved. The **sarangi model** routes through `SarangiStore`: a **live-scalar** param (gain/mix) is pushed lock-free every buffer, while a **structural** param (raga/tonic/strings/filter coefficient) schedules a debounced (~50 ms) off-thread rebuild of the `SarangiEngine`, swapped in under the lock — so rapid slider drags coalesce into one rebuild.

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

On first use of a channel, a pitch bend range RPN is sent to set ±48 semitones (`Config.midiPitchBendRange`). `NoteManager` caches per-channel after that — the hosted-AU's RPN state is sticky, so resending on every Note On is just wire chatter. PitchPad uses the same channel pool and the same value, so the cache stays coherent.

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
3. Launch the Starpad app on the iPad and the StarpadMac app on the Mac. The Mac's top-bar pill should turn green and show `MIDI: N src` once it sees the iPad as a source. The first MIDI Note On from the iPad will trigger SWAM on the Mac immediately.

That's it — no Bonjour pairing, no IP addresses. Each side keeps its own settings; only MIDI flows between them (plus the one scale-sync SysEx below).

## Scale sync (Mac → iPad)

StarpadMac is the scale **editor**; the iPad is the **performer**. The Mac
pushes its Pitch Pad scale to the iPad over the same USB cable as a MIDI
**SysEx** message — the only non-MPE, cross-device data Starpad sends.

- **Encoding** (`PitchScaleSysEx`, StarpadCore, blob `version 3`): `F0 7D 01
  <payload> F7`, where `7D` is the non-commercial SysEx ID, `01` the "scale"
  subtype, and the payload is base64 (7-bit-safe) of a **compact binary** blob
  (`[ver][tonic][margin][layout][count]` then per point `num/den` as 14-bit
  pairs, `y`, `enabled`, and a length-prefixed UTF-8 label) — kept small so it
  clears the iOS USB-MIDI SysEx bridge comfortably. The synced state is a
  `SyncedScaleState` = the scale plus `tonicMidi`, `marginPixels`, and
  `layout` (`PadLayout` — which surface the iPad shows, Pitch Pad or Chord
  Pad).
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
  so the blob doesn't hit SWAM or other gear.

One-way Mac→iPad; the iPad has no scale editor. The synced state includes
the **tonic** (which MIDI note 1/1 maps to), the **margin** (soft-zone
half-width — the **active** surface's margin, since each pad owns its own
slider), and the **layout** (Pitch Pad vs Chord Pad — see
[Chord Pad](chord-pad.md)), all set on the Mac (the iPad's tonic readout is
read-only and it can't pick its own layout). The iPad's `ContentView` swaps
playing surfaces on the synced `layout`. The iPad persists the last synced
state (`SyncedScaleStore`, UserDefaults) and opens on it after an offline
relaunch.

### Routing iPad MIDI to other hosts (Ableton, etc.)

The iPad acts as a standard USB-MIDI controller, so the same cable can drive any MPE-aware DAW alongside the Mac. In Ableton, for example:

1. Open **Preferences → Link, Tempo & MIDI** and enable the iPad MIDI input (Track on).
2. Set the destination instrument's pitch bend range to ±48 semitones.
3. Enable MPE on the track so per-note pitch bend works.

If using Ableton's "Note PB" mode, pitch bends are automatically per-note when MPE is enabled.
