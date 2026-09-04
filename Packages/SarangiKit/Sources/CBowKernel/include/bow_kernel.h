#ifndef BOW_KERNEL_H
#define BOW_KERNEL_H

/* The bow-friction physics kernel (bow_kernel_poly.c).
 *
 * `nb` independent bowed gut strings on ONE shared bridge: per sample the
 * string forces sum into the bridge force F, each string taking the
 * one-sample bridge load -zload*bowW*Z*Vprev, and the modal body then
 * solves the bridge velocity V every string takes back. All cross-sample
 * state lives in an opaque state object; bow_poly_init deep-copies every
 * table (the caller may free its arrays) and bow_poly_process runs one
 * chunk, with controls CHUNK-relative. Concatenated chunk outputs equal
 * one long call.
 *
 * Controls are SLOT-MAJOR with an explicit stride: f0[b*stride + t] for
 * string b; xv/out are plain length-n arrays.
 *
 * Threading. "Drone-setter contract" = a plain aligned store the jt tick
 * reads on its next pass — safe from the control thread while rendering.
 * Loaders, pool/async switches, stereo arming and the FX-hook install
 * allocate or spawn threads: call them OFF the audio thread. Every optional
 * block is byte-null while unarmed (never loaded / 0 / NULL).
 *
 * Body: K modal sections. Then the 52 per-sample scalars, in THIS order —
 * the one layout, shared by bow_poly_init's arguments, the indices
 * bow_poly_set_scalars reads and BowTables.buildOpenString's array:
 *
 *    0 yinf        1 c0        2 dcRho      3 pgain      4 pA
 *    5 bowW        6 kret      7 retA       8 retMode    9 rb0
 *   10 ra1        11 ra2      12 kdisp     13 bowWidth  14 bowCont
 *   15 Z          16 Zt       17 mu_s      18 mu_d      19 v0f
 *   20 nutA       21 brA      22 thLeak    23 thA       24 thD
 *   25 thFloor    26 bowDisp  27 zload     28 nA        29 nT
 *   30 nPow       31 nzHi     32 nzLo      33 nDir      34 nzHiD
 *   35 gutG       36 dispN    37 nailK     38 f0Open    39 gutA2
 *   40 torsRatio  41 torsG    42 torsC     43 v0Pow     44 v0Ref
 *   45 hairHz     46 hairRef  47 lossReg   48 slideRate 49 slideDull
 *   50 slideNoise 51 slideAcc
 */
void *bow_poly_init(int nb, double sr, /* body */ int K, const double *ba1, const double *ba2, const double *bn0, const double *bA, const double *bC, double yinf, double c0, double dcRho, /* voice-force path + bow */ double pgain, double pA, double bowW, double kret, double retA, double retMode, double rb0, double ra1, double ra2, double kdisp, double bowWidth, double bowCont, double Z, double Zt, double mu_s, double mu_d, double v0f, double nutA, double brA, double thLeak, double thA, double thD, double thFloor, double bowDisp, double zload, double nA, double nT, double nPow, double nzHi, double nzLo, double nDir, double nzHiD, double gutG, double dispN, double nailK, double f0Open, double gutA2, double torsRatio, double torsG, double torsC, double v0Powp, double v0Refp, double hairHzp, double hairRefp, double lossRegp, double slideRatep, double slideDullp, double slideNoisep, double slideAccp);

void bow_poly_process(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out);

void bow_poly_free(void *vst);

/* Mount a fresh gut string on slot b. */
void bow_poly_reset_string(void *vst, int b);

/* 1 while string b is ringing or bowed; 0 once silent (the host may skip
   filling its controls). */
int bow_poly_active(const void *vst, int b);

