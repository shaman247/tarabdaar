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
        │     │     │                     routes touches)
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

The Joy-Con path is split by platform: `JoyConReport`, the `JoyConTransport` protocol, `JoyConMapper` (button edges, stick calibration) and `JoyConFusion` (attitude) live in TarabdaarCore and are unit-tested; `JoyConInput` (Mac) coordinates the three Mac-only transports (GameController alias, IOHID full mode, Joy-Con 2 BLE GATT).

**The Mac does not use `NoteManager` for iPad input.** `AppController` holds Mac-side state as `@Published` fields; setters push directly to `AudioEngine`. The **tarab tuning** is owned by `SarangiStore` (`TarabdaarMac/SarangiStore.swift`): it holds the editable `InstrumentState` (the sympathetic-string `[StringSpec]` table, the chromatic set, the melody follower), persists it to UserDefaults and into the `.tarabdaar` preset, and routes each edit to `AudioEngine.rebuildSarangi` — a debounced off-main rebuild that pushes the tuning into the String kernel's taraf. The **String physics scalars** are owned by `StringParamStore` (persisted override dict → `AudioEngine.setStringVoiceOverrides` → debounced `BowEngine` rebuild). The String voice is armed unconditionally at startup; the Live tab's Instrument picker selects the played voice (String / Tanpura / Sitar).

**`AppController` is the WIRING layer, not the mechanism.** The logic it used to carry inline lives in `TarabdaarCore` types with plain inputs and outputs, which it owns, feeds and forwards to:

- **`ControlAxisEvaluator`** (`ControlAxisEvaluator.swift`) — the per-axis binding snapshot (rebuilt on every `tiltMapping` edit), the axis → native-units evaluation, the **strike→acceleration blend** with its 30 Hz weight timer (`StrikeBlendWindow`), and the two-lane (wire / local pump) finger registry driving `FingerAccelTracker`. It emits `(target, value)` batches through `onApply`; `AppController.applyControlBatch` drives composites and parameters from them. The axis indices into `ControlAxes.dims` are its statics.
- **`StrumController`** (`StrumController.swift`) — the controller strum: the L-button and accel-trigger holds (threshold, edge detection, the 100 ms cooldown), the strum-set resolution (the chord bar's selection under the Shepard register law, else the Strings tab's configured set), the generation-scoped touch ids and the in-place retune. It plays through a `NoteSink` of closures over the shared `PitchPadEngine`.
- **`JoyConDisplayRelay` / `VolumeMeterRelay`** (`LinkRelays.swift`) — the JOYCON_STATE frame assembly (drawn axes + the four acted-on fields) and the change-gated 60 Hz volume readout, both taking the send as a closure so neither needs `TarabLink` itself.
- **`DebouncedParamFlush`** (`DebouncedParamFlush.swift`) — the rebuild funnel behind every off-main parameter path: last value per key, one debounced main-thread flush, landing as ONE batch on the physics store (no second debounce).
- **`EngineCrossfader`** (`EngineCrossfader.swift`) — the engine swap both voice sources share: the published engine, the outgoing one crossfading out (equal-power, 300 ms) while its ring decays, swapped-out engines retained past any in-flight buffer. The sources keep only their own extras (render telemetry; the taraf tap and output meter).
- **`Debouncer`** (`Debouncer.swift`) — the one trailing-edge debounce behind every settle-then-act path: the physics push (60 ms), the tarab rebuild (50 ms) and save (400 ms), the tanpura table build (750 ms).

`applyParamToVoice` (with its `ctl_*` interceptions) and `applyComposite` stay on `AppController` — they are the routing point where those collaborators, `AudioEngine` and `StringParamStore` meet.

**The iPad has no `AudioEngine`.** Sound comes only from the Mac.

