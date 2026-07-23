# Config Reference

System-level tunable parameters live in `Packages/StarpadCore/Sources/StarpadCore/Config.swift`. iPad dimension-mappable parameter ranges (glide speed, amplitude, MIDI CCs) are defined in `TiltMapping.swift` via `MappableParameter.defaultRange` and configured at runtime in the MAP editor. See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping) for the full parameter table.

The Mac-side **sarangi model** params (22 of them since the v57-only simplification) live in `SarangiKit`'s `ParamSpec.all` (name, range, default, group, structural flag), edited in the Sarangi tab via `SarangiStore`. The sarangi's FX-rack filter / EQ / reverb are **not** `ParamSpec` params — they're the 2-stage **FX rack** (`FXRack` on `InstrumentState`, edited in the FX tab; the model's own room is the `F_*` group). The shared **master-FX** params (now the tanpura/sitar Room) live on `AppController` as `@Published` fields. Per-preset FX/hosted-AU defaults come from `SoundPreset.state()` in `StarpadMac/SoundPreset.swift`. The played voice is the sarangi model fed by the selected base voice (the fitted sarangi source by default; optionally a hosted SWAM AU run dry — the AU has its own parameter space which you configure via its own UI, open via the HostedAUPill in the Mac top bar).

## Keyboard

The legacy keyboard is no longer on the playing path. The playing scale is the **Pitch Pad** scale (a `PitchScale` of JI ratios), edited on the Mac Pitch Pad tab and synced to the iPad. See [Scales and Tuning](scales-and-tuning.md) and [Pitch Pad](pitch-pad.md).

## Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| `velocityDelay` | 200ms | Time to wait after touch for accelerometer spike. Skipped entirely when no parameter uses the Pressure dimension. |

**Tuning**: Lower = faster response but may miss the spike. Higher = more reliable velocity but adds latency.

## Glide

| Parameter | Value | Description |
|-----------|-------|-------------|
| `glideDistanceExponent` | 0.6 | Sublinear distance scaling. 1.0 = linear, 0.5 = sqrt |
| `releaseGracePeriod` | 50ms | Window after all touches lift to connect next tap as glide |
| `glideMidpoint` | 0.6 | Sigmoid midpoint `m`. Lower = faster onset |

**Tuning**:
- `glideDistanceExponent`: Lower = larger intervals complete faster relative to small ones. At 0.6, an octave (12 semitones) takes ~4.4x a single semitone rather than 12x.
- `releaseGracePeriod`: Increase if notes are disconnecting when you intend them to be legato.
- `glideMidpoint`: 0.5 = symmetric. Lower values shift the fast phase earlier (faster onset, gentler landing).
- Glide speed and compression ranges are dimension-mappable (defaults: 20–200 ms/st and 15–40 ms).
- Glide curve steepness (k) is dimension-mappable (default range 3–12).

## Drag Glide

| Parameter | Value | Description |
|-----------|-------|-------------|
| `dragSnapDelay` | 60ms | How long the finger must be still before snapping to a scale tone |

**Tuning**:
- `dragSnapDelay`: Lower = snaps sooner when finger pauses. Higher = more tolerance for brief pauses mid-slide.
- Drag smoothing is dimension-mappable (default range 0.1–0.5). Snap smoothing is 2× the base value, clamped to 1.0.

## MIDI

| Parameter | Value | Description |
|-----------|-------|-------------|
| `midiPitchBendRange` | ±48 semitones | Must match the receiving synth's pitch bend range |

**Tuning**: Must exactly match the receiving instrument. Ableton MPE default is ±48. Other synths may use ±2, ±12, or ±24. Mismatched values cause pitch bend to be scaled incorrectly.

