# Simulator & Audition Loop

The **audition loop** plays the same MPE pipeline an iPad would, driven
from a JSON score dropped into a watched folder. It exists so sound
design can be iterated without an iPad in the loop — an external tool (a
script, a Claude session) drops a JSON score and gets back a recorded
WAV, enabling fully-autonomous parameter sweeps and target-matching
loops. (The on-screen **Simulator tab was removed** in the 2026-07-23
simplification; `IPadSimulator` + `AuditionRunner` remain **headless**.)

This page covers:

- [The headless simulator](#the-headless-simulator)
- [The audition loop](#the-audition-loop)
- [Audition score format](#audition-score-format)
- [Tools](#tools)
- [Reverse-engineering a target WAV](#reverse-engineering-a-target-wav)

## The headless simulator

A Mac-side host for an [iPad-equivalent `NoteManager`](architecture.md)
with mocked sensors. The same touch → glide → MPE pipeline the iPad uses
runs here, but tilts come from `tilt` events and "strike velocity" from
`strike` events instead of an accelerometer spike. Emitted MPE bytes
never touch CoreMIDI — they're delivered in-process to
`AudioEngine.sendHostedMIDI(...)` (→ the String voice) and `AppController`
CC handling, so the simulator coexists cleanly with a real iPad plugged
in over USB (no double-triggering).

The wiring lives in:

- [`TarabdaarMac/IPadSimulator.swift`](../TarabdaarMac/IPadSimulator.swift) — owns the `NoteManager`, `MockMotionSource`, and the in-process `MIDIEngine` (constructed with `publishToCoreMIDI: false`)
- [`TarabdaarMac/MockMotionSource.swift`](../TarabdaarMac/MockMotionSource.swift) — `MotionSource` shim with tilt/strike-force properties

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

1. `TARABDAAR_AUDITIONS_DIR` env var (overrides everything)
2. `<repo>/auditions/` discovered via `#filePath` (developer debug
   builds; the source file location is meaningful)
3. `~/Library/Application Support/Tarabdaar/Auditions/` (last-resort
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
| `voiceParam` | `at`, `param`, `value`            | Set a Mac-side String-voice parameter — see the table below. |
| `rawNote`    | `at`, `note`, `id?`, `value?`     | Raw MIDI note-on straight to the String voice, **bypassing the NoteManager** (no glide, no tilt-CC emission) — a dead-steady pitch for sound-matching. `id` = MIDI channel (1–15, default 1), `value` = velocity (default 90). |
| `rawNoteOff` | `at`, `note`, `id?`               | Raw MIDI note-off (matching channel). |
| `padOn` / `padGlide` / `padOff` | `at`, `id`, `value` | Drive the Mac playing engine (`controller.pitchPad`) — `value` = ratio vs the tonic (default 1.0). `padGlide` sends a real pitch bend to a new ratio; `padOff` releases. Use these (not `noteOn`/`glide`, which take the legacy NoteManager keyboard path that emits no bend headless) to exercise pitch bends / meend. |

**Why `rawNote`:** `simulator.noteOn` routes through the iPad `NoteManager`, whose
60 Hz loop runs the glide engine and per-tick pitch-bend re-emission. For matching a
steady reference, `rawNote` skips all of that and sends a fixed Note On + bend
straight to the String voice.

### `voiceParam` names

The setters clamp values into the same ranges as the UI sliders.

| Name                  | Range            | Effect |
|-----------------------|------------------|--------|
| `param.<key>` / `string.<key>` | per-key | **Any** parameter in `ParamRegistry` — e.g. `param.bow_jt_gain`, `param.bow_rev_mix`, `param.bow_vib_cents`. Both prefixes are equivalent (`string.` is the historical spelling). Routed through `AppController.setParamValue`, the same path the Parameters-tab sliders take, so a sweep shows in the UI and persists; `live`/`hybrid` keys apply instantly, `rebuild` keys ride a debounced engine rebuild. A key the registry doesn't know still lands as a raw artifact override. See [parameters.md](parameters.md). |
| `drone1`..`drone3`    | press/release    | Press (`>0.5`) / release a Fret Pad drone (jawari-taraf row). |
| `stringPurity`        | 0..1             | Taraf purity axis (composite slot 1: full buzzy chorus → clean kin — sweeps the jawari tone LP `bow_jt_lp` down from open AND recruitment profile `bow_jt_sel` 0.5→0, from the fitted taraf down to the played note's harmonic kin at held loudness). Runtime, no rebuild. |
| `stringTarafDecay`    | 0..1             | Taraf decay axis (composite slot 2: natural → choked). |
| `stringToneTilt`      | -1..1            | Tone tilt axis (composite slot 3: bass → treble). |
| `composite1`..`composite8` | 0..1        | Generic composite-parameter slots (the named 0–1 controls in the Controls tab). |

### Minimal examples

A single note:

```json
{"name":"note","tailSeconds":1,"events":[
  {"at":0.0,"kind":"padOn","id":1,"value":1.0},
  {"at":1.0,"kind":"padOff","id":1}
]}
```

A glide with a tilt-driven taraf-purity sweep:

```json
{"name":"swell","tailSeconds":2,"events":[
  {"at":0.0,"kind":"voiceParam","param":"stringPurity","value":0.2},
  {"at":0.0,"kind":"padOn","id":1,"value":1.0},
  {"at":0.5,"kind":"voiceParam","param":"stringPurity","value":0.9},
  {"at":1.0,"kind":"padGlide","id":1,"value":1.2599},
  {"at":2.0,"kind":"padOff","id":1}
]}
```

A physics sweep — render once for each brightness setting:

```json
{"name":"sweep","tailSeconds":3,"events":[
  {"at":0.0,"kind":"voiceParam","param":"string.bow_rev_mix","value":0.2},
  {"at":0.0,"kind":"padOn","id":1,"value":1.0},
  {"at":1.0,"kind":"padOff","id":1}
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
   taraf sub-octaves don't fool the pitch tracker.
4. Note duration: release when the envelope decays past 40 % of the
   local peak, clamped to 150–600 ms (bowed-attack realism).
5. `tailSeconds` sized so the rendered file matches the target's
   total duration exactly.

The first detected note's RMS sets a `tilt1` value (mapped to the
expression axis by default → the voice responds to that as loudness).

Output to stdout, or `--out <path.json>` to write atomically.

### `audition_compare.py <target.wav> [candidate.wav]`

Reports duration, peak, RMS, per-100ms RMS envelope and autocorr
pitch trace for each file, plus (when both are given) envelope L1
distance, voiced-window count, and mean per-window semitone error.

Both files share the same pitch tracker — so when the candidate's
pitch trace matches the target's pattern (even where both are
biased to a sub-octave by the taraf ring tail), the rendering is faithful.

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
2. Make sure TarabdaarMac is running, with the preset and voice
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
- Pitch class (within an octave for the played voice; taraf-tail
  sub-octaves get folded back via the `≤ G3` filter)
- Onset timing (typically within 100 ms of the target)
- Overall loudness (within ~3 dB of target peak)

What it doesn't do yet:

- Per-note expression curves (tilt sweeps mid-note)
- Physics-parameter sweeps to match a particular tail character
- Pitch detection above the taraf sub-octave bias when the played
  note is itself ≤ G3 (the `≤ G3` filter would discard the truth)

See [`architecture.md`](architecture.md) for how the simulator fits
into the broader Mac/iPad split, and [`config-reference.md`](config-reference.md)
for the underlying parameter ranges each `voiceParam` clamps to.
