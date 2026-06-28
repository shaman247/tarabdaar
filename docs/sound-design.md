# Sound Design

Sound design lives entirely on the Mac (StarpadMac). The iPad is a MIDI controller and produces no audio. The Mac receives MPE over USB, forwards every byte to a hosted Audio Unit (**SWAM Violin**, run **dry**), and feeds that dry violin audio into the **sarangi model** (`SarangiKit`) — a complete pure-Swift DSP package that turns the bowed violin into a full sarangi: a sympathetic-string choir, a jawari bridge buzz, a measured instrument body, and a per-voice **FX rack** (filter + EQ + reverb). The model **is** the played voice (it replaces the dry violin, not a halo on top of it). A separate **tanpura/sitar** layer (`StarpadDSP.TanpuraModel`) runs alongside through the shared master FX (their Room).

## Signal path

SWAM runs **dry** (its internal room/reverb/ambience/body are off in
`hostedAUParams`) because the sarangi model requires a clean violin input. The
model is rendered **inline** by the `SarangiProcessorAU` effect and owns its own
body (block E) + a per-voice **FX rack** (filter + EQ + reverb, replacing the old
block-F Freeverb), so its output goes **straight to `mainMixerNode`, bypassing** the
shared master filter / reverb / `postReverbEQ` (those now process only the tanpura
+ sitar). See [sarangi.md](sarangi.md).

```
MPE in ► N × SWAM AU(dry) ► hostedDriveTap ► SarangiProcessorAU ► symGain ─────────────────────────────────────────► mainMixerNode ► out
                              (sums poly)     (SignalAmpFollower + SarangiEngine.renderSample —                            ▲
                                               full stereo sarangi: bank+jawari+body, then the per-voice FX rack)         │
                                                                                                                          │
   tanpura/sitar ──► gains ──► preReverbMixer ► masterFilter ► reverb ► postReverbEQ ─────────────────────────────────────┘
```

`SarangiProcessorAU` is a custom in-process AUv3 effect (`Packages/StarpadCore/.../SarangiProcessorAU.swift`) spliced right after `hostedDriveTap`. Its `internalRenderBlock` pulls the summed dry SWAM stereo synchronously into a private scratch buffer, forms a mono drive `0.5·(L+R)` (lifted by `sarangiDriveGain`), computes a 0..1 amplitude envelope with a `SignalAmpFollower`, and runs `SarangiEngine.renderSample(input, amp:)` per sample — all in the **same engine pull** as SWAM, so it adds **~0 ms latency**. (It replaced an earlier `installTap(4096)` → `SPSCAudioRing` → separate source-node transport that added ~140 ms.)

