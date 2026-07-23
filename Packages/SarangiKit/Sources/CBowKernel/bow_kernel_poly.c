/* POLYPHONIC bow kernel (2026-07-16) — app-side extension, NOT part of the
   src/bowstring.py C_SRC byte-parity twin (bow_kernel.c stays untouched).

   nb independent bowed gut strings share ONE bridge on ONE instrument:
   per sample every active string runs the mono kernel's bow-string section
   verbatim (friction contacts, thermal rosin, contact noise, nut/bridge
   terminations, gut loss/dispersion) against its OWN delay lines, their
   transmitted forces sum into the single bridge force F, the one taraf web
   + modal body solve V from that sum, and each string then receives the
   same bridge velocity back through its own gated kret return. The bridge
   displacement FM (kdisp*disp) is shared — one bridge moves every string's
   termination.

   STABILITY (the one deliberate physics change vs the mono law): in the
   passive-junction topology the mono kernel loads the bridge with
   -zload*bowW*Z*Vprev (one-sample delay). The delayed form's per-sample
   feedback jy0*nb*zZb crosses 1 at nb=4 with the fitted body (measured
   jy0 = 0.204, zZb = 1.196) — the poly kernel instead folds the processed
   strings' loading into the DELAY-FREE junction solve:
       V = (Vstate + jy0*F0) / (1 + jy0*(jzsum + nProc*zZb))
   which is structurally passive at any polyphony (same -Z*V physics, same
   algebra as the taraf junction). With V == 0 (the generic string's rigid
   bridge) poly and mono are arithmetically identical per string.

   Strings that have decayed to silence are skipped whole (their state is
   zero — skipping is exact); the host can query bow_poly_active(). */

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif

#define MAXBOW 4096

static double pfrac_read(const double *buf, int n, int w, double delay) {
    double rp = (double)w - delay;
    while (rp < 0) rp += n;
    int i0 = (int)rp;
    double fr = rp - i0;
    int i1 = (i0 + 1) % n;
    return buf[i0 % n] * (1.0 - fr) + buf[i1] * fr;
}

/* per-string cross-sample state — the mono kernel's bow-string fields */
typedef struct {
    double buf1[MAXBOW], buf2[MAXBOW];
    double bufAB[64], bufBA[64];
    double bufAM[64], bufMA[64];
    double bufMB[64], bufBM[64];
    int wab, wba, wam, wma, wmb, wbm;
    int w1i, w2i;
    double nutLp, brLp, nutLp2, brLp2;
    double vRet, vRet2;
    double apXs[4], apYs[4];
    double nz1, nz2, nz1b, nz2b;
    double tEnv, fbPrev;
    double Tr3[3];
    double kGate;
    double senv;        /* chunk peak of |brLp| — ring envelope for skip */
    /* torsional wave loop (2026-07-16j; mono-kernel port, per string) */
    double bufT[MAXBOW];
    int wti;
    /* rate-and-state contact aging (2026-07-17g; mono-kernel port,
       per string): strength deficit, ageA at slip / unloaded, decays by
       ageDk per stick sample. ageA = 0 is BIT-NULL. */
    double ageDef, ageDef3[3];
    double hairLp, hairLp3[3];
    /* continuum-release contact (2026-07-19d; mono-kernel port, per
       string): stuck fraction of the hair band per contact site,
       relaxing toward s_eq(|demand|/grip) with release-only tau.
       crW = crMs = 0 is BIT-NULL (branch-gated). */
    double crS, crSB, crS3[3];
    int active;
} bow_pstring_t;

typedef struct {
    /* --- static config (deep copies; C owns the memory) --- */
    double sr;
    int nb, nv;
    int *L;
    double *cs, *cp, *w0, *w1, *w2, *w3, *w4, *g, *lpA, *wout, *kap;
    double *alphaw, *jw, *jl, *jn, *zdrv, *zi, *twt;
    int K;
    double *ba1, *ba2, *bn0, *bA, *bC;
    double yinf, c0, dcRho;
    double pgain, pA, bowW, kret, retA, retMode, rb0, ra1, ra2;
    double kdisp, bowWidth, bowCont, Z, Zt;
    double mu_s, mu_d, v0f, nutA, brA;
    double thLeak, thA, thD, thFloor;
    double bowDisp, jq, jq2, zload;
    double tdirect, tshape, tmix;
    double nA, nT, nPow, nzHi, nzLo, nDir, nzHiD, passive;
    double gutG, dispN, nailK, f0Open, gutA2;
    double torsRatio, torsG, torsC;
    double ageA, ageDk;
    double v0Pow, v0Ref;
    double hairHz, hairRef;
    double crW, crAt;
    double jawRho;
    double jawRoll, jawRollAmp;
    double *rollD, *rollE, *rollAv;
    /* DRIVEN-UNISON TAP DUCK (mono-kernel port; tuw 1.0 = off/bit-null):
       while ANY bowing slot sits within ~30 c of a voice's partial
       coincidence, that voice's direct-tap weight ducks toward tuw. */
    double tuw;
    double *fv, *dwt, *dtg;
    /* --- derived constants --- */
    /* ---- MODAL-JAWARI sympathetic strings (2026-07-21) ----
       The validated tanpura-evolution physics (scripts/tanpura_modal.py
       is the reference twin): per string a MODAL-EXACT stiff steel
       string (precomputed damped-rotation tables ca/cb + wd, quarter-
       step ca4/cb4) over a curved grazing bone sampled at J zone
       points; contact = the compliance-consistent IMPLICIT solve
       (vector Newton on the diagonal, UNDER-RELAXED outer off-diagonal
       lag) with dissipative-only Hunt-Crossley damping and dt/4
       SUBSTEPPING at deep engagement (penetration > jtDeep). Driven
       ONE-WAY by the PREVIOUS sample's junction bridge force (1-sample
       lag = zero stability interaction with the passive web); radiates
       through its own gain (the jawari taraf sit on their own bridge —
       the tdir rationale). All dt-dependence lives in the PRECOMPUTED
       tables (builders own it; C only applies). Loaded by bow_jt_load
       AFTER bow_init (the body-table pattern — init signature, the
       scalar vector and every existing golden untouched). njt == 0 or
       jtGain == 0: the block never runs, jtFprev never updates —
       BYTE-NULL by construction. */
    int njt, jtJ;
    int *jtM, *jtMOff, *jtZOff;
    double *jtCa, *jtCb, *jtCa4, *jtCb4, *jtWd, *jtWdI,
        *jtPhiO, *jtPhiD;   /* jtWdI = 1/wd (kills the division
        in the per-mode rotation — the M-side hot spot) */
    /* zone tables in FLOAT32 (2026-07-21 live optimization): the
       M*J matmuls + the J-vector solve dominate the cost and live
       happily in float (penetrations ~1e-6 m, ulp ~1e-13; forces
       O(100)); the MODAL RECURSION stays double (float drifts).
       Written as clang-vectorizable loops (NEON 4-wide). */
    float *jtPhiU, *jtPhiF;       /* zone matrices, concat M*J */
    float *jtB;                   /* bone profile, concat J */
    float *jtG, *jtG4;            /* compliance, concat J*J */
    float *jtGd, *jtGd4;          /* compliance diag, concat J */
    double jtKc, jtAlpha, jtHcB, jtDeep, jtGain, jtDrv;
    /* RATE DIVIDER (live): the jt block ticks every jtDiv-th
       kernel sample with tables built at sr/jtDiv; the held
       output's ZOH imaging dies in the kernel's own halfband
       decimation to 48k. Drive = mean of the skipped samples. */
    int jtDiv, jtPhase;
    double jtHold, jtFacc;
    double *jtQ, *jtP;            /* modal state, concat modes */
    double jtFprev, jtFmax, jtPenMax;   /* + telemetry */
    double jtFdc;                 /* drive DC tracker (~50 ms) */
    /* jt worker POOL (mono lockstep 2026-07-21 night): persistent
       high-QoS workers for the deferred block-parallel post-pass;
       spawned OFF the audio thread (bow_poly_jt_set_threads at
       engine build).  jtPoolN < 2 = serial replay (bit-exact vs the
       historical inline block). */
    int jtNth, jtPoolN, jtPoolInit, jtGen, jtDone, jtQuit;
    pthread_t jtTid[16];
    pthread_mutex_t jtMx;
    pthread_cond_t jtCvW, jtCvD;
    int jtWnT, jtWPer;
    double jtWPen[16];
    double *jtFrBuf; int jtFrCap;
    double *jtFdv; int *jtTkv; double *jtHp;
    struct { void *st; int idx; } jtParg[16];
    /* ---- ASYNC one-block-late jt (LIVE, 2026-07-21 late night) ----
       the audio callback NEVER waits: it records the block's drive
       into a ring slot and pops the web SIGNAL from a completed-
       samples FIFO (constant ~one-block wash latency; under overload
       the wash flat-fills from its last value instead of glitching).
       A DISPATCHER thread consumes drive jobs in order, runs the
       schedule + the worker pool synchronously on ITS thread, and
       appends the walked web signal to the FIFO.  All jt drive/hold
       state is dispatcher-owned in async mode.  Orchestration only —
       the per-string numerics are the same jt_tick_string. */
    int jtAsync;
    int jtDJobW, jtDJobR;             /* drive-job ring cursors */
    int jtDJobN[8];                   /* per-job sample count */
    double *jtDrvRing;                /* 8 * 4096 doubles */
    double *jtWebRing;                /* web-sample FIFO, 32768 */
    long long jtWebW, jtWebR;         /* FIFO cursors (mono counts) */
    double jtOutHold;                 /* audio-side last web value */
    pthread_t jtDTid;
    int jtDLive, jtDQuit;
    long long jtDropBlocks, jtFlatSamples;   /* telemetry */
    double jtMixG;                    /* live web fade-in: the builder's
                                         static wrap can never sit exactly
                                         on the kernel's SOLVER-DEFINED
                                         contact equilibrium (8 partial
                                         iterations), so every fresh
                                         engine releases a soft ~0.5 s
                                         settling chime — ramp the web
                                         mix over ~0.7 s instead (live
                                         async path only; offline serial
                                         stays bit-exact) */
    double hpG, jy0, jzsum;
    int psv;
    /* --- shared cross-sample state --- */
    int *off;              /* taraf voice ring arena */
    double *arena;
    int *widx;
    double *vx1, *vx2, *vlp, *jdc, *jenv, *sv;
    double venv;
    double bx1[96], bx2[96], by1[96], by2[96];
    double tx1[96], tx2[96], ty1[96], ty2[96];
    double hpY, hpX1;
    double pLp;
    double disp;           /* leaky bridge displacement (integral of V) */
    unsigned long long lcg;
    double Vprev;
    /* --- per-string state --- */
    bow_pstring_t *strs;
    int *proc;             /* per-chunk processed-string index scratch */
} bow_poly_state_t;

/* Mount a string in the FRESH-CONTACT friction state (mono kernel's init):
   the aging deficit starts at ageA — weak grip on a new contact. A bare
   memset would start it at 0 = full static grip, the opposite state, and
   only the unloaded branch (Fb <= 1e-6) would ever correct it. */
static void poly_mount_string(bow_poly_state_t *st, bow_pstring_t *S)
{
    memset(S, 0, sizeof(*S));
    S->ageDef = st->ageA;
    S->ageDef3[0] = S->ageDef3[1] = S->ageDef3[2] = st->ageA;
    /* a freshly-placed bow lands STUCK (mono init) */
    S->crS = 1.0; S->crSB = 1.0;
    S->crS3[0] = S->crS3[1] = S->crS3[2] = 1.0;
}

static double *pdup_d(const double *a, int n) {
    double *b = (double *)malloc(sizeof(double) * (n > 0 ? n : 1));
    memcpy(b, a, sizeof(double) * (size_t)n);
    return b;
}

