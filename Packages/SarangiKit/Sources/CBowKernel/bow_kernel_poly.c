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
    /* Tarabdaar SITAR TWANG (2026-08-01): fast-attack / slow-release
       PER-SIDE peak envelopes of the bridge-reflected wave — the
       self-adjusting graze knee references (see poly_string_return).
       Two sides because a bowed loop settles its Helmholtz wrap on
       either polarity and slides AWAY from a one-sided fold (measured:
       the lobe flipped -0.44 → +0.43 when the fold changed sides); a
       graze that rides each side's own envelope leaves no escape
       configuration. twD is the smoothed rolling-contact length
       shortening (samples) — the conservative wrap (see
       poly_string_return) — and twDb its slow (~80 ms) mean: the read
       applies twD - twDb, so the PM keeps its cascade (AC) while the
       mean shortening (DC ≈ +7…18 cents sharp at useful wrap depths)
       cancels; the tracker's onset lag leaves a brief natural
       sharpening, like a real pluck settling onto the bone. State only
       while the twang is disarmed. */
    double twEnvP, twEnvN, twD, twDb;
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
    /* Tarabdaar TILT purity: runtime web-jawari BUZZ scale (multiplies
       the buzz sources jn/jw; the jl LOSS stays full — see mono). */
    double jawG;
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
    /* Tarabdaar jt tone LP (2026-07-23): one-pole on the radiated jt sum,
       armed by bow_poly_jt_set_lp (NOT part of the load ABI — python-
       parity twins never arm it). jtLpA <= 0 = bypass, bit-exact. */
    double jtLpA, jtLpY;
    /* Tarabdaar jt tone HP (2026-07-26): one-pole high-pass on the
       radiated jt sum, after the LP — the jawari-formant voicing
       (quiet fundamental under the high cluster). Same contract as
       jtLpA: setter outside the load ABI, <= 0 = bypass, byte-exact. */
    double jtHpA, jtHpY;
    /* Tarabdaar TILT axes (2026-07-23 evening, mono lockstep): runtime
       taraf purity + decay — control-thread-written scalars read by
       the jt tick. jtLift = bone drop (0 = byte-exact contact;
       jtLiftRef = load-time max static penetration, the setter's
       unit). jtDampMul = per-tick momentum multiplier (0/>= 1 = off). */
    double jtLift, jtLiftRef, jtDampMul;
    /* Tarabdaar CHARGE GOVERNOR (2026-08-15, bow_jt_gov): per-row AGC
       on the bridge drive into the jt strings. The long-t60 anchor
       rows (Sa/Pa, 7-9 s) otherwise accumulate a whole phrase — up to
       +12 dB of taraf ring on the next kin note, a several-dB
       re-excitation phase lottery, and at high expression the ring
       crosses the contact knee into the loud-buzz regime (measured,
       TarafVarianceBench). Each row tracks a peak envelope of its
       contact-zone velocity (jtGovEnv, ~60 ms release); rows whose
       ring already exceeds the graze target jtGovRef·wd1 (jtGovRef =
       target zone DISPLACEMENT in meters, ×mode-1 rate = velocity
       bound) shed incoming bridge drive by ref/env scaled by
       jtGovAmt — the ring saturates at its single-strike level
       instead of piling up. Held-drone noise drive adds AFTER the
       shed (never ducked). Control-thread scalars + per-row state
       under the worker partition; jtGovAmt 0 = byte-null. */
    double jtGovAmt, jtGovRef, jtGovRel;
    double *jtGovEnv;
    /* Tarabdaar QUIESCENCE GATE (2026-08-17, bow_jt_gate): the idle-CPU
       gate. The jt web is a constant-cost simulation — every row ticks
       its whole mode stack whether ringing or silent, so the app burns
       the full web cost at rest. Armed (jtGateRef > 0 = floor
       DISPLACEMENT in meters, apex-scale like jtGovRef): a row whose
       peak LOW-MODE momentum stays below jtGateRef·wd1 for
       jtGateHold consecutive jt ticks with no bridge drive above its
       wake bound and no drone drive goes to sleep IN PLACE — state
       FROZEN, never zeroed (jtQ holds the settled static wrap against
       the bone; zeroing would strum the re-settle on wake) — and skips
       the whole modal tick, radiating exact 0. Low modes are the
       meter because the wrap sustains a HIGH-mode tick-rate micro
       limit-cycle that never rests (zone velocity ~0.6 and per-row
       radiated peak ~5e-3 sit at CONSTANT baselines at rest, while
       the first modes rest 3+ decades below ring scale). Any drive
       above jtGateFdEps (the force that could ring the low modes back
       to the floor within ~one mode-1 period) or any drone drive
       wakes it.
       Sleeping through an evolve/lift glide would land the bone
       stepped, so the evolve setter wakes everyone. Per-row state is
       worker-owned (a row belongs to one worker); the scalars are
       control-thread writes (drone-setter contract). 0 = byte-null. */
    double jtGateRef;         /* floor displacement (m); 0 = off */
    int jtGateHold;           /* consecutive quiet jt ticks to sleep */
    double *jtGateFdEps;      /* per-row bridge-drive wake bound */
    int *jtGateCnt;           /* per-row quiet-run countdown */
    unsigned char *jtGateSlp; /* per-row asleep flag */
    /* gate PROBE telemetry (plain racy writes, read+reset by
       bow_poly_jt_gate_probe): max am/floor and |FdIn|/eps ratios seen
       on AWAKE rows since the last read (>1 = that condition is what
       blocks sleep), plus a drone-active flag. */
    double jtGateAmR, jtGateFdR;
    int jtGateDnHot;
    double jtGateEvWake;      /* evolve target the sleepers were last
                                 woken under — the set_evolve wake is
                                 CHANGE-gated against this (dead-band
                                 2% of jtDeep = 5% of apex): a tilt
                                 binding re-pushing a constant (or
                                 sensor-jittering) evolve at sensor
                                 rate must not hold the web awake
                                 (measured 2026-08-17: a Joy-Con
                                 stick-Y → bow_jt_evolve binding kept
                                 all rows permanently awake at idle) */
    /* Tarabdaar HARMONIC-EVOLUTION lift (2026-07-26): a SIGNED bone
       offset (meters; + = bone dropped, graze margin shrinks and the
       upward cascade opens; − = raised, pressed past the knee, no
       twang), slewed toward jtEvTgt once per divided jt sample
       (jtEvA, ~40 ms) so the bone glides instead of stepping — the
       click-free live form of `bow_jt_evolve`. The effective deep-
       substep threshold moves with it (jtDeep − 2.5·ev), mirroring
       what building at the shifted apex would have produced. jtEvV
       carries the per-sample slewed values into the worker pool
       (fill-time advance == serial advance, so pool replay stays
       bit-exact). All-zero = byte-null. */
    double jtEvTgt, jtEvCur, jtEvA;
    double *jtEvV;
    /* ---- Tarabdaar RECRUITMENT weights (2026-07-26): per-row scale on
       the bridge drive into each row — the taraf-selectivity axis.
       Targets are control-thread-written (bow_poly_jt_drive_weights);
       the jt tick slews jtDwCur toward jtDwTgt (~30 ms) and multiplies
       the row's incoming bridge force. Per-row state under the worker
       partition (a row belongs to one worker). jtDwOn stays 0 until
       the setter first runs — byte-null by construction. */
    int jtDwOn;
    double jtDwA;                 /* slew coeff (jt tick rate) */
    double *jtDwTgt, *jtDwCur;    /* per-row weight target / current */
    /* RECRUITMENT lush half: radiated-gain multiplier on the jt web's
       output (slewed in jt_lp_step at the kernel rate). Drive weights
       above 1 saturate against the contact (the graze drains harder as
       it is pushed — measured ×2 drive = +8% ring), so the "how loud
       is the chorus" lever is output level, which nothing drains. */
    int jtGMulOn;
    double jtGMulA, jtGMulTgt, jtGMulCur;
    /* ---- Tarabdaar jt BODY radiation (2026-08-01): blend the radiated
       jt sum through the SAME formula-body radiation bank the played
       strings radiate through (shared ba1/ba2/bn0/bC/c0 coefficients,
       OWN filter state) — the taraf rings from the instrument's body
       instead of beside it. Mix target is a control-thread scalar
       write (the drone-setter contract), slewed ~30 ms in jt_lp_step;
       jtBodyOn stays 0 until the setter first runs — byte-null by
       construction. A live bow_poly_set_body re-points both the voice
       and this twin (same read of the same arrays). */
    int jtBodyOn;
    double jtBodyA, jtBodyTgt, jtBodyCur;
    double jbx1[96], jbx2[96], jby1[96], jby2[96];      /* mid twin */
    double jbsx1[96], jbsx2[96], jbsy1[96], jbsy2[96];  /* side twin */
    double *jtQ, *jtP;            /* modal state, concat modes */
    double jtFprev, jtFmax, jtPenMax;   /* + telemetry */
    double jtFdc;                 /* drive DC tracker (~50 ms) */
    /* ---- jt DRONE rows (2026-07-23): press-to-sound taraf ----
       per-row control-thread-written scalars read by the jt tick:
       a pending pluck (one-shot momentum kick via phiD) and a
       sustained filtered-noise drive target, slewed (~20 ms) so
       press/release never click.  All-zero is BYTE-NULL (the tick
       guards the whole branch — goldens untouched). */
    double *jtDnTgt, *jtDnEnv, *jtDnBoost, *jtDnLp, *jtDnLp2;
    unsigned long long *jtDnRng;
    /* pitched drone drive (mellow-drone rev 2026-07-26): per-row sine
       at the row's own mode-1 frequency, mixed jtDnMix sine : (1-mix)
       band-passed noise. A sympathetic string in the real instrument
       is handed a PITCHED bridge force — broadband noise rings the
       row's high modes far above their played-note balance (measured
       H4 ≈ H1 vs the played tap's H4 −29 dB). */
    double *jtDnPh;
    double jtDnMix;
    /* ---- Tarabdaar MELODY-FOLLOWER row (2026-07-25): one jt row live-
       retunes to the played pitch. The host writes jtTrkTarget (Hz —
       plain scalar store, the drone-setter contract); the row's own jt
       tick slews jtTrkF0 toward it every jtTrkIval ticks and recomputes
       ONLY the f0-dependent per-mode tables (ca/cb/ca4/cb4/wd) from the
       stored damping/inharmonicity law — mode shapes, bone profile and
       output taps stay fixed (retune-by-tension: the string's length
       never moves). The active mode count jtTrkMUse = fx/f0 is trimmed
       live so no mode above the builder's fx corner ever enters the
       contact solve (under-resolved modes limit-cycle against the bones
       — the dynamic-taraf-era scratching), and the contact compliance
       G/gd is re-prefix-summed from phiU/phiF when it changes.
       jtTrkRow -1 (the default) = the whole feature is byte-null. */
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
    double jtDnALp, jtDnALp2;     /* noise band-pass coeffs (default
                                     ~25 Hz–1.6 kHz; bow_poly_jt_drone_tone):
                                     sub-audio drive would wander the string
                                     against the jawari bone and pump the
                                     buzz (audible slow tremolo) */
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
    /* ---- TARABDAAR STEREO SIDE OUTPUT (2026-07-23) ----
       A physically-derived SIDE stream carrying only the DIRECT
       radiation — the sources that genuinely occupy distinct places on
       the instrument: the taraf strings' direct tap (tdir), the
       modal-jawari rows' own radiation (the wash — they sit on their
       own bridge), and the bow-contact noise (at the played string's
       position). Everything that reaches the listener VIA THE BRIDGE
       (played-string force, driven web resonance) radiates from the
       ONE body — a fixed central radiator — and stays mid-only, so
       the image is a spread halo around a centred voice and never
       leans with the melody. The tdir side sum runs its own copy of
       the tdir shaping bank (linearity: equals radiating each string
       panned). MID is untouched; L = mid + side, R = mid - side at
       the host — the L+R fold-down is bit-identical to the legacy
       mono output. Armed by bow_poly_set_stereo (call AFTER
       bow_poly_jt_load); never arming it, or passing outS = NULL, is
       the exact legacy path — every golden untouched. */
    int stOn;
    double *stWebPan;                 /* nv: taraf web pans */
    double *stSlotPan;                /* nb: played-string (noise) pans */
    double *stJtPan;                  /* njt: modal-jawari row pans */
    double tsx1[96], tsx2[96], tsy1[96], tsy2[96];   /* side tdir bank */
    double jtLpYS;                    /* side twin of the jt tone LP */
    double jtHpYS;                    /* side twin of the jt tone HP */
    double jtHoldS, jtOutHoldS;       /* side jt hold walk / async hold */
    double *jtHpS;                    /* pool partial sums, side */
    double *jtWebRingS;               /* async web FIFO, side */
    /* ---- TARABDAAR INSTRUMENT WIDTH (2026-08-01 unifying rev): ONE
       small instrument, TWO observation points — the whole stereo law
       in one mechanism. Identical at low frequency (monopole
       radiation), diffusely decorrelated at high frequency: above the
       Schroeder crossover a real body's radiation is a dense
       overlapping mode field where two listening positions see random
       independent mode shapes. The fitted mid has no resolved
       structure up there (its 9 signature modes all land 55–250 Hz;
       the upper spectrum ships as flat c0·F feedthrough), so the
       observation-point DIFFERENCE is modelled the way the mid models
       the diffuse region itself (the bow_body_tail idiom): a dense
       random-sign side-only modal bank. Static, passive, linear — a
       difference transfer, not a pan/Haas/detune trick, so the image
       never leans and the L+R fold-down cancels it exactly.
       The bank runs once per BUS — [0] voice (pre-jt mid), [1] the jt
       wash — with SHARED coefficients and per-bus state. Linearity:
       bank(voice) + bank(jt) = bank(voice + jt), so the split FX
       buses keep their own valid side streams while the fused sum
       equals the one-instrument model. (A per-mode residue readout of
       the body bank itself — the first 2026-08-01 attempt — was
       measured inaudible on this fit and deleted the same day; see
       docs/sarangi.md.) Armed by bow_poly_set_stereo_width; 0 from a
       cold start / never armed = byte-null, every golden safe. */
    int stWidthOn;
    double stWidthTgt, stWidthCur;    /* slewed width scalar */
    double stWidthSl;                 /* ~30 ms one-pole slew coeff */
    /* ---- TARABDAAR SITAR TWANG (2026-08-01): a grazing jawari fold on
       the PLAYED string's bridge termination (poly_string_return) — the
       sitar's flat-bridge contact on the melody string itself, distinct
       from the jt taraf's bones. One-sided collision fold (the web
       combs' v3 idiom) whose knee RIDES the string's own peak envelope
       (twKneeR × per-string twEnv): the graze engages at the same
       relative depth at ANY strike level — the bow_jt_evolve lesson
       (the cascade lives in a narrow band around the knee, which is why
       a fixed knee twangs inconsistently) applied to the played string.
       The upward energy cascade accumulates over string round trips
       (~30-80 trips ≈ 100-300 ms — the sitar sample's measured bloom
       time), the one-sided fold makes the even-harmonic asymmetry, and
       the release-lagged envelope + the bridge LP let the centroid fall
       back. Passive by construction (amt·depth ≤ 1 removes energy).
       Armed by bow_poly_set_twang; 0 from a cold start / never calling
       is byte-null (twOn-gated, and it self-disarms once the slewed
       amount dies). */
    int twOn;
    double twTgt, twCur;              /* slewed 0..1 amount */
    double twSl;                      /* ~30 ms per-sample slew coeff */
    double twKneeR;                   /* knee as fraction of the side env */
    double twDepth;                   /* contact-loss fold depth at amt 1 */
    double twRel;                     /* side-env per-sample release mul */
    double twRollSmp;                 /* wrap length shortening at amt 1 */
    double twAv;                      /* twD smoothing coeff (~0.5 ms) */
    double twDcA;                     /* twDb mean-tracker coeff (~80 ms) */
    /* the sitar-morph half of the axis: the wrap alone cascades into a
       string whose terminations reabsorb HF within tens of ms (gut over
       a leather-topped bridge, finger-release damping) — the sample's
       bloom band SUSTAINS because a sitar is steel over hard bone with
       a fret-wire stop. amount therefore also brightens the
       terminations (pow exponent on the one-pole coeffs) and eases the
       release damping. twBright/twRing/twGut are the morph strengths at
       amount 1; tw*C are their chunk-rate derived values. */
    double twBright, twRing, twGut;
    double twXpC, twBrAC, twNutAC, twGutA2C, twGutC, twRingC;
    /* pitch lock: brightening the termination one-poles REMOVES loop
       phase delay (a one-pole's low-f phase delay is a/(1-a) kernel
       samples), which is what made the twanged ring run sharp of the
       un-twanged ring. twTrimC restores exactly the removed delay on
       the bridge-segment read, chunk-derived — the twanged and plain
       rings then track the same period at any pitch and amount. */
    double twTrimC;
    int sdN;
    double sdA1[16], sdA2[16], sdN0[16], sdG[16];
    double sdX1[2][16], sdX2[2][16], sdY1[2][16], sdY2[2][16];
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
    /* Tarabdaar FX (2026-08-01): host hook on the recorded jt drive — the
       "main voice before the taraf" insert point. Called on the render
       thread with the block's drive buffer AFTER the record walk and
       BEFORE the jt post-pass consumes it (async mode: before the ring
       job is published, so ordering and state continuity hold). Set
       OFF the audio thread at engine build; NULL (the default) is
       byte-null. */
    void (*fxDriveFn)(void *ctx, double *buf, int n);
    void *fxDriveCtx;
    /* TARABDAAR SITAR->TARAF INJECT (2026-08-19): a second voice's
       rendered output drives the modal-jawari web sympathetically —
       the sitar's taraf. SPSC ring: the other voice's render callback
       writes mono samples (bow_poly_jt_inject_write), THIS kernel's
       render mixes what is available into the recorded jt drive right
       before the drive-FX hook (so the voice→taraf insert shapes it
       too). Ring alloc happens in the gain setter (control thread);
       NULL ring / zero gain / empty ring are all byte-null. */
    double *sjRing;                   /* 32768 doubles, lazy alloc */
    long long sjW, sjR;               /* ring cursors (mono counts) */
    double sjGain;                    /* plain scalar store */
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
    st->jawG = 1.0;    /* Tarabdaar TILT purity: 1 = byte-exact legacy */
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
    /* Tarabdaar SITAR TWANG morph: brighter, harder terminations and an
       eased release damping (a sitar string rings against a fret wire,
       not a lifted finger). All exact-legacy while disarmed. */
    const int twOn = st->twOn;
    const double brAe = twOn ? st->twBrAC : brA;
    const double gutGe = twOn ? st->twGutC : gutG;
    const double gutA2e = twOn ? st->twGutA2C : gutA2;
    if (twOn) rdmp = 1.0 - (1.0 - rdmp) * st->twRingC;
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
            if (twOn) nutAf = pow(nutAf, st->twXpC);
        } else if (twOn) {
            nutAf = st->twNutAC;
        }
        double h1 = pfrac_read(S->buf1, MAXBOW, S->w1i,
                               fmax(2.0, L1 * 2.0 - bowWidth));
        double dl = kdisp * st->disp;
        if (dl > 0.02) dl = 0.02; else if (dl < -0.02) dl = -0.02;
        /* Tarabdaar SITAR TWANG: the rolling wrap shortens the bridge
           segment by twD - twDb samples — the wrap's per-cycle phase
           modulation with its pitch-shifting mean removed — and two
           pitch-lock terms hold the twanged ring on the plain ring's
           pitch: twTrimC restores the loop phase delay the brightened
           terminations lost (analytic, verified ±0.1 samples over
           three octaves), and the twWt curve cancels the wrap's
           phase-SELECTIVE residual (the corner samples twD at a
           note-dependent phase; fitted n(P) = 0.335 - 66.2/P samples
           per unit of amt·roll over notes 48/60/72). All 0 while
           disarmed — bit-exact. */
        double twWt = 0.0;
        if (twOn && st->twCur > 0.0) {
            double Pn = sr / fmax(f0t, 40.0);
            twWt = st->twTrimC
                + st->twCur * st->twRollSmp * (0.335 - 66.2 / Pn);
        }
        double h2 = pfrac_read(S->buf2, MAXBOW, S->w2i,
                               fmax(2.0, (L2 * 2.0 - bowWidth) * (1.0 + dl)
                                    - S->twD + S->twDb + twWt));
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
            S->buf1[S->w1i] = -S->nutLp * rdmp * gutGe;
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
            S->buf1[S->w1i] = -S->nutLp * rdmp * gutGe;
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
    /* Tarabdaar SITAR TWANG (2026-08-01): the grazing jawari fold on the
       played string's bridge reflection. The knee rides the string's
       own peak envelope (fast attack, ~40 ms release), so the graze
       engages at the same relative depth at any strike level — the
       consistency the fixed-knee web buzz never had. One-sided: only
       positive excursions past the knee fold, which flattens one
       polarity of the wave (the flat-bridge wrap) and pumps the
       even-harmonic cascade round trip by round trip. Applied BEFORE
       the dispersion chain — the bone sits on the string side of the
       bridge. twOn 0 skips everything (byte-null). */
    if (st->twOn) {
        /* per-side peak envelopes, instant attack / slow release (the
           web roll contact's rollE idiom) — the knee sits just under
           each side's true recent peak, so the graze engages only at
           the excursion TIPS, at any strike level */
        double eP0 = S->twEnvP * st->twRel;
        S->twEnvP = apy > eP0 ? apy : eP0;
        double eN0 = S->twEnvN * st->twRel;
        S->twEnvN = -apy > eN0 ? -apy : eN0;
        double amt = st->twCur;
        if (amt > 0.0) {
            double eP = apy - st->twKneeR * S->twEnvP;
            double eN = -apy - st->twKneeR * S->twEnvN;
            int gP = eP > 0.0 && S->twEnvP > 1e-12;
            int gN = eN > 0.0 && S->twEnvN > 1e-12;
            /* the WRAP — conservative rolling-contact shortening of
               the bridge segment while the tip presses the bone (the
               web's v2 roll idiom): the bridge read slides closer by
               twD samples (poly_string_force), a per-cycle phase
               modulation that pumps the harmonic cascade WITHOUT
               deleting ring energy (a subtractive fold alone measured
               as buzz + a choked ring) */
            double tgt = (gP || gN) ? amt * st->twRollSmp : 0.0;
            S->twD += st->twAv * (tgt - S->twD);
            /* twDb = twD's time-averaged mean: removes the wrap's DC
               pitch shift. (An engaged-gated "corner-phase" tracker was
               tried and measured WORSE — the engagement/corner phase
               relationship varies with note; the residual after the
               time-averaged mean is handled by the fitted twWrapTrim
               curve in poly_string_force.) */
            S->twDb += st->twDcA * (S->twD - S->twDb);
            /* light hysteretic contact loss at the graze */
            double d = amt * st->twDepth;
            if (gP) apy -= d * eP;
            else if (gN) apy += d * eN;
        } else {
            S->twD *= 0.999;
            S->twDb *= 0.999;
        }
    }
    for (int kd = 0; kd < dispNi; kd++) {
        double ay = st->bowDisp * apy + S->apXs[kd] - st->bowDisp * S->apYs[kd];
        S->apXs[kd] = apy; S->apYs[kd] = ay; apy = ay;
    }
    S->buf2[S->w2i] = apy * rdmp
        * (st->twOn ? st->twGutC : st->gutG);
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
                 const double *wd, const double *phiO, const double *phiD,
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
    st->jtGovEnv = (double *)calloc(njt, sizeof(double));
    st->jtGovAmt = 0.0;
    st->jtGovRef = 0.0;
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
        /* mellow-drone rev (2026-07-26): slow swell/fall + a ~1.6 kHz
           drive top — kept in step with the BowEngine bp defaults
           (bow_drone_*), which always overwrite these at build */
        st->jtGovRel = exp(-dtj / 0.060);
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
    /* tilt-axis reference: the deepest static wrap across strings
       (floor jtDeep) — the unit bow_poly_jt_set_lift scales to clear
       the bone at full purity. Axes start off (byte-null). */
    st->jtLift = 0.0; st->jtDampMul = 0.0;
    /* Tarabdaar HARMONIC-EVOLUTION lift (2026-07-26): signed bone offset
       in meters, slewed per jt sample (~40 ms) so the bone GLIDES —
       a tilt sweep is a slow jawari adjustment, not a strum. 0 =
       byte-null (the exact legacy contact + jtDeep compare). */
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

