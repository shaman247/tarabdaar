# Architecture

Starpad is two devices over one USB cable. The iPad is a pure MPE-MIDI controller. The Mac is a MIDI-driven sound module that renders the **sarangi String voice** (`SarangiKit.BowEngine` + the `CBowKernel` C friction kernel) — the only voice, carrying the played strings, the sympathetic (tarab) web, the body, and the room all in-kernel. They share no state — only standard MIDI on the wire (plus one-way pad-sync SysEx) — and each side owns a disjoint slice of the instrument.

## Module Overview

```
iPad (Starpad target) — controller, silent
═══════════════════════════════════════════════════════════════════
StarpadApp.swift
  └── ContentView.swift
        ├── PitchPadEngine (StarpadCore: touch-position → ratio → pinned
        │     │             note + bend; the shared scale/tonic model)
        │     │                            ──► MIDIEngine (shared)
        │     └── PitchScale / FretPadGeometry (the fret field, onset snap,
        │                       drag assist — shared with Mac)
        ├── FretPadViewIOS         (the ONLY surface: render + multitouch,
        │                           always perform mode)
        ├── NoteManager  (StarpadCore: now ONLY the tilt sampler — it streams
        │                 the raw tilt report; its mapping/binding caches and
        │                 keyboard/glide voice paths are gone or idle)
        ├── MIDIEngine             (CoreMIDI MPE output — shared by the pad)
        ├── MotionManager          (CoreMotion: 200 Hz tilts + accel)
        ├── TouchOverlayView       (multi-touch capture)
        └── CalibrationView        (first-launch calibration)

           ─────── USB MPE MIDI ───────►
           Note On/Off, Pitch Bend, plus the RAW TILT REPORT
           (CCs 16/17/18) — the Mac evaluates every binding

Mac (StarpadMac target) — sound module, audible
═══════════════════════════════════════════════════════════════════
StarpadMacApp.swift
  └── MacMainWindow
        ├── AppController (Mac-side source of truth)
        │     ├── AudioEngine            (StarpadCore: hosts the String
        │     │     │                     voice + routes MPE MIDI to it)
        │     │     └── StringVoiceSource — SarangiKit.BowEngine + CBowKernel
        │     │           the WHOLE instrument in-kernel (played strings +
        │     │           taraf + body + radiation + room), 96→48 kHz,
        │     │           node → symGain → mainMixerNode → output
        │     ├── SarangiStore            (owns the editable InstrumentState —
        │     │                            raga + tonic + the [StringSpec] tarab
        │     │                            table that tunes the kernel's taraf)
        │     ├── StringParamStore        (the bowed_string.json physics
        │     │                            overrides — the Parameters tab)
        │     ├── MIDIInput              (CoreMIDI input — every MPE byte
        │     │                            forwarded to the String voice)
        │     ├── MIDIEngine             (CoreMIDI — present for symmetry; unused on Mac)
        │     ├── @Published composites / tiltMapping (Controls tab)
        │     ├── @Published paramValues  (resting values of the live/hybrid
        │     │                            parameters — Parameters tab)
        │     └── fretArrangement (the Fret Pad layout, synced to the iPad)
        └── Views/  (LiveVisualizer, TarabView, FretPad, TiltControls,
                     Parameters, Setup)
```