/* continuum contact: equilibrium stuck fraction at demand ratio
   x = |stickF|/grip (mono kernel's cr_seq, verbatim) */
static double cr_seq(double x, double w) {
    if (w <= 1e-12) return x <= 1.0 ? 1.0 : 0.0;
    if (x <= 1.0 - w) return 1.0;
    if (x >= 1.0 + w) return 0.0;
    double u = (1.0 + w - x) / (2.0 * w);
    return u * u * (3.0 - 2.0 * u);
}

/* rolling-contact read (mono kernel's roll_read, verbatim) */
static double roll_read(const double *b, int wi, int len, int L,
                        double w0, double w1, double w2,
                        double w3, double w4, double rollD)
{
    int s0 = (int)rollD;
    double fr = rollD - (double)s0;
    int base = wi + len - L + s0;
    double a = w0 * b[base % len] + w1 * b[(base - 1) % len]
        + w2 * b[(base - 2) % len] + w3 * b[(base - 3) % len]
        + w4 * b[(base - 4) % len];
    if (fr < 1e-12) return a;
    int b1 = base + 1;
    double c = w0 * b[b1 % len] + w1 * b[(b1 - 1) % len]
        + w2 * b[(b1 - 2) % len] + w3 * b[(b1 - 3) % len]
        + w4 * b[(b1 - 4) % len];
    return (1.0 - fr) * a + fr * c;
}

void *bow_poly_init(int nb, double sr,
                    int nv, const int *L, const double *cs, const double *cp,
                    const double *w0, const double *w1, const double *w2,
                    const double *w3, const double *w4, const double *g,
                    const double *lpA, const double *wout, const double *kap,
                    const double *alphaw, const double *jw, const double *jl,
                    const double *jn, const double *chg,
                    const double *zdrv, const double *zi, const double *twt,
                    int K, const double *ba1, const double *ba2,
                    const double *bn0, const double *bA, const double *bC,
                    double yinf, double c0, double dcRho,
                    double pgain, double pA, double bowW, double kret,
                    double retA, double retMode, double rb0, double ra1,
                    double ra2, double kdisp, double bowWidth, double bowCont,
                    double Z, double Zt,
                    double mu_s, double mu_d, double v0f, double nutA,
                    double brA, double thLeak, double thA, double thD,
                    double thFloor, double bowDisp, double jq, double jq2,
                    double zload, double tdirect, double tshape, double tmix,
                    double nA, double nT, double nPow, double nzHi,
                    double nzLo, double nDir, double nzHiD, double passive,
                    double gutG, double dispN, double nailK, double f0Open,
                    double gutA2, double tdirUni,
                    double torsRatio, double torsG, double torsC,
                    double ageAp, double ageMs,
                    double v0Powp, double v0Refp,
                    double hairHzp, double hairRefp,
                    double crWp, double crMsp,
                    double jawRhop, double jawRollp, double jawRollAmpp)
{
    bow_poly_state_t *st = (bow_poly_state_t *)calloc(1, sizeof(bow_poly_state_t));
    st->sr = sr;
    st->nb = nb < 1 ? 1 : (nb > 64 ? 64 : nb);   /* chunk scratch is [64] */
    st->nv = nv; st->K = K > 96 ? 96 : K;
    st->L = (int *)malloc(sizeof(int) * (nv > 0 ? nv : 1));
    memcpy(st->L, L, sizeof(int) * (size_t)nv);
    st->cs = pdup_d(cs, nv);    st->cp = pdup_d(cp, nv);
    st->w0 = pdup_d(w0, nv);    st->w1 = pdup_d(w1, nv);
    st->w2 = pdup_d(w2, nv);    st->w3 = pdup_d(w3, nv);
    st->w4 = pdup_d(w4, nv);    st->g = pdup_d(g, nv);
    st->lpA = pdup_d(lpA, nv);  st->wout = pdup_d(wout, nv);
    st->kap = pdup_d(kap, nv);  st->alphaw = pdup_d(alphaw, nv);
    st->jw = pdup_d(jw, nv);    st->jl = pdup_d(jl, nv);
    st->jn = pdup_d(jn, nv);    st->zdrv = pdup_d(zdrv, nv);
    st->zi = pdup_d(zi, nv);    st->twt = pdup_d(twt, nv);
    st->ba1 = pdup_d(ba1, K);   st->ba2 = pdup_d(ba2, K);
    st->bn0 = pdup_d(bn0, K);   st->bA = pdup_d(bA, K);
    st->bC = pdup_d(bC, K);
    st->yinf = yinf; st->c0 = c0; st->dcRho = dcRho;
    st->pgain = pgain; st->pA = pA; st->bowW = bowW; st->kret = kret;
    st->retA = retA; st->retMode = retMode; st->rb0 = rb0;
    st->ra1 = ra1; st->ra2 = ra2; st->kdisp = kdisp;
    st->bowWidth = bowWidth; st->bowCont = bowCont;
    st->Z = Z; st->Zt = Zt;
    st->mu_s = mu_s; st->mu_d = mu_d; st->v0f = v0f;
    st->nutA = nutA; st->brA = brA;
    st->thLeak = thLeak; st->thA = thA; st->thD = thD;
    st->thFloor = thFloor;
    st->bowDisp = bowDisp; st->jq = jq; st->jq2 = jq2; st->zload = zload;
    st->tdirect = tdirect; st->tshape = tshape; st->tmix = tmix;
    st->nA = nA; st->nT = nT; st->nPow = nPow;
    st->nzHi = nzHi; st->nzLo = nzLo; st->nDir = nDir; st->nzHiD = nzHiD;
    st->passive = passive;
    st->gutG = gutG; st->dispN = dispN; st->nailK = nailK;
    st->f0Open = f0Open; st->gutA2 = gutA2; st->tuw = tdirUni;
    st->torsRatio = torsRatio; st->torsG = torsG; st->torsC = torsC;
    st->ageA = ageAp;
    st->ageDk = exp(-1.0 / ((ageMs > 0.01 ? ageMs : 0.01) * 1e-3 * sr));
    st->v0Pow = v0Powp; st->v0Ref = v0Refp;
    st->hairHz = hairHzp;
    st->hairRef = (hairRefp > 1e-6 ? hairRefp : 1.0);
    st->crW = crWp;
    st->crAt = crMsp > 1e-6
        ? 1.0 - exp(-1.0 / (crMsp * 1e-3 * sr)) : 1.0;
    st->jawRho = jawRhop;
    st->jawRoll = jawRollp;
    st->jawRollAmp = (jawRollAmpp > 1e-9 ? jawRollAmpp : 1e-9);
    st->fv = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    st->dwt = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    st->dtg = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    for (int i_ = 0; i_ < nv; i_++) {
        st->fv[i_] = sr / (double)(L[i_] > 2 ? L[i_] : 2);
        st->dwt[i_] = 1.0;
        st->dtg[i_] = 1.0;
    }
    /* taraf voice ring arena + pre-charge — verbatim mono */
    st->off = (int *)malloc(sizeof(int) * (nv + 1));
    int tot = 0;
    for (int i = 0; i < nv; i++) { st->off[i] = tot; tot += L[i] + 8; }
    st->off[nv] = tot;
    st->arena = (double *)calloc(tot > 0 ? tot : 1, sizeof(double));
    for (int i = 0; i < nv; i++) {
        if (chg[i] > 1e-12) {
            int len = L[i] + 8;
            int W = len / 6 > 8 ? len / 6 : 8;
            double *b = st->arena + st->off[i];
            for (int k = 0; k < W && k < len; k++)
                b[k] = chg[i] * 0.5 * (1.0 - cos(6.283185307179586 * k / W));
        }
    }
    st->widx = (int *)calloc(nv > 0 ? nv : 1, sizeof(int));
    st->vx1 = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->vx2 = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->vlp = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->jdc = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->jenv = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->sv = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->rollD = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->rollE = (double *)calloc(nv > 0 ? nv : 1, sizeof(double));
    st->rollAv = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    for (int i_ = 0; i_ < nv; i_++) {
        double tau = 0.15 * (double)(L[i_] > 2 ? L[i_] : 2);
        st->rollAv[i_] = 1.0 - exp(-1.0 / (tau > 1.0 ? tau : 1.0));
    }
    st->venv = 1e-6;
    st->hpG = 0.5 * (1.0 + dcRho);
    st->psv = passive > 0.5;
    double jy0 = yinf * st->hpG;
    double jzsum = 0.0;
    for (int k = 0; k < K; k++) jy0 += bA[k] * bn0[k];
    for (int i = 0; i < nv; i++) jzsum += zi[i];
    st->jy0 = jy0;
    st->jzsum = jzsum;
    st->lcg = 0x9E3779B97F4A7C15ULL;
    st->strs = (bow_pstring_t *)calloc(st->nb, sizeof(bow_pstring_t));
    for (int b = 0; b < st->nb; b++) poly_mount_string(st, &st->strs[b]);
    st->proc = (int *)malloc(sizeof(int) * st->nb);
    return (void *)st;
}

/* One string, one sample: the mono kernel's "---- bow string ----" section
   (friction contacts + terminations + contact/transition noise), verbatim
   against this string's state. Returns the string's transmitted bridge
   force; accumulates its direct-radiated noise; outputs the rdmp/gk this
   sample computed (the post-body return write needs them). */