/* Tarabdaar MELODY FOLLOWER (2026-07-25): slew the tracked row's f0
   toward the host's target and rebuild its f0-dependent mode tables in
   place. Runs on whichever thread ticks the row (serial / pool / async
   all funnel through jt_tick_string), so the writes are same-thread
   with the reads. The static wrap is NOT re-solved — the contact
   physics re-settles on its own, which is exactly a string gliding
   under a grazing bone. Cost: ~M transcendental recomputes per ~1.3 ms
   only while the pitch is actually moving; zero at rest. */
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
    /* active mode count: NO 16-mode floor here — a mode above the fx
       corner is under-resolved in the contact solve and limit-cycles
       into broadband static (measured, dynamic-taraf era) */
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
        /* the builder's per-mode damping law (buildJawariTables) */
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
        /* modes leaving/entering the active set start from zero (a
           re-entering mode is pulled into the wrap by the contact) */
        const int lo = mUse < st->jtTrkMUse ? mUse : st->jtTrkMUse;
        int hi = mUse > st->jtTrkMUse ? mUse : st->jtTrkMUse;
        if (hi > Mall) hi = Mall;
        for (int k = lo; k < hi; k++) {
            st->jtQ[mo + k] = 0.0;
            st->jtP[mo + k] = 0.0;
        }
        /* contact compliance = prefix sum over the active modes:
           G[a][b] = (dt^2/2) * sum_k phiU[k][a]*phiF[k][b]
           (phiF carries wj/mu — matches the builder's gscale) */
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

