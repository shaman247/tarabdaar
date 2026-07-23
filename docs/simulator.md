# Simulator & Audition Loop

The **Simulator** tab in StarpadMac plays the same MPE pipeline an iPad
would, driven from the Mac's mouse + keyboard + on-screen sliders. It
exists so sound design can be iterated on without an iPad in the loop
— and so an external tool (a script, a Claude session) can drop a JSON
score in a watched folder and get back a recorded WAV, enabling
fully-autonomous parameter sweeps and target-matching loops.

This page covers:

- [What the Simulator tab is](#what-the-simulator-tab-is)
- [Interactive controls](#interactive-controls)
- [Recording](#recording)
- [The audition loop](#the-audition-loop)
- [Audition score format](#audition-score-format)
- [Tools](#tools)
- [Reverse-engineering a target WAV](#reverse-engineering-a-target-wav)

## What the Simulator tab is

A Mac-side host for an [iPad-equivalent `NoteManager`](architecture.md)
with mocked sensors. The same touch → glide → MPE pipeline
the iPad uses runs here, but tilts come from sliders and "strike
velocity" comes from a single knob instead of an accelerometer spike.
Emitted MPE bytes never touch CoreMIDI — they're delivered in-process
to `AudioEngine.sendHostedMIDI(...)` and `AppController` CC handling,
so the simulator coexists cleanly with a real iPad plugged in over USB
(no double-triggering).

The wiring lives in:

- [`StarpadMac/IPadSimulator.swift`](../StarpadMac/IPadSimulator.swift) — owns the `NoteManager`, `MockMotionSource`, and the in-process `MIDIEngine` (constructed with `publishToCoreMIDI: false`)
- [`StarpadMac/MockMotionSource.swift`](../StarpadMac/MockMotionSource.swift) — `MotionSource` shim with tilt/strike-force properties
- [`StarpadMac/Views/SimulatorView.swift`](../StarpadMac/Views/SimulatorView.swift) — the UI

## Interactive controls

### Mouse

| Action | Result |
|--------|--------|
| Click and drag a key | `touchBegan` → `touchMoved` → `touchEnded` — exactly what tapping the iPad does. Dragging horizontally engages the drag-glide system. |
| Shift-click a key | Locks a finger on that key. Held until shift-clicked again on the same key. Build chords this way. The locked highlight is a fainter cyan than an actively-held key. |
| Shift-click a locked key | Releases that lock. |

### Computer keyboard (anchored to C4 = MIDI 60)

```
white :  A   S   D   F   G   H   J   K   L
note  :  C   D   E   F   G   A   B   C5  D5
black :  W   E       T   Y   U       O
note  :  C#  D#      F#  G#  A#      C#5
```

- **Z / X** — octave down / up (range −3 to +3)
- Held keys behave like fingers; releasing the key releases the touch
- Repeats are ignored (no machine-gun retriggering)

The key monitor is installed in the Simulator tab's `onAppear` and
removed in `onDisappear`, so it only fires while the tab is visible.

### Sliders

| Control | Source of truth | Range | Reset |
|---------|----------------|-------|-------|
| Tilt 1 / 2 / 3 | `MockMotionSource.tilt{1,2,3}` (matches `MotionManager.normalizedTilts`) | [-1, +1] | "Center" button |
| Slider 1 / 2 | `NoteManager.slider{1,2}Value` — same as iPad's on-screen sliders | [0, 1] | "Default" button (0.5) |
| Strike | `MockMotionSource.strikeForce` (peak-G value `peakAccelSince` returns) | [0.01, 0.5] g | hand-set |

Strike force feeds the velocity LUT (`Config.velocityMinG..velocityMaxG`,
log-mapped to MIDI 1..127). 0.1 g ≈ v75; 0.5 g ≈ v127.

The default `DimensionMapping` (shared with the iPad's persisted prefs)
ties:

- `velocity` → `accelPressure` → strike-force knob
- `glideSpeed` / `glideCompression` / `amplitude` / `aftertouch` → `tilt1`

Edit those bindings in the iPad's mapping matrix to change what the
sliders actually control. The simulator reads the same persisted
mapping; there's no separate "simulator preferences."

## Recording

Click **Record** in the Simulator tab to capture post-FX audio (after
master EQ + reverb, before the output device) to a 16-bit stereo WAV.
Files land in `~/Music/Starpad-Recordings/` with timestamped names.
Right-click the Record button to reveal the most recent file in
Finder. Last recording's path is also shown in the footer; clicking it
opens Finder selected on the file.

Implemented as an `installTap(onBus: 0)` on `engine.mainMixerNode` in
[`AudioEngine.startRecording(to:)`](../Packages/StarpadCore/Sources/StarpadCore/AudioEngine.swift).
The tap writes to an `AVAudioFile` with explicit Linear-PCM-Int16
settings (AVAudioFile converts from the engine's Float32 buffers on
write). `stopRecording` removes the tap and closes the file.

## The audition loop

`AuditionRunner` watches `<repo>/auditions/inbox/` for `*.json` score
files. For each new score it:

1. Waits for the file size to be stable (250 ms-ish) — guards against
   readers like bash heredocs that truncate-then-fill and trigger the
   watcher mid-write.
2. Parses the JSON into `AuditionScore`.
3. Calls `simulator.panic()` and resets tilts to 0 so each render
   starts from a clean state.
4. Calls `audio.startRecording(to: <repo>/auditions/outputs/<name>.wav)`.
5. Schedules every event with `DispatchQueue.main.asyncAfter`.
6. At `lastEventAt + tailSeconds`, panics and stops recording.
7. Writes a `.done` JSON marker (or `.error` on parse/render failure)
   next to the score so an external watcher can synchronize. The `.done`
   includes `framesWritten` so silent capture failures are visible.

**Recording mechanism (and why it's not `AVAudioFile`).** `startRecording`
taps `mainMixerNode` and accumulates the post-FX samples into a pre-allocated
interleaved Int16 buffer (no audio-thread allocation); `stopRecording` writes a
complete 16-bit-stereo WAV with its own header, synchronously, before the
`.done` marker. We deliberately do **not** stream to `AVAudioFile`: its
incremental writer buffers internally and **drops the unflushed tail on dispose
for long recordings** — the frames were "written" but never hit disk, so
recordings beyond ~10 s intermittently produced 0-frame WAVs. Owning the buffer
+ header makes any-length recording deterministic and complete. Cap is ~120 s of
stereo (overflow is flagged in the `.done`).

The audition root is resolved as:

1. `STARPAD_AUDITIONS_DIR` env var (overrides everything)
2. `<repo>/auditions/` discovered via `#filePath` (developer debug
   builds; the source file location is meaningful)
3. `~/Library/Application Support/Starpad/Auditions/` (last-resort
   fallback)

**Writers must use atomic writes**: write to `<name>.json.tmp` then
`mv` into place. The `tools/audition_iterate.py` driver does this; a
bash `cat > foo.json <<EOF` heredoc does NOT and will occasionally
race the file-size-stable check.

## Audition score format

```json
{
  "name": "my-render",
  "tailSeconds": 1.5,
  "events": [ ... ]
}
```

| Top-level | Notes |
|-----------|-------|
| `name`    | Optional. Used for the output WAV filename; defaults to the score's filename stem. |
| `tailSeconds` | Seconds of additional recording after the last event. Total render duration = `max(event.at) + tailSeconds`. |
| `events`  | Time-tagged event list (next section). |

### Event kinds

| `kind`       | Fields                            | Effect |
|--------------|-----------------------------------|--------|
| `noteOn`     | `at`, `id`, `note`, `keyY?`       | Begin a note. `id` is your touch identifier (any int); reuse the same id in the matching `noteOff`. `note` is a MIDI number. `keyY` ∈ [0, 1] = vertical finger position on the key (defaults 0.5). |
| `noteOff`    | `at`, `id`                        | Release the note with the matching id. |
| `glide`      | `at`, `id`, `note`, `keyY?`       | Move an already-held note to a new pitch via the drag-glide system. |
| `tilt`       | `at`, `axis`, `value`             | Set a tilt axis. `axis` ∈ {0, 1, 2}, `value` ∈ [-1, +1]. Drives whatever parameters are bound to that tilt in the dimension mapping (default: tilt1 → glide/aftertouch/amplitude). |
| `slider`     | `at`, `index`, `value`            | Set on-screen slider1/slider2. `index` ∈ {0, 1}, `value` ∈ [0, 1]. |
| `strike`     | `at`, `value`                     | Set `MockMotionSource.strikeForce` (peak-G driving the velocity LUT). 0.1 ≈ v75; 0.5 ≈ v127. |
| `voiceParam` | `at`, `param`, `value`            | Set a Mac-side voice / FX parameter — see the table below. |
| `rawNote`    | `at`, `note`, `id?`, `value?`     | Raw MIDI note-on straight to the hosted AU, **bypassing the NoteManager** (no vibrato LFO, no glide, no tilt-CC emission) — a dead-steady pitch for sound-matching. `id` = MIDI channel (1–15, default 1), `value` = velocity (default 90). The sym halo still rings (it's driven by SWAM's audio, not the MIDI path). |
| `rawNoteOff` | `at`, `note`, `id?`               | Raw MIDI note-off (matching channel). |
| `preset`     | `at`, `param` (preset rawValue)   | Apply a `SoundPreset`. Currently only `"swamViola"` ships. |
| `tanpuraPluck` | `at`, `index`, `value`          | Pluck tanpura-drone string `index` (0–3) at velocity `value` (0–1). The runner silences the drone and stops any auto-cycle at score start. |
| `padOn` / `padGlide` / `padOff` | `at`, `id`, `value` | Drive the Mac **Pitch Pad** (`controller.pitchPad`, the real playing engine) — `value` = ratio vs the pad tonic (default 1.0). `padGlide` sends a real pitch bend to a new ratio; `padOff` releases. Use these (not `noteOn`/`glide`, which take the legacy NoteManager keyboard path that emits no bend headless) to exercise pitch bends / the sitar glide. |
| `spadOn` / `spadGlide` / `spadOff` | `at`, `id`, `value` | Same as the `pad*` trio but for the **String Pad** engine (`controller.stringPad`). Lets a score play/test the String Pad path directly. |

**Why `rawNote`:** `simulator.noteOn` routes through the iPad `NoteManager`, whose
60 Hz loop runs the glide engine and per-tick pitch-bend re-emission. For matching a
steady reference, `rawNote` skips all of that and sends a fixed Note On + bend
straight to the hosted AU. (The Starpad-side vibrato LFO that this used to bypass has
since been removed entirely; `rawNote` still bypasses the glide path. The sarangi live
match, `tools/sarangi_iterate.py`, uses `rawNote`.)

### Hosted-AU (SWAM) parameters

Two extra `voiceParam` forms reach the hosted AU's own parameter tree:

| `param`            | Effect |
|--------------------|--------|
| `swam.<identifier>`| Set a hosted-AU parameter by identifier (e.g. `swam.1484578252` = SWAM's Bow Pressure) on every loaded instance. `value` is in the parameter's native range. |
| `__auDump__`       | Write the hosted AU's full parameter list (identifier, name, range, value) to `<auditions-root>/swam_params.json`. Run once to discover the identifiers. `value` is ignored. |

These are how the sarangi match drives SWAM's *own* timbre (Bow Position/Pressure,
String Resonance, etc.) and zeroes its auto-vibrato — far more reaching than a
post-AU EQ. The winning values are persisted as `SoundPreset.State.hostedAUParams`
and applied on preset load by `AudioEngine.setHostedAUParameterDefaults`.

### `voiceParam` names

The setters clamp values into the same ranges as the UI sliders. Unit
hints below match what the on-screen knobs use.

| Name                  | Range            | Effect |
|-----------------------|------------------|--------|
| `sympatheticVolume`   | 0..1             | Overall sym layer level. |
| `symCoupling`         | 0..1             | Excitation depth — how readily a played note excites the sym strings. |
| `symDecay`            | 0.05..30 seconds | Per-harmonic decay base τ (bloom-in / ring-out time). |
| `symHarmonicFalloff`  | 0.5..4           | Spectral rolloff exponent (SA voicing). |
| `symPluckPos`         | 0.02..0.5        | Pluck-position comb (suppresses the fundamental). |
| `symDampingTilt`      | 0..2             | Per-harmonic decay tilt (highs decay faster). |
| `symInharmonicity`    | 0..0.0005        | Stiffness B in `f_k = k·f0·√(1+B·k²)`. |
| `symPartialCount`     | 4..64            | Harmonics per voice. |
| `symDriveLevel`       | 0..8             | Excitation / output strength. |
| `symAttackMs`         | 1..500 ms        | Excitation follower attack. |
| `symAmpModDepth`      | 0..1             | Per-harmonic "jiva" depth (tanpura shimmer). |
| `symAmpModRate`       | 0.01..10 Hz      | Mean per-harmonic jiva LFO rate. |
| `symPitchDrift`       | 0..50 cents      | Per-string slow random-walk pitch drift amplitude. |
| `symPitchDriftRate`   | 0.001..5 Hz      | LPF cutoff on the per-string drift walk. |
| `symBody{0-2}.{freq,gain,q}`, `symBodyDry`, `symBodyTiltDB` | — | Sym-bus body (tanpura chamber). |
| `symRoomWetDB`/`DecayS`/`Damp`/`PredelayMs` | — | Sym-bus Schroeder room. |
| `violaBodyEnabled`, `violaBody{0-3}.{freq,gainDB,widthOct}` | — | Viola-path skin formants. |
| `voiceMix`            | 0..1             | Equal-power crossfade between sym (0) and SWAM (1). |
| `reverbMix`           | 0..100           | Master reverb wet/dry %. |
| `filterCutoff`        | 20..20000 Hz     | Master resonant LPF cutoff. |
| `filterResonance`     | 0..1             | Master resonant LPF Q (UI 0..1 → bandwidth 4.0..0.1 octaves). |
| `tanpuraGainDB`       | -24..24 dB       | Tanpura drone output gain (post-model makeup stage, default +12). |
| `tanpura.<path>`      | per-path         | Any tanpura-drone parameter by path — e.g. `tanpura.jivaDepth`, `tanpura.body0.freq`, `tanpura.string3.decay`, `tanpura.string1.gainTrimDB13` (0-based harmonic index). Clamped by `TanpuraParams.set(path:value:)`; see [tanpura.md](tanpura.md). |
| `baseVoice`           | 0..5             | Base voice feeding the sarangi model: 0 = SWAM Violin, 1 = Viola, 2 = Cello, 3 = Double Bass, 4 = **sitar model**, 5 = **sarangi model source** (the fitted `ViolinSynth` — the shipped default). With 4/5, SWAM is unloaded and notes (`noteOn`/`padOn` + bends) drive the model as the excitation. See [sarangi.md](sarangi.md) / [sitar.md](sitar.md). |

Note: for fast autonomous tanpura iteration you usually do NOT need the
audition runner — `tanpura-render` (StarpadDSP executable) renders a pluck
schedule offline ~50× faster than real time. The runner path is for final
end-to-end verification through the live audio graph
(`tools/tanpura_match.py make-score` emits a ready-made score).

### Minimal examples

A single dry note:

```json
{"name":"dry","tailSeconds":1,"events":[
  {"at":0.0,"kind":"voiceParam","param":"reverbMix","value":0},
  {"at":0.0,"kind":"voiceParam","param":"sympatheticVolume","value":0},
  {"at":0.0,"kind":"noteOn","id":1,"note":65},
  {"at":1.0,"kind":"noteOff","id":1}
]}
```

A glide with tilt-driven loudness swell:

```json
{"name":"swell","tailSeconds":2,"events":[
  {"at":0.0,"kind":"tilt","axis":0,"value":0.2},
  {"at":0.0,"kind":"noteOn","id":1,"note":60},
  {"at":0.5,"kind":"tilt","axis":0,"value":0.8},
  {"at":1.0,"kind":"glide","id":1,"note":64},
  {"at":2.0,"kind":"noteOff","id":1}
]}
```

A parameter sweep — render once for each sym-coupling setting:

```json
{"name":"sweep-low","tailSeconds":3,"events":[
  {"at":0.0,"kind":"voiceParam","param":"symCoupling","value":0.2},
  {"at":0.0,"kind":"voiceParam","param":"sympatheticVolume","value":0.6},
  {"at":0.0,"kind":"noteOn","id":1,"note":67},
  {"at":1.0,"kind":"noteOff","id":1}
]}
```

## Tools

All three live in [`tools/`](../tools/) and need only Python 3 +
numpy/scipy (for the smoothed-envelope onset detector).

### `audition_analyze.py <target.wav>`

Emits a first-pass score JSON. Pipeline:

1. RMS envelope at 50 ms hop, smoothed with a 150 ms box.
2. Onset detection via `scipy.signal.find_peaks` on the smoothed
   envelope, prominence ≥ 15 % of global peak, distance ≥ 250 ms. The
   peak index is then backtracked to where the envelope crosses 60 %
   of its height — that's the noteOn time.
3. Pitch per onset: autocorrelation modal pitch over the 250 ms after
   the onset, with readings ≤ MIDI 55 (G3) dropped from the vote so
   sym-pool sub-octaves don't fool the pitch tracker.
4. Note duration: release when the envelope decays past 40 % of the
   local peak, clamped to 150–600 ms (bowed-attack realism).
5. `tailSeconds` sized so the rendered file matches the target's
   total duration exactly.

The first detected note's RMS sets a `tilt1` value (mapped to MPE
aftertouch by default → SWAM responds to that as loudness).

Output to stdout, or `--out <path.json>` to write atomically.

### `audition_compare.py <target.wav> [candidate.wav]`

Reports duration, peak, RMS, per-100ms RMS envelope and autocorr
pitch trace for each file, plus (when both are given) envelope L1
distance, voiced-window count, and mean per-window semitone error.

Both files share the same pitch tracker — so when the candidate's
pitch trace matches the target's pattern (even where both are
biased to a sub-octave by sym tail), the rendering is faithful.

### `audition_iterate.py <target.wav>`

Drives analyze → render → compare → amplitude refine. Up to N passes
(default 6), stops when the candidate peak is within ±15 % of the
target peak. Writes the best score to `auditions/best.json` and best
render to `auditions/outputs/best.wav`.

Currently the refine step only adjusts global tilt/strike. Adjusting
per-note timing, pitch, and individual `voiceParam`s based on the
residual envelope is the natural next extension.

## Reverse-engineering a target WAV

1. Put the target at `auditions/target.wav` (a 16-bit stereo WAV; any
   sample rate works, 48 kHz is what the Mac records at).
2. Make sure StarpadMac is running, with the preset and voice
   parameters set to whatever was used to record the target. (If
   different settings will give a better match, set them via
   `voiceParam` events at the head of the score.)
3. `python3 tools/audition_iterate.py auditions/target.wav`
4. Listen to `auditions/outputs/best.wav` against the target.
5. Inspect `auditions/best.json`. The first-pass analyzer is
   deliberately simple — if it under- or over-counts notes, tweak
   `--hop-ms` / `--pitch-win-ms` on `audition_analyze.py`, or hand-
   edit `best.json` and re-render by dropping it back into `inbox/`.

The pipeline currently nails:

- Number of notes (within ±1 for clearly-articulated phrases)
- Pitch class (within an octave for the played voice; sym-tail
  sub-octaves get folded back via the `≤ G3` filter)
- Onset timing (typically within 100 ms of the target)
- Overall loudness (within ~3 dB of target peak — bounded by SWAM
  Viola's own dynamic-range ceiling)

What it doesn't do yet:

- Per-note expression curves (tilt sweeps mid-note)
- Sym-pool parameter sweeps to match a particular tail character
- Pitch detection above the sym-pool sub-octave bias when the played
  note is itself ≤ G3 (the `≤ G3` filter would discard the truth)

See [`architecture.md`](architecture.md) for how the simulator fits
into the broader Mac/iPad split, and [`config-reference.md`](config-reference.md)
for the underlying parameter ranges each `voiceParam` clamps to.
