/* POLYPHONIC bow kernel: nb bowed gut strings on ONE bridge. Per sample
   every active string runs the bow-string section (friction contacts,
   thermal rosin, contact noise, terminations, gut loss/dispersion) on its
   OWN delay lines; the forces sum into the bridge force F, the modal body
   solves V, and every string takes the same bridge velocity back
   through its gated kret return.

   Each string's bridge loading enters as the ONE-SAMPLE term
   -zload*bowW*Z*Vprev (the previous sample's bridge velocity); the
   delay-free passive-junction solve it once shared the topology with went
   with the comb bank it existed for.
   Silent strings are skipped whole (exact: their state is zero). */

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif

#define MAXBOW 4096
/* async jt ring sizes (also the two-way-coupling FIFO's) */
#define JT_ABLK 4096
#define JT_ARING 8
#define JT_WEBN 32768

static double pfrac_read(const double *buf, int n, int w, double delay) {
    double rp = (double)w - delay;
    while (rp < 0) rp += n;
    int i0 = (int)rp;
    double fr = rp - i0;
    int i1 = (i0 + 1) % n;
    return buf[i0 % n] * (1.0 - fr) + buf[i1] * fr;
}

/* per-string cross-sample state */
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
    /* torsional wave loop */
    double bufT[MAXBOW];
    int wti;
    double hairLp, hairLp3[3];
    /* SLIDE TRACKER: slF = previous f0, slD/slEnv = signed slew smoother +
       0..1 dulling envelope, slA/slEnvA = signed accel smoother + 0..1 noise
       envelope, slLp = finger-noise one-pole, slRng = per-slot xorshift64.
       All rest at 0, branch-gated — bit-null while disarmed. */
    double slF, slD, slEnv, slA, slEnvA, slLp;
    unsigned long long slRng;
    int slFValid;
    int active;
} bow_pstring_t;

typedef struct {
    /* --- static config (deep copies; C owns the memory) --- */
    double sr;
    int nb;
    int K;
    double *ba1, *ba2, *bn0, *bA, *bC;
    double yinf, c0, dcRho;
    double pgain, pA, bowW, kret, retA, retMode, rb0, ra1, ra2;
    double kdisp, bowWidth, bowCont, Z, Zt;
    double mu_s, mu_d, v0f, nutA, brA;
    double thLeak, thA, thD, thFloor;
    double bowDisp, zload;
    double nA, nT, nPow, nzHi, nzLo, nDir, nzHiD;
    double gutG, dispN, nailK, f0Open, gutA2;
    double torsRatio, torsG, torsC;
    double v0Pow, v0Ref;
    double hairHz, hairRef;
    double lossReg;   /* register damping: loop-corner scaling below f0Open */
    double slideRate, slideDull;         /* slide dulling */
    double slideNoise, slideAcc;         /* accel-driven finger noise */
    /* --- derived constants --- */
    /* ---- MODAL-JAWARI sympathetic strings: per row a modal-exact stiff
       string (precomputed rotation tables ca/cb + wd, quarter-step ca4/cb4)
       over a grazing bone sampled at J zone points; implicit Hunt-Crossley
       contact with dt/4 substepping past jtDeep; driven ONE-WAY by the previous
       sample's junction force. Loaded by bow_poly_jt_load after
       bow_poly_init; njt == 0 or jtGain == 0 = byte-null by construction. */
    int njt, jtJ;
    int *jtM, *jtMOff, *jtZOff;
    double *jtCa, *jtCb, *jtCa4, *jtCb4, *jtWd, *jtWdI,
        *jtPhiD;            /* jtWdI = 1/wd (no division in the rotation) */
    /* TERMINATION DRIVE (bow_jt_drive_term): the second drive shape, the
       bridge force entering through the mode SLOPE at the pin (∝ (−1)^k·k,
       ENERGY-matched per row to the tap) — no |sin(kπ·0.9)| comb, and by
       reciprocity the same sign convention as the pin-force radiation term.
       jtDrvTerm is the 0…1 morph target; each row slews its own copy on the
       radiation's ~40 ms law so a swept knob never steps the drive.
       jtDrvTerm == 0 with a rested cur = the exact tap tick, byte-null. */
    double *jtPhiDT;
    double jtDrvTerm;
    double *jtDrvTermCur;
    /* zone tables in FLOAT32 (the matmuls + J-vector solve dominate; the modal
       recursion stays double). Loops written for clang auto-vectorization. */
    float *jtPhiU, *jtPhiF;       /* zone matrices, concat M*J */
    float *jtB;                   /* bone profile, concat J */
    float *jtG, *jtG4;            /* compliance, concat J*J */
    float *jtGd, *jtGd4;          /* compliance diag, concat J */
    double jtKc, jtAlpha, jtHcB, jtDeep, jtGain, jtDrv;
    /* SLEWED OUTPUT GAIN: jtGainCur glides toward jtGain per kernel sample
       (~40 ms) — the force radiation's low-frequency swing would splash a
       stepped gain. Constant gain: cur == target exactly, bit-identical. */
    double jtGainCur, jtGainA;
    /* RATE DIVIDER: the jt block ticks every jtDiv-th kernel sample on tables
       built at sr/jtDiv (ZOH imaging dies in the host's decimation). Drive =
       mean of the skipped samples. */
    int jtDiv, jtPhase;
    double jtHold, jtFacc;
    /* jt tone LP on the radiated sum (bow_poly_jt_set_lp); <= 0 = bypass,
       bit-exact */
    double jtLpA, jtLpY;
    /* jt tone HP after the LP — the jawari-formant voicing (quiet fundamental
       under the high cluster). Same contract: <= 0 = bypass, bit-exact. */
    double jtHpA, jtHpY;
    /* TILT axes (control-thread scalars): jtLift = bone drop (0 = bit-exact;
       jtLiftRef = load-time max penetration), jtDampMul = momentum
       multiplier. */
    double jtLift, jtLiftRef, jtDampMul;
    /* PER-STRING VOICE-RELATIVE CAP (bow_jt_cap): each row's RADIATED output is
       held at or below ratio × the voice bus's decaying peak (the runaway-bloom
       lever, per string so one anchor row never ducks its neighbours). The
       render loop records the voice peak envelope (~1.2 s-τ) beside the drive;
       the tick scheduler turns it into a per-tick ROW ceiling (× ratio ÷ the
       jt output gain); each row runs a 150 ms peak envelope + gain (3 ms
       attack / 120 ms recovery, reduction = hard × the dB overshoot) as a pure
       radiation gain after its physics. Per-row state is worker-owned: an arm
       edge bumps jtCapGen and each row resets itself on its next tick (never
       write the per-row arrays from the control thread). hard 0 = byte-null. */
    double jtCapHard, jtCapRatio;
    double jtCapVEnv, jtCapVRel;      /* voice peak env + per-sample release */
    double jtCapTRel, jtCapAtk, jtCapRel;   /* per-jt-tick clocks */
    double *jtCapEnv, *jtCapGain;     /* per-row (worker-owned) */
    int jtCapGen, *jtCapRowGen;       /* arm generation, per-row copy */
    double *jtCapV;                   /* per-tick ceiling scratch */
    double *jtCapBuf;                 /* sync voice-env record (with jtFrBuf) */
    double *jtCapRing;                /* async record ring (with jtDrvRing) */
    /* SCOPE TELEMETRY: display-only per-row radiated + per-mode |p_k| peak
       envelopes, NEVER read by the physics. Worker-owned, racy display reads;
       unarmed = the exact unmetered tick. */
    int scopeOn, scopeK;
    double scopeRel;                  /* per-tick level release */
    float scopeModeDk;                /* per-update mode-env decay */
    double *scopeEnv;                 /* per-row radiated peak env */
    float *scopeMode;                 /* per-row × scopeK |p_k| envs */
    unsigned *scopeCnt;               /* per-row tick counter */
    /* BRIDGE-FORCE RADIATION: each row radiates its CONTACT FORCE on the bone
       (plus its TERMINATION force, below); jtRadScale (builder:
       gout·π·wj/(mu·L·wd1)) makes every mode radiate FLAT in pickup units. A
       ~8 Hz DC blocker, primed to the first sample, takes only the static
       wrap preload. */
    double jtRadA;
    double *jtRadScale, *jtRadLp;
    unsigned char *jtRadPrime;
    /* per-row radiation scale slew: jtRadScaleCur glides ~40 ms per jt tick
       toward jtRadScale (a coefficient reload steps the target). Constant
       scale: cur == target exactly, bit-null. */
    double jtRadSlewA;
    double *jtRadScaleCur;
    /* TERMINATION (PIN) FORCE radiation: every row ALSO radiates the LINEAR
       bridge force at its pin, T·du/dx|L, which in the same radiated units
       collapses to jtRadPinScale[s] · sum_k (-1)^k·k·q_k (builder:
       gout·amp2·wd1). Summed with the contact force BEFORE the DC blocker —
       the static wrap gives the pin sum a DC offset the blocker takes.
       Permanent, no mix: a per-row LOAD-ABI scale beside radScale, and
       slewed on the same ~40 ms law (a coefficient reload steps the target —
       the chromatic rows' gout rides bow_jtc_gain/bow_jt_gain, so a stepped
       scale zippers, `ZipperTests`' fast flick). Constant scale: cur ==
       target exactly, bit-null. */
    double *jtRadPinScale, *jtRadPinScaleCur;
    /* TWO-WAY BRIDGE COUPLING (`bow_jt_couple`): the rows load the SAME
       bridge the played strings do, so their summed bridge force returns
       into F. jtCplScale[s] undoes the per-row force->radiated unit match
       (mu*L*wd1/(gout*pi) — the shared factor of BOTH radScale and pinScale),
       so the summed, un-DC-blocked radiated sum comes back in NEWTONS and a
       gain of 1 is the physical load. The web is a DEFERRED post-pass, so
       the return rides a FIFO: the post-pass holds the force per jt tick and
       emits it per output sample; the NEXT block's render loop adds
       jtCplCur * it to F, ahead of the body solve and of the drive record —
       so the rows also feel each other through the bridge on the next tick,
       exactly the lag law the drive's jtFprev uses, one post-pass block out.
       jtCplG 0 with a rested cur = the exact uncoupled render, byte-null. */
    double *jtCplScale;               /* per-row radiated-sum -> newtons */
    double jtCplG, jtCplCur, jtCplA;  /* target / slewed (~40 ms) / coef */
    int jtCplOn;                      /* target or cur non-zero */
    double jtCplHold;                 /* post-pass: force held per jt tick */
    double *jtCplRing;                /* FIFO, post-pass -> render thread */
    long long jtCplW, jtCplR;
    double jtCplOut;                  /* render-side last value (dry fade) */
    double *jtHpC;                    /* pool partial sums, coupling */
    /* QUIESCENCE GATE (bow_jt_gate): the idle-CPU gate. Armed (jtGateRef > 0 =
       floor DISPLACEMENT in meters): a row whose peak LOW-MODE momentum stays
       below jtGateRef·wd1 for jtGateHold ticks with no bridge or drone drive
       sleeps IN PLACE — FROZEN, never zeroed (zeroing jtQ would strum the
       re-settle) — and skips the tick, radiating exact 0. Low modes are the
       meter: the wrap keeps the HIGH modes in a limit-cycle that never rests.
       Worker-owned per-row state, control-thread scalars. 0 = byte-null. */
    double jtGateRef;         /* floor displacement (m); 0 = off */
    int jtGateHold;           /* consecutive quiet jt ticks to sleep */
    double *jtGateFdEps;      /* per-row bridge-drive wake bound */
    int *jtGateCnt;           /* per-row quiet-run countdown */
    unsigned char *jtGateSlp; /* per-row asleep flag */
    /* gate PROBE telemetry (racy, read+reset by bow_poly_jt_gate_probe): max
       ring/floor and drive/eps ratios on AWAKE rows, plus a drone-active
       flag */
    double jtGateAmR, jtGateFdR;
    int jtGateDnHot;
    double jtGateEvWake;      /* set_evolve wake reference: change-gated
                                 (dead-band 2% of jtDeep) so a
                                 re-pushed constant never holds the web awake */
    /* HARMONIC-EVOLUTION lift (bow_jt_evolve): SIGNED bone offset in meters
       (+ = dropped, cascade opens; − = raised), slewed per jt sample (jtEvA,
       ~40 ms); the deep-substep threshold follows (jtDeep − 2.5·ev). jtEvV
       carries the slewed values into the pool (bit-exact replay). 0 =
       byte-null. */
    double jtEvTgt, jtEvCur, jtEvA;
    double *jtEvV;
    /* ---- EVOLUTION REGISTER TILT (bow_jt_ev_reg): per-row SIGNED bone offsets
       added to the global lift, slewed per row per jt tick (row-owned state).
       jtEvOfsOn stays 0 until the setter runs — byte-null. */
    int jtEvOfsOn;
    double jtEvOfsA;                  /* slew coeff (jt tick rate) */
    double *jtEvOfsTgt, *jtEvOfsCur;  /* per-row offset target / current */
    /* ---- TWO BRIDGES: per-row contact law (the chromatic set's own jawari);
       jtRowContactOn 0 until set = byte-null (the tick reads the globals). */
    int jtRowContactOn;
    double *jtRowAlpha, *jtRowHcB, *jtRowDeep;
    /* ---- RECRUITMENT weights: per-row scale on the incoming bridge drive (the
       taraf-selectivity axis). Control-thread targets; the jt tick slews
       jtDwCur (~30 ms). jtDwOn stays 0 until the setter runs — byte-null. */
    int jtDwOn;
    double jtDwA;                 /* slew coeff (jt tick rate) */
    double *jtDwTgt, *jtDwCur;    /* per-row weight target / current */
    /* RECRUITMENT lush half: radiated-gain multiplier on the web's output
       (slewed in jt_lp_step). Drive above 1 saturates against the contact, so
       loudness is an output lever, which nothing drains. */
    int jtGMulOn;
    double jtGMulA, jtGMulTgt, jtGMulCur;
    /* ---- jt BODY radiation: blend the jt sum through the body bank (shared
       coefficients, OWN state), slewed ~30 ms; jtBodyOn 0 until set =
       byte-null. */
    int jtBodyOn;
    double jtBodyA, jtBodyTgt, jtBodyCur;
    double jbx1[96], jbx2[96], jby1[96], jby2[96];      /* mid twin */
    double jbsx1[96], jbsx2[96], jbsy1[96], jbsy2[96];  /* side twin */
    double *jtQ, *jtP;            /* modal state, concat modes */
    double jtFprev, jtFmax, jtPenMax;   /* + telemetry */
    double jtFdc;                 /* drive DC tracker (~50 ms) */
    /* ---- jt DRONE rows: per-row control-thread scalars (onset boost +
       noise drive target, slewed so press/release never click). All-zero =
       byte-null. */
    double *jtDnTgt, *jtDnEnv, *jtDnBoost, *jtDnLp, *jtDnLp2;
    unsigned long long *jtDnRng;
    /* pitched drone drive: sine at the row's mode-1 mixed jtDnMix : (1-mix)
       noise — noise alone rings the high modes far above their played
       balance */
    double *jtDnPh;
    double jtDnMix;
    /* ---- MELODY-FOLLOWER row: one jt row live-retunes to the played pitch.
       The host writes jtTrkTarget (Hz); the row's own tick slews jtTrkF0 and
       recomputes ONLY the f0-dependent mode tables (retune-by-tension). The
       active mode count jtTrkMUse = fx/f0 is trimmed live (modes above the fx
       corner limit-cycle against the bone). jtTrkRow -1 = byte-null. */
    int jtTrkRow;                 /* -1 = none */
    double jtTrkTarget;           /* target f0 Hz (any thread writes) */
    double jtTrkF0;               /* slewed current f0 (jt-thread owned) */
    double jtTrkApplied;          /* f0 the coefficients were built for */
    double jtTrkT60, jtTrkFhf, jtTrkBst, jtTrkFx;
    double jtTrkSlew;             /* per-retune one-pole coefficient */
    int jtTrkTick, jtTrkIval;
    int jtTrkMUse;                /* active modes (<= jtM[row]) */
    int jtTrkDirty;               /* force recompute (set_coeffs ran) */
    double jtDnA;                 /* release slew coeff (jt tick rate) */
    double jtDnAAtk;              /* attack slew coeff (jt tick rate) */
    double jtDnBDec;              /* onset-boost decay per jt tick */
    double jtDnALp, jtDnALp2;     /* noise band-pass coeffs (sub-audio drive
                                     would pump the buzz) */
    /* jt worker POOL: persistent high-QoS workers for the block-parallel
       post-pass, spawned off the audio thread (bow_poly_jt_set_threads).
       jtPoolN < 2 = serial replay, bit-exact vs the pool. */
    int jtNth, jtPoolN, jtPoolInit, jtGen, jtDone, jtQuit;
    pthread_t jtTid[16];
    pthread_mutex_t jtMx;
    /* DISPATCH-OWNER lock: one jt-web computer at a time (dispatcher vs the
       offline-pull fallback share row state, scratch and the pool
       rendezvous; concurrent dispatch wedges a waiter on jtCvD). Taken only
       if jtPoolInit. */
    pthread_mutex_t jtDispMx;
    pthread_cond_t jtCvW, jtCvD;
    int jtWnT, jtWPer;
    double jtWPen[16];
    double *jtFrBuf; int jtFrCap;
    double *jtFdv; int *jtTkv; double *jtHp;
    struct { void *st; int idx; } jtParg[16];
    /* ---- ASYNC one-block-late jt (LIVE): the callback records the block's
       drive into a ring slot and pops the web from a completed-samples FIFO
       (flat-fill under overload); a DISPATCHER thread runs the schedule +
       pool on ITS thread. All jt drive/hold state is dispatcher-owned. */
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
    double jtMixG;                    /* live web fade-in (~0.7 s, async only)
                                         over the fresh engine's chime */
    /* ---- STEREO SIDE OUTPUT: a SIDE stream of the DIRECT radiation only
       (the jawari rows' own radiation, bow noise at the played string);
       everything reaching the listener VIA THE BRIDGE stays
       mid-only. Host: L = mid + side, R = mid - side, fold-down bit-identical
       to mono. Armed by bow_poly_set_stereo; outS = NULL = mono path. */
    int stOn;
    double *stSlotPan;                /* nb: played-string (noise) pans */
    double *stJtPan;                  /* njt: modal-jawari row pans */
    double jtLpYS;                    /* side twin of the jt tone LP */
    double jtHpYS;                    /* side twin of the jt tone HP */
    double jtHoldS, jtOutHoldS;       /* side jt hold walk / async hold */
    double *jtHpS;                    /* pool partial sums, side */
    double *jtWebScr, *jtWebScrS;     /* offline-pull web scratch (mono/side) */
    double *jtWebRingS;               /* async web FIFO, side */
    /* ---- INSTRUMENT WIDTH: one instrument, two observation points — a dense
       random-sign side-only modal bank (identical at low frequency, diffusely
       decorrelated above the Schroeder crossover); static, passive, linear, so
       the L+R fold-down cancels it exactly. One instance per BUS ([0] voice,
       [1] jt wash), shared coefficients. Never armed = byte-null. */
    int stWidthOn;
    double stWidthTgt, stWidthCur;    /* slewed width scalar */
    double stWidthSl;                 /* ~30 ms one-pole slew coeff */
    int sdN;
    double sdA1[16], sdA2[16], sdN0[16], sdG[16];
    double sdX1[2][16], sdX2[2][16], sdY1[2][16], sdY2[2][16];
    double hpG;
    /* --- shared cross-sample state --- */
    double bx1[96], bx2[96], by1[96], by2[96];
    double hpY, hpX1;
    double pLp;
    double disp;           /* leaky bridge displacement (integral of V) */
    unsigned long long lcg;
    double Vprev;
    /* --- per-string state --- */
    bow_pstring_t *strs;
    int *proc;             /* per-chunk processed-string index scratch */
    /* FX hook on the recorded jt drive (the voice→taraf insert), called on the
       render thread before the post-pass consumes it. NULL = byte-null. */
    void (*fxDriveFn)(void *ctx, double *buf, int n);
    void *fxDriveCtx;
    /* SITAR->TARAF INJECT: another voice's output drives the web via an SPSC
       ring (producer's render callback writes; this render mixes what is
       available into the recorded drive before the drive-FX hook). Ring alloc
       in the gain setter; NULL ring / zero gain / empty ring = byte-null. */
    double *sjRing;                   /* 32768 doubles, lazy alloc */
    long long sjW, sjR;               /* ring cursors (mono counts) */
    double sjGain;                    /* plain scalar store */
} bow_poly_state_t;