static double poly_string_force(bow_poly_state_t *st, bow_pstring_t *S,
                                double f0t, double vbt, double fbt,
                                double betat, double gatet,
                                double *noiseDirAcc,
                                double *rdmpOut, double *gkOut)
{
    const double sr = st->sr;
    const double bowW = st->bowW, kdisp = st->kdisp;
    const double bowWidth = st->bowWidth, bowCont = st->bowCont;
    const double Z = st->Z, Zt = st->Zt;
    const double mu_s = st->mu_s, mu_d = st->mu_d, v0f = st->v0f;
    const double nutA = st->nutA, brA = st->brA;
    const double thLeak = st->thLeak, thA = st->thA, thD = st->thD;
    const double thFloor = st->thFloor;
    const double nA = st->nA, nT = st->nT, nPow = st->nPow;
    const double nzHi = st->nzHi, nzLo = st->nzLo;
    const double nDir = st->nDir, nzHiD = st->nzHiD;
    const double gutG = st->gutG, nailK = st->nailK;
    const double f0Open = st->f0Open, gutA2 = st->gutA2;
    const double torsRatio = st->torsRatio, torsG = st->torsG;
    const double torsC = st->torsC;
    const double ageA = st->ageA, ageDk = st->ageDk;
    const double v0Pow = st->v0Pow, v0Ref = st->v0Ref;
    const double hairHz = st->hairHz, hairRef = st->hairRef;
    const double crW = st->crW, crAt = st->crAt;
    const int crOn = (crW > 1e-12) || (crAt < 1.0 - 1e-12);
    const double nutFc0 = -log(nutA) * sr / 6.283185307179586;
    const double kg_atk = exp(-1.0 / (0.003 * sr));
    const double kg_rel = exp(-1.0 / (0.008 * sr));

    double F = 0.0;
    double o2 = 0.0;
    int bowOn = bowW > 1e-9;
    double bowForce = fbt * gatet;
    double kga = bowForce > S->kGate ? kg_atk : kg_rel;
    S->kGate = (1.0 - kga) * bowForce + kga * S->kGate;
    double gk = S->kGate >= 0.10 ? 1.0 : S->kGate * 10.0;
    double rdmp = 1.0 - (0.69 / fmax(f0t, 40.0)) * (1.0 - gk);
    *rdmpOut = rdmp;
    *gkOut = gk;
    if (bowOn) {
        double T = sr / fmax(f0t, 40.0);
        double L1 = fmax(2.0, betat * T * 0.5);
        double L2 = fmax(2.0, (1.0 - betat) * T * 0.5);
        double nutAf = nutA;
        if (nailK != 0.0) {
            double fcn = nutFc0 * pow(f0Open / fmax(f0t, 40.0), nailK);
            if (fcn > 0.45 * sr) fcn = 0.45 * sr;
            if (fcn < 200.0) fcn = 200.0;
            nutAf = exp(-6.283185307179586 * fcn / sr);
        }
        double h1 = pfrac_read(S->buf1, MAXBOW, S->w1i,
                               fmax(2.0, L1 * 2.0 - bowWidth));
        double dl = kdisp * st->disp;
        if (dl > 0.02) dl = 0.02; else if (dl < -0.02) dl = -0.02;
        double h2 = pfrac_read(S->buf2, MAXBOW, S->w2i,
                               fmax(2.0, (L2 * 2.0 - bowWidth) * (1.0 + dl)));
        double hBA = 0, hAB = 0;
        if (bowCont >= 2.5 && bowWidth >= 2.0) {
            /* Pitteroff v2: three hair-group contacts, own friction solves */
            static const double hs2[3] = {0.88, 1.0, 1.12};
            static const double hl2[3] = {0.92, 1.0, 1.09};
            double wseg = bowWidth * 0.5;
            double inL[3], inR[3], inj[3];
            inL[0] = h1;
            inL[1] = pfrac_read(S->bufAM, 64, S->wam, wseg);
            inL[2] = pfrac_read(S->bufMB, 64, S->wmb, wseg);
            inR[0] = pfrac_read(S->bufMA, 64, S->wma, wseg);
            inR[1] = pfrac_read(S->bufBM, 64, S->wbm, wseg);
            inR[2] = h2;
            double FbT = fbt * gatet / 3.0;
            double Zeff = Z / (1.0 + Z / Zt);
            for (int g = 0; g < 3; g++) {
                double vhg = inL[g] + inR[g];
                double soft = 1.0 - thA * hs2[g] * S->Tr3[g];
                if (soft < thFloor) soft = thFloor;
                double mDg = mu_d * (1.0 - thD * (1.0 - soft));
                double mSg = mDg + (mu_s - mu_d) * soft;
                if (ageA > 1e-12) {
                    if (FbT <= 1e-6) S->ageDef3[g] = ageA;
                    else mSg = mDg + (mSg - mDg) * (1.0 - S->ageDef3[g]);
                }
                double v0g = v0f * (0.85 + 0.15 * g);
                if (v0Pow > 1e-12)
                    v0g *= pow(v0Ref / fmax(FbT * 3.0, 0.05), v0Pow);
                double Ffg = 0.0;
                if (FbT > 1e-6) {
                    double dv0 = vhg - vbt;
                    double stickF = -2.0 * Zeff * dv0;
                    if (!crOn) {
                    if (fabs(stickF) <= mSg * FbT) {
                        Ffg = stickF;
                        if (ageA > 1e-12) S->ageDef3[g] *= ageDk;
                    } else {
                        if (ageA > 1e-12) S->ageDef3[g] = ageA;
                        double sg = dv0 > 0 ? 1.0 : -1.0;
                        Ffg = -sg * mDg * FbT;
                        for (int it = 0; it < 8; it++) {
                            double dv = dv0 + Ffg / (2.0 * Zeff);
                            double adv = fabs(dv);
                            double mu = mDg + (mSg - mDg)
                                / (1.0 + adv / v0g);
                            double gg = Ffg + sg * mu * FbT;
                            double dmu = -(mSg - mDg) /
                                (v0g * (1.0 + adv / v0g)
                                 * (1.0 + adv / v0g));
                            double dg = 1.0 + sg * FbT * dmu *
                                (dv > 0 ? 1.0 : -1.0) / (2.0 * Zeff);
                            Ffg -= gg / (fabs(dg) > 0.1 ? dg
                                         : (dg > 0 ? 0.1 : -0.1));
                        }
                    }
                    } else {
                        double xqg = fabs(stickF)
                            / fmax(mSg * FbT, 1e-30);
                        double seg = cr_seq(xqg, crW);
                        if (seg < S->crS3[g])
                            S->crS3[g] += crAt * (seg - S->crS3[g]);
                        else S->crS3[g] = seg;
                        if (S->crS3[g] > 1.0) S->crS3[g] = 1.0;
                        else if (S->crS3[g] < 0.0) S->crS3[g] = 0.0;
                        if (S->crS3[g] >= 1.0 - 1e-12) {
                            Ffg = stickF;
                        } else {
                            double sg = dv0 > 0 ? 1.0 : -1.0;
                            double Fsg = -sg * mDg * FbT;
                            for (int it = 0; it < 8; it++) {
                                double dv = dv0 + Fsg / (2.0 * Zeff);
                                double adv = fabs(dv);
                                double mu = mDg + (mSg - mDg)
                                    / (1.0 + adv / v0g);
                                double gg = Fsg + sg * mu * FbT;
                                double dmu = -(mSg - mDg) /
                                    (v0g * (1.0 + adv / v0g)
                                     * (1.0 + adv / v0g));
                                double dg = 1.0 + sg * FbT * dmu *
                                    (dv > 0 ? 1.0 : -1.0)
                                    / (2.0 * Zeff);
                                Fsg -= gg / (fabs(dg) > 0.1 ? dg
                                             : (dg > 0 ? 0.1 : -0.1));
                            }
                            Ffg = S->crS3[g] * stickF
                                + (1.0 - S->crS3[g]) * Fsg;
                        }
                        if (ageA > 1e-12)
                            S->ageDef3[g] = S->crS3[g]
                                * (S->ageDef3[g] * ageDk)
                                + (1.0 - S->crS3[g]) * ageA;
                    }
                    double dvh = (vhg - vbt) + Ffg / (2.0 * Zeff);
                    double lk = pow(thLeak, hl2[g]);
                    S->Tr3[g] = lk * S->Tr3[g]
                        + (1.0 - lk) * fabs(Ffg * dvh);
                } else if (crOn) {
                    S->crS3[g] = 1.0;
                }
                if (hairHz > 1e-6) {
                    double fcH = hairHz * fmax(FbT * 3.0, 0.02) / hairRef;
                    if (fcH > 0.45 * sr) fcH = 0.45 * sr;
                    double aH = exp(-6.283185307179586 * fcH / sr);
                    S->hairLp3[g] = (1.0 - aH) * Ffg + aH * S->hairLp3[g];
                    Ffg = S->hairLp3[g];
                }
                inj[g] = Ffg / (2.0 * Z);
            }
            double o1v = inR[0] + inj[0];
            S->bufAM[S->wam] = inL[0] + inj[0]; S->wam = (S->wam + 1) % 64;
            S->bufMA[S->wma] = inR[1] + inj[1]; S->wma = (S->wma + 1) % 64;
            S->bufMB[S->wmb] = inL[1] + inj[1]; S->wmb = (S->wmb + 1) % 64;
            S->bufBM[S->wbm] = inR[2] + inj[2]; S->wbm = (S->wbm + 1) % 64;
            o2 = inL[2] + inj[2];
            S->nutLp = (1.0 - nutAf) * o1v + nutAf * S->nutLp;
            S->buf1[S->w1i] = -S->nutLp * rdmp * gutG;
            S->w1i = (S->w1i + 1) % MAXBOW;
            S->brLp = (1.0 - brA) * o2 + brA * S->brLp;
            if (gutA2 > 0.0) {
                S->brLp2 = (1.0 - gutA2) * S->brLp + gutA2 * S->brLp2;
                F += bowW * 2.0 * Z * S->brLp2;
            } else {
                F += bowW * 2.0 * Z * S->brLp;
            }
        } else {
            if (bowWidth >= 1.0) {
                hBA = pfrac_read(S->bufBA, 64, S->wba, bowWidth);
                hAB = pfrac_read(S->bufAB, 64, S->wab, bowWidth);
            }
            double vh = (bowWidth >= 1.0) ? (h1 + hBA) : (h1 + h2);
            double tEcho = 0.0;
            if (torsC > 1e-9) {
                double Lt = (L1 + L2) * 2.0 / torsRatio;
                tEcho = pfrac_read(S->bufT, MAXBOW, S->wti, fmax(4.0, Lt));
                vh += torsC * tEcho;
            }
            double Ff = 0.0;
            double Fb = fbt * gatet * ((bowWidth >= 1.0) ? 0.5 : 1.0);
            double muS = 0, muD = 0;
            static const double hs[3] = {0.88, 1.0, 1.12};
            for (int hgi = 0; hgi < 3; hgi++) {
                double soft = 1.0 - thA * hs[hgi] * S->Tr3[hgi];
                if (soft < thFloor) soft = thFloor;
                double mD = mu_d * (1.0 - thD * (1.0 - soft));
                muD += mD / 3.0;
                muS += (mD + (mu_s - mu_d) * soft) / 3.0;
            }
            if (ageA > 1e-12) {
                if (Fb <= 1e-6) S->ageDef = ageA;
                else muS = muD + (muS - muD) * (1.0 - S->ageDef);
            }
            double v0e = v0f;
            if (v0Pow > 1e-12 && Fb > 1e-6)
                v0e = v0f * pow(v0Ref / fmax(Fb * 2.0, 0.05), v0Pow);
            if (Fb > 1e-6) {
                double Zeff = Z / (1.0 + Z / Zt);
                double dv0 = vh - vbt;
                double stickF = -2.0 * Zeff * dv0;
                if (!crOn) {
                if (fabs(stickF) <= muS * Fb) {
                    Ff = stickF;
                    if (ageA > 1e-12) S->ageDef *= ageDk;
                } else {
                    if (ageA > 1e-12) S->ageDef = ageA;
                    double s = dv0 > 0 ? 1.0 : -1.0;
                    Ff = -s * muD * Fb;
                    for (int it = 0; it < 8; it++) {
                        double dv = dv0 + Ff / (2.0 * Zeff);
                        double adv = fabs(dv);
                        double mu = muD + (muS - muD) / (1.0 + adv / v0e);
                        double gg = Ff + s * mu * Fb;
                        double dmu = -(muS - muD) /
                            (v0e * (1.0 + adv / v0e) * (1.0 + adv / v0e));
                        double dg = 1.0 + s * Fb * dmu *
                            (dv > 0 ? 1.0 : -1.0) / (2.0 * Zeff);
                        Ff -= gg / (fabs(dg) > 0.1 ? dg : (dg > 0 ? 0.1 : -0.1));
                    }
                }
                } else {
                    /* continuum contact (mono port): stuck-fraction
                       blend, release-only tau, snap capture */
                    double xq = fabs(stickF) / fmax(muS * Fb, 1e-30);
                    double se = cr_seq(xq, crW);
                    if (se < S->crS) S->crS += crAt * (se - S->crS);
                    else S->crS = se;
                    if (S->crS > 1.0) S->crS = 1.0;
                    else if (S->crS < 0.0) S->crS = 0.0;
                    if (S->crS >= 1.0 - 1e-12) {
                        Ff = stickF;
                    } else {
                        double s = dv0 > 0 ? 1.0 : -1.0;
                        double Fs = -s * muD * Fb;
                        for (int it = 0; it < 8; it++) {
                            double dv = dv0 + Fs / (2.0 * Zeff);
                            double adv = fabs(dv);
                            double mu = muD + (muS - muD) / (1.0 + adv / v0e);
                            double gg = Fs + s * mu * Fb;
                            double dmu = -(muS - muD) /
                                (v0e * (1.0 + adv / v0e) * (1.0 + adv / v0e));
                            double dg = 1.0 + s * Fb * dmu *
                                (dv > 0 ? 1.0 : -1.0) / (2.0 * Zeff);
                            Fs -= gg / (fabs(dg) > 0.1 ? dg
                                        : (dg > 0 ? 0.1 : -0.1));
                        }
                        Ff = S->crS * stickF + (1.0 - S->crS) * Fs;
                    }
                    if (ageA > 1e-12)
                        S->ageDef = S->crS * (S->ageDef * ageDk)
                            + (1.0 - S->crS) * ageA;
                }
            } else if (crOn) {
                S->crS = 1.0;
            }
            if (hairHz > 1e-6) {
                double fcH = hairHz * fmax(Fb, 0.02) / hairRef;
                if (fcH > 0.45 * sr) fcH = 0.45 * sr;
                double aH = exp(-6.283185307179586 * fcH / sr);
                S->hairLp = (1.0 - aH) * Ff + aH * S->hairLp;
                Ff = S->hairLp;
            }
            if (torsC > 1e-9) {
                double ZeffT = Z / (1.0 + Z / Zt);
                double dvS = (Fb > 1e-6)
                    ? ((vh - vbt) + Ff / (2.0 * ZeffT)) : 0.0;
                S->bufT[S->wti] = torsG * (dvS - tEcho);
                S->wti = (S->wti + 1) % MAXBOW;
            }
            S->tEnv = 0.99958 * S->tEnv + fabs(fbt * gatet - S->fbPrev);
            S->fbPrev = fbt * gatet;
            if ((nA > 1e-9 || nT > 1e-9 || nDir > 1e-9) && Fb > 1e-6) {
                st->lcg = st->lcg * 6364136223846793005ULL
                    + 1442695040888963407ULL;
                double xi = (double)((st->lcg >> 33) & 0xFFFFFF)
                    / 8388608.0 - 1.0;
                S->nz1 = S->nz1 + nzHi * (xi - S->nz1);
                S->nz2 = S->nz2 + nzLo * (S->nz1 - S->nz2);
                S->nz1b = S->nz1b + nzHiD * (xi - S->nz1b);
                S->nz2b = S->nz2b + nzHiD * (S->nz1b - S->nz2b);
                double dvn = (vh - vbt)
                    + Ff / (2.0 * (Z / (1.0 + Z / Zt)));
                double advn = fabs(dvn);
                double slipg = advn / (advn + v0f);
                Ff += (nA * pow(Fb, nPow) + nT * S->tEnv) * slipg
                    * (S->nz1 - S->nz2);
                *noiseDirAcc += nDir * pow(Fb, nPow) * slipg
                    * (S->nz2b - S->nz2);
            }
            {
                double dvh = (vh - vbt) + Ff / (2.0 * (Z / (1.0 + Z / Zt)));
                double P = fabs(Ff * dvh);
                static const double hl[3] = {0.92, 1.0, 1.09};
                for (int hgi = 0; hgi < 3; hgi++) {
                    double lk = pow(thLeak, hl[hgi]);
                    S->Tr3[hgi] = lk * S->Tr3[hgi] + (1.0 - lk) * P;
                }
            }
            double inj = Ff / (2.0 * Z);
            double o1, oAB;
            if (bowWidth >= 1.0) {
                o1 = hBA + inj;
                oAB = h1 + inj;
                /* ---- contact B (bridge side), own friction solve ---- */
                double vhB = h2 + hAB;
                double FfB = 0.0;
                if (Fb > 1e-6) {
                    double softB = 1.0 - thA * S->Tr3[1];
                    if (softB < thFloor) softB = thFloor;
                    double mDB = mu_d * (1.0 - thD * (1.0 - softB));
                    double mSB = mDB + (mu_s - mu_d) * softB;
                    double ZeffB = Z / (1.0 + Z / Zt);
                    double dv0B = vhB - vbt;
                    double stickB = -2.0 * ZeffB * dv0B;
                    if (!crOn) {
                    if (fabs(stickB) <= mSB * Fb) {
                        FfB = stickB;
                    } else {
                        double sB = dv0B > 0 ? 1.0 : -1.0;
                        FfB = -sB * mDB * Fb;
                        for (int it = 0; it < 8; it++) {
                            double dvB = dv0B + FfB / (2.0 * ZeffB);
                            double advB = fabs(dvB);
                            double muB = mDB + (mSB - mDB) / (1.0 + advB / v0f);
                            double ggB = FfB + sB * muB * Fb;
                            double dmuB = -(mSB - mDB) /
                                (v0f * (1.0 + advB / v0f) * (1.0 + advB / v0f));
                            double dgB = 1.0 + sB * Fb * dmuB *
                                (dvB > 0 ? 1.0 : -1.0) / (2.0 * ZeffB);
                            FfB -= ggB / (fabs(dgB) > 0.1 ? dgB
                                          : (dgB > 0 ? 0.1 : -0.1));
                        }
                    }
                    } else {
                        double xqB = fabs(stickB) / fmax(mSB * Fb, 1e-30);
                        double seB = cr_seq(xqB, crW);
                        if (seB < S->crSB)
                            S->crSB += crAt * (seB - S->crSB);
                        else S->crSB = seB;
                        if (S->crSB > 1.0) S->crSB = 1.0;
                        else if (S->crSB < 0.0) S->crSB = 0.0;
                        if (S->crSB >= 1.0 - 1e-12) {
                            FfB = stickB;
                        } else {
                            double sB = dv0B > 0 ? 1.0 : -1.0;
                            double FsB = -sB * mDB * Fb;
                            for (int it = 0; it < 8; it++) {
                                double dvB = dv0B + FsB / (2.0 * ZeffB);
                                double advB = fabs(dvB);
                                double muB = mDB + (mSB - mDB)
                                    / (1.0 + advB / v0f);
                                double ggB = FsB + sB * muB * Fb;
                                double dmuB = -(mSB - mDB) /
                                    (v0f * (1.0 + advB / v0f)
                                     * (1.0 + advB / v0f));
                                double dgB = 1.0 + sB * Fb * dmuB *
                                    (dvB > 0 ? 1.0 : -1.0) / (2.0 * ZeffB);
                                FsB -= ggB / (fabs(dgB) > 0.1 ? dgB
                                              : (dgB > 0 ? 0.1 : -0.1));
                            }
                            FfB = S->crSB * stickB + (1.0 - S->crSB) * FsB;
                        }
                    }
                    double dvhB = (vhB - vbt) + FfB / (2.0 * (Z / (1.0 + Z / Zt)));
                    S->Tr3[1] = thLeak * S->Tr3[1]
                        + (1.0 - thLeak) * fabs(FfB * dvhB);
                } else if (crOn) {
                    S->crSB = 1.0;
                }
                double injB = FfB / (2.0 * Z);
                o2 = hAB + injB;
                double oBA = h2 + injB;
                S->bufAB[S->wab] = oAB; S->wab = (S->wab + 1) % 64;
                S->bufBA[S->wba] = oBA; S->wba = (S->wba + 1) % 64;
            } else {
                o1 = h2 + inj;
                o2 = h1 + inj;
            }
            S->nutLp = (1.0 - nutAf) * o1 + nutAf * S->nutLp;
            S->buf1[S->w1i] = -S->nutLp * rdmp * gutG;
            S->w1i = (S->w1i + 1) % MAXBOW;
            S->brLp = (1.0 - brA) * o2 + brA * S->brLp;
            if (gutA2 > 0.0) {
                S->brLp2 = (1.0 - gutA2) * S->brLp + gutA2 * S->brLp2;
                F += bowW * 2.0 * Z * S->brLp2;
            } else {
                F += bowW * 2.0 * Z * S->brLp;
            }
        }
    }
    return F;
}

