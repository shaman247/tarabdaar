# FX

The **FX tab (⌘6)** is a four-insert effects rack inside the String voice's render path. Each insert point carries an optional **EQ curve** (points the player sets, a curve inferred from them) and an optional **reverb** (**Bigverb**, the default, or **Room**). Everything is **off by default**, and the untouched rack is *byte-null*: `TarafRemovalParityTests` pins the shipped render bit-for-bit with the rack idle.

The Voice insert processes played String radiation; the Taraf insert processes
both banks. Voice → Taraf also receives injected Tanpura/Sitar excitation.
Global processes the combined String-engine output, including taraf and room,
before its limiter; it does not process the separate audible Tanpura/Sitar
outputs. The generated parameter descriptions name these affected signals.

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
per point: `ParamRegistry.fxTemplate` holds the 7 knobs (keyed by their
FIELD SUFFIX — exactly what `FXSettings.apply(field:value:)` parses),
`ParamRegistry.fxPoints` holds the four points (name, `keyPrefix`, what
each processes), and the registry derives `fx_<point>_<knob>` from the
two. Per point:

- `eq_on`, `eq_amount` (curve depth 0…1: every dB of the curve scaled; default 1) — the switch and the one bindable handle on the EQ curve. **The curve's points are not knobs**: they are one structured value per point (`FXSettings.eqPoints`), edited on the FX tab and carried by presets as their own section (`TarabdaarPreset.fxCurves`, keyed by the point's prefix).
- `rev_on`, `rev_type` (0 = Bigverb, 1 = Room), `rev_mix` (wet level — the dry path always passes at unity, a send), `rev_size`, `rev_cut`.

Every derived knob is an ordinary registry parameter (all `.live`,
`.global`, group "FX rack"), so nothing downstream knows the difference:
`ParamRegistry.all` answers all 28 keys, presets capture them under the
SAME key strings older `.tarabdaar` files carry, and tilt bindings and
composites drive them. What the derivation buys is presentation —
each spec carries its `insert` (point + knob), and
`ParamRegistry.insertSections(of:)` splits any group into flat rows plus
insert sections, so the **Parameters tab shows four collapsible inserts**
(a header row per point with its EQ point count + reverb summary) instead
of flat rows, and **docs/parameters.md renders the insert once** plus
a table of the four points. The FX tab builds its panels from the same
`fxPoints` list. To add or rename a knob, edit the template — all four
points follow.

Each template knob requires an effect description and separate low/high
descriptions, shared by all four instances. Toggles and the reverb selector
describe their actual choices. Amount controls state their enable dependency;
reverb mix explicitly retains the dry signal even at its maximum.

## The EQ curve

**The player sets points; the curve is inferred** (`SarangiKit.EQCurve`,
`DSP/EQCurve.swift`). A point is a frequency and the gain the curve must
pass through there — up to 12 per insert point, 20 Hz…20 kHz, ±12 dB,
pitch-sorted with points closer than 1/24 octave merged
(`EQCurve.normalize`). One point is a broadband gain; two make a tilt;
three make a bump. **Beyond the outermost points the curve holds their
gain flat.**

The target is a monotone cubic through the points in log-frequency
(Fritsch–Carlson, so it never overshoots a point), and it is realised as
a biquad cascade whose SHAPE follows the points: a peaking section at
every point with its bandwidth taken from the spacing to its neighbours,
an extra peak every 2 octaves inside a wide gap so long spans can bend, a
low and a high shelf beyond the ends that carry the held gain, and one
broadband gain — at most `EQCurve.maxSections` (20) sections. The section
gains are FITTED: weighted least squares against the target on a 96-point
log grid (the points weighted 16×, the held regions 3×), four Gauss–Newton
passes because a biquad's dB response is only nearly linear in its gain,
ridge-regularised so near-coincident points cannot drive the gains apart.
The response passes through every point to within ~0.1 dB and holds the
ends within ~0.3 dB; between points it is the cascade's own smooth shape
(a bump between three points is a bell, not a spline). **The FX tab draws
the realised response**, at the rate the insert runs (kernel rate for the
three bus points, engine rate for the global one), so what you see is
what the insert does. `FXRackTests` pins the through-the-points and
hold-outside contract at both rates.

The fit runs on the CONTROL thread (`BowEngine.setFX` fits, caches the
design per point set, and rescales the cached design when only
`eq_amount` moved — so a tilt driving the amount never refits) and the
render thread only ever adopts a finished `EQDesign`. **Click-free by
construction**: the unit keeps two cascades; a new design is loaded into
the idle one, run silently for 10 ms so its start-up transient settles,
then crossfaded in over 30 ms and the old cascade dropped — a point drag,
a curve edit and the on/off toggle (a fade to the identity, after which the
EQ half costs nothing) are all the same fade; a design arriving mid-fade
waits for the fade to finish (latest wins). Reverb off sweeps the wet
level to zero; the wet level ramps across each chunk.