/* one modal-jawari sample: rotate every string, contact (substepped at
   deep engagement), one-way drive Fd, return the summed observation.
   Shared by bow_process, bow_jt_test and the poly kernel port. */
/* per-string advance — the threading unit (mono lockstep): touches
   only string s's state slices + shared read-only tables; penmax
   accumulates locally (merged by the caller). */
/* advance the evolution-lift slew one divided jt sample (single
   caller thread per mode: the audio thread, the pool dispatcher or
   the async walker — never the workers). Snap kills denormal tails
   and restores the exact ev == 0.0 byte-null path at rest. */
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

static double jt_tick_string(bow_poly_state_t *st, int s, double Fd,
                             double ev, double *penmax)
{
    const int J = st->jtJ;
    const double dtj = (double)st->jtDiv / st->sr;
    /* QUIESCENCE GATE early-out (2026-08-17): an asleep row is frozen
       in place and skips the whole tick — retune amortization included
       (the follower only sleeps when nothing plays; it retunes within
       jtTrkIval ticks of waking). Bridge drive above the row's wake
       bound or ANY drone drive (pluck boost included) resumes it from
       the frozen state — no re-settle, no strum. Raw Fd is judged
       (recruitment/governor scaling is awake-path state). */
    const double FdIn = Fd;
    if (st->jtGateRef > 0.0 && st->jtGateSlp[s]) {
        if (fabs(Fd) <= st->jtGateFdEps[s]
            && st->jtDnBoost[s] == 0.0 && st->jtDnEnv[s] == 0.0
            && st->jtDnTgt[s] == 0.0)
            return 0.0;
        st->jtGateSlp[s] = 0;
        st->jtGateCnt[s] = st->jtGateHold;
    }
    /* melody-follower retune (amortized: every jtTrkIval ticks of the
       tracked row only; other rows pay one compare) */
    if (s == st->jtTrkRow && --st->jtTrkTick <= 0) {
        st->jtTrkTick = st->jtTrkIval;
        jt_track_retune(st);
    }
    {
        const int Ms = s == st->jtTrkRow ? st->jtTrkMUse : st->jtM[s];
        const int mo = st->jtMOff[s], zo = st->jtZOff[s];
        double *q = st->jtQ + mo, *p = st->jtP + mo;
        /* Tarabdaar RECRUITMENT (2026-07-26): per-row bridge-drive weight,
           slewed here (~30 ms) so a note change re-voices the taraf
           without a step. BEFORE the drone branch: a held drone's noise
           drive adds after and is never ducked. Energy the row already
           holds rings out naturally — the weight gates recruitment, not
           the ring. Unarmed = byte-null. */
        if (st->jtDwOn) {
            double c = st->jtDwCur[s];
            c += st->jtDwA * (st->jtDwTgt[s] - c);
            st->jtDwCur[s] = c;
            Fd *= c;
        }
        /* CHARGE GOVERNOR shed (previous-tick envelope, one jt-tick
           lag): a row ringing above its graze target takes ref/env of
           the bridge drive — an AGC that saturates the ring at the
           single-strike level instead of letting a phrase pile up in
           the long-t60 anchors. BEFORE the drone branch: a held
           drone's own drive is never ducked. */
        if (st->jtGovAmt > 0.0 && st->jtGovRef > 0.0) {
            const double refv = st->jtGovRef * st->jtWd[mo];
            const double env = st->jtGovEnv[s];
            if (env > refv)
                Fd *= 1.0 - st->jtGovAmt * (1.0 - refv / env);
        }
        /* DRONE row (2026-07-23, gradual-attack rev): the whole
           excitation is a slewed filtered-noise drive — NO impulse.
           The envelope eases toward (hold target + onset boost) with
           the attack coefficient and falls with the release one; the
           boost (set by bow_poly_jt_pluck at press) decays over a
           few hundred ms, so the onset is a swell that relaxes into
           the sustain. The string is the resonator — only its modal
           response radiates. Whole branch guarded so the all-zero
           (unused) path is byte-identical to the legacy tick.
           Per-row state, per-row visitation: safe under the worker
           partition (a row belongs to one worker). */
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
                /* band-passed noise (sub-audio content would push the
                   string quasi-statically against the jawari bone and
                   pump the buzz — slow tremolo) */
                double lp = st->jtDnLp[s];
                lp += st->jtDnALp * (w - lp);
                st->jtDnLp[s] = lp;
                double lp2 = st->jtDnLp2[s];
                lp2 += st->jtDnALp2 * (lp - lp2);
                st->jtDnLp2[s] = lp2;
                double drv = lp - lp2;
                /* pitched part (mellow-drone rev): a sine at the row's
                   own mode-1 frequency — the drive a played note hands
                   a sympathetic string. Noise alone rings the row's
                   high modes far above their played-note balance. */
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
        /* Tarabdaar TILT: bone lift (taraf-purity axis, mono lockstep) —
           the jawari bone drops jtLift below its profile; penetration
           shrinks toward zero and the string rings as a PURE modal
           taraf. Composed with the slewed evolution lift `ev` (SIGNED
           — negative raises the bone). 0 = the byte-exact legacy
           contact. */
        const float lift = (float)(st->jtLift + ev);
        float bl[JT_MAXJ];
        const float *bc_ = b_;
        if (lift != 0.0f) {
            for (int j = 0; j < J; j++) bl[j] = b_[j] - lift;
            bc_ = bl;
        }
        /* deep-substep threshold follows the evolution lift the way a
           rebuild at the shifted apex would (phys[3] = 2.5·apex). */
        double deepEff = st->jtDeep - 2.5 * ev;
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
        /* governor envelope: peak |zone velocity| this tick, ~60 ms
           release (state only touched while armed — byte-null off) */
        if (st->jtGovAmt > 0.0) {
            float am = 0.0f;
            for (int j = 0; j < J; j++) {
                float t = fabsf(ud[j]);
                if (t > am) am = t;
            }
            double e = st->jtGovEnv[s] * st->jtGovRel;
            st->jtGovEnv[s] = (double)am > e ? (double)am : e;
        }
        float pen = -1e30f;
        for (int j = 0; j < J; j++) {
            float d = bc_[j] - u[j];
            if (d > pen) pen = d;
        }
        if ((double)pen > *penmax) *penmax = (double)pen;
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
                        (float)st->jtKc, (float)st->jtAlpha,
                        (float)st->jtHcB, dt4, q, p);
            }
        } else {
            jt_core(Ms, J, u, ud, phiF, bc_, G_, gd_,
                    (float)st->jtKc, (float)st->jtAlpha,
                    (float)st->jtHcB, dtj, q, p);
        }
        for (int k = 0; k < Ms; k++)
            p[k] += dtj * Fd * st->jtPhiD[mo + k];
        /* Tarabdaar TILT: extra taraf decay — momentum-proportional loss
           per tick (static wrap p = 0 untouched). 0/>= 1 = off. */
        const double dampm = st->jtDampMul;
        if (dampm > 0.0 && dampm < 1.0)
            for (int k = 0; k < Ms; k++) p[k] *= dampm;
        /* QUIESCENCE GATE entry: a full hold window (~30 ms) of
           sub-floor LOW-MODE momentum with no bridge drive and no
           drone drive freezes the row IN PLACE. The meter is the
           audible ring: peak |p| over the first modes. The zone
           velocity / raw radiated sample CANNOT gate — the settled
           static wrap sustains a tick-rate micro limit-cycle against
           the bone (measured: zone velocity rests at ~0.6, per-row
           radiated peak at ~5e-3, both CONSTANT), but it lives in the
           HIGH modes; the low modes rest 3+ decades below ring scale.
           Single-tick |p| dips at the mode cycle's zero crossings
           can't fake a CONSECUTIVE quiet run. Armed only. */
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
        double yjt = 0.0;
        for (int k = 0; k < Ms; k++)
            yjt += st->jtPhiO[mo + k] * p[k];
        return yjt;
    }
}

