# Sound Design

Starpad's synth is a modal-synthesis voice bank: every "string" — played or sympathetic — is a bank of decaying sinusoidal resonators (one per partial), excited by a generator that can morph from pluck to bow. Mode decay is independent of the excitation envelope, so notes ring out naturally after release and sympathetic strings continue to hum long after the played string has decayed — the core perceptual hallmark of sarangi/sitar.

## Architecture

```
[touch]  ─► played ModalBank[ch] ──┐
                                   ├─► played_sum ──► [reverb: mediumHall] ──► out
    [kernel · played_sum          │
     + small noise · coupling] ──┬┴─► sym ModalBank[s] ──┐
                                 │                        ├─► [reverb] ──► out
                                 └── rings post-release ──┘
```

Rendering happens in two passes inside the audio callback:

1. Played banks sum into a scratch buffer.
2. Sympathetic banks are driven by that scratch buffer × per-bank coupling gain.

A silent-bank skip bypasses the inner mode loop for any sym bank whose ringing energy and current drive are both below threshold — the single biggest CPU saving in typical play, because most sympathetic strings are dark most of the time.

## DSP primitive: coupled-form complex resonator

Each mode is a 2-state resonator:

```
u' = R·cos(ω) · u  −  R·sin(ω) · v  +  drive · inGain
v' = R·sin(ω) · u  +  R·cos(ω) · v
output += v'
```

- `R = exp(−1/(sampleRate · τ))` — per-mode decay, clamped to `1 − 2^−20` for single-precision stability at long decays.
- `ω = 2π · f / sampleRate` — mode angular frequency.
- `inGain = sin(ω) · g` — input gain; driving an impulse produces a clean decaying sinusoid at peak amplitude `g`. The coupled form rejects DC by construction, so bow-noise mean doesn't produce steady-state offset.
- Cost: 4 multiplies + 2 adds + 2 state writes per mode per sample.

## Ingredient reference

### Played string (one per active touch, up to `Config.maxPolyVoices` voices)

Mode structure (6 partials):

| Ingredient | Formula / source | Parameter |
|---|---|---|
| Partial frequencies | `f_k = k · f₀ · √(1 + B·k²)` (stiffness-stretched) | `inharmonicity` (0–0.03) |
| Partial amplitudes | `g_k ∝ 1/k^falloff`, RMS-normalized | `harmonicFalloff` (0–5) |
| Mode decay | `τ_k = τ₀ / k^α`, per-mode R from τ_k | `stringDecay` (0.5–8 s), `dampingTilt` (0–2) |

Excitation generator (per sample):

| Ingredient | What it does | Parameter |
|---|---|---|
| Pluck impulse | Short burst (2–4 samples) at noteOn, scaled by velocity | — (auto on noteOn) |
| Pluck-position comb | `y = x − x[n−P]`, `P = round(pluckPosition · period_samples)` — classic string-pluck comb filter that emphasizes different partials depending on struck position | `pluckPosition` (0–0.5) |
| Bow noise | LCG white noise → one-pole LPF (~800 Hz) × `bowForce` × attack envelope | `bowForce` (0–0.3), `noteAttack` (5–500 ms) |

Attack envelope smooths toward velocity on noteOn, toward 0 on noteOff. Short `noteAttack` + low `bowForce` = percussive pluck. Long `noteAttack` + high `bowForce` = sustained bow.

### Sympathetic strings

Two modal banks per enabled note in `sympatheticScale` (one each at ±`sympatheticDetune` cents), 4 partials each. Always alive. Drive signal per bank:

```
drive[n] = (played_sum[n] · couplingGain[s] + noise[n] · couplingGain[s] · 0.005) · bowScaling
```

where `couplingGain[s] = kernel_excitation(f_played, f_sym) · sympatheticVolume · symCoupling`.

| Ingredient | What it does | Parameter |
|---|---|---|
| Scale-driven bank set | Each enabled MIDI note in `sympatheticScale` → one nominal f₀, spawning ±detune bank pair | (configured via Strings tab of Scale Editor) |
| Excitation kernel | Max over simple-ratio Gaussians (unison/fifth/fourth/octave/thirds/sixth/second). Kernel unchanged from the pre-modal era; repurposed here as drive-scalar. | `sympatheticVolume`, `sympatheticWidth`, `sympatheticSpread`, `sympatheticConsonance`, `symCoupling` |
| Vibrato coupling | f_played fed into kernel is vibrato-modulated, so coupling gains pulse with the bow's inflection | (uses `vibratoDepth` × `vibratoIntensity`) |
| Unison detune pair | Each nominal note → ±cents paired banks, beating to thicken the shimmer | `sympatheticDetune` (0–15 cents) |
| Broadband drive bleed | Tiny `0.005 · couplingGain` noise ensures off-resonance sym modes still respond when played spectrum is narrow | — |
| Mode decay | Same `τ_k = τ₀/k^α` as played, but with a longer τ₀ | `symDecay` (2–20 s), `dampingTilt` |
| Silent-bank skip | Per-block check: if `|state| + |drive|` both below threshold, skip the entire inner mode loop | — |

### Excitation kernel ratios (unchanged)

```
r ∈ {1:1, 3:2, 2:3, 4:3, 3:4, 2:1, 1:2, 5:4, 4:5, 5:3, 3:5, 6:5, 5:6, 9:8, 8:9}
```

