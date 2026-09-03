# Simulator & Audition Loop

The **audition loop** plays the Mac's own playing pipeline from a JSON
score dropped into a watched folder and hands back a recorded WAV, so
sound design can be iterated without an iPad in the loop — a script or a
Claude session drops a score, gets a WAV, and runs autonomous parameter
sweeps and target-matching loops. It is headless: `IPadSimulator` +
`AuditionRunner` have no on-screen tab (not present — see docs/history/).

## The headless simulator

[`IPadSimulator`](../TarabdaarMac/IPadSimulator.swift) hosts an
iPad-equivalent [`NoteManager`](architecture.md) with mocked sensors
([`MockMotionSource`](../TarabdaarMac/MockMotionSource.swift): tilts
from `tilt` events, strike velocity from `strike` events) and an
in-process `MIDIEngine` (`publishToCoreMIDI: false`) — emitted MIDI goes
to `AudioEngine.sendHostedMIDI(...)` and `AppController` CC handling,
never CoreMIDI, so the simulator coexists with a real iPad on the link.
The `pad*` events instead drive the Mac's own `PitchPadEngine` — the
touch path the Fret Pad and the wire use, through the
[Glide Queue](glide-system.md). The score model and `AuditionRunner`
live in [`AuditionScore.swift`](../TarabdaarMac/AuditionScore.swift).

## The audition loop

`AuditionRunner` watches `<repo>/auditions/inbox/` for `*.json` scores.
For each new score it waits for the file size to be stable across two
stats (a guard against truncate-then-fill writers), parses it into
`AuditionScore`, calls `simulator.panic()` and zeroes the tilts, starts
recording to `<repo>/auditions/outputs/<name>.wav`, fires the events,
panics and stops recording at `max(event.at) + tailSeconds`, and writes
a `.done` JSON marker (or `.error` on parse/render failure) beside the
score for an external watcher to synchronize on. The `.done` carries
`framesWritten`, so a silent capture failure is visible — **always
check it**.

Events fire from a dedicated high-QoS scheduler thread that sleeps to
each event's wall-clock offset: the MIDI-only kinds (`rawNote`,
`rawNoteOff`, `rawBend`, `cc`) go straight to the voice off-main, the
rest hop to main. The app renders in **realtime** through the device
path, so a render takes as long as the score; check the overrun watchdog
log as well as the WAV.

**Recording.** `startRecording` taps `mainMixerNode` into a
pre-allocated interleaved Int16 buffer (no audio-thread allocation);
`stopRecording` writes a complete 16-bit-stereo WAV with its own header,
synchronously, before the `.done`. It does **not** stream to
`AVAudioFile`, whose incremental writer drops the unflushed tail on
dispose. Capacity ~120 s of stereo; overflow is flagged in the `.done`.

The audition root resolves as `TARABDAAR_AUDITIONS_DIR` (env var,
overrides everything), else `<repo>/auditions/` discovered via
`#filePath` (developer builds), else
`~/Library/Application Support/Tarabdaar/Auditions/`.

**Writers must use atomic writes**: write `<name>.json.tmp`, then `mv`
into place. `tools/audition_iterate.py` does this; a bash
`cat > foo.json <<EOF` heredoc does NOT and occasionally races the
size-stable check.

## Audition score format

A score is `{"name", "tailSeconds", "events": [...]}`:

| Top-level | Notes |
|-----------|-------|
| `name`    | Optional. Output WAV filename; defaults to the score's filename stem. |
| `tailSeconds` | Seconds of recording after the last event (default 2). Total render = `max(event.at) + tailSeconds`. |
| `events`  | Time-tagged event list (next section). |

### Event kinds

| `kind`       | Fields                            | Effect |
|--------------|-----------------------------------|--------|
| `padOn` / `padGlide` / `padOff` | `at`, `id`, `value` | Drive the Mac playing engine (`controller.pitchPad`) on the selected main instrument — `value` = ratio vs the tonic (default 1.0). `padGlide` retunes the held touch to a new ratio; `padOff` releases. **Use these for pitch bends / meend** — they take the real touch path (fresh-string law, Glide Queue, strike velocity). |
| `noteOn`     | `at`, `id`, `note`, `keyY?`       | Begin a note through the legacy `NoteManager` keyboard path. `id` = your touch identifier (any int; reuse it in `noteOff`), `note` = MIDI number, `keyY` ∈ [0, 1] vertical finger position (default 0.5). Emits no bend headless. |
| `noteOff`    | `at`, `id`                        | Release the note with the matching id. |
| `glide`      | `at`, `id`, `note`, `keyY?`       | Move a held `noteOn` note to a new pitch via the legacy drag-glide system. |
| `tilt`       | `at`, `axis`, `value`             | Set a tilt axis. `axis` ∈ {0, 1, 2}, `value` ∈ [−1, +1]. Drives whatever the Mac's tilt mapping binds to that axis. |
| `slider`     | `at`, `index`, `value`            | Set on-screen slider1/slider2. `index` ∈ {0, 1}, `value` ∈ [0, 1]. |
| `strike`     | `at`, `value`                     | Set `MockMotionSource.strikeForce` (peak-G driving the velocity LUT). 0.1 ≈ v75; 0.5 ≈ v127. |
| `voiceParam` | `at`, `param`, `value`            | Set a Mac-side parameter — see the table below. |
| `rawNote`    | `at`, `note`, `id?`, `value?`     | Raw MIDI note-on straight to the String voice, bypassing `NoteManager` (no glide, no tilt CCs) — a dead-steady pitch for sound-matching. `id` = MIDI channel (1–15, default 1), `value` = velocity (default 90). |
| `rawNoteOff` | `at`, `note`, `id?`               | Raw MIDI note-off (matching channel). |
| `rawBend`    | `at`, `id?`, `value`              | Raw 14-bit pitch bend on channel `id`; `value` in semitones over a ±2 st range. Dropped unless the channel has an active note — send it AFTER the `rawNote`. Pair with a `rawNote` at the nearest semitone for microtonal pitches. |
| `cc`         | `at`, `cc`, `value`               | A MIDI CC (`cc` number, `value` 0–127) sent on every channel — e.g. 11 = expression. |

