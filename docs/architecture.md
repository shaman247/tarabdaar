# Architecture

Starpad is two devices over one USB cable. The iPad is a pure MPE-MIDI controller. The Mac is a MIDI-driven sound module that hosts SWAM Violin (an Audio Unit, run dry) and feeds its audio into a full **sarangi model** (`SarangiKit`) for the played voice, with a separate tanpura/sitar drone layer alongside. They share no state — only standard MIDI on the wire — and each side owns a disjoint slice of the instrument.

## Module Overview

```
iPad (Starpad target) — controller, silent
═══════════════════════════════════════════════════════════════════
StarpadApp.swift
  └── ContentView.swift
        ├── PitchPadEngine (StarpadCore: touch-position → ratio → pinned
        │     │             note + bend; 60 Hz loop overlays
        │     │             aftertouch/CC)  ──► MIDIEngine (shared)
        │     └── PitchScale / PitchPadGeometry (Voronoi cells, soft-margin
        │                       pitchAt, OKLCH colors — shared with Mac)
        ├── PitchPadViewIOS        (full-screen pad: render + multitouch +
        │                           list editor + MAP button)
        ├── NoteManager  (StarpadCore: now the tilt sampler + DimensionMapping
        │     │           host — its keyboard/glide voice paths stay idle)
        │     └── TiltMapping      (dimensions → aftertouch/CC params)
        ├── MIDIEngine             (CoreMIDI MPE output — shared by the pad)
        ├── MotionManager          (CoreMotion: 200 Hz tilts + accel)
        ├── TouchOverlayView       (multi-touch capture)
        └── CalibrationView        (first-launch calibration)

           ─────── USB MPE MIDI ───────►
           Note On/Off, Pitch Bend,
           Channel Pressure, CCs 1/11/71/73/74/75

Mac (StarpadMac target) — sound module, audible
═══════════════════════════════════════════════════════════════════
StarpadMacApp.swift
  └── MacMainWindow
        ├── AppController (Mac-side source of truth)
        │     ├── AudioEngine            (StarpadCore: hosts the SWAM AUs +
        │     │                            wraps SarangiKit.SarangiEngine +
        │     │                            StarpadDSP.TanpuraModel ×2)
        │     │     ├── N × AVAudioUnit (SWAM Violin, dry, one per MPE slot)
        │     │     ├── Packages/SarangiKit — the full sarangi model
        │     │     │     SarangiEngine: dry voice in → complete stereo
        │     │     │     sarangi out (the v57 passive coupled bridge–body
        │     │     │     network: played combs + taraf web on one junction,
        │     │     │     modal body + radiation FIR, 2-stage FX rack)
        │     │     └── Packages/StarpadDSP — tanpura + sitar only
        │     │           TanpuraModel ×2 (drone + sitar) on their own
        │     │           source nodes (see docs/tanpura.md, docs/sitar.md)
        │     ├── SarangiStore            (owns the editable InstrumentState —
        │     │                            raga + tonic + [StringSpec] + the 22
        │     │                            model params + FX rack)
        │     ├── MIDIInput              (CoreMIDI input — every MPE byte
        │     │                            forwarded verbatim to the hosted AUs)
        │     ├── MIDIEngine             (CoreMIDI — present for symmetry; unused on Mac)
        │     ├── @Published tanpura/sitar params, gains, velocities
        │     ├── @Published FX (reverbMix, filterCutoff, filterResonance)
        │     └── currentPreset / applyPreset (currently `.swamViola` only)
        └── Views/  (LiveVisualizer, SarangiEditor, Simulator, pads, Setup)
```

**Mac does not use `NoteManager` for real-iPad input.** `AppController` holds Mac-side state as `@Published` fields; setters push directly to `AudioEngine`. The **sarangi model** is owned separately by `SarangiStore` (`StarpadMac/SarangiStore.swift`): it holds the editable `InstrumentState` (raga + tonic, the sympathetic-string `[StringSpec]` table, the 22 `SarangiKit` model parameters, the output voice EQ, and the 2-stage **FX rack**), persists it to UserDefaults / `.sarangi` JSON, and routes each edit to `AudioEngine` as either a live-scalar update (gains/FX enable+reverb, no rebuild) or a debounced structural rebuild (raga/tonic/strings/filter/EQ coefficients). `SoundPreset` (Mac-only, in `StarpadMac/SoundPreset.swift`) bundles the per-preset hosted-AU descriptor + FX and `AppController.applyPreset` copies them into the mirrors and runs engine configuration. Only one preset (`.swamViola`) ships today; the picker is kept so future hosted-AU presets can drop in without re-plumbing the AppController.

