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