/* Mount a fresh string. */
static void poly_mount_string(bow_poly_state_t *st, bow_pstring_t *S)
{
    memset(S, 0, sizeof(*S));
    /* finger-noise RNG: deterministic per slot (renders reproduce) */
    S->slRng = 0x9E3779B97F4A7C15ULL
        ^ ((unsigned long long)(S - st->strs) + 1ULL) * 0xBF58476D1CE4E5B9ULL;
}

static double *pdup_d(const double *a, int n) {
    double *b = (double *)malloc(sizeof(double) * (n > 0 ? n : 1));
    memcpy(b, a, sizeof(double) * (size_t)n);
    return b;
}

void *bow_poly_init(int nb, double sr,
                    int K, const double *ba1, const double *ba2,
                    const double *bn0, const double *bA, const double *bC,
                    double yinf, double c0, double dcRho,
                    double pgain, double pA, double bowW, double kret,
                    double retA, double retMode, double rb0, double ra1,
                    double ra2, double kdisp, double bowWidth, double bowCont,
                    double Z, double Zt,
                    double mu_s, double mu_d, double v0f, double nutA,
                    double brA, double thLeak, double thA, double thD,
                    double thFloor, double bowDisp,
                    double zload,
                    double nA, double nT, double nPow, double nzHi,
                    double nzLo, double nDir, double nzHiD,
                    double gutG, double dispN, double nailK, double f0Open,
                    double gutA2,
                    double torsRatio, double torsG, double torsC,
                    double v0Powp, double v0Refp,
                    double hairHzp, double hairRefp,
                    double lossRegp, double slideRatep, double slideDullp,
                    double slideNoisep, double slideAccp)
{
    bow_poly_state_t *st = (bow_poly_state_t *)calloc(1, sizeof(bow_poly_state_t));
    st->sr = sr;
    st->nb = nb < 1 ? 1 : (nb > 64 ? 64 : nb);   /* chunk scratch is [64] */
    st->K = K > 96 ? 96 : K;
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
    st->bowDisp = bowDisp; st->zload = zload;
    st->nA = nA; st->nT = nT; st->nPow = nPow;
    st->nzHi = nzHi; st->nzLo = nzLo; st->nDir = nDir; st->nzHiD = nzHiD;
    st->gutG = gutG; st->dispN = dispN; st->nailK = nailK;
    st->f0Open = f0Open; st->gutA2 = gutA2;
    st->torsRatio = torsRatio; st->torsG = torsG; st->torsC = torsC;
    st->v0Pow = v0Powp; st->v0Ref = v0Refp;
    st->hairHz = hairHzp;
    st->hairRef = (hairRefp > 1e-6 ? hairRefp : 1.0);
    st->lossReg = lossRegp;
    st->slideRate = (slideRatep > 1.0 ? slideRatep : 900.0);
    st->slideDull = slideDullp;
    st->slideNoise = slideNoisep;
    st->slideAcc = (slideAccp > 1.0 ? slideAccp : 25000.0);
    st->hpG = 0.5 * (1.0 + dcRho);
    st->lcg = 0x9E3779B97F4A7C15ULL;
    st->strs = (bow_pstring_t *)calloc(st->nb, sizeof(bow_pstring_t));
    for (int b = 0; b < st->nb; b++) poly_mount_string(st, &st->strs[b]);
    st->proc = (int *)malloc(sizeof(int) * st->nb);
    return (void *)st;
}

