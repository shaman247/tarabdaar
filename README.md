# Tarabdaar

An expressive electronic music instrument for iPad, loosely inspired by the [Ondes Martenot](https://en.wikipedia.org/wiki/Ondes_Martenot). The player rests the iPad on their inner forearm, plays notes on a touchscreen piano keyboard, and tilts the device to modulate pitch glide speed and volume. Designed for genres with complex glissandi, such as Indian classical music.

Tarabdaar is monophonic with rich continuous pitch control. Two glide methods (tapping successive keys and dragging across the keyboard) let you perform everything from rapid ornaments to slow expressive slides. An accelerometer-based velocity system detects how hard you strike each note. All expression is output as MPE MIDI for controlling any synthesizer.

## Documentation

- [Overview](docs/overview.md) - Design philosophy and capabilities
- [Playing Guide](docs/playing-guide.md) - Setup, calibration, techniques
- [Architecture](docs/architecture.md) - System design and data flow
- [Glide System](docs/glide-system.md) - Pitch glide mechanics in depth
- [MIDI & Audio](docs/midi-and-audio.md) - MPE output and synthesizer
- [Sensors](docs/sensors.md) - Accelerometer velocity, gyroscope tilt, calibration math
- [Scales & Tuning](docs/scales-and-tuning.md) - Scale editor, just intonation, custom scales
- [Config Reference](docs/config-reference.md) - Every tunable parameter
- [UI Layout](docs/ui-layout.md) - Screen layout, keyboard geometry, graphs

## Requirements

- iPad running iPadOS 16+
- Xcode 15+
- Physical device required for accelerometer/gyroscope and MIDI output (simulator lacks these)

## Building

Open `Tarabdaar/Tarabdaar.xcodeproj` in Xcode, select your iPad as the run destination, and build. The app is locked to landscape orientation and targets iPad only.

## MIDI Setup

1. Connect iPad to Mac via USB
2. On Mac: **Audio MIDI Setup** > **Window > Show MIDI Studio** > Enable iPad
3. In your DAW: enable the iPad as a MIDI input
4. Set instrument pitch bend range to ±48 semitones
5. Enable MPE mode on the receiving track