/* sideOut (nullable): accumulates the PAN-WEIGHTED row sum for the
   Tarabdaar stereo side path — each modal-jawari string radiates from
   its own place across the bridge. NULL = the legacy mono walk. */
static double jt_tick(bow_poly_state_t *st, double Fd, double ev,
                      double *sideOut)
{
    double jrad = 0.0;
    double pen = st->jtPenMax;
    if (sideOut && st->stJtPan) {
        double side = 0.0;
        for (int s = 0; s < st->njt; s++) {
            double y = jt_tick_string(st, s, Fd, ev, &pen);
            jrad += y;
            side += st->stJtPan[s] * y;
        }
        *sideOut = side;
    } else {
        for (int s = 0; s < st->njt; s++)
            jrad += jt_tick_string(st, s, Fd, ev, &pen);
        if (sideOut) *sideOut = 0.0;
    }
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
        const double *evv = st->jtEvV;
        /* Tarabdaar stereo: pan-weighted side partials ride a second
           accumulator row (stOn set at build, before rendering) */
        double *hpS = (st->stOn && st->jtHpS && st->stJtPan)
            ? st->jtHpS + (size_t)idx * JT_POOL_CH : NULL;
        for (int s = s0; s < s1; s++) {
            const double pn = hpS ? st->stJtPan[s] : 0.0;
            for (int k = 0; k < nT; k++) {
                double y = jt_tick_string(st, s, fd[k], evv[k], &pen);
                hp[k] += y;
                if (hpS) hpS[k] += pn * y;
            }
        }
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
        st->jtEvV = (double *)calloc(JT_POOL_CH, sizeof(double));
        st->jtTkv = (int *)malloc(sizeof(int) * JT_POOL_CH);
        st->jtHp = (double *)malloc(sizeof(double) * 16 * JT_POOL_CH);
        st->jtHpS = (double *)malloc(sizeof(double) * 16 * JT_POOL_CH);
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

/* Tarabdaar jt tone LP (2026-07-23): arm/clear the one-pole on the
   radiated jt sum. a <= 0 = bypass (the historical bit-exact output).
   RUNTIME-SAFE (mono lockstep, purity axis 2026-07-23 night): mid +
   side states PRESERVED on coefficient moves; the bypass branches
   keep them warm. Plain scalar write, any thread. */
/* Tarabdaar FX (2026-08-01): install the jt-drive FX hook. Plain pointer
   stores — call OFF the audio thread (engine build, before rendering);
   NULL fn (the calloc default) is byte-null. Context is stored first so
   a non-NULL fn never observes a stale ctx. */
void bow_poly_set_drive_fx(void *vst,
                           void (*fn)(void *ctx, double *buf, int n),
                           void *ctx)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->fxDriveCtx = ctx;
    st->fxDriveFn = fn;
}

/* ---- Tarabdaar sitar→taraf inject (2026-08-19) ---- */
#define SJ_RINGN 32768

/* Control thread (the drone-setter contract, plus a one-time ring
   alloc on the first non-zero gain — call from the param apply path,
   never the audio thread). 0 with no ring allocated stays byte-null. */
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

/* Producer render thread (the OTHER voice's callback): append mono
   samples. Drops the block when the ring is full (consumer stalled —
   e.g. the jt web disabled); the consumer realigns on gross backlog. */
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

void bow_poly_jt_set_lp(void *vst, double a)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->jtLpA = a;
}

/* Tarabdaar jt tone HP (2026-07-26): arm/clear the one-pole high-pass on
   the radiated jt sum (applied after the LP inside jt_lp_step). Same
   contract as set_lp: a <= 0 = bypass (byte-exact legacy), states
   preserved on coefficient moves, plain scalar write, any thread. */
void bow_poly_jt_set_hp(void *vst, double a)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    st->jtHpA = a;
}

/* Tarabdaar jt BODY radiation mix (2026-08-01): 0..1 blend of the
   radiated jt sum through the SAME formula-body radiation bank the
   played strings radiate through (own filter state inside jt_lp_step,
   shared coefficient arrays — a live bow_poly_set_body re-points
   both). Plain scalar store, any thread (the drone-setter contract);
   slewed ~30 ms at the kernel rate. Never calling it is byte-null.
   NOT part of the load ABI — same contract as set_lp/set_hp. */
void bow_poly_jt_set_body(void *vst, double mix)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (mix < 0.0) mix = 0.0;
    if (mix > 1.0) mix = 1.0;
    /* a 0 push while unarmed stays a no-op — the app's startup
       resting-push sends every live parameter, and arming here would
       tick K idle biquads per jt sample forever */
    if (!st->jtBodyOn && mix <= 0.0) return;
    st->jtBodyTgt = mix;
    st->jtBodyOn = 1;
}

/* TARABDAAR STEREO SIDE OUTPUT (2026-07-23): arm the side path with
   per-source pan weights (each already scaled by the host's spread —
   the kernel just applies them). webPan[nv] = taraf web strings,
   jtPan[njt] = modal-jawari rows (call AFTER bow_poly_jt_load),
   slotPan[nb] = played gut strings. NULL / wrong-length arrays leave
   that family centred (zero pan). Call at engine build, off the audio
   thread, before rendering starts. */