/* One string, one sample: friction contacts + terminations + contact noise
   against this string's state. Returns its transmitted bridge force,
   accumulates its direct-radiated noise, outputs rdmp/gk for the return. */
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
    const double v0Pow = st->v0Pow, v0Ref = st->v0Ref;
    const double hairHz = st->hairHz, hairRef = st->hairRef;
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
    double brAe = brA;
    const double gutGe = gutG;
    double gutA2e = gutA2;
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
        /* REGISTER DAMPING (bow_loss_reg): the fitted corners are absolute
           frequencies, so below the tonic they would stay as sharp per second
           as
           the fitted register's (brassy low register). Scale all three by
           (f0/f0Open)^lossReg below the tonic (fc·s == a^s). Composes after the
           nail law; continuous at f0Open; 0 = bit-exact. */
        /* SLIDE TRACKER (bow_slide_*): a moving finger absorbs more HF
           (DULLING,
           driven by the slew) and scrapes where it starts, stops or turns
           (NOISE,
           driven by the slew's derivative). Both trackers are SIGNED 10 ms
           smoothers before rectifying, so the OU drift stays under the 80 c/s
           and
           6000 c/s² floors and steady notes are bit-exact. A per-sample jump >
           ~2 cents is a mount/snap, not a slide. */
        double slN = 0.0;
        if (st->slideDull > 1e-9 || st->slideNoise > 1e-12) {
            if (S->slFValid) {
                double d = (f0t - S->slF) / fmax(f0t, 40.0);
                if (fabs(d) < 0.0012) {
                    double cD = 1.0 - exp(-1.0 / (0.010 * sr));
                    double slDp = S->slD;
                    S->slD += cD * (d - S->slD);
                    double r = 1731.234 * sr * fabs(S->slD);
                    double tgt = r < 80.0
                        ? 0.0 : r / (r + st->slideRate);
                    double a = tgt > S->slEnv
                        ? exp(-1.0 / (0.015 * sr))
                        : exp(-1.0 / (0.120 * sr));
                    S->slEnv = (1.0 - a) * tgt + a * S->slEnv;
                    if (st->slideNoise > 1e-12) {
                        S->slA += cD * ((S->slD - slDp) - S->slA);
                        double acc = 1731.234 * sr * sr * fabs(S->slA);
                        double tgtA = acc < 6000.0
                            ? 0.0 : acc / (acc + st->slideAcc);
                        double aA = tgtA > S->slEnvA
                            ? exp(-1.0 / (0.010 * sr))
                            : exp(-1.0 / (0.100 * sr));
                        S->slEnvA = (1.0 - aA) * tgtA + aA * S->slEnvA;
                    }
                }
            }
            S->slF = f0t; S->slFValid = 1;
            if (st->slideNoise > 1e-12 && S->slEnvA > 1e-6) {
                S->slRng ^= S->slRng << 13;
                S->slRng ^= S->slRng >> 7;
                S->slRng ^= S->slRng << 17;
                double w = (double)(long long)S->slRng
                    * 1.0842021724855044e-19;
                S->slLp += 0.25 * (w - S->slLp);
                /* x40 makeup: ~26 dB path loss to the radiated band, and the
                   drive fires in brief bursts */
                slN = st->slideNoise * 40.0 * S->slEnvA * gk * S->slLp;
            }
        }
        /* one composed corner scale; sReg is exactly 1 (block skipped) when
           nothing is armed */
        {
            double sReg = 1.0;
            if (st->lossReg > 1e-9 && f0Open > 1.0 && f0t < f0Open)
                sReg = pow(f0t / f0Open, st->lossReg);
            if (st->slideDull > 1e-9 && S->slEnv > 1e-6)
                sReg *= 1.0 - st->slideDull * S->slEnv;
            if (sReg < 1.0) {
                nutAf = pow(nutAf, sReg);
                brAe = pow(brAe, sReg);
                if (gutA2e > 0.0) gutA2e = pow(gutA2e, sReg);
            }
        }
        double h1 = pfrac_read(S->buf1, MAXBOW, S->w1i,
                               fmax(2.0, L1 * 2.0 - bowWidth));
        double dl = kdisp * st->disp;
        if (dl > 0.02) dl = 0.02; else if (dl < -0.02) dl = -0.02;
        double h2 = pfrac_read(S->buf2, MAXBOW, S->w2i,
                               fmax(2.0, (L2 * 2.0 - bowWidth) * (1.0 + dl)));
        double hBA = 0, hAB = 0;
        if (bowCont >= 2.5 && bowWidth >= 2.0) {
            /* three hair-group contacts, own friction solve per group */
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
                double v0g = v0f * (0.85 + 0.15 * g);
                if (v0Pow > 1e-12)
                    v0g *= pow(v0Ref / fmax(FbT * 3.0, 0.05), v0Pow);
                double Ffg = 0.0;
                if (FbT > 1e-6) {
                    double dv0 = vhg - vbt;
                    double stickF = -2.0 * Zeff * dv0;
                    if (fabs(stickF) <= mSg * FbT) {
                        Ffg = stickF;
                    } else {
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
                    double dvh = (vhg - vbt) + Ffg / (2.0 * Zeff);
                    double lk = pow(thLeak, hl2[g]);
                    S->Tr3[g] = lk * S->Tr3[g]
                        + (1.0 - lk) * fabs(Ffg * dvh);
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
            S->buf1[S->w1i] = -S->nutLp * rdmp * gutGe + slN;
            S->w1i = (S->w1i + 1) % MAXBOW;
            S->brLp = (1.0 - brAe) * o2 + brAe * S->brLp;
            if (gutA2e > 0.0) {
                S->brLp2 = (1.0 - gutA2e) * S->brLp + gutA2e * S->brLp2;
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
            double v0e = v0f;
            if (v0Pow > 1e-12 && Fb > 1e-6)
                v0e = v0f * pow(v0Ref / fmax(Fb * 2.0, 0.05), v0Pow);
            if (Fb > 1e-6) {
                double Zeff = Z / (1.0 + Z / Zt);
                double dv0 = vh - vbt;
                double stickF = -2.0 * Zeff * dv0;
                if (fabs(stickF) <= muS * Fb) {
                    Ff = stickF;
                } else {
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
                    double dvhB = (vhB - vbt) + FfB / (2.0 * (Z / (1.0 + Z / Zt)));
                    S->Tr3[1] = thLeak * S->Tr3[1]
                        + (1.0 - thLeak) * fabs(FfB * dvhB);
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
            S->buf1[S->w1i] = -S->nutLp * rdmp * gutGe + slN;
            S->w1i = (S->w1i + 1) % MAXBOW;
            S->brLp = (1.0 - brAe) * o2 + brAe * S->brLp;
            if (gutA2e > 0.0) {
                S->brLp2 = (1.0 - gutA2e) * S->brLp + gutA2e * S->brLp2;
                F += bowW * 2.0 * Z * S->brLp2;
            } else {
                F += bowW * 2.0 * Z * S->brLp;
            }
        }
    }
    return F;
}

/* One string, one sample: post-body bridge-motion return + stiffness
   dispersion + reflection write. */
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

static double jt_maxpen(int M, int J, const float *phiU,
                        const float *b_, const double *q);

void bow_poly_jt_load(void *vst, int njt, int J, const int *M,
                 const double *ca, const double *cb,
                 const double *ca4, const double *cb4,
                 const double *wd, const double *radScale,
                 const double *pinScale, const double *cplScale,
                 const double *phiD,
                 const double *phiDT,
                 const double *phiU, const double *phiF,
                 const double *b, const double *G, const double *G4,
                 const double *gd, const double *gd4, const double *phys,
                 const double *q0)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->njt = njt; st->jtJ = J;
    st->jtTrkRow = -1;            /* follower unarmed (byte-null) */
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
    st->jtPhiD = pdup_d(phiD, mtot);
    st->jtPhiDT = pdup_d(phiDT, mtot);
    st->jtDrvTerm = 0.0;                 /* tap shape until set_drive_term */
    st->jtDrvTermCur = (double *)calloc(njt, sizeof(double));
    st->jtPhiU = dup_f(phiU, ztot); st->jtPhiF = dup_f(phiF, ztot);
    st->jtB = dup_f(b, njt * J);
    st->jtG = dup_f(G, njt * J * J); st->jtG4 = dup_f(G4, njt * J * J);
    st->jtGd = dup_f(gd, njt * J);   st->jtGd4 = dup_f(gd4, njt * J);
    st->jtKc = phys[0]; st->jtAlpha = phys[1]; st->jtHcB = phys[2];
    st->jtDeep = phys[3]; st->jtGain = phys[4]; st->jtDrv = phys[5];
    st->jtGainCur = st->jtGain;
    st->jtGainA = 1.0 - exp(-1.0 / (0.040 * st->sr));
    st->jtDiv = (int)(phys[6] + 0.5);
    if (st->jtDiv < 1) st->jtDiv = 1;
    st->jtPhase = 0; st->jtHold = 0.0; st->jtFacc = 0.0;
    st->jtLpY = 0.0;
    st->jtHpA = 0.0; st->jtHpY = 0.0;
    st->jtQ = pdup_d(q0, mtot);    /* settled static wrap (builder) */
    st->jtP = (double *)calloc(mtot, sizeof(double));
    st->jtFprev = 0.0;
    /* drone rows: all-off (byte-null) until bow_poly_jt_drone/pluck */
    st->jtDnTgt = (double *)calloc(njt, sizeof(double));
    st->jtDnEnv = (double *)calloc(njt, sizeof(double));
    st->jtDnBoost = (double *)calloc(njt, sizeof(double));
    st->jtDnLp = (double *)calloc(njt, sizeof(double));
    st->jtDnLp2 = (double *)calloc(njt, sizeof(double));
    st->jtDnPh = (double *)calloc(njt, sizeof(double));
    /* charge governor: off (byte-null until bow_poly_jt_set_gov) */
    /* per-string cap: off (byte-null until bow_poly_jt_set_cap) */
    st->jtCapEnv = (double *)calloc(njt, sizeof(double));
    st->jtCapGain = (double *)malloc(sizeof(double) * (size_t)njt);
    st->jtCapRowGen = (int *)calloc(njt, sizeof(int));
    for (int s = 0; s < njt; s++) st->jtCapGain[s] = 1.0;
    st->jtCapHard = 0.0;
    st->jtCapRatio = 1.0;
    st->jtCapVEnv = 0.0;
    st->jtCapGen = 0;
    /* scope telemetry: off */
    st->scopeOn = 0;
    st->scopeK = 16;
    {
        const double dtj = (double)st->jtDiv / st->sr;
        st->scopeRel = 1.0 - exp(-dtj / 0.120);
        st->scopeModeDk = (float)exp(-4.0 * dtj / 0.150);
    }
    st->scopeEnv = (double *)calloc(njt, sizeof(double));
    st->scopeMode = (float *)calloc((size_t)njt * (size_t)st->scopeK,
                                    sizeof(float));
    st->scopeCnt = (unsigned *)calloc(njt, sizeof(unsigned));
    /* bridge-force radiation: the per-row unit match from the builder;
       DC blockers primed to their first sample */
    st->jtRadA = 1.0 - exp(-2.0 * M_PI * 8.0 * (double)st->jtDiv / st->sr);
    st->jtRadScale = pdup_d(radScale, njt);
    st->jtRadScaleCur = pdup_d(radScale, njt);
    st->jtRadSlewA = 1.0 - exp(-((double)st->jtDiv / st->sr) / 0.040);
    st->jtRadLp = (double *)calloc(njt, sizeof(double));
    st->jtRadPrime = (unsigned char *)malloc((size_t)njt);
    memset(st->jtRadPrime, 1, (size_t)njt);
    /* termination (pin) force: the builder's per-row unit match, permanent */
    st->jtRadPinScale = pdup_d(pinScale, njt);
    st->jtRadPinScaleCur = pdup_d(pinScale, njt);
    /* two-way bridge coupling: the per-row reciprocal of the SHARED
       force->radiated factor of radScale/pinScale, so the tick's un-blocked
       sum reads in newtons. Off (byte-null) until bow_poly_jt_set_couple. */
    st->jtCplScale = pdup_d(cplScale, njt);
    st->jtCplG = 0.0; st->jtCplCur = 0.0; st->jtCplOn = 0;
    st->jtCplHold = 0.0; st->jtCplOut = 0.0;
    st->jtCplW = 0; st->jtCplR = 0;
    st->jtCplA = 1.0 - exp(-1.0 / (0.040 * st->sr));
    if (!st->jtCplRing)
        st->jtCplRing = (double *)calloc(JT_WEBN, sizeof(double));
    /* quiescence gate: off (byte-null until bow_poly_jt_set_gate) */
    st->jtGateFdEps = (double *)calloc(njt, sizeof(double));
    st->jtGateCnt = (int *)calloc(njt, sizeof(int));
    st->jtGateSlp = (unsigned char *)calloc(njt, sizeof(unsigned char));
    st->jtGateRef = 0.0;
    st->jtGateHold = 1;
    st->jtDnMix = 0.5;
    st->jtDnRng = (unsigned long long *)malloc(sizeof(unsigned long long)
                                               * (size_t)njt);
    for (int s = 0; s < njt; s++)
        st->jtDnRng[s] = 0x9E3779B97F4A7C15ULL * (unsigned long long)(s + 1);
    {
        double dtj = (double)st->jtDiv / st->sr;
        /* envelope/tone defaults — BowEngine's bow_drone_* values overwrite
           these at build */
        st->jtCapTRel = 1.0 - exp(-dtj / 0.150);
        st->jtCapAtk = 1.0 - exp(-dtj / 0.003);
        st->jtCapRel = 1.0 - exp(-dtj / 0.120);
        st->jtCapVRel = 1.0 - exp(-1.0 / (st->sr * 1.2));
        st->jtDnA = 1.0 - exp(-dtj / 0.350);
        st->jtDnAAtk = 1.0 - exp(-dtj / 0.150);
        st->jtDnBDec = exp(-dtj / 0.500);
        st->jtDnALp = 1.0 - exp(-2.0 * 3.14159265358979 * 1600.0 * dtj);
        st->jtDnALp2 = 1.0 - exp(-2.0 * 3.14159265358979 * 25.0 * dtj);
        /* recruitment weights: all-ones (byte-null until the setter
           first arms jtDwOn) */
        st->jtDwOn = 0;
        st->jtDwA = 1.0 - exp(-dtj / 0.030);
        st->jtDwTgt = (double *)malloc(sizeof(double) * (size_t)njt);
        st->jtDwCur = (double *)malloc(sizeof(double) * (size_t)njt);
        /* evolution register offsets: zeros (byte-null until the
           setter first arms jtEvOfsOn) */
        st->jtEvOfsOn = 0;
        st->jtEvOfsA = 1.0 - exp(-dtj / 0.040);
        st->jtEvOfsTgt = (double *)calloc((size_t)njt, sizeof(double));
        st->jtEvOfsCur = (double *)calloc((size_t)njt, sizeof(double));
        /* per-row contact law: allocated with the global values, inert
           until bow_poly_jt_set_row_contact arms it */
        st->jtRowContactOn = 0;
        st->jtRowAlpha = (double *)malloc(sizeof(double) * (size_t)njt);
        st->jtRowHcB = (double *)malloc(sizeof(double) * (size_t)njt);
        st->jtRowDeep = (double *)malloc(sizeof(double) * (size_t)njt);
        for (int s = 0; s < njt; s++) {
            st->jtRowAlpha[s] = st->jtAlpha;
            st->jtRowHcB[s] = st->jtHcB;
            st->jtRowDeep[s] = st->jtDeep;
        }
        st->jtGMulOn = 0;
        st->jtGMulA = 1.0 - exp(-1.0 / (0.030 * st->sr));
        st->jtGMulTgt = 1.0;
        st->jtGMulCur = 1.0;
        /* jt body radiation: off (byte-null until the setter arms) */
        st->jtBodyOn = 0;
        st->jtBodyA = 1.0 - exp(-1.0 / (0.030 * st->sr));
        st->jtBodyTgt = 0.0;
        st->jtBodyCur = 0.0;
        memset(st->jbx1, 0, sizeof(st->jbx1));
        memset(st->jbx2, 0, sizeof(st->jbx2));
        memset(st->jby1, 0, sizeof(st->jby1));
        memset(st->jby2, 0, sizeof(st->jby2));
        memset(st->jbsx1, 0, sizeof(st->jbsx1));
        memset(st->jbsx2, 0, sizeof(st->jbsx2));
        memset(st->jbsy1, 0, sizeof(st->jbsy1));
        memset(st->jbsy2, 0, sizeof(st->jbsy2));
        for (int s = 0; s < njt; s++) {
            st->jtDwTgt[s] = 1.0;
            st->jtDwCur[s] = 1.0;
        }
    }
    /* tilt-axis reference: the deepest static wrap across rows (floor jtDeep)
       — the unit bow_poly_jt_set_lift scales to. Axes start off (byte-null). */
    st->jtLift = 0.0; st->jtDampMul = 0.0;
    /* harmonic-evolution lift: slewed ~40 ms per jt sample so the bone glides;
       0 = byte-null */
    st->jtEvTgt = 0.0; st->jtEvCur = 0.0;
    st->jtEvA = 1.0 - exp(-((double)st->jtDiv / st->sr) / 0.040);
    {
        double ref = st->jtDeep > 0.0 ? st->jtDeep : 0.0;
        for (int s = 0; s < njt; s++) {
            double d = jt_maxpen(st->jtM[s], J,
                                 st->jtPhiU + st->jtZOff[s],
                                 st->jtB + (size_t)s * J,
                                 st->jtQ + st->jtMOff[s]);
            if (d > ref) ref = d;
        }
        st->jtLiftRef = ref > 1e-12 ? ref : 1e-12;
    }
}

#define JT_MAXM 72
#define JT_MAXJ 44

/* the implicit contact solve (float, Hertzian fast path): vector Newton on
   the diagonal compliance inside an under-relaxed off-diagonal lag loop,
   projection cap c/gd. alpha == 1.5 collapses every pow to sqrtf. */
/* x^A for x in (1e-12, ~0.05], A in (0,1): pure-arithmetic log2/exp2 (no
   libm powf, so the bits are platform-identical). */
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
    /* ACTIVE-SET matvec: only nonzero-F columns are iterated (F[k] is EXACTLY
       0.0f off the set, so the result is unchanged). */
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
        /* inner Newton over the active-c list only (skipped points hold f=0
           already) */
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
        /* float-appropriate exit: 1e-4 relative */
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

/* contact core at step dts on tables (G, gd): solve on the zone snapshot,
   Hunt-Crossley (dissipative-only), impulse into q/p (double accumulation) */
static void jt_core(int M, int J, const float *u, const float *ud,
                    const float *phiF, const float *b_,
                    const float *G, const float *gd,
                    float kc, float alpha, float hcB,
                    double dts, double *q, double *p, float *fsum)
{
    float F[JT_MAXJ];
    if (!jt_solve(J, b_, u, G, gd, kc, alpha, F)) return;
    for (int j = 0; j < J; j++) {
        float hc = 1.0f + hcB * (-ud[j]);
        if (hc < 0.15f) hc = 0.15f;
        if (hc > 1.0f) hc = 1.0f;
        F[j] *= hc;
    }
    /* radiation tap: force-density sum after the dissipative scaling (read
       only) */
    if (fsum) {
        float t = 0.0f;
        for (int j = 0; j < J; j++) t += F[j];
        *fsum += t;
    }
    double h2 = 0.5 * dts * dts;
    /* project only the active force columns (the rest are exactly 0.0f) */
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

/* MELODY FOLLOWER: slew the row's f0 and rebuild its tables in place on
   the ticking thread. The static wrap is NOT re-solved — the contact
   re-settles on its own, exactly a string gliding under the bone. */
static void jt_track_retune(bow_poly_state_t *st)
{
    const int s = st->jtTrkRow;
    double tgt = st->jtTrkTarget;
    if (tgt < 20.0) return;
    if (tgt > 0.45 * st->sr) tgt = 0.45 * st->sr;
    double f = st->jtTrkF0;
    const double d = tgt - f;
    if (fabs(d) < 1e-5 * f) f = tgt;          /* < ~0.02 c: snap */
    else f += st->jtTrkSlew * d;
    st->jtTrkF0 = f;
    if (f == st->jtTrkApplied && !st->jtTrkDirty) return;
    st->jtTrkDirty = 0;
    st->jtTrkApplied = f;
    const int J = st->jtJ;
    const int mo = st->jtMOff[s], zo = st->jtZOff[s];
    const int Mall = st->jtM[s];
    const double dtj = (double)st->jtDiv / st->sr;
    const double dt4 = 0.25 * dtj;
    /* active mode count, no floor: a mode above the fx corner limit-cycles into
       static */
    int mUse = (int)(st->jtTrkFx / f);
    if (mUse < 2) mUse = 2;
    if (mUse > Mall) mUse = Mall;
    const double t60 = st->jtTrkT60 > 1e-3 ? st->jtTrkT60 : 1.0;
    const double fHf = st->jtTrkFhf > 1.0 ? st->jtTrkFhf : 4000.0;
    const double bst = st->jtTrkBst;
    const double twoPi = 2.0 * 3.14159265358979;
    for (int k = 0; k < mUse; k++) {
        const double kk = (double)(k + 1);
        const double w0 = twoPi * f * kk * sqrt(1.0 + bst * kk * kk);
        const double fk = w0 / twoPi;
        /* the builder's per-mode damping law */
        const double t60k = 1.0 / (1.0 / t60
            + (fk / fHf) * (fk / fHf) * (1.0 / t60));
        const double sg = 6.91 / t60k;
        const double wd2 = w0 * w0 - sg * sg;
        const double wd = sqrt(wd2 > 1e-6 ? wd2 : 1e-6);
        st->jtWd[mo + k] = wd;
        st->jtWdI[mo + k] = 1.0 / wd;
        const double e1 = exp(-sg * dtj), e4 = exp(-sg * dt4);
        st->jtCa[mo + k] = e1 * cos(wd * dtj);
        st->jtCb[mo + k] = e1 * sin(wd * dtj);
        st->jtCa4[mo + k] = e4 * cos(wd * dt4);
        st->jtCb4[mo + k] = e4 * sin(wd * dt4);
    }
    if (mUse != st->jtTrkMUse) {
        /* modes leaving/entering the active set start from zero */
        const int lo = mUse < st->jtTrkMUse ? mUse : st->jtTrkMUse;
        int hi = mUse > st->jtTrkMUse ? mUse : st->jtTrkMUse;
        if (hi > Mall) hi = Mall;
        for (int k = lo; k < hi; k++) {
            st->jtQ[mo + k] = 0.0;
            st->jtP[mo + k] = 0.0;
        }
        /* contact compliance = prefix sum over the active modes: G[a][b] =
           (dt^2/2) * sum_k phiU[k][a]*phiF[k][b] (phiF carries wj/mu) */
        float *G = st->jtG + (size_t)s * (size_t)J * J;
        float *G4 = st->jtG4 + (size_t)s * (size_t)J * J;
        float *gd = st->jtGd + (size_t)s * J;
        float *gd4 = st->jtGd4 + (size_t)s * J;
        const float *phiU = st->jtPhiU + zo;
        const float *phiF = st->jtPhiF + zo;
        const double h2 = dtj * dtj / 2.0;
        for (int a = 0; a < J; a++) {
            for (int b2 = 0; b2 < J; b2++) {
                double sum = 0.0;
                for (int k = 0; k < mUse; k++)
                    sum += (double)phiU[(size_t)k * J + a]
                         * (double)phiF[(size_t)k * J + b2];
                G[(size_t)a * J + b2] = (float)(h2 * sum);
                G4[(size_t)a * J + b2] = (float)(h2 * sum / 16.0);
            }
            gd[a] = G[(size_t)a * J + a];
            gd4[a] = G4[(size_t)a * J + a];
        }
        st->jtTrkMUse = mUse;
    }
}

/* advance the evolution-lift slew one divided jt sample (never on the
   workers). The snap restores the exact ev == 0.0 path at rest. */
static inline double jt_ev_step(bow_poly_state_t *st)
{
    double c = st->jtEvCur;
    const double t = st->jtEvTgt;
    if (c == t) return c;
    c += st->jtEvA * (t - c);
    if (fabs(t - c) < 1e-12) c = t;
    st->jtEvCur = c;
    return c;
}

/* instant-attack peak envelope: a peak jumps to the input, anything below it
   walks toward it at `rel`. The one idiom behind the cap, scope and voice
   side-chain envelopes. */
static inline double peak_env(double e, double a, double rel)
{
    return a > e ? a : e + rel * (a - e);
}

/* One cap stage: peak envelope against the ceiling, the pow(c/e, h) target
   and the attack/release gain slew. Shared by the per-string rows and the
   taraf bus — the caller owns the state triple and the exponent; a
   generation bump resets the stage on its own thread. */
static inline double cap_gain_step(const bow_poly_state_t *st, double cap,
                                   double a, double h, int *gen,
                                   double *env, double *gain)
{
    if (*gen != st->jtCapGen) {
        *gen = st->jtCapGen;
        *env = 0.0;
        *gain = 1.0;
    }
    const double e = peak_env(*env, a, st->jtCapTRel);
    *env = e;
    const double c = cap + 1e-12;
    double gT = 1.0;
    if (e > c && h > 0.0)
        gT = h >= 1.0 ? c / e : pow(c / e, h);
    double g = *gain;
    if (gT < g) g += st->jtCapAtk * (gT - g);
    else g += st->jtCapRel * (gT - g);
    *gain = g;
    return g;
}

/* One row, one divided jt sample — the threading unit (touches only row s
   + shared read-only tables; penmax accumulates locally). cap = this
   tick's row ceiling (jt_cap_ceiling), < 0 = off, cap state untouched. */
static double jt_tick_string(bow_poly_state_t *st, int s, double Fd,
                             double ev, double cap, double *penmax,
                             double *cplOut)
{
    const int J = st->jtJ;
    const double dtj = (double)st->jtDiv / st->sr;
    /* QUIESCENCE GATE early-out: an asleep row skips the whole tick; raw
       bridge drive above its wake bound or any drone drive resumes it from
       the frozen state (no re-settle). */
    const double FdIn = Fd;
    if (st->jtGateRef > 0.0 && st->jtGateSlp[s]) {
        if (fabs(Fd) <= st->jtGateFdEps[s]
            && st->jtDnBoost[s] == 0.0 && st->jtDnEnv[s] == 0.0
            && st->jtDnTgt[s] == 0.0)
            return 0.0;
        st->jtGateSlp[s] = 0;
        st->jtGateCnt[s] = st->jtGateHold;
    }
    /* melody-follower retune, amortized every jtTrkIval ticks of the tracked
       row */
    if (s == st->jtTrkRow && --st->jtTrkTick <= 0) {
        st->jtTrkTick = st->jtTrkIval;
        jt_track_retune(st);
    }
    {
        const int Ms = s == st->jtTrkRow ? st->jtTrkMUse : st->jtM[s];
        const int mo = st->jtMOff[s], zo = st->jtZOff[s];
        double *q = st->jtQ + mo, *p = st->jtP + mo;
        /* RECRUITMENT: slewed per-row drive weight (~30 ms), before the drone
           branch so a held drone is never ducked. Unarmed = byte-null. */
        if (st->jtDwOn) {
            double c = st->jtDwCur[s];
            c += st->jtDwA * (st->jtDwTgt[s] - c);
            st->jtDwCur[s] = c;
            Fd *= c;
        }
        /* EVOLUTION REGISTER TILT: slew this row's own bone offset onto the
           global
           lift (an asleep row freezes its slew with the rest of its state). */
        double evs = ev;
        if (st->jtEvOfsOn) {
            double c = st->jtEvOfsCur[s];
            c += st->jtEvOfsA * (st->jtEvOfsTgt[s] - c);
            st->jtEvOfsCur[s] = c;
            evs += c;
        }
        /* DRONE row: a slewed band-passed drive (hold + decaying onset boost),
           no
           impulse. Whole branch guarded: all-zero = the unarmed tick,
           bit-exact. */
        if (st->jtDnBoost[s] != 0.0 || st->jtDnEnv[s] != 0.0
            || st->jtDnTgt[s] != 0.0) {
            double bst = st->jtDnBoost[s];
            double eff = st->jtDnTgt[s] + bst;
            if (bst != 0.0) {
                bst *= st->jtDnBDec;
                if (bst < 1e-9) bst = 0.0;
                st->jtDnBoost[s] = bst;
            }
            double env = st->jtDnEnv[s];
            env += (eff > env ? st->jtDnAAtk : st->jtDnA) * (eff - env);
            if (env < 1e-9 && eff == 0.0) env = 0.0;
            st->jtDnEnv[s] = env;
            if (env != 0.0) {
                unsigned long long x = st->jtDnRng[s];
                x ^= x << 13; x ^= x >> 7; x ^= x << 17;
                st->jtDnRng[s] = x;
                double w = (double)(long long)(x >> 11)
                    * (1.0 / 4503599627370496.0) - 1.0;
                /* band-passed noise (sub-audio content would pump the buzz) */
                double lp = st->jtDnLp[s];
                lp += st->jtDnALp * (w - lp);
                st->jtDnLp[s] = lp;
                double lp2 = st->jtDnLp2[s];
                lp2 += st->jtDnALp2 * (lp - lp2);
                st->jtDnLp2[s] = lp2;
                double drv = lp - lp2;
                /* pitched part: a sine at the row's own mode-1 frequency */
                const double mix = st->jtDnMix;
                if (mix > 0.0) {
                    double ph = st->jtDnPh[s]
                        + st->jtWd[mo] * dtj;
                    if (ph > 6.283185307179586)
                        ph -= 6.283185307179586;
                    st->jtDnPh[s] = ph;
                    drv = mix * sin(ph) + (1.0 - mix) * drv;
                }
                Fd += env * drv;
            }
        }
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
        /* TILT bone lift: the bone drops jtLift below its profile and the row
           rings as a pure modal taraf; composed with the signed evolution lift.
           0 = the bit-exact contact. */
        const float lift = (float)(st->jtLift + evs);
        float bl[JT_MAXJ];
        const float *bc_ = b_;
        if (lift != 0.0f) {
            for (int j = 0; j < J; j++) bl[j] = b_[j] - lift;
            bc_ = bl;
        }
        /* TWO BRIDGES: the row's own contact law when armed, else the exact
           global scalars */
        const float kcR = (float)st->jtKc;
        const float alphaR = (float)(st->jtRowContactOn
                                     ? st->jtRowAlpha[s] : st->jtAlpha);
        const float hcBR = (float)(st->jtRowContactOn
                                   ? st->jtRowHcB[s] : st->jtHcB);
        const double deepRow = st->jtRowContactOn
                               ? st->jtRowDeep[s] : st->jtDeep;
        /* deep-substep threshold follows the evolution lift (phys[3] =
           2.5·apex) */
        double deepEff = deepRow - 2.5 * evs;
        if (deepEff < 1e-7) deepEff = 1e-7;
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
            float d = bc_[j] - u[j];
            if (d > pen) pen = d;
        }
        if ((double)pen > *penmax) *penmax = (double)pen;
        float fsum = 0.0f;   /* contact force-density sum this tick */
        if ((double)pen > deepEff) {
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
                jt_core(Ms, J, u, ud, phiF, bc_, G4_, gd4_,
                        kcR, alphaR, hcBR, dt4, q, p, &fsum);
            }
            fsum *= 0.25f;   /* mean over the substeps */
        } else {
            jt_core(Ms, J, u, ud, phiF, bc_, G_, gd_,
                    kcR, alphaR, hcBR, dtj, q, p, &fsum);
        }
        {
            const double *pd_ = st->jtPhiD + mo;
            double w = st->jtDrvTermCur[s];
            w += st->jtRadSlewA * (st->jtDrvTerm - w);
            st->jtDrvTermCur[s] = w;
            if (w == 0.0) {
                for (int k = 0; k < Ms; k++) p[k] += dtj * Fd * pd_[k];
            } else {
                const double *pt_ = st->jtPhiDT + mo;
                for (int k = 0; k < Ms; k++)
                    p[k] += dtj * Fd * (pd_[k] + w * (pt_[k] - pd_[k]));
            }
        }
        /* TILT extra decay: momentum-proportional loss per tick; 0 / >= 1 =
           off */
        const double dampm = st->jtDampMul;
        if (dampm > 0.0 && dampm < 1.0)
            for (int k = 0; k < Ms; k++) p[k] *= dampm;
        /* QUIESCENCE GATE entry: a full hold window of sub-floor LOW-MODE
           momentum
           with no bridge or drone drive freezes the row in place (only low-mode
           |p| can meter quiescence — see the state block). Armed only. */
        if (st->jtGateRef > 0.0) {
            const int kg = Ms < 6 ? Ms : 6;
            double am = 0.0;
            for (int k = 0; k < kg; k++) {
                const double t = fabs(p[k]);
                if (t > am) am = t;
            }
            /* probe telemetry: what would block this row's sleep */
            {
                const double amr = am / (st->jtGateRef * st->jtWd[mo]);
                const double fdr = fabs(FdIn) / st->jtGateFdEps[s];
                if (amr > st->jtGateAmR) st->jtGateAmR = amr;
                if (fdr > st->jtGateFdR) st->jtGateFdR = fdr;
                if (st->jtDnBoost[s] != 0.0 || st->jtDnEnv[s] != 0.0
                    || st->jtDnTgt[s] != 0.0)
                    st->jtGateDnHot = 1;
            }
            if (am < st->jtGateRef * st->jtWd[mo]
                && fabs(FdIn) <= st->jtGateFdEps[s]
                && st->jtDnBoost[s] == 0.0 && st->jtDnEnv[s] == 0.0
                && st->jtDnTgt[s] == 0.0) {
                if (--st->jtGateCnt[s] <= 0) {
                    st->jtGateSlp[s] = 1;
                    st->jtGateCnt[s] = st->jtGateHold;
                }
            } else
                st->jtGateCnt[s] = st->jtGateHold;
        }
        /* BRIDGE-FORCE RADIATION: DC-blocked, unit-matched contact force */
        double rs = st->jtRadScaleCur[s];
        rs += st->jtRadSlewA * (st->jtRadScale[s] - rs);
        st->jtRadScaleCur[s] = rs;
        double fr = rs * (double)fsum;
        /* TERMINATION (PIN) FORCE: the linear, comb-free bridge force at the
           pin, weighted flat-per-k — always radiated beside the contact
           force, ahead of the DC blocker. */
        {
            double ps = st->jtRadPinScaleCur[s];
            ps += st->jtRadSlewA * (st->jtRadPinScale[s] - ps);
            st->jtRadPinScaleCur[s] = ps;
            double sp = 0.0;
            for (int k = 0; k < Ms; k++) {
                const double t = (double)(k + 1) * q[k];
                sp += (k & 1) ? t : -t;      /* (-1)^k, k the 1-based mode */
            }
            fr += ps * sp;
        }
        /* TWO-WAY COUPLING pickup: the row's own bridge force in newtons,
           BEFORE the DC blocker and before the output cap (both are
           radiation-side, not physics). */
        if (cplOut) *cplOut += st->jtCplScale[s] * fr;
        double lp = st->jtRadLp[s];
        if (st->jtRadPrime[s]) { lp = fr; st->jtRadPrime[s] = 0; }
        lp += st->jtRadA * (fr - lp);
        st->jtRadLp[s] = lp;
        double yjt = fr - lp;
        /* PER-STRING CAP: pure output gain after the physics; a fresh arm
           (generation bump) resets the row here, on its own worker. */
        if (cap >= 0.0) {
            const double h = st->jtCapHard;
            yjt *= cap_gain_step(st, cap, fabs(yjt), h,
                                 &st->jtCapRowGen[s], &st->jtCapEnv[s],
                                 &st->jtCapGain[s]);
        }
        /* SCOPE TELEMETRY (after the cap — what the row actually
           contributes) */
        if (st->scopeOn) {
            const double e = peak_env(st->scopeEnv[s], fabs(yjt),
                                      st->scopeRel);
            st->scopeEnv[s] = e;
            if ((++st->scopeCnt[s] & 3u) == 0u) {
                const int SK = st->scopeK;
                const int K = SK < Ms ? SK : Ms;
                float *me = st->scopeMode + (size_t)s * (size_t)SK;
                const float dk = st->scopeModeDk;
                for (int k = 0; k < K; k++) {
                    const float pk = fabsf((float)p[k]);
                    const float d = me[k] * dk;
                    me[k] = pk > d ? pk : d;
                }
                for (int k = K; k < SK; k++) me[k] *= dk;
            }
        }
        return yjt;
    }
}

/* The per-tick ROW ceiling: recorded voice peak × ratio ÷ the jt output
   gain (so a row's raw sample compares with the voice in bus units).
   < 0 = off. */
static inline double jt_cap_ceiling(const bow_poly_state_t *st, double venv)
{
    if (st->jtCapHard <= 0.0) return -1.0;
    double g = fabs(st->jtGain);
    if (st->jtGMulOn) g *= fabs(st->jtGMulCur);
    if (g < 1e-12) g = 1e-12;
    return venv * st->jtCapRatio / g;
}

/* sideOut (nullable): accumulates the pan-weighted row sum for the stereo side
   path */
static double jt_tick(bow_poly_state_t *st, double Fd, double ev,
                      double cap, double *sideOut, double *cplOut)
{
    double jrad = 0.0;
    double pen = st->jtPenMax;
    double cpl = 0.0;
    double *cp = cplOut ? &cpl : NULL;
    if (sideOut && st->stJtPan) {
        double side = 0.0;
        for (int s = 0; s < st->njt; s++) {
            double y = jt_tick_string(st, s, Fd, ev, cap, &pen, cp);
            jrad += y;
            side += st->stJtPan[s] * y;
        }
        *sideOut = side;
    } else {
        for (int s = 0; s < st->njt; s++)
            jrad += jt_tick_string(st, s, Fd, ev, cap, &pen, cp);
        if (sideOut) *sideOut = 0.0;
    }
    if (cplOut) *cplOut = cpl;
    st->jtPenMax = pen;
    return jrad;
}

/* ---- persistent jt worker pool ---- */
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
        const double *evv = st->jtEvV;
        const double *capv = st->jtCapV;
        /* stereo: pan-weighted side partials ride a second accumulator row */
        double *hpS = (st->stOn && st->jtHpS && st->stJtPan)
            ? st->jtHpS + (size_t)idx * JT_POOL_CH : NULL;
        /* two-way coupling: a second partial-sum row, in newtons */
        double *hpC = (st->jtCplOn && st->jtHpC)
            ? st->jtHpC + (size_t)idx * JT_POOL_CH : NULL;
        for (int s = s0; s < s1; s++) {
            const double pn = hpS ? st->stJtPan[s] : 0.0;
            for (int k = 0; k < nT; k++) {
                double y = jt_tick_string(st, s, fd[k], evv[k],
                                          capv[k], &pen,
                                          hpC ? hpC + k : NULL);
                hp[k] += y;
                if (hpS) hpS[k] += pn * y;
            }
        }
        st->jtWPen[idx] = pen;
        pthread_mutex_lock(&st->jtMx);
        st->jtDone++;
        if (st->jtDone >= st->jtPoolN)
            pthread_cond_broadcast(&st->jtCvD);
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
    /* a dispatcher mid-rendezvous waits on jtCvD — wake it too, or a
       teardown/resize during a dispatch wedges it forever */
    pthread_cond_broadcast(&st->jtCvD);
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
        pthread_mutex_init(&st->jtDispMx, NULL);
        pthread_cond_init(&st->jtCvW, NULL);
        pthread_cond_init(&st->jtCvD, NULL);
        st->jtPoolInit = 1;
    }
    jt_pool_stop(st);
    if (nth < 2) return;
    if (!st->jtHp) {
        st->jtFrCap = JT_POOL_CH;
        st->jtFrBuf = (double *)malloc(sizeof(double) * JT_POOL_CH);
        st->jtCapBuf = (double *)malloc(sizeof(double) * JT_POOL_CH);
        st->jtFdv = (double *)malloc(sizeof(double) * JT_POOL_CH);
        st->jtEvV = (double *)calloc(JT_POOL_CH, sizeof(double));
        st->jtCapV = (double *)calloc(JT_POOL_CH, sizeof(double));
        st->jtTkv = (int *)malloc(sizeof(int) * JT_POOL_CH);
        st->jtHp = (double *)malloc(sizeof(double) * 16 * JT_POOL_CH);
        st->jtHpS = (double *)malloc(sizeof(double) * 16 * JT_POOL_CH);
        st->jtHpC = (double *)malloc(sizeof(double) * 16 * JT_POOL_CH);
        st->jtWebScr = (double *)malloc(sizeof(double) * JT_POOL_CH);
        st->jtWebScrS = (double *)malloc(sizeof(double) * JT_POOL_CH);
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

/* Install the jt-drive FX hook OFF the audio thread; NULL fn = byte-null.
   Context is stored first so a non-NULL fn never sees a stale ctx. */
void bow_poly_set_drive_fx(void *vst,
                           void (*fn)(void *ctx, double *buf, int n),
                           void *ctx)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->fxDriveCtx = ctx;
    st->fxDriveFn = fn;
}

