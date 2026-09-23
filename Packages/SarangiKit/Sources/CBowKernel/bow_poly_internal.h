/* PRIVATE to the String kernel's two translation units: the state, the
   sizes, and the per-sample inlines the render loop and the taraf share
   (they must inline in both files — no cross-file call on the hot path).
   The public ABI is bow_kernel.h. */
#ifndef BOW_POLY_INTERNAL_H
#define BOW_POLY_INTERNAL_H

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

#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif
#include "bow_kernel.h"   /* bow_scalars_t + the public prototypes */
#include "kernel_common.h"
#include "bow_contact.h"

#define MAXBOW 4096
/* async jt ring sizes (also the two-way-coupling FIFO's) */
#define JT_ABLK 4096
#define JT_ARING 8
#define JT_WEBN 32768

/* n is a power of two (MAXBOW or 64): the wrap is a mask. */
static double pfrac_read(const double *buf, int n, int w, double delay) {
    double rp = (double)w - delay;
    while (rp < 0) rp += n;
    int i0 = (int)rp;
    double fr = rp - i0;
    const int m = n - 1;
    return buf[i0 & m] * (1.0 - fr) + buf[(i0 + 1) & m] * fr;
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
    /* REGIME TELEMETRY (cumulative, host diffs): nut-side contact slip
       onsets, samples in slip, bowed samples, and periods elapsed
       (Σ f0/sr). Helmholtz = one slip per period. Plain counters — the
       render is byte-identical with or without a reader. */
    double rgPeriods;
    unsigned long long rgSlips, rgSlipSmp, rgSmp;
    int rgSlipping;
    /* FUNDAMENTAL CAPTURE: four Q=3 band-passes tracking f0, 2f0, 3f0 and
       4f0 on the bridge-side wave, with 4-period leaky powers rgP[0..3]
       and the whole wave's rgPtot. rgP[0]/rgPtot is the fundamental SHARE;
       rgP[0]/max(rgP[1..3]) the fundamental DOMINANCE — Helmholtz motion
       keeps H1 the strongest low partial at any force, an overtone regime
       (the string locked on H3/H4) drops it 10–30 dB under one of them.
       Telemetry only. */
    double rgIc1[4], rgIc2[4], rgP[4], rgPtot;
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
    /* --- derived per-sample constants (poly_load_scalars; sr-bound) --- */
    double nutFc0;                       /* nail-law corner at the open string */
    double kgAtk, kgRel;                 /* key-gate 3 ms attack / 8 ms release */
    double slCD, slAtk, slRel;           /* slide tracker: 10 ms smoother, env */
    double slAAtk, slARel;               /* slide-noise env attack / release */
    double thLeakPow[3];                 /* thLeak^{0.92, 1, 1.09} per hair group */
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
    _Atomic double *jtOutputLevelTgt;
    double *jtOutputLevelCur;       /* worker-owned, 40 ms bank level slew */
    _Atomic double *jtProfileTgt;    /* control writers, relaxed atomic loads */
    double *jtProfileCur;           /* worker-owned, 250 ms gain slew */
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
    double *jtCplScale;               /* per-row blocked-sum -> newtons */
    /* per-row LAST returned load, and what a SLEEPING row keeps returning.
       The gate freezes a row's physics, so a bare `return 0` STEPS the
       returned force to 0, and a step on the shared bridge strums the
       played strings and every other row. (That is NOT what made the first
       cut of the knob ring forever — the un-DC-blocked pickup was, and
       blocking it alone restores full silence — but the step is real, the
       row is still carrying its contact micro limit-cycle when it sleeps,
       and continuity here costs one multiply.) A sleeping row returns its
       last value decaying on the DC blocker's own rate (jtRadA), which is
       what the blocker would have done to a frozen force anyway.
       Worker-owned; only ever touched when coupling is armed (byte-null
       otherwise). */
    double *jtCplLast;
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
    /* Optional row-local evolution gesture. One atomic mailbox per row;
       the row worker owns every envelope sample, including retriggers. */
    void **jtDual; /* indexed by bank row; NULL entries use the legacy solver */
    int jtDualCount;
    int jtDualReady;
    int jtDualPending;
    _Atomic uint64_t *jtPulseRequest;
    double *jtPulseEnv, *jtPulseLift, *jtPulseDecay, *jtPulseAttack;
    int *jtPulseLeft;
    _Atomic uint64_t *jtBurstRequest;
    double *jtBurstEnv, *jtBurstDecay, *jtBurstPhase;
    int *jtBurstLeft;
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
    /* LIVE BRIDGE DRIVE (`bow_jt_drive`): jtDrv glides toward jtDrvTgt once
       per jt tick (~40 ms) when armed; unarmed it is the build's phys[5]. */
    int jtDrvOn;
    double jtDrvA, jtDrvTgt;
    /* the build's drive (phys[5]): the level reference. dn = jtDrv/jtDrvRef
       scales what enters every row and 1/dn what leaves it, so the knob
       moves the graze operating point at constant loudness. */
    double jtDrvRef;
    /* LEVEL COMPENSATION on the row output: (ref/act)^(exp/2), exp 0 = the
       raw physics, 1 = constant loudness. ref/act are two power trackers
       with the web's own decay, fed by the raw and the drive-scaled input,
       so the ratio is the drive AVERAGED OVER THE ENERGY THE WEB HOLDS: a
       sweep during ring-out changes nothing until new energy arrives, and a
       fresh note after a sweep lands on its own compensation at once. */
    double jtDrvExp, jtDrvCmpA, jtDrvEref, jtDrvEact;
    double *jtDnV, *jtCmV;            /* per-tick dn / comp scratch (pool) */
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
    int *jtOrder;                    /* immutable task order while workers run */
    atomic_int jtNextRow;            /* one worker owns each row for a job */
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

#define JT_MAXM 72
#define JT_MAXJ 44
/* ---- persistent jt worker pool ---- */
/* ---- sitar→taraf inject ---- */
#define SJ_RINGN 32768

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

/* the slewed jt output gain, stepped ONCE per kernel output sample (call
   once per sample and reuse for the side stream) */
static inline double jt_gain_step(bow_poly_state_t *st)
{
    st->jtGainCur += st->jtGainA * (st->jtGain - st->jtGainCur);
    return st->jtGainCur;
}

/* one jt-tick step of the live bridge-drive scalar: the multiplier on the
   played strings' bridge force into every row. Unarmed = the build value
   untouched; armed at the same value = cur + a·0, bit-identical. */
static inline double jt_drive_step(bow_poly_state_t *st)
{
    if (st->jtDrvOn) st->jtDrv += st->jtDrvA * (st->jtDrvTgt - st->jtDrv);
    return st->jtDrv;
}

/* the tick's normalized drive d/ref: exactly 1.0 at the build value (x/x),
   so every ×dn and ×1/dn in the tick is bit-exact at rest */
static inline double jt_drive_norm(const bow_poly_state_t *st, double d)
{
    return st->jtDrvRef > 0.0 ? d / st->jtDrvRef : 1.0;
}

/* one tick of the drive's level compensation (see jtDrvExp). Fraw = this
   tick's UNSCALED bridge force; the drone envelopes (which enter the rows
   ×dn) count as input power beside it. Both trackers see the same history,
   so with nothing arriving they decay together and the ratio holds; in
   silence the floor term makes it dn^-2 exactly, the steady-state answer.
   dn == 1.0 keeps the two trackers bit-identical (×1.0 is exact) — the
   resting instrument returns 1.0 without a pow. */
static inline double jt_drive_comp_step(bow_poly_state_t *st, double dn,
                                        double Fraw)
{
    double p = Fraw * Fraw;
    for (int s = 0; s < st->njt; s++) {
        const double e = st->jtDnEnv[s];
        p += e * e;
    }
    const double dn2 = dn * dn;
    const double a = st->jtDrvCmpA;
    st->jtDrvEref += a * (p - st->jtDrvEref);
    st->jtDrvEact += a * (dn2 * p - st->jtDrvEact);
    if (dn == 1.0 && st->jtDrvEact == st->jtDrvEref) return 1.0;
    const double eps = 1e-30;
    const double ratio = (st->jtDrvEref + eps) / (st->jtDrvEact + eps * dn2);
    return pow(ratio, 0.5 * st->jtDrvExp);
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

/* TWO-WAY COUPLING FIFO: the post-pass emits ONE bridge-force sample (N)
   per output sample; the next render block pops them into F. Armed only —
   an unarmed web never touches the ring. */
static inline void jt_cpl_put(bow_poly_state_t *st, long long *w, double v)
{
    if (st->jtCplRing) st->jtCplRing[(*w)++ & (JT_WEBN - 1)] = v;
}

#define JT_POOL_CH 65536

/* bow_jt.c — the modal-jawari taraf: the load ABI, the row ticks, the
   worker pool, the deferred post-pass and every bow_poly_jt_* setter. */
double jt_tick(bow_poly_state_t *st, double Fd, double ev,
                      double cap, double dn, double comp,
                      double *sideOut, double *cplOut);
void jt_run_job(bow_poly_state_t *st, const double *drv,
                       const double *cv, int n,
                       double *web, double *webS);
void jt_pool_stop(bow_poly_state_t *st);
void jt_gate_eps(bow_poly_state_t *st, double refDisp);
void jt_track_retune(bow_poly_state_t *st);
double jt_dual_tick(bow_poly_state_t *st,int row,double drive,double *returned);
void jt_dual_free(void *dual);
double jt_dual_cost(void *dual);

void jt_run_job_locked(bow_poly_state_t *st, const double *drv,
                              const double *cv, int n,
                              double *web, double *webS);

void jt_run_job_locked(bow_poly_state_t *st, const double *drv,
                              const double *cv, int n,
                              double *web, double *webS);

#endif
