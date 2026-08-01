# Starpad - Claude Development Guide

## Documentation

The `docs/` directory is the detailed reference. **Read the relevant page before changing the code it describes** — the pages below carry the measurements, traps and rationale that this file only summarises.

The Markdown files are the SOURCE. A browsable HTML site is generated into **`docs/html/`** by `tools/gen_docs_html.py` on every `tools/build-mac.sh` run (open `docs/html/index.html`). **Never edit `docs/html/*` by hand** — edit the Markdown. The generator runs AFTER the `paramdoc` step so the auto-generated `parameters.md` is included.

- [Overview](docs/overview.md) — what Starpad is, design philosophy
- [Playing Guide](docs/playing-guide.md) — how to play the instrument
- [Architecture](docs/architecture.md) — module responsibilities, data flow
- [Glide System](docs/glide-system.md) — pitch glide mechanics
- [MIDI & Audio](docs/midi-and-audio.md) — MPE output, MIDI routing, the audio graph, the SysEx pad sync
- [Sound Design](docs/sound-design.md) — the String voice, taraf, rebuild cost, in-place parameters, zipper
- [Sensors](docs/sensors.md) — accelerometer velocity, gyroscope tilt, calibration
- [Scales & Tuning](docs/scales-and-tuning.md) — scale editor, just intonation, custom scales
- [Config Reference](docs/config-reference.md) — every tunable parameter with guidance
- [UI Layout](docs/ui-layout.md) — screen layout, keyboard geometry, graphs
- [Simulator & Audition Loop](docs/simulator.md) — JSON score format + the headless audition pipeline
- [Sarangi](docs/sarangi.md) — the played voice: SarangiKit, the kernel, the tarab bank
- [Fret Pad](docs/fret-pad.md) — the sole playing surface: fret field, snapping, drag assist, legato, drones
- [FX](docs/fx.md) — the four-insert FX rack (2026-08-01): graphic EQ + Bigverb/Room reverb at voice→taraf, voice, taraf, global; the kernel hooks and bit-exactness contract
- [Parameters](docs/parameters.md) — **AUTO-GENERATED, never edit by hand.** Rendered by `paramdoc` from the live `ParamRegistry` / `CompositeParam` definitions on every build. To change the doc, change the definitions.
- [Packaging](docs/packaging.md) — notarization, App Store / TestFlight, entitlements

## What the app is now

**A single-voice instrument with one playing surface.** The sarangi **String voice** (`SarangiKit.BowEngine` + the `CBowKernel` C friction kernel) is the ONLY voice, and the **Fret Pad** is the only playing surface. Mac tabs: **Live ⌘1 · Tarab ⌘2 · Fret Pad ⌘3 · Controls ⌘4 · Parameters ⌘5 · FX ⌘6 · Setup ⌘7**. (The FX tab, 2026-08-01, is a NEW four-insert rack inside `BowEngine` — see [docs/fx.md](docs/fx.md); it is unrelated to the FX tab deleted 2026-07-24 with the coupled network, which must stay dead.)

**Deleted — do not revive, do not "restore" on the assumption it was an accident.** Four rounds of deliberate deletion (2026-07-23 simplification, 2026-07-24 SWAM strip, 2026-07-24 parameter unification + remnant audit, 2026-07-24 taraf simplification) removed:

