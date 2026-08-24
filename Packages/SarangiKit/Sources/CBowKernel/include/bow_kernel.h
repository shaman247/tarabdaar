#ifndef BOW_KERNEL_H
#define BOW_KERNEL_H

/* The bow-friction physics kernel (bow_kernel_poly.c).
 *
 * `nb` independent bowed gut strings on ONE shared bridge: per sample the
 * string forces sum into the bridge force F, and each string's
 * -zload*bowW*Z*V loading is folded DELAY-FREE into the junction solve, so
 * stability is structural at any polyphony. All cross-sample state lives in
 * an opaque state object; bow_poly_init deep-copies every table (the caller
 * may free its arrays) and bow_poly_process runs one chunk, with controls
 * CHUNK-relative. Concatenated chunk outputs equal one long call.
 *
 * Controls are SLOT-MAJOR with an explicit stride: f0[b*stride + t] for
 * string b; xv/out are plain length-n arrays.
 *
 * There used to be a second, MONO kernel here (bow_kernel.c, ~2800 lines)
 * whose only purpose was byte-parity with the offline Python render's C
 * source. Tarabdaar never ran it — the live voice is always polyphonic — and
 * it was deleted with the rest of the upstream-parity machinery
 * (2026-07-24) along with its ~18 mono entry points.
 */
void *bow_poly_init(int nb, double sr, /* voices */ int nv, const int *L, const double *cs, const double *cp, const double *w0, const double *w1, const double *w2, const double *w3, const double *w4, const double *g, const double *lpA, const double *wout, const double *kap, const double *alphaw, const double *jw, const double *jl, const double *jn, const double *chg, const double *zdrv, const double *zi, const double *twt, /* body */ int K, const double *ba1, const double *ba2, const double *bn0, const double *bA, const double *bC, double yinf, double c0, double dcRho, /* voice-force path + bow */ double pgain, double pA, double bowW, double kret, double retA, double retMode, double rb0, double ra1, double ra2, double kdisp, double bowWidth, double bowCont, double Z, double Zt, double mu_s, double mu_d, double v0f, double nutA, double brA, double thLeak, double thA, double thD, double thFloor, double bowDisp, double jq, double jq2, double zload, double tdirect, double tshape, double tmix, double nA, double nT, double nPow, double nzHi, double nzLo, double nDir, double nzHiD, double passive, double gutG, double dispN, double nailK, double f0Open, double gutA2, double tdirUni, double torsRatio, double torsG, double torsC, double ageAp, double ageMs, double v0Powp, double v0Refp, double hairHzp, double hairRefp, double crWp, double crMsp, double jawRhop, double jawRollp, double jawRollAmpp);

void bow_poly_process(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out);

void bow_poly_free(void *vst);

/* Mount a fresh gut string on slot b (a newly-allocated note). This is NOT a
   memset: the state is zero everywhere EXCEPT the rate-and-state contact
   aging deficit, which starts at ageA — a fresh contact grips WEAKLY, where
   zero means full static grip (the opposite state, and only the unloaded
   friction branch would ever correct it). */
void bow_poly_reset_string(void *vst, int b);

/* 1 while string b is ringing or bowed (its section is being processed);
   0 once it has decayed to silence — the host may skip filling its
   controls. */
int bow_poly_active(const void *vst, int b);

/* MODAL-JAWARI sympathetic strings: modal-exact strings over grazing bones,
   implicit under-relaxed contact, dt/4 substepping, driven one-way by the
   previous sample's junction bridge force. This is the instrument's ENTIRE
   sympathetic response (the linear comb web that used to sit beside it was
   removed 2026-07-24). Load AFTER bow_poly_init — all dt-dependence lives in
   the builder's tables; never loading it (njt 0) is byte-null. Table layouts
   are documented at the definition. bow_poly_jt_load MALLOCS and is
   init-only: to change coefficients on a running kernel use
   bow_poly_jt_set_coeffs. */
