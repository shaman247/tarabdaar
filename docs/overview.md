# Overview

Starpad is an expressive electronic music instrument for iPad, loosely inspired by the [Ondes Martenot](https://en.wikipedia.org/wiki/Ondes_Martenot). The player rests the iPad on their inner forearm, plays notes on a touchscreen piano keyboard, and tilts the device to modulate pitch glide speed and volume. It is designed for genres with complex glissandi, such as Indian classical music.

## Design Philosophy

- **Monophonic and expressive**. One voice with rich continuous pitch control, rather than many discrete notes. Every parameter that can vary continuously does.
- **iPad as instrument**. The capacitive touchscreen provides the keyboard. The accelerometer detects strike velocity. The gyroscope senses tilt for expression. No external hardware needed.
- **Glissandi first**. The pitch glide system is the core feature. Two methods (tap glides and drag glides) give the player control over pitch transitions ranging from instant jumps to slow, expressive slides.
- **MIDI-native**. All expression (pitch bend, velocity, aftertouch) is output as standard MPE MIDI, so Starpad can control any synthesizer.

## Current Capabilities

- Two-octave piano keyboard (G3-G5) with realistic layout
- Tap glides: touch successive keys to glide between them, with a waypoint queue for ornaments
- Drag glides: slide a finger across the keyboard for continuous pitch control with scale-tone correction
- Accelerometer-based velocity detection (strike harder = louder)
- Vibrato controlled by finger vertical position on the key
- Tilt-controlled amplitude and glide speed (3 calibrated tilt axes)
- Scale editor with note toggles, just intonation support, configurable keyboard range
- MPE MIDI output over USB (per-note pitch bend isolation via channel rotation)
- Built-in sine wave synthesizer for standalone use
- Pitch graph and pitch velocity graph for visual feedback
- Seven-point device orientation calibration (3 axes, each with positive/negative endpoints)