/* ---- sitar→taraf inject ---- */
#define SJ_RINGN 32768

/* Control thread (drone-setter contract + a one-time ring alloc on the
   first non-zero gain — never the audio thread). */
void bow_poly_jt_inject_gain(void *vst, double g)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    if (g != 0.0 && !st->sjRing) {
        double *r = (double *)calloc(SJ_RINGN, sizeof(double));
        st->sjW = 0; st->sjR = 0;
        __atomic_store_n(&st->sjRing, r, __ATOMIC_RELEASE);
    }
    st->sjGain = g;
}

/* Producer render thread (the other voice's callback). Drops the block
   when the ring is full; the consumer realigns on gross backlog. */
void bow_poly_jt_inject_write(void *vst, const double *x, int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || n <= 0) return;
    double *ring = __atomic_load_n(&st->sjRing, __ATOMIC_ACQUIRE);
    if (!ring) return;
    long long ww = st->sjW;
    long long rr = __atomic_load_n(&st->sjR, __ATOMIC_ACQUIRE);
    if (ww - rr > SJ_RINGN - n) return;   /* full: drop */
    for (int t = 0; t < n; t++)
        ring[(ww + t) & (SJ_RINGN - 1)] = x[t];
    __atomic_store_n(&st->sjW, ww + n, __ATOMIC_RELEASE);
}

