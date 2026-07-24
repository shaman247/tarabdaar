#ifndef BOW_KERNEL_H
#define BOW_KERNEL_H

/* One-shot render — the legacy entry point (init -> process(n) -> free),
   bit-identical to the pre-streaming monolith. Same C source as
   src/bowstring.py C_SRC; symbol renamed render -> bow_kernel_render. */
void bow_kernel_render(int n, double sr, /* controls (per sample, kernel rate) */ const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, /* voices */ int nv, const int *L, const double *cs, const double *cp, const double *w0, const double *w1, const double *w2, const double *w3, const double *w4, const double *g, const double *lpA, const double *wout, const double *kap, const double *alphaw, const double *jw, const double *jl, const double *jn, const double *chg, const double *zdrv, const double *zi, const double *twt, /* body */ int K, const double *ba1, const double *ba2, const double *bn0, const double *bA, const double *bC, double yinf, double c0, double dcRho, /* voice-force path + bow */ double pgain, double pA, double bowW, double kret, double retA, double retMode, double rb0, double ra1, double ra2, double kdisp, double bowWidth, double bowCont, double Z, double Zt, double mu_s, double mu_d, double v0f, double nutA, double brA, double thLeak, double thA, double thD, double thFloor, double bowDisp, double jq, double jq2, double zload, double tdirect, double tshape, double tmix, double nA, double nT, double nPow, double nzHi, double nzLo, double nDir, double nzHiD, double passive, double gutG, double dispN, double nailK, double f0Open, double gutA2, double tdirUni, double torsRatio, double torsG, double torsC, double ageAp, double ageMs, double v0Powp, double v0Refp, double hairHzp, double hairRefp, double crWp, double crMsp, double jawRhop, double jawRollp, double jawRollAmpp, double *out);

/* Streaming API (live-port groundwork): all cross-sample state lives in an
   opaque bow_state_t. bow_init deep-copies every table (the caller may free
   its arrays); bow_process runs one chunk (controls CHUNK-relative);
   concatenated chunk outputs are BIT-IDENTICAL to one bow_kernel_render call
   over the same controls. */
void *bow_init(double sr, /* voices */ int nv, const int *L, const double *cs, const double *cp, const double *w0, const double *w1, const double *w2, const double *w3, const double *w4, const double *g, const double *lpA, const double *wout, const double *kap, const double *alphaw, const double *jw, const double *jl, const double *jn, const double *chg, const double *zdrv, const double *zi, const double *twt, /* body */ int K, const double *ba1, const double *ba2, const double *bn0, const double *bA, const double *bC, double yinf, double c0, double dcRho, /* voice-force path + bow */ double pgain, double pA, double bowW, double kret, double retA, double retMode, double rb0, double ra1, double ra2, double kdisp, double bowWidth, double bowCont, double Z, double Zt, double mu_s, double mu_d, double v0f, double nutA, double brA, double thLeak, double thA, double thD, double thFloor, double bowDisp, double jq, double jq2, double zload, double tdirect, double tshape, double tmix, double nA, double nT, double nPow, double nzHi, double nzLo, double nDir, double nzHiD, double passive, double gutG, double dispN, double nailK, double f0Open, double gutA2, double tdirUni, double torsRatio, double torsG, double torsC, double ageAp, double ageMs, double v0Powp, double v0Refp, double hairHzp, double hairRefp, double crWp, double crMsp, double jawRhop, double jawRollp, double jawRollAmpp);

void bow_process(void *vst, int n, /* controls (per sample, kernel rate, CHUNK-relative) */ const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out);

/* MODAL-JAWARI sympathetic strings (2026-07-21): the validated tanpura-
   evolution block — modal-exact strings over grazing bones, implicit
   under-relaxed contact, dt/4 substepping, driven one-way by the previous
   sample's junction bridge force. Load AFTER bow_init (all dt-dependence
   lives in the builder's tables); never loading it (njt 0) is BYTE-NULL.
   Table layouts documented at the definition (bow_kernel.c). */
void bow_jt_load(void *vst, int njt, int J, const int *M, const double *ca, const double *cb, const double *ca4, const double *cb4, const double *wd, const double *phiO, const double *phiD, const double *phiU, const double *phiF, const double *b, const double *G, const double *G4, const double *gd, const double *gd4, const double *phys, const double *q0);
void bow_jt_probe(void *vst, double *pen, double *fprev);
void bow_jt_test(void *vst, int n, const double *drive, double *out);
/* persistent jt worker pool for the deferred post-pass — call OFF the
   audio thread (engine build); nth < 2 = the serial bit-exact path */