/* One string, one sample: the post-body bridge-motion return + stiffness
   dispersion + reflection write (the mono loop's second bowOn block). */
static void poly_string_return(bow_poly_state_t *st, bow_pstring_t *S,
                               double V, double rdmp, double gk)
{
    const double kretG = st->kret * gk;
    double vr;
    if (st->retMode >= 0.5) {
        vr = st->rb0 * (kretG * V) - st->ra1 * S->vRet - st->ra2 * S->vRet2;
        S->vRet2 = S->vRet; S->vRet = vr;
    } else {
        S->vRet = (1.0 - st->retA) * (kretG * V) + st->retA * S->vRet;
        S->vRet2 = (1.0 - st->retA) * S->vRet + st->retA * S->vRet2;
        vr = S->vRet2;
    }
    int dispNi = (int)(st->dispN + 0.5);
    if (dispNi < 1) dispNi = 1; if (dispNi > 4) dispNi = 4;
    double apy = -S->brLp + vr;
    for (int kd = 0; kd < dispNi; kd++) {
        double ay = st->bowDisp * apy + S->apXs[kd] - st->bowDisp * S->apYs[kd];
        S->apXs[kd] = apy; S->apYs[kd] = ay; apy = ay;
    }
    S->buf2[S->w2i] = apy * rdmp * st->gutG;
    S->w2i = (S->w2i + 1) % MAXBOW;
}

static float *dup_f(const double *a, int n)
{
    float *o = (float *)malloc(sizeof(float) * (size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) o[i] = (float)a[i];
    return o;
}

void bow_poly_jt_load(void *vst, int njt, int J, const int *M,
                 const double *ca, const double *cb,
                 const double *ca4, const double *cb4,
                 const double *wd, const double *phiO, const double *phiD,
                 const double *phiU, const double *phiF,
                 const double *b, const double *G, const double *G4,
                 const double *gd, const double *gd4, const double *phys,
                 const double *q0)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->njt = njt; st->jtJ = J;
    if (njt <= 0) return;
    int mtot = 0, ztot = 0;
    st->jtM = (int *)malloc(sizeof(int) * njt);
    st->jtMOff = (int *)malloc(sizeof(int) * njt);
    st->jtZOff = (int *)malloc(sizeof(int) * njt);
    for (int s = 0; s < njt; s++) {
        st->jtM[s] = M[s]; st->jtMOff[s] = mtot; st->jtZOff[s] = ztot;
        mtot += M[s]; ztot += M[s] * J;
    }
    st->jtCa = pdup_d(ca, mtot);   st->jtCb = pdup_d(cb, mtot);
    st->jtCa4 = pdup_d(ca4, mtot); st->jtCb4 = pdup_d(cb4, mtot);
    st->jtWd = pdup_d(wd, mtot);
    st->jtWdI = (double *)malloc(sizeof(double) * mtot);
    for (int i = 0; i < mtot; i++) st->jtWdI[i] = 1.0 / wd[i];
    st->jtPhiO = pdup_d(phiO, mtot); st->jtPhiD = pdup_d(phiD, mtot);
    st->jtPhiU = dup_f(phiU, ztot); st->jtPhiF = dup_f(phiF, ztot);
    st->jtB = dup_f(b, njt * J);
    st->jtG = dup_f(G, njt * J * J); st->jtG4 = dup_f(G4, njt * J * J);
    st->jtGd = dup_f(gd, njt * J);   st->jtGd4 = dup_f(gd4, njt * J);
    st->jtKc = phys[0]; st->jtAlpha = phys[1]; st->jtHcB = phys[2];
    st->jtDeep = phys[3]; st->jtGain = phys[4]; st->jtDrv = phys[5];
    st->jtDiv = (int)(phys[6] + 0.5);
    if (st->jtDiv < 1) st->jtDiv = 1;
    st->jtPhase = 0; st->jtHold = 0.0; st->jtFacc = 0.0;
    st->jtQ = pdup_d(q0, mtot);    /* settled static wrap (builder) */
    st->jtP = (double *)calloc(mtot, sizeof(double));
    st->jtFprev = 0.0;
}

#define JT_MAXM 72
#define JT_MAXJ 44