/* jt tone LP/HP: a <= 0 = bypass (bit-exact); mid + side states are
   preserved on coefficient moves. Plain scalar writes, any thread. */
void bow_poly_jt_set_lp(void *vst, double a)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->jtLpA = a;
}

void bow_poly_jt_set_hp(void *vst, double a)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->jtHpA = a;
}

static void jt_gate_eps(bow_poly_state_t *st, double refDisp);

/* TERMINATION DRIVE morph 0..1 (bow_jt_drive_term): 0 = the fitted 0.90 L
   tap shape (byte-null — every row's slewed copy rests at 0 and the tick
   takes the exact tap branch), 1 = the pin's mode-slope shape (energy-matched
   per row to the tap, so the row's total drive energy is unchanged and only
   its distribution over the modes moves). Plain scalar
   store, any thread; each row slews toward it on the radiation's ~40 ms law.
   The gate's wake bound follows the effective shape. */
void bow_poly_jt_set_drive_term(void *vst, double w)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (w < 0.0) w = 0.0;
    if (w > 1.0) w = 1.0;
    if (w == st->jtDrvTerm) return;
    st->jtDrvTerm = w;
    if (st->jtGateRef > 0.0) jt_gate_eps(st, st->jtGateRef);
}

/* jt BODY radiation mix 0..1 — plain scalar store, any thread, slewed
   ~30 ms at the kernel rate; never calling it is byte-null. */
/* TWO-WAY BRIDGE COUPLING gain (`bow_jt_couple`): how much of the rows'
   own summed bridge force (newtons) returns into the played strings' F.
   Control-thread scalar; the render loop slews it ~40 ms and reads the
   post-pass FIFO one block back. 0 with a rested slew = byte-null. */
void bow_poly_jt_set_couple(void *vst, double g)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    if (g < 0.0) g = 0.0;
    if (g > 4.0) g = 4.0;
    st->jtCplG = g;
}

void bow_poly_jt_set_body(void *vst, double mix)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (mix < 0.0) mix = 0.0;
    if (mix > 1.0) mix = 1.0;
    /* a 0 push while unarmed stays a no-op (arming would tick K idle biquads
       per sample forever) */
    if (!st->jtBodyOn && mix <= 0.0) return;
    st->jtBodyTgt = mix;
    st->jtBodyOn = 1;
}

/* Arm the side path with per-source pans (jtPan[njt] after
   jt_load, slotPan[nb]; NULL = centred). Engine build, off the audio thread. */
void bow_poly_set_stereo(void *vst,
                         const double *jtPan, int nJt,
                         const double *slotPan, int nSlot)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    free(st->stSlotPan); free(st->stJtPan);
    st->stSlotPan = (double *)calloc(st->nb, sizeof(double));
    st->stJtPan = (double *)calloc(st->njt > 0 ? st->njt : 1,
                                   sizeof(double));
    if (slotPan && nSlot == st->nb)
        memcpy(st->stSlotPan, slotPan, sizeof(double) * (size_t)st->nb);
    if (jtPan && st->njt > 0 && nJt == st->njt)
        memcpy(st->stJtPan, jtPan, sizeof(double) * (size_t)st->njt);
    st->jtLpYS = 0.0;
    st->jtHpYS = 0.0;
    memset(st->jbsx1, 0, sizeof(st->jbsx1));
    memset(st->jbsx2, 0, sizeof(st->jbsx2));
    memset(st->jbsy1, 0, sizeof(st->jbsy1));
    memset(st->jbsy2, 0, sizeof(st->jbsy2));
    st->jtHoldS = 0.0;
    st->jtOutHoldS = 0.0;
    st->stOn = 1;
}

/* INSTRUMENT WIDTH derive: 16 modes log-spaced 700 Hz -> 6.5 kHz (golden
   jitter, Q ~ 12, plastic-number signs), peak-normalized, × 1.4 × a
   log-frequency directivity ramp (0 below 300 Hz -> 1 at 3 kHz). Depends
   only on the sample rate. */
static double poly_width_ramp(double f)
{
    if (f <= 300.0) return 0.0;
    double d = (log2(f) - log2(300.0)) / (log2(3000.0) - log2(300.0));
    return d > 1.0 ? 1.0 : d;
}

static void poly_width_derive(bow_poly_state_t *st)
{
    const double GOLD = 0.6180339887498949;
    const double SIGNQ = 0.7548776662466927;
    st->sdN = 0;
    for (int k = 0; k < 16; k++) {
        double u = fmod((double)(k + 1) * GOLD, 1.0);
        double f = 700.0 * pow(6500.0 / 700.0,
                               ((double)k + 0.5 + 0.8 * (u - 0.5)) / 16.0);
        if (f >= 0.45 * st->sr) break;
        double qq = 12.0 * (0.7 + 0.6 * u);
        double R = exp(-M_PI * f / (qq * st->sr));
        double th = 2.0 * M_PI * f / st->sr;
        double a1 = 2.0 * R * cos(th), a2 = -(R * R);
        double c1 = cos(th), s1 = sin(th);
        double c2 = cos(2.0 * th), s2 = sin(2.0 * th);
        double nr = 1.0 - c2, ni = s2;                    /* 1 - z^-2 */
        double dr = 1.0 - a1 * c1 - a2 * c2;
        double di = a1 * s1 + a2 * s2;
        double mag = sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
        double sg = fmod((double)(k + 1) * SIGNQ, 1.0) < 0.5 ? 1.0 : -1.0;
        int i = st->sdN;
        st->sdA1[i] = a1;
        st->sdA2[i] = a2;
        st->sdN0[i] = 1.0 / (mag > 1e-12 ? mag : 1e-12);
        st->sdG[i] = sg * 1.4 * poly_width_ramp(f);
        st->sdN = i + 1;
    }
    st->stWidthSl = 1.0 - exp(-1.0 / (0.030 * st->sr));
}

/* one width-bank step for bus b ([0] voice, [1] jt wash): shared coefficients,
   per-bus state */
static inline double poly_width_bank(bow_poly_state_t *st, int b, double x)
{
    double acc = 0.0;
    for (int k = 0; k < st->sdN; k++) {
        double y = st->sdN0[k] * (x - st->sdX2[b][k])
            + st->sdA1[k] * st->sdY1[b][k] + st->sdA2[k] * st->sdY2[b][k];
        st->sdX2[b][k] = st->sdX1[b][k]; st->sdX1[b][k] = x;
        st->sdY2[b][k] = st->sdY1[b][k]; st->sdY1[b][k] = y;
        acc += st->sdG[k] * y;
    }
    return acc;
}

/* Arm / retarget the width: the bank stores unit width and the scalar is
   slewed ~30 ms on the render thread. Call off the audio thread; width 0
   from a cold start = byte-null. */
void bow_poly_set_stereo_width(void *vst, double width)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    st->stWidthTgt = width;
    if (!st->stWidthOn && width <= 1e-9) return;   /* stay byte-null */
    poly_width_derive(st);
    st->stWidthOn = 1;         /* arm last — the render gates on it */
}

/* the slewed jt output gain, stepped ONCE per kernel output sample (call
   once per sample and reuse for the side stream) */
static inline double jt_gain_step(bow_poly_state_t *st)
{
    st->jtGainCur += st->jtGainA * (st->jtGain - st->jtGainCur);
    return st->jtGainCur;
}

/* one filtered step of the jt output walk (bypass = warm-tracked identity)
   and the ONE slew point of the lush gain jtGMul, applied to the RETURN
   only so engaging it never steps the filter state. */
static inline double jt_lp_step(bow_poly_state_t *st, double x)
{
    double m = 1.0;
    if (st->jtGMulOn) {
        st->jtGMulCur += st->jtGMulA * (st->jtGMulTgt - st->jtGMulCur);
        m = st->jtGMulCur;
    }
    /* jt BODY radiation before the tone LP/HP (the rows radiate into the
       body; the tone pair is EQ after it). Mix slewed ~30 ms; mix 0 adds
       exactly 0.0. */
    if (st->jtBodyOn) {
        st->jtBodyCur += st->jtBodyA * (st->jtBodyTgt - st->jtBodyCur);
        double wet = st->c0 * x;
        const int Kb = st->K;
        for (int k = 0; k < Kb; k++) {
            double y = st->bn0[k] * (x - st->jbx2[k])
                + st->ba1[k] * st->jby1[k] + st->ba2[k] * st->jby2[k];
            st->jbx2[k] = st->jbx1[k]; st->jbx1[k] = x;
            st->jby2[k] = st->jby1[k]; st->jby1[k] = y;
            wet += st->bC[k] * y;
        }
        x += st->jtBodyCur * (wet - x);
    }
    if (st->jtLpA <= 0.0) st->jtLpY = x;
    else { st->jtLpY += st->jtLpA * (x - st->jtLpY); x = st->jtLpY; }
    /* jt tone HP (x − LP(x)) after the LP; unarmed = warm-tracked identity */
    if (st->jtHpA <= 0.0) st->jtHpY = x;
    else { st->jtHpY += st->jtHpA * (x - st->jtHpY); x -= st->jtHpY; }
    return m * x;
}

/* side twin (own states, same coefficients) */
static inline double jt_lp_stepS(bow_poly_state_t *st, double x)
{
    const double m = st->jtGMulOn ? st->jtGMulCur : 1.0;
    /* body twin: reads the mix the mono step just advanced */
    if (st->jtBodyOn) {
        double wet = st->c0 * x;
        const int Kb = st->K;
        for (int k = 0; k < Kb; k++) {
            double y = st->bn0[k] * (x - st->jbsx2[k])
                + st->ba1[k] * st->jbsy1[k] + st->ba2[k] * st->jbsy2[k];
            st->jbsx2[k] = st->jbsx1[k]; st->jbsx1[k] = x;
            st->jbsy2[k] = st->jbsy1[k]; st->jbsy1[k] = y;
            wet += st->bC[k] * y;
        }
        x += st->jtBodyCur * (wet - x);
    }
    if (st->jtLpA <= 0.0) st->jtLpYS = x;
    else { st->jtLpYS += st->jtLpA * (x - st->jtLpYS); x = st->jtLpYS; }
    if (st->jtHpA <= 0.0) st->jtHpYS = x;
    else { st->jtHpYS += st->jtHpA * (x - st->jtHpYS); x -= st->jtHpYS; }
    return m * x;
}

/* Radiated-gain multiplier (the lush half of recruitment), slewed ~30 ms
   in jt_lp_step. Plain scalar store, any thread; 1 = bit-exact. */
void bow_poly_jt_set_gain_mul(void *vst, double m)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (m < 0.0) m = 0.0;
    if (m > 4.0) m = 4.0;
    st->jtGMulTgt = m;
    st->jtGMulOn = 1;
}

/* Per-row bridge-drive weights (recruitment) — plain stores, any thread;
   the jt tick slews. All-ones is bit-exact. */
