# Architecture

Tarabdaar is two devices over one link (USB cable, or the BLE-MIDI session when unplugged). The iPad is a silent controller; the Mac is the sound module. The wire is **TLP** (`Packages/TarabdaarCore/.../Link/`): a latest-wins performance state frame (every touch at full-resolution pitch, tilt, strike, drones and chord selection — atomic) plus reliable sync events, tunneled in one SysEx envelope over the CoreMIDI transports (see [MIDI & Audio](midi-and-audio.md)). The two sides share no state beyond the sync events, and each owns a disjoint slice of the instrument.

## Module overview

```
iPad (Tarabdaar target) — controller, silent
═══════════════════════════════════════════════════════════════════
TarabdaarApp.swift
  └── ContentView.swift
        ├── PitchPadEngine (TarabdaarCore: touch position → ratio →
        │     │             fractional-MIDI pitch; the shared scale/tonic
        │     │             model)      ──► OutboundPlayState (shared)
        │     └── PitchScale / FretPadGeometry (the fret field, onset snap,
        │                       drag assist — shared with the Mac)
        ├── FretPadViewIOS         (the ONLY surface: render + multitouch,
        │                           always perform mode; the chord bar)
        ├── NoteManager            (the 60 Hz tilt sampler → OutboundPlayState)
        ├── TarabLink (role .pad)  (120 Hz off-main paced sender: PERF_STATE
        │                           frames; events; ping/pong)
        ├── MIDIEngine             (the tunnel's byte pump, wired-first routing)
        ├── ScaleSyncReceiver      (SysEx reassembly → TarabLink; holds the
        │                           synced scale, layout and JOYCON_STATE)
        ├── MotionManager          (CoreMotion: 200 Hz raw tilts + accel + strike)
        └── TouchOverlayView       (multi-touch capture)

           ── TLP over CoreMIDI SysEx (USB session, or BLE-MIDI) ──►
           PERF_STATE frames — the Mac evaluates every binding

Mac (TarabdaarMac target) — sound module, audible
═══════════════════════════════════════════════════════════════════
TarabdaarMacApp.swift
  └── MacMainWindow
        ├── AppController (Mac-side source of truth)
        │     ├── AudioEngine            (TarabdaarCore: hosts the voices,
        │     │     │                     routes touches + in-process MIDI)
        │     │     ├── StringVoiceSource — SarangiKit.BowEngine + CBowKernel:
        │     │     │     played strings + taraf + body + radiation + room
        │     │     │     in-kernel, 96→48 kHz, node → symGain → mainMixerNode
        │     │     └── TanpuraVoiceSource ×2 — SarangiKit.TanpuraEngine
        │     │           (the Tanpura: drone voice / optional main instrument;
        │     │           the Sitar: main instrument only), both charging the
        │     │           String kernel's inject ring
        │     ├── GlideSequencer          (the glide queue above allocation)
        │     ├── SarangiStore            (the editable InstrumentState — the
        │     │                            [StringSpec] tarab table, follower)
        │     ├── StringParamStore        (bowed_string.json overrides)
        │     ├── MIDIInput + TarabLink (role .host) + LinkIngest
        │     │     (SysEx reassembly → frame diff → touchOn/Glide/Off +
        │     │      drones + tilt + chord; external channel-voice MIDI)
        │     ├── MIDIEngine             (the tunnel's outbound send)
        │     ├── JoyConInput            (transports, arm/wrist/stick calibration)
        │     ├── KeyboardNotePlayer     (computer-keyboard notes)
        │     ├── @Published composites / tiltMapping / paramValues
        │     └── fretArrangement        (the Fret Pad layout, synced to the iPad)
        └── Views/  (LiveVisualizer, Strings, FretPad, TiltControls,
                     Parameters, FX, Setup, Scope, TarafScope)
```

**The Mac does not use `NoteManager` for iPad input.** `AppController` holds Mac-side state as `@Published` fields; setters push directly to `AudioEngine`. The **tarab tuning** is owned by `SarangiStore` (`TarabdaarMac/SarangiStore.swift`): it holds the editable `InstrumentState` (the sympathetic-string `[StringSpec]` table, the chromatic set, the melody follower), persists it to UserDefaults and into the `.tarabdaar` preset, and routes each edit to `AudioEngine.rebuildSarangi` — a debounced off-main rebuild that pushes the tuning into the String kernel's taraf. The **String physics scalars** are owned by `StringParamStore` (persisted override dict → `AudioEngine.setStringVoiceOverrides` → debounced `BowEngine` rebuild). The String voice is armed unconditionally at startup; the Live tab's Instrument picker selects the played voice (String / Tanpura / Sitar).