## Audio

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sampleRate` | 44100 Hz | Audio sample rate |
| `frequencySmoothing` | 0.002 | Per-sample smoothing coefficient (~11ms time constant) |
| `attackCoefficient` | 0.05 | Envelope attack speed (~2ms to reach full amplitude) |
| `releaseCoefficient` | 0.9993 | Envelope release speed (~50ms to fade out) |
| `maxAmplitude` | 0.3 | Maximum amplitude at velocity 127 (headroom for clipping) |

**Tuning**:
- `frequencySmoothing`: Lower = smoother glides on audio thread, but more latency. Higher = tighter tracking but potential zipper noise.
- `attackCoefficient`: Higher = snappier attack. Lower = softer onset. Keep below 0.1 to avoid clicks.
- `releaseCoefficient`: Closer to 1.0 = slower release. Must be < 1.0. Voices are removed when envelope < 0.001.
- `maxAmplitude`: Increase for louder output (may clip with amplitude boost). Decrease if distortion occurs.

## Motion

| Parameter | Value | Description |
|-----------|-------|-------------|
| `motionUpdateRate` | 200 Hz | CoreMotion sample rate |
| `accelHistoryLength` | 200 | Display buffer size (~1 second at 200Hz) |
| `accelBufferDuration` | 100ms | Ring buffer for velocity correlation |
| `peakDecayRate` | 0.95 | Peak indicator decay per sample |

**Tuning**: Generally don't change these. `motionUpdateRate` above 200Hz gives diminishing returns. `accelBufferDuration` must be > `velocityDelay`.

## Velocity Mapping

| Parameter | Value | Description |
|-----------|-------|-------------|
| `velocityMinG` | 0.01g | Accelerometer reading for softest playable tap |
| `velocityMaxG` | 0.5g | Accelerometer reading for hardest tap |

**Tuning**: Adjust based on the player's touch and the specific iPad model. Narrower range = more sensitive. `velocityMinG` too low may trigger from ambient vibration. These only apply when Pressure is in use.

## Sliders

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sliderWidth` | 150pt | Slider track length (~1.5 inches on iPad) |
| `sliderHeight` | 66pt | Slider track height (1.5× finger-width) |
| `slider1Default` | 0.5 | Value Slider 1 returns to when released |
| `slider2Default` | 0.5 | Value Slider 2 returns to when released |

**Tuning**: Adjust defaults to match the most common resting value for the parameter they're mapped to. `sliderWidth`/`sliderHeight` can be adjusted for ergonomics.

## Sarangi model (Mac)