void bow_poly_jt_drive_weights(void *vst, const double *w, int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->jtDwTgt || !w || n <= 0) return;
    if (n > st->njt) n = st->njt;
    for (int s = 0; s < n; s++) {
        double v = w[s];
        if (v < 0.0) v = 0.0;
        if (v > 4.0) v = 4.0;
        st->jtDwTgt[s] = v;
    }
    st->jtDwOn = 1;
}

/* HARMONIC-EVOLUTION lift in meters (BowEngine owns the 0…1 map), slewed
   ~40 ms so a tilt sweep is an adjustment, not a strum. Plain store. */
void bow_poly_jt_set_evolve(void *vst, double meters)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (meters > 1e-3) meters = 1e-3;
    if (meters < -1e-3) meters = -1e-3;
    st->jtEvTgt = meters;
    /* wake sleeping gate rows on a MATERIAL move (else they meet the moved
       bone as a step); change-gated against jtGateEvWake so drift wakes while
       a re-pushed constant never does */
    if (st->jtGateRef > 0.0 && st->jtGateSlp
        && fabs(meters - st->jtGateEvWake) > 0.02 * st->jtDeep) {
        st->jtGateEvWake = meters;
        for (int s = 0; s < st->njt; s++) st->jtGateSlp[s] = 0;
    }
}

/* EVOLUTION REGISTER TILT: per-row signed bone offsets in meters; a
   sleeping row whose target materially moves is woken. Plain array writes. */
void bow_poly_jt_set_evolve_ofs(void *vst, const double *ofs, int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->jtEvOfsTgt || !ofs || n <= 0) return;
    if (n > st->njt) n = st->njt;
    for (int s = 0; s < n; s++) {
        double v = ofs[s];
        if (v > 1e-3) v = 1e-3;
        if (v < -1e-3) v = -1e-3;
        if (st->jtGateRef > 0.0 && st->jtGateSlp && st->jtGateSlp[s]
            && fabs(v - st->jtEvOfsTgt[s]) > 0.02 * st->jtDeep)
            st->jtGateSlp[s] = 0;
        st->jtEvOfsTgt[s] = v;
    }
    st->jtEvOfsOn = 1;
}

/* TWO BRIDGES setter: alpha = exponent, hcb = hysteretic damping, deep =
   substep threshold (2.5 × apex). Exactly-global rows tick bit-identically
   to the unarmed path. Plain stores; survives bow_poly_jt_set_coeffs. */
void bow_poly_jt_set_row_contact(void *vst, const double *alpha,
                                 const double *hcb, const double *deep,
                                 int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->jtRowAlpha || n <= 0) return;
    if (n > st->njt) n = st->njt;
    for (int s = 0; s < n; s++) {
        if (alpha) {
            double a = alpha[s];
            if (a < 1.0) a = 1.0;
            if (a > 3.0) a = 3.0;
            st->jtRowAlpha[s] = a;
        }
        if (hcb) {
            double h = hcb[s];
            if (h < 0.0) h = 0.0;
            st->jtRowHcB[s] = h;
        }
        if (deep) {
            double d = deep[s];
            if (d < 1e-7) d = 1e-7;
            st->jtRowDeep[s] = d;
        }
    }
    st->jtRowContactOn = 1;
}

void bow_poly_jt_set_damp_t60(void *vst, double t60)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (t60 > 0.0) {
        double dtj = (double)st->jtDiv / st->sr;
        st->jtDampMul = exp(-2.0 * 6.907755278982137 * dtj / t60);
    } else {
        st->jtDampMul = 0.0;
    }
}

/* PER-STRING CAP: hard 0..1 (0 = byte-null), ratio vs the voice peak. An
   arm edge bumps the generation — rows reset on their own workers, no array
   writes here. Armed flag written last. */
void bow_poly_jt_set_cap(void *vst, double hard, double ratio)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (hard > 0.0) {
        if (st->jtCapHard <= 0.0) st->jtCapGen++;
        st->jtCapRatio = ratio > 0.01 ? ratio : 0.01;
        st->jtCapHard = hard < 1.0 ? hard : 1.0;
    } else {
        st->jtCapHard = 0.0;
    }
}

/* The gate's per-row wake bound, evaluated on the EFFECTIVE drive shape (the
   tap/termination morph): the drive that could ring the low modes back to the
   floor within ~one mode-1 period (|p| ≈ π·Fd·phiD/wd1) — conservative.
   Re-run whenever the morph moves so a comb-free drive is metered on its own
   shape; at morph 0 it reads the tap table exactly. */
static void jt_gate_eps(bow_poly_state_t *st, double refDisp)
{
    const double w = st->jtDrvTerm;
    for (int s = 0; s < st->njt; s++) {
        const int mo = st->jtMOff[s];
        const double wd1 = st->jtWd[mo];
        double pdm = 0.0;
        for (int k = 0; k < st->jtM[s]; k++) {
            const double pd = st->jtPhiD[mo + k];
            const double t = fabs(w == 0.0 ? pd
                                  : pd + w * (st->jtPhiDT[mo + k] - pd));
            if (t > pdm) pdm = t;
        }
        st->jtGateFdEps[s] = pdm > 0.0
            ? refDisp * wd1 * wd1 / (M_PI * pdm)
            : 1e300;
    }
}

/* QUIESCENCE GATE: refDisp = floor DISPLACEMENT in meters (× wd1 per row).
   <= 0 disarms AND wakes every row (a stale asleep flag under a later
   re-arm would truncate a ringing row). jtGateRef is written last. */
void bow_poly_jt_set_gate(void *vst, double refDisp)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->jtGateFdEps) return;
    if (refDisp <= 0.0) {
        st->jtGateRef = 0.0;
        for (int s = 0; s < st->njt; s++) st->jtGateSlp[s] = 0;
        return;
    }
    const double dtj = (double)st->jtDiv / st->sr;
    const int hold = (int)(0.030 / dtj + 0.5);
    st->jtGateHold = hold < 1 ? 1 : hold;
    jt_gate_eps(st, refDisp);
    for (int s = 0; s < st->njt; s++) st->jtGateCnt[s] = st->jtGateHold;
    st->jtGateEvWake = st->jtEvTgt;   /* evolve wake reference = now */
    st->jtGateRef = refDisp;
}

/* gate probe: out = {asleep rows, total rows, max ring/floor ratio, max
   drive/eps ratio, drone-hot flag} since the last read (>1 names the
   condition blocking sleep). Racy telemetry reads, any thread. */
void bow_poly_jt_gate_probe(void *vst, double out[5])
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    out[0] = out[1] = out[2] = out[3] = out[4] = 0.0;
    if (!st || st->njt <= 0 || !st->jtGateSlp || st->jtGateRef <= 0.0)
        return;
    int n = 0;
    for (int s = 0; s < st->njt; s++) n += st->jtGateSlp[s];
    out[0] = (double)n;
    out[1] = (double)st->njt;
    out[2] = st->jtGateAmR;  st->jtGateAmR = 0.0;
    out[3] = st->jtGateFdR;  st->jtGateFdR = 0.0;
    out[4] = (double)st->jtGateDnHot;  st->jtGateDnHot = 0;
}

/* rows currently asleep under the quiescence gate (0 unarmed) —
   telemetry/tests; any thread. */
int bow_poly_jt_gate_asleep(void *vst)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->jtGateSlp || st->jtGateRef <= 0.0)
        return 0;
    int n = 0;
    for (int s = 0; s < st->njt; s++) n += st->jtGateSlp[s];
    return n;
}

/* SCOPE TELEMETRY arm: clears the meters and turns the per-row tick branch
   on; disarmed the tick is the exact unmetered path. Control-thread
   writes; the workers own the per-row state (telemetry-grade races). */
void bow_poly_scope_arm(void *vst, int on)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->scopeEnv) return;
    if (on && !st->scopeOn) {
        memset(st->scopeEnv, 0, sizeof(double) * (size_t)st->njt);
        memset(st->scopeMode, 0,
               sizeof(float) * (size_t)st->njt * (size_t)st->scopeK);
        memset(st->scopeCnt, 0, sizeof(unsigned) * (size_t)st->njt);
    }
    st->scopeOn = on ? 1 : 0;
}

/* Per-row scope read: f0 (Hz), level = radiated peak envelope in voice-bus
   units, asleep = gate flag, modes = first K |p_k| envelopes (row-major,
   zero-padded). Asleep rows read silent. Returns njt (0 = unarmed). */
int bow_poly_scope_jt(void *vst, int nrows, double *f0, double *level,
                      unsigned char *asleep, float *modes, int K)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0 || !st->scopeEnv || !st->scopeOn) return 0;
    double g = fabs(st->jtGain);
    if (st->jtGMulOn) g *= fabs(st->jtGMulCur);
    const int n = nrows < st->njt ? nrows : st->njt;
    const int SK = st->scopeK;
    for (int s = 0; s < n; s++) {
        const int mo = st->jtMOff[s];
        const int slp = (st->jtGateRef > 0.0 && st->jtGateSlp
                         && st->jtGateSlp[s]) ? 1 : 0;
        if (f0) {
            double f = st->jtWd[mo] / (2.0 * M_PI);
            if (s == st->jtTrkRow && st->jtTrkF0 > 0.0) f = st->jtTrkF0;
            f0[s] = f;
        }
        if (level) level[s] = slp ? 0.0 : st->scopeEnv[s] * g;
        if (asleep) asleep[s] = (unsigned char)slp;
        if (modes && K > 0) {
            const float *me = st->scopeMode + (size_t)s * (size_t)SK;
            for (int k = 0; k < K; k++)
                modes[(size_t)s * (size_t)K + k] =
                    (k < SK && !slp) ? me[k] : 0.0f;
        }
    }
    return st->njt;
}

/* Per played-string scope read: level = ring envelope (chunk peak of the
   bridge-side wave; 0 when inactive). Returns nb. */
int bow_poly_scope_slots(void *vst, double *level, int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || !st->strs) return 0;
    const int m = n < st->nb ? n : st->nb;
    for (int b = 0; b < m; b++) {
        const bow_pstring_t *S = &st->strs[b];
        level[b] = S->active ? S->senv : 0.0;
    }
    return st->nb;
}

/* LIVE PARAMETERS: replace the 52 scalars on a live state (same order
   and derivations as bow_poly_init); tables and all running state are left
   alone. Plain scalar writes. Order MUST stay in lockstep with init. */
void bow_poly_set_scalars(void *vst, const double *s, int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || !s || n < 47) return;
    st->yinf = s[0]; st->c0 = s[1]; st->dcRho = s[2];
    st->pgain = s[3]; st->pA = s[4]; st->bowW = s[5]; st->kret = s[6];
    st->retA = s[7]; st->retMode = s[8]; st->rb0 = s[9];
    st->ra1 = s[10]; st->ra2 = s[11]; st->kdisp = s[12];
    st->bowWidth = s[13]; st->bowCont = s[14];
    st->Z = s[15]; st->Zt = s[16];
    st->mu_s = s[17]; st->mu_d = s[18]; st->v0f = s[19];
    st->nutA = s[20]; st->brA = s[21];
    st->thLeak = s[22]; st->thA = s[23]; st->thD = s[24];
    st->thFloor = s[25];
    st->bowDisp = s[26]; st->zload = s[27];
    st->nA = s[28]; st->nT = s[29]; st->nPow = s[30];
    st->nzHi = s[31]; st->nzLo = s[32]; st->nDir = s[33];
    st->nzHiD = s[34];
    st->gutG = s[35]; st->dispN = s[36]; st->nailK = s[37];
    st->f0Open = s[38]; st->gutA2 = s[39];
    st->torsRatio = s[40]; st->torsG = s[41]; st->torsC = s[42];
    st->v0Pow = s[43]; st->v0Ref = s[44];
    st->hairHz = s[45]; st->hairRef = (s[46] > 1e-6 ? s[46] : 1.0);
    /* scalars 47-51: register damping, slide dulling, finger noise — absent =
       inert */
    st->lossReg = (n >= 48) ? s[47] : 0.0;
    st->slideRate = (n >= 49 && s[48] > 1.0) ? s[48] : 900.0;
    st->slideDull = (n >= 50) ? s[49] : 0.0;
    st->slideNoise = (n >= 51) ? s[50] : 0.0;
    st->slideAcc = (n >= 52 && s[51] > 1.0) ? s[51] : 25000.0;
}

/* Overwrite the BODY modal bank's coefficients on a live state; the
   resonator histories are untouched, so a body retune under a sounding
   note is click-free. Refuses (0) when the mode count differs. */
int bow_poly_set_body(void *vst, int K, const double *ba1, const double *ba2,
                const double *bn0, const double *bA, const double *bC)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || K != st->K || K < 0) return 0;
    if (K == 0) return 1;
    if (!ba1 || !ba2 || !bn0 || !bA || !bC) return 0;
    memcpy(st->ba1, ba1, sizeof(double) * (size_t)K);
    memcpy(st->ba2, ba2, sizeof(double) * (size_t)K);
    memcpy(st->bn0, bn0, sizeof(double) * (size_t)K);
    memcpy(st->bA,  bA,  sizeof(double) * (size_t)K);
    memcpy(st->bC,  bC,  sizeof(double) * (size_t)K);
    return 1;
}

/* Overwrite the MODAL-JAWARI tables in place; the modal STATE is kept (the
   web relaxing to the new wrap IS the correct transient). Refuses when the
   shape moved. Mirrors bow_poly_jt_load's conversions. */
int bow_poly_jt_set_coeffs(void *vst, int njt, int J, const int *M,
              const double *ca, const double *cb,
              const double *ca4, const double *cb4, const double *wd,
              const double *radScale, const double *pinScale,
              const double *cplScale,
              const double *phiD, const double *phiDT,
              const double *phiU, const double *phiF,
              const double *b, const double *G, const double *G4,
              const double *gd, const double *gd4, const double *phys)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || njt != st->njt || J != st->jtJ || njt <= 0) return 0;
    if (!M || !ca || !cb || !ca4 || !cb4 || !wd || !radScale || !pinScale
        || !cplScale
        || !phiD || !phiDT || !phiU || !phiF || !b || !G || !G4 || !gd || !gd4
        || !phys) return 0;
    int mtot = 0, ztot = 0;
    for (int s = 0; s < njt; s++) {
        if (M[s] != st->jtM[s]) return 0;      /* shape moved */
        mtot += M[s];
        ztot += M[s] * J;
    }
    for (int i = 0; i < mtot; i++) {
        st->jtCa[i] = ca[i];   st->jtCb[i] = cb[i];
        st->jtCa4[i] = ca4[i]; st->jtCb4[i] = cb4[i];
        st->jtWd[i] = wd[i];
        st->jtWdI[i] = 1.0 / wd[i];
        st->jtPhiD[i] = phiD[i];
        st->jtPhiDT[i] = phiDT[i];
    }
    for (int s = 0; s < njt; s++) {
        st->jtRadScale[s] = radScale[s];
        st->jtRadPinScale[s] = pinScale[s];
        st->jtCplScale[s] = cplScale[s];
    }
    for (int i = 0; i < ztot; i++) {
        st->jtPhiU[i] = (float)phiU[i];
        st->jtPhiF[i] = (float)phiF[i];
    }
    for (int i = 0; i < njt * J; i++) {
        st->jtB[i] = (float)b[i];
        st->jtGd[i] = (float)gd[i];
        st->jtGd4[i] = (float)gd4[i];
    }
    for (int i = 0; i < njt * J * J; i++) {
        st->jtG[i] = (float)G[i];
        st->jtG4[i] = (float)G4[i];
    }
    st->jtKc = phys[0]; st->jtAlpha = phys[1]; st->jtHcB = phys[2];
    st->jtDeep = phys[3]; st->jtGain = phys[4]; st->jtDrv = phys[5];
    /* (jtGainCur keeps gliding toward the new jtGain — no reset) */
    /* the reload rebuilt the follower row at its BUILD pitch — the next tick
       recomputes at the tracked pitch and re-trims G/gd */
    if (st->jtTrkRow >= 0) {
        st->jtTrkMUse = st->jtM[st->jtTrkRow];
        st->jtTrkApplied = 0.0;
        st->jtTrkDirty = 1;
        st->jtTrkTick = 1;
    }
    return 1;
}