**The headless simulator.** `IPadSimulator` (Mac-only, no tab) holds its own `NoteManager` + `MockMotionSource` so `AuditionRunner` can play notes from a script. Its `MIDIEngine` is constructed with `publishToCoreMIDI: false`; emitted MPE bytes hit the in-process `onLocalEvent` callback, which routes them into `AudioEngine.sendHostedMIDI(...)` and (for CCs) `AppController.handleSimulatorCC`. The simulator never feeds `MIDIInput`, so it coexists with a real iPad. See [Simulator & Audition Loop](simulator.md).

**The iPad has no `AudioEngine`.** `NoteManager.audioEngine` is nil on the iPad; sound comes only from the Mac.

**Almost no state syncs across devices.** Editing the tarab or the physics on the Mac ships nothing to the iPad. The exceptions are the one-way **pad-sync TLP events** — the playing scale and the Fret Pad layout ([MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)) — plus the acted-on `JOYCON_STATE` fields (`connected`, `fieldWarp`, `octave`) and the iPad's chord selection riding the state frame. Everything else is performance state on the wire.

## iPad pipeline

The playing surface is the **Fret Pad** — see [Fret Pad](fret-pad.md). `PitchPadEngine` writes touches into `OutboundPlayState` and is the shared scale/tonic model. `NoteManager` is constructed only as the tilt sampler; its keyboard/glide voice paths sit idle.

1. **Touch → ratio.** `TouchOverlayView` captures multitouch and reports per-finger `touchBegan` / `touchMoved` / `touchEnded` with normalized x/y. `FretPadSurfaceIOS` maps each to a point in the pad's logical area and resolves the fret field, onset snap and drag assist to a ratio.
2. **Per-touch state (`PitchPadEngine`).** `noteOn(touchId:ratio:)` writes the touch at full-resolution fractional-MIDI pitch (`tonicFractionalMidi + 12·log2(ratio)`, plus the onset-captured octave shift) — no channel, no note pinning, no bend split. `glide(touchId:ratio:)` updates the pitch (change-gated); the Mac ramps to each update within one render block. `noteOff(touchId:)` removes the touch — its absence from the next frame IS the note-off.
3. **Tilt and strike (60 Hz).** `NoteManager`'s tick writes the raw tilt into the same `OutboundPlayState`; `MotionManager` supplies the strike envelope and the per-touch strike velocity, so everything rides each frame atomically.
4. **Wire output (`TarabLink`).** A 120 Hz `DispatchSourceTimer` on its own `userInteractive` serial queue snapshots the dirty state into one `PERF_STATE` frame per tick (250 ms heartbeat when idle) and sends it via `MIDIEngine.sendSysExToLink` — the USB session wired-first, BLE-MIDI otherwise. UI stalls cannot delay the wire.

## Mac pipeline

1. **Link input.** `MIDIInput` opens a CoreMIDI input port and connects to every visible source on launch and hot-plug. Inbound SysEx is reassembled and handed to `TarabLink`; `LinkIngest` diffs each `PERF_STATE` frame — removals → onsets/retriggers → glides, drone-mask edges, chord-selection edges, change-gated tilt — into `AudioEngine.touchOn/touchGlide/touchOff` (touch-id keyed, full-resolution pitch), `setDronePressed` and `AppController.strumChord`, on the link queue. Link drop or 1.5 s staleness runs the kill path (`touchesAllOff`). Channel-voice MIDI from external controllers forwards into `AudioEngine.sendHostedMIDI(...)` → `routeSarangiModelMIDI` → the mapper's `.midi` slot keys — the same slots and allocation laws as the touch path.
2. **AudioEngine.** The signal graph:

```
TLP in ──► LinkIngest ──► AudioEngine.touch* ──► GlideSequencer ──► StringVoiceSource ──► symGain ──► mainMixerNode ──► output
MIDI in ─► sendHostedMIDI / routeSarangiModelMIDI ────────────────┘  (BowEngine + CBowKernel, 96 → 48 kHz)
                                              plucked voices ──► TanpuraVoiceSource(s) ──┘ (+ inject ring → String taraf)
```

`StringVoiceSource` (`Packages/TarabdaarCore/.../StringVoiceSource.swift`) is an `AVAudioSourceNode` at 48 kHz wrapping `SarangiKit.BowEngine`. The kernel is the **complete** instrument — played strings, the modal-jawari taraf, the formula body, radiation and room — so its node connects directly to `symGain → mainMixerNode`; there is no master filter/reverb bus (the [FX rack](fx.md) lives inside `BowEngine`). The plucked voices are `TanpuraVoiceSource` nodes beside it, and their output also charges the String kernel's sympathetic web through its inject ring. Its `.live` knobs go through ONE plumbing table (`StringVoiceSource.setControl`: per-key clamp, a cached value and the `BowEngine` push, plus the knob's NEUTRAL — `setEngine` re-applies only the knobs that differ from neutral, so a fresh engine stays byte-null); `AudioEngine.setStringControlParam` is a lookup into it. Structural tarab/tonic changes flow through `AudioEngine.rebuildSarangi`: the engine is rebuilt off-main (tables + kernel init + jt worker-pool spawn), generation-checked, and swapped lock-free under a crossfade; the physics scalars ride `stringVoiceOverrides`. See [Sarangi](sarangi.md).