/* the implicit contact solve (tanpura_modal.contact_force, FLOAT +
   HERTZIAN FAST PATH): vector Newton on the diagonal compliance inside
   an UNDER-RELAXED off-diagonal lag loop; projection cap c/gd. When
   alpha == 1.5 (Hertz sphere-on-plane — the live default) every pow
   collapses to sqrtf; other alphas keep powf (offline exploration).
   Loops are written for clang auto-vectorization (float NEON). */
/* x^A for x in (1e-12, ~0.05], A in (0,1) — pure-arithmetic
   log2/exp2 (bit casts + minimax polys, floorf only; NO libm powf,
   so the bits are platform-identical).  HAND-PORTED from the mono
   kernel 2026-07-21k — the twins must move together (a bit split at
   alpha != 1.5 would hide behind the artifact's staged 1.5). */
static inline float jt_fastpow(float x, float A)
{
    union { float f; int32_t i; } u, v;
    u.f = x;
    const int e = ((u.i >> 23) & 255) - 127;
    u.i = (u.i & 0x007fffff) | 0x3f800000;      /* mantissa in [1,2) */
    const float m = u.f;
    const float lm = (((-7.915036575e-02f * m + 6.288157292e-01f) * m
                       - 2.081060203e+00f) * m + 4.028372767e+00f) * m
        - 2.496773768e+00f;
    const float y = A * ((float)e + lm);
    const float yi = floorf(y);
    const float yf = y - yi;
    const float p2 = ((7.901993961e-02f * yf + 2.241264441e-01f) * yf
                      + 6.968385764e-01f) * yf + 9.998119628e-01f;
    v.i = ((int32_t)yi + 127) << 23;            /* 2^yi */
    return p2 * v.f;
}

static int jt_solve(int J, const float *b_, const float *ustar,
                    const float *G, const float *gd,
                    float kc, float alpha, float *F)
{
    float eta0[JT_MAXJ], c[JT_MAXJ], f[JT_MAXJ];
    int any = 0;
    for (int j = 0; j < J; j++) {
        eta0[j] = b_[j] - ustar[j];
        if (eta0[j] > 0.0f) any = 1;
        F[j] = 0.0f;
    }
    if (!any) return 0;
    const int hertz = (alpha > 1.499f && alpha < 1.501f);
    /* ACTIVE-SET matvec (mono lockstep 2026-07-21k): only ~2 of J
       zone points carry force at the render op — iterate nonzero-F
       columns only (F[k] is EXACTLY 0.0f off the set; iteration 0
       has an empty list and gf = 0 exactly, as before). */
    int act[JT_MAXJ];
    int na = 0;
    for (int o = 0; o < 8; o++) {
        for (int j = 0; j < J; j++) {
            const float *Gr = G + (size_t)j * J;
            float gf = 0.0f;
            for (int i = 0; i < na; i++) {
                const int k = act[i];
                gf += Gr[k] * F[k];
            }
            c[j] = eta0[j] - (gf - gd[j] * F[j]);
            if (c[j] > 0.0f)
                f[j] = hertz ? kc * c[j] * sqrtf(c[j])
                             : kc * c[j] * jt_fastpow(c[j],
                                                      alpha - 1.0f);
            else
                f[j] = 0.0f;
        }
        /* inner Newton over the ACTIVE-c list only (bit-exact: the
           skipped points held f=0 already; per-point math and
           ascending order unchanged) */
        int acj[JT_MAXJ];
        int ncj = 0;
        for (int j = 0; j < J; j++)
            if (c[j] > 0.0f) acj[ncj++] = j;
        for (int it = 0; it < 5; it++) {
            for (int i2 = 0; i2 < ncj; i2++) {
                const int j = acj[i2];
                float eta = c[j] - gd[j] * f[j];
                float gv, gp;
                if (eta > 0.0f) {
                    float ea = hertz
                        ? sqrtf(eta > 1e-12f ? eta : 1e-12f)
                        : jt_fastpow(eta > 1e-12f ? eta : 1e-12f,
                                     alpha - 1.0f);
                    gv = f[j] - kc * ea * eta;
                    gp = 1.0f + kc * alpha * gd[j] * ea;
                } else { gv = f[j]; gp = 1.0f; }
                float fn = f[j] - gv / gp;
                if (fn < 0.0f) fn = 0.0f;
                float cap = c[j] / (gd[j] > 1e-30f ? gd[j] : 1e-30f);
                f[j] = fn > cap ? cap : fn;
            }
        }
        float dF = 0.0f, fm = 1.0f;
        for (int j = 0; j < J; j++) {
            float d = f[j] - F[j]; if (d < 0.0f) d = -d;
            if (d > dF) dF = d;
            if (f[j] > fm) fm = f[j];
        }
        /* float-appropriate exit: 1e-4 relative (forces O(100) sit
           above the float noise floor at 1e-6 — the exit never fired
           and every solve ran all its outer iterations) */
        if (dF < 1e-4f * fm) {
            for (int j = 0; j < J; j++) F[j] = f[j];
            break;
        }
        for (int j = 0; j < J; j++) F[j] += 0.5f * (f[j] - F[j]);
        na = 0;
        for (int j = 0; j < J; j++)
            if (F[j] > 0.0f) act[na++] = j;
    }
    return 1;
}

/* zone snapshot: u/udot at the J points from the double state
   (float matmuls; elementwise over j — vectorizes without fast-math) */
static void jt_zone(int M, int J, const float *phiU,
                    const double *q, const double *p,
                    float *u, float *ud)
{
    float qf[JT_MAXM], pf[JT_MAXM];
    for (int k = 0; k < M; k++) { qf[k] = (float)q[k]; pf[k] = (float)p[k]; }
    for (int j = 0; j < J; j++) { u[j] = 0.0f; ud[j] = 0.0f; }
    for (int k = 0; k < M; k++) {
        const float *Pr = phiU + (size_t)k * J;
        float qk = qf[k], pk = pf[k];
        for (int j = 0; j < J; j++) {
            u[j] += Pr[j] * qk;
            ud[j] += Pr[j] * pk;
        }
    }
}

/* contact core at step size dts on tables (G, gd): solve on the
   PRECOMPUTED zone snapshot, Hunt-Crossley (dissipative-only),
   impulse into q/p (double accumulation). */
static void jt_core(int M, int J, const float *u, const float *ud,
                    const float *phiF, const float *b_,
                    const float *G, const float *gd,
                    float kc, float alpha, float hcB,
                    double dts, double *q, double *p)
{
    float F[JT_MAXJ];
    if (!jt_solve(J, b_, u, G, gd, kc, alpha, F)) return;
    for (int j = 0; j < J; j++) {
        float hc = 1.0f + hcB * (-ud[j]);
        if (hc < 0.15f) hc = 0.15f;
        if (hc > 1.0f) hc = 1.0f;
        F[j] *= hc;
    }
    double h2 = 0.5 * dts * dts;
    /* project only the ACTIVE force columns (mono lockstep — the
       rest are exactly 0.0f and contribute nothing) */
    int actc[JT_MAXJ];
    int nac = 0;
    for (int j = 0; j < J; j++)
        if (F[j] != 0.0f) actc[nac++] = j;
    if (nac == 0) return;
    for (int k = 0; k < M; k++) {
        const float *Fr = phiF + (size_t)k * J;
        float imp = 0.0f;
        for (int i = 0; i < nac; i++) {
            const int j = actc[i];
            imp += Fr[j] * F[j];
        }
        p[k] += dts * (double)imp;
        q[k] += h2 * (double)imp;
    }
}

/* max penetration probe (deep-engagement substep trigger) */
static double jt_maxpen(int M, int J, const float *phiU,
                        const float *b_, const double *q)
{
    float u[JT_MAXJ];
    for (int j = 0; j < J; j++) u[j] = 0.0f;
    for (int k = 0; k < M; k++) {
        const float *Pr = phiU + (size_t)k * J;
        float qk = (float)q[k];
        for (int j = 0; j < J; j++) u[j] += Pr[j] * qk;
    }
    float pen = -1e30f;
    for (int j = 0; j < J; j++) {
        float d = b_[j] - u[j];
        if (d > pen) pen = d;
    }
    return (double)pen;
}

/* one modal-jawari sample: rotate every string, contact (substepped at
   deep engagement), one-way drive Fd, return the summed observation.
   Shared by bow_process, bow_jt_test and the poly kernel port. */
/* per-string advance — the threading unit (mono lockstep): touches
   only string s's state slices + shared read-only tables; penmax
   accumulates locally (merged by the caller). */
static double jt_tick_string(bow_poly_state_t *st, int s, double Fd,
                             double *penmax)
{
    const int J = st->jtJ;
    const double dtj = (double)st->jtDiv / st->sr;
    {
        const int Ms = st->jtM[s];
        const int mo = st->jtMOff[s], zo = st->jtZOff[s];
        double *q = st->jtQ + mo, *p = st->jtP + mo;
        const double *ca_ = st->jtCa + mo;
        const double *cb_ = st->jtCb + mo;
        const double *wd_ = st->jtWd + mo;
        const double *wi_ = st->jtWdI + mo;
        const float *phiU = st->jtPhiU + zo;
        const float *phiF = st->jtPhiF + zo;
        const float *b_ = st->jtB + (size_t)s * J;
        const float *G_ = st->jtG + (size_t)s * (size_t)J * J;
        const float *G4_ = st->jtG4 + (size_t)s * (size_t)J * J;
        const float *gd_ = st->jtGd + (size_t)s * J;
        const float *gd4_ = st->jtGd4 + (size_t)s * J;
        double qs[JT_MAXM], ps[JT_MAXM];
        memcpy(qs, q, sizeof(double) * (size_t)Ms);
        memcpy(ps, p, sizeof(double) * (size_t)Ms);
        for (int k = 0; k < Ms; k++) {
            double qk = q[k], pk = p[k];
            q[k] = ca_[k] * qk + cb_[k] * (pk * wi_[k]);
            p[k] = -cb_[k] * (wd_[k] * qk) + ca_[k] * pk;
        }
        float u[JT_MAXJ], ud[JT_MAXJ];
        jt_zone(Ms, J, phiU, q, p, u, ud);
        float pen = -1e30f;
        for (int j = 0; j < J; j++) {
            float d = b_[j] - u[j];
            if (d > pen) pen = d;
        }
        if ((double)pen > *penmax) *penmax = (double)pen;
        if ((double)pen > st->jtDeep) {
            /* deep engagement: restore, 4 quarter steps */
            memcpy(q, qs, sizeof(double) * (size_t)Ms);
            memcpy(p, ps, sizeof(double) * (size_t)Ms);
            const double *ca4_ = st->jtCa4 + mo;
            const double *cb4_ = st->jtCb4 + mo;
            double dt4 = 0.25 * dtj;
            for (int ss = 0; ss < 4; ss++) {
                for (int k = 0; k < Ms; k++) {
                    double qk = q[k], pk = p[k];
                    q[k] = ca4_[k] * qk + cb4_[k] * (pk * wi_[k]);
                    p[k] = -cb4_[k] * (wd_[k] * qk) + ca4_[k] * pk;
                }
                jt_zone(Ms, J, phiU, q, p, u, ud);
                jt_core(Ms, J, u, ud, phiF, b_, G4_, gd4_,
                        (float)st->jtKc, (float)st->jtAlpha,
                        (float)st->jtHcB, dt4, q, p);
            }
        } else {
            jt_core(Ms, J, u, ud, phiF, b_, G_, gd_,
                    (float)st->jtKc, (float)st->jtAlpha,
                    (float)st->jtHcB, dtj, q, p);
        }
        for (int k = 0; k < Ms; k++)
            p[k] += dtj * Fd * st->jtPhiD[mo + k];
        double yjt = 0.0;
        for (int k = 0; k < Ms; k++)
            yjt += st->jtPhiO[mo + k] * p[k];
        return yjt;
    }
}

