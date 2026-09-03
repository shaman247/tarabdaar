# Architecture

Tarabdaar is two devices over one link (USB cable, or the BLE-MIDI session when unplugged). The iPad is a silent controller; the Mac is the sound module rendering the **sarangi String voice** (`SarangiKit.BowEngine` + the `CBowKernel` C friction kernel) — the played strings, the sympathetic (tarab) web, the body, and the room all in-kernel. **The wire is TLP (2026-08-14)** — one binary protocol (`TarabdaarCore/Link/`): a latest-wins performance state frame (all touches at full-resolution pitch + tilt + drones, atomic) plus reliable sync events, tunneled in a single SysEx envelope over the CoreMIDI transports (see [MIDI & Audio](midi-and-audio.md)). They share no state beyond the sync events, and each side owns a disjoint slice of the instrument.

## Module Overview

```
iPad (Tarabdaar target) — controller, silent
═══════════════════════════════════════════════════════════════════
TarabdaarApp.swift
  └── ContentView.swift
        ├── PitchPadEngine (TarabdaarCore: touch-position → ratio →
        │     │             fractional-MIDI pitch; the shared scale/tonic
        │     │             model)      ──► OutboundPlayState (shared)
        │     └── PitchScale / FretPadGeometry (the fret field, onset snap,
        │                       drag assist — shared with Mac)
        ├── FretPadViewIOS         (the ONLY surface: render + multitouch,
        │                           always perform mode)
        ├── NoteManager  (TarabdaarCore: the 60 Hz tilt sampler — writes
        │                 tilt into OutboundPlayState; audition MIDI paths idle)
        ├── TarabLink (role .pad)  (120 Hz off-main paced sender: state →
        │                 PERF_STATE frames; events; ping/pong)
        ├── MIDIEngine             (the tunnel's byte pump: wired-first
        │                 destination routing, sendSysExToLink)
        ├── ScaleSyncReceiver      (CoreMIDI SysEx reassembly → TarabLink)
        ├── MotionManager          (CoreMotion: 200 Hz raw tilts + accel)
        └── TouchOverlayView       (multi-touch capture)

           ── TLP over CoreMIDI SysEx (USB session, or BLE-MIDI) ──►
           PERF_STATE frames (touches + 16-bit tilt + drones, atomic)
           — the Mac evaluates every binding

Mac (TarabdaarMac target) — sound module, audible
═══════════════════════════════════════════════════════════════════
TarabdaarMacApp.swift
  └── MacMainWindow
        ├── AppController (Mac-side source of truth)
        │     ├── AudioEngine            (TarabdaarCore: hosts the String
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
        │     ├── MIDIInput              (CoreMIDI input — SysEx reassembly
        │     │                            → TarabLink; external MPE gear
        │     │                            still forwards channel-voice)
        │     ├── TarabLink (role .host) + LinkIngest (frame diff → touchOn/
        │     │                            Glide/Off + drones + tilt)
        │     ├── MIDIEngine             (CoreMIDI — the tunnel's outbound send)
        │     ├── @Published composites / tiltMapping (Controls tab)
        │     ├── @Published paramValues  (resting values of the live/hybrid
        │     │                            parameters — Parameters tab)
        │     └── fretArrangement (the Fret Pad layout, synced to the iPad)
        └── Views/  (LiveVisualizer, StringsView, FretPad, TiltControls,
                     Parameters, Setup)
```