Consonance-biased weights: unison 1.0, fifths 0.8, fourths/octaves 0.5–0.6, thirds/sixths 0.2–0.3, seconds 0.15. Kernel σ, non-unison multiplier (`spread`), and weight exponent (`consonance`) are all dimension-mappable — see [Config Reference](config-reference.md#modal-synth).

### Bus

| Ingredient | Parameter |
|---|---|
| Reverb bus | `AVAudioUnitReverb(.mediumHall)` post-mix; `reverbMix` (0–60 %) |

## Suggested starting points

### Sarangi (bowed, long sustain, warm)

| Parameter | Value |
|---|---|
| `noteAttack` | 150 ms |
| `bowForce` | 0.18 |
| `pluckPosition` | 0 (no pluck click) |
| `harmonicFalloff` | 1.8 |
| `stringDecay` | 3.5 s |
| `dampingTilt` | 0.9 |
| `inharmonicity` | 0.001 |
| `symDecay` | 10 s |
| `symCoupling` | 0.7 |
| `sympatheticVolume` | 0.6 |
| `sympatheticWidth` | 2.5 st |
| `sympatheticDetune` | 7 cents |
| `reverbMix` | 40 % |

### Sitar (plucked, inharmonic, jawari buzz)

| Parameter | Value |
|---|---|
| `noteAttack` | 15 ms |
| `bowForce` | 0 |
| `pluckPosition` | 0.22 |
| `harmonicFalloff` | 1.2 |
| `stringDecay` | 5 s |
| `dampingTilt` | 0.4 |
| `inharmonicity` | 0.015 |
| `symDecay` | 14 s |
| `symCoupling` | 0.9 |
| `sympatheticVolume` | 0.8 |
| `sympatheticWidth` | 1.2 st |
| `sympatheticConsonance` | 4 |
| `sympatheticDetune` | 4 cents |
| `reverbMix` | 30 % |

### Plucked dulcimer

| Parameter | Value |
|---|---|
| `noteAttack` | 8 ms |
| `bowForce` | 0 |
| `pluckPosition` | 0.15 |
| `harmonicFalloff` | 2.2 |
| `stringDecay` | 2 s |
| `dampingTilt` | 1.2 |
| `inharmonicity` | 0.003 |
| `symDecay` | 5 s |
| `symCoupling` | 0.4 |
| `sympatheticVolume` | 0.3 |
| `sympatheticDetune` | 10 cents |
| `reverbMix` | 25 % |

### Bowed pad

| Parameter | Value |
|---|---|
| `noteAttack` | 350 ms |
| `bowForce` | 0.25 |
| `pluckPosition` | 0 |
| `harmonicFalloff` | 2.8 |
| `stringDecay` | 6 s |
| `dampingTilt` | 0.3 |
| `inharmonicity` | 0 |
| `symDecay` | 18 s |
| `symCoupling` | 0.6 |
| `sympatheticVolume` | 0.7 |
| `sympatheticWidth` | 3.5 st |
| `sympatheticConsonance` | 0.5 |
| `sympatheticSpread` | 1.5 |
| `reverbMix` | 55 % |

## Next steps

Candidate additions, ordered by estimated impact-per-effort.

### Quick wins

1. **Stereo output** — currently mono. Distribute sym banks across the stereo field by log-frequency. Requires re-plumbing `AVAudioFormat` throughout and moderate render-path work; no per-sample DSP cost.
2. **Bow-pressure → damping tilt** — route `accelPressure` into a per-voice `dampingTilt` offset so hard press = brighter attack, soft touch = gentler. Uses existing dimension infrastructure.
3. **Body-resonance filter** — a fixed 2-pole resonant filter on the main bus centered around 200–400 Hz, emphasizing one "body" band the way an instrument's body cavity does. One biquad on the mono mix.
4. **Pitch drift** — a slow (0.3–0.7 Hz), small (±2 cents) random LFO on played-bank f₀. Imitates micro-pitch drift of an acoustic instrument.

### Production polish

5. **Multi-mode excitation coupling** — instead of only `sin(ω) · g` per-mode input gain, allow a per-mode bow-friction gain curve so the excitation spectrum shapes what the modes actually pick up. More physically accurate bow modeling.
6. **Per-voice independent decay parameter via keyY** — use key-Y dimension for per-voice `stringDecay` offset so high keys can be snappier than low ones automatically.
7. **Alternate reverb presets** — expose the full `AVAudioUnitReverb` preset enum (small room, hall, cathedral, plate, chamber, …) as a selectable field. Discrete UI control, not a mappable dimension.

### Bigger changes

8. **Bi-directional coupling** — currently sym banks absorb energy from played banks but don't feed back. Real sympathetic strings feed a small fraction of their vibration back into the played string via the bridge. Route `sym_sum · k` back into the played banks' drive for a subtle "alive" quality.
9. **Per-mode pan** — for stereo, place each mode at a slightly different pan position so partials smear across the stereo field, giving a hint of body size.
10. **Waveguide bridge model** — a small delay-line model of the bridge that mixes played + sym string vibrations with slight coupling delays. Significantly more physical; moderate DSP cost.

### Deferred / out of scope

- **Sample-based body impulse response** — convolution of the dry signal with a sarangi body IR would get us the most "real" body sound, but requires an IR asset and a convolution engine.
- **External audio plugins (AUv3)** — hosting third-party effects at significant integration cost.
