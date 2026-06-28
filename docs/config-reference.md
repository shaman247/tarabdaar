# Config Reference

System-level tunable parameters live in `Packages/StarpadCore/Sources/StarpadCore/Config.swift`. iPad dimension-mappable parameter ranges (glide speed, amplitude, MIDI CCs) are defined in `TiltMapping.swift` via `MappableParameter.defaultRange` and configured at runtime in the MAP editor. See [Sensors — Dimension System](sensors.md#dimension-system-parameter-mapping) for the full parameter table.

The Mac-side **sarangi model** params (23 of them) live in `SarangiKit`'s `ParamSpec.all` (name, range, default, group, structural flag), edited in the Sarangi tab via `SarangiStore`. The sarangi's reverb / filter / EQ are **not** `ParamSpec` params — they're the per-voice **FX rack** (`FXRack` on `InstrumentState`, edited in the FX tab). The shared **master-FX** params (now the tanpura/sitar Room) live on `AppController` as `@Published` fields. Per-preset FX/hosted-AU defaults come from `SoundPreset.state()` in `StarpadMac/SoundPreset.swift`. The played voice is the sarangi model fed by a hosted Audio Unit (SWAM Violin, run dry); the AU has its own parameter space which you configure via its own UI (open via the HostedAUPill in the Mac top bar).

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

The Mac's played voice is the **sarangi model** (`SarangiKit`): the dry SWAM Violin audio is turned into a full sarangi by the block chain (body pre-EQ, a 37-string Karplus-Strong sympathetic bank, a jawari bridge exciter, body color + body FIR; the drone block was removed, and the old block-F Freeverb is now the per-voice FX rack). The model owns its own body + per-voice FX and goes straight to `mainMixerNode`, bypassing the master FX. See [Sound Design](sound-design.md) and [Sarangi](sarangi.md) for the architecture.

There are **23 model parameters** (`SarangiKit.ParamSpec.all` — the upstream fit's set minus the 4 removed drone/`mix_drone` params and the 4 removed `F_*` reverb params, plus 3 Starpad-added: `sym_bow_follow`, `main_gain`, `sym_gain`), grouped Bank / Jawari / Body / Reverb (empty — `F_*` removed) / Mix. Each is either **structural** (rebuilds the engine's filter coefficients off-thread) or a **live scalar** (a gain/mix the render thread reads lock-free). They are owned + persisted by `SarangiStore` in `InstrumentState`; the Sarangi-tab sliders (⌘2) edit them directly, and audition scores reach them via `voiceParam` name `sarangi.<paramId>` (e.g. `sarangi.B_gain`, `sarangi.mix_jaw`). They are **not** part of the iPad's `MappableParameter` enum. Defaults below are the `ParamSpec` factory defaults; a fitted preset (`pair1`/`pair2`) overrides them.

### Bank (block B — sympathetic strings)

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `B_gain` | 0–1.2 | 0.4 | — | "Bank gain" — overall sympathetic-bank level. |
| `B_t60_scale` | 0.5–2.8 | 1.0 | ✓ | "Decay × (t60)" — scales every string's t60 ring time. |
| `B_bright` | 0–1.5 | 0.8 | — | "Bright choir" — level of the brighter raga-tuned choir relative to the clean chromatic row. |
| `B_lp` | 0.1–1 | 0.4 | ✓ | "String brightness" — gut-string HF roll-off on the comb strings (clean choir = `0.6·B_lp`, bright/raga choir = `B_lp`). Lower = darker/muted tarab. |
| `sym_bow_follow` | 0–1 | 0.7 | — | "Sym ↔ bow follow" — how much the bank fades WITH the bow (vs ringing on its own long t60). 0 = free authentic ring; 1 = the sym tracks the note for tight, responsive staccato. Non-fitted (Starpad-added). See [sarangi.md](sarangi.md) → Responsiveness. |

### Jawari (block C — bridge buzz)

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `C_pre_hp` | 1500–3500 Hz | 2200 | ✓ | "Pre HP (Hz)" — high-pass before the shaper. |
| `C_drive_min` | 1–3 | 1.5 | — | "Drive min" — shaper drive at low `amp`. |
| `C_drive_max` | 4–20 | 12 | — | "Drive max" — shaper drive at full `amp`. |
| `C_asym` | 0–0.5 | 0.3 | — | "Asymmetry" — `tanh` shaper asymmetry (even-harmonic content). |
| `C_wet` | 0–0.6 | 0.25 | — | "Buzz wet" — wet level of the buzz. |
| `C_rasp` | 0–1 | 0.2 | — | "Rasp" — extra buzz roughness. |
| `C_top` | 0–0.8 | 0.15 | — | "Top edge" — high-frequency edge. |
| `C_sweep_lo` | 3–7 ×f0 | 5 | ✓ | "Sweep lo (×f0)" — low bound of the morphing-bandpass sweep. |
| `C_sweep_hi` | 10–20 ×f0 | 16 | ✓ | "Sweep hi (×f0)" — high bound of the sweep. |
| `C_to_bank` | 0–1 | 0.3 | — | "Buzz → bright" — how much buzz feeds back into the bright choir's drive. |

> **Drone (block D) — REMOVED.** The `tonic/4` laraj drone (`DroneGen`, the
> `D_*`/`mix_drone` params) was deleted: at sub‑bass it became a clipping low
> rumble when the sym was boosted.

### Body (block E)

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `E_low_shelf_f` | 80–300 Hz | 160 | ✓ | "Low shelf (Hz)". |
| `E_low_shelf_db` | −6…+12 dB | 0 | ✓ | "Low shelf (dB)". |
| `E_body` | 0–1.6 | 1.0 | — | "Body ring" — level of the 6 modal body resonances. |

> Block E also applies a measured min-phase **body FIR** (1025 taps) on the dry branch and the `eModes` body resonances (6 `BodyMode` peaks). The FIR + `D_nharm` + `E_modes` come from the fitted preset (`pairN.json` / `pairN_fir.json`) and are not slider-editable.

### Reverb — removed (now the per-voice FX rack)

The old block-F Freeverb params (`F_rt60` / `F_mix` / `F_predelay` / `F_width`) were **removed** from `ParamSpec` (the `ParamGroup.reverb` enum case is kept, empty). The sarangi's reverb / filter / EQ are now the per-voice **FX rack** (`FXRack`), stored on `InstrumentState.fx` (persisted; `SarangiStore.persistKey` bumped v3→v4) and edited in the **FX tab** (⌘4) — see [FX rack](#fx-rack-mac). It is not a slider group here.

### Mix

| Parameter | Range | Default | Structural | Label / description |
|-----------|-------|---------|------------|---------------------|
| `mix_dry` | 0.5–1.2 | 0.85 | — | "Dry (violin)" — level of the dry bowed-violin branch (through block E body). |
| `mix_bank` | 0–1.5 | 0.5 | — | "Bank" — sympathetic-bank level into the supplement mix. |
| `mix_jaw` | 0–1.5 | 1.0 | — | "Jawari" — buzz level into the supplement mix. |
| `main_gain` | 0–6 | 1.0 | — | "Main voice gain" — playback level of the bowed note (dry + jawari). Applied at the output mix only, so it does **not** change how hard the sympathetic strings are excited. Non-fitted (Starpad-added). |
| `sym_gain` | 0–40 | 12 | — | "Sym voice gain" — playback level of the sympathetic bank. The bank is intrinsically ~30 dB below the main, so the range/default are large (12 ≈ −12 dB under the main; 40 ≈ equal). Non-fitted (Starpad-added). |

Plus a Starpad-side **`sarangiDriveGain`** ("Drive (SWAM→model)", in the **FX tab's Violin section**, not a model param — lives on `AppController`/`AudioEngine`): lifts SWAM's raw output (~50× quieter than the fit reference) up to the model's operating level. A soft limiter (`SarangiEngine.softClip`) backstops loud peaks.

Plus two non-`ParamSpec` scalars on `SarangiParams`: `gin` (input gain, default 1.0) and `gout` (master output gain, default 1.0 — the Sarangi-tab "Output" slider, 0–2). Both are live scalars.

### Sympathetic-string table + tuning

The bank (block B) is a fully editable `[StringSpec]` table — each row `(freq, gain, t60, bright, enabled)` — **independent of the playing (Pitch Pad) scale** (the old auto-derive-from-scale behaviour was removed). It is generated for a **raga + tonic** by `RagaTuning.buildStrings` (JI ratios, a 37-string four-choir layout with seeded ±cents detune). Two ragas ship (E♭ harmonic minor, Bhairav). Editing a row, adding/removing strings, or changing raga/tonic triggers a structural rebuild. `regenerate()` rebuilds from raga + tonic (discarding edits); `transpose` scales every frequency to a new tonic keeping edits. See [Sarangi](sarangi.md).

### Presets

Two fitted presets — `pair1` (E♭ harmonic minor) and `pair2` (Bhairav) — each bundle a `pairN.json` parameter file plus a `pairN_fir.json` block-E body FIR. Loading one reproduces that pair's full setup (raga + tonic + regenerated bank + params + FIR), so the live model matches its offline render. `pair1` is the default. The whole `InstrumentState` persists to UserDefaults and exports/imports as a `.sarangi` JSON file.

### FX rack (Mac)

The sarangi's reverb / filter / EQ are a **per-voice FX rack** (`FXRack` in `SarangiKit`), stored on `InstrumentState.fx` and edited in the **FX tab** (⌘4). The model splits its output into a **Violin** voice (dry + jawari), a **Sym** voice (the bank), and a **Global** stage over the sum; each of the three stages is a low-pass **filter** (cutoff + resonance) → **3-band parametric EQ** (`EQBand`: `freq` / `gainDB` / `q`) → **reverb** (`reverbMix` + `reverbWidth` + `reverbRT60`), behind an **enable** flag. Defaults: Violin **on** (reverb ≈ 0.25 + open filter), Sym **off** (dry), Global **off**.

A stage's `enabled` + `reverbMix` + `reverbWidth` are **live scalars** (`AudioEngine.applySarangiFXScalars`); its `filterCutoff` / `filterResonance` / EQ / `reverbRT60` are **structural** (rebuild). Audition `voiceParam` paths:

- `sarangi.fx.<violin|sym|global>.<enabled|reverbMix|reverbWidth|reverbRT60|filterCutoff|filterResonance>`
- `sarangi.fx.<stage>.eq<0..2>.<freq|gainDB|q>`

See [Sarangi — FX rack](sarangi.md#fx-rack-the-fx-tab-4).

### Master FX (tanpura/sitar Room)

`AVAudioUnitEQ` (resonant low-pass) → `AVAudioUnitReverb(.mediumHall)` → `postReverbEQ`. They wrap the `(tanpura + sitar)` mix on `preReverbMixer`. The **sarangi bypasses this** entirely (it uses its own per-voice FX rack, above), so these now shape only the tanpura/sitar tail — and the controls were relocated to the **Tanpura tab** ("Room (tanpura + sitar)" section). Owned by `AppController`; audition names `reverbMix` / `filterCutoff` / `filterResonance`.

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| `filterCutoff` | 20–20000 Hz | 18000 | Master EQ band frequency. 18 kHz keeps the filter effectively open; lower darkens the tanpura/sitar. |
| `filterResonance` | 0–1 | 0 | Maps onto the EQ band's bandwidth (0 → 4 octaves wide / no resonance, 1 → 0.1 octaves wide / sharp peak). |
| `reverbMix` | 0–100 % | 25 | Wet/dry mix on `AVAudioUnitReverb` — the tanpura/sitar room. |

### Hosted AU

The sarangi model is fed by a hosted Audio Unit; each `SoundPreset.State` carries an `AudioEngine.HostedAUDescriptor`.

| Field | Type | Description |
|-------|------|-------------|
| `hostedAudioUnit` | `HostedAUDescriptor?` | 3-tuple of 4-char codes `(type, subType, manufacturer)` passed to CoreAudio's `AudioComponentDescription` to locate the AU. `("aumu", "Svl3", "AuMo")` for SWAM **Violin** 3 (the shipping sarangi base). `nil` means "no hosted AU" (the model runs on silence — useful for testing only). |
| `hostedAUParams` | `[String: Float]` | SWAM AU param id → value, applied to every slot on load by `setHostedAUParameterDefaults`. Carries the matched bow timbre (Bow Position/Pressure/Noise, String Resonance) **and the dry-SWAM block** — `Ambiente Room Simulator` / `Reverb Mix` / `Reverb Time` / `Early Reflection Gain` / `Ambience Amount` / `Room Sizes` / `Instrument Body` all 0, so SWAM contributes no internal room/body (the sarangi model handles both). The model needs a clean dry violin. |

`AudioEngine.loadHostedInstrument` instantiates `Config.maxHostedPolyVoices` copies in parallel since SWAM Violin is monophonic. See [Polyphonic Mode](#polyphonic-mode) below.

**Tuning**:

- For a brighter/sharper sarangi: lower `B_t60_scale` for a tighter bank, raise `B_bright` for more of the bright choir, and lean on the jawari (`mix_jaw`, `C_wet`, `C_drive_max`, `C_top`).
- For more bridge buzz/shimmer: raise `C_wet` / `C_rasp` / `C_to_bank`; sweep `C_sweep_lo`/`C_sweep_hi` for the buzz character.
- Balance the layers with the **Mix** group (`mix_dry`/`main_gain` vs `mix_bank`/`mix_jaw`/`sym_gain`); `gout` is the master output trim, and "Drive (SWAM→model)" sets the input level.
- Space comes from the per-voice **FX rack** (the FX tab's per-stage reverb mix/width/rt60), not the master reverb — the sarangi bypasses it.
- **Tune the tarab to the raga.** Pick a raga + tonic (or load `pair1`/`pair2`) so the sympathetic strings match the played notes. A mistuned bank rings at unrelated pitches.

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