void bow_poly_jt_load(void *vst, int njt, int J, const int *M, const double *ca, const double *cb, const double *ca4, const double *cb4, const double *wd, const double *phiO, const double *phiD, const double *phiU, const double *phiF, const double *b, const double *G, const double *G4, const double *gd, const double *gd4, const double *phys, const double *q0);

/* Persistent jt worker pool for the deferred post-pass — call OFF the audio
   thread (engine build); nth < 2 = the serial path. */
void bow_poly_jt_set_threads(void *vst, int nth);

/* ASYNC one-block-late live jt: the audio callback records the drive and
   mixes the completed web FIFO — it NEVER waits on workers; a dispatcher
   thread runs the pool. Call on/off OFF the audio thread.
   stats: [0] dropped drive blocks, [1] flat-filled samples,
   [2] FIFO fill, [3] async flag. */
void bow_poly_jt_set_async(void *vst, int on);
void bow_poly_jt_async_stats(void *vst, double *out4);

/* DRONE rows (2026-07-23, gradual-attack rev): press-to-sound jawari-taraf
   strings. The excitation is entirely a slewed filtered-noise drive — no
   impulse: _jt_drone sets the sustained drive level for row s (0 = release,
   the row rings out); _jt_pluck sets a decaying ONSET BOOST so the press
   swells (attack slew) to level+boost and relaxes into the sustain;
   _jt_drone_env sets the attack/release/boost-decay times (seconds);
   _jt_drone_tone sets the noise band-pass corners (Hz — lp = top, hp =
   bottom; the band keeps sub-audio drive from pumping the jawari buzz)
   and the pitched fraction toneMix (0..1: each row is driven by a sine
   at its own mode-1 frequency mixed with the noise — a played note
   hands a sympathetic string a PITCHED force, and pure noise rings the
   row's high modes far above their played-note balance). Non-positive
   lp/hp and negative toneMix keep the load-time defaults; call both at
   engine build, off the audio thread. Control-thread safe (per-row
   scalar writes; the jt tick reads them). Unused (all zero) is
   byte-null. */
void bow_poly_jt_drone(void *vst, int s, double level);
void bow_poly_jt_pluck(void *vst, int s, double amp);
void bow_poly_jt_drone_env(void *vst, double atkSec, double relSec, double onsetDecaySec);
void bow_poly_jt_drone_tone(void *vst, double lpHz, double hpHz, double toneMix);

/* MELODY-FOLLOWER row (Tarabdaar 2026-07-25): one modal-jawari row live-
   retunes to the played pitch. track_config arms row `row` (call at engine
   build off the audio thread, or again after bow_poly_jt_set_coeffs to
   refresh the law constants — re-arming the same row keeps its current
   pitch): f0 = the row's builder frequency, t60/fHf/bst = the damping /
   inharmonicity law the in-kernel retune re-applies (the builder's own
   values). row < 0 disarms. track_target writes the pitch target (Hz) —
   a plain scalar store from any thread (the drone-setter contract); the
   row's own jt tick slews toward it (~15 ms) and rebuilds only the
   f0-dependent mode tables in place, trimming the active mode count to
   the builder's fx corner (no under-resolved contact modes). Never
   arming it is byte-null. */
void bow_poly_jt_track_config(void *vst, int row, double f0, double t60, double fHf, double bst);
void bow_poly_jt_track_target(void *vst, double hz);

/* Runtime taraf axes, control-thread safe (per-scalar aligned writes read by
   the jt tick — the drone-setter contract; call any time after
   bow_poly_jt_load). set_lp: one-pole coefficient on the radiated jt sum
   (a = 1 - exp(-2*pi*fc/sr) at the kernel rate; a <= 0 = bypass).
   set_damp_t60: extra taraf decay as an amplitude t60 in seconds (<= 0 =
   off / natural ring). Both byte-null while unused. */
void bow_poly_jt_set_lp(void *vst, double a);
void bow_poly_jt_set_damp_t60(void *vst, double t60);