void bow_poly_set_stereo(void *vst, const double *webPan, int nWeb,
                         const double *jtPan, int nJt,
                         const double *slotPan, int nSlot)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    free(st->stWebPan); free(st->stSlotPan); free(st->stJtPan);
    st->stWebPan = (double *)calloc(st->nv > 0 ? st->nv : 1,
                                    sizeof(double));
    st->stSlotPan = (double *)calloc(st->nb, sizeof(double));
    st->stJtPan = (double *)calloc(st->njt > 0 ? st->njt : 1,
                                   sizeof(double));
    if (webPan && nWeb == st->nv)
        memcpy(st->stWebPan, webPan, sizeof(double) * (size_t)st->nv);
    if (slotPan && nSlot == st->nb)
        memcpy(st->stSlotPan, slotPan, sizeof(double) * (size_t)st->nb);
    if (jtPan && st->njt > 0 && nJt == st->njt)
        memcpy(st->stJtPan, jtPan, sizeof(double) * (size_t)st->njt);
    memset(st->tsx1, 0, sizeof(st->tsx1));
    memset(st->tsx2, 0, sizeof(st->tsx2));
    memset(st->tsy1, 0, sizeof(st->tsy1));
    memset(st->tsy2, 0, sizeof(st->tsy2));
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

/* TARABDAAR INSTRUMENT WIDTH (2026-08-01 unifying rev): derive the
   diffuse-field difference bank (see the state block): 16 modes
   log-spaced 700 Hz -> 6.5 kHz with golden jitter, Q ~ 12,
   plastic-number signs (the builder's own jitter/sign sequences —
   deterministic, no RNG), each peak-normalized like the mid body
   modes and weighted by a log-frequency directivity ramp d(f), 0
   below 300 Hz -> 1 at 3 kHz (ka ~ 1 onset for a sarangi-sized
   radiator: fundamentals stay dead-centre, only the upper spectrum
   opens). The drive is the radiated mid itself, so unit weight =
   "as loud as the mid"; 1.4·d(f) at the peaks stays well inside what
   two real observation points show (|H_L - H_R| reaches 2·|H| at a
   sign flip) — measured with BOTH bus instances live (the wash rings
   right in the bank's band, so it dominates the calibration): width
   0.2 lands melody interaural coherence ~0.9 at 4-8 kHz with the
   bare wash at ~0.3-0.4 ("air, image intact"); 0.6 is very wide
   (melody ~0.4-0.5). Depends only on the sample rate — a live body
   retune does NOT need a re-derive. */
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

/* one width-bank step for bus b ([0] voice, [1] jt wash): shared
   coefficients, per-bus state — linearity keeps the split FX buses'
   side streams valid while their sum equals the one-instrument model */
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

/* Arm / retarget the instrument width. Width factors out of the bank
   linearly, so the bank stores unit width and the scalar is slewed
   ~30 ms on the render thread (zipper-safe live moves). Call at
   engine build off the audio thread (any order w.r.t.
   bow_poly_set_stereo — the render gates on stOn && stWidthOn).
   Never calling it, or width 0 from a cold start, is the exact
   legacy side path. */
void bow_poly_set_stereo_width(void *vst, double width)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    st->stWidthTgt = width;
    if (!st->stWidthOn && width <= 1e-9) return;   /* stay byte-null */
    poly_width_derive(st);
    st->stWidthOn = 1;         /* arm last — the render gates on it */
}

/* TARABDAAR SITAR TWANG (2026-08-01): shape defaults, derived once on
   first arm (the width-derive idiom). Values are the sitar1.wav fit
   (staccato C4 on the shipping artifact vs the sample's pluck 2, band-
   trajectory match): buzz-band/low-band gap -9.5/-8.5/-10.6/-11.8 dB
   at 150/300/600/900 ms into the ring vs the sitar's -6/-2/-7/-7, low
   band decaying in step, pitch error +0.9 cents. The contact-loss fold
   ships at 0 — any measured depth shortened the ring without adding
   twang (the wrap PM is the whole cascade); the hook keeps it for
   sound-design experiments. See bow_poly_set_twang_shape to re-fit. */
static void poly_twang_defaults(bow_poly_state_t *st)
{
    if (st->twSl > 0.0) return;                    /* already derived */
    st->twSl = 1.0 - exp(-1.0 / (0.030 * st->sr));
    st->twKneeR = 0.5;
    st->twDepth = 0.0;
    st->twRel = exp(-1.0 / (0.040 * st->sr));
    /* extended-top rev (the "go twangier" rework): the endpoints are
       HOTTER than the original sitar1.wav fit (roll 4 / bright 2.5 /
       ring 0.95 / gut 0.8, knee 0.55), which now lives near amount
       ~0.75 of the throw — ring/gut deliberately exceed their derive
       caps so they SATURATE at the fitted sustain by ~0.75 and the
       last quarter spends its travel on wrap + brightness (the buzz
       levers that still move up there; the sweep measured the buzz
       equilibrium saturating near roll 5.5 — a bigger swing also
       smears more HF, so past this the axis only buys drain). */
    st->twRollSmp = 5.5;
    st->twAv = 1.0 - exp(-1.0 / (0.0005 * st->sr));
    st->twDcA = 1.0 - exp(-1.0 / (0.030 * st->sr));
    st->twBright = 3.33;
    st->twRing = 1.27;
    st->twGut = 1.07;
    st->twXpC = 1.0;
    st->twBrAC = st->brA;
    st->twNutAC = st->nutA;
    st->twGutA2C = st->gutA2;
    st->twGutC = st->gutG;
    st->twRingC = 1.0;
}

/* chunk-rate derivation of the sitar-morph effective terminations from
   the current slewed amount (called at the top of process3 while armed;
   pow at chunk rate, plain reads per sample) */
static void poly_twang_derive(bow_poly_state_t *st)
{
    double a = st->twCur;
    if (a < 0.0) a = 0.0;
    if (a > 1.0) a = 1.0;
    double xp = 1.0 + st->twBright * a;
    st->twXpC = xp;
    st->twBrAC = pow(st->brA, xp);
    st->twNutAC = pow(st->nutA, xp);
    st->twGutA2C = st->gutA2 > 0.0 ? pow(st->gutA2, xp) : st->gutA2;
    /* ring/gut ease saturate (endpoints > 1 park the fitted sustain at
       ~3/4 throw; the caps keep the loop lossy enough to stay stable) */
    double gutE = st->twGut * a;
    if (gutE > 0.9) gutE = 0.9;
    st->twGutC = 1.0 - (1.0 - st->gutG) * (1.0 - gutE);
    double ringE = st->twRing * a;
    if (ringE > 0.98) ringE = 0.98;
    st->twRingC = 1.0 - ringE;
    /* pitch lock: phase delay the brightened one-poles no longer
       provide, added back on the bridge read (a/(1-a) per pole per
       pass; low-f form — f0 sits well under both corners; verified
       accurate to ~0.1 samples across three octaves on a wrap-free
       morph). The wrap's own detune is handled separately — the
       engaged-gated twDb tracker in poly_string_return. */
    double dBr = st->brA / (1.0 - st->brA)
        - st->twBrAC / (1.0 - st->twBrAC);
    double dNut = st->nutA / (1.0 - st->nutA)
        - st->twNutAC / (1.0 - st->twNutAC);
    st->twTrimC = dBr + dNut;
    if (st->twTrimC < 0.0) st->twTrimC = 0.0;
}

/* Arm / retarget the played-string sitar-twang amount 0..1 (the live
   form of the `bow_twang` parameter — see the state-struct comment for
   the physics). Plain scalar store, any thread (the drone-setter
   contract); the amount slews ~30 ms per kernel sample. 0 from a cold
   start / never calling is byte-null, and the fold self-disarms once
   a live 0 finishes slewing. */
void bow_poly_set_twang(void *vst, double amt)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    if (amt < 0.0) amt = 0.0;
    if (amt > 1.0) amt = 1.0;
    st->twTgt = amt;
    if (!st->twOn && amt <= 1e-9) return;          /* stay byte-null */
    poly_twang_defaults(st);
    st->twOn = 1;
}

/* Offline / fitting hook (the bow_jt_set_lift precedent — no registry
   parameter drives this): override the twang wrap's shape. kneeR =
   graze knee as a fraction of each side's peak envelope (0..0.99 —
   high = only the excursion tips engage); depth = the hysteretic
   contact-LOSS fold slope at amount 1 (small — the wrap itself is
   conservative); relMs = the peak envelope's release (attack is
   instant — the rollE idiom); rollSmp = the wrap's bridge-segment
   shortening in kernel-rate samples at amount 1 (the main, energy-
   conserving cascade device). Non-positive values keep the current
   (fitted-default) shape. Call off the audio thread. */
void bow_poly_set_twang_shape(void *vst, double kneeR, double depth,
                              double relMs, double rollSmp,
                              double bright, double ring, double gut)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st) return;
    poly_twang_defaults(st);
    if (kneeR > 0.0) st->twKneeR = kneeR < 0.99 ? kneeR : 0.99;
    if (depth > 0.0) st->twDepth = depth < 2.0 ? depth : 2.0;
    if (relMs > 0.0)
        st->twRel = exp(-1.0 / (relMs * 1e-3 * st->sr));
    if (rollSmp > 0.0) st->twRollSmp = rollSmp < 24.0 ? rollSmp : 24.0;
    if (bright > 0.0) st->twBright = bright < 4.0 ? bright : 4.0;
    if (ring > 0.0) st->twRing = ring < 1.5 ? ring : 1.5;
    if (gut > 0.0) st->twGut = gut < 1.2 ? gut : 1.2;
}

/* one filtered step of the jt output walk (bypass = identity with a
   warm state track — output byte-identical to the legacy bypass).
   ALSO the ONE application point of the recruitment lush gain
   (jtGMul): every radiating path runs the mono step exactly once per
   kernel sample, so the slew advances here; the side twin reads the
   value the mono step just advanced. The gain multiplies the RETURN
   only — the LP state stays pre-gain, so engaging/releasing the boost
   never steps the filter. Unarmed multiplies by exactly 1.0
   (bit-null). */