- **Tabs:** Tanpura, Sitar, Harmonics, Simulator, Chord Pad, String Pad, Pitch Pad, FX, Sarangi.
- **Packages/voices:** the whole `StarpadDSP` package (tanpura + sitar), the SWAM / hosted-AU host and base-voice selection (`BaseVoice`/`SwamInstrument`/`SoundPreset`), the sitar base voice, the `chordPad`/`stringPad` engines.
- **The coupled bridge–body network**: `SarangiProcessorAU`, `SarangiEngine`, `ResonatorBank`/`CombString`/`BodyAdmittance`, the FX rack + 25 network params (`SarangiParams`, `ParamSpec`, `VoiceFXParams`, `VoiceEQBand`), body/viola EQ, spectrum rings, master reverb/filter, `MappableMacParam` CC mappings. Kept *vendored* in SarangiKit for a while after Starpad stopped instantiating them; deleted outright on 2026-07-24 with the upstream link (below).
- **The linear sympathetic taraf web** (2026-07-24): the comb-string web on the passive wave junction and the open gut pair — the whole `bow_taraf_*` / `bow_open_*` parameter group (14 knobs), the web + open-string blocks in `BowTables.buildOpenString`, `BowEngine.setJawGain` and its `AudioEngine`/`StringVoiceSource` plumbing. It was a cheap approximation (comb + a flat-bridge buzz term) of what the **modal-jawari block** (`bow_jt_*`) models properly, and silencing it sounded better — so `bow_jt_*` is now the instrument's entire sympathetic response, still tuned from the Tarab tab. The kernel's web machinery is still compiled but runs at `nv = 0`. Guard: `TarafRemovalParityTests` pins a SHA-256 of the shipped render against the pre-removal build's web-silenced output (they match sample for sample).
- **The free-pitch tarab + the fitted string table** (2026-07-25, the scale centralization): per-string `ratio`/`freq`/Hz inputs, the `exactRatio` bit-exact load path, the seeded detune chorus (`SeededGaussian`), the fitted `sarangi_pilu_strings.json` artifact and with it **the string-table law**, plus `InstrumentState`'s `ragaId`/`ragaName`/`intervals` fields. Strings are `(degree, octave)` into the centralized scale now; the persisted document was migrated in place; the parity hash was deliberately re-blessed (settle pre-roll 4 → 5 blocks for the resulting exact-unison chime).
- **The chromatic taraf row + the choir grouping** (2026-07-25): the 15 fixed JI-chromatic strings (gain 0.40 — below the jawari selection's `bow_jt_gmin`, so they never sounded; `TarafRemovalParityTests` passes unchanged) and the whole `StringGroup` choir model — `RagaTuning.chromaticRatios`, the group-tagged builders (`buildChoirs`/`buildGroupedSpecs`, now flat `buildBank`/`buildSpecs`), `InstrumentState.resolvedGroups`, `SarangiStore.setGroupEnabled` (now `setAllEnabled`) and the Tarab tab's per-choir sections (one flat table now). The fitted artifact kept its remaining 24 rows byte-identical; the persisted document was migrated in place, and a stray `group` key (like the `weight` key retired the same day when it folded into `gain`) decodes away ignored.
- **Dead document fields and their plumbing** (2026-07-24, with the taraf simplification): `StringSpec.bright` + `StringSpec.raga` (two Tarab-tab toggles the String voice never read — the raga/chrom class is now DERIVED from the choir), `InstrumentState.fir` + `.fx`, `BowTuning.init(tonic:resolved:canonicalLayout:)`, `SarangiStore`'s whole FX-rack API + `ParamDescriptor` bindings + the `sarangi.<paramId>` / `sarangi.fx.*` audition routes, and `AudioEngine`'s three `applySarangi*` no-op stubs (`rebuildSarangi` now takes just `strings` + `tonic`). All of it drove the deleted coupled network. **The persist key was deliberately NOT bumped** — a bump discards the user's tarab edits, and the retired keys simply decode away.
- **Geometry/stores:** `StringPadGeometry`, `ChordPadGeometry`, `StringArrangementStore`, `StringArrangementSysEx` + its sync store, the iOS `ScaleEditorView`, `StringParamsView`/`SarangiEditorView`'s editor, the iOS `CurveEditorView`. Symbols the Fret Pad still needs (`scaleDegrees`, `scaleLabel`, `octaveMarked`, `Temperament`, `ScalePreset`) live in **`ScaleDegrees.swift`**.
- **The fixed sargam naming table** (2026-07-25): `sargamNames` / `sargamName(semitonesAboveTonic:)` / `sargamName(forRatio:)` — a 12-tone chromatic vocabulary that named the frets, the drone buttons and the Tarab tab's degree dropdown while the scale editor named the SAME pitches its own way (the default scale's `2-` drew as `r`). Deleted — the **default scale** then took the sargam names itself (`S r R g G m M P d D n N`, in both `StarpadMac/Default.json` and the `PitchScale.defaultJI` fallback — **keep the two in step**), so the pad still reads sargam, but as the scale's own editable labels. See the naming rule below.

