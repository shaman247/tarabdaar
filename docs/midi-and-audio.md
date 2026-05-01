# MIDI & Audio

## Built-in Synthesizer (AudioEngine)

The engine is a **modal-synthesis** voice bank. Every "string" — played or sympathetic — is a collection of decaying sinusoidal resonators (one per partial), excited by a generator that can morph from pluck to bow. Modes ring on their own Q after the exciter stops, which is what gives released notes a natural tail and gives sympathetic strings their distinctive "keeps humming after you lift the finger" behavior.

- **Played banks** — fixed pool of `Config.maxPolyVoices` modal banks indexed by channel, activated by touch. Excited by a mix of pluck impulse (optionally passed through a pluck-position comb filter) and attack-ramped low-passed noise (the bow component).
- **Sympathetic banks** — two modal banks per enabled note in `sympatheticScale` (one each at ±`sympatheticDetune` cents). Always alive; driven every sample by the played-audio sum × a per-bank coupling gain derived from the existing interval kernel.

### Resonator: coupled-form complex exponential

Each mode is a 2-state resonator updated per sample:

```
u' = R·cos(ω) · u  −  R·sin(ω) · v  +  drive · inGain
v' = R·sin(ω) · u  +  R·cos(ω) · v
output += v'
```

- `R = exp(−1 / (sampleRate · τ))` — mode decay
- `ω = 2π · f / sampleRate` — mode angular frequency
- `inGain = sin(ω) · g` — input gain; with `g = 1/k^falloff` (RMS-normalized) this makes an impulse produce a clean decaying sinusoid at amplitude `g`
- `R` is clamped to `1 − 2^−20` for single-precision stability at long decays
- Modes with `f_k ≥ 0.45·sampleRate` (high inharmonicity × high k × high pitch) are zeroed at coefficient time so they can't oscillate

Cost per mode: 4 multiplies + 2 adds + 2 state writes. ≈200 modes × 44.1 kHz is well inside the block budget.

### Mode structure per bank

Partial frequencies follow a stiffness-corrected harmonic series:

```
f_k = k · f₀ · √(1 + B · k²)
```

Per-partial decay adds a frequency-dependent tilt so high partials can fade faster than the fundamental (natural string behavior):

```
τ_k = τ₀ / k^α
```

Coefficients `(R·cos(ω), R·sin(ω), inGain)` are recomputed only when f₀, decay, tilt, falloff, or inharmonicity change — never per sample.

### Excitation generator (played banks)

Each played bank's drive signal is the sum of two components:

1. **Pluck impulse**: a short (2–4 samples) ramp written into a delay line on `noteOn`, scaled by velocity.
2. **Pluck-position comb**: `y = x − x[n−P]` where `P = round(pluckPosition · period_samples)`. The classic "where you pluck the string" filter — different P emphasize different partials.
3. **Bow noise**: LCG white noise → one-pole LPF (~800 Hz cutoff) × `bowForce` × attack envelope. The envelope smooths toward `velocity` on `noteOn` with time constant `noteAttack` and toward 0 on `noteOff`.

Short `noteAttack` + low `bowForce` = percussive pluck. Long `noteAttack` + high `bowForce` = sustained bow.

### Sympathetic coupling

Each sympathetic bank is driven by

```
drive[n] = (played_sum[n] · couplingGain[s] + whiteNoise[n] · couplingGain[s] · 0.005) · bowScaling
```

where `couplingGain[s]` is the existing kernel excitation for that bank's pitch relative to the played fundamental, scaled by `sympatheticVolume · symCoupling`. `played_sum[n]` is the pre-gain-normalized sum of played banks' outputs for this frame. The small broadband-noise term ensures off-resonance sym strings still respond when the played spectrum misses their modes.

When a played note is released, `couplingGain` naturally falls to 0 (no base pitch → kernel=0), drive stops, and the sym modes ring out on their own Q — which is the whole point of the modal rewrite.

### Two-pass render

`AVAudioSourceNode` callback at 44100 Hz, per block:

1. Allocate a stack scratch buffer of `frames` doubles via `withUnsafeTemporaryAllocation`.
2. **Pass 1**: render each active played bank into the scratch buffer; check bank lifecycle afterward (move to idle when energy < threshold or 10 s after noteOff).
3. Apply equal-power gain `1/sqrt(voiceCount)` and copy scratch to the real output buffer. (Gain is applied after sym-drive extraction so sym level is invariant to poly count.)
4. **Pass 2**: for each sym bank, silent-bank skip (skip entire inner loop when both `bank.energy()` and `couplingGain` are below threshold — the dominant CPU win). Otherwise run the resonator bank driven by `scratch × couplingGain + tiny noise`, accumulating into the output.
5. Output feeds the reverb unit.

Thread safety: `NSLock` protects bank pools, coefficient arrays, and parameter state. Held for the duration of the render callback. Main-thread setters (`noteOn`, `noteOff`, `setFrequency`, `updateVoiceParams`, `setHarmonicFalloff`, `setStringDecay`, `setSymDecay`, `setDampingTilt`, `setInharmonicity`, `setBowForce`, `setPluckPosition`, `setSymCoupling`, `setReverbMix`, `configureSympatheticVoices`, `setSympatheticDetune`, `setSympatheticTargetAmps`, `sympatheticSnapshot`, `baseVoiceSnapshot`) acquire the same lock.