void bow_jt_set_threads(void *vst, int nth);
/* poly twins (ONE jt web at the poly level, shared junction force) */
void bow_poly_jt_load(void *vst, int njt, int J, const int *M, const double *ca, const double *cb, const double *ca4, const double *cb4, const double *wd, const double *phiO, const double *phiD, const double *phiU, const double *phiF, const double *b, const double *G, const double *G4, const double *gd, const double *gd4, const double *phys, const double *q0);
void bow_poly_jt_probe(void *vst, double *pen, double *fprev);
void bow_poly_jt_test(void *vst, int n, const double *drive, double *out);
void bow_poly_jt_set_threads(void *vst, int nth);
/* ASYNC one-block-late live jt: the audio callback records the drive
   and mixes the completed web FIFO — it NEVER waits on workers; a
   dispatcher thread runs the pool.  Call on/off OFF the audio thread.
   stats: [0] dropped drive blocks, [1] flat-filled samples,
   [2] FIFO fill, [3] async flag. */
void bow_poly_jt_set_async(void *vst, int on);
void bow_poly_jt_async_stats(void *vst, double *out4);
/* DRONE rows (2026-07-23, gradual-attack rev): press-to-sound
   jawari-taraf strings. The excitation is entirely a slewed
   filtered-noise drive — no impulse: bow_*_jt_drone sets the sustained
   drive level for row s (0 = release, the row rings out);
   bow_*_jt_pluck sets a decaying ONSET BOOST so the press swells
   (attack slew) to level+boost and relaxes into the sustain;
   bow_*_jt_drone_env sets the attack/release/boost-decay times
   (seconds; non-positive keeps defaults 80/40/350 ms) — call at engine
   build, off the audio thread. Control-thread safe (per-row scalar
   writes; the jt tick reads them). Unused (all zero) is BYTE-NULL —
   every golden untouched. */
void bow_jt_drone(void *vst, int s, double level);
void bow_jt_pluck(void *vst, int s, double amp);
void bow_jt_drone_env(void *vst, double atkSec, double relSec, double onsetDecaySec);
void bow_poly_jt_drone(void *vst, int s, double level);
void bow_poly_jt_pluck(void *vst, int s, double amp);
void bow_poly_jt_drone_env(void *vst, double atkSec, double relSec, double onsetDecaySec);
/* Starpad jt tone LP (2026-07-23): one-pole coefficient applied to the
   radiated jt sum (a = 1 - exp(-2*pi*fc/sr) at the kernel rate).
   a <= 0 = bypass — the historical bit-exact output. Call at engine
   build, off the audio thread. */
void bow_jt_set_lp(void *vst, double a);
void bow_poly_jt_set_lp(void *vst, double a);
/* Starpad TILT axes (2026-07-23 evening): runtime taraf purity + decay,
   control-thread-safe (per-scalar aligned writes read by the jt tick —
   the drone-setter contract; call any time after bow_[poly_]jt_load).
   set_lift: frac >= 0 drops the jawari bone frac * (load-time max
   static penetration, floor jtDeep) below its profile — large frac
   clears contact = PURE ringing taraf; 0 = byte-exact buzzy legacy.
   set_damp_t60: extra taraf decay as an amplitude t60 in seconds
   (<= 0 = off/natural ring). Both byte-null while unused. */
void bow_jt_set_lift(void *vst, double frac);
void bow_jt_set_damp_t60(void *vst, double t60);
void bow_poly_jt_set_lift(void *vst, double frac);
void bow_poly_jt_set_damp_t60(void *vst, double t60);
/* Starpad TILT purity (2026-07-23 night): scale of the formula-taraf
   WEB voices' BUZZ sources (jn in-loop contact/fold, jw output-tap
   grazing) — 1 = the byte-exact fitted buzz, 0 = no buzz. The jl
   in-loop LOSS is deliberately NOT scaled (it self-limits hot rings;
   removing it made half-purity buzz harder than base). The audible
   jangle lives mostly HERE, not in the modal-jt bones; the purity
   axis drives this together with the jt bone lift. Plain scalar
   write, any thread; host slews chunk-rate. */
void bow_set_jaw_gain(void *vst, double g);
void bow_poly_set_jaw_gain(void *vst, double g);

/* STARPAD (2026-07-24): overwrite the 61 per-sample scalars on a live
   state (same order as bow_init / bow_poly_init). Tables and running
   state are untouched — this is what lets a physics parameter apply
   without rebuilding the engine. */
void bow_set_scalars(void *vst, const double *s, int n);
void bow_poly_set_scalars(void *vst, const double *s, int n);

/* STARPAD stage 3 (2026-07-24): overwrite coefficient ARRAYS in place,
   keeping every history — the body modal bank and the modal-jawari
   tables. Return 1 on success, 0 when the shape moved (caller rebuilds). */
int bow_set_body(void *vst, int K, const double *ba1, const double *ba2,
                 const double *bn0, const double *bA, const double *bC);
int bow_poly_set_body(void *vst, int K, const double *ba1, const double *ba2,
                      const double *bn0, const double *bA, const double *bC);
int bow_jt_set_coeffs(void *vst, int njt, int J, const int *M,
                      const double *ca, const double *cb,
                      const double *ca4, const double *cb4, const double *wd,
                      const double *phiO, const double *phiD,
                      const double *phiU, const double *phiF,
                      const double *b, const double *G, const double *G4,
                      const double *gd, const double *gd4, const double *phys);