**Almost no state syncs across devices.** Editing the tarab or the physics on the Mac ships nothing to the iPad. The exceptions are the one-way **pad-sync TLP events** — the playing scale and the Fret Pad layout ([MIDI & Audio — Scale sync](midi-and-audio.md#scale-sync-mac--ipad)) — plus the acted-on `JOYCON_STATE` fields (`connected`, `fieldWarp`, `octave`) and the iPad's chord selection riding the state frame. Everything else is performance state on the wire.

## iPad pipeline

The playing surface is the **Fret Pad** — see [Fret Pad](fret-pad.md). `PitchPadEngine` writes touches into `OutboundPlayState` and is the shared scale/tonic model. `NoteManager` is the 60 Hz tilt sampler and nothing else.

1. **Touch → ratio.** `TouchOverlayView` captures multitouch and reports per-finger `touchBegan` / `touchMoved` / `touchEnded` with normalized x/y. `FretPadSurfaceIOS` maps each to a point in the pad's logical area and resolves the fret field, onset snap and drag assist to a ratio.
2. **Per-touch state (`PitchPadEngine`).** `noteOn(touchId:ratio:)` writes the touch at full-resolution fractional-MIDI pitch (`tonicFractionalMidi + 12·log2(ratio)`, plus the onset-captured octave shift) — no channel, no note pinning, no bend split. `glide(touchId:ratio:)` updates the pitch (change-gated); the Mac ramps to each update within one render block. `noteOff(touchId:)` removes the touch — its absence from the next frame IS the note-off.
3. **Tilt and strike (60 Hz).** `NoteManager`'s tick writes the raw tilt into the same `OutboundPlayState`; `MotionManager` supplies the strike envelope and the per-touch strike velocity, so everything rides each frame atomically.
4. **Wire output (`TarabLink`).** A 120 Hz `DispatchSourceTimer` on its own `userInteractive` serial queue snapshots the dirty state into one `PERF_STATE` frame per tick (250 ms heartbeat when idle) and sends it via `MIDIEngine.sendSysExToLink` — the USB session wired-first, BLE-MIDI otherwise. UI stalls cannot delay the wire.

## Mac pipeline

1. **Link input.** `MIDIInput` opens a CoreMIDI input port and connects to every visible source on launch and hot-plug. Inbound SysEx is reassembled and handed to `TarabLink`; `LinkIngest` diffs each `PERF_STATE` frame — removals → onsets/retriggers → glides, drone-mask edges, chord-selection edges, change-gated tilt — into `AudioEngine.touchOn/touchGlide/touchOff` (touch-id keyed, full-resolution pitch), `setDronePressed` and `AppController.strumChord`, on the link queue. Link drop or 1.5 s staleness runs the kill path (`touchesAllOff`). This is the ONLY way a note reaches the voice: there is no MIDI note path, and channel-voice bytes on the port are skipped.
2. **AudioEngine.** The signal graph:

```
TLP in ──► LinkIngest ──► AudioEngine.touch* ──► GlideSequencer ──► StringVoiceSource ──► symGain ──► mainMixerNode ──► output
                                                                     (BowEngine + CBowKernel, 96 → 48 kHz)
                                              plucked voices ──► TanpuraVoiceSource(s) ──┘ (+ inject ring → String taraf)
```

`StringVoiceSource` (`Packages/TarabdaarCore/.../StringVoiceSource.swift`) is an `AVAudioSourceNode` at 48 kHz wrapping `SarangiKit.BowEngine`. The kernel is the **complete** instrument — played strings, the modal-jawari taraf, the formula body, radiation and room — so its node connects directly to `symGain → mainMixerNode`; there is no master filter/reverb bus (the [FX rack](fx.md) lives inside `BowEngine`). The plucked voices are `TanpuraVoiceSource` nodes beside it, and their output also charges the String kernel's sympathetic web through its inject ring. Its `.live` knobs go through ONE plumbing table (`StringVoiceSource.setControl`: per-key clamp, a cached value and the `BowEngine` push, plus the knob's NEUTRAL — `setEngine` re-applies only the knobs that differ from neutral, so a fresh engine stays byte-null); `AudioEngine.setStringControlParam` is a lookup into it. Structural tarab/tonic changes flow through `AudioEngine.rebuildSarangi`: the engine is rebuilt off-main (tables + kernel init + jt worker-pool spawn), generation-checked, and swapped lock-free under a crossfade; the physics scalars ride `stringVoiceOverrides`. See [Sarangi](sarangi.md).

3. **Startup.** `AppController` arms the String voice, seeds `StringParamStore` with the physics scalars of the one resting-value store, pushes the tarab tuning via `rebuildSarangi`, restores the last preset state (presets are one `TarabdaarPreset` document — see [Sound Design](sound-design.md)), and sets the Mac pads' flat expression level to 32. Live edits (Parameters / Strings / Controls / FX tabs) reach `AudioEngine` through the one apply path, `AppController.applyParamToVoice`, and the store `didSet` hooks.

## Threading model

| Side | Thread | Component | Responsibility |
|------|--------|-----------|----------------|
| iPad | Main | PitchPadEngine | touch → ratio → `OutboundPlayState` writes (O(1) locked) |
| iPad | Main | NoteManager (Timer) | 60 Hz tilt sampling → `OutboundPlayState` |
| iPad | tarablink queue | TarabLink (DispatchSourceTimer) | 120 Hz paced sender — state frames onto the wire |
| iPad | Main | SwiftUI | UI rendering (~15 Hz, throttled) |
| Mac | CoreMIDI | MIDIInput | SysEx reassembly → TarabLink (nothing else) |
| Mac | tarablink queue | TarabLink + LinkIngest | Frame decode + diff → `AudioEngine.touch*` |
| Mac | Audio (real-time) | source render blocks | Pull decimated samples from the kernels |
| Mac | jt worker pool | BowEngine | The async modal-jawari post-pass |
| Mac | Main | SwiftUI | UI rendering — slider drags push to AudioEngine via `didSet` / the stores; the Scope model polls `scopeSnapshot()` at 30 Hz |

Every touch entry point of `AudioEngine` (`touchOn`/`touchExpr`/`touchGlide`/`touchOff`, the scope and the volume readout) speaks `PlayedVoice` — the String source and the two plucked mounts each conform, so the paths never branch on the instrument; a release reaches every voice, so a note begun before an instrument switch still lets go. The audio callback pulls from the `BowEngine` kernel (which runs its own async jawari worker pool). Structural edits build a fresh engine off-main (debounced, generation-checked) and swap it lock-free; the runtime taraf axes (purity/decay/tone) are pushed and chunk-rate smoothed inside the engine. The `.live` apply path (`AppController.applyParamToVoice` → `StringVoiceSource.setControl` / `setFXParam`) is entered from the link queue (tilt bindings), the main thread (sliders, composites, preset loads, drone toggles) and the evaluator's timers at once; the source's control and FX caches sit under one lock, and engine pushes read from a snapshot taken inside it (`ControlCacheConcurrencyTests`). The control path (`MIDIInput` → `TarabLink` → `LinkIngest` → `AudioEngine.touch*` → `BowControlMapper`) is control-rate and does no heavy work on the audio thread.

**Dependency injection.** iPad — managers are `@StateObject` in `ContentView` and wired in `onAppear` (`noteManager.motionSource = motion`, `noteManager.playState = playState`, `midi.start()`). Mac — `AppController` owns audio + midi + midiIn and wires them in `init`; its `@Published` setters push directly to `audio` via `didSet` hooks.

## Polyphony

The Fret Pad is inherently polyphonic: each finger (`touchId`) is one wire identity with its own full-resolution pitch, and the Mac's `BowControlMapper` mounts a fresh gut string per onset on one shared bridge (`bow_live_poly` strings — poly-as-physics). There is no mono/poly toggle. The iPad's display `SoundingState` (Hz readout + glow) is single-valued and reflects whichever touch updated last; the wire carries every touch regardless. With the glide queue armed (`ctl_glide_on`), overlapping onsets become waypoints of one gliding voice instead of new strings — see [Glide System](glide-system.md).

## Key design decisions

- **No shared state** beyond pad sync and the few acted-on `JOYCON_STATE` fields. If a feature lives on one side, all its state lives on that side.
- **Mac as the sound source.** The iPad is intentionally silent, and nothing but a TLP frame makes the Mac play — there is no MIDI note vocabulary on either side.
- **Self-contained voices.** `SarangiKit` (`Packages/SarangiKit/`) is Tarabdaar's own Swift/C code: `BowEngine` + `CBowKernel` is the String voice with the whole instrument in-kernel; `TanpuraEngine` + `tanpura_kernel.c` is the plucked voice mounted as the Tanpura and the Sitar. No hosted AU, no upstream; `TarafRemovalParityTests` pins the shipped render's SHA-256.
- **One registry.** `Config.swift` holds system constants; every instrument parameter is a `ParamSpec` in `ParamRegistry.swift` (key, group, range, scope, apply strategy) — one source of truth for the Parameters tab, the composite/tilt menus and the generated [Parameters](parameters.md) page. Tilt targets are `MapTarget` (`TiltMapping.swift`); composites live on `AppController.composites`.
- **One scale, one tonic.** `Tuning` (one instance, shared by both Mac pad engines; every follower hangs off `tuning.didChange` with its own debounce) owns a `PitchScale` of JI ratios, edited on the Fret Pad tab and synced to the iPad; the tarab is a `[StringSpec]` table of scale degrees. See [Scales & Tuning](scales-and-tuning.md).
- **Tilt calibration is Mac-side.** The iPad streams raw attitude at a fixed ±90° scale; the guided arm calibration (Setup tab) and the Joy-Con wrist calibration produce the control axes. See [Sensors](sensors.md).
