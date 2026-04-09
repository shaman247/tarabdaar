# Armpad - Claude Development Guide

## Documentation

The `docs/` directory contains comprehensive documentation. **Read the relevant pages before making changes.**

- [Overview](docs/overview.md) - What Armpad is, design philosophy
- [Playing Guide](docs/playing-guide.md) - How to play the instrument
- [Architecture](docs/architecture.md) - System design, module responsibilities, data flow
- [Glide System](docs/glide-system.md) - Pitch glide mechanics (waypoint queue, drag mode, curves)
- [MIDI & Audio](docs/midi-and-audio.md) - MPE output, synthesizer, pitch bend math
- [Sensors](docs/sensors.md) - Accelerometer velocity, gyroscope tilt, calibration
- [Scales & Tuning](docs/scales-and-tuning.md) - Scale editor, just intonation, custom scales
- [Config Reference](docs/config-reference.md) - Every tunable parameter with guidance
- [UI Layout](docs/ui-layout.md) - Screen layout, keyboard geometry, graphs

## Key Conventions

- **Config.swift** holds system-level constants. Dimension-mappable parameter ranges are in **TiltMapping.swift** (`MappableParameter.defaultRange`).
- **Scale.swift** owns frequency calculations and scale state. Always use `scale.frequency(for:)`, never hardcode 12-TET formulas.
- **NoteManager.swift** is the orchestrator. All pitch logic flows through it.
- **Mono/Poly modes**. Up to 6 voices (`Config.maxPolyVoices`). Mono uses channel 0 only.
- **Log-frequency space**. All pitch interpolation uses `log2(freq)` for perceptually linear movement.
- **MPE per note**. Each note activation gets a fresh MIDI channel (round-robin 1-15).
- **Dimension system**. Parameters are driven by configurable dimensions (tilts, pressure, key Y, sliders). Use `cachedParamValue(for:voiceIndex:)` in the hot path — never the dictionary-based lookup.
- **60Hz glide loop** on main thread drives all continuous updates (pitch, vibrato, tilt, MIDI).
- **Audio thread** (AVAudioSourceNode callback) only reads frequency/amplitude; never does MIDI or state logic.
- **SwiftUI updates are throttled** to ~15Hz via manual `objectWillChange.send()`.

## Building

```bash
cd Armpad
xcodebuild -project Armpad.xcodeproj -scheme Armpad \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M3)' \
  -quiet build 2>&1 | grep -E "error:|warning:"
```

The simulator destination name may vary. Check available destinations with:
```bash
xcodebuild -project Armpad.xcodeproj -scheme Armpad -showdestinations 2>&1 | grep "iPad"
```

Physical device required for accelerometer, gyroscope, and MIDI output.

## Adding Files to the Xcode Project

When creating new `.swift` files, you must manually add them to `Armpad.xcodeproj/project.pbxproj`:
1. Add a `PBXBuildFile` entry (A1xxxxxx)
2. Add a `PBXFileReference` entry (A2xxxxxx)
3. Add to the `PBXGroup` children list
4. Add to the `PBXSourcesBuildPhase` files list

Use sequential IDs following the existing pattern (A100000A, A200000A, etc.).

## Updating Documentation

When you modify code, update the corresponding docs/ page. Specifically:
- Changed Config.swift values or dimension-mappable parameters? Update `docs/config-reference.md` and `docs/sensors.md`.
- Changed parameter mapping UI or curve interpolation? Update `docs/ui-layout.md` and `docs/playing-guide.md`.
- Changed glide behavior? Update `docs/glide-system.md`.
- Changed touch handling or UI? Update `docs/ui-layout.md` or `docs/playing-guide.md`.
- Changed MIDI/audio output? Update `docs/midi-and-audio.md`.
- Changed sensor usage? Update `docs/sensors.md`.
- Changed module structure? Update `docs/architecture.md`.