**Kept, headless:** `IPadSimulator` + `AuditionRunner` — the audition inbox→WAV pipeline still runs, it just has no on-screen tab. **Kept as a model:** `AppController.pitchPad` survives as the shared scale/tonic model even though its surface is gone; the Fret Pad tab hosts the scale selector + list editor (`ScaleListEditor` in `FretPadView.swift`).

**Trap:** `PadLayout`'s non-fret enum cases must stay — the sync blob encodes the layout by raw value, so removing them breaks blob compatibility.

## Key Conventions

- **Two devices, one cable, almost no shared state.** iPad is a MIDI controller (USB-MIDI only — no Bonjour/Wi-Fi); it owns glide/vibrato params, calibration, and MPE emission. Mac owns the String physics, the tarab tuning, and the composite/tilt bindings. **Do not introduce shared params** beyond the one exception below — if a feature lives on one side, all its state lives on that side.
- **The one exception: pad sync, Mac → iPad over SysEx, one-way.** Exactly two messages: `F0 7D 01` (scale + tonic incl. its fractional cents + margin + layout, blob v4) and `F0 7D 03` (fret arrangement). **These are the ONLY SysEx and the ONLY cross-device state in the app** — subtype `0x02` is retired, and the `0x04` tilt-mapping message was deleted when the iPad stopped evaluating mappings. The iPad has no scale editor and its tonic is read-only. Mechanics: [docs/midi-and-audio.md](docs/midi-and-audio.md).
- **The iPad evaluates no parameter mappings.** It streams only the raw tilt report (`TiltAxisWire`, CCs 16/17/18); the Mac evaluates its own `tiltMapping` (`AppController.applyTiltAxis`). `NoteManager` on the iPad is now just the 60 Hz tilt sampler — its keyboard/glide/voice MIDI paths stay idle, alive only for audition `noteOn`/`glide` scripts.
- **StarpadCore package** (`Packages/StarpadCore/`) — cross-platform building blocks (`Scale`, `MIDIEngine`, `MIDIInput`, `Config`, `MotionSource`, `CalibrationData`, `PitchPadEngine`, `NoteManager`, Mac-only `AudioEngine`). `PitchPadEngine` has two inits: `init(audio:)` (Mac, in-process) and `init(midi:)` (iPad, real USB-MPE). **Anything used outside the package must be `public`** — including `init`.
- **SarangiKit package** (`Packages/SarangiKit/`) — the played voice: the C friction kernel, its table builders, the control mapper and the tarab document. **It is Starpad's own code now.** It began as a vendored copy of `~/Desktop/sarangi` and was kept synced with it, which is why it carried a coupled bridge–body network, an additive violin voice, a byte-parity MONO kernel and ~3.4 MB of offline goldens that Starpad never played. **The upstream link was cut 2026-07-24** and all of it was deleted; there is no re-vendor procedure, no divergence table and no "fix it upstream" rule any more — **change the DSP here**. What survives is exactly the shipping signal path, and `TarafRemovalParityTests` pins its SHA-256, so an accidental edit to the kernel or the table builders fails loudly.
- **`CBowKernel` builds with `-O3` ALWAYS.** The offline reference dylib is `cc -O3`; a debug kernel runs far below realtime.
- **PARAMETER MODEL — read [docs/parameters.md](docs/parameters.md) before touching any parameter.** There is **ONE registry**: `ParamRegistry` (`Packages/StarpadCore/.../ParamRegistry.swift`), a flat list of `ParamSpec` covering every knob. **Adding a parameter = ONE `ParamSpec` entry** — it appears in the Parameters tab, the composite menu, the tilt menu and the docs automatically. The ONE apply path is `AppController.applyParamToVoice(key, value)` (a non-nil return means the caller must funnel it through the debounced `queueRebuildValues` flush). Tilt targets are `MapTarget` — `.composite(slot:)` or `.param(key:)`, endpoints in native units. Apply strategy (`live` / `rebuild` / `hybrid`) is a routing hint, not a user-facing category: no UI labels it. Behaviour, measurements and traps: [docs/sound-design.md](docs/sound-design.md).
- **ONE centralized scale + ONE tonic (2026-07-25).** `AppController.pitchPad` owns the scale and the tonic (set **in Hz** on the Fret Pad tab — the app's ONLY Hz input; `tonicMidi` + `tonicCents` internally); the Fret Pad frets, the tarab strings and the drones are all scale-degree references resolved against it. Tarab strings are `(degree, octave)` — **no per-string ratio or Hz exists anywhere** (the one non-degree pitch is the Tarab tab's **melody follower**, a special sympathetic string that live-retunes kernel-side to the highest played note — `InstrumentState.follower`, default off; see [docs/sarangi.md](docs/sarangi.md)), and **following the scale is unconditional** (the "Follow the Pitch Pad scale" toggle + `autoSyncToScale`/`manualEdits` were removed 2026-07-25): the row LAYOUT regenerates when the scale's degree COUNT changes or via the Tarab tab's "Regenerate from scale"; hand edits otherwise stand. **The tarab pool is pitch-sorted with ONE string per pitch (2026-07-26)** — `InstrumentState.normalizeStrings` enforces it on every entry path (doubling-era documents fold in place, drone mappings follow the surviving twin), the UI rejects duplicate-pitch edits, and the historic Sa/Pa doubling rows folded into their strongest twins (`TarafRemovalParityTests` deliberately re-blessed). **The string-table law is RETIRED** — the fitted Pilu table's per-string detunes can't be expressed as scale degrees, the artifact was deleted, and `TarafRemovalParityTests` was re-blessed on the generated JI-grid default (git history has the fitted artifact + measurements).
- **ONE naming: the scale labels its own pitches (2026-07-25).** Wherever a pitch is named — Fret Pad frets, drone buttons (Mac + iPad), the Tarab tab's degree dropdown and its drone mapping — the text is the scale point's own `label` (`PitchPoint.displayLabel`, blank → the ratio), never a second vocabulary. Two helpers in `ScaleDegrees.swift`: `scaleLabel(degree:octave:degrees:)` when the degree index is known (exact — prefer it), `scaleLabel(forRatio:degrees:)` when only a ratio survives (nearest degree in any octave). Octave repeats add `'`/`,` (`octaveMarked`). Rename a degree in the scale editor and it renames everywhere. Concert note names (`Scale.noteName` / `NoteName.name(forMIDI:)`) are a different axis — they label absolute Hz in the tuning readouts, not scale degrees. Guard: `ScaleLabelTests`.
- **Autonomous audition.** `AuditionRunner` watches `<repo>/auditions/inbox/` for `*.json` scores; WAVs land in `<repo>/auditions/outputs/` with a `.done` (or `.error`) marker. **Writers must use atomic writes** (`*.json.tmp` → `mv`) — the runner waits for size-stable files but a non-atomic writer still races. `tools/audition_iterate.py` does this; **bash heredocs do NOT**. Score format: [docs/simulator.md](docs/simulator.md).
- **`InputDimension`** (was `Dimension`) — renamed to avoid clashing with `Foundation.Dimension` once both modules are visible.
- **Where ranges live.** `Config.swift` holds system-level constants only. Every instrument parameter's range lives in **`ParamRegistry.swift`**; tilt-binding endpoint ranges come from the target (`MapTarget.defaultRange` in `TiltMapping.swift`).
- **`Scale.swift`** owns 12-TET frequency / note-name helpers. **Always use `scale.frequency(for:)`, never hardcode 12-TET formulas.** The playing scale is a `PitchScale` (JI ratios); the tarab table stores scale-degree references into it (`InstrumentState.scaleRatios` mirrors the pad's degree ratios via the scale push).
- **Log-frequency space.** All pitch interpolation uses `log2(freq)` — perceptually linear movement.
- **MPE per note.** Each note activation on iPad gets a fresh MIDI channel (round-robin 1-15). Mono/Poly is iPad-side channel allocation only; the Mac has no poly toggle — the voice's polyphony is `bow_live_poly` gut strings on one shared bridge (poly-as-physics).
- **Hot path:** use `cachedParamValue(for:voiceIndex:)` — **never** the dictionary-based lookup.
- **60 Hz glide loop** (iPad, main thread) drives all continuous updates. The played pitch tracks the finger directly via `pitchAt`; the Mac sends the bend immediately from `glide` (no loop). The automatic vibrato LFO was removed — **vibrato is a playing technique** (move the finger).
- **Audio thread** (Mac) runs the `StringVoiceSource` render block, pulling from the kernel under the source's own lock. It **never** does MIDI or state logic.
- **SwiftUI updates are throttled** to ~15 Hz via manual `objectWillChange.send()` on the iPad's `NoteManager`.

## Building

From the repo root:

```bash
./tools/build-mac.sh
```

Wraps the macOS build, filters non-actionable noise, exits non-zero on errors, and regenerates `docs/parameters.md` + `docs/html/`. Wire it into a pre-commit hook or CI step so a refactor that breaks `StarpadMac` while iOS still compiles is caught before merge.

Tests: `cd Packages/StarpadCore && swift test`. The parameter-system regression guards live there (`ParamUnificationTests`, `RebuildCostTests`, `ParamLivenessTests`, `LiveParamPushTests`, `ZipperTests`, `RealtimePerformanceTests`, `PresetCodingTests`, `TarafRemovalParityTests`), alongside the scale guards (`TarabRatioTests`, `DroneStringTests`, `ScaleLabelTests`).

The iOS target builds with the standard `xcodebuild -scheme Starpad` invocation against an iPad simulator destination; `-showdestinations` lists the available names, which vary by machine.

**A physical device is required** for accelerometer, gyroscope, and MIDI output.

Adding a new source file to the Xcode project: see the `add-xcode-file` skill (files under `Packages/` need no pbxproj edit; target files need four).

## Sound Design Iteration

The voice's physics were fitted offline (in the since-decoupled `~/Desktop/sarangi` project) and ship as `bowed_string.json`. Starpad does not re-fit; it edits the fitted values. (The exact fitted Pilu STRING table is gone — since the 2026-07-25 scale centralization the tarab is generated from the centralized scale.) To change the sound:

- **Parameters tab (⌘5)** — every parameter in 11 filterable groups (7 voice + the 4 FX points), each row with a mapping button. `rebuild` rows persist as an override dict and re-apply through a crossfaded off-main rebuild; `live`/`hybrid` rows apply instantly. "Default (Sarangi Live)" / "Reset all" clears everything; double-click a row label resets one.
- **Tarab tab (⌘2)** — the sympathetic strings and their tuning. Since the taraf simplification these rows feed the modal-jawari block only, so a row its selection does not pick up is inert.
- **Controls tab (⌘4)** — tilt bindings and composite macros, driving any parameter live.
- **FX tab (⌘6)** — the four-insert FX rack (graphic EQ + Bigverb/Room reverb at voice→taraf, voice, taraf, global; all `.live` registry params `fx_<point>_*`, off by default = byte-null). See [docs/fx.md](docs/fx.md).
- Audition path for scripted sweeps: `param.<key>` or `string.<key>`.

**LEVELS — the non-obvious part:** calibration lives inside the fitted preset (`bow_live_trim` / `bow_rev_*`), and the Mac pads hold a flat **CC11 = 32** — the fitted expression median. CC11 is a real ±16 dB loudness axis here, not a trim. Loud peaks are backstopped inside the kernel.

**Presets** save/load as ONE `StarpadPreset` document (2026-07-30) covering the whole rig — sarangi doc + physics + param values + composites + tilt bindings. **No file panels**: Save preset… asks only for a name, the preset lands in the app-managed library (`PresetLibrary`, `Application Support/Starpad/Presets/`, one `.starpad` file each) and appears in the Load-preset menu automatically, under the factory default (a full-rig reset). Every section is optional, so split-era/legacy files dropped into the folder still load, applying only what they carry. Details and traps: [docs/sound-design.md](docs/sound-design.md).

**To make a change the shipping default,** edit `bowed_string.json` in `Packages/SarangiKit/Sources/SarangiKit/Resources/` (the physics) or the builders that generate the tarab (`RagaTuning.buildSpecs` for the layout), and re-run the tests — `TarafRemovalParityTests` will fail, which is the signal to re-bless its hash deliberately rather than by accident.

## Updating Documentation

When you change code, update the matching `docs/` page in the same commit — the page titles in the index above map onto the subsystems directly. `docs/parameters.md` and `docs/html/` are generated; never hand-edit them.