/* MODAL-JAWARI strings — the taraf: modal-exact strings over grazing
   bones, implicit under-relaxed contact, dt/4 substepping, driven one-way
   by the previous sample's bridge force. Load AFTER bow_poly_init; MALLOCS,
   init-only (live changes: jt_set_coeffs). njt 0 is byte-null.
   Layout (njt rows, J zone points, M[r] modes per row, per-row blocks
   concatenated; ΣM = total modes, ΣJ = njt·J):
     M[njt]          active modes per row
     ca cb ca4 cb4   ΣM    per-mode damped rotation at dt and dt/4
     wd              ΣM    damped modal angular frequency (rad/s)
     radScale[njt]   per-row contact force → radiated velocity
     pinScale[njt]   per-row TERMINATION (pin) force → the same units
                     (radiated beside the contact force, always)
     cplScale[njt]   TWO-WAY COUPLING unit match: the reciprocal of the
                     factor radScale and pinScale SHARE, mu·L·wd1/(gout·π),
                     DIVIDED by the bank's total row gain Σ gout so the loop
                     gain does not grow with the document — the row's
                     DC-BLOCKED radiated sum reads back in bank-normalized
                     NEWTONS for jt_set_couple
     phiD            ΣM    bridge-force drive tap per mode (÷mu, ×drive)
     phiU phiF       ΣM·J  mode shape at the zone points (raw / ×wj÷mu)
     b               ΣJ    bone height at the zone points (m)
     G G4            ΣJ·J  zone Green's matrix at dt / dt/4
     gd gd4          ΣJ    its diagonals
     phys[7]         kc, alpha, hcB, deep, gain, drive, div
     q0              ΣM    static-wrap modal displacement at rest */
void bow_poly_jt_load(void *vst, int njt, int J, const int *M, const double *ca, const double *cb, const double *ca4, const double *cb4, const double *wd, const double *radScale, const double *pinScale, const double *cplScale, const double *phiD, const double *phiU, const double *phiF, const double *b, const double *G, const double *G4, const double *gd, const double *gd4, const double *phys, const double *q0);

/* Persistent jt worker pool for the deferred post-pass (off the audio
   thread); nth < 2 = serial. */
void bow_poly_jt_set_threads(void *vst, int nth);

/* ASYNC one-block-late jt: the callback never waits on workers; a
   dispatcher thread runs the pool. stats: [0] dropped drive blocks,
   [1] flat-filled samples, [2] FIFO fill, [3] async flag. */
void bow_poly_jt_set_async(void *vst, int on);
void bow_poly_jt_async_stats(void *vst, double *out4);

/* DRONE rows: press-to-sound taraf strings on a slewed filtered-noise
   drive. _drone: row s's sustained level (0 = release). _pluck: a decaying
   onset boost. _drone_env: attack / release / boost-decay (s).
   _drone_tone: band-pass corners (Hz; lp top, hp bottom) and toneMix 0..1,
   the fraction driven by a sine at the row's mode-1; non-positive /
   negative keep the defaults. Drone-setter contract; all-zero = byte-null. */
void bow_poly_jt_drone(void *vst, int s, double level);
void bow_poly_jt_pluck(void *vst, int s, double amp);
void bow_poly_jt_drone_env(void *vst, double atkSec, double relSec, double onsetDecaySec);
void bow_poly_jt_drone_tone(void *vst, double lpHz, double hpHz, double toneMix);

/* MELODY-FOLLOWER row: live-retunes to the played pitch. track_config
   arms `row` (off the audio thread; re-arm after jt_set_coeffs — keeps the
   pitch): f0 = builder frequency, t60/fHf/bst = the damping law re-applied
   in-kernel; row < 0 disarms. track_target (Hz, drone-setter contract):
   slews ~15 ms, rebuilds only the f0-dependent mode tables, trims the
   active modes to the fx corner. Never arming is byte-null. */
void bow_poly_jt_track_config(void *vst, int row, double f0, double t60, double fHf, double bst);
void bow_poly_jt_track_target(void *vst, double hz);

/* Drone-setter contract. set_lp: one-pole coefficient on the radiated jt
   sum, a = 1 - exp(-2*pi*fc/sr) at the kernel rate (<= 0 = bypass).
   set_damp_t60: extra decay as an amplitude t60 in s (<= 0 = off). */
void bow_poly_jt_set_lp(void *vst, double a);
void bow_poly_jt_set_damp_t60(void *vst, double t60);

/* VOICE-RELATIVE CAP (`bow_jt_cap*`): each row's RADIATED output held at
   or below ratio × the voice bus's peak (instant attack, ~1.2 s-τ
   release); per-row 150 ms envelope + gain (3 ms down, 120 ms recovery).
   hard 0..1 = fraction of the dB overshoot removed (0 = byte-null); a pure
   output gain, applied per string. Drone-setter. */