int bow_poly_jt_set_coeffs(void *vst, int njt, int J, const int *M,
                           const double *ca, const double *cb,
                           const double *ca4, const double *cb4,
                           const double *wd, const double *phiO,
                           const double *phiD, const double *phiU,
                           const double *phiF, const double *b,
                           const double *G, const double *G4,
                           const double *gd, const double *gd4,
                           const double *phys);

void bow_free(void *vst);

/* POLYPHONIC kernel (2026-07-16, app-side extension — bow_kernel_poly.c):
   nb independent bowed gut strings on the SAME bridge (one taraf web, one
   modal body, one radiation output). Per-sample the string forces sum into
   the bridge force F; in the passive-junction topology each played string's
   -zload*bowW*Z*V loading is folded DELAY-FREE into the junction solve
   (the one-sample-delayed mono law diverges for nb >= 4: jy0*nb*zZb > 1),
   so stability stays structural at any polyphony. The mono kernel above is
   the byte-parity twin of src/bowstring.py C_SRC and is NOT touched by
   this; a single active poly string reproduces it up to the delay-free
   loading fold (identical when V == 0, e.g. the generic string's rigid
   bridge). Same table/scalar arguments as bow_init, plus nb.
   Controls are SLOT-MAJOR with an explicit stride: f0[b*stride + t] for
   string b; xv/out are plain length-n arrays. */
void *bow_poly_init(int nb, double sr, /* voices */ int nv, const int *L, const double *cs, const double *cp, const double *w0, const double *w1, const double *w2, const double *w3, const double *w4, const double *g, const double *lpA, const double *wout, const double *kap, const double *alphaw, const double *jw, const double *jl, const double *jn, const double *chg, const double *zdrv, const double *zi, const double *twt, /* body */ int K, const double *ba1, const double *ba2, const double *bn0, const double *bA, const double *bC, double yinf, double c0, double dcRho, /* voice-force path + bow */ double pgain, double pA, double bowW, double kret, double retA, double retMode, double rb0, double ra1, double ra2, double kdisp, double bowWidth, double bowCont, double Z, double Zt, double mu_s, double mu_d, double v0f, double nutA, double brA, double thLeak, double thA, double thD, double thFloor, double bowDisp, double jq, double jq2, double zload, double tdirect, double tshape, double tmix, double nA, double nT, double nPow, double nzHi, double nzLo, double nDir, double nzHiD, double passive, double gutG, double dispN, double nailK, double f0Open, double gutA2, double tdirUni, double torsRatio, double torsG, double torsC, double ageAp, double ageMs, double v0Powp, double v0Refp, double hairHzp, double hairRefp, double crWp, double crMsp, double jawRhop, double jawRollp, double jawRollAmpp);

void bow_poly_process(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out);

/* STARPAD STEREO SIDE OUTPUT (2026-07-23, poly kernel only): a physically-
   derived SIDE stream carrying only the DIRECT radiation — the taraf
   strings' direct tap (pan-weighted through its own copy of the tdir
   shaping bank), the modal-jawari rows' own radiation (they sit on their
   own bridge), and the bow-contact noise at its string's position. All
   bridge-borne energy (played-string force, driven web resonance) radiates
   from the ONE body — a fixed central radiator — and stays mid-only, so
   the image is a spread halo around a centred voice that never leans with
   the melody. The host forms L = mid + side, R = mid - side, so the L+R
   fold-down is bit-identical to the legacy mono out. bow_poly_set_stereo
   arms it with pre-scaled pan arrays (call AFTER bow_poly_jt_load — the jt
   row pans need njt — off the audio thread, before rendering);
   NULL/wrong-length arrays leave that source family centred.
   bow_poly_process2 with outS = NULL, or never arming, is the bit-exact
   legacy path (bow_poly_process wraps it). */
void bow_poly_set_stereo(void *vst, const double *webPan, int nWeb, const double *jtPan, int nJt, const double *slotPan, int nSlot);
void bow_poly_process2(void *vst, int n, int stride, const double *f0, const double *vb, const double *fb, const double *beta, const double *gate, const double *xv, double *out, double *outS);

/* Mount a fresh gut string on slot b (a newly-allocated note). This is NOT a
   memset: the state is zero everywhere EXCEPT the rate-and-state contact
   aging deficit, which starts at ageA — a fresh contact grips WEAKLY, where
   zero means full static grip (the opposite state, and only the unloaded
   friction branch would ever correct it). Same seed as the mono kernel's
   init; poly/mono parity at nonzero bow_age_a depends on it. */
void bow_poly_reset_string(void *vst, int b);

/* 1 while string b is ringing or bowed (its section is being processed);
   0 once it has decayed to silence — the host may skip filling its
   controls. */
int bow_poly_active(const void *vst, int b);

void bow_poly_free(void *vst);

#endif