The Mac's played voice is the **sarangi model** (`SarangiKit`): the base voice's dry audio (the fitted **sarangi model source** by default, or dry SWAM / the sitar) is turned into a full sarangi by the v57 **passive coupled bridge–body network** (played combs + the taraf web loading one bridge via a delay-free junction solve, the modal body + W side channel, the direct taraf tap, the radiation FIR + `E_lp`, and the optional drone/room — both fitted 0; Starpad's 2-stage FX rack sits on top, default off). The model owns its own body + room and goes straight to `mainMixerNode`, bypassing the master FX. See [Sound Design](sound-design.md) and [Sarangi](sarangi.md) for the architecture.

There are **22 model parameters** (`SarangiKit.ParamSpec.all` — the v57 live surface; the legacy jawari exciter `C_*`, `mix_dry`/`mix_bank`/`mix_jaw`, `sym_gain`, `sym_bow_follow`, `H1`–`H5`, `B_chorus`, `B_jawari`/`B_jawari_rel`, `B_couple`, `E_body`/`E_low_shelf_*`/`dry_lp`, and `F_width` were removed — none are read by the passive coupled render), grouped Bank / Drone / Body / Reverb / Mix. Each is either **structural** (rebuilds the engine's filter coefficients off-thread) or a **live scalar** (a gain the render thread reads per buffer). They are owned + persisted by `SarangiStore` in `InstrumentState`; the Sarangi-tab sliders (⌘3) edit them directly, and audition scores reach them via `voiceParam` name `sarangi.<paramId>` (e.g. `sarangi.B_gain`, `sarangi.N_taraf_dir`). They are **not** part of the iPad's `MappableParameter` enum. Defaults below are the `ParamSpec` factory defaults; the fitted preset (`sarangi_pilu`) overrides them.

### Bank (the taraf web + the junction tap)

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `B_gain` | 0–6 | 0.4 | — | "Bank gain" — overall taraf level (also sets the per-string junction weights; within a choir the gain cancels in the impedance law). Fitted: ≈3.87. |
| `B_t60_scale` | 0.5–3.55 | 1.0 | ✓ | "Decay × (t60)" — scales every string's t60 ring time. Fitted: ≈3.27. |
| `B_bright` | 0–1.5 | 0 | — | "Bright choir" — level of the bright-tagged strings relative to the clean choir. |
| `B_lp` | 0.1–1 | 0.4 | ✓ | "String brightness" — gut-string HF roll-off baked into the comb loop. |
| `B_pol_split` | 0–6 ¢ | 0 | ✓ | "Polarization ¢" — every string becomes its two transverse polarizations, split ~this many cents (golden-ratio spread). Fitted: ≈2.75 ¢. |
| `B_pol_gain` | 0.4–1 | 0.85 | ✓ | "Polarization gain" — the second polarization's gain. |
| `B_pol_t60` | 0.3–1 | 0.65 | ✓ | "Polarization t60×" — the second polarization's decay multiplier. |
| `B_inharm` | 0–0.3 | 0 | ✓ | "Wire stiffness" — in-loop dispersion allpass: partials ring sharp like stiff wire. Fitted: ≈0.245. |
| `B_damp` | 0–1 | 0 | ✓ | "String damping" — in-loop f² damping: upper partials decay in fractions of a second while the fundamental keeps the string's t60 (sympathetic selectivity by harmonic order). Fitted: 0.6. |
| `B_spread` | 0–1 | 0.7 | — | "Stereo spread" — per-string pan positions (frequency rank across the bridge) radiated through the W side channel → the mono sum is pan-invariant. |
| `N_taraf_dir` | 0–0.12 | 0 | ✓ | "Taraf direct tap" — the direct taraf-velocity radiation tap: the ringing-comb persistence the junction's W cannot radiate. Preset-carried (never in `sarangi_coupled.json`). Fitted: 0.02. |
| `N_taraf_dir_lp` | 0–4000 Hz | 900 | ✓ | "Tap low-pass (Hz)" — two cascaded one-poles shaping the tap (the causal twin of the offline zero-phase radiation-efficiency magnitude; ≤0 = unshaped). |

### Drone (the sustained low drone, ≈ tonic/4)

The v57/Pilu fit ships `mix_drone` = 0 (session ground truth: no drone); the block stays playable live.

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `mix_drone` | 0–1 | 0 | — | "Drone" — drone level into the bridge force. |
| `D_t60` | 0.5–6 s | 2.0 | ✓ | "Drone decay s". |
| `D_level` | 0–1 | 0.36 | ✓ | "Drone level" (internal resonator level). |
| `D_nharm` | 1–4 | 3 | ✓ | "Drone harmonics". |
| `D_floor` | 0–1 | 0.6 | ✓ | "Drone floor" — activity-gate continuity floor. |

### Body

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `E_lp` | 6–19 kHz | 16000 | ✓ | "Body low-pass (Hz)" — the body's radiation low-pass (the skin's efficiency rolloff), after the radiation FIR. Fitted: ≈18.7 kHz. |

> The rest of the body is **not** slider-editable: the modal admittance/radiation bank + the radiation FIR come from `sarangi_coupled.json` (the FIR ships at both 44.1 kHz and 48 kHz), and the output user-EQ (`VoiceEQBand` on `InstrumentState.eqBands`) defaults **flat** (the fitted W valley superseded the old de-horn cuts; `VoiceEQBand.dehornA` remains available).

### Reverb (the room)

The v57 ear-law is **no reverb** — the ringing taraf is the room — so the preset ships `F_mix` = 0; the sliders stay for taste. (The FX rack's per-stage reverbs are separate, on `InstrumentState.fx`, also default off.)

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `F_rt60` | 0.5–2 s | 1.2 | ✓ | "Room RT60 (s)". |
| `F_mix` | 0–0.6 | 0 | — | "Room mix" — mono additive wet, split equally L/R. |
| `F_predelay` | 8–40 ms | 20 | ✓ | "Pre-delay (ms)". |

### Mix

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `main_gain` | 0–6 | 1.0 | — | "Main gain" — playback gain at the output mix only (never changes how hard the strings are driven). |

Plus a Starpad-side **`sarangiDriveGain`** ("Drive (source→model)", FX tab's Pre-drive section — lives on `AppController`/`AudioEngine`, default 1): a trim on the drive into the network. With the model source, calibration is in the preset instead (`gin 2.6` / `gout 0.45`); with SWAM, raise it for presence. A soft limiter (`SarangiEngine.softClip`) backstops loud peaks.

Plus two non-`ParamSpec` scalars on `SarangiParams`: `gin` (input gain) and `gout` (master output gain — the Sarangi-tab "Output" slider). Both are live scalars.

### Sympathetic-string table + tuning

The taraf bank is a fully editable `[StringSpec]` table — each row `(freq, gain, t60, bright, enabled, group)` — edited in the **Tarab tab (⌘4)**. **By default it auto-tunes to the Pitch Pad scale** (`autoSyncToScale`); manual edits / raga picks detach it. Generated by `RagaTuning.buildChoirs` (JI ratios, four-choir layout, seeded ±cents detune — but note the fitted `sarangi_pilu` preset LOADS its exact offline table instead: a regeneration, including the default scale auto-sync, replaces it and audibly weakens the ring — the string-table law). Editing a row, adding/removing strings, or changing raga/tonic triggers a structural rebuild. Three ragas ship: E♭ harmonic minor, Bhairav, **Pilu** (fitted). See [Sarangi](sarangi.md).

### Preset

One fitted preset — **`sarangi_pilu`** (the v57 Pilu-session fit, default — pair with the **Sarangi (model)** base voice) — bundles the params JSON plus the **exact offline string table** (`sarangi_pilu_strings.json`, 39 strings). Loading it reproduces the offline render's setup. The whole `InstrumentState` persists to UserDefaults (`persistKey` **v7**) and exports/imports as a `.sarangi` JSON file. The bundle also carries **`sarangi_coupled.json`** (the REQUIRED coupled network config — modes/residues, junction impedances, radiation FIR at 44.1 k + 48 k; the engine is silent without it), `sarangi_model_v57.json` (the fitted source model), and `live_comp.json` (live loudness calibration).

### FX rack (Mac)

The **FX rack** (`FXRack` in `SarangiKit`) sits on top of the model's own room, stored on `InstrumentState.fx` and edited in the **FX tab** (⌘5). **Two stages** since the v57 re-vendor (the passive coupled network has one output stream, so the old per-voice Violin/Sym stages were removed): `violinPre` (a *pre-drive* stage that shapes the played voice BEFORE it excites the bridge/taraf web) and `global` (mid/side on the network's output). Each stage is a low-pass **filter** (cutoff + resonance) → an interactive **graphical EQ** (a variable-length list of `EQBand`s, each `{ id, freq, gainDB, q, type, enabled }`; `type` ∈ `peaking` / `lowShelf` / `highShelf` / `highPass` / `lowPass`; 0…`VoiceFXParams.maxEQBands` = 12) → **reverb** (`reverbMix` + `reverbWidth` + `reverbRT60`), behind an **enable** flag. **Defaults: BOTH stages OFF** (the fitted v57 chain is the sound). Old persisted data decodes tolerantly; `persistKey` is **v7**.

A stage's `enabled` + `reverbMix` + `reverbWidth` are **live scalars** (`AudioEngine.applySarangiFXScalars`); its `filterCutoff` / `filterResonance` / **EQ bands** are **live filter** — an in-place biquad coefficient swap on the running engine (`AudioEngine.applySarangiFXFilters`, click-free, no rebuild). Only `reverbRT60` is **structural** (rebuild). Audition `voiceParam` paths:

- `sarangi.fx.<violinPre|global>.<enabled|reverbMix|reverbWidth|reverbRT60|filterCutoff|filterResonance>`
- `sarangi.fx.<stage>.eq<N>.<freq|gainDB|q>` (arbitrary existing band index N)

See [Sarangi — FX rack](sarangi.md#fx-rack-the-fx-tab-5).

### Master FX (tanpura/sitar Room)

`AVAudioUnitEQ` (resonant low-pass) → `AVAudioUnitReverb(.mediumHall)` → `postReverbEQ`. They wrap the `(tanpura + sitar)` mix on `preReverbMixer`. The **sarangi bypasses this** entirely (it uses its own per-voice FX rack, above), so these now shape only the tanpura/sitar tail — and the controls were relocated to the **Tanpura tab** ("Room (tanpura + sitar)" section). Owned by `AppController`; audition names `reverbMix` / `filterCutoff` / `filterResonance`.

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| `filterCutoff` | 20–20000 Hz | 18000 | Master EQ band frequency. 18 kHz keeps the filter effectively open; lower darkens the tanpura/sitar. |
| `filterResonance` | 0–1 | 0 | Maps onto the EQ band's bandwidth (0 → 4 octaves wide / no resonance, 1 → 0.1 octaves wide / sharp peak). |
| `reverbMix` | 0–100 % | 25 | Wet/dry mix on `AVAudioUnitReverb` — the tanpura/sitar room. |

### Hosted AU

The sarangi model can be fed by a hosted Audio Unit (a dry SWAM base voice — the shipping default is the fitted sarangi source instead); each `SoundPreset.State` carries an `AudioEngine.HostedAUDescriptor`.

| Field | Type | Description |
|-------|------|-------------|
| `hostedAudioUnit` | `HostedAUDescriptor?` | 3-tuple of 4-char codes `(type, subType, manufacturer)` passed to CoreAudio's `AudioComponentDescription` to locate the AU. `("aumu", "Svl3", "AuMo")` for SWAM **Violin** 3 (the default SWAM pick; the shipping default base voice is the fitted sarangi source, which loads no AU). `nil` means "no hosted AU" (the model runs on silence — useful for testing only). |
| `hostedAUParams` | `[String: Float]` | SWAM AU param id → value, applied to every slot on load by `setHostedAUParameterDefaults`. Carries the matched bow timbre (Bow Position/Pressure/Noise, String Resonance) **and the dry-SWAM block** — `Ambiente Room Simulator` / `Reverb Mix` / `Reverb Time` / `Early Reflection Gain` / `Ambience Amount` / `Room Sizes` / `Instrument Body` all 0, so SWAM contributes no internal room/body (the sarangi model handles both). The model needs a clean dry violin. |

`AudioEngine.loadHostedInstrument` instantiates `Config.maxHostedPolyVoices` copies in parallel since SWAM Violin is monophonic. See [Polyphonic Mode](#polyphonic-mode) below.

**Tuning**:

- For a brighter/sharper sarangi: lower `B_t60_scale` for a tighter bank, raise `B_lp` for brighter strings, raise `E_lp` to open the body's radiation.
- For more ringing-string presence: raise `B_gain`, and `N_taraf_dir` (with `N_taraf_dir_lp` shaping how dark the tap is).
- Level with `main_gain`/`gout` (output only — the strings' excitation is set by `gin` and "Drive (source→model)").
- Space comes from the room group (`F_mix`/`F_rt60` — fitted 0: the ringing taraf IS the room) or the **FX rack**'s per-stage reverbs, not the master reverb — the sarangi bypasses it.
- **Tune the tarab to the raga.** By default the tarab follows the Pitch Pad scale; the fitted `sarangi_pilu` table is exact for Pilu (a re-sync replaces it). A mistuned bank rings at unrelated pitches.

## Tanpura drone (Mac)

The playable tanpura on the Tanpura tab is parameterized by `TanpuraParams` (StarpadDSP). All values are settable live from the tab, from audition scores via `voiceParam` names `tanpura.<path>`, and from the offline renderer's spec JSON. Persisted to UserDefaults; **not** part of `SoundPreset`.

Per string ×4: `f0` (30–1000 Hz), `level` (0–2.2), `falloff` (0–4), `pluckPos` (0.02–0.5), `decay` (0.2–30 s), `dampTilt` (0–2), `bloomDelay` (0–1.5 s), `bloomSkew` (0–2), `attackLevel` (0–1), `attackDecay` (0.005–0.5 s), `inharmonicity` (0–0.002), `subLevelDB` (−60…−2; level of the half-integer jawari sub-bank at (k+0.5)·f0, −60 = off), `subFalloff` (0–4; the sub bank's own spectral falloff), `subKneeH` (1–64; 4th-order k-lowpass knee on the sub bank, 64 ≈ off), plus per-harmonic arrays `gainTrimDB[64]` (−60…+24 dB), `peakTrim[64]` (0.05–8×), `decayTrim[64]` (0.05–8×).

Global: `harmonicCount` (4–64), `jivaDepth` (0–1), `jivaRate` (0.05–3 Hz), `jivaTilt` (0–1), `jivaConserve` (0–1; rescales jiva to conserve total power — fixes the isolated-pluck wah-wah pump), `jivaRateSpread` (0–1.5; per-harmonic jiva-rate scatter width, 0 = single shared rate), `pitchDriftCents` (0–10), `pitchDriftRate` (0.01–2 Hz), `pluckVariationDB` (0–6), `noiseLevel`/`noiseDecay`/`noiseFreq`/`noiseQ`, `crossExcite` (0–0.5), `crossTolCents` (1–50), `panSpread` (0–1), `bodyDry` (0–1), `body[3]{freq,gain,q}` (q to 350 — high Q is a ringing body mode), `tiltDB` (−12…12), `masterGain` (0–1), `roomWetDB` (−60…−6; in-model Schroeder room, −60 = off), `roomDecayS` (0.15–2.5), `roomDamp` (0–1), `roomPredelayMs` (0–40).

Outside `TanpuraParams`: `tanpuraGainDB` (−24…+24 dB, default **+12**) on `AppController` — output makeup gain applied in `AudioEngine` after the model's peak-normalized `masterGain`, so listening volume never disturbs the matched bake. Slider in the Tanpura tab toolbar; audition `voiceParam` name `tanpuraGainDB`.

What each does, the envelope math, and the matching pipeline that fits them to a reference recording: [tanpura.md](tanpura.md).

## Polyphonic Mode

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maxPolyVoices` | 16 | Maximum simultaneous voices in poly mode |
| `maxHostedPolyVoices` | 8 | Concurrent voices for a hosted-AU preset (SWAM Violin). Each AU instance is monophonic; each MPE channel routes to its own slot via `channel % N`. Higher = more notes before stealing, but each SWAM instance costs ~5–10% CPU on Apple Silicon. |

## Display

| Parameter | Value | Description |
|-----------|-------|-------------|
| `pitchHistoryLength` | 120 | Pitch graph buffer (~2 seconds at 60Hz) |
| `peakDelayHistory` | 20 | Rolling window for velocity delay instrumentation |

**Tuning**: Increase `pitchHistoryLength` for a longer graph (more memory, wider view). Decrease for a more zoomed-in, responsive view.