static inline double jt_lp_step(bow_poly_state_t *st, double x)
{
    double m = 1.0;
    if (st->jtGMulOn) {
        st->jtGMulCur += st->jtGMulA * (st->jtGMulTgt - st->jtGMulCur);
        m = st->jtGMulCur;
    }
    /* Tarabdaar jt BODY radiation (2026-08-01): blend through the voice's
       own body radiation bank (shared coefficients, own state) BEFORE
       the tone LP/HP — physically the rows radiate into the body, the
       tone pair is sound-design EQ after it. Mix slewed ~30 ms here;
       the filter keeps ticking while armed so engage/release never
       steps the state. mix 0 adds exactly 0.0 — bit-exact dry. */
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
    /* Tarabdaar jt tone HP (2026-07-26, the jawari-formant voicing):
       one-pole high-pass (x − LP(x)) AFTER the tone LP — quiets the
       taraf's fundamental band under the high-harmonic cluster.
       Unarmed = warm-tracked identity, byte-exact legacy. */
    if (st->jtHpA <= 0.0) st->jtHpY = x;
    else { st->jtHpY += st->jtHpA * (x - st->jtHpY); x -= st->jtHpY; }
    return m * x;
}

/* side twin (own states, same coefficients) — Tarabdaar stereo */
static inline double jt_lp_stepS(bow_poly_state_t *st, double x)
{
    const double m = st->jtGMulOn ? st->jtGMulCur : 1.0;
    /* body twin: same coefficients, own state; reads the mix the mono
       step just advanced (the jtGMul pattern) */
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

/* Radiated-gain multiplier (the lush half of the recruitment axis):
   scales the jt web's OUTPUT, slewed ~30 ms in jt_lp_step. Unlike a
   drive boost, output level cannot be drained by the graze contact —
   this is the reliable "how loud is the chorus" lever. Plain scalar
   store, any thread (the drone-setter contract). 1 = bit-exact; never
   calling it is byte-null. */
void bow_poly_jt_set_gain_mul(void *vst, double m)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (m < 0.0) m = 0.0;
    if (m > 4.0) m = 4.0;
    st->jtGMulTgt = m;
    st->jtGMulOn = 1;
}

/* Per-row bridge-drive weights (the recruitment axis) — plain per-row
   scalar stores, any thread (the drone-setter contract; the jt tick
   slews). First call arms the tick's multiply; all-ones is bit-exact. */
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

/* Tarabdaar HARMONIC-EVOLUTION lift (2026-07-26): signed bone offset in
   meters (+ = bone dropped — graze margin shrinks, the upward cascade
   opens; − = raised — pressed past the knee, no twang), slewed per jt
   sample (~40 ms) by jt_ev_step so the bone GLIDES: a tilt sweep is a
   slow jawari adjustment, not a strum. The live form of the
   `bow_jt_evolve` parameter (BowEngine owns the 0…1 → meters map).
   Plain scalar store, any thread. 0 at rest = byte-null. */
void bow_poly_jt_set_evolve(void *vst, double meters)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (meters > 1e-3) meters = 1e-3;
    if (meters < -1e-3) meters = -1e-3;
    st->jtEvTgt = meters;
    /* wake sleeping quiescence-gate rows on a MATERIAL bone move: a
       row that slept through a real glide would meet the moved bone
       as a STEP on wake (the strum this slew exists to avoid). The
       wake is CHANGE-gated against the target the sleepers were
       frozen under — comparing to jtGateEvWake (not the previous
       push) so slow cumulative drift still wakes once it adds up,
       while a re-pushed constant or sensor jitter (a live tilt
       binding streams this setter at sensor rate) never does. A
       sub-dead-band offset met on wake is <= 5% of the graze apex —
       nothing. Awake rows track the slew exactly regardless. */
    if (st->jtGateRef > 0.0 && st->jtGateSlp
        && fabs(meters - st->jtGateEvWake) > 0.02 * st->jtDeep) {
        st->jtGateEvWake = meters;
        for (int s = 0; s < st->njt; s++) st->jtGateSlp[s] = 0;
    }
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

/* CHARGE GOVERNOR (Tarabdaar 2026-08-15, `bow_jt_gov`): amt 0..1 is the
   governor strength (0 = byte-null raw physics); refDisp is the target
   contact-zone ring DISPLACEMENT in meters (apex-scale — the graze
   band), converted per row to a velocity bound refDisp·wd1 on the
   row's zone-velocity peak envelope. Drone-setter contract: plain
   scalar writes, the jt tick reads them. */
void bow_poly_jt_set_gov(void *vst, double amt, double refDisp)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (amt > 0.0 && refDisp > 0.0) {
        st->jtGovRef = refDisp;
        st->jtGovAmt = amt < 1.0 ? amt : 1.0;
    } else {
        st->jtGovAmt = 0.0;
    }
}

/* QUIESCENCE GATE (Tarabdaar 2026-08-17, `bow_jt_gate`): refDisp is the
   sleep floor as contact-zone ring DISPLACEMENT in meters (apex-scale,
   ×mode-1 rate = the per-row velocity floor — the jtGovRef convention).
   Arms the per-row wake bounds and the ~30 ms hold window; <= 0
   disarms AND wakes every row (a stale asleep flag under a later
   re-arm would truncate a ringing row). Drone-setter contract: plain
   scalar/array writes, the jt tick reads them; the armed flag
   jtGateRef is written last. */
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
    for (int s = 0; s < st->njt; s++) {
        const int mo = st->jtMOff[s];
        const double wd1 = st->jtWd[mo];
        double pdm = 0.0;
        for (int k = 0; k < st->jtM[s]; k++) {
            const double t = fabs(st->jtPhiD[mo + k]);
            if (t > pdm) pdm = t;
        }
        /* wake bound: the drive that could ring the low modes back up
           to the floor refDisp·wd1 within ~one mode-1 period of
           resonant driving (|p| ≈ π·Fd·phiD/wd1) — conservative, so
           anything that could become audible wakes the row. The
           follower's retunes scale wd1 by at most an octave-ish and
           only land while it is awake (drive present) — the stale
           bound stays the right order. */
        st->jtGateFdEps[s] = pdm > 0.0
            ? refDisp * wd1 * wd1 / (M_PI * pdm)
            : 1e300;
        st->jtGateCnt[s] = st->jtGateHold;
    }
    st->jtGateEvWake = st->jtEvTgt;   /* evolve wake reference = now */
    st->jtGateRef = refDisp;
}

/* gate probe: out = {asleep rows, total rows, max ring/floor ratio,
   max drive/eps ratio, drone-hot flag} since the last read (ratios
   reset on read; >1 names the condition blocking sleep).
   Telemetry-grade racy reads; any thread. */
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

/* TARABDAAR LIVE PARAMETERS (2026-07-24): replace the per-sample scalar
   vector on a LIVE state — the same 61 values bow_poly_init takes, in the
   same order, with the same derivations. Coefficient/table arrays and
   every piece of RUNNING STATE (string histories, the contact/aging
   state crS/crSB/crS3/ageDef/ageDef3, jawG, the jt web) are left
   alone, so editing a physics parameter no longer needs a fresh engine
   — no rebuild, no settle pre-roll, no crossfade, no lost ring.
   Plain scalar writes, control-thread safe, exactly like the
   jaw-gain/drone setters. No parity fixture calls it, so every golden
   is untouched. Order MUST stay in lockstep with bow_poly_init. */
void bow_poly_set_scalars(void *vst, const double *s, int n)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || !s || n < 61) return;
    const double sr = st->sr;
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
    st->bowDisp = s[26]; st->jq = s[27]; st->jq2 = s[28];
    st->zload = s[29];
    st->tdirect = s[30]; st->tshape = s[31]; st->tmix = s[32];
    st->nA = s[33]; st->nT = s[34]; st->nPow = s[35];
    st->nzHi = s[36]; st->nzLo = s[37]; st->nDir = s[38];
    st->nzHiD = s[39];
    st->passive = s[40];
    st->gutG = s[41]; st->dispN = s[42]; st->nailK = s[43];
    st->f0Open = s[44]; st->gutA2 = s[45]; st->tuw = s[46];
    st->torsRatio = s[47]; st->torsG = s[48]; st->torsC = s[49];
    st->ageA = s[50];
    st->ageDk = exp(-1.0 / ((s[51] > 0.01 ? s[51] : 0.01) * 1e-3 * sr));
    st->v0Pow = s[52]; st->v0Ref = s[53];
    st->hairHz = s[54]; st->hairRef = (s[55] > 1e-6 ? s[55] : 1.0);
    st->crW = s[56];
    st->crAt = s[57] > 1e-6
        ? 1.0 - exp(-1.0 / (s[57] * 1e-3 * sr)) : 1.0;
    st->jawRho = s[58];
    st->jawRoll = s[59];
    st->jawRollAmp = (s[60] > 1e-9 ? s[60] : 1e-9);
}

/* TARABDAAR LIVE PARAMETERS stage 3 (2026-07-24): overwrite the BODY modal
   bank's coefficients on a live state. The resonator HISTORIES are
   separate arrays and are left untouched, so retuning the body under a
   sounding note is click-free (the same trick as swapping biquad
   coefficients while keeping the delay state). Refuses (returns 0) when
   the mode count differs — that is a reallocation, i.e. a real rebuild.
   No parity fixture calls it; the goldens are unaffected. */
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

/* TARABDAAR LIVE PARAMETERS stage 3: overwrite the MODAL-JAWARI tables'
   coefficients in place. The modal STATE (jtQ = the settled static wrap,
   jtP, the drone envelopes, jtFprev) is deliberately kept: changing the
   bone geometry under a ringing web is a real physical act, and the web
   relaxing from its old wrap toward the new equilibrium IS the correct
   transient. Refuses when the shape moved (string count, zone count or
   any per-string mode count) — that needs a rebuild. Mirrors
   bow_jt_load's conversions; keep the two in lockstep. */
