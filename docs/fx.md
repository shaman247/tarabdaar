# FX

The **FX tab (⌘6)** is a four-insert effects rack inside the String voice's render path. Each insert point carries an optional **10-band graphic EQ** and an optional **reverb** (**Bigverb**, the default, or **Room**). Everything is **off by default**, and the untouched rack is *byte-null*: `TarafRemovalParityTests` pins the shipped render bit-for-bit with the rack idle.

## The four insert points

In signal order (`SarangiKit.FXPoint`):

| Point | Key prefix | What it processes | Rate |
|---|---|---|---|
| **Voice → Taraf** | `fx_drive_` | The main voice **as the sympathetic strings hear it** — the recorded jt-drive buffer (the junction bridge force), mono. Shapes only the taraf's excitation; the radiated voice is untouched. | kernel (96 kHz) |
| **Voice** | `fx_voice_` | The main voice bus (bridge radiation + bow noise) after the taraf tap, before the shared radiation post-chain. | kernel (96 kHz) |
| **Taraf** | `fx_taraf_` | The modal-jawari web's own radiated output (drones included), same depth. | kernel (96 kHz) |
| **Global** | `fx_global_` | The final stereo L/R, after the whole fitted chain (radiation FIR/LP/HP, hill, tone tilt, calibration room, outGain). | engine (48 kHz) |

EQ on **Voice → Taraf** re-voices *which harmonics recruit the taraf* without changing the played tone; reverb there smears the sympathetic excitation in time. EQ on **Taraf** re-balances the wash against the melody. **Global** is a normal master insert.

## Parameters

**ONE INSERT, FOUR POINTS.** The rack is described once and instantiated
per point: `ParamRegistry.fxTemplate` holds the 16 knobs (keyed by their
FIELD SUFFIX — exactly what `FXSettings.apply(field:value:)` parses),
`ParamRegistry.fxPoints` holds the four points (name, `keyPrefix`, what
each processes), and the registry derives `fx_<point>_<knob>` from the
two. Per point:

- `eq_on`, `eq_b1`…`eq_b10` — octave bands 31.5 Hz…16 kHz, ±12 dB (RBJ peaking, Q ≈ 1.41).
- `rev_on`, `rev_type` (0 = Bigverb, 1 = Room), `rev_mix` (wet level — the dry path always passes at unity, a send), `rev_size`, `rev_cut`.

