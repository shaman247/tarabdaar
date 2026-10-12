# History

The instrument's development record, kept out of the live docs so those
describe only what the instrument currently is.

- `CLAUDE-2026-09-03.md` — the last full-history version of the project
  guide: every deletion and rename since the Starpad era with its
  rationale, the "do not revive" list with detail, and the dated
  conventions. Consult it before resurrecting anything.
- [Documentation audit — 2026-10-12](documentation-audit-2026-10-12.md) —
  archived jawari proposals, old 34-row coupling measurements and historical
  rebuild/continuity benchmarks; the live docs retain current bank contracts.
- Reference research outputs — archived on the user's external USB backup
  as of 2026-10-12; the local copy was deleted that day to recover disk space.
  The original project path is `output/reference_onsets/` (about 123.5 GiB).
  Restore needed files from that backup to the same relative
  path for historical comparisons or research/export scripts that consume them.
  The experiment scripts, original reference recordings and bundled fitted
  resources remain in the local project.
- `simulator.md` — the headless audition loop: `IPadSimulator` +
  `AuditionRunner`, the JSON score format and the `tools/audition_*.py`
  scripts. The pipeline was removed 2026-09-03 along with the in-process
  MIDI vocabulary it drove; the page is the record of how it worked.
- The FX rack's **10-band graphic EQ** (`fx_<point>_eq_b1`…`_b10`, octave
  bands 31.5 Hz…16 kHz) was replaced on 2026-09-04 by the EQ curve — points
  the player sets, a curve inferred from them ([FX](../fx.md)). Fixed
  bands with a knob each were neither flexible (nothing between the
  centres, nothing narrower than an octave) nor general (40 of the rack's
  64 keys were bands). Old files load as a curve through the band centres.
- `tools/archive/` (in the repo root) — the retired fitting and analysis
  pipelines.
- Git history carries everything else; the docs pages under `docs/` are
  present-tense from 2026-09-03 on.
