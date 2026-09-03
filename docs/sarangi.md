# Sarangi — the played voice

> **Read this first.** The **String voice is the ONLY voice**, and
> `Packages/SarangiKit/` now contains only what plays it. Deleted in three
> passes on 2026‑07‑24: the SWAM / hosted‑AU host and base‑voice picker; the
> coupled bridge–body network (`SarangiProcessorAU`, `SarangiEngine`, the FX
> rack + FX tab, the 25 network params, body/viola EQ, master reverb/filter);
> the linear sympathetic taraf web; and finally — once the package stopped
> being a vendored copy of `~/Desktop/sarangi` — the additive violin voice,
> the byte‑parity **mono kernel**, and 3.4 MB of offline goldens. Mac tabs:
> Live ⌘1 · Strings ⌘2 · Fret Pad ⌘3 · Controls ⌘4 · Parameters ⌘5 · FX ⌘6 · Setup ⌘7.

Tarabdaar's sarangi is **`SarangiKit`** (`Packages/SarangiKit/`), which began as
a port of the Sarangi Live project (`~/Desktop/sarangi`) and became Tarabdaar's
own code when the upstream link was cut on 2026‑07‑24. The played voice is the
**String instrument**: a GENERIC PURE‑PHYSICS bowed gut string —
**`BowEngine`** running the **C friction kernel** (`CBowKernel`,
`bow_kernel.c`/`bow_kernel_poly.c` — the byte‑exact twin of the offline
Python render's C source) at 96 kHz, decimated to 48 kHz, with:

- a **formula body** (modal resonators from physical scalars — no fitted FIR,
  no fingerprint mask, no coupled/chain artifacts),
- the **modal‑jawari taraf fused in‑kernel** (`bow_jt_*`: the grazing‑bone
  modal‑contact physics validated by the upstream tanpura campaign; **always
  on** — the `bow_jtaraf_on` arming switch was removed 2026‑08‑02, since the
  block IS the sympathetic response and its only other setting was "no taraf
  at all"; the block builds whenever there are enabled tarab rows, running
  ASYNC one‑block‑late on its own worker pool so the audio callback never
  waits. **2026‑08‑31: one jt‑web computer at a time** — the async
  dispatcher's `jt_run_job` and `bow_poly_process3`'s offline‑pull
  fallback share the string states, the schedule scratch and the pool
  rendezvous; under offline test pulls (faster than realtime, the web
  ring underruns constantly) they could dispatch the pool CONCURRENTLY,
  crossing the `jtDone`/`jtGen` counting so the one‑waiter completion
  signal woke the wrong dispatcher — the render thread slept forever at
  0% CPU (a full guard run burned 30 min wedged). Fixed with the
  `jtDispMx` dispatch‑owner mutex around the whole web computation in
  both paths (taken only when a pool/dispatcher exists — the plain
  serial parity path never locks), a `broadcast` completion, and
  rendezvous waits that break on `jtQuit` so a teardown can never strand
  a dispatcher. Sync‑only: `TarafRemovalParityTests` passed unchanged).
  Since the **2026‑07‑22
  J8z6 update** the shipping jt config is **J8/zone6**: `bow_jt_J` 8
  with the new `bow_jt_zone` 0.006 key (default 0.010 = legacy) — the
  contact lives in ~6 mm around the apex, so a narrowed zone concentrates
  the modes on the active region (`BowTables.buildJawariTables` reads it;
  upstream measured J8z6 closer‑to‑converged than the old J16 at 10 mm and
  ~24% cheaper). **2026‑07‑23 warmth knobs** (Tarabdaar‑local; every default =
  the previously hardcoded value, so untouched artifacts sound byte‑identical):
  `bow_jt_hcb` (contact hysteresis damping, legacy 8 — more = rounder buzz
  pulses), `bow_jt_fhf` (the per‑mode f² damping‑law corner, legacy 4000 Hz —
  lower = the top decays faster = warmer), `bow_jt_bst` (stiffness
  inharmonicity, legacy 2e‑4 — lower = more harmonic top, less bell‑metallic;
  all three are builder‑side, `buildJawariTables`), and `bow_jt_lp` (one‑pole
  low‑pass on the radiated jt sum only, ≥ 20 kHz = bypass — the ONE kernel
  divergence: state + `bow_jt_set_lp`/`bow_poly_jt_set_lp` setters outside
  the load ABI, so the python‑parity `bow_*_jt_test` entries and every golden
  stay bit‑exact; mirrors the coupled network's `N_jaw_lp` 6 kHz precedent).
  All four are rows in the Parameters tab's "Jawari taraf" group / audition
  `string.<key>`. **2026‑07‑26 harmonic‑evolution axis** (`bow_jt_evolve`,
  0…1, default 0.5 = bit‑exact, `.live`): the tanpura/sitar **twang** is
  the energy cascade up the partials that runs while the ring amplitude
  GRAZES the bone — it lives in a narrow amplitude band around the graze
  knee, which is why the stock taraf twanged inconsistently (at
  `bow_jt_apex` 1e‑5 a half‑level tap cascades, a full‑level tap presses
  past the knee and doesn't). The parameter spans graze margin ×4 … ×¼
  around the fitted bone: 1 = margin ×¼ — the cascade is fast (measured
  tap‑ring centroid rise 1.2 s → 0.27 s, high‑harmonic peak −16 →
  +24 dB re h1) and runs at any drive level (reliable twang; the taraf
  also rings ~8 dB hotter, as a real opened jawari does — trim with
  `bow_jt_gain`); 0 = margin ×4 — pressed past the knee, harmonics
  static, no twang, slightly choked. **Implementation: a kernel‑slewed
  SIGNED bone lift** (`bow_poly_jt_set_evolve`, meters; scaling the
  parabolic bone's apex ≡ a uniform vertical offset), advanced once per
  divided jt sample (~40 ms one‑pole, fill‑time in the pool/async drive
  walk so serial and pool replays stay bit‑exact; the deep‑substep
  threshold tracks it as jtDeep − 2.5·ev). This is the ONE sanctioned
  runtime bone move — the bone GLIDES, so a tilt sweep is a slow jawari
  adjustment; the v1 stage‑3 table‑reload implementation STEPPED the
  bone under the wrap and audibly strummed under a tilt
  (`JtEvolveSweepTests` pins the click‑free sweep, and `bow_jt_set_lift`
  stays offline‑only). Pitch shifts stay ≤ 16 cents across the travel.
  **The register tilt (2026‑08‑27, `bow_jt_ev_reg`, −1…1, default 0 =
  byte‑null, `.live`):** the bone offset above is ONE global scalar, but
  the cascade it opens is amplitude‑gated — only rows whose ring reaches
  the grazing band ignite — and the rows that get there and STAY there
  are the low Sa/Pa anchors: kin to nearly every played note (the
  recruitment lattice charges them coherently all phrase), longest t60
  (their fundamentals sit far below the `bow_jt_fhf` f² corner), largest
  displacement per unit energy (u ∝ p/ω). So at high evolve they sit in
  the cascading band for their whole multi‑second ring — the sustained
  sarod‑drone bloom heard from the low strings. `bow_jt_ev_reg` makes
  that emergent bias a playable axis: evolve units per OCTAVE from the
  tonic, evaluated per row on the SAME margin map (e_row = clamp(e +
  reg·log2(tonic/f_row), 0, 1), offset = lift(e_row) − lift(e) — every
  row stays on the calibrated ×4…×¼ span) and pushed as per‑row bone
  offsets ADDED to the global lift (`bow_poly_jt_set_evolve_ofs`,
  row‑slewed ~40 ms in `jt_tick_string` — row‑owned state, serial and
  pool advance identically; a sleeping quiescence‑gate row wakes on a
  material move of its own target, and the engine reuses setJtEvolve's
  cumulative dead‑band so a bound tilt's sensor jitter never moves
  bones). Positive opens the below‑tonic rows toward the band (the
  drone bloom on demand — measured +17 % rms on the low‑Sa drone ring
  at reg 0.8, kin‑charged playing drives it far harder) while pressing
  the above‑tonic web closed, so the bloom comes WITHOUT web‑wide buzz;
  negative reverses it. It rides the evolution knob (offsets are
  differences on the map, recomputed when either moves), so
  evolve×register make a 2‑D jawari surface — both tilt‑bindable.
  Guards: `testEvolveRegisterBloomsTheLowRows` (byte‑null at 0 + the
  low‑row bloom), `testEvolveRegisterSweepIsClickFree`.
  **The radiated observable (2026‑09‑03 — bridge‑force radiation):** the
  rows radiate their CONTACT FORCE on the jawari bone (the zone
  force‑density sum × spacing, DC‑blocked ~8 Hz, unit‑matched per row by
  `JtTables.rowForceScale` = gout·π·wj/(mu·L·wd1) so the fitted level law
  carried over). Until then they radiated a velocity PICKUP at
  `bow_jt_tap` 0.90 L whose |sin(k·π·tap)| comb humped h5/h15 and NULLED
  h10 in every row — the "two clusters" the Taraf tab exposed — and the
  2026‑07‑26 "formant voicing" answer was to slide the tap toward the
  bridge. The pickup, `bow_jt_tap`, `bow_jtc_tap` and the one‑day
  `bow_jt_rad_force` mix (2026‑09‑02) are DELETED — do not revive; the
  force radiates every mode flat in the pickup's units, the buzz
  harmonics the comb muffled now radiate (≈ +5…8 dB hotter taraf,
  measured), and the drive tap stays fitted at 0.90 L (roadmap item 2).
  Two consequences of the observable, measured 2026‑09‑03: the contact
  pulse train carries a large low‑frequency swing (the DC blocker takes
  only the static preload), so `bow_jt_gain` now GLIDES ~40 ms inside the
  kernel (`jtGainCur`) and so does each row's radiation scale
  (`jtRadScaleCur`, per jt tick — the two‑bridge chromatic level rides
  `bow_jtc_gain / bow_jt_gain`, so a `bow_jt_gain` sweep re‑scales every
  chromatic row per update; a 60 Hz stepped scale splashed impulses ~10×
  the signal — ZipperTests' fast flick) — both bit‑null when constant; and
  an INSTANT bone move (evolve 0.5 → 0) radiates the bone slapping into a
  ringing string as a real ~0.3 step ~32 ms later (a physical thump the
  velocity pickup never showed; the kernel's 40 ms bone slew makes tilt
  sweeps clean — `testEvolveSweepIsClickFree` now starts its triangle at
  rest). The opened graze (`bow_jt_ev_reg`) reads ~8 dB QUIETER in
  contact force while its cascade doubles (the string touches the bone
  less), and the quiet grazing haze under‑radiates versus the linear
  pickup (force ∝ η^1.3) — both are the contact‑only observable: the
  PIN force at the string's rigid termination (T·∂u/∂x at L, linear,
  comb‑free) is NOT yet radiated — see roadmap item 1b.
  `bow_jt_hp` (`.live`, one‑pole HP on the
  radiated jt sum after the tone LP, kernel `bow_poly_jt_set_hp`, 0 =
  byte‑null) then drops the fundamental band. Measured tap 0.98 +
  hp 1200 at evolve 1: cluster h4–h8 within 4 dB of each other, h1
  −17 dB — the "high harmonics peaking near each other over quiet lows"
  jawari voicing. **The body-radiation blend (2026-08-01, the coherence
  rev):** `bow_jt_body` (`.live`, 0…1, default 0 = byte-exact) blends
  the radiated jt sum through the SAME formula-body radiation bank the
  played strings radiate through (shared coefficient arrays — a body
  edit re-voices both — with its own mid+side filter state, applied
  before the tone LP/HP inside the jt output walk; kernel
  `bow_poly_jt_set_body`, plain scalar write slewed ~30 ms, the
  set_lp/set_hp contract). Until this knob the taraf radiated RAW —
  its sum was added after the body solve — so the melody carried the
  body formants and the wash didn't, which is a large part of why the
  taraf read as a separate backing chorus rather than the same
  instrument. **The charge governor (2026‑08‑15):** `bow_jt_gov`
  (`.live`, 0…1, default 0 = byte‑null, kernel
  `bow_poly_jt_set_gov`) — the taraf's accumulation tamer. Measured
  (`TarafVarianceBench`, TarabdaarCore, skip‑gated on
  `TARAF_BENCH_DIR`/`_HOT`/`_GOV`): the long‑t60 anchor rows (Sa
  0.95/7 s, low Sa 0.95/9 s, low Pa 0.85/8 s — consonant with
  everything by design) accumulate a whole phrase, so high Sa lands
  +8…+12 dB hotter after four notes than struck cold (Pa +4…+6 dB, a
  non‑kin degree +1…+2), re‑excitation phase against the stored ring
  makes it a several‑dB strike‑to‑strike lottery (`p += dt·Fd·phiD`
  on ringing state — the tanpura pluck lottery's twin), and at high
  expression the pile‑up crosses the contact knee into the hard‑buzz
  regime (early‑ring buzz share 1 % → 14–16 %, only after a phrase —
  the "randomly very loud with buzz on Pa/high Sa" report). The
  `bow_jt_norm` output law can't reach this: it trims `phiO`
  (radiation) while the drive side `phiD` scales with raw row gain,
  so the anchors charge internally regardless. The governor is a
  per‑row AGC at the CAUSE: each row tracks a ~60 ms peak envelope
  of its contact‑zone velocity, and drive into a row ringing above
  the graze target (`bow_jt_gov_ref` bp scalar × apex → per‑row
  velocity bound via mode‑1 rate) is shed by ref/env — the ring
  saturates at its single‑strike level instead of piling up. Applied
  BEFORE the drone‑noise add (held drones are never ducked);
  recruitment weights compose upstream. 0 is bit‑exact; the startup
  resting push arms nothing (`TarafGovernorTests`). **Calibration
  (gov sweep, ref 12/24/48/96/192):** the shipped ref **48** is the
  knee — a resting‑level solo strike renders BIT‑IDENTICALLY at
  gov 1 (its envelope never crosses the target), the moderate CC64
  phrase swell on Pa moves ~0.2 dB, while the hot phrase→high‑Sa
  pile‑up sheds 14–16 dB and its buzz share falls 16 % → ~1.5 %
  (hot solos compress gently, −41.2 → −45.9 dB, buzz 6.1 → 1.8 %).
  TRAP: ref ~96 parks the ring AT the buzz‑maximal graze band
  (buzz share 28 %, WORSE than ungoverned — the band is where the
  cascade lives; hold the ring there and it buzzes continuously).
  12–24 over‑govern (solo −13…−6 dB). Re‑run the sweep after any
  bone/apex refit, don't interpolate. The sympathetic swell through
  a phrase is real sarangi behaviour — the knob dials how much the
  taraf remembers, it doesn't delete the physics. **The quiescence
  gate (2026‑08‑17):** `bow_jt_gate` (a **bp scalar like
  `bow_jt_gov_ref`, NOT a registry parameter** — always on at the
  baked default **40** dB below the graze apex; a 0 override in
  tests/auditions is the bit‑exact raw‑physics escape hatch; kernel
  `bow_poly_jt_set_gate`) — the idle‑CPU gate. The jt web is a constant‑cost simulation: every row
  ticks its whole mode stack (up to `bow_jt_mcap` 64 modes) at the jt
  rate whether ringing or silent, so the idle app burns the full web
  cost — measured ~350 % CPU across the `bow_jt_threads` 8 workers
  plus the async dispatcher with nothing playing. Armed, a row whose
  peak LOW‑MODE momentum rests below the floor (`10^(−gate/20)` ×
  apex × mode‑1 rate, the governor's velocity‑bound convention) for
  ~30 ms of consecutive jt ticks with no bridge drive above its wake
  bound and no drone drive goes to sleep **in place**: its state is
  FROZEN, never zeroed — `jtQ` holds the settled static wrap against
  the bone, and zeroing it would strum the re‑settle on wake — and
  the whole modal tick is skipped (output truncates from sub‑floor to
  exact 0). The low modes (first ≤ 6) are the ONE workable meter: the
  wrap is a dynamic equilibrium — a tick‑rate micro limit‑cycle
  against the bone that never rests — so the contact‑zone velocity
  (constant ~0.6 at rest, right under the governor's ~1.0 graze
  scale) and the raw radiated sample (constant ~5e‑3 per row) both
  sit on standing baselines, while the audible ring lives in the
  first modes, which rest 3+ decades below ring scale. The
  consecutive‑tick hold means single‑tick |p| dips at the mode
  cycle's zero crossings can't fake quiet. Wake: bridge drive above
  the per‑row bound (the force that could ring the low modes back to
  the floor within ~one mode‑1 period of resonant driving —
  conservative, precomputed at arm time) or ANY drone drive (pluck
  boost included) resumes the frozen state instantly, so the first
  note of a phrase meets a fully live taraf;
  `bow_poly_jt_set_evolve` wakes everyone on a MATERIAL bone move (a
  row sleeping through a real glide would meet the moved bone as a
  step) — change‑gated with a dead‑band (2% of jtDeep = 5% of apex)
  against the target the sleepers were frozen under, because a live
  tilt/stick binding streams the setter at sensor rate. **The
  evolve‑binding trap (2026‑08‑17):** every APPLIED evolve change
  physically moves the bone, and zero‑mean sensor jitter pumping the
  bone keeps the resting rows' low modes above the gate floor —
  measured: a Joy‑Con stick‑Y → `bow_jt_evolve` binding held all 19
  rows awake at idle (the full pre‑gate burn back, plus HAL overload
  on a DisplayPort output). Fixed at the choke point:
  `BowEngine.setJtEvolve` has a cumulative 0.005 dead‑band against
  the last APPLIED value — jitter never accumulates past it, a real
  sweep does (its ≤0.5% staircase rides the kernel's ~40 ms slew;
  `JtEvolveSweepTests` unchanged). Guard:
  `TarafGateTests.testEvolveJitterSpamDoesNotHoldWebAwake`. Held
  drones never sleep. **The floor is baked at 40 dB — the PRESSED‑BONE finding
  (2026‑08‑17):** a resting bone pressed past the knee
  (`bow_jt_evolve` toward 0 = negative lift) sustains a steady
  LOW‑mode limit cycle at rest — measured: stock rig at evolve 0
  parks at ×3.34 of a 60 dB floor (5/19 rows ever sleep), a hot‑gain
  22‑row rig at ×6.6 (≈ −43.6 dB re apex velocity, reported
  inaudible) — so the original 60 dB floor never closed on pressed
  rigs and the whole web stayed awake at idle. 40 sleeps both with
  ≥2× margin; deeper than ~75 dB sits under even the neutral‑bone
  resting baseline and never closes. Measured at the bake: 10 of 19
  rows asleep after 1 s of silence, the rest within ~10 s; a 20 s
  idle offline render fell 45 s → 5 s wall (~9× less CPU).
  `TarafRemovalParityTests` was deliberately RE‑BLESSED for the
  40 dB floor (the quietest rows sleep in its phrase's opening
  silence; ~7e‑4 sample moves near the first onset — the 60 dB
  floor had been verified hash‑identical under the prior
  reference).
  Asleep count:
  `bow_poly_jt_gate_asleep` → `BowEngine.jtGateAsleep()`. Guards:
  `TarafGateTests` (the default sleeps at idle and wakes on a
  strike, the 0 override truly disarms, and the woken strike keeps
  the ungated ring),
- the **taraf bridge‑coupling web** (2026‑08‑01, the coherence rev's
  TWO‑WAY fix): one SILENT linear comb per enabled tarab row back on
  the passive wave junction (`bow_cpl_*`, group "Taraf coupling";
  default `bow_cpl_z` 0 = byte‑null) — no buzz terms, no radiation
  tap, no polarization doublets; a row's only output is the junction
  itself. The played strings finally FEEL the taraf as a load: a note
  at a kin pitch drains into its rows (sympathetic absorption), the
  rows store the energy and return it through the body (the release
  bloom a one‑way drive cannot make), and the returning junction
  force also re‑drives the jt block, so the radiated ring sustains
  with it. Passive by construction (g < 1, zi > 0 — the exact
  delay‑free junction solve that shipped through 2026‑07‑24; the
  builder is the restored `webLoopCoeffs` law). One physical string,
  two computational devices: the comb carries the string's bridge
  load, the jt row its buzz + radiated ring. Measured
  (`TarafCouplingTests`, single row, jt off): kin release tail +17%
  RMS near the SINGLE‑ROW matching optimum z ≈ 0.05, non‑kin flat at
  EVERY z, bounded at the knob ceiling. **z is PER‑ROW and the bank
  multiplies it** — total bridge load ≈ rows × z, so the single‑row
  optimum over‑damps a full bank (measured in‑app on the 19‑row
  default: z 0.05 drags held notes ~5 dB; z 0.0141 ≈ −2.5 dB with the
  release bloom clearly audible — tail RMS UP right after note‑off
  while the long wash ring SHORTENS ~9 dB, both physical). The
  offline fit's Z (0.0141) was fitted at full‑bank scale — the
  audition reference; coupling damp/bright/inharm default to the
  artifact's fitted web values (0.019 / 0.80 / 0.1), — RUNTIME playing controls (no rebuild),
  reached now as ordinary `ParamRegistry` entries: `bow_jt_lp`,
  `bow_jt_damp` and `bow_tone_tilt` are `.live`. (A fourth used to be the
  jawari‑buzz scaler `bow_set_jaw_gain`, the live half of the `.hybrid`
  parameter `bow_taraf_jawari`; it acted on the LINEAR sympathetic web,
  which was **deleted 2026‑07‑24**, so both it and `setStringJawGain` are
  gone, and so is the C setter.) Path:
  composite or direct tilt binding → `AppController.applyParamToVoice` →
  `AudioEngine.setStringControlParam` / `setStringHybridScaler` →
  `setStringJtToneLp`/`setStringTarafDamp`/
  `setStringToneTilt` → `StringVoiceSource` (stores, re‑applies on every
  engine rebuild in `setEngine`) → `BowEngine` chunk‑rate smoothers;
  audition `voiceParam`s `stringPurity`/`stringTarafDecay`/`stringToneTilt`
  drive the default composites, `composite1..8` the slots directly). The
  shipped composite defaults reproduce the former hardcoded axes:
  1. **Taraf purity** (CC71: 0 = the fitted buzzy jawari chorus, 127 =
     clean kin ring) — TWO mechanisms since the recruitment axis
     (2026‑07‑26), both live members of the composite:
     **(a) TONE** — the modal‑jt buzz brightness fades through the
     radiated‑jt **tone‑LP corner sweep** (build corner → 
     `bow_tilt_pure_lp` 1500 Hz, log in p; `bow_[poly_]jt_set_lp` is
     runtime‑safe since this rework: state preserved on coefficient
     moves + warm‑tracked bypass, both kernels incl. the stereo side
     state `jtLpYS`). Measured (bowed note): hi‑band buzz falls
     MONOTONICALLY −24 → −34.5 dB over the full throw, RMS eases
     0.120 → 0.100 — no loudness bloom, no tuning change.
     **(b) RECRUITMENT** (`bow_jt_sel`, 2026‑07‑26; PROFILE rework
     2026‑08‑01 — the first bipolar axis' top half was a pure uniform
     boost (drive ×lush + radiated gain), so the whole knob read as a
     taraf VOLUME slider; an interim monotone "breadth" cut topped out
     at the fitted response, still note‑dependent. The axis now sweeps
     each row's CONTRIBUTION to the taraf at held loudness).
     **0.5 = the fitted taraf** (all weights 1, bit‑exact) — the
     natural resonance profile: unison rows dominate, octaves a few dB
     down, fifths faint, unrelated rows only haze. BELOW: per‑row
     BRIDGE‑DRIVE weights — the render thread scores every jawari
     row's harmonic kinship to the gated pitches (kin lattice: unison
     1, octaves/twelfth/fifth/fourth fading as `(p·q)^-bow_jt_sel_kin`
     [0.7, shared with the drone spread], Gaussian cents corridor
     `bow_jt_sel_width` [30 c] — both bp scalars; the kin score is
     SQUARED at the endpoint so octaves sit clearly under the unison
     and the fifth family is faint) and pushes them through
     `bow_poly_jt_drive_weights`; the jt tick slews each row ~30 ms
     and scales its incoming bridge force. ABOVE: the profile FLATTENS
     — resonant rows are CUT toward the common haze level
     (w → √(haze/(haze+kin²)); a unison row falls to ~0.22, a non‑kin
     row keeps full drive — cuts because extra drive is drained by the
     graze contact, ×2 drive measured only +8% ring) until at 1 every
     row contributes EQUALLY and the response no longer depends on the
     played note. LOUDNESS COMPENSATION throughout: the radiated jt
     gain (`bow_poly_jt_set_gain_mul`, slewed in the output walk)
     holds the taraf's power — below 0.5 at the note's own fitted
     level, above 0.5 blending to ONE fixed common level (rows·haze +
     `recruitKinNominal` [1.75, a tonic‑like note's kin power]), so
     the flat end is note‑independent in level too. The model
     (`BowEngine.recruitGainMul`) is an incoherent power sum over the
     kin scores plus a per‑row haze floor (`recruitHazeFloor` 0.05 —
     also the flat end's per‑row target, and what keeps the gain
     engaging smoothly on non‑kin notes), cap ×`bow_jt_sel_comp` [4,
     the kernel clamp]; the follower row and held‑drone rows count as
     fully ringing in the model, so a held drone is never pumped by
     the compensation. Chords combine soft‑OR (misses multiply —
     gentler than a max, bounded at 1); no gated note holds the last
     weights + gain so a ring keeps its recruit pattern; the
     melody‑follower row keeps weight 1 on the selective half but
     flattens like a unison row on the flat half; drone rows' own
     noise drive adds AFTER the weight, so a held drone is never
     ducked. Weights gate recruitment, not the ring — energy a row
     holds decays naturally. Measured (`TarafRecruitTests`): on a KIN
     note the post‑release taraf tail holds within −3.1/+1.6 dB of
     fitted over the whole throw; on a non‑kin note the kin‑only end
     thins the chorus to −15.5 dB (physics leaves only haze to boost —
     the ×4 cap keeps it honest; uncompensated it would sit ~12 dB
     lower still) and the flat end lifts it +4.5 dB toward the common
     level. Cross‑note tails do NOT fully equalize at the flat end —
     the weights level each row's contribution and the gain levels the
     modeled response, but how hard a note excites the bridge still
     varies with its register and dynamics, as on a physical
     instrument. Unarmed the kernel is byte‑null
     (`TarafRemovalParityTests` unchanged). The purity composite
     sweeps it 0.5 → 0 (purity up = kin‑only; rest = the fitted taraf
     — resting at 1.0 would park the instrument on the
     note‑independent flat wash, the same decoupled "backing ensemble"
     failure the coherence rev fixed).
     (A THIRD mechanism, **REMOVED with the linear web 2026‑07‑24**:
     `bow_[poly_]set_jaw_gain` scaled the formula‑taraf web's buzz
     sources — `jn` in‑loop contact/fold, `jw` output‑tap grazing —
     linearly to zero across the throw.)
     **The jt bones NEVER move at runtime.** Cut 1 (bone lift over the
     whole throw) read as loudness/fullness, not purity — the jangle
     was in the web (which is itself gone now, so the axis is the tone
     LP alone; the measurement above was taken with the web present).
     Cut 2 (lift deferred to the top quarter) still
     STRUMMED: releasing the static‑wrap energy of every row at once
     is an unavoidable "strummed modal jawari" transient (measured
     2.4× ring peaks through a lift sweep — smoothing cannot fix a
     physical energy release), a partially lifted bone buzzes HARDER
     than the fitted wrap (opened‑jawari regime, +17 dB), and full
     lift detuned the rows ~15 c. `bow_[poly_]jt_set_lift` +
     `bow_tilt_pure_lift` remain in the kernel for offline
     sound‑design use only.
  2. **Taraf decay** (CC73: 0 = natural ring, 127 = choked):
     `bow_[poly_]jt_set_damp_t60` — per‑tick momentum damping in the jt
     tick (static wrap untouched), amplitude t60 log‑interpolated
     `bow_tilt_damp_max_t60` 20 s → `bow_tilt_damp_min_t60` 0.25 s
     (axis 0 = off). All kernel axes are plain scalar writes (the
     drone‑setter contract) — kernel divergences beside `bow_jt_lp`;
     unused they are byte‑null (goldens and python‑parity untouched,
     82/82 green). **Click‑free by construction (2026‑07‑23 night):**
     `BowEngine.updateTarafAxes` smooths purity/decay at chunk rate
     (~40 ms) on the render thread and pushes the kernel scalars only
     when they move (the tone‑tilt pattern). **Settle pre‑roll (same
     night):** a fresh kernel's jt web relaxes off the builder's q0
     with an audible ~200 ms jawari chime (measured idle peak ~0.004 ≈
     −37 dBFS) — every UI‑edit rebuild "strummed" on publish, and
     debounced rebuilds landing near the first note read as onset
     clicks. `StringVoiceSource.buildEngine` now renders and discards
     ~0.5 s off‑main before returning (chime −26 dB, below the tail
     floor; also primes the async‑jt FIFO). Deliberately NOT in
     `BowEngine.init` — parity fixtures need renders from t = 0.
     **2026‑08‑18: the DAMPED SETTLE superseded pre‑roll length tuning**
     — the taraf is choked (t60 50 ms) through the discarded blocks and
     restored byte‑exactly before publish, so the chime dies at the
     cause instead of asymptoting at ~−50 dBFS: publish peak −93 dBFS
     at the shipped 3 settle blocks (was 5), and the launch is silent
     (see [Sound Design](sound-design.md), rebuild cost).
  3. **Tone tilt** (CC72: 0 = bass bias, 64 = flat, 127 = treble bias):
     a complementary low/high shelf pair (∓/± `bow_tilt_eq_db` 9 dB at
     `bow_tilt_eq_lo` 300 Hz / `bow_tilt_eq_hi` 2400 Hz) over the whole
     voice in `BowEngine.postChain` AND `postChainStereo` (the stereo
     side path runs side twins of the shelves — same coefficients,
     independent state; EQing mid and side identically = EQing L/R, so
     the image never narrows), pre‑room so the wet follows; target
     smoothed ~50 ms on the render thread with in‑place coefficient
     swaps (click‑free); flat = exact bypass.
  All six range keys are bp scalars, overridable via `string.<key>`.
  Verified offline (drone‑row harness 2026‑07‑23): purity 1 → mid‑band
  +17 dB ring, 2.8× tail; damp 1 → post‑release tail RMS 0.014 → 0.0002;
  EQ ±1 → ~±13 dB complementary band tilt. Note the
  kernel + BowEngine sections,
- the **sitar‑twang axis** (`bow_twang`, 2026‑08‑01, 0…1, default 0 =
  byte‑null, `.live`; fitted to `sitar1.wav`): a grazing jawari WRAP on
  the **played strings'** bridge termination — distinct from the jt
  taraf's bones. While an excursion tip of the bridge‑reflected wave
  presses past the graze knee, the string's speaking length shortens by
  a smoothed rolling‑contact offset (`bow_poly_set_twang` /
  `poly_string_return` + the `buf2` read in `poly_string_force`) — an
  energy‑CONSERVING per‑cycle phase modulation that pumps the harmonic
  cascade round trip by round trip — and the terminations morph toward
  sitar hardware (pow‑exponent brightening of the bridge/nut/gut
  corners, eased finger‑release damping). Findings that shaped it, all
  measured on the shipping artifact: a one‑sided subtractive fold is
  ESCAPED by a bowed loop (the Helmholtz wrap settles on whichever
  polarity the fold misses — the lobe measurably flipped sides when the
  fold did), so the graze rides per‑side instant‑attack peak envelopes
  (the web rollE idiom, knee ~0.55 × the side's own peak — twang at ANY
  strike level, the bow_jt_evolve consistency lesson); a subtractive
  fold at ANY useful depth reads as buzz + a choked ring (energy
  deleted, not cascaded), which is why the wrap is a length modulation
  (the web's v2 roll idiom) and the contact‑loss fold ships at 0; the
  wrap alone drains the note into the stock lossy top (the morph is
  what lets the pumped 2.5–6 kHz cluster SUSTAIN). **The extended top
  (same day, the "go twangier" rev):** the endpoints are HOTTER than
  the sitar1.wav fit — roll 5.5 / bright 3.33 / knee 0.5, with the
  ring/gut eases (1.27/1.07) deliberately past their derive caps so
  the fitted sustain saturates by ~0.75 of the throw and the last
  quarter spends its travel on wrap + brightness. **The sitar1.wav
  match therefore lives near `bow_twang` ≈ 0.75** (measured there:
  buzz‑band/low‑band gap ≈ −9.6/−9.9/−12.7 dB at 150/300/600 ms vs the
  sample's −6/−2/−7; at 1 the early gap opens to ≈ −7 dB — pushing the
  wrap past roll ≈ 5.5 measured NO further buzz, only drain: a bigger
  swing also smears more HF, the equilibrium saturates. **PITCH LOCK
  (two open‑loop terms + one tracker, all byte‑null off):** (1) the
  wrap's mean shortening (naively ~+7…18 c sharp) is subtracted by a
  ~30 ms tracker of twD's time‑average (an engaged‑gated "corner
  phase" variant measured WORSE — the engagement/corner phase
  relation varies per note); (2) the termination brightening REMOVES
  loop phase delay (a one‑pole's low‑f phase delay is a/(1−a)
  samples), restored analytically on the bridge read — verified exact
  (±0.1 smp) over three octaves on a wrap‑free morph; (3) the wrap's
  phase‑SELECTIVE residual is cancelled by the fitted curve
  n(P) = 0.335 − 66.2/P samples per unit amt·roll. Result: the
  twanged ring holds the plain ring's pitch to ~±5 c (worst −7 c low
  register at full twang) with a brief sitar‑like onset settle
  (~+10 c decaying in ~300 ms) at high notes; the residual WANDERS
  with the chaotic ring — it is not a constant, so chasing it below
  ±5 c open‑loop is noise‑fitting. The offline re‑fit hook is
  `bow_poly_set_twang_shape` (kneeR/depth/relMs/rollSmp/bright/ring/
  gut, the `bow_jt_set_lift` precedent); harness `TwangFitTests`
  (env‑gated), guards `TwangTests` (byte‑null, sustained buzz,
  level‑consistency, click‑free live sweep). Note the base ring sags
  ~7 c flat after release (finger‑release damping); the twang ring is
  locked to THAT (the two rings agree), not to nominal,
- an **analytic Schelleng press envelope** (wedge‑relative force mapping),
  place‑then‑draw articulation with attack bite, aftertouch vibrato, and
  **self‑calibrated intonation** (two‑stage pitch‑correction tables).
  **Attack sharpness has TWO drives (2026‑08‑19):** the press law (onset
  press above `bow_attack_thresh` — the pads hold press ~0.56, so
  lowering the threshold sharpens every onset) and the **onset strike
  velocity** (`bow_attack_vel`: sharpness = max(press law, key ×
  velocity 0…1) — per‑note articulation: tap hard = martelé bite +
  `bow_draw_min_ms` fast draw + `bow_attack_fms` velocity‑leads‑force
  ramp, place gently = the legato draw; velocity comes from the iPad's
  accelerometer estimate ([sensors.md](sensors.md)) or MIDI/audition
  velocity, and the key at its 0 default keeps the historic press‑only
  law bit‑exact — the velocity byte was carried but discarded before).
  Everything in the Articulation group acts on FRESH attacks — since
  2026‑08‑24 every note‑on is one (each note mounts a fresh string);
  within‑note finger glides never re‑articulate, so glide character is
  untouched by construction,
- the **sustain‑liveness layer** (2026‑08‑01, fitted to clean SWAM Violin 3
  captures): a post‑onset settle (`bow_settle_db`) that eases the stroke off
  its capture overshoot (since 2026‑08‑19 `bow_settle_sharp` exempts a
  SHARP attack from it — depth × (1 − key × sharpness) — so an accented
  staccato holds its level while gentle sustains keep the fitted
  balance; 0 = bit‑null), three seeded Ornstein–Uhlenbeck walks
  (`bow_drift_*`) that give a held note its slow pitch/level/timbre wander,
  and a glide‑rate bow lightening (`bow_glide_dip_db`) that articulates
  finger glides (meend) — measurements and traps in
  [sound-design.md](sound-design.md),
- **polyphony as physics**: `bow_live_poly 8` gut strings on ONE shared
  bridge (delay‑free junction). **Every note‑on mounts a fresh string
  (2026‑08‑24)** — the mono‑meend re‑bow, the effective‑mono legato
  steal and the note‑off glide‑back to a held predecessor were all
  removed: a new note takes an unused slot (else the longest‑released,
  else steals the oldest sounding note), its serial bump snaps the
  pitch, and note‑off just lifts the bow (the string rings on its
  slot at its frozen pitch). Pitch glides exist only WITHIN a note — the
  finger dragging its own string. **The 9 Hz meend smoother is also gone
  (2026‑08‑24, same day):** the filter ramps log2 f0 linearly to the
  latest target across each render block (continuous, on target within
  one block), so ALL meend is the player's finger, delivered at wire
  rate — the instrument adds no glide shaping of its own.

The whole instrument — played strings + taraf + body + radiation + room — is
the kernel; it needs ONLY **`bowed_string.json`** and renders **straight to
the mix** (in Tarabdaar: `StringVoiceSource` → `symGain` → `mainMixerNode`).
It **is the only voice** — the base‑voice picker and the SWAM/sitar sources
are deleted.

**Nothing of the v57 era remains.** The passive coupled bridge–body network
(`SarangiEngine.renderSample`) stopped being instantiated with the 2026‑07‑24
SWAM strip and was deleted later the same day, together with the additive
violin voice, the per‑class taraf‑jawari buzz params (`N_jaw_*`) and the
fitted JSONs that fed them (`sarangi_model_v57.json`, `sarangi_coupled.json`,
`sarangi_pilu.json`).

The physics were fitted offline in `~/Desktop/sarangi` and ship as
`bowed_string.json`. (The fitted tarab table, `sarangi_pilu_strings.json`,
was retired 2026-07-25 with the scale-defined pitch model — the tarab is
generated from the centralized scale now.) Tarabdaar does not re‑fit — but it
does now **own** the DSP: there is no re‑sync, and the package is edited in
place.

## The String instrument in Tarabdaar

- **`StringVoiceSource`** (`Packages/TarabdaarCore/.../StringVoiceSource.swift`)
  — an `AVAudioSourceNode` at the artifact's native **48 kHz** (the mixer
  input SRCs to the 44.1 kHz engine) pulling `BowEngine.render`. Engine swaps
  are published under a brief unfair lock; swapped‑out engines are retained
  briefly so an in‑flight buffer never reads a freed one. Its static
  `buildEngine(tonicHz:strings:mapper:overrides:)` is the port of upstream
  `BowSource.buildStringEngine`: taraf TUNING rows = the enabled tarab
  strings, taraf PHYSICS = `bow_jt_*` artifact keys, and the **modal‑jawari
  row selection** is the python `_jt_load` mirror (raga‑set pitch‑class
  coverage: playing‑register rows first, one 60‑cent class each keeping the
  row nearest the class median, remaining `bow_jt_max` slots by gain).
  **Realtime telemetry** (kept from the 2026‑07‑22 dynamic‑taraf
  experiment, since reverted): `StringVoiceSource.jtStats()` /
  `AudioEngine.stringVoiceJtStats()` expose the async jawari web's
  dropped‑job / flat‑fill counters, `StringVoiceSource.renderStats()`
  times every render callback against 90% of its buffer budget (a LATE
  callback glitches at the device while the audition tap records a clean
  WAV — the counter is the only way to see it), and `AppController` runs a
  5 s watchdog that NSLogs "jt OVERLOAD" / "render OVERRUN" only when the
  counters grow. When clicking is reported, check these two lines first.
- **Controls — `BowControlMapper`** (`SarangiKit/Bow/BowControls.swift`), the
  long‑lived mapper shared across rebuilds: CC11 expr · CC1 press · CC74 pos
  · CC2/**75** tilt · aftertouch = player vibrato · CC120/123 all‑off.
  **TARABDAAR MPE DIVERGENCE**: note identity and pitch bend are keyed by the
  status byte's channel nibble (per‑note channels, **per‑channel bend** —
  each Pitch Pad finger bends only its own gut string); a single‑channel
  controller behaves exactly like upstream. `bendRange` is set to
  `Config.midiPitchBendRange` at source creation. The Mac pads' flat CC11
  stays **32** (≈ the mapper's idle expr 0.251); the Setup‑tab axis sliders
  initialize from `BowControlMapper.default*`.
- **Rebuilds**: `AudioEngine.rebuildSarangi` (every structural tarab/tonic
  change, incl. the Pitch‑Pad scale sync) records `lastSarangiTonic`/
  `lastSarangiStrings` and, while the String voice is active, kicks
  `rebuildStringVoice` — the `BowEngine` is rebuilt **off‑main** on a serial
  queue (tables + kernel init + jt pool spawn), generation‑checked, and
  swapped in; the mapper keeps held notes/axes across the swap.
- **Artifact overrides**: `AudioEngine.stringVoiceOverrides` /
  `setStringVoiceOverrides` apply scalar overrides OVER `bowed_string.json`
  at build time. Audition path: **`string.<key>`** (e.g.
  `string.bow_jt_gain`, `string.bow_rev_mix`, `string.bow_live_trim`).
- **The parameter list (Parameters tab, ⌘5)** — `ParametersView`
  (`TarabdaarMac/Views/ParametersView.swift`) over **`ParamRegistry`**
  (`Packages/TarabdaarCore/…/ParamRegistry.swift`), backed for physics rows by
  **`StringParamStore`** (`TarabdaarMac/StringParamStore.swift`). Eight
  groups: **Bow stroke · Body (formula modes) · Bow & string · Playing
  ranges · Jawari taraf (modal contact) ·
  Articulation · Radiation & output** — the physics rows are
  `bowed_string.json` scalars, applied live via a debounced off‑main
  String‑engine rebuild; the bow/taraf/tone rows apply instantly.
  (Before the 2026‑07‑24 unification this list was a separate **Sarangi
  tab** and the live axes had their own Parameters tab, which is how
  buzz/vibrato/damping ended up with two knobs each.) Tarabdaar cannot rewrite the
  bundled artifact, so edits persist as an **override dict**
  (`tarabdaar.stringOverrides.v1` in UserDefaults) applied over the artifact
  at build time; an override that lands back on the artifact value is
  dropped, so *dirty* means "differs from the Sarangi Live default".
  Double‑click a row label to reset that value; the header's **"Default
  (Sarangi Live)"** button clears everything. Slider ranges are authoring
  hints — an artifact value outside the range widens the slider rather than
  being clamped. (The coupled‑network 25‑param section that used to sit below
  this editor was deleted 2026‑07‑24 — the network no longer runs.)
- **The default preset = the Sarangi Live default.** Fresh installs (and the
  preset menu's **"Default (Sarangi Live) — Pilu, fitted"** entry, via
  `SarangiStore.loadSarangiLiveDefault` + `StringParamStore.resetToDefault`)
  give exactly the upstream default instrument: the untouched
  `bowed_string.json` physics (zero overrides), the EXACT fitted Pilu string
  table, Sa = 328.9 Hz, and — NEW since the String era — **tarab auto‑sync
  starts OFF** so the fitted table sticks (the Strings tab's "Follow the Pitch
  Pad scale" switch opts back in; `SarangiStore.persistKey` bumped v7→**v8**
  so stale documents don't shadow the new default).
- **What lives elsewhere**: the Strings tab IS the String voice's taraf tuning;
  room/level live in the physics panel (Radiation & output). The coupled‑network
  params, the FX rack, the output user‑EQ, and the drive gain are all deleted
  (they acted on the removed coupled network).
- **Stereo (2026‑07‑23 immersive rev).** The poly kernel renders a second
  **SIDE stream** (`bow_poly_process2`/`bow_poly_set_stereo`,
  `bow_kernel_poly.c`) carrying only the **direct radiation** — the jawari
  strings' direct tap (through its own copy of the tdir shaping bank), the
  modal‑jawari rows' own radiation (**drone buttons included**), and the
  bow‑contact noise at its string's position. Everything that reaches the
  listener **via the bridge** (played‑string force, driven web resonance)
  radiates from the ONE body — a fixed central radiator — and stays
  mid‑only, so the image is a spread sympathetic halo around a centred
  voice that never leans with the melody. Pans are **per pitch class around
  the tonic** (`spread·sin(2π·pc)`: tonic centre‑stage, svaras at fixed
  symmetric places, octaves share a place — a plain low→high rank map was
  tried and rejected: the ring concentrates in the playing register + the
  low drones and parked the energy centroid 6–10 dB off‑centre). The host
  forms `L = mid + side, R = mid − side`; the side (and the room's
  decorrelated width tank, `Reverb.processMonoStereo`) cancel in L+R, so
  the **mono fold‑down is bit‑identical to the legacy mono output**
  (`BowStereoTests` asserts all three invariants). **The pans are LEGACY
  staging since the 2026‑08‑01 width unification** (below): the spread
  scalars are unseeded (registry defaults 0 = disarmed) and the pan
  machinery is kept only for A/B, pending removal.
- **Instrument width (2026‑08‑01 unifying rev): ONE width law for the
  whole instrument** — `bow_st_width` (`bow_poly_set_stereo_width`,
  `bow_kernel_poly.c`). The physical claim: one small instrument heard
  from TWO observation points — identical at low frequency (monopole
  radiation), diffusely decorrelated at high frequency, because above
  the Schroeder crossover a real body's radiation is a dense
  overlapping mode field where two listening positions see random
  independent mode shapes. When this shipped (2026‑08‑01) the fitted
  mid had no resolved modal structure up there (its 9 signature modes
  all sit 55–250 Hz; the upper spectrum shipped as flat `c0`
  feedthrough — that flatness was later measured at ±0.3 dB over
  250–6500 Hz and fixed by the 2026‑08‑24 **formant forest** bake: the
  mid's diffuse tail `bow_body_tail_*` now runs 32 modes / 280–6500 Hz
  at radiation 2.5, see [sound‑design.md](sound-design.md)), so the
  observation‑point DIFFERENCE is modelled the way the mid models the
  diffuse region itself: a **diffuse‑field difference bank** — 16
  dense random‑sign side‑only modes, 700 Hz – 6.5 kHz, Q ≈ 12,
  golden/plastic jitter like the mid's own diffuse tail, peak weight
  `1.4·d(f)` (directivity ramp 300 Hz → 3 kHz; |ΔH| ≤ 2·|H| bounds
  it). The bank runs **once per bus** — the pre‑jt voice mid and the
  jt wash — with shared coefficients and per‑bus state: by linearity
  the two together equal one bank on the complete radiated output,
  and the split FX buses keep valid side streams. Not a pan, not
  Haas/detune: a static passive difference transfer, width slewed
  ~30 ms kernel‑side, derived from the sample rate alone. Seeded
  `bow_st_width` 0.2; replaced the per‑source pans (`bow_st_spread` /
  `bow_st_played`, disarmed) AND the interim body‑side residue
  readout (same day — a second per‑mode readout of the body bank,
  measured inaudible on this fit and deleted; git history has it).
  Measured (offline probe, seed 0.2, both buses live): melody
  interaural coherence ≈ 0.99 below 1 kHz → ~0.9 at 4–8 kHz, the
  bare wash ~0.3–0.4 in its ring band (a wider halo than the retired
  pans gave), balance within ±0.8 dB; 0.6 is very wide (melody
  ~0.4–0.5). Guard:
  `BowStereoTests.testInstrumentWidthAloneWidensAndFoldsDown`.

The sections below describe the **coupled‑network chain** — removed from
Tarabdaar on 2026‑07‑24 (it colored the deleted SWAM / sitar base voices) and
kept in SarangiKit for upstream parity tests only.

## What used to be here — the coupled network and the violin voice

Two large subsystems documented in this page until 2026‑07‑24 are **gone from
the repository**, not merely unused:

- **The v57 additive source voice** (`Violin/`: `ViolinModel` / `ViolinSynth` /
  `ExprEqualizer`, plus the 3.3 MB `sarangi_model_v57.json` control‑grid
  tables). It stopped being a Tarabdaar voice with the SWAM strip.
- **The passive coupled bridge–body network** (`SarangiEngine.renderSample`,
  `ResonatorBank` / `CombString` / `BodyAdmittance` / `WModalBank`, the 25
  `SarangiParams` scalars, the FX rack, `sarangi_coupled.json`). It stopped
  being instantiated at the same time.

Both survived a while longer because SarangiKit was a **vendored copy** of
`~/Desktop/sarangi` and they were needed to keep its parity tests running. That
link was cut on 2026‑07‑24: SarangiKit is Tarabdaar's own code now, so everything
whose only job was to track upstream went with it — including the byte‑parity
**mono kernel** (`bow_kernel.c`) and every offline golden. Git history has the
physics write‑ups if they are ever wanted back.

## Sympathetic strings (the Strings tab, ⌘2)

**TWO SETS ON TWO BRIDGES (2026-09-02).** The real sarangi carries its tarab
in two families — the **chromatic set** (~15 strings through the main
bridge, tuned semitone by semitone) and the **raga sets** (on separate small
bridges, tuned to the notes of the raga) — and each bridge has its own
jawari. Tarabdaar's taraf is split the same way: every `StringSpec` carries
a `set` (`TarabSet.raga` / `.chromatic`, persisted as a string; absent =
raga, so every pre-split document reads as all raga strings). The **raga
set** is the bank described below — scale-degree strings on the
`bow_jt_*` bridge. The **chromatic set** is 15 semitone strings (low Ga …
tivra Ma, the historic `chromaticRatios` row of raga.build_strings,
`RagaTuning.buildChromaticSpecs`, gain 0.6 / t60 3.0 — above the jawari
selection's `bow_jt_gmin` so it SOUNDS, unlike the 0.40-gain choir deleted
2026-07-25) whose `degree` is a **semitone (0…11) into the fixed JI
chromatic grid** (`RagaTuning.chromaticRatio`) off the same tonic: still no
ratio or Hz in the document, still retuned by a tonic move, but
deliberately NOT by a scale edit — the chromatic set is tuned once,
whatever the raga. It sits on its own bridge, the **`bow_jtc_*` group**
("Chromatic bridge (jawari taraf)" in the Parameters tab): the twin of
every `bow_jt_*` bridge knob — level, drive, graze depth, contact zone /
bone radius (`bow_jt_zone`/`bow_jt_radius` joined the raga group the same
day), contact law, level norm, contact damping, damping corner,
inharmonicity, and its own live **evolution** axis (the radiation tap
twin lived one day: 2026-09-03 the bridge-force radiation replaced the
0.90 L pickup for the whole web, and `bow_jt_tap`/`bow_jtc_tap` went with
it) — while the
web-wide taraf controls (tone LP/HP, body, governor, damping, comp, cap,
recruitment, register tilt) stay shared. Mechanics: the bone GEOMETRY of a
bridge was always per-row kernel data, so the builder
(`BowTables.buildJawariTables(rows:…:chromatic:)`) bakes chromatic rows
with the `bow_jtc_*` profile and per-row level/drive scales (ratios
against the raga bridge's global `phys` gain/drive); the CONTACT LAW
(alpha, hcB, the deep-substep threshold at 2.5 × that bridge's apex) is
per row in the kernel via `bow_poly_jt_set_row_contact` (drone-setter
contract — never called for an all-raga rig = byte-null; a chromatic row
resting at the raga values ticks bit-identically — a case of SarangiKit's `ByteNullContractTests`, plus the parity hash), and
`bow_jtc_evolve` rides the existing per-row bone-offset path
(`bow_poly_jt_set_evolve_ofs`): each chromatic row evaluates the margin map
on its own apex at its own evolve, minus the raga bridge's global lift
(`BowEngine.pushJtEvolveOffsets`). Resting values are pinned equal to the
raga bridge's shipped numbers (`BowTables.chromaticBridgeDefaults` ==
the registry defaults, `TarabSetTests` — the artifact never carries the
keys, so DEFAULT = ENGINE TRUTH), so the split alone adds strings, not a
new sound. Kernel row order: the raga bridge's rows (exactly the
pre-split `jawariRows` selection), then the chromatic bridge's (selected
by the same rule on its own — `StringVoiceSource.jawariRowPlan`, the ONE
plan build and live reload share), then the follower; a pitch on both
bridges resolves drone presses to its raga row. The pool invariant below
is PER BRIDGE (Sa on both is the instrument's own layout); the raga set
lists first in the document. The Strings tab shows two tables — "Raga
strings (side bridges)" with the follower pinned above it, "Chromatic
strings (main bridge)" under a semitone dropdown (`+k` + the scale's own
label where it has that pitch, else the grid fraction) — each with its
own +, Enable/Disable all, and a "Reset chromatic set" beside "Regenerate
from scale" (which now rebuilds the raga set only). The drone/strum
auto-mappings stay on the raga bridge; the pickers list both. **Schema 3
→ 4 migration:** a pre-split document is seeded with the default
chromatic set on decode, its raga rows untouched, ONCE (the re-saved
document is schema 4; a deleted chromatic set stays deleted). The persist
key is not bumped. `TarafRemovalParityTests` was deliberately re-blessed
for the grown default document (and again 2026-09-03 for the bridge-force
radiation). (This is NOT the 2026-08-26 sitar bank:
that was a second raga-tuned bank with a different jawari preset, rejected
by ear and removed the next day; this is the instrument's chromatic set,
resting at the same jawari.) CPU: ~9% of a core per awake row — Pilu is
now 19 + 15 = 34 rows; the pool starves somewhere past ~40, so an
overgrown bank shows as taraf drop/flatten, not as callback overruns.
**Recruitment note:** `bow_jt_sel` (and the Taraf Purity composite) weighs
every row by kinship to the played pitches — with the chromatic set
mounted every semitone has a unison row, so a "non-kin" note no longer
exists and kin-only still rings the chromatic unison (that is the set
doing its job; `TarafRecruitTests` measures the raga law on the raga
bridge alone, `Presets.state(_:chromatic: false)`).

The RAGA set lives in the **Strings tab** (`StringsView`) as **one flat pool
of strings** — a `StringSpec` (`Model/StringSpec.swift`) is `degree, octave,
gain, t60, enabled` (+ `set`). **The pitch is SCALE-DEFINED (2026-07-25)**: `degree`
indexes `InstrumentState.scaleRatios` — the ONE centralized scale, mirrored
from the Pitch Pad on every change — and `octave` shifts it by whole
octaves, so a string can only ever sound a pitch of the scale, and a scale
or tonic move retunes the whole bank (a tonic write IS a transpose). The
editor row is a **Pitch dropdown** (the scale's degrees under the scale's
own labels — the same names the Fret Pad draws on its frets), an
**Octave dropdown** (−2…+2), a read-only Hz readout, then Gain / t60 / On;
there is no per-string ratio or Hz input anywhere — the app's one Hz input
is the tonic, on the Fret Pad tab. Absolute Hz is minted only at resolve
time: `resolved(tonic:scaleRatios:)` = `degreeRatio × 2^octave × tonic`
quantized to **millihertz** (deterministic to the bit — the drone press
path finds its jt row by exact nominal Hz). An out-of-range `degree`
(the scale shrank) clamps to the top degree. Pinned by `TarabRatioTests`.
**`gain`** is the one per-string level knob — it scales the string in the
String voice's in-kernel modal-jawari taraf (jt-subset selection); 0
silences the string while keeping its row.

**THE POOL INVARIANT (2026-07-26): sorted by pitch, one string per
pitch.** The table always lists lowest frequency first, and two rows at
the same pitch are impossible. Enforced by
`InstrumentState.normalizeStrings` (sort + fold duplicates, keeping the
stronger twin — higher gain, then longer t60) on every entry path: both
inits (a doubling-era persisted document migrates in place, keeping the
v8 persist key; a drone button mapped to a dropped twin is re-pointed at
its survivor), `updateScale`/`regenerateFromScale`, and the store's edit
paths. In the UI, an edit that would land a row on another row's pitch
is **rejected** (the picker snaps back — no silent row deletion), and
"+" adds at the first FREE pitch (base octave first, then up, then
down). Guards: `TarabRatioTests` (pool-invariant section).

(Model history, all 2026-07-25, each step migrating the persisted document
in place: `weight` folded into `gain`; the 15-string chromatic choir +
`StringGroup` grouping removed — inert rows, bit-identical render; then
free ratios — and before them absolute `freq` — replaced by degree+octave.
Stray `weight`/`group`/`ratio`/`freq`/`bright`/`raga` keys in old documents
decode away ignored.)

**The scale push.** An `AppController` sink on
`pitchPad.$scale`/`$tonicMidi`/`$tonicCents` calls `syncTarabFromScale` →
`SarangiStore.syncTarabToScale` with the tonic Hz + degree ratios
(`scaleDegrees(from:).map(\.ratio)`). The PITCHES always follow — there is
no opt-out (the "Follow the Pitch Pad scale" toggle and the
`autoSyncToScale`/`manualEdits` fields were removed 2026-07-25). The row
LAYOUT regenerates when the scale's degree COUNT changes — existing rows
would go stale-and-clamped — or via the tab's explicit **"Regenerate from
scale"** button; otherwise `updateScale` retunes and hand edits stand.
Regeneration is `regenerateFromScale` → `RagaTuning.buildSpecs`: one
string per scale degree, emphasized Sa/Pa, low-octave repeats and 6
upper-octave repeats — Pa is the degree nearest 3/2, the vadi the
2nd-highest degree — deduped and pitch-sorted (Pilu: 19 rows).
(2026-08-01 coherence rev: the CROWD's t60s shortened ~×0.6 — the long
wash decoupled from the playing and read as a pad — while the three
drone anchors the buttons auto-map to, Sa / low Sa / low Pa, keep the
fitted 7/9/8 s ring; their tap character is pinned by
`DroneExcitationTests`. Persisted documents keep their hand-tuned
t60s — "Regenerate from scale" adopts the new law.) The rows
tune the String voice's in‑kernel modal‑jawari taraf. (They also fed a
linear comb web until 2026‑07‑24; that web is deleted, so a row the
jawari selection does not pick up no longer sounds.) The historic layout
DOUBLED Sa/Pa with exact-unison twin rows (unisons since the detune
chorus died with the free-ratio model; the settle pre-roll grew 4 → 5
blocks for their coherent chime, `RebuildCostTests`) — the no-duplicates
law (2026-07-26) folds each doubling into its strongest twin, so the
emphasis survives as that row's gain/t60 and those pitches ring once;
`TarafRemovalParityTests` was deliberately re-blessed for it, and
`ModelTests` applies the same fold to the golden fixture.

**The melody follower (2026‑07‑25).** One special sympathetic string sits
pinned above the pool: its pitch is not a scale degree — it **live‑retunes
to the highest note being played** (glides and bends included), so it
always rings in sympathy with the melody. Same Gain / t60 / On knobs as
any row; no octave, no Hz readout, not a drone‑button target (it has no
stable nominal pitch). **Default OFF** — disabled it adds no jt row and
the render is byte‑identical (`TarafRemovalParityTests` unchanged).
Mechanics: the row is built at tonic/2 (generous mode allocation, appended
after the jawari selection in `StringVoiceSource.jawariRows` so build and
live‑reload shapes always agree), and the kernel retunes it in place
(`bow_poly_jt_track_config`/`_target` in `bow_kernel_poly.c`): the render
thread pushes the highest gated slot's `f0Target` once per chunk, the
row's own jt tick slews toward it (~15 ms) every ~1.3 ms and rewrites just
the f0‑dependent mode tables (`ca/cb/ca4/cb4/wd`) from the builder's
damping/inharmonicity law — mode shapes, bone profile and output taps
never move (retune‑by‑tension). The active mode count is trimmed to the
builder's 18 kHz `fx` corner as the pitch rises (an under‑resolved contact
mode limit‑cycles into broadband static — the dynamic‑taraf‑era lesson),
with the contact compliance matrix re‑prefix‑summed on each count change.
With no note held the target stays put, so the string rings out wherever
the melody left it. Guard: `FollowerStringTests` (TarabdaarCore) pins that
the row's ring follows each played pitch (drone‑excited, ±40 c band scan)
and that octave‑jump abuse stays bounded. Note the known jt property that
a wrapped row rings a hair sharp of nominal (grazing‑bone stiffening)
applies to this row like any other; its sympathetic pickup level is a
sound‑design quantity (gain/t60), not a mechanism guarantee.

**Drone buttons (2026‑07‑25 — mapped strings, no dedicated rows).** Below
the strings sits a "Drone buttons" section: each of the 3 Fret Pad buttons
plucks **one of the sympathetic strings above**, chosen per slot
(`InstrumentState.droneStringIds`, 3 × optional `StringSpec.id`; nil =
unmapped, button inert). All sympathetic strings are the same — there is no
drone-specific pitch/gain/t60 anywhere; a mapped string sounds exactly as
its row is tuned, and if the row is disabled or the jawari selection skips
it (gain below `bow_jt_gmin`) the button is silent like the row itself.
The dedicated-drone-row era (2026‑07‑23…25: appended rows, ±6 ¢ coverage
reuse, `bow_drone_comp_cents` compensation, per‑slot `DroneStringSpec`)
is deleted. **Auto‑mapping** (fresh documents + every bank regeneration):
per slot the highest‑gain enabled string within ±100 ¢ of low Sa / low Pa /
Sa — gain‑first so the emphasized Sa/Pa rows win over quiet rows;
a deleted row's mapping prunes to nil on decode. Mapping changes are
voice‑neutral: no engine rebuild (`AudioEngine.setDroneMappedFreqs`
retargets the buttons; a press is an identity lookup on the row's nominal
Hz via `BowEngine.droneRow(forExactHz:)`), and they never detach scale
auto‑sync. The Fret Pad's button labels are display‑only ratios derived
from the mapped pitches (see [Fret Pad](fret-pad.md)). The row selection
shared by engine builds and live jt reloads is
`StringVoiceSource.jawariRows` — **one** implementation, guarded by
`DroneStringTests.testBuildAndLivePathsSelectIdenticalRows`.

(The *Manual tuning* section — a raga
picker + tonic Set/Transpose/Regenerate — was removed 2026‑07‑25 along with
`InstrumentState.setRaga` / `regenerate` / `transpose(toTonic:)`.
`RagaTuning` itself survives — its ragas seed `Presets.state` and the JI
machinery drives the scale‑sync builders.)
`RagaTuning.buildStrings(intervals:) -> [ResolvedString]` keeps golden
parity for the surviving rows (the fixture's chromatic segment is skipped;
the fixture was exported detune-off, which is now the only mode);
`buildSpecs(scaleRatios:)` is the degree-space layout builder.

## Jawari modelling roadmap (2026‑09‑02)

What the Taraf tab's spectra exposed, and the improvements proposed for
the modal‑jawari rows, in the order they are worth doing. Status marks
what has landed.

1. **Radiate the bridge contact force, not a 0.90 L pickup — BAKED IN
   2026‑09‑03: the force IS the radiation; the pickup, `bow_jt_tap` /
   `bow_jtc_tap` and the one‑day `bow_jt_rad_force` mix are deleted, and
   `TarafRemovalParityTests` was deliberately re‑blessed for it.** The
   legacy output was a velocity pickup φO_k = sin(k·π·tap) at 0.90 L,
   whose comb humped modes 5/15 and nulled mode 10 in every row — the
   "two clusters" — and which no real taraf has: a sympathetic string
   drives the body through the force it exerts on its bridge at the
   termination. The kernel's contact solve already computes the zone
   force densities every tick; `jt_core` sums them (read‑only, after the
   dissipative scaling; the impulse into the modes is untouched) and the
   tick radiates the DC‑blocked (~8 Hz one‑pole, primed to the first
   sample) force. Unit match per row, from the builder
   (`JtTables.rowForceScale` = gout·π·wj/(mu·L·wd1), riding the load ABI
   in the slot `phiO` used to take): with T = mu·(L·wd1/π)² the
   termination force of a unit mode‑1 ring maps to the old pickup's
   velocity amplitude, so the fitted level law carried over — measured in
   the test scaffold ≈ +7.6 dB hotter ring / +4.8 dB while bowing than the
   pickup (the buzz harmonics the comb muffled now add; trim with
   `bow_jt_gain`) — and every mode radiates FLAT in those units, so the
   Taraf tab's single modal‑energy spectrum is also the radiated one. It
   shipped as a 0…1 mix for one day (2026‑09‑02); the user judged mix 1
   "sounds great" and it was baked the next day. Guard:
   `JtForceRadiationTests` (finite, DC‑free ring at the calibrated order;
   deterministic).
1b. **Add the termination (pin) force to the radiation.** The modal basis
   is pinned at L; the bone only grazes the last few mm, so the bridge
   assembly receives BOTH the pin force T·∂u/∂x|L (linear in the modal
   state, weight ∝ k — flat in velocity units, no comb) and the bone
   contact force (the buzz, nonlinear, radiated since 2026‑09‑03). Item 1
   radiates the contact part alone — which is what the user heard and
   approved — so the quiet grazing haze under‑radiates (force ∝ η^1.3),
   an opened graze reads quieter, and bone moves thump. Adding the pin
   term (signs: both act on the same bridge; the static parts cancel in
   the DC blocker) would restore the linear string tone under the buzz.
   Cheap: Σ(−1)^k·k·q_k per row per tick. To be judged by ear against the
   contact‑only sound before it ships.
2. **Drive from the termination too.** The bridge force enters each row
   through a second, fixed 0.90 L tap (φD), so the null at mode 10 is
   squared and modes 10/20 are never charged. A shared‑bridge excitation
   couples into mode k through the mode slope at the end (∝ k·(−1)^k, no
   null). Same pattern: an option first, then a re‑fit of the recruitment
   levels.
3. **Two‑way coupling among the rows.** Each row is driven one way from the
   played string and never feels the other rows; on the instrument the rows
   exchange energy through the shared bridge, which is what makes a taraf
   bloom as a web. The silent coupling web (`bow_cpl_*`) approximates this
   on the linear side; feeding the modal rows' summed bridge force (now
   available — the item‑1 tap) back into the junction would make it
   physical. Stability is the risk: keep the one‑sample lag the drive uses.
4. **Bone profile.** The parabola is right near the apex, but a real jawari
   surface is an asymmetric arc with a longer, gentler slope toward the nut;
   that lengthens the buzz cascade rather than deepening it. Build‑time
   table, cheap to try.
5. **Damping law.** Per‑mode loss is a constant plus an f² roll‑off around
   `bow_jt_fhf`; real strings add an air term ∝ f and a bending term ∝ f².
   Modest, but it sets how long the high cluster survives the cascade.
6. **Port the tanpura contact string** (the fitted r7 modal‑contact string
   with the jiva thread) under the sarangi web. The sitar‑taraf experiment
   tried a second bank of those and was removed for CPU (~9 %/core/row);
   revisit only if 1–3 don't get there.

## Presets & resources

**One preset** ships, generated in code by `Presets.state`:

- **sarangi_pilu** — *Default (Sarangi Live) — Pilu* — the first‑launch
  SEED: raga **Pilu**'s JI degree ratios as the scale, its session tonic
  (328.9 Hz) as the starting tonic, and the generated string layout. On
  launch the Pitch Pad scale is pushed over it, so what actually ships is
  the LAYOUT and the gains/t60s, not a pitch table. The timbre lives in
  `bowed_string.json` (`bow_*`).

One resource ships: **`bowed_string.json`** (the String voice's physics).
The others — `sarangi_model_v57.json` (3.3 MB), `sarangi_coupled.json`,
`live_comp.json`, `sarangi_pilu.json` and finally `sarangi_pilu_strings.json`
— fed the deleted voices and the retired fitted-table model, and are gone.

**The string-table law is RETIRED (2026-07-25).** It protected the fitted
Pilu table's exact per-string detunes (PCG64-seeded, ~5 ¢ rms/string; the
upstream measurement: regenerated detunes cost a −3.7 dB 125–250 Hz lean +
audibly weaker ring). Scale-defined strings cannot carry a detune — a
degree can't be a few cents off itself — so the fitted table was retired
with the free-ratio model, the taraf now sits exactly on the scale's JI
grid, and `TarafRemovalParityTests` was deliberately re-blessed on the
generated default's render. Git history has the artifact and the law's
full measurements if a fitted-table mode is ever wanted back.

## Mac side: state, editor, persistence

- **`SarangiStore`** (`TarabdaarMac/SarangiStore.swift`) owns the editable
  `InstrumentState`. Every tarab edit funnels into a **debounced structural
  rebuild** (`AudioEngine.rebuildSarangi(strings:tonic:droneFreqs:)`); the
  scale push (`syncTarabToScale`) rebuilds immediately. Auto‑saves to
  UserDefaults (`persistKey` **v8**, deliberately never bumped for the
  2026‑07‑25 model rewrites — the stored blob was migrated in place each
  time); export/import `.sarangi` JSON.
- **Strings tab (⌘2)** (`StringsView`): the sympathetic strings + optional scale sync.
- **Controls tab (⌘4)** (`TiltControlsView`): the tilt bindings (to a
  composite or straight to a parameter) + the composite parameters.
- **Parameters tab (⌘5)** (`ParametersView`): every parameter of the
  instrument + the preset toolbar / "Default (Sarangi Live)" reset.

## SarangiKit is Tarabdaar's own code

Until 2026‑07‑24 this section was a **re‑vendor divergence table**: SarangiKit
was a copy of `~/Desktop/sarangi`, a re‑sync overwrote every Tarabdaar‑local
change, and the code still compiled afterwards — which is what made it
dangerous. Each row named a feature that would silently disappear (the MPE
per‑channel bend, the jt warmth knobs, the tilt axes, the live‑parameter C
entry points, the per‑sample `outGain` interpolation, the stereo side path,
the removal of the linear taraf web).

None of that applies now. The upstream link is cut, there is no re‑sync, and
the DSP is edited here. What replaces the table as a safety net is
`TarafRemovalParityTests` (TarabdaarCore): it renders a scripted phrase through
`StringVoiceSource` and compares a **SHA‑256 of the samples** against the
shipping instrument, so any accidental change to the kernel, the table
builders or the post‑chain fails loudly and deliberately.

## Audio graph

`AudioEngine` (`Packages/TarabdaarCore/Sources/TarabdaarCore/AudioEngine.swift`) — one path:

```
MPE in ► routeSarangiModelMIDI ► StringVoiceSource ► symGain ► mainMixerNode ► output
                                  (BowEngine + CBowKernel, 96 kHz → 48 kHz)
```

The played voice is `StringVoiceSource`, an `AVAudioSourceNode` at the kernel's
native 48 kHz (the mixer input converts to the engine's 44.1 kHz), connected
**directly** to `symGain → mainMixerNode`. The kernel is the whole instrument,
so there is no coupled-network effect, no drive tap, and no master FX bus. MIDI
reaches it via `AudioEngine.sendHostedMIDI` → `routeSarangiModelMIDI` →
`BowControlMapper`.

## Harmonic display

*(Removed.)* The Harmonics tab went in the 2026‑07‑23 simplification, and
the machinery that fed it — `CombString.bufferCopy()`, `ResonatorBank`'s
snapshot/DFT path (`BankSnapshot.swift`) — was deleted with the coupled
network on 2026‑07‑24. The sympathetic strings still ring in and out of
resonance as the played pitch slides. **2026‑09‑01: the Mac Scope tab
(⌘8) is the per‑string view again**, built on display‑only KERNEL meters
rather than a bank snapshot/DFT: `bow_poly_scope_arm` turns on, per
modal‑jawari row, a peak envelope of the row's own radiated (post‑cap)
sample every tick and per‑mode peak envelopes of the first 16 modes'
modal velocities |p_k| every 4th tick — the string's own energy per mode,
which with the flat bridge‑force radiation is also its radiated spectrum up
to a constant (worker‑owned state, telemetry‑grade racy reads — the
gate‑probe convention);
`bow_poly_scope_jt` reads them with the row's CURRENT f0 (the follower's
retune) and its asleep flag, levels scaled by the jt output gain into
voice‑bus units; `bow_poly_scope_slots` reads each played string's ring
envelope (`senv`, the bridge‑wave chunk peak) so released strings still
meter. Armed only while the tab shows; disarmed = the exact legacy tick,
and `ScopeTelemetryTests` pins the armed render byte‑identical. The
tab's levels, centroids and drawing are described in
[UI Layout](ui-layout.md).

## Tests

Consolidated on 2026‑09‑03 to the bare guard set (the fitted‑number suites
and benches went — the sound is judged by ear; history lives in git):

- **`TarafRemovalParityTests`** (TarabdaarCore, gated) — the SHA‑256 of one
  rendered phrase pins the whole shipped signal path. Bless deliberately.
- **`ByteNullContractTests`** (SarangiKit) — every optional path armed at
  its resting value renders bit‑identically: scope meters, bus meter, FX
  rack, cap, comp, balance, governor, twang, inject, damp, tilt, body,
  register, master gain, tone LP bypass. Add a case per new "0 = off" knob.
- **Kernel lockstep** — `BowedStringEngineTests` (formula body, table
  shapes, the shared `stringBP()`/`testTaraf` scaffold), `BowPolyTests` (a
  chord stays bounded), `BowStereoTests` (fold‑down invariance),
  `TanpuraEngineTests` (exporter golden), `TouchMapperTests` (touch path ≡
  MIDI path — the parity substrate).
- **Realtime / rebuild / in‑place** (TarabdaarCore, gated, phase 2 serial) —
  `RealtimePerformanceTests`, `RebuildCostTests` (crossfade budget, silent
  publish), `ZipperTests` (fast flick), `LiveParamPushTests`.
- **Model and wire** (fast) — `ParamUnificationTests`, `PresetCodingTests`,
  `TLPCodecTests`, `TarabLinkTests`, `LinkIngestTests`,
  `GlideSequencerTests`, `ScaleLabelTests`, `TarabRatioTests`,
  `DroneStringTests`, `FretLayoutTests`, `FretWarpTests`, `ChordBarTests`,
  `TarabSetTests`, `LegacyMigrationTests`, `ScalePresetTests`.

Run `cd Packages/SarangiKit && swift test` and `tools/test-full.sh`.

## Calibration notes

- **Sample rates.** The **String voice** kernel runs at 96 kHz internally and
  half‑band‑decimates to 48 kHz (`StringVoiceSource`'s `AVAudioSourceNode`); the
  engine runs at `Config.sampleRate = 44100`, so the mixer input converts the
  48 kHz source.
- **Levels** live in the artifact / overrides — `bow_live_trim` and `bow_rev_*`
  set the output level, and the Mac pads hold a flat per‑note CC11 = 32 (the
  fitted expr median). Loud peaks are backstopped inside the kernel.