int bow_poly_jt_set_coeffs(void *vst, int njt, int J, const int *M,
              const double *ca, const double *cb,
              const double *ca4, const double *cb4, const double *wd,
              const double *phiO, const double *phiD,
              const double *phiU, const double *phiF,
              const double *b, const double *G, const double *G4,
              const double *gd, const double *gd4, const double *phys)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || njt != st->njt || J != st->jtJ || njt <= 0) return 0;
    if (!M || !ca || !cb || !ca4 || !cb4 || !wd || !phiO || !phiD
        || !phiU || !phiF || !b || !G || !G4 || !gd || !gd4 || !phys) return 0;
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
        st->jtPhiO[i] = phiO[i]; st->jtPhiD[i] = phiD[i];
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
    /* the reload rebuilt the follower row's tables at its BUILD pitch
       with the full mode count — mark it so the next tick recomputes at
       the current tracked pitch (and re-trims G/gd, since the arrays
       were just overwritten with full-M sums) */
    if (st->jtTrkRow >= 0) {
        st->jtTrkMUse = st->jtM[st->jtTrkRow];
        st->jtTrkApplied = 0.0;
        st->jtTrkDirty = 1;
        st->jtTrkTick = 1;
    }
    return 1;
}

/* run one drive job to a WEB SIGNAL buffer: the schedule + the
   worker pool (blocking waits are fine — this runs on the DISPATCHER
   thread, never the audio callback) + the hold walk.  The numerics
   are the sync post-pass's exactly; only the destination differs. */