### Audio Graph

```
[AVAudioSourceNode]  →  [AVAudioUnitReverb (mediumHall)]  →  mainMixerNode
```

The reverb unit is inserted between the synthesis source node and the mixer. Its `wetDryMix` (0–100) is pushed per-tick from the `reverbMix` mappable parameter. Apple's reverb implementation handles the DSP off the audio render thread, so dialing it up doesn't steal cycles from the synthesis path.

### Sympathetic Excitation Kernel

Every 60 Hz glide tick, `NoteManager.updateSympatheticAmps` computes the per-bank coupling gain from the kernel and pushes the full array to the audio engine via `setSympatheticTargetAmps(_:)` (method name retained from the pre-modal era; values are now consumed as drive-scalars into each sym bank's modal resonator input). The formula for one sympathetic bank at `f_sym` driven by the played fundamental `f_base`:

```
excitation(f_base, f_sym, σ, spread, consonance) = max over (r, w_raw, isUnison) in kernel of:
    w = isUnison ? w_raw : pow(w_raw, consonance) · spread
    w · exp( -(log2(f_sym/f_base) - log2(r))² / (2·σ²) )

σ from `sympatheticWidth` (semitones, converted to octaves)
spread from `sympatheticSpread` (linear multiplier on non-unison weights)
consonance from `sympatheticConsonance` (exponent on each non-unison weight)

kernel ratios + base consonance weights:
    unison           1:1   weight 1.0    (always full — never scaled by spread)
    perfect fifth    3:2   weight 0.8
    fourth           4:3   weight 0.5
    octave           2:1   weight 0.6
    major third      5:4   weight 0.3
    major sixth      5:3   weight 0.3
    minor third      6:5   weight 0.2
    major second     9:8   weight 0.15
    …and reciprocals for intervals below base (1:2, 2:3, 3:4, …)
```

The Gaussian at the unison peak gives the "proximity" feel. At the default σ ≈ 2 st, D4 (2 st above C4) gets ~0.5 of the unison peak → "somewhat excited". The kernel peaks at simple ratios give the "harmonic" feel — G4 (ratio 3:2) gets the fifth's full weight 0.8 × `spread`. The max-over-ratios combinator means each voice takes the strongest connection to the base without double-counting.

Pulling `spread` to 0 leaves only the unison Gaussian — excitation becomes purely proximity-based, and voices a fifth away go silent. Pushing `spread` toward 2 doubly emphasizes harmonic relationships so a perfect fifth can ring as strongly as a near-unison.

`excitation` is multiplied by `sympatheticVolume · symCoupling` to produce the per-bank coupling gain. The `symCoupling` mappable parameter lets the player scale the entire sympathetic drive bus without touching the perceptual balance the kernel provides.

The `f_base` value fed into the kernel isn't the raw glide-smoothed frequency — it's already vibrated: `f_base · 2^(sin(vibratoPhase) · depth · intensity / 12)`. That way sympathetic drive pulses with the bow's vibrato, which is the physically correct behavior for real sympathetic strings and is an essential part of the sarangi's "shimmer".

When no played note is sounding, all coupling gains go to 0 — drive stops, but sym modes keep ringing on their own Q until their `symDecay` carries them to silence. That lingering halo is the modal rewrite's main perceptual payoff over the previous always-on-sine model.

### Parameter update cadence

60 Hz main-thread control-rate updates push every modal parameter (`harmonicFalloff`, `stringDecay`, `symDecay`, `dampingTilt`, `inharmonicity`, `bowForce`, `pluckPosition`, `sympatheticDetune`, `symCoupling`, `reverbMix`) plus the per-bank coupling-gain array. Each setter short-circuits when the incoming value is unchanged, so idempotent ticks are cheap. Coefficient recomputation (a few cos/sin/exp calls per bank per mode) happens at parameter-change time, not per sample.

## MIDI Engine (MIDIEngine)

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

At activation, a pitch bend range RPN is sent on the new channel to set ±48 semitones.

### Pitch Bend Calculation

```
baseSemitone = MIDI note number of the original noteOn
currentSemitone = 12 * log2(currentFreq / 440) + 69
vibratoSemitones = sin(phase) * maxDepth * intensity
offset = (currentSemitone - baseSemitone) + vibratoSemitones
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
| Pitch Bend | 0xE0 | Continuous pitch (glide + vibrato) |
| Channel Pressure | 0xD0 | Tilt expression |
| Control Change | 0xB0 | RPN setup, all-notes-off (panic) |

## Connecting to Ableton over USB

1. Connect iPad to Mac via USB cable
2. On Mac: **Audio MIDI Setup** > **Window > Show MIDI Studio** > Enable iPad
3. In Ableton: **Preferences > Link, Tempo & MIDI** > Enable iPad MIDI input (Track on)
4. Set instrument pitch bend range to ±48 semitones
5. Enable MPE on the track (so per-note pitch bend works)

If using Ableton's "Note PB" mode, pitch bends are automatically per-note when MPE is enabled.