void bow_poly_jt_set_cap(void *vst, double hard, double ratio);

/* QUIESCENCE GATE (`bow_jt_gate`): a row whose peak LOW-MODE momentum
   stays below refDisp·wd1 for ~30 ms with no bridge or drone drive freezes
   IN PLACE, skips its tick and radiates exact 0; drive wakes it. Low modes
   are the meter — the wrap's high-mode micro limit-cycle never rests.
   refDisp in m (apex scale); <= 0 disarms (byte-null). Drone-setter
   contract. _gate_asleep = sleeping rows (any thread). */
void bow_poly_jt_set_gate(void *vst, double refDisp);
int bow_poly_jt_gate_asleep(void *vst);

/* SCOPE TELEMETRY (display only; racy reads, any thread). _scope_jt per
   row: f0 (Hz), radiated peak envelope (voice-bus units), asleep flag, the
   first K modal velocity envelopes |p_k| (row-major). _scope_slots: each
   played string's ring envelope. */
void bow_poly_scope_arm(void *vst, int on);
int bow_poly_scope_jt(void *vst, int nrows, double *f0, double *level, unsigned char *asleep, float *modes, int K);
int bow_poly_scope_slots(void *vst, double *level, int n);

/* Gate probe: out = {asleep rows, total rows, max ring/floor ratio, max
   drive/eps ratio, drone-hot 0/1} since the last read (ratios reset on
   read; >1 names what blocks sleep). Any thread. */
void bow_poly_jt_gate_probe(void *vst, double out[5]);

/* jt tone HP: one-pole high-pass on the radiated jt sum, after the tone
   LP. Same contract as set_lp. */
void bow_poly_jt_set_hp(void *vst, double a);

/* jt BODY mix 0..1: the radiated jt sum through the played strings' body
   radiation bank (shared coefficients, own state; before the tone LP/HP).
   Drone-setter contract, slewed ~30 ms; never calling it is byte-null. */
void bow_poly_jt_set_body(void *vst, double mix);

/* TWO-WAY BRIDGE COUPLING gain (`bow_jt_couple`, 0 = byte-null): the rows
   load the SAME bridge the played strings do, so their summed bridge force
   (contact + termination, DC-BLOCKED, converted to bank-normalized newtons
   by cplScale) is added back into the played strings' bridge force F —
   which drives the body, returns to every played string through kret, AND
   is what the next jt tick's drive is taken from, so the rows also exchange
   energy with each other through the bridge. DC-BLOCKED because the raw
   load carries each row's static wrap preload: a resting web must return
   ~0, not a constant bridge force (the un-blocked return self-excited the
   web from silence and was what made the first cut of this knob ring
   forever). A row the quiescence gate puts to sleep also FADES its last
   returned value out (jtCplLast) rather than stepping to 0 — a step on the
   shared bridge strums every other row.
   The web is a deferred post-pass, so the return rides a FIFO one post-pass
   block back — the drive's own one-tick lag law at block granularity; there
   is no algebraic loop either way. Slewed ~40 ms in the render loop.
   Control-thread scalar. */
void bow_poly_jt_set_couple(void *vst, double g);

/* HARMONIC-EVOLUTION lift: SIGNED vertical bone offset (m; + = dropped,
   the twang cascade opens; − = raised). Slewed in-kernel (~40 ms) so the
   bone GLIDES — a stepped bone (set_coeffs) strums the wrapped strings.
   The deep-substep threshold tracks it. Live form of `bow_jt_evolve`
   (BowEngine maps 0…1 → m). Clamped ±1e-3; 0 = byte-null. */
void bow_poly_jt_set_evolve(void *vst, double meters);

/* Per-row SIGNED bone offsets (m) ADDED to the lift, slewed ~40 ms — live
   form of `bow_jt_ev_reg`. Writes min(n, njt) rows, clamped ±1e-3; wakes a
   gated row whose target moves. Never calling / all-zeros = byte-null. */
void bow_poly_jt_set_evolve_ofs(void *vst, const double *ofs, int n);