**Mac does not use `NoteManager` for real-iPad input.** `AppController` holds Mac-side state as `@Published` fields; setters push directly to `AudioEngine`. The **tarab tuning** is owned by `SarangiStore` (`TarabdaarMac/SarangiStore.swift`): it holds the editable `InstrumentState` (raga + tonic + the sympathetic-string `[StringSpec]` table), persists it to UserDefaults (and into the `.tarabdaar` preset), and routes each edit to `AudioEngine.rebuildSarangi` (a debounced off-main rebuild that pushes the tuning into the String kernel's taraf). The **String physics scalars** are owned by `StringParamStore` (persisted override dict → `AudioEngine.setStringVoiceOverrides` → debounced `BowEngine` rebuild). There is no `SoundPreset` / hosted-AU / base-voice machinery anymore — the String voice is armed unconditionally at startup.

**Exception — the headless simulator.** `IPadSimulator` (Mac-only, no tab) holds its own `NoteManager` + `MockMotionSource` so the audition runner can play notes from a script. Its `MIDIEngine` is constructed with `publishToCoreMIDI: false`; emitted MPE bytes hit the in-process `onLocalEvent` callback, which routes them directly into `AudioEngine.sendHostedMIDI(...)` and (for CCs) `AppController.handleSimulatorCC`. The simulator does NOT feed `MIDIInput`, so it coexists cleanly with a real iPad plugged in over USB. `AuditionRunner` watches the inbox for JSON score files, plays each through the simulator, records the output to a sibling `.wav`, and writes a `.done` marker — so an external watcher can iterate sound-design parameters autonomously.

**iPad does not have an `AudioEngine`.** `NoteManager.audioEngine` is always nil on iPad; the iPad is silent and produces sound only via the Mac.

**Almost no state syncs across devices.** Editing the tarab or the String physics on the Mac doesn't ship anything to the iPad; the tarab strings are an editable table owned Mac-side (independent of the playing scale — see [Sound Design](sound-design.md#sympathetic-strings--the-editable-bank)). The exceptions are the one-way **pad-sync TLP events**: the playing scale and the Fret Pad layout (see [MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)). Everything else is performance state frames on the wire.

## iPad Pipeline

The iPad's playing surface is the **Fret Pad** — see [Fret Pad](fret-pad.md).
`PitchPadEngine` writes touches into `OutboundPlayState` (and survives as the
shared scale/tonic model). `NoteManager` is still constructed but only as the
tilt sampler; its keyboard/glide voice paths are never driven (no `touchBegan`
calls reach it), so they sit idle.

### Stage 1: Touch → ratio
`TouchOverlayView` captures multitouch and reports per-finger `touchBegan`,
`touchMoved`, `touchEnded` with normalized (0-1) x/y. `PitchPadSurfaceIOS`
maps each to a pixel point in the pad's logical area and calls the shared
`pitchAt(...)` soft-Voronoi solver → `(ratio, per-cell fill weights)`.

### Stage 2: Per-touch state (PitchPadEngine)
- `noteOn(touchId:ratio:)`: write the touch into `OutboundPlayState` at
  full-resolution fractional-MIDI pitch (`tonicFractionalMidi +
  12·log2(ratio)`) — no channel, no note pinning, no bend split.
- `glide(touchId:ratio:)`: update the touch's pitch (change-gated). The
  pitch tracks the finger directly; the Mac ramps to each update within
  one render block (no meend smoother since 2026-08-24).
- `noteOff(touchId:)`: remove the touch — its absence from the next frame
  IS the note-off.

### Stage 3: Tilt (60 Hz, iPad)
`NoteManager`'s 60 Hz tick writes the raw tilt into the same
`OutboundPlayState`, so tilt and pitch ride each frame atomically.

### Stage 4: Wire output (TarabLink)
`TarabLink`'s 120 Hz paced sender — a `DispatchSourceTimer` on its own
`userInteractive` serial queue, OFF the main thread — snapshots the dirty
state into one `PERF_STATE` frame per tick (250 ms heartbeat when idle)
and sends it via `MIDIEngine.sendSysExToLink`: the USB session wired-first,
the BLE-MIDI session otherwise. UI stalls can no longer delay the wire.

## Mac Pipeline

### Stage 1: Link input
`MIDIInput` opens a CoreMIDI input port and connects to every visible source on launch and on hot-plug. Inbound SysEx is reassembled and handed to `TarabLink` (the TLP tunnel); `LinkIngest` diffs each `PERF_STATE` frame — removals → onsets/retriggers → glides, drone-mask edges, change-gated tilt — into `AudioEngine.touchOn/touchGlide/touchOff` (touch-id keyed, full-resolution pitch) and `setDronePressed`, on the link queue. Link drop or 1.5 s staleness runs the kill path (`touchesAllOff`). Channel-voice MIDI from external controllers still parses and forwards into `AudioEngine.sendHostedMIDI(...)` → `routeSarangiModelMIDI` → the mapper's `.midi` slot keys — the same slots and allocation laws the touch path uses (every note-on a fresh string since 2026-08-24).

### Stage 2: AudioEngine
The Mac signal graph:

```
TLP in ──► LinkIngest ──► AudioEngine.touch* ──► StringVoiceSource ──► symGain ──► mainMixerNode ──► output
MIDI in ─► sendHostedMIDI / routeSarangiModelMIDI ─┘  (BowEngine + CBowKernel,
                                                       96 kHz → 48 kHz, whole instrument)
```

The played voice is `StringVoiceSource` (`Packages/TarabdaarCore/.../StringVoiceSource.swift`), an `AVAudioSourceNode` at 48 kHz wrapping `SarangiKit.BowEngine`. The kernel is the **complete** instrument — the played strings, the modal-jawari taraf, the formula body, radiation, and room — so its node connects **directly** to `symGain → mainMixerNode`; there is no master filter/reverb bus. The source node is attached + connected in `setSarangiModelVoiceEnabled(true)`, called unconditionally at startup since the String voice is the only voice. Structural tarab/tonic changes flow through `AudioEngine.rebuildSarangi`: the engine is rebuilt off-main (tables + kernel init + jt worker-pool spawn), generation-checked, and swapped lock-free; the String physics scalars ride `stringVoiceOverrides`. See [sarangi.md](sarangi.md).

### Stage 3: Startup / state application
There is no preset system. At init `AppController` arms the String voice (`audio.setSarangiModelVoiceEnabled(true)`), seeds the physics overrides from `StringParamStore`, pushes the tarab tuning via `rebuildSarangi`, and sets the Mac pads' flat expression level to 32. Live edits (Parameters/Strings/Controls tabs) push to `AudioEngine` through `AppController.applyParamToVoice` and the store `didSet` hooks.

## Threading Model

| Side | Thread | Component | Responsibility |
|------|--------|-----------|----------------|
| iPad | Main | PitchPadEngine | touch→ratio→`OutboundPlayState` writes (O(1) locked) |
| iPad | Main | NoteManager (Timer) | 60 Hz tilt sampling → `OutboundPlayState` |
| iPad | tarablink queue | TarabLink (DispatchSourceTimer) | 120 Hz paced sender — state frames onto the wire, off-main |
| iPad | Main | SwiftUI | UI rendering (~15 Hz, throttled) |
| Mac  | CoreMIDI | MIDIInput | SysEx reassembly → TarabLink; external channel-voice → `sendHostedMIDI` |
| Mac  | tarablink queue | TarabLink + LinkIngest | Frame decode + diff → `AudioEngine.touch*` (the CoreMIDI thread's old role) |
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
- **Tilt calibration**: ONE step, Mac-side, arm-only (2026-08-13) — the guided arm calibration (Setup tab; rest + 3 sweeps over the iPad's raw tilt stream, see [midi-and-audio.md](midi-and-audio.md)). The iPad streams raw attitude at a fixed ±90° scale (-1..+1 per axis); its legacy 7-point calibration is deleted, and the 2026-08-12 wrist half (Joy-Con fusion, tilt4) was removed the next day.