An unknown `kind` logs and is ignored.

### `voiceParam` names

Values are clamped into the same ranges as the UI sliders.

| Name                  | Range            | Effect |
|-----------------------|------------------|--------|
| `param.<key>` / `string.<key>` | per-key | **Any** parameter in `ParamRegistry` — e.g. `param.bow_jt_gain`, `param.bow_rev_mix`. The prefixes are equivalent (`string.` is the historical spelling). Routed through `AppController.setParamValue`, the same path the Parameters-tab sliders take, so a sweep shows in the UI and persists; `live`/`hybrid` keys apply instantly, `rebuild` keys ride a debounced engine rebuild. A key the registry doesn't know lands as a raw artifact override. See [parameters.md](parameters.md). |
| `instrument`          | 0 / 1 / 2        | Main instrument: 0 = String, 1 = Tanpura, 2 = Sitar. The sitar arms + builds on its first switch — give the score a few seconds before its first note. |
| `drone1`..`drone3`    | press/release    | Press (`>0.5`) / release a Fret Pad drone. |
| `strum`               | press/release    | The controller strum (the Joy-Con L path): `>0.5` sounds the held main-voice chord, `≤0.5` releases it — a score must send both edges. |
| `chord`               | degree / −1      | Select the chord bar's chord for the strum: value = the degree index (octave 0), negative = deselect (fall back to the configured strum set). See [fret-pad.md](fret-pad.md). |
| `stringPurity`        | 0..1             | Composite slot 1 (taraf purity: buzzy chorus → clean kin — `bow_jt_lp` down from open AND `bow_jt_sel` 0.5→0). Runtime, no rebuild. |
| `stringTarafDecay`    | 0..1             | Composite slot 2 (taraf decay: natural → choked). |
| `stringToneTilt`      | −1..1            | Composite slot 3 (tone tilt: bass → treble). |
| `composite1`..`composite8` | 0..1        | Generic composite slots (the named 0–1 controls in the Controls tab). |

### Example

A note, a meend and a taraf-purity sweep (a physics sweep is the same
shape with `"param":"param.bow_rev_mix"`, rendered once per setting):

```json
{"name":"swell","tailSeconds":2,"events":[
  {"at":0.0,"kind":"voiceParam","param":"stringPurity","value":0.2},
  {"at":0.0,"kind":"padOn","id":1,"value":1.0},
  {"at":0.5,"kind":"voiceParam","param":"stringPurity","value":0.9},
  {"at":1.0,"kind":"padGlide","id":1,"value":1.2599},
  {"at":2.0,"kind":"padOff","id":1}
]}
```

**Traps.** One `padGlide` jump is a snap — a meend needs stepped glides.
Headless sessions share the running app's UserDefaults, so restore every
`param.*` key a score probes. Always render a control score too.

## Tools

Three scripts in [`tools/`](../tools/) (Python 3 + numpy/scipy):

- **`audition_analyze.py <target.wav>`** — a first-pass score: RMS
  envelope (50 ms hop, 150 ms box); onsets via `scipy.signal.find_peaks`
  (prominence ≥ 15 % of global peak, distance ≥ 250 ms, backtracked to
  the 60 % crossing); autocorrelation pitch over the 250 ms after each
  onset with readings ≤ MIDI 55 (G3) dropped so taraf sub-octaves don't
  fool the vote; release at 40 % of the local peak, clamped to
  150–600 ms; `tailSeconds` matched to the target's duration; the first
  note's RMS sets a `tilt1` (the expression axis by default). Stdout, or
  `--out <path.json>` (atomic).
- **`audition_compare.py <target.wav> [candidate.wav]`** — duration,
  peak, RMS, per-100 ms RMS envelope and pitch trace per file, plus
  envelope L1 distance, voiced-window count and mean per-window semitone
  error. Both files share the pitch tracker, so a matching pitch
  *pattern* means a faithful render even where both read a taraf
  sub-octave.
- **`audition_iterate.py <target.wav>`** — analyze → render → compare →
  amplitude refine (global tilt/strike only), up to 6 passes, stopping
  when the candidate peak is within ±15 % of the target's; writes
  `auditions/best.json` and `auditions/outputs/best.wav`.

## Reverse-engineering a target WAV

Put the target at `auditions/target.wav` (16-bit stereo; the Mac
records at 48 kHz), run TarabdaarMac with the preset the target was made
with (or set parameters via `voiceParam` events at the head of the
score), run `python3 tools/audition_iterate.py auditions/target.wav`,
and listen to `auditions/outputs/best.wav` against the target. If the
analyzer miscounts notes, tweak `--hop-ms` / `--pitch-win-ms`, or
hand-edit `best.json` and re-render by dropping it into `inbox/`. The
pipeline lands note count (±1 for clear phrases), pitch class (within an
octave), onset timing (~100 ms) and loudness (~3 dB); it does not do
per-note expression curves, physics sweeps to match a tail character,
or pitch detection for played notes ≤ G3 (the sub-octave filter would
discard the truth).

See [architecture.md](architecture.md) for how the simulator fits the
Mac/iPad split, and [config-reference.md](config-reference.md) for the
ranges each `voiceParam` clamps to.