/* Per-row CONTACT LAW (the chromatic bridge, `bow_jtc_*`): stiffness
   exponent alpha, hysteretic damping hcb, deep-substep threshold deep
   (2.5 × apex). NULL array = left as is. Writes min(n, njt) rows, clamped
   (alpha 1…3, hcb >= 0, deep >= 1e-7). Never calling it is byte-null; the
   global phys values tick bit-identically. Drone-setter contract. */
void bow_poly_jt_set_row_contact(void *vst, const double *alpha,
                                 const double *hcb, const double *deep,
                                 int n);

/* RECRUITMENT weights: per-row scale on the BRIDGE drive only (drone drive
   and stored ring-out untouched), slewed ~30 ms; the host writes harmonic
   kinship to the played pitches. Writes min(n, njt) rows, clamped [0, 4];
   never calling / all-ones = byte-null. Drone-setter contract. */
void bow_poly_jt_drive_weights(void *vst, const double *w, int n);

/* Radiated-gain multiplier on the jt output, slewed ~30 ms. Clamped
   [0, 4]; 1 / never calling = byte-null. Drone-setter contract. */
void bow_poly_jt_set_gain_mul(void *vst, double m);

/* LIVE PARAMETERS, no rebuild. set_scalars replaces the 52 scalars
   (bow_poly_init order; a shorter block leaves the tail inert), tables and
   running state untouched. set_body / jt_set_coeffs replace coefficient
   ARRAYS keeping every history; return 1 on success, 0 when the shape
   moved (caller rebuilds). */
void bow_poly_set_scalars(void *vst, const double *s, int n);
int bow_poly_set_body(void *vst, int K, const double *ba1, const double *ba2,
                      const double *bn0, const double *bA, const double *bC);
int bow_poly_jt_set_coeffs(void *vst, int njt, int J, const int *M,
                           const double *ca, const double *cb,
                           const double *ca4, const double *cb4,
                           const double *wd, const double *radScale,
                           const double *pinScale,
                           const double *cplScale,
                           const double *phiD,
                           const double *phiU,
                           const double *phiF, const double *b,
                           const double *G, const double *G4,
                           const double *gd, const double *gd4,
                           const double *phys);

/* STEREO SIDE OUTPUT: a SIDE stream of the DIRECT radiation only (taraf
   rows, bow-contact noise); bridge-borne energy stays mid-only. Host:
   L = mid + side, R = mid - side, so L+R equals the mono out bit-for-bit.
   set_stereo arms it with pre-scaled pan arrays (AFTER jt_load, off the
   audio thread); NULL / wrong length leaves that family centred. process2
   with outS = NULL, or never arming, is the mono path. */
void bow_poly_set_stereo(void *vst, const double *jtPan, int nJt, const double *slotPan, int nSlot);

/* INSTRUMENT WIDTH: a random-sign diffuse-field difference bank
   (700 Hz - 6.5 kHz) on the radiated output, once per bus — coherence
   falls with frequency, zero net lean. width 0..1, slewed ~30 ms; 0 =
   byte-null. Rides the set_stereo side stream. */
void bow_poly_set_stereo_width(void *vst, double width);
void bow_poly_process2(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out, double *outS);

/* FX INSERTS, byte-null by default. set_drive_fx (voice → taraf): `fn`
   runs on the render thread over the block's jt-drive buffer (kernel rate)
   BEFORE the post-pass consumes it; install off the audio thread; NULL =
   plain path. process3 (split bus): with outJt non-NULL the jt post-pass
   ADDS into outJt/outJtS (kernel-zeroed) instead of out/outS; each term
   lands exactly once, so `out[t] + outJt[t]` matches the fused rounding
   BIT-EXACTLY; outJt NULL = the fused path. */
void bow_poly_set_drive_fx(void *vst, void (*fn)(void *ctx, double *buf, int n), void *ctx);

/* SITAR→TARAF INJECT: another voice's output drives the taraf. SPSC ring,
   mono, kernel rate. inject_write: from the OTHER voice's render callback
   (drops when full). inject_gain: drive scale (control thread; allocates
   on the first non-zero call — never on an audio thread). Mixed into the
   jt drive before the drive-FX hook. Zero gain / empty = byte-null. */
void bow_poly_jt_inject_gain(void *vst, double g);
void bow_poly_jt_inject_write(void *vst, const double *x, int n);
void bow_poly_process3(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out, double *outS, double *outJt, double *outJtS);

#endif