Every derived knob is an ordinary registry parameter (all `.live`,
`.global`, group "FX rack"), so nothing downstream knows the difference:
`ParamRegistry.all` answers all 64 keys, presets capture them under the
SAME key strings older `.tarabdaar` files carry, tilt bindings and
composites drive them, and auditions reach them via
`param.fx_<point>_<field>`. What the derivation buys is presentation —
each spec carries its `insert` (point + knob), and
`ParamRegistry.insertSections(of:)` splits any group into flat rows plus
insert sections, so the **Parameters tab shows four collapsible inserts**
(a header row per point with its on/off + reverb summary; 40 of the 64
knobs are EQ bands that are inert while that point's EQ is off) instead
of 64 flat rows, and **docs/parameters.md renders the insert once** plus
a table of the four points. The FX tab builds its panels from the same
`fxPoints` list. To add or rename a knob, edit the template — all four
points follow.

**Click-free by construction**: toggles glide rather than switch — EQ off sweeps every band to 0 dB (~50 ms) before bypassing; reverb off sweeps the wet level to zero. Band moves redesign coefficients state-kept (`Biquad.copyCoefficients`); the wet level ramps across each chunk.

## The reverbs

- **Bigverb** (`SarangiKit/DSP/Bigverb.swift`) — a port of [sndkit's bigverb](https://paulbatchelor.github.io/sndkit/bigverb/) (Sean Costello's csound `reverbsc`): 8 parallel feedback delay lines whose read taps jitter along random line segments (cubic-interpolated, the reference's 8-line table / LCG / 28-bit fractional read), coupled through a junction pressure. `size` is the feedback (reference default 0.93), `cutoff` a one-pole LP inside every loop. Wide, modulated, blooming.
- **Room** — the Freeverb-style tank that also serves as the calibration room (`DSP/Reverb.swift`), retuned live via `Reverb.setTone` (comb feedbacks re-derived for RT60, state kept). `rev_size` maps to RT60 0.25 s → 8 s (log). Tighter, and running-RMS energy-matched to the dry level.

Switching kinds resets the incoming tank (no stale tail). Both allocate at engine build — the render thread never allocates.

## Architecture

The taraf is computed **in-kernel** (the modal-jawari post-pass), so the first three points rest on two kernel hooks (`bow_kernel.h`, both byte-null by default):

- **`bow_poly_set_drive_fx`** — the voice→taraf insert. The kernel records each block's junction force into a drive buffer for the deferred jt post-pass; the hook lets the host process that buffer in place *after the record walk, before the post-pass consumes it* — in async-jt mode before the job is published, so ordering and the FX's own filter state stay single-threaded. Installed once per engine at build (`BowEngine` init → C trampoline → `FXChainUnit`).
- **`bow_poly_process3`** — the split-bus render: with `outJt` non-NULL the jt post-pass **adds into `outJt`/`outJtS`** (kernel-zeroed) instead of `out`/`outS`. Every jt term lands in each sample **exactly once**, so host-side `out[t] + outJt[t]` reproduces the fused path's floating-point rounding **bit-exactly** — `BowEngine` engages the split only while a voice/taraf insert is live, and flipping between the split and fused paths is inaudible *and* bit-exact.

`BowEngine.renderPolyChunk` then runs: kernel (drive hook fires inside) → voice/taraf FX on the split buses at the kernel rate (mid **and** side through identical filters — by linearity that equals EQing L/R; a bus reverb hears L/R = m±s and its wet folds back to mid/side) → sum → the one 2:1 decimation → the fitted post-chain → **global FX** on the final L/R.

Settings flow: FX tab → `AppController.setParamValue` → `applyParamToVoice` → `AudioEngine.setStringControlParam` (the `fx_` prefix route) → `StringVoiceSource.setFXParam` (parses the key, **caches per-point `FXSettings`** — the long-lived side, re-applied to every fresh engine so a rebuild never snaps the rack back) → `BowEngine.setFX` (staged under `tiltLock`, adopted at chunk boundaries). FX *DSP state* is per-engine: across a rebuild the tails restart under the 300 ms crossfade; the settings persist.

## Traps

- **Key sync**: the template's `knob` suffixes and `fxPoints`' prefixes must parse via `FXPoint.parse` + `FXSettings.apply(field:)` — `AudioEngine` routes by the `fx_` prefix, so an unknown suffix would be a slider that silently does nothing, and a renamed knob would orphan the key in every saved preset. `FXRackTests` guards all of it: the key surface pinned literally, the point list against `FXPoint.allCases`, every key through `FXSettings`, and every default equal to `FXSettings()` (a drifted default would arm the rack at the startup resting push and break the byte-null contract).
- **Stereo fold-down**: a stereo reverb wet is decorrelated — with any FX reverb on, L+R no longer equals the mono render (the one deliberate exception to the app's fold-down invariant). EQ alone preserves it.
- **Mono degenerate output**: `StringVoiceSource`'s render aliases `outR = outL` when the host hands one buffer; the global FX writes L then R like the rest of the chain — don't "optimize" the global point to process only one channel.
- **`renderFixture`** (the parity/perf entry) never ticks the FX units, so FX stays disengaged there regardless of settings — parity tests can't be perturbed by a stray FX param.

Tests: `FXRackTests` (the insert definition, key sync, resting defaults, the insert split), `ByteNullContractTests` ("fx rack at rest"), `TarafRemovalParityTests` (the byte-null guarantee). The earlier master-FX bus of the coupled network is not present — see `docs/history/`.