**Exception — the Simulator tab.** `IPadSimulator` (Mac-only) holds its own `NoteManager` + `MockMotionSource` so the Mac can play notes from a mouse + tilt sliders without an iPad in the loop, for sound-design iteration. Its `MIDIEngine` is constructed with `publishToCoreMIDI: false`; emitted MPE bytes hit the in-process `onLocalEvent` callback, which routes them directly into `AudioEngine.sendHostedMIDI(...)` and (for CCs) `AppController.handleSimulatorCC`. The simulator does NOT feed `MIDIInput`, so it coexists cleanly with a real iPad plugged in over USB. `AuditionRunner` watches `~/Music/Starpad-Auditions/inbox/` for JSON score files, plays each through the simulator, records the post-FX output to a sibling `.wav`, and writes a `.done` marker — so Claude (or any external watcher) can iterate sound-design parameters autonomously.

**Exception — the Chord Pad tab.** `AppController` holds a second `PitchPadEngine` (`chordPad`, beside `pitchPad`) used purely as the MPE emitter for the Mac-only **Chord Pad** — a hex grid for playing chords (`StarpadMac/Views/ChordPadView.swift` + the shared `Packages/StarpadCore/.../ChordPadGeometry.swift`). The grid converts each cell's pitch to `2^(semis/12)` and feeds the engine's ratio API; it reads the scale + tonic from `pitchPad` (read-only) and adds no cross-device state. See [Chord Pad](chord-pad.md).

**iPad does not have an `AudioEngine`.** `NoteManager.audioEngine` is always nil on iPad; the iPad is silent and produces sound only via the Mac (or any other USB-MIDI consumer).