3. **Startup.** `AppController` arms the String voice, seeds the physics overrides from `StringParamStore`, pushes the tarab tuning via `rebuildSarangi`, restores the last preset state (presets are one `TarabdaarPreset` document — see [Sound Design](sound-design.md)), and sets the Mac pads' flat expression level to 32. Live edits (Parameters / Strings / Controls / FX tabs) reach `AudioEngine` through the one apply path, `AppController.applyParamToVoice`, and the store `didSet` hooks.

## Threading model

| Side | Thread | Component | Responsibility |
|------|--------|-----------|----------------|
| iPad | Main | PitchPadEngine | touch → ratio → `OutboundPlayState` writes (O(1) locked) |
| iPad | Main | NoteManager (Timer) | 60 Hz tilt sampling → `OutboundPlayState` |
| iPad | tarablink queue | TarabLink (DispatchSourceTimer) | 120 Hz paced sender — state frames onto the wire |
| iPad | Main | SwiftUI | UI rendering (~15 Hz, throttled) |
| Mac | CoreMIDI | MIDIInput | SysEx reassembly → TarabLink; external channel-voice → `sendHostedMIDI` |
| Mac | tarablink queue | TarabLink + LinkIngest | Frame decode + diff → `AudioEngine.touch*` |
| Mac | Audio (real-time) | source render blocks | Pull decimated samples from the kernels |
| Mac | jt worker pool | BowEngine | The async modal-jawari post-pass |
| Mac | Main | SwiftUI | UI rendering — slider drags push to AudioEngine via `didSet` / the stores; the Scope model polls `scopeSnapshot()` at 30 Hz |

The audio callback pulls from the `BowEngine` kernel (which runs its own async jawari worker pool). Structural edits build a fresh engine off-main (debounced, generation-checked) and swap it lock-free; the runtime taraf axes (purity/decay/tone) are pushed and chunk-rate smoothed inside the engine. The control path (`MIDIInput` → `sendHostedMIDI` → `routeSarangiModelMIDI` → `BowControlMapper`) is control-rate and does no heavy work on the audio thread.

**Dependency injection.** iPad — managers are `@StateObject` in `ContentView` and wired in `onAppear` (`noteManager.motionSource = motion`, `noteManager.midiEngine = midi`, `midi.start()`). Mac — `AppController` owns audio + midi + midiIn and wires them in `init` (`midiIn.audioEngine = audio`); its `@Published` setters push directly to `audio` via `didSet` hooks.

## Polyphony

The Fret Pad is inherently polyphonic: each finger (`touchId`) is one wire identity with its own full-resolution pitch, and the Mac's `BowControlMapper` mounts a fresh gut string per onset on one shared bridge (`bow_live_poly` strings — poly-as-physics). There is no mono/poly toggle and no MPE channel rotation. The iPad's display `SoundingState` (Hz readout + glow) is single-valued and reflects whichever touch updated last; the wire carries every touch regardless. With the glide queue armed (`ctl_glide_on`), overlapping onsets become waypoints of one gliding voice instead of new strings — see [Glide System](glide-system.md).

## Key design decisions

- **No shared state** beyond pad sync and the few acted-on `JOYCON_STATE` fields. If a feature lives on one side, all its state lives on that side.
- **Mac as the sound source.** The iPad is intentionally silent. MPE and per-message SysEx are off the wire; the MIDI vocabulary survives in-process only (auditions, external controllers, the touch/MIDI parity substrate).
- **Self-contained voices.** `SarangiKit` (`Packages/SarangiKit/`) is Tarabdaar's own Swift/C code: `BowEngine` + `CBowKernel` is the String voice with the whole instrument in-kernel; `TanpuraEngine` + `tanpura_kernel.c` is the plucked voice mounted as the Tanpura and the Sitar. No hosted AU, no upstream; `TarafRemovalParityTests` pins the shipped render's SHA-256.
- **One registry.** `Config.swift` holds system constants; every instrument parameter is a `ParamSpec` in `ParamRegistry.swift` (key, group, range, scope, apply strategy) — one source of truth for the Parameters tab, the composite/tilt menus and the generated [Parameters](parameters.md) page. Tilt targets are `MapTarget` (`TiltMapping.swift`); composites live on `AppController.composites`.
- **One scale, one tonic.** `AppController.pitchPad` owns a `PitchScale` of JI ratios, edited on the Fret Pad tab and synced to the iPad; the tarab is a `[StringSpec]` table of scale degrees. See [Scales & Tuning](scales-and-tuning.md).
- **Tilt calibration is Mac-side.** The iPad streams raw attitude at a fixed ±90° scale; the guided arm calibration (Setup tab) and the Joy-Con wrist calibration produce the control axes. See [Sensors](sensors.md).