- **Played voice.** The sarangi model, fed by SWAM Violin hosted as `N = Config.maxHostedPolyVoices` parallel `AVAudioUnit` instances. SWAM is monophonic — polyphony comes from running 8 copies and round-robining MPE channels onto them. See [MIDI & Audio — Polyphonic hosted-AU model](midi-and-audio.md#polyphonic-hosted-au-model).
- **Sarangi model.** `Packages/SarangiKit/Sources/SarangiKit/DSP/SarangiEngine.swift`. The block chain (see below) takes the dry violin and produces the full stereo sarangi. Editable Mac-side via `SarangiStore` (raga + tonic + the sympathetic-string table + the 23 model parameters + the per-voice FX rack). See [sarangi.md](sarangi.md) for the full treatment.
- **Tanpura + sitar.** `StarpadDSP.TanpuraModel` runs on its own source nodes (`tanpuraSource`/`sitarSource → preReverbMixer`), riding the shared master FX and the audition recording tap. Unchanged by the sarangi rework. See [tanpura.md](tanpura.md) / [sitar.md](sitar.md).
- **Master FX (tanpura/sitar Room).** `AVAudioUnitEQ` (one band, resonant low-pass) → `AVAudioUnitReverb` (`.mediumHall`) → a 3-band `postReverbEQ`. The sarangi bypasses this whole chain (it has its own per-voice FX rack), so the master FX now shape only the tanpura/sitar tail (and the controls moved to the Tanpura tab's "Room" section).

## The sarangi model — the block chain

`SarangiEngine.renderSample(input, amp:)` is a 1:1 Swift port of a standalone
Python model (`chain.process`). `input` is the dry mono violin (`0.5·(L+R)`);
`amp ∈ [0,1]` is the note's amplitude envelope (live: a `SignalAmpFollower` on the
drive) which drives the jawari swell. The blocks:

- **A — Body pre-EQ.** Dry/body shaping on the violin branch.
- **B — Sympathetic bank.** 37 **Karplus-Strong comb strings** in two choirs (a clean JI-chromatic row plus a brighter raga-tuned diatonic/octave set), JI-tuned with a seeded ±cents chorus detune (`RagaTuning.buildStrings`). This is the editable string table (see below).
- **C — Jawari exciter.** The bridge "buzz": a 4× oversampled asymmetric `tanh` shaper plus a downward-sweeping morphing bandpass (`JawariExciter`).
- **D — Drone generator.** *Removed* — the tonic/4 laraj drone became a clipping sub-bass rumble when the sym was boosted, so the block was deleted.
- **E — Body color.** A measured min-phase **body FIR** (1025 taps, per fitted preset) on the dry branch, plus a low shelf and 6 modal body resonances (`BodyColor`, now split into a violin-voice ring and a sym-voice ring).
- **FX rack (was block F).** The model splits its output into a **Violin** voice (dry + jawari) and a **Sym** voice (the bank), applies a per-voice **filter + EQ + reverb** stage to each, sums, then applies a **Global** stage. This replaces the old single block-F Freeverb tank.

The chain is mono internally, going stereo at the FX rack (each stage's reverb is
stereo). There are **23 model parameters** (`ParamSpec.all`, grouped
Bank / Jawari / Body / Reverb (empty — `F_*` removed) / Mix — see
[Config Reference](config-reference.md#sarangi-model-mac)); each is either
**structural** (rebuilds the engine's filter coefficients off-thread) or a **live
scalar** (a gain/mix the render thread reads lock-free). The FX rack is separate
state (`FXRack` on `InstrumentState.fx`, edited in the FX tab). Two fitted presets
ship — **pair1** (E♭ harmonic minor) and **pair2** (Bhairav) — each a `pairN.json`
parameter file plus a `pairN_fir.json` body FIR (`Presets`, bundled resources).

## Sympathetic strings — the editable bank

The sympathetic bank (block B) is a **fully editable `[StringSpec]` table** — each
row a `(freq, gain, t60, bright, enabled)` Karplus-Strong string — owned Mac-side
by `SarangiStore` in `InstrumentState`. **It is independent of the playing (Pitch
Pad) scale** (the old auto-derive-from-scale behaviour was removed): the user tunes
the tarab to the raga directly.

The bank is generated for a chosen **raga + tonic** by `RagaTuning.buildStrings`
(JI ratios, a 37-string layout in four choirs: 15 chromatic, the diatonic mids with
Sa/Pa doubling, a low choir, and 6 upper-octave strings, all with seeded ±cents
detune). Two ragas ship — **E♭ harmonic minor** and **Bhairav** — and the table is
open to extend. Picking a raga resets the tonic to its hint and regenerates the
bank; the tonic can be set by Hz or note name (e.g. `Eb4`). Editing any row,
adding/removing strings, or changing raga/tonic triggers a (debounced) structural
rebuild of the engine. `regenerate()` rebuilds from raga + tonic (discarding
manual edits); `transpose` scales every string frequency to a new tonic while
keeping manual edits. Full detail: [sarangi.md](sarangi.md).

### Presets and the body FIR

A fitted preset (`pair1` / `pair2`) reproduces a complete offline match: its raga
+ tonic, the regenerated string bank, the `pairN.json` parameter values, and the
`pairN_fir.json` block-E body FIR — so the live model matches that pair's offline
render out of the box. `pair1` (E♭ harmonic minor) is the default. The whole
`InstrumentState` persists to UserDefaults and can be exported/imported as a
`.sarangi` JSON file.

## Tanpura drone (the actual instrument)

StarpadMac also has a **playable tanpura** — four harmonic-resolved modeled strings on the Tanpura tab, matched against a real recording by an autonomous measurement/optimization loop. Each harmonic of each string (up to 64) is synthesized individually with its own bloom envelope (gain, peak time, decay — per-harmonic editable in the UI), which is what produces the signature jawari cascade where harmonics peak at different times; a per-string half-integer sub-bank (`subLevelDB`) adds the bridge's period-2 partials at `(k+0.5)·f0`, which the reference recording carries at surprisingly high level. Full model, parameter, and matching-pipeline documentation: [tanpura.md](tanpura.md).

## Liveness

Sympathetic strings without movement sound static. The sarangi model's life comes from two structural sources rather than per-string LFOs: the **37 Karplus-Strong strings beating against each other** (each JI-tuned with a seeded ±cents chorus detune, so neighbours slip in and out of beat), and the **jawari exciter** (block C), whose downward-sweeping morphing bandpass and asymmetric shaper give the buzzy, shimmering bridge character, swelling with the note's `amp` envelope. There is no separate "jiva" parameter group — the bank and jawari parameters (see [Config Reference](config-reference.md#sarangi-model-mac)) shape all of it.

## Master FX (the tanpura/sitar Room)

The master filter + reverb + `postReverbEQ` now shape **only the tanpura/sitar tail** — the sarangi owns its own block-E body + per-voice FX rack and bypasses this chain entirely. The controls live on the **Tanpura tab** (the "Room (tanpura + sitar)" section).

| Parameter | Range | Description |
|---|---|---|
| `reverbMix` | 0–100 % | Wet/dry mix of `AVAudioUnitReverb(.mediumHall)`. Wraps the tanpura/sitar bus. |
| `filterCutoff` | 20–20000 Hz | `AVAudioUnitEQ` band, type `.resonantLowPass`. Default 18 kHz keeps the filter open; lower values darken the tanpura/sitar. |
| `filterResonance` | 0–1 | Maps onto the EQ band's bandwidth (0 → 4 octaves wide, 1 → 0.1 octaves wide, i.e. sharp resonant peak). |

## Hosted-AU integration

The hosted instrument is identified by a 3-tuple `(type, subType, manufacturer)` on `SoundPreset.State.hostedAudioUnit`. The current preset uses `("aumu", "Svl3", "AuMo")` for SWAM Violin 3, run **dry** (its internal room/reverb/ambience/body off in `hostedAUParams`, since the sarangi model needs a clean violin input).

- `AudioEngine.loadHostedInstrument` instantiates `Config.maxHostedPolyVoices` copies in parallel and wires each into the graph at the `hostedDriveTap` mixer (whose summed output is pulled inline by the `SarangiProcessorAU` effect — no tap, no ring).
- Every MIDI byte arrives via `MIDIInput` and is forwarded verbatim to the AU's `scheduleMIDIEventBlock`. Per-voice messages route to the channel's bound slot; master-channel and channel-state CCs (CC 121, CC 123, RPN 101/100/6/38) broadcast.
- Edits made via the AU's UI on the primary slot mirror onto every other instance via an `AUParameterTree` observer, so the user only configures one SWAM and polyphonic voices stay consistent.
- **Programmatic AU-parameter control.** `AudioEngine.hostedParameterDump()` enumerates SWAM's full parameter tree (identifier, name, range, value) and `setHostedParameter(identifier:value:)` sets one on every slot. A preset carries its own defaults in `SoundPreset.State.hostedAUParams` (identifier → value), pushed by `AudioEngine.setHostedAUParameterDefaults` and re-applied to each slot on instantiate. This is how the sarangi match drives SWAM's **bow timbre** (Bow Position/Pressure) and zeroes its auto-vibrato. From an audition score: `voiceParam` `swam.<identifier>` sets a value; `voiceParam` `__auDump__` writes `swam_params.json` for discovery. The **Strings Model** default (set to *Virtual Adaptive Resizing (Mono)*) rides this same dictionary (`"960866759": 1.0`).
- **Full-state restore (opaque settings, incl. MIDI CC assignments).** Some SWAM settings are NOT AU parameters and so can't be reached via `hostedAUParams` — most importantly the **per-control MIDI CC mappings** (which incoming CC drives Expression / Vibrato Depth / Bow Pressure / Bow/Pizz Position). These live inside SWAM's opaque encoded `fullStateForDocument` blob. A preset carries that blob in `SoundPreset.State.hostedAUState` (a serialized binary plist), pushed by `AudioEngine.setHostedAUFullState` and restored to each slot in `attachHostedInstance` **before** the `hostedAUParams` pass (so the params we tune in code still win; the blob supplies only the opaque routing). The blob can't be authored from code — it must be **captured** from a hand-configured SWAM: assign the CCs in SWAM's MIDI-mapping UI (open it from the AU-status popover → *Open AU view*), then click **Capture SWAM State** (same popover) → `AppController.captureSwamState()` writes `StarpadMac/SwamDefaultState.swift` (base64 of the blob); rebuild to bake it in. Empty base64 ⇒ restore is a no-op. Dev/source builds only (the capture writes into the source tree via `#filePath`).
- Clean quit (`⌘Q`) unloads every AU instance; SWAM's licensing daemon needs the explicit release or the next launch sees a stuck token.

See [MIDI & Audio — Hosted AU + sarangi drive](midi-and-audio.md#hosted-au--sarangi-drive) for the full per-slot allocation table and reset sequence.

## Next steps

Candidate additions, ordered by estimated impact-per-effort.

### Quick wins

1. **More fitted ragas** — extend `RagaTuning.ragas` and ship additional `pairN` presets (params + body FIR) for more ragas/tonics.
2. **More hosted-AU presets** — drop additional `SoundPreset` cases pointing at other AU instruments (SWAM French Horn, Pianoteq, etc.).

### Production polish

3. **String-table editing UX** — bulk operations (transpose a selection, mute a choir, copy a string) in the Sarangi tab's string table.

### Bigger changes

4. **Live param sweeps via audition** — the autonomous loop can already sweep the 23 model params (`sarangi.<paramId>` voiceParams) and the FX rack (`sarangi.fx.<stage>.<field>`). Wire a CMA-ES match against bowed refs through the running app, the way the tanpura/sitar are matched.