static double jt_tick(bow_poly_state_t *st, double Fd)
{
    double jrad = 0.0;
    double pen = st->jtPenMax;
    for (int s = 0; s < st->njt; s++)
        jrad += jt_tick_string(st, s, Fd, &pen);
    st->jtPenMax = pen;
    return jrad;
}

/* ---- persistent jt worker pool (mono lockstep) ---- */
#define JT_POOL_CH 65536

static void *jt_pool_run(void *va)
{
    struct { void *st; int idx; } *pa = va;
    bow_poly_state_t *st = (bow_poly_state_t *)pa->st;
    const int idx = pa->idx;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    int mygen = 0;
    pthread_mutex_lock(&st->jtMx);
    for (;;) {
        while (st->jtGen == mygen && !st->jtQuit)
            pthread_cond_wait(&st->jtCvW, &st->jtMx);
        if (st->jtQuit) break;
        mygen = st->jtGen;
        const int nT = st->jtWnT;
        const int per = st->jtWPer;
        pthread_mutex_unlock(&st->jtMx);
        const int s0 = idx * per;
        int s1 = s0 + per;
        if (s1 > st->njt) s1 = st->njt;
        double pen = st->jtWPen[idx];
        double *hp = st->jtHp + (size_t)idx * JT_POOL_CH;
        const double *fd = st->jtFdv;
        for (int s = s0; s < s1; s++)
            for (int k = 0; k < nT; k++)
                hp[k] += jt_tick_string(st, s, fd[k], &pen);
        st->jtWPen[idx] = pen;
        pthread_mutex_lock(&st->jtMx);
        st->jtDone++;
        if (st->jtDone >= st->jtPoolN)
            pthread_cond_signal(&st->jtCvD);
    }
    pthread_mutex_unlock(&st->jtMx);
    return NULL;
}

static void jt_pool_stop(bow_poly_state_t *st)
{
    if (st->jtPoolN < 2) { st->jtPoolN = 0; return; }
    pthread_mutex_lock(&st->jtMx);
    st->jtQuit = 1;
    pthread_cond_broadcast(&st->jtCvW);
    pthread_mutex_unlock(&st->jtMx);
    for (int i = 0; i < st->jtPoolN; i++)
        pthread_join(st->jtTid[i], NULL);
    st->jtPoolN = 0;
    st->jtQuit = 0;
}

void bow_poly_jt_set_threads(void *vst, int nth)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (nth < 1) nth = 1;
    if (nth > 16) nth = 16;
    if (st->njt > 0 && nth > st->njt) nth = st->njt;
    st->jtNth = nth;
    if (st->jtPoolN == nth || (st->jtPoolN == 0 && nth < 2)) return;
    if (!st->jtPoolInit) {
        pthread_mutex_init(&st->jtMx, NULL);
        pthread_cond_init(&st->jtCvW, NULL);
        pthread_cond_init(&st->jtCvD, NULL);
        st->jtPoolInit = 1;
    }
    jt_pool_stop(st);
    if (nth < 2) return;
    if (!st->jtHp) {
        st->jtFrCap = JT_POOL_CH;
        st->jtFrBuf = (double *)malloc(sizeof(double) * JT_POOL_CH);
        st->jtFdv = (double *)malloc(sizeof(double) * JT_POOL_CH);
        st->jtTkv = (int *)malloc(sizeof(int) * JT_POOL_CH);
        st->jtHp = (double *)malloc(sizeof(double) * 16 * JT_POOL_CH);
    }
    st->jtGen = 0; st->jtDone = 0; st->jtQuit = 0;
    st->jtPoolN = nth;
    for (int i = 0; i < nth; i++) {
        st->jtParg[i].st = st;
        st->jtParg[i].idx = i;
        pthread_create(&st->jtTid[i], NULL, jt_pool_run,
                       &st->jtParg[i]);
    }
}

/* ---- async one-block-late jt (LIVE): dispatcher machinery ---- */
#define JT_ABLK 4096
#define JT_ARING 8
#define JT_WEBN 32768

/* run one drive job to a WEB SIGNAL buffer: the schedule + the
   worker pool (blocking waits are fine — this runs on the DISPATCHER
   thread, never the audio callback) + the hold walk.  The numerics
   are the sync post-pass's exactly; only the destination differs. */
static void jt_run_job(bow_poly_state_t *st, const double *drv, int n,
                       double *web)
{
    int nT = 0;
    double *fdv = st->jtFdv;
    int *tkv = st->jtTkv;
    for (int t = 0; t < n; t++) {
        double F = drv[t];
        st->jtFdc += 2e-4 * (F - st->jtFdc);
        st->jtFacc += F - st->jtFdc;
        if (++st->jtPhase >= st->jtDiv) {
            double Fd = st->jtFacc / st->jtDiv;
            st->jtFacc = 0.0; st->jtPhase = 0;
            fdv[nT] = st->jtFprev * st->jtDrv;
            tkv[nT] = t;
            nT++;
            st->jtFprev = Fd;
        }
        if (F > st->jtFmax) st->jtFmax = F;
        if (-F > st->jtFmax) st->jtFmax = -F;
    }
    if (nT == 0) {
        for (int t = 0; t < n; t++)
            web[t] = st->jtGain * st->jtHold;
        return;
    }
    const int nth = st->jtPoolN;
    if (nth >= 2) {
        double *hp = st->jtHp;
        for (int th = 0; th < nth; th++) {
            memset(hp + (size_t)th * JT_POOL_CH, 0,
                   sizeof(double) * (size_t)nT);
            st->jtWPen[th] = st->jtPenMax;
        }
        pthread_mutex_lock(&st->jtMx);
        st->jtWnT = nT;
        st->jtWPer = (st->njt + nth - 1) / nth;
        st->jtDone = 0;
        st->jtGen++;
        pthread_cond_broadcast(&st->jtCvW);
        while (st->jtDone < st->jtPoolN)
            pthread_cond_wait(&st->jtCvD, &st->jtMx);
        pthread_mutex_unlock(&st->jtMx);
        for (int th = 0; th < nth; th++)
            if (st->jtWPen[th] > st->jtPenMax)
                st->jtPenMax = st->jtWPen[th];
        double hold = st->jtHold;
        int ki = 0;
        for (int t = 0; t < n; t++) {
            if (ki < nT && t == tkv[ki]) {
                double H = 0.0;
                for (int th = 0; th < nth; th++)
                    H += hp[(size_t)th * JT_POOL_CH + ki];
                hold = H;
                ki++;
            }
            web[t] = st->jtGain * hold;
        }
        st->jtHold = hold;
    } else {
        double hold = st->jtHold;
        int ki = 0;
        for (int t = 0; t < n; t++) {
            if (ki < nT && t == tkv[ki]) {
                hold = jt_tick(st, fdv[ki]);
                ki++;
            }
            web[t] = st->jtGain * hold;
        }
        st->jtHold = hold;
    }
}

static void *jt_dispatch_run(void *va)
{
    bow_poly_state_t *st = (bow_poly_state_t *)va;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    double webBuf[JT_ABLK];
    pthread_mutex_lock(&st->jtMx);
    for (;;) {
        while (!st->jtDQuit
               && __atomic_load_n(&st->jtDJobW, __ATOMIC_ACQUIRE)
                  == st->jtDJobR) {
            /* the callback's wake is opportunistic (trylock) — a
               1 ms timed backstop bounds a missed signal */
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 1000000;
            if (ts.tv_nsec >= 1000000000) {
                ts.tv_nsec -= 1000000000;
                ts.tv_sec += 1;
            }
            pthread_cond_timedwait(&st->jtCvW, &st->jtMx, &ts);
        }
        if (st->jtDQuit) break;
        const int slot = st->jtDJobR & (JT_ARING - 1);
        const int n = st->jtDJobN[slot];
        pthread_mutex_unlock(&st->jtMx);
        jt_run_job(st, st->jtDrvRing + (size_t)slot * JT_ABLK, n,
                   webBuf);
        long long w = st->jtWebW;
        for (int t = 0; t < n; t++)
            st->jtWebRing[(w + t) & (JT_WEBN - 1)] = webBuf[t];
        __atomic_store_n(&st->jtWebW, w + n, __ATOMIC_RELEASE);
        pthread_mutex_lock(&st->jtMx);
        st->jtDJobR++;
    }
    pthread_mutex_unlock(&st->jtMx);
    return NULL;
}

void bow_poly_jt_set_async(void *vst, int on)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (on && !st->jtDLive) {
        if (!st->jtPoolInit) {
            pthread_mutex_init(&st->jtMx, NULL);
            pthread_cond_init(&st->jtCvW, NULL);
            pthread_cond_init(&st->jtCvD, NULL);
            st->jtPoolInit = 1;
        }
        if (!st->jtFdv) {
            /* dispatcher path uses the schedule scratch even when the
               worker pool is off (serial-in-dispatcher fallback) */
            st->jtFdv = (double *)malloc(sizeof(double) * JT_POOL_CH);
            st->jtTkv = (int *)malloc(sizeof(int) * JT_POOL_CH);
        }
        if (!st->jtDrvRing) {
            st->jtDrvRing = (double *)malloc(sizeof(double)
                                             * JT_ARING * JT_ABLK);
            st->jtWebRing = (double *)calloc(JT_WEBN, sizeof(double));
        }
        st->jtDJobW = 0; st->jtDJobR = 0;
        st->jtWebW = 0; st->jtWebR = 0;
        st->jtOutHold = 0.0;
        st->jtMixG = 0.0;
        st->jtDropBlocks = 0; st->jtFlatSamples = 0;
        st->jtDQuit = 0;
        st->jtAsync = 1;
        pthread_create(&st->jtDTid, NULL, jt_dispatch_run, st);
        st->jtDLive = 1;
    } else if (!on && st->jtDLive) {
        pthread_mutex_lock(&st->jtMx);
        st->jtDQuit = 1;
        pthread_cond_broadcast(&st->jtCvW);
        pthread_mutex_unlock(&st->jtMx);
        pthread_join(st->jtDTid, NULL);
        st->jtDLive = 0;
        st->jtAsync = 0;
        st->jtDQuit = 0;
    }
}

void bow_poly_jt_async_stats(void *vst, double *out4)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    out4[0] = (double)st->jtDropBlocks;
    out4[1] = (double)st->jtFlatSamples;
    out4[2] = (double)(st->jtWebW - st->jtWebR);
    out4[3] = (double)st->jtAsync;
}

/* telemetry probe: running max penetration beyond the static wrap and
   the last drive value (calibration/diagnosis only, no audio effect) */
void bow_poly_jt_probe(void *vst, double *pen, double *fprev)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    double mx = -1e30;
    for (int s = 0; s < st->njt; s++) {
        double d = jt_maxpen(st->jtM[s], st->jtJ,
                             st->jtPhiU + st->jtZOff[s],
                             st->jtB + (size_t)s * st->jtJ,
                             st->jtQ + st->jtMOff[s]);
        if (d > mx) mx = d;
    }
    if (st->jtPenMax > mx) mx = st->jtPenMax;
    *pen = mx;
    *fprev = st->jtFmax;
    /* stash the DC estimate where a debugger can see it */
    (void)st->jtFdc;
}

/* parity/test entry: run ONLY the jt block with a given drive sequence
   (no bow, no web) — the harness compares this against the python
   reference twin scripts/tanpura_modal.py on identical tables. */