**Almost no state syncs across devices.** Changing a preset or editing the sarangi model on the Mac doesn't ship anything to the iPad; the sarangi's sympathetic strings are an editable table owned Mac-side (independent of the playing scale — see [Sound Design](sound-design.md#sympathetic-strings)). The single exception is **Pitch Pad scale sync**: StarpadMac edits the playing scale and pushes it to the iPad as a SysEx blob over the same USB cable (see [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)). Everything else is just MPE notes on the wire.

## iPad Pipeline

The iPad's playing surface is the **Pitch Pad** (it replaced the piano
keyboard). The pad code is shared with the Mac Pitch Pad tab — see
[Pitch Pad](pitch-pad.md). `NoteManager` is still constructed but only as
the tilt sampler + `DimensionMapping` host; its keyboard/glide voice paths
are never driven (no `touchBegan` calls reach it), so they sit idle.

### Stage 1: Touch → ratio
`TouchOverlayView` captures multitouch and reports per-finger `touchBegan`,
`touchMoved`, `touchEnded` with normalized (0-1) x/y. `PitchPadSurfaceIOS`
maps each to a pixel point in the pad's logical area and calls the shared
`pitchAt(...)` soft-Voronoi solver → `(ratio, per-cell fill weights)`.

### Stage 2: Per-touch MPE (PitchPadEngine)
- `noteOn(touchId:ratio:)`: allocate an MPE channel, pin the MIDI note at
  the nearest semitone to the tonic, Note On, bend to the ratio.
- `glide(touchId:ratio:)`: update the per-touch ratio + bend (note stays
  pinned, so SWAM doesn't re-articulate while crossing cells). The pitch
  tracks the finger directly.
- `noteOff(touchId:)`: Note Off, free the channel.

### Stage 3: Tilt expression (60 Hz, iPad)
`PitchPadEngine`'s own 60 Hz `Timer` (started only in the iPad
`init(midi:)`): for each held touch it re-sends the position-derived pitch
bend plus channel pressure (aftertouch) and any mapped CCs, reading bound
values from `NoteManager.cachedParamValue(...)` / `activeCCs`. The Mac has
no tilt source, so its `glide` sends the bend directly and no loop runs.

### Stage 4: MIDI Output
`PitchPadEngine` sends through the shared `MIDIEngine`
(`publishToCoreMIDI: true`). MPE channel-voice messages flow over USB-MIDI
to whatever destination CoreMIDI exposes — typically the Mac running
StarpadMac, but also Ableton/Logic/etc.

## Mac Pipeline

### Stage 1: MIDI Input
`MIDIInput` opens a CoreMIDI input port and connects to every visible source on launch and on hot-plug. The read block parses MPE channel-voice messages and forwards every byte verbatim to the hosted Audio Units via `AudioEngine.sendHostedMIDI(...)`. There is no in-house synth voice path on the Mac any more — SWAM does all played-note synthesis.

Each Note On allocates an idle hosted-AU slot to its MPE channel (or steals the LRU slot if all 8 are busy); the channel→slot binding holds for the lifetime of the note. Per-voice messages (Pitch Bend, Channel Pressure, per-voice CCs) look up the channel's current slot and route to that one AU. Master-channel (ch 0) messages and channel-state CCs (RPN 101/100/6/38, CC 121, CC 123) broadcast to every loaded instance so global state stays consistent.

A side observer in `MIDIInput.handleCC` maintains a per-channel RPN-bend-range mirror and propagates every CC through `onCC` so `AppController` can drive Mac-owned FX parameters from incoming controllers.

### Stage 2: AudioEngine
The Mac signal graph:

```
base voice ──► hostedDriveTap ──► SarangiProcessorAU ──► symGain ────────────────────────────────────────► mainMixerNode ──► output
(model src 48k │  (sums, SRC)      (beginBuffer +                                                                ▲
 N × SWAM dry)                      SarangiEngine.renderSample — the passive coupled                             │
                                    bridge–body network, then the 2-stage FX rack)                               │
                                                                                                                │
   tanpuraSource/sitarSource ──► gains ──► preReverbMixer ──► masterFilter ──► reverb ──► postReverbEQ ─────────┘
```

The sarangi model is rendered **inline** by `SarangiProcessorAU`, a custom in-process AUv3 effect (`Packages/StarpadCore/.../SarangiProcessorAU.swift`) spliced into the graph right after `hostedDriveTap`. Its `internalRenderBlock` pulls the summed drive stereo synchronously into a private scratch buffer, builds a mono "drive" (`0.5·(L+R)`) lifted by `sarangiDriveGain`, calls `engine.beginBuffer()` once, and calls `SarangiKit.SarangiEngine.renderSample(input)` per sample — all under one `AudioEngine.lock` acquisition. `SarangiEngine` is the **complete** played voice — dry voice in → full stereo sarangi out: the v57 **passive coupled bridge–body network** (played combs + the ~39-string taraf web loading one bridge via a delay-free junction solve, the modal body + W side channel, the direct taraf tap, the radiation FIR + `E_lp`, the fitted-to-0 drone/room), then Starpad's **2-stage FX rack** (`violinPre` pre-drive + `global` mid/side output, both default OFF). The engine requires the bundled `sarangi_coupled.json` — unarmed it renders silence. The model goes `symGain → mainMixerNode` **directly, bypassing Starpad's master FX**. The master chain (`preReverbMixer → masterFilter → reverb → postReverbEQ`) is now the room for the **tanpura + sitar only**. Because the effect renders in the same engine pull as the base voice, it adds **~0 ms latency** — it replaced an earlier tap → `SPSCAudioRing` → separate source-node transport that added ~140 ms. The effect is created synchronously before `engine.start()` (an `AVAudioUnitEffect` after a one-time `registerSarangiAUOnce()`, subtype `'Srng'`) because connecting a custom AU into an already-running engine does NOT allocate its render resources. The old muted dry-SWAM passthrough is gone; the now-dangling `hostedInstrumentGain` / `hostedMakeupGain` / `sarangiMixer` / `violaBodyEQ` nodes stay **attached but disconnected** so their property setters remain valid. See [sarangi.md](sarangi.md).

Two more source nodes carry the **tanpura drone** and the **sitar** (`StarpadDSP.TanpuraModel`, each behind its own lock): `tanpuraSource/sitarSource → tanpuraGain/sitarGain → preReverbMixer`, so they ride the shared master filter + reverb + postReverbEQ (now used **only** by tanpura/sitar) and are captured by the audition recording tap. They are deliberately not summed into the sarangi effect, which is driven only by the hosted-AU (SWAM) audio. See [tanpura.md](tanpura.md) / [sitar.md](sitar.md).

### Stage 3: Preset application
`AppController.applyPreset(_:)` reads the preset's `State` struct and:

1. Copies FX values into `@Published` mirrors so the Mac UI sliders reflect them. The `didSet` hooks push each value into `AudioEngine`.
2. Loads or unloads the hosted AU (N parallel `AVAudioUnit` instances) and applies its dry-SWAM `hostedAUParams`.
3. Restores the per-preset CC-mapping table.

The sarangi model itself is **not** part of the preset — `SarangiStore` owns and persists it independently.

Only `.swamViola` ships at the moment; the picker is kept as scaffolding for future hosted-AU presets.

## Threading Model

| Side | Thread | Component | Responsibility |
|------|--------|-----------|----------------|
| iPad | Main | PitchPadEngine (Timer) | 60 Hz tilt-expression loop; touch→ratio→MPE sends |
| iPad | Main | NoteManager (Timer) | 60 Hz tilt sampling + DimensionMapping host (voice paths idle) |
| iPad | Main | SwiftUI | UI rendering (~15 Hz, throttled) |
| Mac  | CoreMIDI | MIDIInput | Forwards every MPE byte to the hosted AUs; mirrors RPN state |
| Mac  | Audio (real-time) | `SarangiProcessorAU.internalRenderBlock` | Pulls the summed drive input, runs `beginBuffer()` + `SarangiEngine.renderSample` per sample, inline |
| Mac  | Main | SwiftUI | UI rendering — slider drags push to AudioEngine via @Published `didSet` / `SarangiStore` |

The Mac audio callback (`SarangiProcessorAU.internalRenderBlock`) pulls its upstream SWAM input and runs the live `SarangiEngine` whose live-scalar gains/mixes are written by the main thread (`SarangiStore` slider edits). Thread safety is via `NSLock` (`AudioEngine.lock`): the render block acquires it once to run the per-sample render closure; structural edits build a fresh `SarangiEngine` off-thread (debounced) and swap it under the same lock, while live scalars are pushed lock-free. The hosted-AU MIDI path is realtime-safe per the AUv3 spec — `MIDIInput` calls into `AudioEngine.sendHostedMIDI` which only locks to look up the channel→slot binding, then calls the AU's `scheduleMIDIEventBlock` outside the lock. There is no longer any drive-ring / tap thread (the old `SPSCAudioRing` transport was deleted): the sarangi renders inline in the SWAM signal path.

## Dependency Injection

iPad — managers are `@StateObject` in `ContentView` and wired in `onAppear`:

```swift
noteManager.motionSource = motion
noteManager.midiEngine = midi
midi.start()
```

Mac — `AppController` owns audio + midi + midiIn and wires them in `init`:

```swift
midiIn.audioEngine = audio
// AppController's @Published setters push directly to `audio`
// via didSet hooks — no NoteManager indirection.
```

## Polyphony (iPad)

The Pitch Pad is inherently polyphonic: each finger (`touchId`) gets its
own MPE channel from `PitchPadEngine`'s round-robin allocator (channels
1-15), so concurrent touches never share bend/pressure state. There is no
mono/poly toggle — every touch is an independent voice. The display
`SoundingState` (Hz readout + cell fills) is single-valued and reflects
whichever touch updated last; the MIDI is fully polyphonic regardless.