**Older files.** The rack's first EQ was a 10-band octave graphic
(`eq_b1`…`eq_b10`, 31.5 Hz…16 kHz). A `.tarabdaar` file or saved profile
from that era loads as a curve with a point at every band centre
(`TarabdaarPreset.legacyEQCurves`), so it sounds as it did; the band keys
themselves are retired.

## The reverbs

- **Bigverb** (`SarangiKit/DSP/Bigverb.swift`) — a port of [sndkit's bigverb](https://paulbatchelor.github.io/sndkit/bigverb/) (Sean Costello's csound `reverbsc`): 8 parallel feedback delay lines whose read taps jitter along random line segments (cubic-interpolated, the reference's 8-line table / LCG / 28-bit fractional read), coupled through a junction pressure. `size` is the feedback (reference default 0.93), `cutoff` a one-pole LP inside every loop. Wide, modulated, blooming.
- **Room** — the Freeverb-style tank that also serves as the calibration room (`DSP/Reverb.swift`), retuned live via `Reverb.setTone` (comb feedbacks re-derived for RT60, state kept). `rev_size` maps to RT60 0.25 s → 8 s (log). Tighter, and running-RMS energy-matched to the dry level.

Switching kinds resets the incoming tank (no stale tail). Both allocate at engine build — the render thread never allocates.

## Architecture

The taraf is computed **in-kernel** (the modal-jawari post-pass), so the first three points rest on two kernel hooks (`bow_kernel.h`, both byte-null by default):

- **`bow_poly_set_drive_fx`** — the voice→taraf insert. The kernel records each block's junction force into a drive buffer for the deferred jt post-pass; the hook lets the host process that buffer in place *after the record walk, before the post-pass consumes it* — in async-jt mode before the job is published, so ordering and the FX's own filter state stay single-threaded. Installed once per engine at build (`BowEngine` init → C trampoline → `FXChainUnit`).
- **`bow_poly_process3`** — the split-bus render: with `outJt` non-NULL the jt post-pass **adds into `outJt`/`outJtS`** (kernel-zeroed) instead of `out`/`outS`. Every jt term lands in each sample **exactly once**, so host-side `out[t] + outJt[t]` reproduces the fused path's floating-point rounding **bit-exactly** — `BowEngine` engages the split only while a voice/taraf insert is live, and flipping between the split and fused paths is inaudible *and* bit-exact.

`BowEngine.renderPolyChunk` then runs: kernel (drive hook fires inside) → voice/taraf FX on the split buses at the kernel rate (mid **and** side through identical filters — by linearity that equals EQing L/R; a bus reverb hears L/R = m±s and its wet folds back to mid/side) → sum → the one 2:1 decimation → the fitted post-chain → **global FX** on the final L/R.

Settings flow: FX tab → `AppController.setParamValue` → `applyParamToVoice` → `AudioEngine.setStringControlParam` (the `fx_` prefix route) → `StringVoiceSource.setFXParam` (parses the key, **caches per-point `FXSettings`** — the long-lived side, re-applied to every fresh engine so a rebuild never snaps the rack back) → `BowEngine.setFX` (fits the EQ design, stages settings + design under `tiltLock`, adopted at chunk boundaries). The curve's points take the parallel `setEQCurve` route into the same cache. FX *DSP state* is per-engine: across a rebuild the tails restart under the 300 ms crossfade; the settings persist.

## Traps

- **Key sync**: the template's `knob` suffixes and `fxPoints`' prefixes must parse via `FXPoint.parse` + `FXSettings.apply(field:)` — `AudioEngine` routes by the `fx_` prefix, so an unknown suffix would be a slider that silently does nothing, and a renamed knob would orphan the key in every saved preset. `FXRackTests` guards all of it: the key surface pinned literally, the point list against `FXPoint.allCases`, every key through `FXSettings`, and every default equal to `FXSettings()` (a drifted default would arm the rack at the startup resting push and break the byte-null contract).
- **The curve is not a key**: the points reach the voice through `AppController.setEQCurve` → `AudioEngine.setStringEQCurve` → `StringVoiceSource.setEQCurve` (the same cache and lock as the knobs, re-applied to every fresh engine), not through `setParamValue` — a preset or profile that only restores `paramValues` restores no curve. `EQCurve.design` allocates: never call it from the render thread.
- **Stereo fold-down**: a stereo reverb wet is decorrelated — with any FX reverb on, L+R no longer equals the mono render (the one deliberate exception to the app's fold-down invariant). EQ alone preserves it.
- **Mono degenerate output**: `StringVoiceSource`'s render aliases `outR = outL` when the host hands one buffer; the global FX writes L then R like the rest of the chain — don't "optimize" the global point to process only one channel.
- **`renderFixture`** (the parity/perf entry) never ticks the FX units, so FX stays disengaged there regardless of settings — parity tests can't be perturbed by a stray FX param.

Tests: `FXRackTests` (the insert definition, key sync, resting defaults, the insert split), `ByteNullContractTests` ("fx rack at rest"), `TarafRemovalParityTests` (the byte-null guarantee). The earlier master-FX bus of the coupled network is not present — see `docs/history/`.