void bow_poly_jt_test(void *vst, int n, const double *drive, double *out)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (st->njt <= 0) return;
    for (int t = 0; t < n; t++) {
        st->jtFacc += drive[t];
        if (++st->jtPhase >= st->jtDiv) {
            double Fd = st->jtFacc / st->jtDiv;
            st->jtFacc = 0.0; st->jtPhase = 0;
            st->jtHold = jt_tick(st, st->jtFprev * st->jtDrv);
            st->jtFprev = Fd;
        }
        out[t] = st->jtGain * st->jtHold;
    }
}

void bow_poly_process(void *vst, int n, int stride,
                      const double *f0, const double *vb, const double *fb,
                      const double *beta, const double *gate,
                      const double *xv, double *out)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    const int nv = st->nv;
    const int K = st->K;
    const int *L = st->L;
    const int *off = st->off;
    const double *cs = st->cs, *cp = st->cp, *w0 = st->w0, *w1 = st->w1;
    const double *w2 = st->w2, *w3 = st->w3, *w4 = st->w4, *g = st->g;
    const double *lpA = st->lpA, *wout = st->wout, *kap = st->kap;
    const double *alphaw = st->alphaw, *jw = st->jw, *jl = st->jl;
    const double *jn = st->jn, *zdrv = st->zdrv, *zi = st->zi;
    const double *twt = st->twt;
    const double *ba1 = st->ba1, *ba2 = st->ba2, *bn0 = st->bn0;
    const double *bA = st->bA, *bC = st->bC;
    const double yinf = st->yinf, c0 = st->c0, dcRho = st->dcRho;
    const double pgain = st->pgain, pA = st->pA, bowW = st->bowW;
    const double Z = st->Z, zload = st->zload;
    const double jq = st->jq, jq2 = st->jq2;
    const double tdirect = st->tdirect, tshape = st->tshape, tmix = st->tmix;
    const double tuw = st->tuw;
    double *fv = st->fv, *dwt = st->dwt, *dtg = st->dtg;
    const double aDuck = exp(-1.0 / (0.010 * st->sr));
    const double hpG = st->hpG, jy0 = st->jy0, jzsum = st->jzsum;
    const int psv = st->psv;
    const int bowOn = bowW > 1e-9;
    double *arena = st->arena;
    int *widx = st->widx;
    double *vx1 = st->vx1, *vx2 = st->vx2, *vlp = st->vlp;
    double *jdc = st->jdc, *jenv = st->jenv, *sv = st->sv;

    /* per-chunk processed-string set: bowed this chunk, or still ringing */
    int nProc = 0;
    for (int b = 0; b < st->nb; b++) {
        bow_pstring_t *S = &st->strs[b];
        const double *fbb = fb + (size_t)b * stride;
        const double *gab = gate + (size_t)b * stride;
        int driving = 0;
        for (int t = 0; t < n; t++) {
            if (fbb[t] * gab[t] > 1e-6) { driving = 1; break; }
        }
        if (driving || S->senv > 1e-10 || S->kGate > 1e-9) {
            S->active = 1;
            st->proc[nProc++] = b;
        } else {
            S->active = 0;
        }
    }
    /* delay-free string loading of the junction (passive topology): every
       processed string adds zload*bowW*Z — constant over the chunk, so the
       solve denominator is one precomputed scalar */
    double zsumB = 0.0;
    if (psv && bowOn && zload > 1e-9)
        zsumB = (double)nProc * (zload * bowW * Z);
    const double zsumT = jzsum + zsumB;
    const double jden = 1.0 + jy0 * zsumT;

    double pkArr[64], rdmpArr[64], gkArr[64];
    for (int i = 0; i < nProc; i++) pkArr[i] = 0.0;

    /* drive record for the deferred jt post-pass (one-way web).
       ASYNC live mode records straight into a dispatcher ring slot
       and never waits; sync mode rides the preallocated buffer (no
       audio-thread malloc) or mallocs for offline-sized calls. */
    double *jtFr = NULL;
    int jtAsyncBlk = 0;
    if (st->njt > 0 && st->jtGain != 0.0) {
        if (st->jtAsync && st->jtDLive && n <= JT_ABLK) {
            jtAsyncBlk = 1;
            int wj = st->jtDJobW;
            int rj = __atomic_load_n(&st->jtDJobR, __ATOMIC_ACQUIRE);
            if (wj - rj < JT_ARING)
                jtFr = st->jtDrvRing
                    + (size_t)(wj & (JT_ARING - 1)) * JT_ABLK;
            else
                st->jtDropBlocks++;   /* overload: skip this block's
                                         drive (web decays briefly) */
        } else {
            jtFr = (st->jtFrBuf && n <= st->jtFrCap)
                ? st->jtFrBuf
                : (double *)malloc(sizeof(double) * (size_t)n);
        }
    }

    for (int t = 0; t < n; t++) {
        double F = 0.0;
        double tdir = 0.0;
        double noiseDir = 0.0;
        /* driven-unison duck targets, block-rate (tuw = 1 -> inert):
           a voice ducks if ANY bowing slot sits at a coincidence */
        if (tuw < 0.999 && (t & 63) == 0) {
            static const double rat[11] = {0.25, 0.333333333, 0.5,
                                           0.666666667, 0.75, 1.0,
                                           1.333333333, 1.5, 2.0, 3.0, 4.0};
            for (int i = 0; i < nv; i++) {
                double best = 1e9;
                for (int si = 0; si < nProc; si++) {
                    int b = st->proc[si];
                    size_t o = (size_t)b * stride + t;
                    if (gate[o] <= 0.5) continue;
                    double fb0 = f0[o] > 40.0 ? f0[o] : 40.0;
                    double r = fb0 / fv[i];
                    for (int u = 0; u < 11; u++) {
                        double d = fabs(log(r / rat[u]));
                        if (d < best) best = d;
                    }
                }
                dtg[i] = (best < 0.0173) ? tuw : 1.0;
            }
        }
        for (int i = 0; i < nProc; i++) {
            int b = st->proc[i];
            bow_pstring_t *S = &st->strs[b];
            size_t o = (size_t)b * stride + t;
            F += poly_string_force(st, S, f0[o], vb[o], fb[o], beta[o],
                                   gate[o], &noiseDir,
                                   &rdmpArr[i], &gkArr[i]);
            if (fabs(S->brLp) > pkArr[i]) pkArr[i] = fabs(S->brLp);
            /* non-passive topology keeps the mono one-sample -Z*V load
               (V == 0 for the rigid-bridge generic string) */
            if (!psv && bowOn && zload > 1e-9)
                F -= zload * bowW * Z * st->Vprev;
        }
        /* ---- additive voice force (shared path, zeros live) ---- */
        st->pLp = (1.0 - pA) * xv[t] + pA * st->pLp;
        F += pgain * st->pLp;
        /* ---- taraf/played web combs ---- */
        if (!psv) {
            for (int i = 0; i < nv; i++) {
                double x = kap[i] * st->Vprev + alphaw[i] * xv[t];
                int len = L[i] + 8;
                double *b = arena + off[i];
                int wi = widx[i];
                double y1 = b[(wi + len - 1) % len];
                double y2 = b[(wi + len - 2) % len];
                double yL0 = b[(wi + len - L[i]) % len];
                double yL1 = b[(wi + len - L[i] - 1) % len];
                double yL2 = b[(wi + len - L[i] - 2) % len];
                double yL3 = b[(wi + len - L[i] - 3) % len];
                double yL4 = b[(wi + len - L[i] - 4) % len];
                double ySer = w0[i] * yL0 + w1[i] * yL1 + w2[i] * yL2
                    + w3[i] * yL3 + w4[i] * yL4;
                if (st->jawRoll > 1e-12 && st->rollD[i] > 1e-12)
                    ySer = roll_read(b, wi, len, L[i], w0[i], w1[i],
                                     w2[i], w3[i], w4[i], st->rollD[i]);
                double y = (1.0 - g[i]) * (x + cs[i] * vx1[i] + cp[i] * vx2[i])
                    - cs[i] * y1 - cp[i] * y2
                    + g[i] * ySer;
                double wv = y;
                if (st->jawRoll > 1e-12) {
                    /* v2 brief-contact law (mono port): engage only
                       near the positive displacement extreme */
                    st->rollE[i] = fmax(0.99999 * st->rollE[i], fabs(y));
                    double tgt = (jn[i] > 1e-9
                                  && y > st->jawRollAmp * st->rollE[i])
                        ? st->jawRoll * jn[i] : 0.0;
                    st->rollD[i] += st->rollAv[i] * (tgt - st->rollD[i]);
                    if (st->rollD[i] > 3.0) st->rollD[i] = 3.0;
                } else if (jn[i] > 1e-9 && y > 0.0) {
                    if (st->jawRho > 1e-12) {
                        /* v3 collision fold (mono port) */
                        double e2 = y - jq2;
                        if (e2 > 0.0)
                            wv = y - jn[i] * (1.0 + st->jawRho) * e2;
                    } else {
                        double s = y / (y + jq2 + 1e-30);
                        wv = y * (1.0 - jn[i] * s);
                    }
                }
                if (jl[i] > 1e-9) {
                    double e = 0.9995 * jenv[i] + 0.0005 * fabs(y);
                    jenv[i] = e;
                    double hot = e / (e + jq + 1e-30);
                    wv = wv * (1.0 - jl[i] * hot);
                }
                b[wi] = wv;
                widx[i] = (wi + 1) % len;
                vx2[i] = vx1[i];
                vx1[i] = x;
                double yo = y;
                if (jw[i] > 1e-9) {
                    double r = fabs(y);
                    jdc[i] = 0.99947 * jdc[i] + 0.00053 * r;
                    yo = y + jw[i] * (r - jdc[i]);
                }
                vlp[i] = (1.0 - lpA[i]) * yo + lpA[i] * vlp[i];
                F += wout[i] * vlp[i];
                dwt[i] += (1.0 - aDuck) * (dtg[i] - dwt[i]);
                tdir += dwt[i] * twt[i] * wout[i] * vlp[i];
            }
        } else {
            /* PASSIVE WAVE JUNCTION, PASS 1 (mono law + the poly strings'
               delay-free loading in zsumT/jden) */
            for (int i = 0; i < nv; i++) {
                int len = L[i] + 8;
                double *b = arena + off[i];
                int wi = widx[i];
                double y1 = b[(wi + len - 1) % len];
                double y2 = b[(wi + len - 2) % len];
                double yL0 = b[(wi + len - L[i]) % len];
                double yL1 = b[(wi + len - L[i] - 1) % len];
                double yL2 = b[(wi + len - L[i] - 2) % len];
                double yL3 = b[(wi + len - L[i] - 3) % len];
                double yL4 = b[(wi + len - L[i] - 4) % len];
                double ySer = w0[i] * yL0 + w1[i] * yL1 + w2[i] * yL2
                    + w3[i] * yL3 + w4[i] * yL4;
                if (st->jawRoll > 1e-12 && st->rollD[i] > 1e-12)
                    ySer = roll_read(b, wi, len, L[i], w0[i], w1[i],
                                     w2[i], w3[i], w4[i], st->rollD[i]);
                double S = (1.0 - g[i]) * (cs[i] * vx1[i] + cp[i] * vx2[i])
                    - cs[i] * y1 - cp[i] * y2
                    + g[i] * ySer;
                sv[i] = S;
                F += (1.0 - g[i]) * alphaw[i] * xv[t] + S;
            }
            double Vst = yinf * (dcRho * st->hpY - hpG * st->hpX1);
            for (int k = 0; k < K; k++)
                Vst += bA[k] * (ba1[k] * st->by1[k] + ba2[k] * st->by2[k]
                                - bn0[k] * st->bx2[k]);
            double Vs = (Vst + jy0 * F) / jden;
            F -= zsumT * Vs;
        }
        /* ---- body: admittance V + radiation ---- */
        st->hpY = hpG * (F - st->hpX1) + dcRho * st->hpY;
        st->hpX1 = F;
        double V = yinf * st->hpY;
        double rad = c0 * F;
        for (int k = 0; k < K; k++) {
            double y = bn0[k] * (F - st->bx2[k]) + ba1[k] * st->by1[k]
                + ba2[k] * st->by2[k];
            st->bx2[k] = st->bx1[k]; st->bx1[k] = F;
            st->by2[k] = st->by1[k]; st->by1[k] = y;
            V += bA[k] * y;
            rad += bC[k] * y;
        }
        if (psv) {
            /* PASSIVE JUNCTION, PASS 2 — verbatim mono */
            for (int i = 0; i < nv; i++) {
                double x = alphaw[i] * xv[t] - zdrv[i] * V;
                double y = (1.0 - g[i]) * x + sv[i];
                double wv = y;
                if (st->jawRoll > 1e-12) {
                    /* v2 brief-contact law (mono port): engage only
                       near the positive displacement extreme */
                    st->rollE[i] = fmax(0.99999 * st->rollE[i], fabs(y));
                    double tgt = (jn[i] > 1e-9
                                  && y > st->jawRollAmp * st->rollE[i])
                        ? st->jawRoll * jn[i] : 0.0;
                    st->rollD[i] += st->rollAv[i] * (tgt - st->rollD[i]);
                    if (st->rollD[i] > 3.0) st->rollD[i] = 3.0;
                } else if (jn[i] > 1e-9 && y > 0.0) {
                    if (st->jawRho > 1e-12) {
                        /* v3 collision fold (mono port) */
                        double e2 = y - jq2;
                        if (e2 > 0.0)
                            wv = y - jn[i] * (1.0 + st->jawRho) * e2;
                    } else {
                        double s = y / (y + jq2 + 1e-30);
                        wv = y * (1.0 - jn[i] * s);
                    }
                }
                if (jl[i] > 1e-9) {
                    double e = 0.9995 * jenv[i] + 0.0005 * fabs(y);
                    jenv[i] = e;
                    double hot = e / (e + jq + 1e-30);
                    wv = wv * (1.0 - jl[i] * hot);
                }
                int len = L[i] + 8;
                double *b = arena + off[i];
                int wi = widx[i];
                b[wi] = wv;
                widx[i] = (wi + 1) % len;
                vx2[i] = vx1[i];
                vx1[i] = x;
                double yo = y;
                if (jw[i] > 1e-9) {
                    double r = fabs(y);
                    jdc[i] = 0.99947 * jdc[i] + 0.00053 * r;
                    yo = y + jw[i] * (r - jdc[i]);
                }
                vlp[i] = (1.0 - lpA[i]) * yo + lpA[i] * vlp[i];
                dwt[i] += (1.0 - aDuck) * (dtg[i] - dwt[i]);
                tdir += dwt[i] * twt[i] * wout[i] * vlp[i];
            }
        }
        if (bowOn) {
            for (int i = 0; i < nProc; i++) {
                bow_pstring_t *S = &st->strs[st->proc[i]];
                poly_string_return(st, S, V, rdmpArr[i], gkArr[i]);
            }
        }
        st->venv = 0.9995 * st->venv + 0.0005 * fabs(V);
        st->disp = 0.99967 * st->disp + V;
        st->Vprev = V;
        double trad = tdir;
        if (tshape > 0.5) {
            trad = c0 * tdir;
            #pragma clang loop vectorize(disable)
            for (int k = 0; k < K; k++) {
                double y = bn0[k] * (tdir - st->tx2[k]) + ba1[k] * st->ty1[k]
                    + ba2[k] * st->ty2[k];
                st->tx2[k] = st->tx1[k]; st->tx1[k] = tdir;
                st->ty2[k] = st->ty1[k]; st->ty1[k] = y;
                trad += bC[k] * y;
            }
            trad = tmix * trad + (1.0 - tmix) * tdir;
        }
        out[t] = rad + tdirect * trad + noiseDir;
        /* ---- modal-jawari drive RECORD (mono lockstep): the jt web
           is ONE-WAY (drive = the shared junction force F, output
           adds only) — deferred to the post-pass below ---- */
        if (jtFr) jtFr[t] = F;
    }
    /* ring envelopes → next chunk's skip decision */
    for (int i = 0; i < nProc; i++) {
        bow_pstring_t *S = &st->strs[st->proc[i]];
        S->senv = pkArr[i];
        if (!(S->senv > 1e-10) && S->kGate <= 1e-9) S->active = 0;
    }
    /* ---- modal-jawari POST-PASS ----
       ASYNC live: publish the drive job (no wait) + mix the web
       FIFO's completed samples (flat-fill from the last value when
       the dispatcher is behind — a briefly flattened wash, never a
       glitch).  SYNC: the mono-lockstep serial replay (bit-exact) or
       the caller-blocking worker pool. */
    if (jtAsyncBlk) {
        if (jtFr) {
            int wj = st->jtDJobW;
            st->jtDJobN[wj & (JT_ARING - 1)] = n;
            __atomic_store_n(&st->jtDJobW, wj + 1, __ATOMIC_RELEASE);
            if (pthread_mutex_trylock(&st->jtMx) == 0) {
                pthread_cond_broadcast(&st->jtCvW);
                pthread_mutex_unlock(&st->jtMx);
            }
        }
        long long ww = __atomic_load_n(&st->jtWebW, __ATOMIC_ACQUIRE);
        long long rr = st->jtWebR;
        int avail = (int)(ww - rr);
        int take = avail < n ? avail : n;
        double g = st->jtMixG;
        for (int t = 0; t < take; t++) {
            double v = st->jtWebRing[(rr + t) & (JT_WEBN - 1)];
            if (g < 1.0) { g += 3.0e-5; if (g > 1.0) g = 1.0; }
            out[t] += g * v;
            st->jtOutHold = v;
        }
        for (int t = take; t < n; t++) {
            if (g < 1.0) { g += 3.0e-5; if (g > 1.0) g = 1.0; }
            out[t] += g * st->jtOutHold;
        }
        st->jtMixG = g;
        if (take < n)
            st->jtFlatSamples += (long long)(n - take);
        st->jtWebR = rr + take;
    } else if (jtFr) {
        if (st->jtPoolN < 2) {
            for (int t = 0; t < n; t++) {
                double F = jtFr[t];
                st->jtFdc += 2e-4 * (F - st->jtFdc);
                st->jtFacc += F - st->jtFdc;
                if (++st->jtPhase >= st->jtDiv) {
                    double Fd = st->jtFacc / st->jtDiv;
                    st->jtFacc = 0.0; st->jtPhase = 0;
                    st->jtHold = jt_tick(st, st->jtFprev * st->jtDrv);
                    st->jtFprev = Fd;
                }
                out[t] += st->jtGain * st->jtHold;
                if (F > st->jtFmax) st->jtFmax = F;
                if (-F > st->jtFmax) st->jtFmax = -F;
            }
        } else {
            const int nth = st->jtPoolN;
            double *fdv = st->jtFdv;
            int *tkv = st->jtTkv;
            double *hp = st->jtHp;
            for (int c0 = 0; c0 < n; c0 += JT_POOL_CH) {
                const int cn = n - c0 < JT_POOL_CH ? n - c0
                                                   : JT_POOL_CH;
                int nT = 0;
                for (int t = 0; t < cn; t++) {
                    double F = jtFr[c0 + t];
                    st->jtFdc += 2e-4 * (F - st->jtFdc);
                    st->jtFacc += F - st->jtFdc;
                    if (++st->jtPhase >= st->jtDiv) {
                        double Fd = st->jtFacc / st->jtDiv;
                        st->jtFacc = 0.0; st->jtPhase = 0;
                        fdv[nT] = st->jtFprev * st->jtDrv;
                        tkv[nT] = t;
                        nT++;
                        st->jtFprev = Fd;
                    }
                    if (F > st->jtFmax) st->jtFmax = F;
                    if (-F > st->jtFmax) st->jtFmax = -F;
                }
                if (nT == 0) {
                    for (int t = 0; t < cn; t++)
                        out[c0 + t] += st->jtGain * st->jtHold;
                    continue;
                }
                for (int th = 0; th < nth; th++) {
                    memset(hp + (size_t)th * JT_POOL_CH, 0,
                           sizeof(double) * (size_t)nT);
                    st->jtWPen[th] = st->jtPenMax;
                }
                pthread_mutex_lock(&st->jtMx);
                st->jtWnT = nT;
                st->jtWPer = (st->njt + nth - 1) / nth;
                st->jtDone = 0;
                st->jtGen++;
                pthread_cond_broadcast(&st->jtCvW);
                while (st->jtDone < st->jtPoolN)
                    pthread_cond_wait(&st->jtCvD, &st->jtMx);
                pthread_mutex_unlock(&st->jtMx);
                for (int th = 0; th < nth; th++)
                    if (st->jtWPen[th] > st->jtPenMax)
                        st->jtPenMax = st->jtWPen[th];
                double hold = st->jtHold;
                int ki = 0;
                for (int t = 0; t < cn; t++) {
                    if (ki < nT && t == tkv[ki]) {
                        double H = 0.0;
                        for (int th = 0; th < nth; th++)
                            H += hp[(size_t)th * JT_POOL_CH + ki];
                        hold = H;
                        ki++;
                    }
                    out[c0 + t] += st->jtGain * hold;
                }
                st->jtHold = hold;
            }
        }
        if (jtFr != st->jtFrBuf)
            free(jtFr);
    }
}