/* jt CHARGE GOVERNOR (Tarabdaar 2026-08-15, `bow_jt_gov`): per-row AGC
   on the bridge drive into the jt strings — a row whose ring already
   exceeds the graze target sheds incoming drive by ref/env, so the
   long-t60 anchor rows saturate at their single-strike ring instead of
   accumulating a whole phrase (the loud-buzz pile-up on kin notes).
   amt 0..1 = strength (0 = byte-null); refDisp = target contact-zone
   ring displacement in meters (apex scale), converted per row to a
   velocity bound refDisp·wd1 on a ~60 ms peak envelope of the zone
   velocity. Held-drone drive is added after the shed and never ducked.
   Drone-setter contract (plain scalar writes; the jt tick reads). */
void bow_poly_jt_set_gov(void *vst, double amt, double refDisp);

/* jt QUIESCENCE GATE (Tarabdaar 2026-08-17, `bow_jt_gate`): the idle-CPU
   gate — a row whose peak LOW-MODE momentum stays below refDisp·wd1
   for ~30 ms with no bridge drive above its wake bound and no drone
   drive freezes IN PLACE (static wrap kept — no re-settle strum on
   wake) and skips its whole modal tick, radiating exact 0; drive
   wakes it. Low modes are the meter: the wrap's high-mode tick-rate
   micro limit-cycle never rests, so zone velocity / raw radiated
   level cannot gate. refDisp = floor ring displacement in meters
   (apex scale, the jtGovRef convention); <= 0 disarms and wakes every
   row (byte-null). Drone-setter contract. _gate_asleep = rows
   currently sleeping (telemetry/tests; any thread). */
void bow_poly_jt_set_gate(void *vst, double refDisp);
int bow_poly_jt_gate_asleep(void *vst);
/* gate probe telemetry: out = {asleep rows, total rows, max ring/floor
   ratio, max drive/eps ratio, drone-hot 0/1} since the last read
   (ratios reset on read; >1 names the condition blocking sleep). Any
   thread. */
void bow_poly_jt_gate_probe(void *vst, double out[5]);

/* jt tone HP (Tarabdaar 2026-07-26): one-pole high-pass on the radiated jt
   sum, applied AFTER the tone LP inside the same output walk — the
   jawari-formant voicing (quiets the taraf's fundamental band under the
   high-harmonic cluster; pairs with the `bow_jt_tap` radiation tap).
   Same contract as set_lp: a = 1 - exp(-2*pi*fc/sr) at the kernel rate,
   a <= 0 = bypass (byte-exact legacy), mid + side states preserved on
   coefficient moves. Plain scalar write, any thread. */
void bow_poly_jt_set_hp(void *vst, double a);

/* jt BODY radiation mix (Tarabdaar 2026-08-01): 0..1 blend of the radiated
   jt sum through the SAME formula-body radiation bank the played strings
   radiate through (shared coefficient arrays, own filter state — mid +
   side twins inside the jt output walk, applied BEFORE the tone LP/HP).
   The coherence lever: the taraf rings from the instrument's body
   instead of beside it. Same contract as set_lp/set_hp: plain scalar
   write, any thread, slewed ~30 ms at the kernel rate; never calling it
   is byte-null. NOT part of the load ABI. */
void bow_poly_jt_set_body(void *vst, double mix);

/* HARMONIC-EVOLUTION lift (Tarabdaar 2026-07-26): a SIGNED vertical bone
   offset in meters (+ = bone dropped — the graze margin shrinks and the
   twang cascade opens; − = raised — the wrap presses past the knee, no
   twang). Slewed inside the kernel (~40 ms, once per divided jt sample)
   so the bone GLIDES: sweeping it live is a slow jawari adjustment, not
   the strum a stepped bone move (set_coeffs with a new profile) causes.
   The deep-substep threshold tracks it (jtDeep − 2.5·ev). The live form
   of the `bow_jt_evolve` parameter — BowEngine owns the 0…1 → meters
   map (apex · (1 − 4^(1−2e))). Clamped ±1e-3. 0 at rest = byte-null. */
void bow_poly_jt_set_evolve(void *vst, double meters);

