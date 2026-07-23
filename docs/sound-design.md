# Sound Design

Sound design lives entirely on the Mac (StarpadMac). The iPad is a MIDI controller and produces no audio. The Mac receives MPE over USB and routes it to the selected **base voice** — by default the **fitted sarangi source** (`SarangiKit.ViolinSynth` playing `sarangi_model_v57.json`), alternatively a hosted **SWAM** Solo Strings AU (run **dry**) or the sitar model — whose audio feeds the **sarangi chain** (`SarangiKit.SarangiEngine`): a complete pure-Swift DSP package producing the full sarangi as one **passive coupled bridge–body network** — the played strings + the taraf web loading a shared bridge, a modal body with real interference antiresonances, the direct taraf-velocity tap, and the fitted radiation FIR — plus Starpad's 2-stage **FX rack** (default off). The model **is** the played voice. A separate **tanpura/sitar** layer (`StarpadDSP.TanpuraModel`) runs alongside through the shared master FX (their Room).

## Signal path

The base voice feeds `hostedDriveTap`: the **sarangi model source** as its own
48 kHz `AVAudioSourceNode` (default), or N × dry SWAM AU instances (SWAM's
internal room/reverb/ambience/body off in `hostedAUParams` — the chain needs a
clean input), or the sitar rendered in-block. The chain is rendered **inline**
by the `SarangiProcessorAU` effect and owns its own body (the coupled
network's modal body + radiation FIR), room, and FX rack, so its output goes
**straight to `mainMixerNode`, bypassing** the shared master filter / reverb /
`postReverbEQ` (those now process only the tanpura + sitar). See
[sarangi.md](sarangi.md).

```
MPE in ► base voice (model source 48k │ N × SWAM AU dry) ► hostedDriveTap ► SarangiProcessorAU ► symGain ───────────► mainMixerNode ► out
                                                             (sums, SRC)     (beginBuffer + SarangiEngine.renderSample —        ▲
                                                                              the passive coupled network + FX rack)            │
                                                                                                                               │
   tanpura/sitar ──► gains ──► preReverbMixer ► masterFilter ► reverb ► postReverbEQ ──────────────────────────────────────────┘
```

`SarangiProcessorAU` is a custom in-process AUv3 effect (`Packages/StarpadCore/.../SarangiProcessorAU.swift`) spliced right after `hostedDriveTap`. Its `internalRenderBlock` pulls the summed drive stereo synchronously into a private scratch buffer, forms a mono drive `0.5·(L+R)` (lifted by `sarangiDriveGain`), calls `engine.beginBuffer()` once, and runs `SarangiEngine.renderSample(input)` per sample — all in the **same engine pull**, so it adds **~0 ms latency**. (It replaced an earlier `installTap(4096)` → `SPSCAudioRing` → separate source-node transport that added ~140 ms.)

- **Played voice.** The sarangi chain, fed by the selected base voice. The **model source** is monophonic (held-note stack with fitted legato glides — the sarangi is a bowed single line); SWAM polyphony comes from `N = Config.maxHostedPolyVoices` parallel instances round-robining MPE channels. See [MIDI & Audio — Polyphonic hosted-AU model](midi-and-audio.md#polyphonic-hosted-au-model).
- **Sarangi model.** `Packages/SarangiKit/Sources/SarangiKit/DSP/SarangiEngine.swift` (+ the source in `Violin/`). The passive coupled network (see below) takes the dry source and produces the full stereo sarangi. Editable Mac-side via `SarangiStore` (raga + tonic + the sympathetic-string table + the 22 model parameters + the FX rack). See [sarangi.md](sarangi.md) for the full treatment.
- **Tanpura + sitar.** `StarpadDSP.TanpuraModel` runs on its own source nodes (`tanpuraSource`/`sitarSource → preReverbMixer`), riding the shared master FX and the audition recording tap. Unchanged by the sarangi rework. See [tanpura.md](tanpura.md) / [sitar.md](sitar.md).
- **Master FX (tanpura/sitar Room).** `AVAudioUnitEQ` (one band, resonant low-pass) → `AVAudioUnitReverb` (`.mediumHall`) → a 3-band `postReverbEQ`. The sarangi bypasses this whole chain (it has its own per-voice FX rack), so the master FX now shape only the tanpura/sitar tail (and the controls moved to the Tanpura tab's "Room" section).

## The sarangi model — the passive coupled network

`SarangiEngine.renderSample(input)` (after `beginBuffer()` once per buffer) is
the live twin of the offline v57 coupled model (`coupled.junction_solve`,
parity ≤ 1e-9). `input` is the dry mono voice (`0.5·(L+R)`); there is no
separate amplitude envelope — the network is driven purely by the audio. The
pieces:

- **The junction.** Every string loads ONE shared bridge with impedance `Z_in = Z(1+G)/(1−G)`; the bridge velocity is solved **delay-free per sample** (`V = (Vst + y0·F0)/(1 + y0·ΣZ)` — structurally stable, no guard). Per-string impedances follow the live bank gains (`B_gain` cancels within a choir — the offline law).
- **Played strings.** The drive excites the bridge directly (`pGain`·LP) plus **3 open-tuned played combs** (Sa / Pa / low Sa at the engine tonic).
- **The taraf web.** ~39 strings → **polarization doublets** (`B_pol_*`, each string's two transverse modes a few cents apart), fractional-delay **web combs** with stiff-wire dispersion (`B_inharm`), in-loop f² damping (`B_damp`), and the in-loop HF roll-off `B_lp`.
- **The modal body** (`BodyAdmittance`). One modal bank with two residue taps: the bridge **admittance** (what loads and re-excites the strings) and the **radiation** (what you hear; signed residues ⇒ real antiresonances). **`WModalBank`** radiates the stereo **side** channel from the per-string pans (`B_spread`) — mono-sum-invariant.
- **The direct taraf tap** (`N_taraf_dir`/`N_taraf_dir_lp`). The taraf strings' own weighted velocity reaching the ear past the body's W — the string-Q-sharp ring the Q≤12 modal radiation can't carry.
- **Radiation FIR + `E_lp`.** The fitted radiation FIR ships inside `sarangi_coupled.json` at both 44.1 kHz and 48 kHz (no Starpad-side bakes), followed by the `E_lp` radiation low-pass.
- **Drone + room.** Both playable but **fitted to 0** (`mix_drone` 0, `F_mix` 0 — "the ringing taraf is the room").
- **Output user EQ** (`VoiceEQBand`) — default **FLAT** (the fitted W valley superseded the old de-horn cuts). Starpad's **FX rack** (2 stages: `violinPre` pre-drive + `global` mid/side output, each filter + EQ + reverb) sits on top — **both OFF by default**.

The engine **requires** the bundled `sarangi_coupled.json` (`N_junction
"passive"`); unarmed it renders silence. Stereo comes from the per-string pans
(the mono sum equals the mono chain). There are **22 model parameters**
(`ParamSpec.all`, grouped Bank / Drone / Body / Reverb / Mix — see
[Config Reference](config-reference.md#sarangi-model-mac)); each is either
**structural** (rebuilds the engine's filter coefficients off-thread) or a **live
scalar** (a gain/mix the render thread reads lock-free). The FX rack is separate
state (`FXRack` on `InstrumentState.fx`, edited in the FX tab). **One fitted
preset** ships — **sarangi_pilu** (the v57 Pilu-session fit; pair with the
model base voice) — a params JSON plus the **exact offline string table**
(`Presets`, bundled resources).

## Sympathetic strings — the editable bank

The sympathetic taraf bank is a **fully editable `[StringSpec]` table** — each
row a `(freq, gain, t60, bright, enabled, group)` web-comb string — owned Mac-side
by `SarangiStore` in `InstrumentState` and edited in the **Tarab tab (⌘4)**. **By
default it auto-tunes to the Pitch Pad scale** (`autoSyncToScale`); a hand edit /
choir toggle / raga pick detaches it for manual tuning. See
[sarangi.md](sarangi.md#sympathetic-strings-the-tarab-tab-4).

The bank is generated for a chosen **raga + tonic** by `RagaTuning.buildStrings`
(JI ratios, a four-choir layout: 15 chromatic, the scale degrees with Sa/Pa
doubling, a low choir, and 6 upper-octave strings, all with seeded ±cents
detune). Three ragas ship — **E♭ harmonic minor**, **Bhairav**, and **Pilu**
(the fitted 9-note thumri scale) — and the table is open to extend. Picking a
raga resets the tonic to its hint and regenerates the bank; the tonic can be set
by Hz or note name (e.g. `Eb4`). Editing any row, adding/removing strings, or
changing raga/tonic triggers a (debounced) structural rebuild of the engine.
`regenerate()` rebuilds from raga + tonic (discarding manual edits); `transpose`
scales every string frequency to a new tonic while keeping manual edits.
**Caveat:** any regeneration (including the default scale auto-sync) REPLACES
the fitted preset's exact string table — the offline detunes are PCG64-seeded
and cannot be reproduced by the Swift RNG, and the exact table audibly matters
(the string-table law) — so turn auto-sync off to keep the fit exact. Full
detail: [sarangi.md](sarangi.md).

### The preset

The single fitted preset (`sarangi_pilu`) reproduces the complete offline v57
match: raga Pilu + Sa 328.9 Hz, the **exact offline string table**
(`sarangi_pilu_strings.json`), and the fitted parameter values — so the live
model matches the offline render out of the box. Pair it with the **Sarangi
(model)** base voice. The whole `InstrumentState` persists to UserDefaults and
can be exported/imported as a `.sarangi` JSON file.

## Tanpura drone (the actual instrument)

StarpadMac also has a **playable tanpura** — four harmonic-resolved modeled strings on the Tanpura tab, matched against a real recording by an autonomous measurement/optimization loop. Each harmonic of each string (up to 64) is synthesized individually with its own bloom envelope (gain, peak time, decay — per-harmonic editable in the UI), which is what produces the signature jawari cascade where harmonics peak at different times; a per-string half-integer sub-bank (`subLevelDB`) adds the bridge's period-2 partials at `(k+0.5)·f0`, which the reference recording carries at surprisingly high level. Full model, parameter, and matching-pipeline documentation: [tanpura.md](tanpura.md).

## Liveness

Sympathetic strings without movement sound static. The sarangi model's life is structural, not LFO-driven: the **taraf web's strings beating against each other** (seeded ±cents detune **plus** each string's polarization doublet), **true bridge coupling** (every string loads and re-excites every other through the shared passive junction — physics, not a mixed-in effect), and — on the model source — the fitted **voice↔taraf coupling** (`SympatheticWeb`/`SourceFMBank`: the wash the voice excites interferes with and modulates the voice itself). The Bank parameters (see [Config Reference](config-reference.md#sarangi-model-mac)) shape all of it.

## Master FX (the tanpura/sitar Room)

The master filter + reverb + `postReverbEQ` now shape **only the tanpura/sitar tail** — the sarangi owns its own body (the coupled network's modal body + radiation FIR) + FX rack and bypasses this chain entirely. The controls live on the **Tanpura tab** (the "Room (tanpura + sitar)" section).

| Parameter | Range | Description |
|---|---|---|
| `reverbMix` | 0–100 % | Wet/dry mix of `AVAudioUnitReverb(.mediumHall)`. Wraps the tanpura/sitar bus. |
| `filterCutoff` | 20–20000 Hz | `AVAudioUnitEQ` band, type `.resonantLowPass`. Default 18 kHz keeps the filter open; lower values darken the tanpura/sitar. |
| `filterResonance` | 0–1 | Maps onto the EQ band's bandwidth (0 → 4 octaves wide, 1 → 0.1 octaves wide, i.e. sharp resonant peak). |

## Hosted-AU integration

The hosted instrument is identified by a 3-tuple `(type, subType, manufacturer)` on `SoundPreset.State.hostedAudioUnit`, run **dry** (its internal room/reverb/ambience/body off in `hostedAUParams`, since the sarangi model needs a clean bowed input).

- **Base-voice selection (Setup tab).** Which voice feeds the model is the user's choice, surfaced as the "Base voice" picker in the Setup tab's Audio section (`AppController.baseVoice`, the flat `BaseVoice` enum in `StarpadMac/SoundPreset.swift`, persisted to `starpad.baseVoice`; migrates the older `starpad.hostedInstrument` key; fresh installs default to the sarangi model). Six options:
  - **Four SWAM Solo Strings 3 voices** — Violin `Svl3`, Viola `Sva3`, Cello `Sce3`, Double Bass `Sdb3` (all `("aumu", …, "AuMo")`; subTypes verified with `auval -a`). **The four share the AU parameter layout**, so the preset's dry `hostedAUParams` (bow timbre + room/body off) and the captured CC-assignment blob apply unchanged — switching only swaps the component subType, and the params/state already installed in the engine re-apply to the new slots on attach. Default is Violin (the voice the model was fitted against).
  - **Our sitar model** (`.sitar`) — instead of a SWAM AU, the plucked sitar (`TanpuraParams.sitar`) becomes the excitation. `AudioEngine` owns a dedicated `voiceSitar` (`TanpuraModel`, separate from the Sitar tab's `sitar`) that is rendered **inside the sarangi process block** and drives `renderSample` in SWAM's place (SWAM is unloaded); the coupled bridge / taraf web / modal body / FX then color the plucked sitar. Incoming notes drive it through `routeSitarBaseVoiceMIDI` (a note→pluck bridge on the shared MIDI choke point `sendHostedMIDI`): each Note On plucks a pooled string (4 strings, round-robin/steal) tuned to the note, **pitch bend glides** the string continuously (cheap `TanpuraModel.retuneString`), and Note Off frees the string to ring out. The sitar timbre stays in step with the Sitar tab (`AppController.sitarParams` pushes to `voiceSitar` when it's the base voice). **Level:** the sitar model's raw output is far quieter than SWAM's, and `sarangiDriveGain` (default 1.0) is calibrated for SWAM — so the base-voice sitar gets its own **+18 dB makeup** (`AudioEngine.sitarBaseVoiceMakeup`, matching the Sitar tab's `sitarGainDB`) applied to its drive, or it under-drives the model to near-silence at the default drive. This is why it plays through any pad (Pitch / Chord / **String**) — all three emit through the same `sendHostedMIDI` bridge.
  - **The fitted sarangi source** (`.sarangiModel`, the default) — the `SarangiKit.ViolinSynth` playing `sarangi_model_v57.json` as its own 48 kHz source node feeding `hostedDriveTap` (SWAM is unloaded). Monophonic with fitted legato glides + MPE bend tracking (`routeSarangiModelMIDI` → `SarangiModelVoiceControl`); expr/press/pos/tilt ride CC11/CC1/CC74/CC2-or-75 (Setup-tab sliders idle at the fitted operating point, and the Mac pads' flat per-note CC11 drops to 32 ≈ the fitted expr median for this voice). See [sarangi.md](sarangi.md#the-source-model-violin-the-sarangi-model-base-voice).
  The preset's `State.hostedAudioUnit` only gates *whether* a hosted AU is used at all (`nil` ⇒ unload); the *which* comes from `baseVoice`, applied by `AppController.applyBaseVoice` (called from `applyPreset` and the picker's `didSet`). Scriptable from an audition score via `voiceParam` `baseVoice` (0=Violin, 1=Viola, 2=Cello, 3=Double Bass, 4=sitar, 5=sarangi model).

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

1. **More fitted ragas** — extend `RagaTuning.ragas` and ship additional fitted presets (params + exact string tables) for more ragas/tonics; only Pilu has a fitted table today.
2. **More hosted-AU presets** — drop additional `SoundPreset` cases pointing at other AU instruments (SWAM French Horn, Pianoteq, etc.).

### Production polish

3. **String-table editing UX** — bulk operations (transpose a selection, mute a choir, copy a string) in the Sarangi tab's string table.

### Bigger changes

4. **Live param sweeps via audition** — the autonomous loop can already sweep the 22 model params (`sarangi.<paramId>` voiceParams) and the FX rack (`sarangi.fx.<stage>.<field>`). Wire a CMA-ES match against bowed refs through the running app, the way the tanpura/sitar are matched.