The Mac renders whatever channels the iPad sends.

## Key Design Decisions

- **No shared state, no syncing.** Earlier iterations tried Bonjour + UDP, then SysEx settings sync; both proved brittle. The current design has no cross-device state at all — just MIDI.
- **MPE per note.** Each iPad-side note allocation rotates through MIDI channels 1-15 so old notes' pitch bends and channel pressure don't bleed into new notes.
- **Mac as the sound source.** The Mac hosts SWAM Violin (dry) and runs the full `SarangiKit` model on its output for the played voice; iPad is intentionally silent. This decoupling makes the iPad a useful general-purpose MPE controller for Ableton/Logic/etc., not just for the Mac side.
- **Hosted AUs first-class.** `AppController.applyPreset` loads N parallel `AVAudioUnit` instances (`Config.maxHostedPolyVoices`, default 8) since SWAM is monophonic. MPE channels round-robin onto those slots; their summed dry audio (`hostedDriveTap`) drives the sarangi model inline via the `SarangiProcessorAU` effect's `renderSample` call (no tap/ring transport).
- **Sarangi is a self-contained model.** `SarangiKit` (`Packages/SarangiKit/`) is a pure-Swift port: `SarangiEngine.renderSample` is the played voice — the passive coupled bridge–body network with its own modal body, radiation FIR, and a **2-stage FX rack** (`violinPre` pre-drive + `global`, each filter+EQ+reverb) — routed `symGain → mainMixerNode` direct, **bypassing Starpad's master FX** (which serves only the tanpura + sitar). StarpadDSP now owns only the tanpura + sitar (`TanpuraModel`).
- **Config.swift**: system-level constants. iPad's dimension-mappable parameter ranges in `TiltMapping.swift` via `MappableParameter.defaultRange`. The 22 sarangi model params live in `SarangiKit`'s `ParamSpec.all` (ranges/defaults/group/structural flag); the sarangi FX rack lives on `InstrumentState.fx`; Mac master-FX params live as `@Published` fields on `AppController`.
- **Scales**: there is one configured *playing* scale — a `PitchScale` (the Pitch Pad's JI ratios, persisted via `ScaleStore`), edited on the Mac and synced to the iPad; the legacy `Scale`/`ScaleEditorView` keyboard model is no longer used for playing. The sarangi's sympathetic strings are a **separate, editable `[StringSpec]` table** (raga + tonic in `InstrumentState`), independent of the playing scale. `Scale.swift` still hosts 12-TET note-name / frequency helpers used on both sides.
- **3-axis calibration** (iPad): 7 capture points (rest + 2 endpoints × 3 axes) in (pitch, roll, yaw) 3D space. Values normalized to -1..+1 per axis.