**Mac does not use `NoteManager` for real-iPad input.** `AppController` holds Mac-side state as `@Published` fields; setters push directly to `AudioEngine`. The **tarab tuning** is owned by `SarangiStore` (`StarpadMac/SarangiStore.swift`): it holds the editable `InstrumentState` (raga + tonic + the sympathetic-string `[StringSpec]` table), persists it to UserDefaults (and into the `.starpad` preset), and routes each edit to `AudioEngine.rebuildSarangi` (a debounced off-main rebuild that pushes the tuning into the String kernel's taraf). The **String physics scalars** are owned by `StringParamStore` (persisted override dict → `AudioEngine.setStringVoiceOverrides` → debounced `BowEngine` rebuild). There is no `SoundPreset` / hosted-AU / base-voice machinery anymore — the String voice is armed unconditionally at startup.

**Exception — the headless simulator.** `IPadSimulator` (Mac-only, no tab) holds its own `NoteManager` + `MockMotionSource` so the audition runner can play notes from a script. Its `MIDIEngine` is constructed with `publishToCoreMIDI: false`; emitted MPE bytes hit the in-process `onLocalEvent` callback, which routes them directly into `AudioEngine.sendHostedMIDI(...)` and (for CCs) `AppController.handleSimulatorCC`. The simulator does NOT feed `MIDIInput`, so it coexists cleanly with a real iPad plugged in over USB. `AuditionRunner` watches the inbox for JSON score files, plays each through the simulator, records the output to a sibling `.wav`, and writes a `.done` marker — so an external watcher can iterate sound-design parameters autonomously.

**iPad does not have an `AudioEngine`.** `NoteManager.audioEngine` is always nil on iPad; the iPad is silent and produces sound only via the Mac (or any other USB-MIDI consumer).

**Almost no state syncs across devices.** Editing the tarab or the String physics on the Mac doesn't ship anything to the iPad; the tarab strings are an editable table owned Mac-side (independent of the playing scale — see [Sound Design](sound-design.md#sympathetic-strings--the-editable-bank)). The exceptions are the one-way **pad-sync SysEx**: the playing scale, the Fret Pad layout, and the tilt bindings, each pushed to the iPad over the same USB cable (see [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)). Everything else is just MPE notes on the wire.

## iPad Pipeline

The iPad's playing surface is the **Fret Pad** — see [Fret Pad](fret-pad.md).
`PitchPadEngine` is the MPE emitter (and survives as the shared scale/tonic
model). `NoteManager` is still constructed but only as the tilt sampler +
`DimensionMapping` host; its keyboard/glide voice paths are never driven (no
`touchBegan` calls reach it), so they sit idle.

### Stage 1: Touch → ratio
`TouchOverlayView` captures multitouch and reports per-finger `touchBegan`,
`touchMoved`, `touchEnded` with normalized (0-1) x/y. `PitchPadSurfaceIOS`
maps each to a pixel point in the pad's logical area and calls the shared
`pitchAt(...)` soft-Voronoi solver → `(ratio, per-cell fill weights)`.

### Stage 2: Per-touch MPE (PitchPadEngine)
- `noteOn(touchId:ratio:)`: allocate an MPE channel, pin the MIDI note at
  the nearest semitone to the tonic, Note On, bend to the ratio.
- `glide(touchId:ratio:)`: update the per-touch ratio + bend (note stays
  pinned, so the voice doesn't re-articulate while gliding). The pitch
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
`MIDIInput` opens a CoreMIDI input port and connects to every visible source on launch and on hot-plug. The read block parses MPE channel-voice messages and forwards every byte into `AudioEngine.sendHostedMIDI(...)` (name kept for continuity). That method consumes the Fret Pad drone CCs (102–104; 105 — the retired 4th slot — is still swallowed, never forwarded) and the composite-slot CCs, and routes everything else — Note On/Off, Pitch Bend, Channel Pressure, per-voice CCs — to the String voice's `BowControlMapper` via `routeSarangiModelMIDI`. There is no hosted AU; the `BowEngine` does all played-note synthesis, keyed per-finger by the status byte's channel nibble (the Starpad MPE divergence — per-note bend).

A side observer in `MIDIInput.handleCC` propagates every CC through `onCC` so `AppController` can drive Mac-owned parameters (the composite slots) from incoming controllers.

### Stage 2: AudioEngine
The Mac signal graph:

```
MPE in ──► sendHostedMIDI / routeSarangiModelMIDI ──► StringVoiceSource ──► symGain ──► mainMixerNode ──► output
                                                        (BowEngine + CBowKernel,
                                                         96 kHz → 48 kHz, whole instrument)
```

The played voice is `StringVoiceSource` (`Packages/StarpadCore/.../StringVoiceSource.swift`), an `AVAudioSourceNode` at 48 kHz wrapping `SarangiKit.BowEngine`. The kernel is the **complete** instrument — the played strings, the modal-jawari taraf, the formula body, radiation, and room — so its node connects **directly** to `symGain → mainMixerNode`; there is no master filter/reverb bus. The source node is attached + connected in `setSarangiModelVoiceEnabled(true)`, called unconditionally at startup since the String voice is the only voice. Structural tarab/tonic changes flow through `AudioEngine.rebuildSarangi`: the engine is rebuilt off-main (tables + kernel init + jt worker-pool spawn), generation-checked, and swapped lock-free; the String physics scalars ride `stringVoiceOverrides`. See [sarangi.md](sarangi.md).

### Stage 3: Startup / state application
There is no preset system. At init `AppController` arms the String voice (`audio.setSarangiModelVoiceEnabled(true)`), seeds the physics overrides from `StringParamStore`, pushes the tarab tuning via `rebuildSarangi`, and sets the Mac pads' flat expression level to 32. Live edits (Parameters/Tarab/Controls tabs) push to `AudioEngine` through `AppController.applyParamToVoice` and the store `didSet` hooks.

## Threading Model

| Side | Thread | Component | Responsibility |
|------|--------|-----------|----------------|
| iPad | Main | PitchPadEngine (Timer) | 60 Hz tilt-expression loop; touch→ratio→MPE sends |
| iPad | Main | NoteManager (Timer) | 60 Hz tilt sampling + DimensionMapping host (voice paths idle) |
| iPad | Main | SwiftUI | UI rendering (~15 Hz, throttled) |
| Mac  | CoreMIDI | MIDIInput | Forwards every MPE byte to the String voice (`sendHostedMIDI` → `routeSarangiModelMIDI`) |
| Mac  | Audio (real-time) | `StringVoiceSource` render block | Pulls decimated samples from the `BowEngine` kernel |
| Mac  | Main | SwiftUI | UI rendering — slider drags push to AudioEngine via @Published `didSet` / `SarangiStore` / `StringParamStore` |

The Mac audio callback is the `StringVoiceSource`'s `AVAudioSourceNode` render block, pulling from the `BowEngine` kernel (which runs its own async jawari worker pool). Structural edits (tarab tuning, physics overrides) build a fresh `BowEngine` off-main (debounced, generation-checked) and swap it lock-free; the runtime taraf axes (purity/decay/tone) are pushed and chunk-rate smoothed inside the engine. The MIDI path (`MIDIInput` → `sendHostedMIDI` → `routeSarangiModelMIDI` → `BowControlMapper`) is control-rate and does no heavy work on the audio thread.

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

The Fret Pad is inherently polyphonic: each finger (`touchId`) gets its
own MPE channel from `PitchPadEngine`'s round-robin allocator (channels
1-15), so concurrent touches never share bend/pressure state. There is no
mono/poly toggle — every touch is an independent voice. The display
`SoundingState` (Hz readout + cell fills) is single-valued and reflects
whichever touch updated last; the MIDI is fully polyphonic regardless.

The Mac renders whatever channels the iPad sends.

## Key Design Decisions

- **No shared state, no syncing.** Earlier iterations tried Bonjour + UDP, then SysEx settings sync; both proved brittle. The current design has no cross-device state at all — just MIDI.
- **MPE per note.** Each iPad-side note allocation rotates through MIDI channels 1-15 so old notes' pitch bends and channel pressure don't bleed into new notes.
- **Mac as the sound source.** The Mac renders the `SarangiKit` String voice; iPad is intentionally silent. This decoupling makes the iPad a useful general-purpose MPE controller for Ableton/Logic/etc., not just for the Mac side.
- **One self-contained voice.** `SarangiKit` (`Packages/SarangiKit/`) is a pure-Swift/C port: `BowEngine` + `CBowKernel` is the played voice — the whole instrument in-kernel (played strings + taraf + body + radiation + room) — routed `StringVoiceSource → symGain → mainMixerNode` direct. There is no hosted AU, no coupled network, no master FX bus, and no base-voice selection (all removed 2026-07-24). `SarangiKit` began as a vendored copy of `~/Desktop/sarangi`; that link was cut 2026-07-24 and everything it carried for upstream parity — the coupled `SarangiEngine`, the additive violin voice, the byte-parity mono kernel — was deleted.
- **Config.swift**: system-level constants. Every instrument parameter is a `ParamSpec` in **`ParamRegistry.swift`** (key, group, range, apply strategy) — one source of truth for the Parameters tab, the composite/tilt menus, and the generated `docs/parameters.md`. `.rebuild` values are stored by `StringParamStore` (the `bowed_string.json` override dict), `.live`/`.hybrid` resting values on `AppController.paramValues`. Tilt-binding targets are `MapTarget` in `TiltMapping.swift`; the tarab is the `[StringSpec]` table on `InstrumentState`; composites live on `AppController.composites`.
- **Scales**: there is one configured *playing* scale — a `PitchScale` (JI ratios, persisted via `ScaleStore`), edited on the Mac (in the Fret Pad tab) and synced to the iPad; the legacy `Scale`/`ScaleEditorView` keyboard model is no longer used for playing. The tarab is a **separate, editable `[StringSpec]` table** (raga + tonic in `InstrumentState`), independent of the playing scale. `Scale.swift` still hosts 12-TET note-name / frequency helpers used on both sides.
- **3-axis calibration** (iPad): 7 capture points (rest + 2 endpoints × 3 axes) in (pitch, roll, yaw) 3D space. Values normalized to -1..+1 per axis.