void bow_poly_reset_string(void *vst, int b)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (b < 0 || b >= st->nb) return;
    poly_mount_string(st, &st->strs[b]);
}

int bow_poly_active(const void *vst, int b)
{
    const bow_poly_state_t *st = (const bow_poly_state_t *)vst;
    if (b < 0 || b >= st->nb) return 0;
    return st->strs[b].active;
}

void bow_poly_free(void *vst)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    if (st->njt > 0) {
        bow_poly_jt_set_async(vst, 0);   /* dispatcher first: it may
                                            be waiting on the pool */
        jt_pool_stop(st);
        if (st->jtPoolInit) {
            pthread_mutex_destroy(&st->jtMx);
            pthread_cond_destroy(&st->jtCvW);
            pthread_cond_destroy(&st->jtCvD);
        }
        free(st->jtFrBuf); free(st->jtFdv); free(st->jtTkv);
        free(st->jtHp);
        free(st->jtDrvRing); free(st->jtWebRing);
        free(st->jtM); free(st->jtMOff); free(st->jtZOff);
        free(st->jtCa); free(st->jtCb); free(st->jtCa4); free(st->jtCb4);
        free(st->jtWd); free(st->jtWdI);
        free(st->jtPhiO); free(st->jtPhiD);
        free(st->jtPhiU); free(st->jtPhiF); free(st->jtB);
        free(st->jtG); free(st->jtG4); free(st->jtGd); free(st->jtGd4);
        free(st->jtQ); free(st->jtP);
    }
    free(st->L);
    free(st->cs); free(st->cp); free(st->w0); free(st->w1); free(st->w2);
    free(st->w3); free(st->w4); free(st->g); free(st->lpA); free(st->wout);
    free(st->kap); free(st->alphaw); free(st->jw); free(st->jl);
    free(st->jn); free(st->zdrv); free(st->zi); free(st->twt);
    free(st->ba1); free(st->ba2); free(st->bn0); free(st->bA); free(st->bC);
    free(st->fv); free(st->dwt); free(st->dtg);
    free(st->off); free(st->arena); free(st->widx); free(st->vx1);
    free(st->vx2); free(st->vlp); free(st->jdc); free(st->jenv);
    free(st->sv);
    free(st->rollD);
    free(st->rollE);
    free(st->rollAv);
    free(st->strs); free(st->proc);
    free(st);
}