/* TWO-WAY COUPLING FIFO: the post-pass emits ONE bridge-force sample (N)
   per output sample; the next render block pops them into F. Armed only —
   an unarmed web never touches the ring. */
static inline void jt_cpl_put(bow_poly_state_t *st, long long *w, double v)
{
    if (st->jtCplRing) st->jtCplRing[(*w)++ & (JT_WEBN - 1)] = v;
}

/* run one drive job to a web-signal buffer: schedule + pool (blocking is
   fine — this is the DISPATCHER thread) + hold walk. Same numerics as the
   sync post-pass. */
static void jt_run_job_locked(bow_poly_state_t *st, const double *drv,
                              const double *cv, int n,
                              double *web, double *webS)
{
    int nT = 0;
    double *fdv = st->jtFdv;
    double *evv = st->jtEvV;
    double *capv = st->jtCapV;
    int *tkv = st->jtTkv;
    for (int t = 0; t < n; t++) {
        double F = drv[t];
        st->jtFdc += 2e-4 * (F - st->jtFdc);
        st->jtFacc += F - st->jtFdc;
        if (++st->jtPhase >= st->jtDiv) {
            double Fd = st->jtFacc / st->jtDiv;
            st->jtFacc = 0.0; st->jtPhase = 0;
            fdv[nT] = st->jtFprev * st->jtDrv;
            evv[nT] = jt_ev_step(st);
            capv[nT] = jt_cap_ceiling(st, cv[t]);
            tkv[nT] = t;
            nT++;
            st->jtFprev = Fd;
        }
        if (F > st->jtFmax) st->jtFmax = F;
        if (-F > st->jtFmax) st->jtFmax = -F;
    }
    if (nT == 0) {
        long long cw = st->jtCplW;
        for (int t = 0; t < n; t++) {
            const double g = jt_gain_step(st);
            web[t] = g * jt_lp_step(st, st->jtHold);
            if (webS)
                webS[t] = g * jt_lp_stepS(st, st->jtHoldS);
            if (st->jtCplOn) jt_cpl_put(st, &cw, st->jtCplHold);
        }
        if (st->jtCplOn)
            __atomic_store_n(&st->jtCplW, cw, __ATOMIC_RELEASE);
        return;
    }
    const int nth = st->jtPoolN;
    if (nth >= 2) {
        double *hp = st->jtHp;
        double *hpS = webS ? st->jtHpS : NULL;
        double *hpC = (st->jtCplOn && st->jtHpC) ? st->jtHpC : NULL;
        for (int th = 0; th < nth; th++) {
            memset(hp + (size_t)th * JT_POOL_CH, 0,
                   sizeof(double) * (size_t)nT);
            if (hpS)
                memset(hpS + (size_t)th * JT_POOL_CH, 0,
                       sizeof(double) * (size_t)nT);
            if (hpC)
                memset(hpC + (size_t)th * JT_POOL_CH, 0,
                       sizeof(double) * (size_t)nT);
            st->jtWPen[th] = st->jtPenMax;
        }
        pthread_mutex_lock(&st->jtMx);
        st->jtWnT = nT;
        st->jtWPer = (st->njt + nth - 1) / nth;
        st->jtDone = 0;
        st->jtGen++;
        pthread_cond_broadcast(&st->jtCvW);
        while (st->jtDone < st->jtPoolN && !st->jtQuit)
            pthread_cond_wait(&st->jtCvD, &st->jtMx);
        pthread_mutex_unlock(&st->jtMx);
        for (int th = 0; th < nth; th++)
            if (st->jtWPen[th] > st->jtPenMax)
                st->jtPenMax = st->jtWPen[th];
        double hold = st->jtHold, holdS = st->jtHoldS;
        double holdC = st->jtCplHold;
        long long cw = st->jtCplW;
        int ki = 0;
        for (int t = 0; t < n; t++) {
            if (ki < nT && t == tkv[ki]) {
                double H = 0.0, HS = 0.0, HC = 0.0;
                for (int th = 0; th < nth; th++) {
                    H += hp[(size_t)th * JT_POOL_CH + ki];
                    if (hpS)
                        HS += hpS[(size_t)th * JT_POOL_CH + ki];
                    if (hpC)
                        HC += hpC[(size_t)th * JT_POOL_CH + ki];
                }
                hold = H;
                holdS = HS;
                if (hpC) holdC = HC;
                ki++;
            }
            const double g = jt_gain_step(st);
            web[t] = g * jt_lp_step(st, hold);
            if (webS)
                webS[t] = g * jt_lp_stepS(st, holdS);
            if (st->jtCplOn) jt_cpl_put(st, &cw, holdC);
        }
        st->jtHold = hold;
        st->jtHoldS = holdS;
        st->jtCplHold = holdC;
        if (st->jtCplOn)
            __atomic_store_n(&st->jtCplW, cw, __ATOMIC_RELEASE);
    } else {
        double hold = st->jtHold, holdS = st->jtHoldS;
        double holdC = st->jtCplHold;
        long long cw = st->jtCplW;
        int ki = 0;
        for (int t = 0; t < n; t++) {
            if (ki < nT && t == tkv[ki]) {
                double sacc = 0.0, cacc = 0.0;
                hold = jt_tick(st, fdv[ki], evv[ki], capv[ki],
                               webS ? &sacc : NULL,
                               st->jtCplOn ? &cacc : NULL);
                if (webS) holdS = sacc;
                if (st->jtCplOn) holdC = cacc;
                ki++;
            }
            const double g = jt_gain_step(st);
            web[t] = g * jt_lp_step(st, hold);
            if (webS)
                webS[t] = g * jt_lp_stepS(st, holdS);
            if (st->jtCplOn) jt_cpl_put(st, &cw, holdC);
        }
        st->jtHold = hold;
        st->jtHoldS = holdS;
        st->jtCplHold = holdC;
        if (st->jtCplOn)
            __atomic_store_n(&st->jtCplW, cw, __ATOMIC_RELEASE);
    }
}

/* One jt-web computer at a time (jtDispMx); the dispatcher always has
   jtPoolInit set */
static void jt_run_job(bow_poly_state_t *st, const double *drv,
                       const double *cv, int n,
                       double *web, double *webS)
{
    pthread_mutex_lock(&st->jtDispMx);
    jt_run_job_locked(st, drv, cv, n, web, webS);
    pthread_mutex_unlock(&st->jtDispMx);
}

static void *jt_dispatch_run(void *va)
{
    bow_poly_state_t *st = (bow_poly_state_t *)va;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    double webBuf[JT_ABLK];
    double webBufS[JT_ABLK];
    pthread_mutex_lock(&st->jtMx);
    for (;;) {
        while (!st->jtDQuit
               && __atomic_load_n(&st->jtDJobW, __ATOMIC_ACQUIRE)
                  == st->jtDJobR) {
            /* the callback's wake is opportunistic (trylock) — a 1 ms timed
               backstop bounds a missed signal */
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
        const int sOn = st->stOn && st->jtWebRingS && st->stJtPan;
        jt_run_job(st, st->jtDrvRing + (size_t)slot * JT_ABLK,
                   st->jtCapRing + (size_t)slot * JT_ABLK, n,
                   webBuf, sOn ? webBufS : NULL);
        long long w = st->jtWebW;
        for (int t = 0; t < n; t++) {
            st->jtWebRing[(w + t) & (JT_WEBN - 1)] = webBuf[t];
            if (sOn)
                st->jtWebRingS[(w + t) & (JT_WEBN - 1)] = webBufS[t];
        }
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
            pthread_mutex_init(&st->jtDispMx, NULL);
            pthread_cond_init(&st->jtCvW, NULL);
            pthread_cond_init(&st->jtCvD, NULL);
            st->jtPoolInit = 1;
        }
        if (!st->jtFdv) {
            /* the dispatcher uses the schedule scratch even without a worker
               pool */
            st->jtFdv = (double *)malloc(sizeof(double) * JT_POOL_CH);
            st->jtEvV = (double *)calloc(JT_POOL_CH, sizeof(double));
            st->jtCapV = (double *)calloc(JT_POOL_CH, sizeof(double));
            st->jtTkv = (int *)malloc(sizeof(int) * JT_POOL_CH);
        }
        if (!st->jtDrvRing) {
            st->jtDrvRing = (double *)malloc(sizeof(double)
                                             * JT_ARING * JT_ABLK);
            st->jtCapRing = (double *)calloc((size_t)JT_ARING * JT_ABLK,
                                             sizeof(double));
            st->jtWebRing = (double *)calloc(JT_WEBN, sizeof(double));
            st->jtWebRingS = (double *)calloc(JT_WEBN, sizeof(double));
        }
        st->jtDJobW = 0; st->jtDJobR = 0;
        st->jtWebW = 0; st->jtWebR = 0;
        st->jtOutHold = 0.0;
        st->jtOutHoldS = 0.0;
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

/* DRONE rows: control-thread setters — aligned 8-byte per-row stores read
   by the jt tick (a torn transition is inaudible). bow_poly_jt_pluck sets
   the decaying ONSET BOOST; no impulse anywhere. */
void bow_poly_jt_drone(void *vst, int s, double level)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || s < 0 || s >= st->njt || !st->jtDnTgt) return;
    st->jtDnTgt[s] = level > 0.0 ? level : 0.0;
}

void bow_poly_jt_pluck(void *vst, int s, double amp)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || s < 0 || s >= st->njt || !st->jtDnBoost) return;
    st->jtDnBoost[s] = amp > 0.0 ? amp : 0.0;
}

/* MELODY FOLLOWER: arm `row` (f0 = builder frequency, t60/fHf/bst = the
   builder's damping law). Engine build off the audio thread, or after
   set_coeffs — re-arming the SAME row keeps its pitch. row < 0 disarms. */
void bow_poly_jt_track_config(void *vst, int row, double f0, double t60,
                              double fHf, double bst)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (row < 0 || row >= st->njt) { st->jtTrkRow = -1; return; }
    st->jtTrkT60 = t60;
    st->jtTrkFhf = fHf;
    st->jtTrkBst = bst;
    st->jtTrkFx = 18000.0 < 0.42 * st->sr / st->jtDiv
        ? 18000.0 : 0.42 * st->sr / st->jtDiv;   /* the builder's fx */
    st->jtTrkIval = 128;                          /* ~1.3 ms at 96 k */
    const double dtj = (double)st->jtDiv / st->sr;
    st->jtTrkSlew = 1.0 - exp(-((double)st->jtTrkIval * dtj) / 0.015);
    st->jtTrkDirty = 1;
    if (st->jtTrkRow != row) {
        st->jtTrkRow = -1;        /* park while re-seeding (tick races) */
        st->jtTrkF0 = f0 > 20.0 ? f0 : 20.0;
        st->jtTrkApplied = 0.0;
        st->jtTrkTarget = st->jtTrkF0;
        st->jtTrkMUse = st->jtM[row];
        st->jtTrkTick = 1;
        st->jtTrkRow = row;
    }
}

/* The follower's pitch target (Hz) — plain aligned store, any thread; the tick
   slews to it */
void bow_poly_jt_track_target(void *vst, double hz)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->jtTrkRow < 0) return;
    if (hz > 0.0) st->jtTrkTarget = hz;
}

/* drone envelope times (seconds), engine build off the audio thread;
   non-positive values keep the load-time defaults */
void bow_poly_jt_drone_env(void *vst, double atkSec, double relSec,
                           double onsetDecaySec)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    double dtj = (double)st->jtDiv / st->sr;
    if (atkSec > 0.0) st->jtDnAAtk = 1.0 - exp(-dtj / atkSec);
    if (relSec > 0.0) st->jtDnA = 1.0 - exp(-dtj / relSec);
    if (onsetDecaySec > 0.0) st->jtDnBDec = exp(-dtj / onsetDecaySec);
}

/* drone drive tone (engine build, off the audio thread): lpHz/hpHz = noise
   band-pass corners, toneMix = pitched fraction 0..1 (sine at the row's
   mode-1 : noise). Non-positive lp/hp, negative toneMix = keep defaults. */
void bow_poly_jt_drone_tone(void *vst, double lpHz, double hpHz,
                            double toneMix)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    double dtj = (double)st->jtDiv / st->sr;
    if (lpHz > 0.0)
        st->jtDnALp = 1.0 - exp(-2.0 * 3.14159265358979 * lpHz * dtj);
    if (hpHz > 0.0)
        st->jtDnALp2 = 1.0 - exp(-2.0 * 3.14159265358979 * hpHz * dtj);
    if (toneMix >= 0.0)
        st->jtDnMix = toneMix > 1.0 ? 1.0 : toneMix;
}

void bow_poly_process2(void *vst, int n, int stride,
                       const double *f0, const double *vb, const double *fb,
                       const double *beta, const double *gate,
                       const double *xv, double *out, double *outS);

void bow_poly_process3(void *vst, int n, int stride,
                       const double *f0, const double *vb, const double *fb,
                       const double *beta, const double *gate,
                       const double *xv, double *out, double *outS,
                       double *outJt, double *outJtS);

/* Mono entry — the bit-exact parity path. */
void bow_poly_process(void *vst, int n, int stride,
                      const double *f0, const double *vb, const double *fb,
                      const double *beta, const double *gate,
                      const double *xv, double *out)
{
    bow_poly_process2(vst, n, stride, f0, vb, fb, beta, gate, xv,
                      out, NULL);
}

/* Stereo entry: outS = the SIDE stream (host: L = mid + side, R = mid -
   side). outS NULL or stereo never armed = the mono path, bit-exact. */
void bow_poly_process2(void *vst, int n, int stride,
                       const double *f0, const double *vb, const double *fb,
                       const double *beta, const double *gate,
                       const double *xv, double *out, double *outS)
{
    bow_poly_process3(vst, n, stride, f0, vb, fb, beta, gate, xv,
                      out, outS, NULL, NULL);
}

/* Split-bus entry: with outJt non-NULL the jt post-pass ADDS into
   outJt/outJtS (zeroed here); out[t] + outJt[t] reproduces the fused
   rounding bit-exactly. outJt NULL = the fused path. */
