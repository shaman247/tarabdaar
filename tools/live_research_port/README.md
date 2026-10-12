# Fitted sarangi in the live instrument

The production voice retains the current two-direction raga bank, chromatic
bank, release behavior and performance allocation. A separate saved rig enables
the shared source settings and fitted observations. The factory artifact stays
unchanged, so old presets and zero-valued observation controls retain their sound.

`export.py` exports the selected short-time-timbre `both12` model, fitted body
radiation differences, accepted three-band image-room impulse and force-driven
acoustic modes. It exports no recorded audio or fitted gesture trajectory.
`preset.py --base /path/to/verified-production.tarabdaar` derives the new live preset from the saved production rig without
changing any string row, tuning, taraf parameter, routing, bow-axis curve or controller binding.
It requires a complete version-2 snapshot with every current registry parameter
and explicit bridge and pitch-source tags on every row. Disabled banks stay disabled.
Capture the base with the current Release app and compare
the saved banks and controller bindings with the live rig before exporting.
The file named `Production before research port 2026-10-10` is an invalid
legacy-app capture; do not use it as a production reference. The recovery files
and provenance are under `output/live-research-port/taraf-recovery/`.
Registry metadata comes from `paramdoc --json`. `profile.json` enumerates the
selected prototype's source scalars and observation settings, with hashes of
their source job and artifact. Only those explicit parameters are merged;
unrelated artifact defaults are never imported. Every non-parameter section
is copied exactly. The output's `.audit.json` records each changed value,
the preserved sections, bank counts and input/output hashes. Hybrid performance depths
remain the saved rig's values. In particular, `bow_vib_cents` in the artifact
is available depth, not an instruction to activate vibrato. The export rejects
fitted scalar differences that the application's registry would discard.
Contact width, thermal relaxation and bridge-resonance frequency/Q/gain are
registered controls, so their fitted values survive preset loading.
The formula body's main frequencies are set to the reference calibration using
the air-ratio parameter at export; later tonic changes follow the ordinary
production body's frequency scaling.

The saved `Working sarangi - 2026-10-10` rig remains the rollback preset.
`Research sarangi - preserved live rig` combines that rig with the selected
`both12` prototype. Both are complete snapshots; subsequent saves use the
ordinary preset library and its overwrite backups.

The runtime is a causal adaptation of the offline observation, not a sample-exact
copy of its centered STFT. Every 10 ms it evaluates the same 23-feature mapping,
180 ms bow memory, smooth overlap-confidence weighting and 129 half-order gain
knots. Gain smoothing defaults to 30 ms. A real-cepstrum minimum-phase conversion
produces a 2048-tap causal FIR; adjacent filters crossfade over 10 ms. There is no
fixed audio lookahead or block delay. Phase and transient fine structure differ
from the offline correction. The fitted magnitude is preserved within the
reported native audit error; transient equivalence is not claimed.

The room retains every tap of the synthetic 1.6-second-decay image response,
with independently adjustable low/mid/high output levels. Its first 2048 taps
use a short-partition convolver; later taps use 1024-frame partitions, whose
latency and spread scheduling are covered by the impulse's own offset. Changing wet level or band gains
preserves accumulated history. The fitted dry multiplier is absorbed into the
wet/dry ratios rather than changing the instrument's master calibration.

The source bridge-force tap only observes existing force. Its optional acoustic
modes do not replace or feed back into the taraf. Body radiation blending changes
signed radiation residues, leaving body mobility and played-string feedback
unchanged. The 6 kHz upper shelf currently acts on the combined radiated mix,
unlike the research observer's played-body-only shelf; this is an explicit live
adaptation and has its own control. All gains are before the existing limiter.

`audit.py` independently checks the C gain predictor against SciPy B-splines,
minimum-phase magnitude accuracy across registers, complete room impulse
convolution, exact unarmed bypass and reset silence. Package contracts cover
radiation/feedback separation and host callback partitioning. The full-bank
realtime suite exercises timbre/room changes with the current physical taraf.