/* RECRUITMENT weights (Tarabdaar 2026-07-26): per-row scale on the BRIDGE
   drive into each modal-jawari string — the taraf-selectivity axis. The
   host computes each row's harmonic kinship to the currently played
   pitches and writes the weights here (plain per-row scalar stores, the
   drone-setter contract); the jt tick slews each row ~30 ms and
   multiplies its incoming bridge force. Weights scale ONLY the bridge
   drive — the drone rows' own noise drive and the ring-out of energy a
   row already holds are untouched. Weights above 1 drive rows HARDER
   than the fitted operating point (the lush-chorus half of the axis —
   the graze nonlinearity turns extra drive into cascade, not just
   level). Writes min(n, njt) rows, clamped to [0, 4]; never calling it
   is byte-null (and all-ones is bit-exact). */
void bow_poly_jt_drive_weights(void *vst, const double *w, int n);

/* Radiated-gain multiplier on the jt web's output (the lush half of the
   recruitment axis), slewed ~30 ms inside the output walk. Drive
   weights saturate against the graze contact (pushing harder drains
   harder — measured x2 drive = +8% ring), so chorus PROMINENCE rides
   output level instead, which nothing drains. Plain scalar store, any
   thread (the drone-setter contract); clamped to [0, 4]; 1 = bit-exact,
   never calling it is byte-null. */
void bow_poly_jt_set_gain_mul(void *vst, double m);

/* LIVE PARAMETERS: overwrite state in place so a physics edit applies
   without rebuilding the engine. set_scalars replaces the 61 per-sample
   scalars (same order as bow_poly_init), leaving tables and running state
   untouched. set_body / jt_set_coeffs replace coefficient ARRAYS while
   KEEPING every history — the body resonators stay click-free and the
   jawari web relaxes into its new geometry. Both return 1 on success, 0
   when the shape moved (caller rebuilds). */
void bow_poly_set_scalars(void *vst, const double *s, int n);
int bow_poly_set_body(void *vst, int K, const double *ba1, const double *ba2,
                      const double *bn0, const double *bA, const double *bC);
int bow_poly_jt_set_coeffs(void *vst, int njt, int J, const int *M,
                           const double *ca, const double *cb,
                           const double *ca4, const double *cb4,
                           const double *wd, const double *phiO,
                           const double *phiD, const double *phiU,
                           const double *phiF, const double *b,
                           const double *G, const double *G4,
                           const double *gd, const double *gd4,
                           const double *phys);

/* STEREO SIDE OUTPUT (2026-07-23): a physically-derived SIDE stream carrying
   only the DIRECT radiation — the modal-jawari rows' own radiation (they sit
   on their own bridge, drones included) and the bow-contact noise at its
   string's position. All bridge-borne energy (played-string force) radiates
   from the ONE body — a fixed central radiator — and stays mid-only, so the
   image is a spread halo around a centred voice that never leans with the
   melody. The host forms L = mid + side, R = mid - side, so the L+R
   fold-down is bit-identical to the mono out. bow_poly_set_stereo arms it
   with pre-scaled pan arrays (call AFTER bow_poly_jt_load — the jt row pans
   need njt — off the audio thread, before rendering); NULL/wrong-length
   arrays leave that source family centred. bow_poly_process2 with
   outS = NULL, or never arming, is the mono path (bow_poly_process wraps
   it). */
void bow_poly_set_stereo(void *vst, const double *webPan, int nWeb, const double *jtPan, int nJt, const double *slotPan, int nSlot);