void bow_poly_process3(void *vst, int n, int stride,
                       const double *f0, const double *vb, const double *fb,
                       const double *beta, const double *gate,
                       const double *xv, double *out, double *outS,
                       double *outJt, double *outJtS)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    const int stOn = (outS != NULL) && st->stOn;
    if (outS && !stOn)
        memset(outS, 0, sizeof(double) * (size_t)n);
    /* jt bus destinations: the split buffers when armed, else fused */
    double *jo = out, *joS = outS;
    if (outJt) {
        memset(outJt, 0, sizeof(double) * (size_t)n);
        jo = outJt;
    }
    if (outJtS) {
        memset(outJtS, 0, sizeof(double) * (size_t)n);
        if (outJt) joS = outJtS;
    }
    const double *stSp = st->stSlotPan;
    const int K = st->K;
    const double *ba1 = st->ba1, *ba2 = st->ba2, *bn0 = st->bn0;
    const double *bA = st->bA, *bC = st->bC;
    const double yinf = st->yinf, c0 = st->c0, dcRho = st->dcRho;
    const double pgain = st->pgain, pA = st->pA, bowW = st->bowW;
    const double Z = st->Z, zload = st->zload;
    const double hpG = st->hpG;
    const int bowOn = bowW > 1e-9;

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
    double pkArr[64], rdmpArr[64], gkArr[64];
    for (int i = 0; i < nProc; i++) pkArr[i] = 0.0;

    /* ---- TWO-WAY BRIDGE COUPLING: pop the previous post-pass block's
       summed row bridge force. Arm/disarm on the target plus the resting
       slew, so a rested 0 never touches F or the FIFO. ---- */
    const double *cplRing = NULL;
    long long cplRR = 0;
    int cplTake = 0;
    if (st->jtCplG != 0.0 || st->jtCplCur != 0.0) {
        if (!st->jtCplOn) {
            /* fresh arm: start from the writer, never from a stale backlog */
            st->jtCplR = __atomic_load_n(&st->jtCplW, __ATOMIC_ACQUIRE);
            st->jtCplOut = 0.0;
            st->jtCplOn = 1;
        }
        if (st->jtCplRing) {
            long long ww = __atomic_load_n(&st->jtCplW, __ATOMIC_ACQUIRE);
            cplRR = st->jtCplR;
            long long avail = ww - cplRR;
            if (avail > JT_WEBN / 2) {      /* gross backlog: realign */
                cplRR = ww - n;
                avail = n;
            }
            if (avail < 0) avail = 0;
            cplTake = avail < (long long)n ? (int)avail : n;
            cplRing = st->jtCplRing;
        }
    } else if (st->jtCplOn) {
        st->jtCplOn = 0;
        st->jtCplCur = 0.0;
        st->jtCplOut = 0.0;
        st->jtCplHold = 0.0;
    }
    const int cplOn = st->jtCplOn;

    /* drive record for the deferred jt post-pass: async mode records into a
       dispatcher ring slot; sync mode uses the preallocated buffer or
       mallocs */
    double *jtFr = NULL;
    /* the cap's voice-envelope record rides beside the drive (state only) */
    double *jtCv = NULL;
    int jtAsyncBlk = 0;
    if (st->njt > 0 && st->jtGain != 0.0) {
        if (st->jtAsync && st->jtDLive && n <= JT_ABLK) {
            jtAsyncBlk = 1;
            int wj = st->jtDJobW;
            int rj = __atomic_load_n(&st->jtDJobR, __ATOMIC_ACQUIRE);
            if (wj - rj < JT_ARING) {
                jtFr = st->jtDrvRing
                    + (size_t)(wj & (JT_ARING - 1)) * JT_ABLK;
                jtCv = st->jtCapRing
                    + (size_t)(wj & (JT_ARING - 1)) * JT_ABLK;
            } else
                st->jtDropBlocks++;   /* overload: skip this block's drive (web
                                         decays briefly) */
        } else {
            jtFr = (st->jtFrBuf && n <= st->jtFrCap)
                ? st->jtFrBuf
                : (double *)malloc(sizeof(double) * (size_t)n);
            jtCv = (st->jtCapBuf && n <= st->jtFrCap)
                ? st->jtCapBuf
                : (double *)malloc(sizeof(double) * (size_t)n);
        }
    }

    for (int t = 0; t < n; t++) {
        double F = 0.0;
        double noiseDir = 0.0;
        /* stereo side accumulator — DIRECT radiation only (dead when !stOn) */
        double noiseDirS = 0.0;
        for (int i = 0; i < nProc; i++) {
            int b = st->proc[i];
            bow_pstring_t *S = &st->strs[b];
            size_t o = (size_t)b * stride + t;
            double nd0 = noiseDir;
            F += poly_string_force(st, S, f0[o], vb[o], fb[o], beta[o],
                                   gate[o], &noiseDir,
                                   &rdmpArr[i], &gkArr[i]);
            /* the bow-contact noise sounds AT the played string's position; its
               bridge force radiates from the one body and stays mid-only */
            if (stOn) noiseDirS += stSp[b] * (noiseDir - nd0);
            if (fabs(S->brLp) > pkArr[i]) pkArr[i] = fabs(S->brLp);
            /* the one-sample -Z*V bridge load (V == 0 for a rigid bridge) */
            if (bowOn && zload > 1e-9)
                F -= zload * bowW * Z * st->Vprev;
        }
        /* ---- additive voice force (shared path, zeros live) ---- */
        st->pLp = (1.0 - pA) * xv[t] + pA * st->pLp;
        F += pgain * st->pLp;
        /* ---- TWO-WAY COUPLING return: the rows' own bridge force joins F
           BEFORE the body solve (so it moves the bridge the played strings
           take back through kret) and before the drive record (so the rows
           feel each other through the bridge next tick). ---- */
        if (cplOn) {
            double c;
            if (t < cplTake) {
                c = cplRing[(cplRR + t) & (JT_WEBN - 1)];
            } else {
                /* FIFO dry (async behind, or the web not running): fade the
                   held force out rather than park a DC load on the bridge */
                c = st->jtCplOut * 0.9995;
            }
            st->jtCplOut = c;
            double gc = st->jtCplCur
                + st->jtCplA * (st->jtCplG - st->jtCplCur);
            if (st->jtCplG == 0.0 && gc < 1e-12 && gc > -1e-12) gc = 0.0;
            st->jtCplCur = gc;
            F += gc * c;
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
        if (bowOn) {
            for (int i = 0; i < nProc; i++) {
                bow_pstring_t *S = &st->strs[st->proc[i]];
                poly_string_return(st, S, V, rdmpArr[i], gkArr[i]);
            }
        }
        st->disp = 0.99967 * st->disp + V;
        st->Vprev = V;
        out[t] = rad + noiseDir;
        /* ---- INSTRUMENT WIDTH on the voice bus (the jt wash gets its own bank
           instance in the post-pass); antisymmetric side, byte-null unarmed
           ---- */
        double radS = 0.0;
        if (stOn && st->stWidthOn) {
            st->stWidthCur += st->stWidthSl
                * (st->stWidthTgt - st->stWidthCur);
            radS = st->stWidthCur * poly_width_bank(st, 0, out[t]);
        }
        /* ---- STEREO SIDE: the bow noise at its string + the width side ---- */
        if (stOn) outS[t] = radS + noiseDirS;
        /* ---- modal-jawari drive RECORD: the web is one-way, deferred to the
           post-pass ---- */
        if (jtFr) jtFr[t] = F;
        /* per-string cap side-chain: instant-attack voice-bus peak envelope,
           recorded per sample (out[t] is voice-only here) */
        if (jtCv) {
            const double e = peak_env(st->jtCapVEnv, fabs(out[t]),
                                      st->jtCapVRel);
            st->jtCapVEnv = e;
            jtCv[t] = e;
        }
    }
    if (cplOn) st->jtCplR = cplRR + cplTake;
    /* ring envelopes → next chunk's skip decision */
    for (int i = 0; i < nProc; i++) {
        bow_pstring_t *S = &st->strs[st->proc[i]];
        S->senv = pkArr[i];
        if (!(S->senv > 1e-10) && S->kGate <= 1e-9) S->active = 0;
    }
    /* ---- drive FX (the voice→taraf insert) runs on the render thread in both
       modes, before the async job is published. NULL hook = byte-null. ---- */
    /* ---- sitar→taraf inject before the drive-FX hook; a dropped block
       still advances the ring, a gross backlog realigns. Zero gain =
       byte-null ---- */
    if (st->sjRing) {
        long long ww = __atomic_load_n(&st->sjW, __ATOMIC_ACQUIRE);
        long long rr = st->sjR;
        if (ww - rr > 4 * JT_ABLK) rr = ww - n;   /* stale backlog */
        int avail = (int)(ww - rr);
        int take = avail < n ? avail : n;
        if (jtFr && st->sjGain != 0.0) {
            double g = st->sjGain;
            for (int t = 0; t < take; t++)
                jtFr[t] += g * st->sjRing[(rr + t) & (SJ_RINGN - 1)];
        }
        __atomic_store_n(&st->sjR, rr + take, __ATOMIC_RELEASE);
    }
    if (jtFr && st->fxDriveFn)
        st->fxDriveFn(st->fxDriveCtx, jtFr, n);
    /* ---- modal-jawari POST-PASS. ASYNC live: publish the job (no wait) and
       mix the FIFO's completed samples (flat-fill when the dispatcher is
       behind). SYNC: serial replay (bit-exact) or the caller-blocking pool. */
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
            jo[t] += g * v;
            st->jtOutHold = v;
            if (stOn) {
                double vs = st->jtWebRingS[(rr + t) & (JT_WEBN - 1)];
                joS[t] += g * vs;
                st->jtOutHoldS = vs;
                if (st->stWidthOn)
                    joS[t] += st->stWidthCur
                        * poly_width_bank(st, 1, g * v);
            }
        }
        for (int t = take; t < n; t++) {
            if (g < 1.0) { g += 3.0e-5; if (g > 1.0) g = 1.0; }
            jo[t] += g * st->jtOutHold;
            if (stOn) {
                joS[t] += g * st->jtOutHoldS;
                if (st->stWidthOn)
                    joS[t] += st->stWidthCur
                        * poly_width_bank(st, 1, g * st->jtOutHold);
            }
        }
        st->jtMixG = g;
        if (take < n)
            st->jtFlatSamples += (long long)(n - take);
        st->jtWebR = rr + take;
    } else if (jtFr) {
        /* Offline-pull fallback on THIS thread; jtDispMx excludes the
           dispatcher
           (taken only when a pool/dispatcher exists — the serial path never
           locks) */
        const int dispLock = st->jtPoolInit;
        if (dispLock)
            pthread_mutex_lock(&st->jtDispMx);
        if (st->jtPoolN < 2) {
            /* serial: interleaved by design, NOT jt_run_job_locked's serial
               branch — that one scans the whole job before it walks the
               output, so every jt_cap_ceiling would read jtGMulCur from
               before the block's jt_lp_step slews it. */
            long long cw = st->jtCplW;
            for (int t = 0; t < n; t++) {
                double F = jtFr[t];
                st->jtFdc += 2e-4 * (F - st->jtFdc);
                st->jtFacc += F - st->jtFdc;
                if (++st->jtPhase >= st->jtDiv) {
                    double Fd = st->jtFacc / st->jtDiv;
                    st->jtFacc = 0.0; st->jtPhase = 0;
                    double sacc = 0.0, cacc = 0.0;
                    const double cap = jt_cap_ceiling(st, jtCv[t]);
                    st->jtHold = jt_tick(st, st->jtFprev * st->jtDrv,
                                         jt_ev_step(st), cap,
                                         stOn ? &sacc : NULL,
                                         st->jtCplOn ? &cacc : NULL);
                    if (stOn) st->jtHoldS = sacc;
                    if (st->jtCplOn) st->jtCplHold = cacc;
                    st->jtFprev = Fd;
                }
                if (st->jtCplOn) jt_cpl_put(st, &cw, st->jtCplHold);
                const double g = jt_gain_step(st);
                double jv = g * jt_lp_step(st, st->jtHold);
                jo[t] += jv;
                if (stOn) {
                    joS[t] += g * jt_lp_stepS(st, st->jtHoldS);
                    if (st->stWidthOn)
                        joS[t] += st->stWidthCur
                            * poly_width_bank(st, 1, jv);
                }
                if (F > st->jtFmax) st->jtFmax = F;
                if (-F > st->jtFmax) st->jtFmax = -F;
            }
            if (st->jtCplOn)
                __atomic_store_n(&st->jtCplW, cw, __ATOMIC_RELEASE);
        } else {
            /* pooled: the dispatcher's own job runner, one JT_POOL_CH chunk
               at a time into the web scratch, then the shared output walk */
            double *web = st->jtWebScr;
            double *webS = stOn ? st->jtWebScrS : NULL;
            for (int c0 = 0; c0 < n; c0 += JT_POOL_CH) {
                const int cn = n - c0 < JT_POOL_CH ? n - c0
                                                   : JT_POOL_CH;
                jt_run_job_locked(st, jtFr + c0, jtCv + c0, cn, web, webS);
                for (int t = 0; t < cn; t++) {
                    const double jv = web[t];
                    jo[c0 + t] += jv;
                    if (stOn) {
                        joS[c0 + t] += webS[t];
                        if (st->stWidthOn)
                            joS[c0 + t] += st->stWidthCur
                                * poly_width_bank(st, 1, jv);
                    }
                }
            }
        }
        if (dispLock)
            pthread_mutex_unlock(&st->jtDispMx);
        if (jtFr != st->jtFrBuf)
            free(jtFr);
        if (jtCv != st->jtCapBuf)
            free(jtCv);
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
        bow_poly_jt_set_async(vst, 0);   /* dispatcher first: it may be waiting
                                            on the pool */
        jt_pool_stop(st);
        if (st->jtPoolInit) {
            pthread_mutex_destroy(&st->jtMx);
            pthread_mutex_destroy(&st->jtDispMx);
            pthread_cond_destroy(&st->jtCvW);
            pthread_cond_destroy(&st->jtCvD);
        }
        free(st->jtFrBuf); free(st->jtFdv); free(st->jtTkv);
        free(st->jtEvV);
        free(st->jtHp); free(st->jtHpS); free(st->jtHpC);
        free(st->jtWebScr); free(st->jtWebScrS);
        free(st->sjRing);
        free(st->jtDrvRing); free(st->jtWebRing);
        free(st->jtWebRingS);
        free(st->jtM); free(st->jtMOff); free(st->jtZOff);
        free(st->jtCa); free(st->jtCb); free(st->jtCa4); free(st->jtCb4);
        free(st->jtWd); free(st->jtWdI);
        free(st->jtPhiD); free(st->jtPhiDT); free(st->jtDrvTermCur);
        free(st->jtPhiU); free(st->jtPhiF); free(st->jtB);
        free(st->jtG); free(st->jtG4); free(st->jtGd); free(st->jtGd4);
        free(st->jtQ); free(st->jtP);
        free(st->jtDnTgt); free(st->jtDnEnv); free(st->jtDnBoost);
        free(st->jtDnLp); free(st->jtDnLp2); free(st->jtDnRng);
        free(st->jtDnPh);
        free(st->jtCapEnv); free(st->jtCapGain); free(st->jtCapRowGen);
        free(st->jtCapV); free(st->jtCapBuf); free(st->jtCapRing);
        free(st->scopeEnv); free(st->scopeMode); free(st->scopeCnt);
        free(st->jtRadScale); free(st->jtRadScaleCur); free(st->jtRadLp);
        free(st->jtRadPinScale); free(st->jtRadPinScaleCur);
        free(st->jtCplScale); free(st->jtCplRing);
        free(st->jtRadPrime);
        free(st->jtGateFdEps); free(st->jtGateCnt); free(st->jtGateSlp);
        free(st->jtDwTgt); free(st->jtDwCur);
        free(st->jtEvOfsTgt); free(st->jtEvOfsCur);
        free(st->jtRowAlpha); free(st->jtRowHcB); free(st->jtRowDeep);
    }
    free(st->ba1); free(st->ba2); free(st->bn0); free(st->bA); free(st->bC);
    free(st->stSlotPan); free(st->stJtPan);
    free(st->strs); free(st->proc);
    free(st);
}