static void jt_run_job(bow_poly_state_t *st, const double *drv, int n,
                       double *web, double *webS)
{
    int nT = 0;
    double *fdv = st->jtFdv;
    double *evv = st->jtEvV;
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
            tkv[nT] = t;
            nT++;
            st->jtFprev = Fd;
        }
        if (F > st->jtFmax) st->jtFmax = F;
        if (-F > st->jtFmax) st->jtFmax = -F;
    }
    if (nT == 0) {
        for (int t = 0; t < n; t++) {
            web[t] = st->jtGain * jt_lp_step(st, st->jtHold);
            if (webS)
                webS[t] = st->jtGain * jt_lp_stepS(st, st->jtHoldS);
        }
        return;
    }
    const int nth = st->jtPoolN;
    if (nth >= 2) {
        double *hp = st->jtHp;
        double *hpS = webS ? st->jtHpS : NULL;
        for (int th = 0; th < nth; th++) {
            memset(hp + (size_t)th * JT_POOL_CH, 0,
                   sizeof(double) * (size_t)nT);
            if (hpS)
                memset(hpS + (size_t)th * JT_POOL_CH, 0,
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
        double hold = st->jtHold, holdS = st->jtHoldS;
        int ki = 0;
        for (int t = 0; t < n; t++) {
            if (ki < nT && t == tkv[ki]) {
                double H = 0.0, HS = 0.0;
                for (int th = 0; th < nth; th++) {
                    H += hp[(size_t)th * JT_POOL_CH + ki];
                    if (hpS)
                        HS += hpS[(size_t)th * JT_POOL_CH + ki];
                }
                hold = H;
                holdS = HS;
                ki++;
            }
            web[t] = st->jtGain * jt_lp_step(st, hold);
            if (webS)
                webS[t] = st->jtGain * jt_lp_stepS(st, holdS);
        }
        st->jtHold = hold;
        st->jtHoldS = holdS;
    } else {
        double hold = st->jtHold, holdS = st->jtHoldS;
        int ki = 0;
        for (int t = 0; t < n; t++) {
            if (ki < nT && t == tkv[ki]) {
                double sacc = 0.0;
                hold = jt_tick(st, fdv[ki], evv[ki],
                               webS ? &sacc : NULL);
                if (webS) holdS = sacc;
                ki++;
            }
            web[t] = st->jtGain * jt_lp_step(st, hold);
            if (webS)
                webS[t] = st->jtGain * jt_lp_stepS(st, holdS);
        }
        st->jtHold = hold;
        st->jtHoldS = holdS;
    }
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
        const int sOn = st->stOn && st->jtWebRingS && st->stJtPan;
        jt_run_job(st, st->jtDrvRing + (size_t)slot * JT_ABLK, n,
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
            pthread_cond_init(&st->jtCvW, NULL);
            pthread_cond_init(&st->jtCvD, NULL);
            st->jtPoolInit = 1;
        }
        if (!st->jtFdv) {
            /* dispatcher path uses the schedule scratch even when the
               worker pool is off (serial-in-dispatcher fallback) */
            st->jtFdv = (double *)malloc(sizeof(double) * JT_POOL_CH);
            st->jtEvV = (double *)calloc(JT_POOL_CH, sizeof(double));
            st->jtTkv = (int *)malloc(sizeof(int) * JT_POOL_CH);
        }
        if (!st->jtDrvRing) {
            st->jtDrvRing = (double *)malloc(sizeof(double)
                                             * JT_ARING * JT_ABLK);
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

/* DRONE rows: control-thread setters (per-row scalar writes read by
   the jt tick — an aligned 8-byte store; a torn transition is inaudible
   and a lost onset under a simultaneous tick is a non-event).
   bow_poly_jt_pluck (gradual-attack rev) sets the decaying ONSET BOOST —
   the drive envelope swells toward level+boost, no impulse anywhere. */
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

/* MELODY FOLLOWER (Tarabdaar 2026-07-25): arm row `row` as the live-
   retuned follower. f0 = the row's builder frequency; t60/fHf/bst = the
   damping/inharmonicity law constants the retune re-applies (the
   builder's own). Call at engine build off the audio thread, or after
   bow_poly_jt_set_coeffs to refresh the constants — re-arming the SAME
   row keeps the current pitch (only the law is refreshed), so a live
   parameter reload never snaps the follower back to its build pitch.
   row < 0 disarms. */
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

/* The follower's pitch target (Hz) — the drone-setter contract: a plain
   aligned scalar store from any thread; the row's jt tick slews to it.
   Out-of-range values are clamped/ignored at the tick. */
void bow_poly_jt_track_target(void *vst, double hz)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || st->jtTrkRow < 0) return;
    if (hz > 0.0) st->jtTrkTarget = hz;
}

/* drone envelope times (seconds), call at engine build off the audio
   thread: attack/release slews of the drive envelope + the onset-boost
   decay. Non-positive values keep the load-time defaults. */
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

/* drone drive tone, call at engine build off the audio thread.
   lpHz/hpHz = the noise band-pass corners (sub-audio drive would
   wander the string against the jawari bone and pump the buzz).
   toneMix = the pitched fraction of the drive (0..1): each row is
   driven by a sine at its own mode-1 frequency mixed with the noise —
   1 = fully pitched, 0 = the first-rev pure-noise drive. Non-positive
   lp/hp and negative toneMix keep the load-time defaults. */
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

/* Legacy mono entry — the bit-exact path every golden runs. */
void bow_poly_process(void *vst, int n, int stride,
                      const double *f0, const double *vb, const double *fb,
                      const double *beta, const double *gate,
                      const double *xv, double *out)
{
    bow_poly_process2(vst, n, stride, f0, vb, fb, beta, gate, xv,
                      out, NULL);
}

/* Stereo entry (Tarabdaar 2026-07-23): outS = the SIDE stream (host does
   L = mid + side, R = mid - side — the L+R fold-down equals the mono
   out exactly). outS NULL or bow_poly_set_stereo never called = the
   legacy path, bit-exact. */
void bow_poly_process2(void *vst, int n, int stride,
                       const double *f0, const double *vb, const double *fb,
                       const double *beta, const double *gate,
                       const double *xv, double *out, double *outS)
{
    bow_poly_process3(vst, n, stride, f0, vb, fb, beta, gate, xv,
                      out, outS, NULL, NULL);
}

/* Split-bus entry (Tarabdaar FX, 2026-08-01): when outJt is non-NULL the
   modal-jawari post-pass ADDS into outJt/outJtS (kernel-zeroed here)
   instead of out/outS, so the host can process the voice and taraf
   buses separately. Every jt term lands in each sample exactly once,
   so host-side `out[t] + outJt[t]` reproduces the fused path's
   rounding bit-exactly — splitting is free, and outJt NULL is the
   verbatim legacy code path. */
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
    const double *stWp = st->stWebPan, *stSp = st->stSlotPan;
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

    /* Tarabdaar SITAR TWANG: self-disarm once a live 0 finished slewing —
       back to the zero-cost byte-null path — else derive the chunk's
       sitar-morph terminations from the slewed amount */
    if (st->twOn && st->twTgt <= 1e-9 && st->twCur < 1e-7) {
        st->twOn = 0;
        st->twCur = 0.0;
    }
    if (st->twOn)
        poly_twang_derive(st);
    for (int t = 0; t < n; t++) {
        double F = 0.0;
        double tdir = 0.0;
        double noiseDir = 0.0;
        /* Tarabdaar SITAR TWANG: ~30 ms amount slew (zipper-safe live
           moves; dead branch while disarmed) */
        if (st->twOn)
            st->twCur += st->twSl * (st->twTgt - st->twCur);
        /* Tarabdaar stereo side accumulators — DIRECT radiation only
           (dead when !stOn) */
        double tdirS = 0.0, noiseDirS = 0.0;
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
            double nd0 = noiseDir;
            F += poly_string_force(st, S, f0[o], vb[o], fb[o], beta[o],
                                   gate[o], &noiseDir,
                                   &rdmpArr[i], &gkArr[i]);
            /* the bow-contact noise sounds AT the played string's
               position; the string's bridge force radiates from the
               one central body and stays mid-only */
            if (stOn) noiseDirS += stSp[b] * (noiseDir - nd0);
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
                        ? st->jawRoll * st->jawG * jn[i] : 0.0;
                    st->rollD[i] += st->rollAv[i] * (tgt - st->rollD[i]);
                    if (st->rollD[i] > 3.0) st->rollD[i] = 3.0;
                } else if (jn[i] > 1e-9 && y > 0.0) {
                    if (st->jawRho > 1e-12) {
                        /* v3 collision fold (mono port) */
                        double e2 = y - jq2;
                        if (e2 > 0.0)
                            wv = y - st->jawG * jn[i] * (1.0 + st->jawRho) * e2;
                    } else {
                        double s = y / (y + jq2 + 1e-30);
                        wv = y * (1.0 - st->jawG * jn[i] * s);
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
                    yo = y + st->jawG * jw[i] * (r - jdc[i]);
                }
                vlp[i] = (1.0 - lpA[i]) * yo + lpA[i] * vlp[i];
                F += wout[i] * vlp[i];
                dwt[i] += (1.0 - aDuck) * (dtg[i] - dwt[i]);
                tdir += dwt[i] * twt[i] * wout[i] * vlp[i];
                if (stOn)
                    tdirS += stWp[i] * dwt[i] * twt[i]
                        * wout[i] * vlp[i];
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
        /* ---- TARABDAAR BODY-SIDE READOUT (2026-08-01): the second
           observation point — a separate residue sum over the SAME
           fresh mode outputs (after the loop above st->by1[k] holds
           this sample's y), so the hot loop and the mid readout are
           untouched. K MACs per sample when armed; byte-null off. */
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
                        ? st->jawRoll * st->jawG * jn[i] : 0.0;
                    st->rollD[i] += st->rollAv[i] * (tgt - st->rollD[i]);
                    if (st->rollD[i] > 3.0) st->rollD[i] = 3.0;
                } else if (jn[i] > 1e-9 && y > 0.0) {
                    if (st->jawRho > 1e-12) {
                        /* v3 collision fold (mono port) */
                        double e2 = y - jq2;
                        if (e2 > 0.0)
                            wv = y - st->jawG * jn[i] * (1.0 + st->jawRho) * e2;
                    } else {
                        double s = y / (y + jq2 + 1e-30);
                        wv = y * (1.0 - st->jawG * jn[i] * s);
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
                    yo = y + st->jawG * jw[i] * (r - jdc[i]);
                }
                vlp[i] = (1.0 - lpA[i]) * yo + lpA[i] * vlp[i];
                dwt[i] += (1.0 - aDuck) * (dtg[i] - dwt[i]);
                tdir += dwt[i] * twt[i] * wout[i] * vlp[i];
                if (stOn)
                    tdirS += stWp[i] * dwt[i] * twt[i]
                        * wout[i] * vlp[i];
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
        /* ---- TARABDAAR INSTRUMENT WIDTH (2026-08-01 unifying rev):
           the second observation point on the whole voice bus — the
           diffuse-field difference bank on the full pre-jt mid
           (bridge radiation + taraf direct + bow noise). The jt wash
           gets its own bank instance in the post-pass ([1]); by
           linearity the two together equal one bank on the complete
           instrument. Antisymmetric side — cancels exactly in the
           L+R fold-down; byte-null when unarmed. ---- */
        double radS = 0.0;
        if (stOn && st->stWidthOn) {
            st->stWidthCur += st->stWidthSl
                * (st->stWidthTgt - st->stWidthCur);
            radS = st->stWidthCur * poly_width_bank(st, 0, out[t]);
        }
        /* ---- STEREO SIDE (Tarabdaar): the pan-weighted taraf direct
           tap (through its own copy of the tdir shaping bank;
           linearity = radiating each string panned) + the bow noise
           at its string's position (both LEGACY staging, disarmed by
           default since the width unification — seeds 0) + the
           instrument-width side above. ---- */
        if (stOn) {
            double tradS = tdirS;
            if (tshape > 0.5) {
                tradS = c0 * tdirS;
                for (int k = 0; k < K; k++) {
                    double yS = bn0[k] * (tdirS - st->tsx2[k])
                        + ba1[k] * st->tsy1[k] + ba2[k] * st->tsy2[k];
                    st->tsx2[k] = st->tsx1[k]; st->tsx1[k] = tdirS;
                    st->tsy2[k] = st->tsy1[k]; st->tsy1[k] = yS;
                    tradS += bC[k] * yS;
                }
                tradS = tmix * tradS + (1.0 - tmix) * tdirS;
            }
            outS[t] = radS + tdirect * tradS + noiseDirS;
        }
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
    /* ---- Tarabdaar drive FX (2026-08-01): the host shapes the recorded
       drive BEFORE the web hears it — the voice→taraf insert. Runs on
       the render thread in both modes (async: before the job is
       published), so the hook's own DSP state stays single-threaded
       and in order. NULL hook = byte-null. ---- */
    /* ---- Tarabdaar sitar→taraf inject (2026-08-19): mix the other
       voice's ring into the recorded drive BEFORE the drive-FX hook,
       so the voice→taraf insert shapes it too. When this block's
       drive was dropped (jtFr NULL) the ring still advances, holding
       stream alignment; a gross backlog (a stalled consumer catching
       up, e.g. the jt web re-enabled) realigns to the freshest block
       instead of replaying seconds of stale drive. Empty ring or zero
       gain touches nothing — byte-null. ---- */
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
        if (st->jtPoolN < 2) {
            for (int t = 0; t < n; t++) {
                double F = jtFr[t];
                st->jtFdc += 2e-4 * (F - st->jtFdc);
                st->jtFacc += F - st->jtFdc;
                if (++st->jtPhase >= st->jtDiv) {
                    double Fd = st->jtFacc / st->jtDiv;
                    st->jtFacc = 0.0; st->jtPhase = 0;
                    double sacc = 0.0;
                    st->jtHold = jt_tick(st, st->jtFprev * st->jtDrv,
                                         jt_ev_step(st),
                                         stOn ? &sacc : NULL);
                    if (stOn) st->jtHoldS = sacc;
                    st->jtFprev = Fd;
                }
                double jv = st->jtGain * jt_lp_step(st, st->jtHold);
                jo[t] += jv;
                if (stOn) {
                    joS[t] += st->jtGain
                        * jt_lp_stepS(st, st->jtHoldS);
                    if (st->stWidthOn)
                        joS[t] += st->stWidthCur
                            * poly_width_bank(st, 1, jv);
                }
                if (F > st->jtFmax) st->jtFmax = F;
                if (-F > st->jtFmax) st->jtFmax = -F;
            }
        } else {
            const int nth = st->jtPoolN;
            double *fdv = st->jtFdv;
            double *evv = st->jtEvV;
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
                        evv[nT] = jt_ev_step(st);
                        tkv[nT] = t;
                        nT++;
                        st->jtFprev = Fd;
                    }
                    if (F > st->jtFmax) st->jtFmax = F;
                    if (-F > st->jtFmax) st->jtFmax = -F;
                }
                if (nT == 0) {
                    for (int t = 0; t < cn; t++) {
                        double jv = st->jtGain
                            * jt_lp_step(st, st->jtHold);
                        jo[c0 + t] += jv;
                        if (stOn) {
                            joS[c0 + t] += st->jtGain
                                * jt_lp_stepS(st, st->jtHoldS);
                            if (st->stWidthOn)
                                joS[c0 + t] += st->stWidthCur
                                    * poly_width_bank(st, 1, jv);
                        }
                    }
                    continue;
                }
                for (int th = 0; th < nth; th++) {
                    memset(hp + (size_t)th * JT_POOL_CH, 0,
                           sizeof(double) * (size_t)nT);
                    if (stOn && st->jtHpS)
                        memset(st->jtHpS + (size_t)th * JT_POOL_CH, 0,
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
                double hold = st->jtHold, holdS = st->jtHoldS;
                int ki = 0;
                for (int t = 0; t < cn; t++) {
                    if (ki < nT && t == tkv[ki]) {
                        double H = 0.0, HS = 0.0;
                        for (int th = 0; th < nth; th++) {
                            H += hp[(size_t)th * JT_POOL_CH + ki];
                            if (stOn && st->jtHpS)
                                HS += st->jtHpS[(size_t)th
                                                * JT_POOL_CH + ki];
                        }
                        hold = H;
                        holdS = HS;
                        ki++;
                    }
                    double jv = st->jtGain * jt_lp_step(st, hold);
                    jo[c0 + t] += jv;
                    if (stOn) {
                        joS[c0 + t] += st->jtGain
                            * jt_lp_stepS(st, holdS);
                        if (st->stWidthOn)
                            joS[c0 + t] += st->stWidthCur
                                * poly_width_bank(st, 1, jv);
                    }
                }
                st->jtHold = hold;
                st->jtHoldS = holdS;
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
        free(st->jtEvV);
        free(st->jtHp); free(st->jtHpS);
        free(st->sjRing);
        free(st->jtDrvRing); free(st->jtWebRing);
        free(st->jtWebRingS);
        free(st->jtM); free(st->jtMOff); free(st->jtZOff);
        free(st->jtCa); free(st->jtCb); free(st->jtCa4); free(st->jtCb4);
        free(st->jtWd); free(st->jtWdI);
        free(st->jtPhiO); free(st->jtPhiD);
        free(st->jtPhiU); free(st->jtPhiF); free(st->jtB);
        free(st->jtG); free(st->jtG4); free(st->jtGd); free(st->jtGd4);
        free(st->jtQ); free(st->jtP);
        free(st->jtDnTgt); free(st->jtDnEnv); free(st->jtDnBoost);
        free(st->jtDnLp); free(st->jtDnLp2); free(st->jtDnRng);
        free(st->jtDnPh);
        free(st->jtGovEnv);
        free(st->jtGateFdEps); free(st->jtGateCnt); free(st->jtGateSlp);
        free(st->jtDwTgt); free(st->jtDwCur);
    }
    free(st->L);
    free(st->cs); free(st->cp); free(st->w0); free(st->w1); free(st->w2);
    free(st->w3); free(st->w4); free(st->g); free(st->lpA); free(st->wout);
    free(st->kap); free(st->alphaw); free(st->jw); free(st->jl);
    free(st->jn); free(st->zdrv); free(st->zi); free(st->twt);
    free(st->ba1); free(st->ba2); free(st->bn0); free(st->bA); free(st->bC);
    free(st->fv); free(st->dwt); free(st->dtg);
    free(st->stWebPan); free(st->stSlotPan); free(st->stJtPan);
    free(st->off); free(st->arena); free(st->widx); free(st->vx1);
    free(st->vx2); free(st->vlp); free(st->jdc); free(st->jenv);
    free(st->sv);
    free(st->rollD);
    free(st->rollE);
    free(st->rollAv);
    free(st->strs); free(st->proc);
    free(st);
}