/* TARABDAAR SITAR TWANG (2026-08-01): a grazing jawari WRAP on the PLAYED
   strings' bridge termination — the sitar's flat-bridge contact on the
   melody string itself (the jt taraf's bones are untouched). While an
   excursion tip presses past the graze knee (per-side peak envelopes,
   so the graze engages at ANY strike level — the bow_jt_evolve
   consistency lesson), the bridge segment SHORTENS by a smoothed
   rolling-contact offset (the web's v2 roll idiom): a per-cycle,
   energy-CONSERVING phase modulation that pumps the harmonic cascade
   round trip by round trip (a subtractive fold alone measured as buzz
   + a choked ring), plus a light hysteretic contact-loss fold.
   set_twang is the live 0..1 amount (plain scalar store, any thread —
   the drone-setter contract; slewed ~30 ms in-kernel; 0 from a cold
   start / never calling is byte-null, a live 0 self-disarms after the
   slew). set_twang_shape is the OFFLINE fitting hook (the
   bow_jt_set_lift precedent): kneeR = graze knee as a fraction of each
   side's peak envelope, depth = the contact-loss fold slope, relMs =
   the envelope's release (attack is instant), rollSmp = the wrap's
   length shortening in kernel samples at amount 1, bright/ring/gut =
   the sitar-morph strengths (termination brightening exponent, release-
   damping ease, gut-loss ease — the wrap alone cascades into
   terminations that reabsorb HF within tens of ms); non-positive keeps
   the fitted defaults. */
void bow_poly_set_twang(void *vst, double amt);
void bow_poly_set_twang_shape(void *vst, double kneeR, double depth,
                              double relMs, double rollSmp,
                              double bright, double ring, double gut);

/* TARABDAAR INSTRUMENT WIDTH (2026-08-01 unifying rev): hear the ONE
   instrument from TWO observation points — a dense random-sign
   diffuse-field difference bank (700 Hz - 6.5 kHz, directivity-ramped)
   on the complete radiated output, run once per bus (voice, jt wash;
   shared coefficients, per-bus state — linearity keeps the split FX
   buses' side streams valid). The whole stereo law in one knob:
   interaural coherence falls with frequency like a real instrument's,
   with zero net lean (not a pan, not Haas/detune). width 0..1 is
   slewed ~30 ms render-side; 0 from a cold start / never calling =
   byte-null. Rides the bow_poly_set_stereo side stream (outS non-NULL
   + stOn). */
void bow_poly_set_stereo_width(void *vst, double width);
void bow_poly_process2(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out, double *outS);

/* TARABDAAR FX INSERTS (2026-08-01). Two byte-null-by-default hooks for the
   host FX rack:

   bow_poly_set_drive_fx — the "voice → taraf" insert: `fn` is called on
   the render thread with the block's recorded jt-drive buffer (kernel
   rate) after the record walk and BEFORE the post-pass consumes it
   (async mode: before the job publishes, keeping order + hook-state
   continuity). Install OFF the audio thread at engine build; NULL = the
   exact legacy path.

   bow_poly_process3 — the split-bus render: with outJt non-NULL the jt
   post-pass ADDS into outJt/outJtS (kernel-zeroed) instead of out/outS,
   handing the host separate voice and taraf buses. Each jt term lands
   exactly once per sample, so host-side `out[t] + outJt[t]` matches the
   fused path's rounding BIT-EXACTLY; outJt NULL is verbatim legacy
   (bow_poly_process2 wraps it). */
void bow_poly_set_drive_fx(void *vst, void (*fn)(void *ctx, double *buf, int n), void *ctx);

/* TARABDAAR SITAR→TARAF INJECT (2026-08-19). A second voice's rendered
   output drives the modal-jawari web sympathetically — the sitar main
   instrument's taraf halo. SPSC ring, mono, kernel rate:

   bow_poly_jt_inject_write — call from the OTHER voice's render callback
   with its block (mono mixdown). Drops the block when the ring is full
   (consumer stalled).

   bow_poly_jt_inject_gain — drive scale (control thread; allocates the
   ring on the first non-zero call — never call on an audio thread).

   The kernel mixes available ring samples into the recorded jt drive
   right before the drive-FX hook, so the voice→taraf FX insert shapes
   the injected drive too. Never calling these, zero gain, or an empty
   ring is byte-null (TarafRemovalParityTests' guarantee holds). */
void bow_poly_jt_inject_gain(void *vst, double g);
void bow_poly_jt_inject_write(void *vst, const double *x, int n);
void bow_poly_process3(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out, double *outS, double *outJt, double *outJtS);

#endif
