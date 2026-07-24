/* Swift twin of src/bowstring.py C_SRC — DO NOT EDIT BY HAND beyond the
   render -> bow_kernel_render symbol rename. Regenerate with
   scripts/sync_bow_kernel.py. The -O3 build + the vectorize-disable
   pragma + stack staging are BYTE-PARITY guards — they must survive every
   sync (memory: swift-bow-port). */

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif

#define MAXBOW 4096

static double frac_read(const double *buf, int n, int w, double delay) {
    double rp = (double)w - delay;
    while (rp < 0) rp += n;
    int i0 = (int)rp;
    double fr = rp - i0;
    int i1 = (i0 + 1) % n;
    return buf[i0 % n] * (1.0 - fr) + buf[i1] * fr;
}

/* Full coupled network + MSW bow, per sample.
   voices: nv web combs (taraf + played), arena ring buffers.
   voice drive_i = kap[i]*Vprev + alpha_w[i]*xv[t]   (alpha_w != 0 only for
   the played combs).  F = pgain*onepole(xv) + bowW*2Z*brLp + sum w_i*y_i.
   body: K modal sections, two taps (admittance A -> V, radiation C -> out),
   yinf DC-blocked.  bow string: two-segment velocity waveguide + hyperbolic
   friction, reflected bridge wave gets kret*V.
   passive > 0.5 (N_junction "passive"): the kappa return is replaced by the
   physical wave junction — comb drive alphaw*xv - zdrv*V, string force on
   the bridge f_i = y_i + zi*V, solved DELAY-FREE per sample (see the pass-1
   block; the FFT twin is coupled.junction_solve).

   STREAMING SPLIT (2026-07-09, live-port groundwork): every piece of
   cross-sample state — ring buffers and their write indices, filter
   states, envelopes, the rosin temperatures, the noise LCG — lives in
   bow_state_t; bow_init() allocates + pre-charges it (deep-copying every
   table so the caller may free its arrays), bow_process() runs the
   per-sample loop over one chunk (controls indexed CHUNK-relative; the
   loop has no absolute-time dependence — audited: `t` only indexes the
   control/out arrays), bow_free() releases it.  render() — the one-shot
   legacy entry point — is init -> process(n) -> free and is BIT-IDENTICAL
   to the pre-streaming monolith (the loop body is verbatim; scalar state
   is staged through locals exactly as before). */

typedef struct {
    /* --- static config (deep copies; C owns the memory) --- */
    double sr;
    int nv;
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
    /* gut-string physics (2026-07-14): broadband per-round-trip loss,
       dispersion cascade count, nail-termination position exponent and
       the open-string reference pitch (all null at gutG=1/dispN=1/
       nailK=0 -> bit-identical legacy render) */
    double gutG, dispN, nailK, f0Open;
    /* second termination pole (gut internal loss grows ~f^2, not the
       one-pole's 6 dB/oct — the 8-16k hiss survived moderate corners):
       applied to the REFLECTION path only (the loop), NOT the bridge
       force out (transmitted keeps its brightness). 0 = off/legacy. */
    double gutA2;
    /* DRIVEN-UNISON TAP DUCK (2026-07-15, the loud-Pa bloom): a taraf
       string bowed AT a partial coincidence (h*f0 ~= k*f_i) reaches a huge
       driven steady state; the junction radiates that response correctly,
       but the direct tap re-radiated it +12-16 dB over the target (the tap
       exists for the FREE ring the junction cannot radiate). While the bow
       is on and a voice sits within ~30 c of a coincidence, its tap weight
       ducks toward tuw (1.0 = off/legacy, bit-null); on release the full
       tap returns, so the after-stroke bloom ring is untouched. In-loop
       force F never ducks (zero loop change). */
    double tuw;
    /* TORSIONAL WAVE LOOP (2026-07-16j, the source-spectrum round): slip
       at the contact excites the string's TORSIONAL wave (c_tors ~ 5x
       transverse); it returns after a short round trip and perturbs the
       contact velocity -> SECONDARY micro-slips = period-locked harmonic
       HF regeneration (structured, not noise). torsC = 0 is BIT-NULL
       (whole block skipped, state untouched). */
    double torsRatio, torsG, torsC;
    double bufT[MAXBOW];
    int wti;
    /* RATE-AND-STATE CONTACT AGING (2026-07-17g, slip-synchronization):
       static grip GROWS with stick time (Dieterich-Ruina aging / rosin
       contact re-adhesion) — a freshly-slipped contact is WEAK, so
       micro-slips cluster INTO the slip phase; a mid-period perturbation
       meets a fully-aged strong contact and is suppressed = slip events
       collect at ONE phase per period (period-locked spectrum; built
       against the measured ~3 dB inter-harmonic hash floor the taraf-off
       ablations could not move). ageDef = current strength DEFICIT: set
       to ageA at every slip (and while unloaded — a re-placed bow lands
       fresh), decaying toward 0 by ageDk per stick sample. ageA = 0 is
       BIT-NULL (every touch point branch-gated). */
    double ageA, ageDk;
    double ageDef, ageDef3[3];
    /* CREMER CORNER ROUNDING (2026-07-18f, the quiet-bloom diff cell):
       the Helmholtz corner SHARPENS with bow force — at low force the
       slip pulse rounds and the spectrum collapses to a warm core (the
       real instrument's quiet playing is DARK; ours blazed +10..24 dB
       broadband). v0_eff = v0 · (v0Ref / max(Fb, 0.05))^v0Pow applied in
       the friction mu curve of both branches. v0Pow = 0 is BIT-NULL. */
    double v0Pow, v0Ref;
    /* HAIR COMPLIANCE (2026-07-19c, the quiet-raspberry round): the bow
       hair is a compliant ribbon — friction force transmits THROUGH the
       hair spring, a FORCE-DEPENDENT low-pass (corner = hairHz·Fb/hairRef):
       at low force compliance dominates (heavy smoothing of micro-slip
       force = the clean pianissimo of a real bow), pressed = stiff =
       intact. Applied to the transmitted force in both branches;
       hairHz <= 0 is BIT-NULL. */
    double hairHz, hairRef;
    double hairLp, hairLp3[3];
    /* CONTINUUM-RELEASE CONTACT (2026-07-19d, the raspberry root cause):
       the ~1 cm hair band is a CONTINUUM of contacts with DISTRIBUTED
       local grip limits (normal-force profile across the ribbon + hair
       diversity), so stick->slip is PROGRESSIVE, never a switch. crS =
       stuck fraction of the band, relaxing toward the equilibrium
       fraction s_eq(|stickF|/grip) — a smoothstep over [1-crW, 1+crW] —
       with per-sample coefficient crAt (release-front crossing time
       crMs ~ band width / transverse wave speed). Blended force
       F = crS*stickF + kineticSolve(dv0*(1-crS), Fb*(1-crS)): exactly
       the same Newton solve with offset and force scaled, so the
       branches join continuously (at the release point the kinetic
       curve at dv->0 equals the grip force). WHY it darkens pianissimo
       only: quiet playing HOVERS the demand at the grip edge (Schelleng-
       minimum region), where a binary switch chatters between branch
       solutions at sample rate — the measured FLAT quiet spectrum
       (0/-1/-1/-9 vs target 0/-7/-12/-21) and the ablation-immune
       inter-harmonic hash floor. The blend replaces chatter with a
       smooth intermediate force; deep stick and deep slip (forte
       Helmholtz) satisfy s_eq in {1,0} and are untouched.
       crW = 0 AND crMs = 0 is BIT-NULL (every touch point branch-gated). */
    double crW, crAt;
    double crS, crSB, crS3[3];
    /* JAWARI COLLISION MODE (2026-07-20): restitution of the v3
       elastic-fold contact; 0 = the legacy smooth compressor,
       byte-exact. */
    double jawRho;
    /* ROLLING CONTACT v2 (2026-07-20, toy-proven): jawRoll = wrap
       depth in samples (0 = OFF, byte-exact legacy); jawRollAmp = the
       contact THRESHOLD as a fraction of the voice's peak envelope —
       the string touches the curved bridge only near its displacement
       EXTREME (brief, phase-locked, ~2 ms events). Continuous
       modulation SMEARS the ring (PM sidebands, the ear's 'HF noise');
       slow drift is linear and cannot bloom; brief contact events
       scatter energy BETWEEN partials = the tanpura's mid-decay
       harmonic bloom (toy: h6 +5 dB two windows into the ring).
       rollD = current wrap (2 ms attack/release, one-sample lag);
       rollE = per-voice peak-tracking envelope. While jawRoll > 0 the
       amplitude jawari laws (compressor/fold) are BYPASSED. */
    double jawRoll, jawRollAmp;
    /* Starpad TILT purity: runtime web-jawari BUZZ scale (multiplies
       the buzz sources jn/jw at their engagement sites; the jl in-loop
       LOSS stays full — it self-limits hot rings, and un-damping it
       made half-purity buzz HARDER than base. 1.0 = byte-exact).
       Control/render-thread scalar write (drone-setter contract). */
    double jawG;
    double *rollD, *rollE, *rollAv;
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
    /* Starpad jt tone LP (2026-07-23): one-pole on the radiated jt sum,
       armed by bow_jt_set_lp (NOT part of the load ABI — python-parity
       twins never arm it). jtLpA <= 0 = bypass, bit-exact legacy path. */
    double jtLpA, jtLpY;
    /* Starpad TILT axes (2026-07-23 evening): runtime taraf purity +
       decay, control-thread-written scalars read by the jt tick (the
       drone-setter contract). jtLift = bone drop in displacement units
       (0 = byte-exact contact; jtLiftRef = load-time max static
       penetration, the setter's unit). jtDampMul = per-tick momentum
       multiplier for extra taraf decay (0 or >= 1 = off). */
    double jtLift, jtLiftRef, jtDampMul;
    double *jtQ, *jtP;            /* modal state, concat modes */
    double jtFprev, jtFmax, jtPenMax;   /* + telemetry */
    /* ---- WAVEGUIDE JAWARI strings (2026-07-21e, the fast
       reformulation): velocity-wave DWG per string (circular rails,
       O(1) propagation — mode count is free), one-pole loop damping
       fit to the modal t60 law + Thiran fractional tuning, contact
       zone = the natural delay cells under the bone with LOCAL
       within-step compliance (kloc = dt/Z0 — per-point Newton, no
       coupling solve). The modal jt block above stays the offline
       reference twin; this is the live formulation. njw == 0 or
       jwGain == 0 = BYTE-NULL. Layout: one arena for all rails;
       per-string slices. */
    int njw, jwR, jwTot;          /* strings, subticks/sample, nodes */
    int *jwN, *jwOff, *jwOi;      /* cells, node offset, obs node */
    double *jwLam2, *jwMuk, *jwS1h, *jwA0, *jwB0, *jwKloc, *jwFdrv,
        *jwGainRow, *jwOfrac, *jwKcRow;
    double *jwB;                  /* bone plane (-1 = no bone) */
    double *jwU;                  /* 3-plane arena: u, uprev, d2prev */
    double jwKc, jwAlpha, jwHcB, jwGain, jwDrv;
    double jwFprev, jwFdc;
    double jwPenMax;              /* running max dynamic penetration —
                                     probe parity with jt's jtPenMax
                                     (a current-state-only read probes
                                     the ring-down, not the passage) */
    /* ---- jt worker POOL (2026-07-21 night) ----
       persistent high-QoS workers for the block-parallel post-pass:
       spawned OFF the audio thread (bow_jt_set_threads at engine
       build, or bow_jt_load's env read for offline), condvar handoff
       per chunk, fixed string partition + fixed-order reduction =
       deterministic for a given worker count.  jtPoolN < 2 = the
       serial replay (bit-exact vs the historical inline). */
    int jtNth, jtPoolN, jtPoolInit, jtGen, jtDone, jtQuit;
    pthread_t jtTid[16];
    pthread_mutex_t jtMx;
    pthread_cond_t jtCvW, jtCvD;
    int jtWnT, jtWPer;
    double jtWPen[16];
    double *jtFrBuf; int jtFrCap;
    double *jtFdv; int *jtTkv; double *jtHp;
    struct { void *st; int idx; } jtParg[16];
    double jtFdc;                 /* drive DC tracker (~50 ms) —
        the bowed bridge force carries the STATIC bow reaction;
        bridge rocking transmits AC only, and DC on a grazing
        bone is a deep-press linearizer (the grazing-knee law) */
    /* ---- jt DRONE rows (2026-07-23): press-to-sound taraf ----
       per-row control-thread-written scalars read by the jt tick:
       a pending pluck (one-shot momentum kick via phiD) and a
       sustained filtered-noise drive target, slewed (~20 ms) so
       press/release never click.  All-zero is BYTE-NULL (the tick
       guards the whole branch — goldens untouched). */
    double *jtDnTgt, *jtDnEnv, *jtDnBoost, *jtDnLp, *jtDnLp2;
    unsigned long long *jtDnRng;
    double jtDnA;                 /* release slew coeff (jt tick rate) */
    double jtDnAAtk;              /* attack slew coeff (jt tick rate) */
    double jtDnBDec;              /* onset-boost decay per jt tick */
    double jtDnALp, jtDnALp2;     /* noise band-pass coeffs (~25 Hz–2 kHz):
                                     sub-audio drive would wander the string
                                     against the jawari bone and pump the
                                     buzz (audible slow tremolo) */
    double *fv;              /* per-voice fundamental (from L, ~1%) */
    double *dwt, *dtg;       /* per-voice duck state / target */
    double nutLp2, brLp2;
    /* --- derived constants (computed once, same op order as legacy) --- */
    double hpG, jy0, jzsum, jden;
    int psv;
    /* --- cross-sample state (everything the loop carries) --- */
    int *off;              /* voice ring arena */
    double *arena;
    int *widx;
    double *vx1, *vx2, *vlp, *jdc, *jenv;
    double *sv;            /* state-only comb output (passive pass-1 cache;
                              per-sample scratch, kept here to avoid
                              per-chunk allocation) */
    double venv;           /* bridge-velocity field envelope */
    /* body state */
    double bx1[96], bx2[96], by1[96], by2[96];
    /* second W instance for the taraf direct-radiation path */
    double tx1[96], tx2[96], ty1[96], ty2[96];
    double hpY, hpX1;
    /* bow state */
    double buf1[MAXBOW], buf2[MAXBOW];
    double bufAB[64], bufBA[64];   /* inter-contact segment */
    int wab, wba;
    /* Pitteroff v2: A-M-B chain, two independent segments */
    double bufAM[64], bufMA[64];
    double bufMB[64], bufBM[64];
    int wam, wma, wmb, wbm;
    int w1i, w2i;
    double nutLp, brLp, pLp, vRet, vRet2;
    double disp;           /* leaky bridge displacement (integral of V) */
    double apXs[4], apYs[4];   /* bow-string stiffness dispersion allpass
                                  cascade (dispN stages; stage 0 == the
                                  legacy apX1/apY1) */
    unsigned long long lcg;  /* noise RNG state (seeded; parity-excluded
                                noise path, project convention) */
    double nz1, nz2;       /* contact-noise band shaping */
    double nz1b, nz2b;     /* direct-radiation noise: own 2-pole top */
    double tEnv, fbPrev;   /* transition (bow-change) activity */
    double Tr3[3];         /* per-hair-group rosin temperature:
       a bow is an ENSEMBLE of contacts — hair-property diversity
       desynchronizes the thermal relaxation oscillation (the graded form
       of the subcritical cliff measured on the single-contact model) */
    double Vprev;
    double kGate;          /* bow-force envelope gating the bridge return
       (kret).  The friction is the ONLY energy source: a lifted bow leaves
       a strictly PASSIVE string, so the bridge-mobility coupling that
       returns V into the string must switch OFF when the bow stops driving.
       Without this the tonic-tuned (near-lossless) bow string, fed by the
       ringing taraf through V, re-pumped its own harmonic post-release and
       grew without bound (energy created from nothing). */
} bow_state_t;

static double *dup_d(const double *a, int n) {
    double *b = (double *)malloc(sizeof(double) * (n > 0 ? n : 1));
    memcpy(b, a, sizeof(double) * (size_t)n);
    return b;
}

/* continuum contact: equilibrium stuck fraction of the hair band at
   demand ratio x = |stickF|/grip. w = 0 degenerates to the binary
   stick test (x <= 1), keeping the null path's exact decision. */
static double cr_seq(double x, double w) {
    if (w <= 1e-12) return x <= 1.0 ? 1.0 : 0.0;
    if (x <= 1.0 - w) return 1.0;
    if (x >= 1.0 + w) return 0.0;
    double u = (1.0 + w - x) / (2.0 * w);
    return u * u * (3.0 - 2.0 * u);
}

/* CURVED-BRIDGE ROLLING CONTACT (2026-07-20): the jawari read — the
   voice's 5-tap feedback group shifted SHORTER by the current wrap
   rollD (integer part = tap-group shift, fractional part = crossfade
   between adjacent shifts). Delay modulation only: the circulating
   amplitude is never scaled, so the contact is lossless by
   construction (the amplitude-contact law: any amplitude-domain
   contact drains a free comb; a rolling termination cannot). */
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

void *bow_init(double sr,
               /* voices */
               int nv, const int *L, const double *cs, const double *cp,
               const double *w0, const double *w1, const double *w2,
               const double *w3, const double *w4, const double *g,
               const double *lpA, const double *wout, const double *kap,
               const double *alphaw, const double *jw, const double *jl,
               const double *jn, const double *chg,
               const double *zdrv, const double *zi, const double *twt,
               /* body */
               int K, const double *ba1, const double *ba2, const double *bn0,
               const double *bA, const double *bC, double yinf, double c0,
               double dcRho,
               /* voice-force path + bow */
               double pgain, double pA, double bowW, double kret, double retA,
               double retMode, double rb0, double ra1, double ra2,
               double kdisp, double bowWidth, double bowCont,
               double Z, double Zt,
               double mu_s, double mu_d, double v0f, double nutA, double brA,
               double thLeak, double thA, double thD, double thFloor,
               double bowDisp, double jq, double jq2, double zload,
               double tdirect, double tshape, double tmix, double nA,
               double nT, double nPow, double nzHi, double nzLo,
               double nDir, double nzHiD, double passive,
               double gutG, double dispN, double nailK, double f0Open,
               double gutA2, double tdirUni,
               double torsRatio, double torsG, double torsC,
               double ageAp, double ageMs,
               double v0Powp, double v0Refp,
               double hairHzp, double hairRefp,
               double crWp, double crMsp,
               double jawRhop, double jawRollp, double jawRollAmpp)
{
    bow_state_t *st = (bow_state_t *)calloc(1, sizeof(bow_state_t));
    st->sr = sr; st->nv = nv; st->K = K > 96 ? 96 : K;
    st->L = (int *)malloc(sizeof(int) * (nv > 0 ? nv : 1));
    memcpy(st->L, L, sizeof(int) * (size_t)nv);
    st->cs = dup_d(cs, nv);    st->cp = dup_d(cp, nv);
    st->w0 = dup_d(w0, nv);    st->w1 = dup_d(w1, nv);
    st->w2 = dup_d(w2, nv);    st->w3 = dup_d(w3, nv);
    st->w4 = dup_d(w4, nv);    st->g = dup_d(g, nv);
    st->lpA = dup_d(lpA, nv);  st->wout = dup_d(wout, nv);
    st->kap = dup_d(kap, nv);  st->alphaw = dup_d(alphaw, nv);
    st->jw = dup_d(jw, nv);    st->jl = dup_d(jl, nv);
    st->jn = dup_d(jn, nv);    st->zdrv = dup_d(zdrv, nv);
    st->zi = dup_d(zi, nv);   st->twt = dup_d(twt, nv);
    st->fv = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    st->dwt = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    st->dtg = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    for (int i_ = 0; i_ < nv; i_++) {
        st->fv[i_] = sr / (double)(L[i_] > 2 ? L[i_] : 2);
        st->dwt[i_] = 1.0;
        st->dtg[i_] = 1.0;
    }
    st->ba1 = dup_d(ba1, K);   st->ba2 = dup_d(ba2, K);
    st->bn0 = dup_d(bn0, K);   st->bA = dup_d(bA, K);
    st->bC = dup_d(bC, K);
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
    st->hairHz = hairHzp; st->hairRef = (hairRefp > 1e-6 ? hairRefp : 1.0);
    st->crW = crWp;
    st->crAt = crMsp > 1e-6
        ? 1.0 - exp(-1.0 / (crMsp * 1e-3 * sr)) : 1.0;
    st->crS = 1.0; st->crSB = 1.0;
    st->crS3[0] = st->crS3[1] = st->crS3[2] = 1.0;
    st->jawRho = jawRhop;
    st->jawRoll = jawRollp;
    st->jawRollAmp = (jawRollAmpp > 1e-9 ? jawRollAmpp : 1e-9);
    /* Starpad TILT purity: runtime scale on the web voices' jawari
       depths (jn/jl/jw). 1.0 = byte-exact legacy (x*1.0 is IEEE-
       exact); the host slews it at chunk rate. */
    st->jawG = 1.0;
    st->ageDef = ageAp;
    st->ageDef3[0] = st->ageDef3[1] = st->ageDef3[2] = ageAp;
    /* voice ring arena */
    st->off = (int *)malloc(sizeof(int) * (nv + 1));
    int tot = 0;
    for (int i = 0; i < nv; i++) { st->off[i] = tot; tot += L[i] + 8; }
    st->off[nv] = tot;
    st->arena = (double *)calloc(tot, sizeof(double));
    /* PRE-CHARGE (2026-07-07n): the recordings are mid-performance
       excerpts — every string carries residual ring from minutes of prior
       playing (hundreds of broadband transient kicks; narrow ~0.05 Hz
       resonances integrate them). Initial condition, not target-peeking:
       a raised-cosine "recently kicked" bump in each delay line rings the
       string's own partial series and decays with its true t60. */
    for (int i = 0; i < nv; i++) {
        if (chg[i] > 1e-12) {
            int len = L[i] + 8;
            int W = len / 6 > 8 ? len / 6 : 8;
            double *b = st->arena + st->off[i];
            for (int k = 0; k < W && k < len; k++)
                b[k] = chg[i] * 0.5 * (1.0 - cos(6.283185307179586 * k / W));
        }
    }
    st->widx = (int *)calloc(nv, sizeof(int));
    st->vx1 = (double *)calloc(nv, sizeof(double));
    st->vx2 = (double *)calloc(nv, sizeof(double));
    st->vlp = (double *)calloc(nv, sizeof(double));
    st->jdc = (double *)calloc(nv, sizeof(double));
    st->jenv = (double *)calloc(nv, sizeof(double));
    st->sv = (double *)calloc(nv, sizeof(double));
    st->rollD = (double *)calloc(nv, sizeof(double));
    st->rollE = (double *)calloc(nv, sizeof(double));
    /* per-voice contact rate: the brief-contact event must resolve
       WITHIN the voice's period (a fixed ms constant exceeds the
       period above ~500 Hz and averages the events away — measured):
       tau_i = 0.15 * period_i */
    st->rollAv = (double *)malloc(sizeof(double) * (nv > 0 ? nv : 1));
    for (int i_ = 0; i_ < nv; i_++) {
        double tau = 0.15 * (double)(L[i_] > 2 ? L[i_] : 2);
        st->rollAv[i_] = 1.0 - exp(-1.0 / (tau > 1.0 ? tau : 1.0));
    }
    st->venv = 1e-6;   /* bridge-velocity field envelope */
    st->hpG = 0.5 * (1.0 + dcRho);
    /* PASSIVE JUNCTION constants: the body admittance chain has
       instantaneous feedthrough jy0 = yinf*hpG + sum_k bA_k*bn0_k (V's
       same-sample linear response to F), and the strings load the bridge
       with jzsum = sum_i zi_i.  The per-sample implicit solve
       V = (Vstate + jy0*F0)/(1 + jy0*jzsum) is EXACT (all instantaneous
       V-dependence is linear with constant coefficients) — a one-sample-
       delayed -Z*V is not guaranteed stable here (|Y*Zsum| peaks ~3 at the
       calibrated Z; the delay-free junction is structurally passive). */
    st->psv = passive > 0.5;
    double jy0 = yinf * st->hpG;
    double jzsum = 0.0;
    for (int k = 0; k < K; k++) jy0 += bA[k] * bn0[k];
    for (int i = 0; i < nv; i++) jzsum += zi[i];
    st->jy0 = jy0;
    st->jzsum = jzsum;
    st->jden = 1.0 + jy0 * jzsum;
    st->lcg = 0x9E3779B97F4A7C15ULL;
    /* every remaining state field (ring buffers, body/bow filter states,
       write indices, envelopes, Tr3, Vprev) is zero from calloc — exactly
       the legacy locals' = {0} initializers */
    return (void *)st;
}

/* modal-jawari table loader: call AFTER bow_init, before processing.
   Concatenated layouts — modes: ca/cb/ca4/cb4/wd/phiO/phiD (sum of M_i);
   zone matrices phiU/phiF: per-string M_i*J row-major [mode][zone]
   (phiF carries wj/MU folded, phiD carries drive-point/MU folded);
   b/gd/gd4: J per string; G/G4: J*J per string.
   phys = [kc, alpha, hcB, deep, gain, drive]. */
static float *dup_f(const double *a, int n)
{
    float *o = (float *)malloc(sizeof(float) * (size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) o[i] = (float)a[i];
    return o;
}

void bow_jt_set_threads(void *vst, int nth);
static int jt_env_threads(void);

static double jt_maxpen(int M, int J, const float *phiU,
                        const float *b_, const double *q);

void bow_jt_load(void *vst, int njt, int J, const int *M,
                 const double *ca, const double *cb,
                 const double *ca4, const double *cb4,
                 const double *wd, const double *phiO, const double *phiD,
                 const double *phiU, const double *phiF,
                 const double *b, const double *G, const double *G4,
                 const double *gd, const double *gd4, const double *phys,
                 const double *q0)
{
    bow_state_t *st = (bow_state_t *)vst;
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
    st->jtCa = dup_d(ca, mtot);   st->jtCb = dup_d(cb, mtot);
    st->jtCa4 = dup_d(ca4, mtot); st->jtCb4 = dup_d(cb4, mtot);
    st->jtWd = dup_d(wd, mtot);
    st->jtWdI = (double *)malloc(sizeof(double) * mtot);
    for (int i = 0; i < mtot; i++) st->jtWdI[i] = 1.0 / wd[i];
    st->jtPhiO = dup_d(phiO, mtot); st->jtPhiD = dup_d(phiD, mtot);
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
    st->jtQ = dup_d(q0, mtot);    /* settled static wrap (builder) */
    st->jtP = (double *)calloc(mtot, sizeof(double));
    st->jtFprev = 0.0;
    /* drone rows: all-off (byte-null) until bow_jt_drone/pluck */
    st->jtDnTgt = (double *)calloc(njt, sizeof(double));
    st->jtDnEnv = (double *)calloc(njt, sizeof(double));
    st->jtDnBoost = (double *)calloc(njt, sizeof(double));
    st->jtDnLp = (double *)calloc(njt, sizeof(double));
    st->jtDnLp2 = (double *)calloc(njt, sizeof(double));
    st->jtDnRng = (unsigned long long *)malloc(sizeof(unsigned long long)
                                               * (size_t)njt);
    for (int s = 0; s < njt; s++)
        st->jtDnRng[s] = 0x9E3779B97F4A7C15ULL * (unsigned long long)(s + 1);
    {
        double dtj = (double)st->jtDiv / st->sr;
        st->jtDnA = 1.0 - exp(-dtj / 0.060);
        st->jtDnAAtk = 1.0 - exp(-dtj / 0.040);
        st->jtDnBDec = exp(-dtj / 0.200);
        st->jtDnALp = 1.0 - exp(-2.0 * 3.14159265358979 * 2000.0 * dtj);
        st->jtDnALp2 = 1.0 - exp(-2.0 * 3.14159265358979 * 25.0 * dtj);
    }
    /* tilt-axis reference: the deepest static wrap across strings
       (floor jtDeep) — the unit bow_jt_set_lift scales to clear the
       bone at full purity. Axes start off (byte-null). */
    st->jtLift = 0.0; st->jtDampMul = 0.0;
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
    /* offline worker opt-in (env); the app calls bow_jt_set_threads
       itself at engine build — both happen OFF the audio thread */
    bow_jt_set_threads(vst, jt_env_threads());
}

#define JW_MAXN 1400
#define JT_MAXM 72
#define JT_MAXJ 44

/* the implicit contact solve (tanpura_modal.contact_force, FLOAT +
   HERTZIAN FAST PATH): vector Newton on the diagonal compliance inside
   an UNDER-RELAXED off-diagonal lag loop; projection cap c/gd. When
   alpha == 1.5 (Hertz sphere-on-plane — the live default) every pow
   collapses to sqrtf; other alphas keep powf (offline exploration).
   Loops are written for clang auto-vectorization (float NEON). */
/* solver telemetry (diagnosis; ~zero cost — a handful of adds per
   solve): [0] solves, [1] outer iters, [2] converged exits,
   [3] active-point sum at exit, [4] no-contact skips */
static double JT_STATS[6];

/* x^A for x in (1e-12, ~0.05], A in (0,1) — pure-arithmetic
   log2/exp2 (bit casts + minimax polys, floorf only; NO libm powf,
   so the bits are platform-identical, unlike libm).  Composed rel
   err <= 2.3e-4 over the full eta range — three orders inside the
   solve's partial-convergence slack (measured: the 1e-4 exit never
   fires; powf owned ~33% of the web cost at the ratified J16). */
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
    if (!any) { JT_STATS[4] += 1.0; return 0; }
    JT_STATS[0] += 1.0;
    const int hertz = (alpha > 1.499f && alpha < 1.501f);
    /* ACTIVE-SET matvec (2026-07-21j): measured at the ratified
       render op only ~2 of 16 zone points carry force at exit, so
       the cross-compliance sum is ~87% exact-zero terms — iterate
       the nonzero-F columns only.  Algebraically identical (F[k] is
       EXACTLY 0.0f off the active set; only float summation order
       moves — the solver's 8-iteration partial-convergence law is
       untouched).  F starts all-zero, so iteration 0 has an empty
       list and gf = 0 exactly, as before. */
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
           skipped points held f=0 already and the per-point math and
           ascending order are unchanged — measured ~68 of 80 inner
           iterations were branch-and-continue waste, and jt_core owns
           84% of the render) */
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
        JT_STATS[1] += 1.0;
        if (dF < 1e-4f * fm) {
            for (int j = 0; j < J; j++) F[j] = f[j];
            JT_STATS[2] += 1.0;
            break;
        }
        for (int j = 0; j < J; j++) F[j] += 0.5f * (f[j] - F[j]);
        na = 0;
        for (int j = 0; j < J; j++)
            if (F[j] > 0.0f) act[na++] = j;
    }
    for (int j = 0; j < J; j++)
        if (F[j] > 0.0f) JT_STATS[3] += 1.0;
    return 1;
}

void bow_jt_solve_stats(double *out6)
{
    for (int i = 0; i < 6; i++) {
        out6[i] = JT_STATS[i];
        JT_STATS[i] = 0.0;
    }
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
    /* project only the ACTIVE force columns (measured ~2 of J at the
       render op — the rest are exactly 0.0f and contribute nothing) */
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
/* per-string advance — the threading unit (2026-07-21k): everything
   here touches only string s's state slices + shared read-only
   tables, so strings can run concurrently given the same drive.
   penmax accumulates locally (merged by the caller — no shared-state
   writes from worker threads). */
static double jt_tick_string(bow_state_t *st, int s, double Fd,
                             double *penmax)
{
    const int J = st->jtJ;
    const double dtj = (double)st->jtDiv / st->sr;
    {
        const int Ms = st->jtM[s];
        const int mo = st->jtMOff[s], zo = st->jtZOff[s];
        double *q = st->jtQ + mo, *p = st->jtP + mo;
        /* DRONE row (2026-07-23, gradual-attack rev): the whole
           excitation is a slewed filtered-noise drive — NO impulse.
           The envelope eases toward (hold target + onset boost) with
           the attack coefficient and falls with the release one; the
           boost (set by bow_jt_pluck at press) decays over a few
           hundred ms, so the onset is a swell that relaxes into the
           sustain. The string is the resonator — only its modal
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
                /* band-passed drive (~25 Hz–2 kHz): sub-audio content
                   would push the string quasi-statically against the
                   jawari bone and pump the buzz (slow tremolo) */
                double lp = st->jtDnLp[s];
                lp += st->jtDnALp * (w - lp);
                st->jtDnLp[s] = lp;
                double lp2 = st->jtDnLp2[s];
                lp2 += st->jtDnALp2 * (lp - lp2);
                st->jtDnLp2[s] = lp2;
                Fd += env * (lp - lp2);
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
        /* Starpad TILT: bone lift (taraf-purity axis) — the jawari
           bone drops jtLift below its profile, penetration shrinks
           toward zero and the string rings as a PURE modal taraf
           (contact solve early-outs — cheaper, not costlier).
           0 = the byte-exact legacy contact. Read once per tick
           (control-thread-written aligned double — drone contract). */
        const float lift = (float)st->jtLift;
        float bl[JT_MAXJ];
        const float *bc_ = b_;
        if (lift > 0.0f) {
            for (int j = 0; j < J; j++) bl[j] = b_[j] - lift;
            bc_ = bl;
        }
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
        /* Starpad TILT: extra taraf decay — momentum-proportional loss
           per tick (velocity damping: amplitude e^{-t/tau}, the static
           wrap p = 0 untouched). 0 or >= 1 = off (byte-exact). */
        const double dampm = st->jtDampMul;
        if (dampm > 0.0 && dampm < 1.0)
            for (int k = 0; k < Ms; k++) p[k] *= dampm;
        double yjt = 0.0;
        for (int k = 0; k < Ms; k++)
            yjt += st->jtPhiO[mo + k] * p[k];
        return yjt;
    }
}

static double jt_tick(bow_state_t *st, double Fd)
{
    double jrad = 0.0;
    double pen = st->jtPenMax;
    for (int s = 0; s < st->njt; s++)
        jrad += jt_tick_string(st, s, Fd, &pen);
    st->jtPenMax = pen;
    return jrad;
}

/* ---- block-parallel jt post-pass: PERSISTENT WORKER POOL ----
   (2026-07-21 night — replaces the spawn-per-chunk machinery.)
   The drive schedule is string-independent, so workers advance
   DISJOINT string ranges through each chunk and accumulate per-thread
   partial holds; the reduction is serial in fixed thread order
   (deterministic for a given worker count — differs from the single
   s-ascending sum only in float association).  Workers are spawned
   OFF the audio thread (bow_jt_set_threads at engine build; offline
   the env read at bow_jt_load) at high QoS and parked on a condvar —
   per-block handoff is two lock/signal pairs, so 256-frame live
   blocks amortize.  jtPoolN < 2 = the serial replay path (bit-exact
   vs the historical inline block).  JT_STATS counts are approximate
   under workers (diagnostic only). */
#define JT_POOL_CH 65536

static void *jt_pool_run(void *va)
{
    struct { void *st; int idx; } *pa = va;
    bow_state_t *st = (bow_state_t *)pa->st;
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

static void jt_pool_stop(bow_state_t *st)
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

void bow_jt_set_threads(void *vst, int nth)
{
    bow_state_t *st = (bow_state_t *)vst;
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

/* Starpad jt tone LP (2026-07-23): arm/clear the one-pole on the
   radiated jt sum. a <= 0 = bypass (the historical bit-exact output).
   RUNTIME-SAFE since the purity axis (2026-07-23 night): the filter
   state is PRESERVED (a coefficient move on a continuous one-pole is
   click-free) and the bypass branch keeps the state WARM, so arming
   mid-ring starts from the current signal, not stale history. Plain
   scalar write, any thread. */
void bow_jt_set_lp(void *vst, double a)
{
    bow_state_t *st = (bow_state_t *)vst;
    st->jtLpA = a;
}

/* Starpad TILT axes (2026-07-23 evening): control-thread-safe scalar
   writes read by the jt tick (the drone-setter contract — aligned
   8-byte stores; a torn transition is inaudible).
   bow_jt_set_lift: frac >= 0 drops the jawari bone frac*jtLiftRef
   below its profile (jtLiftRef = load-time max static penetration,
   floor jtDeep) — large frac clears contact entirely = pure ringing
   taraf; 0 restores the byte-exact buzzy contact.
   bow_jt_set_damp_t60: extra taraf decay as an amplitude t60 in
   seconds (<= 0 = off/natural). */
void bow_jt_set_lift(void *vst, double frac)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st || st->njt <= 0) return;
    st->jtLift = frac > 0.0 ? frac * st->jtLiftRef : 0.0;
}

void bow_jt_set_damp_t60(void *vst, double t60)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st || st->njt <= 0) return;
    if (t60 > 0.0) {
        double dtj = (double)st->jtDiv / st->sr;
        /* p *= m per tick = velocity damping: amplitude decays at
           -ln(m)/(2 dtj); t60 = ln(1000) / that rate */
        st->jtDampMul = exp(-2.0 * 6.907755278982137 * dtj / t60);
    } else {
        st->jtDampMul = 0.0;
    }
}

/* Starpad TILT purity: scale the formula-taraf WEB voices' BUZZ
   sources (jn in-loop contact/fold, jw output-tap grazing) — 1 = the
   byte-exact fitted buzz, 0 = no buzz. The jl in-loop LOSS is NOT
   scaled: it self-limits hot rings, and removing it let half-purity
   rings grow and buzz HARDER than base (non-monotonic axis). Read
   once per process chunk; the host slews it at chunk rate
   (click-free). Plain scalar write, any thread. */
void bow_set_jaw_gain(void *vst, double g)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st) return;
    st->jawG = g < 0.0 ? 0.0 : (g > 1.0 ? 1.0 : g);
}

/* STARPAD LIVE PARAMETERS (2026-07-24): replace the per-sample scalar
   vector on a LIVE state — the same 61 values bow_init takes, in the
   same order, with the same derivations. Coefficient/table arrays and
   every piece of RUNNING STATE (string histories, the contact/aging
   state crS/crSB/crS3/ageDef/ageDef3, jawG, the jt web) are left
   alone, so editing a physics parameter no longer needs a fresh engine
   — no rebuild, no settle pre-roll, no crossfade, no lost ring.
   Plain scalar writes, control-thread safe, exactly like the
   jaw-gain/drone setters. No parity fixture calls it, so every golden
   is untouched. Order MUST stay in lockstep with bow_init. */
void bow_set_scalars(void *vst, const double *s, int n)
{
    bow_state_t *st = (bow_state_t *)vst;
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

/* STARPAD LIVE PARAMETERS stage 3 (2026-07-24): overwrite the BODY modal
   bank's coefficients on a live state. The resonator HISTORIES are
   separate arrays and are left untouched, so retuning the body under a
   sounding note is click-free (the same trick as swapping biquad
   coefficients while keeping the delay state). Refuses (returns 0) when
   the mode count differs — that is a reallocation, i.e. a real rebuild.
   No parity fixture calls it; the goldens are unaffected. */
int bow_set_body(void *vst, int K, const double *ba1, const double *ba2,
                const double *bn0, const double *bA, const double *bC)
{
    bow_state_t *st = (bow_state_t *)vst;
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

/* STARPAD LIVE PARAMETERS stage 3: overwrite the MODAL-JAWARI tables'
   coefficients in place. The modal STATE (jtQ = the settled static wrap,
   jtP, the drone envelopes, jtFprev) is deliberately kept: changing the
   bone geometry under a ringing web is a real physical act, and the web
   relaxing from its old wrap toward the new equilibrium IS the correct
   transient. Refuses when the shape moved (string count, zone count or
   any per-string mode count) — that needs a rebuild. Mirrors
   bow_jt_load's conversions; keep the two in lockstep. */
int bow_jt_set_coeffs(void *vst, int njt, int J, const int *M,
              const double *ca, const double *cb,
              const double *ca4, const double *cb4, const double *wd,
              const double *phiO, const double *phiD,
              const double *phiU, const double *phiF,
              const double *b, const double *G, const double *G4,
              const double *gd, const double *gd4, const double *phys)
{
    bow_state_t *st = (bow_state_t *)vst;
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
    return 1;
}

/* one filtered step of the jt output walk (bypass = identity with a
   warm state track — output byte-identical to the legacy bypass) */
static inline double jt_lp_step(bow_state_t *st, double x)
{
    if (st->jtLpA <= 0.0) { st->jtLpY = x; return x; }
    st->jtLpY += st->jtLpA * (x - st->jtLpY);
    return st->jtLpY;
}

static int jt_env_threads(void)
{
    static int cached = -2;
    if (cached == -2) {
        const char *e = getenv("SARANGI_JT_THREADS");
        cached = e ? atoi(e) : 1;
        if (cached < 1) cached = 1;
        if (cached > 16) cached = 16;
    }
    return cached;
}

/* telemetry probe: running max penetration beyond the static wrap and
   the last drive value (calibration/diagnosis only, no audio effect) */
void bow_jt_probe(void *vst, double *pen, double *fprev)
{
    bow_state_t *st = (bow_state_t *)vst;
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

/* DRONE rows: control-thread setters (per-row scalar writes read by
   the jt tick — an aligned 8-byte store; a torn transition is inaudible
   and a lost onset under a simultaneous tick is a non-event).
   bow_jt_pluck (gradual-attack rev) sets the decaying ONSET BOOST —
   the drive envelope swells toward level+boost, no impulse anywhere. */
void bow_jt_drone(void *vst, int s, double level)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st || s < 0 || s >= st->njt || !st->jtDnTgt) return;
    st->jtDnTgt[s] = level > 0.0 ? level : 0.0;
}

void bow_jt_pluck(void *vst, int s, double amp)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st || s < 0 || s >= st->njt || !st->jtDnBoost) return;
    st->jtDnBoost[s] = amp > 0.0 ? amp : 0.0;
}

/* drone envelope times (seconds), call at engine build off the audio
   thread: attack/release slews of the drive envelope + the onset-boost
   decay. Non-positive values keep the load-time defaults. */
void bow_jt_drone_env(void *vst, double atkSec, double relSec,
                      double onsetDecaySec)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st || st->njt <= 0) return;
    double dtj = (double)st->jtDiv / st->sr;
    if (atkSec > 0.0) st->jtDnAAtk = 1.0 - exp(-dtj / atkSec);
    if (relSec > 0.0) st->jtDnA = 1.0 - exp(-dtj / relSec);
    if (onsetDecaySec > 0.0) st->jtDnBDec = exp(-dtj / onsetDecaySec);
}

/* parity/test entry: run ONLY the jt block with a given drive sequence
   (no bow, no web) — the harness compares this against the python
   reference twin scripts/tanpura_modal.py on identical tables. */
void bow_jt_test(void *vst, int n, const double *drive, double *out)
{
    bow_state_t *st = (bow_state_t *)vst;
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

/* ---- WAVEGUIDE JAWARI (see the state-struct note) ----
   Rails: for string s, jwRail[off .. off+2N): vp = [0..N), vm = [N..2N)
   as circular buffers with a shared head h (incrementing). Spatial
   cell k FROM THE BRIDGE (k=0 = bridge end):
     vp cell k  = vp[(h + k) % N]          (arrives at bridge k=0)
     vm cell k  = vm[(h + N - 1 - k) % N]  (arrives at nut at k=N-1)
   One tick: read ends, advance h (propagation), loop-filter + Thiran
   into the vm bridge end, rigid nut into vp, contact on the zone
   cells, drive injection, integrate uz. */
/* ---- JAWARI FD STRINGS (final form, 2026-07-21g): the VALIDATED
   Bilbao scheme (tanpura_fd.py, ear-approved in the campaign) per
   taraf row — pinned ends, distributed sigma0/sigma1 damping,
   stiffness d4 (real inharmonicity), TENSION-EXACT tuning, PER-CELL
   IMPLICIT contact (diagonal by FD locality — the explicit penalty is
   the campaign's known instability at bone stiffness). Runs R
   subticks per kernel sample (R = 2 -> a 192 kHz zone grid inside the
   96 kHz kernel; the fine grid closes the purity/contrast gap).
   All dt/h dependence baked in the builder's tables. */
double jw_tick(bow_state_t *st, double Fd);

void bow_jw_load(void *vst, int njw, int R, const int *N,
                 const int *oi,
                 const double *lam2, const double *muk,
                 const double *s1h, const double *A0, const double *B0,
                 const double *kloc, const double *fdrv,
                 const double *gainRow, const double *ofrac,
                 const double *kcr, const double *b,
                 const double *phys, double settle_s)
{
    bow_state_t *st = (bow_state_t *)vst;
    st->njw = njw; st->jwR = R;
    if (njw <= 0) return;
    st->jwN = (int *)malloc(sizeof(int) * njw);
    st->jwOff = (int *)malloc(sizeof(int) * njw);
    st->jwOi = (int *)malloc(sizeof(int) * njw);
    int tot = 0;
    for (int s = 0; s < njw; s++) {
        /* STACK-SMASH GUARD (the audit law, relearned today): the
           static scratch is JW_MAXN — a row exceeding it corrupted
           adjacent kernel state via the load-time settle and
           decorrelated the BASE render (gain-invariant!). Clamp hard;
           the builder must never send more. */
        int Ns = N[s];
        if (Ns + 1 > JW_MAXN) Ns = JW_MAXN - 1;
        st->jwN[s] = Ns; st->jwOff[s] = tot; st->jwOi[s] = oi[s];
        tot += Ns + 1;
    }
    st->jwTot = tot;
    st->jwLam2 = dup_d(lam2, njw); st->jwMuk = dup_d(muk, njw);
    st->jwS1h = dup_d(s1h, njw);   st->jwA0 = dup_d(A0, njw);
    st->jwB0 = dup_d(B0, njw);     st->jwKloc = dup_d(kloc, njw);
    st->jwFdrv = dup_d(fdrv, njw); st->jwGainRow = dup_d(gainRow, njw);
    st->jwOfrac = dup_d(ofrac, njw);
    st->jwKcRow = dup_d(kcr, njw);
    st->jwB = dup_d(b, tot);
    st->jwU = (double *)calloc(3 * (size_t)tot, sizeof(double));
    st->jwKc = phys[0]; st->jwAlpha = phys[1]; st->jwHcB = phys[2];
    st->jwGain = phys[3]; st->jwDrv = phys[4];
    st->jwFprev = 0.0; st->jwFdc = 0.0; st->jwPenMax = 0.0;
    int ns = (int)(settle_s * st->sr);
    for (int n_ = 0; n_ < ns; n_++)
        jw_tick(st, 0.0);
    /* pen semantics parity with jt (which starts on the static wrap):
       report DYNAMIC penetration only — the settle snap is load-time */
    st->jwPenMax = 0.0;
}

/* R FD subticks for every string; returns the row-weighted velocity
   observation of the LAST subtick. */
double jw_tick(bow_state_t *st, double Fd)
{
    const int hertz = (st->jwAlpha > 1.499 && st->jwAlpha < 1.501);
    const int tot = st->jwTot;
    double out = 0.0;
    for (int s = 0; s < st->njw; s++) {
        const int N = st->jwN[s];
        const int nn = N + 1;
        double *u = st->jwU + st->jwOff[s];
        double *upv = u + tot;
        double *d2p = u + 2 * (size_t)tot;
        const double *b_ = st->jwB + st->jwOff[s];
        const double lam2 = st->jwLam2[s], muk = st->jwMuk[s];
        const double s1h = st->jwS1h[s];
        const double A0 = st->jwA0[s], B0 = st->jwB0[s];
        const double kloc = st->jwKloc[s];
        /* per-row contact stiffness: kc mapped through the modal
           reference's basis-truncation compliance (see jw_tables) —
           keeps the contact in the COMPLIANT Hertzian regime the
           reference actually plays in, instead of the grid's
           position-constraint wall */
        const double kcS = st->jwKcRow[s];
        const int oi = st->jwOi[s];
        /* FRACTIONAL 0.9L tap (2026-07-21j): the modal twin drives and
           observes at EXACT x=0.9L, where sin(k pi 0.9) NULLS modes
           10/20/... — a grid-rounded integer tap leaks them (+97 dB
           relative) and scatters near-node mode levels by +-8 dB. */
        const double w1 = st->jwOfrac[s];
        const double w0 = 1.0 - w1;
        double obs = 0.0;
        /* observation spans the WHOLE kernel sample (all R subticks):
           the R-subtick boxcar is the anti-alias for the R:1 read-out
           (last-subtick-only = raw decimation, folds 48-96k in-band) */
        const double uo0 = w0 * u[oi] + w1 * u[oi + 1];
        for (int r = 0; r < st->jwR; r++) {
            /* fused update: un computed into upv (recycled), then
               pointer swap semantics via copy-back — keep simple:
               compute into a stack pass over nodes with local temps */
            double um1 = 0.0, um2 = 0.0;   /* u[i-1], u[i-2] history */
            (void)um1; (void)um2;
            /* d2 current into a temp plane: reuse d2p AFTER reading */
            /* pass 1: un[i]; we need d2(u) and d2p (previous d2) */
            /* compute serially with local buffers on the stack is
               awkward for large N — use two sweeps over the arena
               planes instead (d2 into a scratch = upv AFTER it is
               consumed).  Simplest correct: allocate-free two-sweep:
               sweep A computes d2 into d2new (stack chunks), sweep B
               forms un. To stay allocation-free we fold: */
            /* --- sweep: for i, need u[i-2..i+2], upv[i], d2p[i] --- */
            double c_um2 = 0.0, c_um1 = 0.0;
            double keep_prev_u = 0.0;
            (void)keep_prev_u;
            c_um2 = 0.0; c_um1 = u[0];
            double d2_im1 = 0.0;           /* d2 at i-1 (current) */
            double un_prev = 0.0;          /* un[i-1] result */
            (void)un_prev;
            /* boundary: un[0] = 0 (pinned) */
            double new_d2p_0 = 0.0;
            (void)new_d2p_0;
            double keepA = u[0], keepB = 0.0;
            (void)keepA; (void)keepB;
            /* For clarity and correctness use a small static scratch:
               NODES <= JW_MAXN. */
            {
                static double d2c[JW_MAXN];
                static double unb[JW_MAXN];
                d2c[0] = 0.0; d2c[N] = 0.0;
                for (int i = 1; i < N; i++)
                    d2c[i] = u[i + 1] - 2.0 * u[i] + u[i - 1];
                for (int i = 2; i < N - 1; i++) {
                    double d4 = u[i + 2] - 4.0 * u[i + 1] + 6.0 * u[i]
                        - 4.0 * u[i - 1] + u[i - 2];
                    unb[i] = (2.0 * u[i] - B0 * upv[i] + lam2 * d2c[i]
                              - muk * d4
                              + s1h * (d2c[i] - d2p[i])) / A0;
                }
                {
                    double d4a = u[3] - 4.0 * u[2] + 6.0 * u[1]
                        - 4.0 * u[0] + (-u[1]);
                    unb[1] = (2.0 * u[1] - B0 * upv[1] + lam2 * d2c[1]
                              - muk * d4a
                              + s1h * (d2c[1] - d2p[1])) / A0;
                    double d4b = u[N - 3] - 4.0 * u[N - 2]
                        + 6.0 * u[N - 1] - 4.0 * u[N] + (-u[N - 1]);
                    unb[N - 1] = (2.0 * u[N - 1] - B0 * upv[N - 1]
                                  + lam2 * d2c[N - 1] - muk * d4b
                                  + s1h * (d2c[N - 1] - d2p[N - 1]))
                        / A0;
                }
                unb[0] = 0.0; unb[N] = 0.0;
                /* per-cell implicit contact where bone exists */
                for (int i = 1; i < N; i++) {
                    double bb = b_[i];
                    if (bb <= -0.5) continue;
                    double eta0 = bb - unb[i];
                    if (eta0 <= 0.0) continue;
                    /* implicit contact solved in ETA-space (2026-07-21j):
                       g(eta) = eta + K*eta^alpha - eta0 is monotone
                       CONVEX — Newton from eta0 descends to the root
                       globally.  The old f-space iteration OSCILLATES
                       at bone stiffness (f: 3e5 -> 0 -> 7 -> ...) and
                       never converged: the contact failed to push back
                       and the web measured pen 344 um / output -39 dB
                       at the real render op (jt reference: 8 um). */
                    double K = kloc * kcS;
                    double eta = eta0;
                    for (int it = 0; it < 8; it++) {
                        double ea = hertz ? sqrt(eta)
                            : pow(eta, st->jwAlpha - 1.0);
                        double g_ = eta + K * ea * eta - eta0;
                        double gp_ = 1.0 + K * st->jwAlpha * ea;
                        double en = eta - g_ / gp_;
                        eta = en > 0.0 ? en : 0.5 * eta;
                    }
                    unb[i] += (eta0 - eta);
                    if (eta > st->jwPenMax) st->jwPenMax = eta;
                }
                if (Fd != 0.0) {
                    unb[oi] += st->jwFdrv[s] * Fd * w0;
                    unb[oi + 1] += st->jwFdrv[s] * Fd * w1;
                }
                /* commit: upv <- u, u <- unb, d2p <- d2c */
                for (int i = 0; i <= N; i++) {
                    upv[i] = u[i];
                    u[i] = unb[i];
                    d2p[i] = d2c[i];
                }
            }
        }
        obs = (w0 * u[oi] + w1 * u[oi + 1] - uo0) / (double)st->jwR;
        out += st->jwGainRow[s] * obs;
    }
    return out;
}

void bow_jw_probe(void *vst, double *pen, double *fmax)
{
    bow_state_t *st = (bow_state_t *)vst;
    double mx = -1e30;
    for (int s = 0; s < st->njw; s++) {
        const double *u = st->jwU + st->jwOff[s];
        const double *b_ = st->jwB + st->jwOff[s];
        for (int i = 0; i <= st->jwN[s]; i++) {
            if (b_[i] <= -0.5) continue;
            double d = b_[i] - u[i];
            if (d > mx) mx = d;
        }
    }
    if (st->jwPenMax > mx) mx = st->jwPenMax;
    *pen = mx;
    *fmax = st->jwFprev;
}

void bow_jw_test(void *vst, int n, const double *drive, double *out)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (st->njw <= 0) return;
    for (int t = 0; t < n; t++) {
        out[t] = st->jwGain * jw_tick(st, st->jwFprev * st->jwDrv);
        st->jwFprev = drive[t];
    }
}

void bow_process(void *vst, int n,
                 /* controls (per sample, kernel rate, CHUNK-relative) */
                 const double *f0, const double *vb, const double *fb,
                 const double *beta, const double *gate, const double *xv,
                 double *out)
{
    bow_state_t *st = (bow_state_t *)vst;
    /* Aliases into the state.  The loop below is the legacy render() body
       VERBATIM (byte-parity bar): scalar state is loaded into locals here
       and stored back after the loop; arrays are pointer aliases (loads/
       stores of doubles are exact — no FP consequence). */
    const double sr = st->sr;
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
    const double kret = st->kret, retA = st->retA, retMode = st->retMode;
    const double rb0 = st->rb0, ra1 = st->ra1, ra2 = st->ra2;
    const double kdisp = st->kdisp, bowWidth = st->bowWidth;
    const double bowCont = st->bowCont, Z = st->Z, Zt = st->Zt;
    const double mu_s = st->mu_s, mu_d = st->mu_d, v0f = st->v0f;
    const double nutA = st->nutA, brA = st->brA;
    const double thLeak = st->thLeak, thA = st->thA, thD = st->thD;
    const double thFloor = st->thFloor;
    const double bowDisp = st->bowDisp, jq = st->jq, jq2 = st->jq2;
    const double zload = st->zload, tdirect = st->tdirect;
    const double tshape = st->tshape, tmix = st->tmix;
    const double nA = st->nA, nT = st->nT, nPow = st->nPow;
    const double nzHi = st->nzHi, nzLo = st->nzLo;
    const double nDir = st->nDir, nzHiD = st->nzHiD;
    const double gutG = st->gutG, nailK = st->nailK;
    const double tuw = st->tuw;
    const double torsRatio = st->torsRatio, torsG = st->torsG;
    const double torsC = st->torsC;
    const double ageA = st->ageA, ageDk = st->ageDk;
    const double v0Pow = st->v0Pow, v0Ref = st->v0Ref;
    const double hairHz = st->hairHz, hairRef = st->hairRef;
    double hairLp = st->hairLp;
    double hairLp3[3];
    memcpy(hairLp3, st->hairLp3, sizeof hairLp3);
    const double crW = st->crW, crAt = st->crAt;
    const int crOn = (crW > 1e-12) || (crAt < 1.0 - 1e-12);
    const double jawRho = st->jawRho;
    const double jawRoll = st->jawRoll, jawRollAmp = st->jawRollAmp;
    /* Starpad TILT purity: web-jawari depth scale (1.0 = byte-exact).
       Hoisted per chunk — the host updates it between chunks. */
    const double jawG = st->jawG;
    double *rollD = st->rollD;
    double *rollE = st->rollE;
    double *rollAv = st->rollAv;
    double crS = st->crS, crSB = st->crSB;
    double crS3[3];
    memcpy(crS3, st->crS3, sizeof crS3);
    double ageDef = st->ageDef;
    double ageDef3[3];
    memcpy(ageDef3, st->ageDef3, sizeof ageDef3);
    int wti = st->wti;
    double *fv = st->fv, *dwt = st->dwt, *dtg = st->dtg;
    const double aDuck = exp(-1.0 / (0.010 * st->sr));
    const double f0Open = st->f0Open, gutA2 = st->gutA2;
    int dispNi = (int)(st->dispN + 0.5);
    if (dispNi < 1) dispNi = 1; if (dispNi > 4) dispNi = 4;
    /* nail termination: recover the nut corner Hz from its coefficient
       (exact inverse of exp(-2*pi*fc/sr)) for the position-dependent law */
    const double nutFc0 = -log(nutA) * st->sr / 6.283185307179586;
    const double hpG = st->hpG, jy0 = st->jy0, jzsum = st->jzsum;
    const double jden = st->jden;
    const int psv = st->psv;
    double *arena = st->arena;
    int *widx = st->widx;
    double *vx1 = st->vx1, *vx2 = st->vx2, *vlp = st->vlp;
    double *jdc = st->jdc, *jenv = st->jenv, *sv = st->sv;
    double venv = st->venv;
    /* Fixed-size state arrays are STAGED through stack locals for the loop
       (memcpy in/out; loads/stores of doubles are exact): the legacy
       monolith had these on the STACK, and accessing them through the
       state pointer instead changes -O3 codegen (measured: the fused-
       multiply-add lowering of the body-radiation accumulators flipped,
       a 1-ulp/sample drift) — stack staging restores the byte-identical
       loop compilation. */
    double bx1[96], bx2[96], by1[96], by2[96];
    double tx1[96], tx2[96], ty1[96], ty2[96];
    double buf1[MAXBOW], buf2[MAXBOW];
    double bufAB[64], bufBA[64];
    double bufAM[64], bufMA[64];
    double bufMB[64], bufBM[64];
    double Tr3[3];
    memcpy(bx1, st->bx1, sizeof bx1); memcpy(bx2, st->bx2, sizeof bx2);
    memcpy(by1, st->by1, sizeof by1); memcpy(by2, st->by2, sizeof by2);
    memcpy(tx1, st->tx1, sizeof tx1); memcpy(tx2, st->tx2, sizeof tx2);
    memcpy(ty1, st->ty1, sizeof ty1); memcpy(ty2, st->ty2, sizeof ty2);
    memcpy(buf1, st->buf1, sizeof buf1);
    double bufT[MAXBOW];
    memcpy(bufT, st->bufT, sizeof bufT); memcpy(buf2, st->buf2, sizeof buf2);
    memcpy(bufAB, st->bufAB, sizeof bufAB);
    memcpy(bufBA, st->bufBA, sizeof bufBA);
    memcpy(bufAM, st->bufAM, sizeof bufAM);
    memcpy(bufMA, st->bufMA, sizeof bufMA);
    memcpy(bufMB, st->bufMB, sizeof bufMB);
    memcpy(bufBM, st->bufBM, sizeof bufBM);
    memcpy(Tr3, st->Tr3, sizeof Tr3);
    double hpY = st->hpY, hpX1 = st->hpX1;
    int wab = st->wab, wba = st->wba;
    int wam = st->wam, wma = st->wma, wmb = st->wmb, wbm = st->wbm;
    int w1i = st->w1i, w2i = st->w2i;
    double nutLp = st->nutLp, brLp = st->brLp, pLp = st->pLp;
    double nutLp2 = st->nutLp2, brLp2 = st->brLp2;
    double vRet = st->vRet, vRet2 = st->vRet2;
    double disp = st->disp;
    double apXs[4], apYs[4];
    memcpy(apXs, st->apXs, sizeof apXs); memcpy(apYs, st->apYs, sizeof apYs);
    unsigned long long lcg = st->lcg;
    double nz1 = st->nz1, nz2 = st->nz2;
    double nz1b = st->nz1b, nz2b = st->nz2b;
    double tEnv = st->tEnv, fbPrev = st->fbPrev;
    double Vprev = st->Vprev;
    double kGate = st->kGate;
    /* bridge-return gate: kret is DRIVEN only while the bow supplies energy.
       The moment the friction stops (Fb->0) the return is a LINEAR ACTIVE
       loop (no stick-slip to bound it), so it must cut with the bow, not
       lag it — a slow release let a resonant note (the fifth, on the body
       mode) pump +14 dB before the gate closed.  Fast both ways (attack
       3 ms, release 8 ms): within a sustained bow gk==1 (timbre unchanged);
       at note-off gk->0 as fast as the bow force falls. */
    const double kg_atk = exp(-1.0 / (0.003 * sr));
    const double kg_rel = exp(-1.0 / (0.008 * sr));

    /* drive record for the deferred jt post-pass (one-way web);
       live blocks ride the pool's preallocated buffer — no malloc
       on the audio thread */
    double *jtFr = NULL;
    if (st->njt > 0 && st->jtGain != 0.0)
        jtFr = (st->jtFrBuf && n <= st->jtFrCap)
            ? st->jtFrBuf
            : (double *)malloc(sizeof(double) * (size_t)n);

    for (int t = 0; t < n; t++) {
        /* ---- bow string ---- */
        double F = 0.0;
        double o2 = 0.0;
        double tdir = 0.0;
        double noiseDir = 0.0;
        int bowOn = bowW > 1e-9;
        /* driven-unison duck targets, block-rate (tuw = 1 -> inert) */
        if (tuw < 0.999 && (t & 63) == 0) {
            double fb0 = f0[t] > 40.0 ? f0[t] : 40.0;
            for (int i = 0; i < nv; i++) {
                double r = fb0 / fv[i];
                double best = 1e9;
                const double rat[11] = {0.25, 0.333333333, 0.5,
                                        0.666666667, 0.75, 1.0, 1.333333333,
                                        1.5, 2.0, 3.0, 4.0};
                for (int u = 0; u < 11; u++) {
                    double d = fabs(log(r / rat[u]));
                    if (d < best) best = d;
                }
                /* within ~30 c of a partial coincidence AND bowing */
                dtg[i] = (best < 0.0173 && gate[t] > 0.5) ? tuw : 1.0;
            }
        }
        /* BOW-FORCE GATE (conservation of energy).  bowForce = fb*gate; a
           fast envelope (attack 3 ms, release 8 ms) tracks whether the bow
           is driving.  It does two things, both no-ops while gk==1 (a
           sustained bow -> the friction-era timbre is bit-unchanged):
             (1) gates the bridge-mobility return kret -> kretG (a released
                 string is passive; the return can only take energy, never
                 add it — the tonic-ring runaway was this return re-pumping
                 the near-lossless string after note-off), and
             (2) DAMPS the string reflections (rdmp) so a released string
                 decays inaudible by ~5-6 s instead of ringing ~15 s
                 (frequency-compensated: rdmp per-reflection gives a roughly
                 f0-independent decay). */
        double bowForce = fb[t] * gate[t];
        double kga = bowForce > kGate ? kg_atk : kg_rel;
        kGate = (1.0 - kga) * bowForce + kga * kGate;
        double gk = kGate >= 0.10 ? 1.0 : kGate * 10.0;
        double kretG = kret * gk;
        double rdmp = 1.0 - (0.69 / fmax(f0[t], 40.0)) * (1.0 - gk);
        if (bowOn) {
            double T = sr / fmax(f0[t], 40.0);
            double L1 = fmax(2.0, beta[t] * T * 0.5);
            double L2 = fmax(2.0, (1.0 - beta[t]) * T * 0.5);
            /* NAIL TERMINATION (2026-07-14): no fingerboard — the string
               is stopped in air by the nail/cuticle, a lossy termination
               whose loss grows with stopped position. fc_nut scales as
               (f0_open/f0)^nailK; nailK = 0 -> exact legacy nutA. */
            double nutAf = nutA;
            if (nailK != 0.0) {
                double fcn = nutFc0 * pow(f0Open / fmax(f0[t], 40.0), nailK);
                if (fcn > 0.45 * sr) fcn = 0.45 * sr;
                if (fcn < 200.0) fcn = 200.0;
                nutAf = exp(-6.283185307179586 * fcn / sr);
            }
            double h1 = frac_read(buf1, MAXBOW, w1i, fmax(2.0, L1 * 2.0 - bowWidth));
            /* PHYSICAL FM: bridge DISPLACEMENT moves the termination ->
               the bridge segment's length modulates (velocity injection
               alone cannot shift the period; friction re-locks phase) */
            double dl = kdisp * disp;
            if (dl > 0.02) dl = 0.02; else if (dl < -0.02) dl = -0.02;
            double h2 = frac_read(buf2, MAXBOW, w2i,
                                  fmax(2.0, (L2 * 2.0 - bowWidth) * (1.0 + dl)));
            /* FINITE-WIDTH BOW (Pitteroff): two contact points separated by
               a real string segment (bowWidth samples one-way). A Helmholtz
               corner passes both near-coherently; an octave/multiphonic
               regime with structure between them is differentially damped —
               the physical regime stabilizer a point bow idealizes away. */
            double hBA = 0, hAB = 0;
            if (bowCont >= 2.5 && bowWidth >= 2.0) {
                /* PITTEROFF v2 (2026-07-07i, the roughness floor): THREE
                   hair-group contacts, each with its OWN friction solve,
                   own rosin temperature and own knee diversity, joined by
                   real string segments (bowWidth/2 each; buf1/buf2 use the
                   total width so the period is preserved). v1 AVERAGED the
                   3-group ensemble into one contact — slips stayed
                   coherent and every slip AM'd all harmonics together
                   (the ear-confirmed 15-40 Hz h2 roughness at 26-34% vs
                   the target's 3-4%). Independent contacts desynchronize
                   PHYSICALLY: a slip at one contact meets still-stuck
                   neighbours through the segment waves. */
                static const double hs2[3] = {0.88, 1.0, 1.12};
                static const double hl2[3] = {0.92, 1.0, 1.09};
                double wseg = bowWidth * 0.5;
                double inL[3], inR[3], inj[3];
                inL[0] = h1;
                inL[1] = frac_read(bufAM, 64, wam, wseg);
                inL[2] = frac_read(bufMB, 64, wmb, wseg);
                inR[0] = frac_read(bufMA, 64, wma, wseg);
                inR[1] = frac_read(bufBM, 64, wbm, wseg);
                inR[2] = h2;
                double FbT = fb[t] * gate[t] / 3.0;
                double Zeff = Z / (1.0 + Z / Zt);
                for (int g = 0; g < 3; g++) {
                    double vhg = inL[g] + inR[g];
                    double soft = 1.0 - thA * hs2[g] * Tr3[g];
                    if (soft < thFloor) soft = thFloor;
                    double mDg = mu_d * (1.0 - thD * (1.0 - soft));
                    double mSg = mDg + (mu_s - mu_d) * soft;
                    if (ageA > 1e-12) {
                        if (FbT <= 1e-6) ageDef3[g] = ageA;
                        else mSg = mDg + (mSg - mDg) * (1.0 - ageDef3[g]);
                    }
                    double v0g = v0f * (0.85 + 0.15 * g);
                    if (v0Pow > 1e-12)
                        v0g *= pow(v0Ref / fmax(FbT * 3.0, 0.05), v0Pow);
                    double Ffg = 0.0;
                    if (FbT > 1e-6) {
                        double dv0 = vhg - vb[t];
                        double stickF = -2.0 * Zeff * dv0;
                        if (!crOn) {
                        if (fabs(stickF) <= mSg * FbT) {
                            Ffg = stickF;
                            if (ageA > 1e-12) ageDef3[g] *= ageDk;
                        } else {
                            if (ageA > 1e-12) ageDef3[g] = ageA;
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
                            if (seg < crS3[g])
                                crS3[g] += crAt * (seg - crS3[g]);
                            else crS3[g] = seg;
                            if (crS3[g] > 1.0) crS3[g] = 1.0;
                            else if (crS3[g] < 0.0) crS3[g] = 0.0;
                            if (crS3[g] >= 1.0 - 1e-12) {
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
                                Ffg = crS3[g] * stickF
                                    + (1.0 - crS3[g]) * Fsg;
                            }
                            if (ageA > 1e-12)
                                ageDef3[g] = crS3[g] * (ageDef3[g] * ageDk)
                                    + (1.0 - crS3[g]) * ageA;
                        }
                        double dvh = (vhg - vb[t]) + Ffg / (2.0 * Zeff);
                        double lk = pow(thLeak, hl2[g]);
                        Tr3[g] = lk * Tr3[g]
                            + (1.0 - lk) * fabs(Ffg * dvh);
                    } else if (crOn) {
                        crS3[g] = 1.0;
                    }
                    if (hairHz > 1e-6) {
                        double fcH = hairHz * fmax(FbT * 3.0, 0.02)
                            / hairRef;
                        if (fcH > 0.45 * sr) fcH = 0.45 * sr;
                        double aH = exp(-6.283185307179586 * fcH / sr);
                        hairLp3[g] = (1.0 - aH) * Ffg + aH * hairLp3[g];
                        Ffg = hairLp3[g];
                    }
                    inj[g] = Ffg / (2.0 * Z);
                }
                double o1v = inR[0] + inj[0];
                bufAM[wam] = inL[0] + inj[0]; wam = (wam + 1) % 64;
                bufMA[wma] = inR[1] + inj[1]; wma = (wma + 1) % 64;
                bufMB[wmb] = inL[1] + inj[1]; wmb = (wmb + 1) % 64;
                bufBM[wbm] = inR[2] + inj[2]; wbm = (wbm + 1) % 64;
                o2 = inL[2] + inj[2];
                nutLp = (1.0 - nutAf) * o1v + nutAf * nutLp;
                buf1[w1i] = -nutLp * rdmp * gutG;
                w1i = (w1i + 1) % MAXBOW;
                brLp = (1.0 - brA) * o2 + brA * brLp;
                /* second termination pole on the TRANSMITTED force only:
                   the loop keeps its brightness (Helmholtz lock — a loop
                   pole dead-noted the taar windows even at 9 kHz), the
                   radiated force takes the gut HF dissipation. */
                if (gutA2 > 0.0) {
                    brLp2 = (1.0 - gutA2) * brLp + gutA2 * brLp2;
                    F += bowW * 2.0 * Z * brLp2;
                } else {
                    F += bowW * 2.0 * Z * brLp;
                }
            } else {
            if (bowWidth >= 1.0) {
                hBA = frac_read(bufBA, 64, wba, bowWidth);
                hAB = frac_read(bufAB, 64, wab, bowWidth);
            }
            double vh = (bowWidth >= 1.0) ? (h1 + hBA) : (h1 + h2);
            double tEcho = 0.0;
            if (torsC > 1e-9) {
                double Lt = (L1 + L2) * 2.0 / torsRatio;
                tEcho = frac_read(bufT, MAXBOW, wti, fmax(4.0, Lt));
                vh += torsC * tEcho;
            }
            double Ff = 0.0;
            double Fb = fb[t] * gate[t] * ((bowWidth >= 1.0) ? 0.5 : 1.0);
            /* THERMAL FRICTION: rosin softens with contact heating
               (friction power history) — deterministic cycle-to-cycle
               variability; the physical far-pedestal + regime stabilizer */
            /* heating erodes the STATIC/DYNAMIC CONTRAST (the grip
               edge) while kinetic friction stays stable — the graded form;
               softening mu_d too caused a refreeze/re-grip relaxation
               oscillation = a chaotic cliff (measured: nothing at thA 6.5,
               full flattening at 7.5) */
            /* ensemble over 3 hair groups (thA spread ±12%, v0 spread
               ±15%): average the effective friction curve */
            double muS = 0, muD = 0;
            static const double hs[3] = {0.88, 1.0, 1.12};
            for (int hgi = 0; hgi < 3; hgi++) {
                double soft = 1.0 - thA * hs[hgi] * Tr3[hgi];
                if (soft < thFloor) soft = thFloor;
                double mD = mu_d * (1.0 - thD * (1.0 - soft));
                muD += mD / 3.0;
                muS += (mD + (mu_s - mu_d) * soft) / 3.0;
            }
            if (ageA > 1e-12) {
                if (Fb <= 1e-6) ageDef = ageA;
                else muS = muD + (muS - muD) * (1.0 - ageDef);
            }
            double v0e = v0f;
            if (v0Pow > 1e-12 && Fb > 1e-6)
                v0e = v0f * pow(v0Ref / fmax(Fb * 2.0, 0.05), v0Pow);
            if (Fb > 1e-6) {
                double Zeff = Z / (1.0 + Z / Zt);   /* torsional damping at the bow: the physical Helmholtz stabilizer */
                double dv0 = vh - vb[t];
                double stickF = -2.0 * Zeff * dv0;
                if (!crOn) {
                if (fabs(stickF) <= muS * Fb) {
                    Ff = stickF;
                    if (ageA > 1e-12) ageDef *= ageDk;
                } else {
                    if (ageA > 1e-12) ageDef = ageA;
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
                    /* continuum contact: stuck-fraction relaxation, then
                       blended force = crS*stick + kinetic at the
                       (1-crS)-scaled operating point (see struct note) */
                    double xq = fabs(stickF) / fmax(muS * Fb, 1e-30);
                    double se = cr_seq(xq, crW);
                    /* ASYMMETRIC state dynamics: release is a FRONT
                       propagating across the band (finite completion
                       time crMs regardless of how fast the demand
                       crossed), capture is a STRING-STATE event (dv
                       through zero re-grips the whole band at once).
                       A symmetric tau delayed capture too = extended
                       slip duty = the measured h2-dominant octave
                       drift; snapping capture removes it. */
                    if (se < crS) crS += crAt * (se - crS);
                    else crS = se;
                    if (crS > 1.0) crS = 1.0;
                    else if (crS < 0.0) crS = 0.0;
                    if (crS >= 1.0 - 1e-12) {
                        Ff = stickF;
                    } else {
                        /* released fraction SNAPS to the sliding branch
                           (full-argument slip solve — transient friction
                           does not creep along the steady curve's summit
                           at near-zero dv; the scaled-operating-point
                           form measured +4..+5 dB h5/h6 = the summit
                           traversal bump) */
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
                        Ff = crS * stickF + (1.0 - crS) * Fs;
                    }
                    /* rate-and-state aging follows the stuck fraction:
                       crS=1 -> the stick decay, crS=0 -> the slip reset */
                    if (ageA > 1e-12)
                        ageDef = crS * (ageDef * ageDk) + (1.0 - crS) * ageA;
                }
            } else if (crOn) {
                crS = 1.0;   /* unloaded: a re-placed bow lands stuck */
            }
            /* BOW CONTACT NOISE (2026-07-07m, the diff-spectrogram's #1
               structured residual): real bowing carries continuous
               wideband friction noise — rosin/hair asperities perturb the
               friction force, strongest DURING SLIP (surface sliding), so
               the noise is pitch-synchronously gated (the 'breath' that
               fills the target's inter-harmonic floor: measured deficit
               -2.8/-7.0/-5.7 dB in 0.5-1.5/1.5-3/3-6 kHz). Band-shaped
               400 Hz-8.5 kHz, force- and slip-scaled, seeded LCG. nA = 0
               reproduces the deterministic kernel exactly. */
            /* TRANSITION NOISE (2026-07-07n, diff residual #2): at a
               bow change / rearticulation the bow grazes with rapidly
               changing force — a broadband burst the target shows as
               vertical noise bands at every note boundary. Gain follows
               the force-change rate (50 ms leak), works at LOW force
               (grazing), still slip-gated inside the contact block. */
            if (hairHz > 1e-6) {
                double fcH = hairHz * fmax(Fb, 0.02) / hairRef;
                if (fcH > 0.45 * sr) fcH = 0.45 * sr;
                double aH = exp(-6.283185307179586 * fcH / sr);
                hairLp = (1.0 - aH) * Ff + aH * hairLp;
                Ff = hairLp;
            }
            if (torsC > 1e-9) {
                double ZeffT = Z / (1.0 + Z / Zt);
                double dvS = (Fb > 1e-6)
                    ? ((vh - vb[t]) + Ff / (2.0 * ZeffT)) : 0.0;
                bufT[wti] = torsG * (dvS - tEcho);
                wti = (wti + 1) % MAXBOW;
            }
            tEnv = 0.99958 * tEnv + fabs(fb[t] * gate[t] - fbPrev);
            fbPrev = fb[t] * gate[t];
            if ((nA > 1e-9 || nT > 1e-9 || nDir > 1e-9) && Fb > 1e-6) {
                lcg = lcg * 6364136223846793005ULL
                    + 1442695040888963407ULL;
                double xi = (double)((lcg >> 33) & 0xFFFFFF)
                    / 8388608.0 - 1.0;
                /* band corners are PARAMETERS (2026-07-07p): the floor
                   deficit is band-CONCENTRATED (measured -2..-5 dB at
                   1.6-6.4 kHz on both pairs, at/above target outside) —
                   stick-slip micro-events are 0.1-0.5 ms wide, so real
                   rosin noise concentrates 2-10 kHz, not flat to 400 Hz.
                   Defaults reproduce the old 0.43/0.026 @96k corners. */
                nz1 = nz1 + nzHi * (xi - nz1);
                nz2 = nz2 + nzLo * (nz1 - nz2);
                nz1b = nz1b + nzHiD * (xi - nz1b);   /* lower 2-pole top */
                nz2b = nz2b + nzHiD * (nz1b - nz2b); /* for direct radiation */
                double dvn = (vh - vb[t])
                    + Ff / (2.0 * (Z / (1.0 + Z / Zt)));
                double advn = fabs(dvn);
                double slipg = advn / (advn + v0f);
                /* force-scaling is SUBLINEAR (nPow < 1): at light force
                   the slip is less locked and the relative asperity
                   noise rises — the target's taraf ring lands at the
                   same level after a gentle note as after a loud one
                   (measured -44/-44), while linear nA*Fb collapsed the
                   gentle-note pump ~20 dB. nPow = 1 is the old law. */
                Ff += (nA * pow(Fb, nPow) + nT * tEnv) * slipg
                    * (nz1 - nz2);
                /* DIRECT CONTACT-NOISE RADIATION (2026-07-08): a bowed
                   string radiates broadband asperity noise TWO ways — (a)
                   transmitted into the string (the nA term above, which
                   perturbs the slip decision on the next sample = the
                   15-40 Hz h2 roughness), and (b) radiated DIRECTLY from
                   the near-field contact region to the mic (does NOT enter
                   the friction loop). Path (b) fills the target's inter-
                   harmonic floor with ZERO slip perturbation, so it lifts
                   the wash without the roughness that caps the nA term.
                   Same asperity process (slip-gated, force-scaled, band
                   nzLo-nzHiD); added to out[t] post-radiation, never
                   recirculated. The direct path has its OWN band top
                   (nzHiD < nzHi): the skin radiates the very-HF asperity
                   noise inefficiently (same reason bow_E_lp exists), and
                   the render is already HF-EXCESS above ~6 kHz — so the
                   directly-radiated noise rolls off there while the in-
                   loop noise keeps its full band (it sees the body W
                   rolloff downstream). nDir = 0 reproduces the kernel
                   exactly. */
                noiseDir = nDir * pow(Fb, nPow) * slipg * (nz2b - nz2);
            }
            {
                double dvh = (vh - vb[t]) + Ff / (2.0 * (Z / (1.0 + Z / Zt)));
                double P = fabs(Ff * dvh);
                /* per-group leaks differ (hair thickness diversity) */
                static const double hl[3] = {0.92, 1.0, 1.09};
                for (int hgi = 0; hgi < 3; hgi++) {
                    double lk = pow(thLeak, hl[hgi]);
                    Tr3[hgi] = lk * Tr3[hgi] + (1.0 - lk) * P;
                }
            }
            double inj = Ff / (2.0 * Z);  /* transverse waves only */
            double o1, oAB;
            if (bowWidth >= 1.0) {
                o1 = hBA + inj;              /* toward nut from contact A */
                oAB = h1 + inj;              /* toward contact B */
                /* ---- contact B (bridge side), own friction solve ---- */
                double vhB = h2 + hAB;
                double FfB = 0.0;
                if (Fb > 1e-6) {
                    double softB = 1.0 - thA * Tr3[1];
                    if (softB < thFloor) softB = thFloor;
                    double mDB = mu_d * (1.0 - thD * (1.0 - softB));
                    double mSB = mDB + (mu_s - mu_d) * softB;
                    double ZeffB = Z / (1.0 + Z / Zt);
                    double dv0B = vhB - vb[t];
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
                        if (seB < crSB) crSB += crAt * (seB - crSB);
                        else crSB = seB;
                        if (crSB > 1.0) crSB = 1.0;
                        else if (crSB < 0.0) crSB = 0.0;
                        if (crSB >= 1.0 - 1e-12) {
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
                            FfB = crSB * stickB + (1.0 - crSB) * FsB;
                        }
                    }
                    double dvhB = (vhB - vb[t]) + FfB / (2.0 * (Z / (1.0 + Z / Zt)));
                    Tr3[1] = thLeak * Tr3[1] + (1.0 - thLeak) * fabs(FfB * dvhB);
                } else if (crOn) {
                    crSB = 1.0;
                }
                double injB = FfB / (2.0 * Z);
                o2 = hAB + injB;             /* toward bridge from B */
                double oBA = h2 + injB;      /* toward contact A */
                bufAB[wab] = oAB; wab = (wab + 1) % 64;
                bufBA[wba] = oBA; wba = (wba + 1) % 64;
            } else {
                o1 = h2 + inj;
                o2 = h1 + inj;
            }
            nutLp = (1.0 - nutAf) * o1 + nutAf * nutLp;
            buf1[w1i] = -nutLp * rdmp * gutG;
            w1i = (w1i + 1) % MAXBOW;
            brLp = (1.0 - brA) * o2 + brA * brLp;
            if (gutA2 > 0.0) {
                brLp2 = (1.0 - gutA2) * brLp + gutA2 * brLp2;
                F += bowW * 2.0 * Z * brLp2;
            } else {
                F += bowW * 2.0 * Z * brLp;
            }
            }
        }
        /* STRING IMPEDANCE LOADING (2026-07-07i, the tremolo's true
           source): the bowed string exerts F = 2Z*v+ - Z*V on the bridge;
           we carried only the outgoing-wave term. Without the -Z*V load a
           real semi-infinite-line RESISTANCE is missing from the bridge,
           and the kret return forms an underdamped secondary loop whose
           interference with the direct reflection wobbles the slips at
           15-40 Hz (measured: kret=0 collapses h2 roughness 27->1 vs
           target 2.8 — and this same missing damping underlies the 2873
           Hz sing and the return-coupling note deaths). zload = physical
           at 1.0; data-gated 0. Uses Vprev (the network's one-sample
           bridge convention). */
        if (bowOn && zload > 1e-9) {
            F -= zload * bowW * Z * Vprev;
        }
        /* ---- additive voice force ---- */
        pLp = (1.0 - pA) * xv[t] + pA * pLp;
        F += pgain * pLp;
        /* ---- taraf/played web combs (drive = kappa*Vprev + alpha*xv) ---- */
        if (!psv) {
        for (int i = 0; i < nv; i++) {
            double x = kap[i] * Vprev + alphaw[i] * xv[t];
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
            if (jawRoll > 1e-12 && rollD[i] > 1e-12)
                ySer = roll_read(b, wi, len, L[i], w0[i], w1[i], w2[i],
                                 w3[i], w4[i], rollD[i]);
            double y = (1.0 - g[i]) * (x + cs[i] * vx1[i] + cp[i] * vx2[i])
                - cs[i] * y1 - cp[i] * y2
                + g[i] * ySer;
            /* IN-LOOP JAWARI LOSS (2026-07-07g, the Ab tremolo fix):
               a hard-ringing taraf GRAZES the jawari bridge and loses
               energy to the buzz — the contact is an amplitude-
               dependent damper that self-limits ring accumulation.
               Our linear combs let coincidence rings (e.g. the Ab3-h2
               partial under a played Ab4) pile up to the played note's
               level (+16 dB vs the target's -18) and BEAT against it
               (the 0.8 Hz tremolo). Loss engages as the voice envelope
               exceeds jq x the bridge-velocity field (self-scaling, no
               absolute threshold); effective t60 shortens for hot
               rings, quiet shimmer keeps the long ring. Per-bank via
               the same jawari depths as the buzz. jl = 0 exact. */
            double wv = y;
            /* IN-LOOP JAWARI CONTACT v2 (2026-07-07n): one-sided smooth
               grazing at the bridge — the string presses the flat bone on
               ONE half-cycle, compressing that half of the reflection
               (passive: (1 - jn*s) in [0,1], unconditionally stable).
               Unlike the output-tap buzz (jw) this RECIRCULATES: the
               asymmetric contact + stiff-wire inharmonicity intermodulate
               the ringing partials and redistribute energy across the FULL
               series (Raman's tanpura mechanism) — a taraf driven at its
               h2 regrows the fundamental, the under-note ring becomes a
               choir. jn = 0 exact. */
            if (jawRoll > 1e-12) {
                /* v2 BRIEF-CONTACT law (see the struct note): engage
                   only near the positive displacement extreme */
                rollE[i] = fmax(0.99999 * rollE[i], fabs(y));
                double tgt = (jn[i] > 1e-9
                              && y > jawRollAmp * rollE[i])
                    ? jawRoll * jawG * jn[i] : 0.0;
                rollD[i] += rollAv[i] * (tgt - rollD[i]);
                if (rollD[i] > 3.0) rollD[i] = 3.0;
            } else if (jn[i] > 1e-9 && y > 0.0) {
                /* jq2 = the CONTACT clearance (its own, small: the string
                   grazes the bone at normal ring amplitude — that is what
                   makes a jawari bridge buzz; jq=0.4 is the LOSS gate,
                   sized to self-limit only hot coincidence rings) */
                if (jawRho > 1e-12) {
                    /* v3 COLLISION (2026-07-20, the attack-comb round):
                       one-sided ELASTIC fold at the clearance — the
                       excess displacement REFLECTS about the barrier
                       (restitution jawRho), it is not absorbed. At
                       rho→1 the redistribution is near-lossless (the
                       compressor's intermodulation and its ring DRAIN
                       are the same multiply — measured −7.8 dB of web
                       ring at depth .4; a reflection decouples them)
                       and the fold map is PERIOD-DOUBLING-CAPABLE (the
                       smooth compressor is monotonic and cannot
                       bifurcate — the target's attack odd-comb needs a
                       collision route). |wv| <= y always (passive).
                       jawRho = 0 is the legacy law, byte-exact. */
                    double e = y - jq2;
                    if (e > 0.0)
                        wv = y - jawG * jn[i] * (1.0 + jawRho) * e;
                } else {
                    double s = y / (y + jq2 + 1e-30);
                    wv = y * (1.0 - jawG * jn[i] * s);
                }
            }
            if (jl[i] > 1e-9) {
                double e = 0.9995 * jenv[i] + 0.0005 * fabs(y);
                jenv[i] = e;
                /* clearance is GEOMETRIC (absolute per-string gap):
                   the field-relative form (jq*venv) never engaged —
                   a -16 dB ring reads 'cold' next to the played voice.
                   jq is now the absolute clearance in kernel units
                   (N_jaw_thr, bisected). */
                double hot = e / (e + jq + 1e-30);
                wv = wv * (1.0 - jl[i] * hot);
            }
            b[wi] = wv;
            widx[i] = (wi + 1) % len;
            vx2[i] = vx1[i];
            vx1[i] = x;
            /* PER-BANK JAWARI (2026-07-07f, user design): some sarangi
               bridges have a jawari curve — the string GRAZES the flat
               bone each half-cycle when amplitude is high, generating the
               pitch-synchronous buzz. Depth is a BANK property: raga-tuned
               taraf buzz most, chromatic taraf and played strings little.
               v1 = output-tap rectified grazing (|y| with a slow DC track
               removed — buzz blooms and decays WITH the string, radiates
               through the shared bridge force, loop stays linear/stable).
               In-loop (termination) jawari is the v2 upgrade if the ear
               wants the buzz to recirculate. Data-gated: jw = 0 exactly
               reproduces the previous kernel. */
            double yo = y;
            if (jw[i] > 1e-9) {
                double r = fabs(y);
                jdc[i] = 0.99947 * jdc[i] + 0.00053 * r;  /* ~20 ms @96k */
                yo = y + jawG * jw[i] * (r - jdc[i]);
            }
            vlp[i] = (1.0 - lpA[i]) * yo + lpA[i] * vlp[i];
            F += wout[i] * vlp[i];
            /* DIRECT TARAF RADIATION (2026-07-07l): the sympathetic
               strings sit on their OWN small bridge on the same skin —
               they radiate directly, not only through the main bridge
               force node. tdir raises taraf audibility with ZERO loop
               change (N_taraf_out scaled the bridge force = loop gain,
               invisible to the stability projection — the 'ring' it
               bought was loop heat). Still passes R = rfir x E_lp. */
            dwt[i] += (1.0 - aDuck) * (dtg[i] - dwt[i]);
            tdir += dwt[i] * twt[i] * wout[i] * vlp[i];
        }
        } else {
            /* PASSIVE WAVE JUNCTION, PASS 1 (2026-07-09): each comb splits
               as y_i = (1-g_i)*x_i + S_i with S_i state-only.  The drive is
               x_i = alphaw*xv - zdrv*V (delay-free; zdrv = 2*Z_i/(1-g_i)),
               and the string's force on the bridge is f_i = y_i + zi*V —
               together the comb realizes f_i = f_src,i - Z_i(1+G)/(1-G)*V,
               the positive-real string input impedance of the FFT twin
               (coupled.junction_solve).  Accumulate F0 = all V-independent
               force terms, then solve V and the junction bridge force
               F = F0 - jzsum*V in closed form. */
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
                if (jawRoll > 1e-12 && rollD[i] > 1e-12)
                    ySer = roll_read(b, wi, len, L[i], w0[i], w1[i],
                                     w2[i], w3[i], w4[i], rollD[i]);
                double S = (1.0 - g[i]) * (cs[i] * vx1[i] + cp[i] * vx2[i])
                    - cs[i] * y1 - cp[i] * y2
                    + g[i] * ySer;
                sv[i] = S;
                F += (1.0 - g[i]) * alphaw[i] * xv[t] + S;
            }
            /* body state part of V (the filters below recompute the same V
               from the solved F — they own the state updates) */
            double Vst = yinf * (dcRho * hpY - hpG * hpX1);
            for (int k = 0; k < K; k++)
                Vst += bA[k] * (ba1[k] * by1[k] + ba2[k] * by2[k]
                                - bn0[k] * bx2[k]);
            double Vs = (Vst + jy0 * F) / jden;
            F -= jzsum * Vs;
        }
        /* ---- body: admittance V + radiation ---- */
        hpY = hpG * (F - hpX1) + dcRho * hpY;
        hpX1 = F;
        double V = yinf * hpY;
        double rad = c0 * F;
        for (int k = 0; k < K; k++) {
            double y = bn0[k] * (F - bx2[k]) + ba1[k] * by1[k]
                + ba2[k] * by2[k];
            bx2[k] = bx1[k]; bx1[k] = F;
            by2[k] = by1[k]; by1[k] = y;
            V += bA[k] * y;
            rad += bC[k] * y;
        }
        if (psv) {
            /* PASSIVE JUNCTION, PASS 2: run each comb at the solved V —
               y_i = (1-g_i)*x_i + S_i is the full difference equation
               (pass-1 cached the state part); jawari nonlinearities and
               state writes exactly as the legacy loop.  The main-bridge
               string force f_i = y_i + zi*V is already inside F via
               F0 - jzsum*V, so the wout*vlp radiated tap feeds ONLY the
               direct taraf path (adding it to F would double-count). */
            for (int i = 0; i < nv; i++) {
                double x = alphaw[i] * xv[t] - zdrv[i] * V;
                double y = (1.0 - g[i]) * x + sv[i];
                double wv = y;
                if (jawRoll > 1e-12) {
                    rollE[i] = fmax(0.99999 * rollE[i], fabs(y));
                    double tgt = (jn[i] > 1e-9
                                  && y > jawRollAmp * rollE[i])
                        ? jawRoll * jawG * jn[i] : 0.0;
                    rollD[i] += rollAv[i] * (tgt - rollD[i]);
                    if (rollD[i] > 3.0) rollD[i] = 3.0;
                } else if (jn[i] > 1e-9 && y > 0.0) {
                    if (jawRho > 1e-12) {
                        /* v3 collision fold — see the legacy-loop note */
                        double e = y - jq2;
                        if (e > 0.0)
                            wv = y - jawG * jn[i] * (1.0 + jawRho) * e;
                    } else {
                        double s = y / (y + jq2 + 1e-30);
                        wv = y * (1.0 - jawG * jn[i] * s);
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
                    yo = y + jawG * jw[i] * (r - jdc[i]);
                }
                vlp[i] = (1.0 - lpA[i]) * yo + lpA[i] * vlp[i];
                dwt[i] += (1.0 - aDuck) * (dtg[i] - dwt[i]);
            tdir += dwt[i] * twt[i] * wout[i] * vlp[i];
            }
        }
        if (bowOn) {
            /* bridge-motion return into the string, v- = -v+ + H_b(V):
               retMode >= 0.5 -> PHYSICAL BRIDGE MOBILITY (2026-07-07c):
               the sarangi bridge is a bone MASS riding the skin membrane;
               string-end transverse velocity follows bridge motion through
               the mass-on-compliance resonance (f_b, Q_b) — a resonant
               2-pole, unit DC gain, minimum phase. Same asymptotic roll-off
               as the legacy arbitrary LP(ret_fc)^2 (which existed only to
               stop the flat-return "mic feedback" at ~2.3 kHz), but the
               shape and phase are now a bridge property, not a tuning knob.
               retMode < 0.5 -> legacy cascaded one-poles (A/B renderable). */
            double vr;
            if (retMode >= 0.5) {
                vr = rb0 * (kretG * V) - ra1 * vRet - ra2 * vRet2;
                vRet2 = vRet; vRet = vr;
            } else {
                vRet = (1.0 - retA) * (kretG * V) + retA * vRet;
                vRet2 = (1.0 - retA) * vRet + retA * vRet2;
                vr = vRet2;
            }
            /* STIFFNESS DISPERSION (gut string): allpass (c<0) makes upper
               partials ring SHARP — h2 a few cents off 2f0, detuning the
               octave-taraf coincidence behind the F4 capture. Cascaded
               dispNi times (thick gut is strongly dispersive); dispNi=1 ==
               the legacy single stage, op-for-op. GUT ROUND-TRIP LOSS
               (gutG): broadband distributed damping commuted to the
               reflection writes; gutG=1 -> legacy. */
            double apy = -brLp + vr;
            for (int kd = 0; kd < dispNi; kd++) {
                double ay = bowDisp * apy + apXs[kd] - bowDisp * apYs[kd];
                apXs[kd] = apy; apYs[kd] = ay; apy = ay;
            }
            buf2[w2i] = apy * rdmp * gutG;
            w2i = (w2i + 1) % MAXBOW;
        }
        venv = 0.9995 * venv + 0.0005 * fabs(V);
        disp = 0.99967 * disp + V;   /* ~5 Hz leak at 96k */
        Vprev = V;
        /* SKIN-SHAPED TARAF RADIATION (2026-07-07n): the taraf bridges
           sit on the SAME membrane — their direct radiation passes the
           same modal radiation transfer W, whose response collapses
           below the lowest skin mode. Unshaped tdir radiated the low
           joda string's 147 Hz FUNDAMENTAL flat (pair-11 pedestal
           inversion: render fundamental-heavy +30 dB, target h2-heavy).
           tshape = 0 reproduces the previous kernel exactly. */
        double trad = tdir;
        if (tshape > 0.5) {
            trad = c0 * tdir;
            /* byte-parity: keep this loop SCALAR — in the streaming split
               the auto-vectorizer turned it into 2-lane NEON whose
               reduction computes trad += round(bC*y) (separate fmul.2d)
               instead of the monolith's fused fmadd (measured: the 1-ulp
               trad drift). The scalar body compiles identically to the
               legacy one-shot. */
            #pragma clang loop vectorize(disable)
            for (int k = 0; k < K; k++) {
                double y = bn0[k] * (tdir - tx2[k]) + ba1[k] * ty1[k]
                    + ba2[k] * ty2[k];
                tx2[k] = tx1[k]; tx1[k] = tdir;
                ty2[k] = ty1[k]; ty1[k] = y;
                trad += bC[k] * y;
            }
            /* tmix < 1 fills the W inter-mode valleys for the taraf
               path: the W poles were fitted for the MAIN-BRIDGE
               radiation; the taraf bridge sits elsewhere on the skin
               with a smoother transfer (the 225-400 Hz under-note
               lattice lines sat -13 dB in the 224.9/398.3 valley).
               LF physics stays with the post-kernel rad_hp rolloff. */
            trad = tmix * trad + (1.0 - tmix) * tdir;
        }
        out[t] = rad + tdirect * trad + noiseDir;
        /* ---- modal-jawari drive RECORD (2026-07-21k) ----
           the jt web is ONE-WAY (drive = the bridge force F, output
           adds into out[] only — the null-case law rests on this), so
           the whole web is DEFERRED to a post-pass over the recorded
           drive: identical ops in identical order = bit-exact, and
           the post-pass is block-structured so strings can advance in
           parallel. */
        if (jtFr) jtFr[t] = F;
        /* ---- waveguide jawari (kernel rate, O(1) per string) ----
           (the 2026-07-21h "load anomaly" was NOT this block: a
           mis-scoped edit had GutStream arming the modal jt web
           whenever jw was on; null case loaded-gain-0 is bit-exact) */
        if (st->njw > 0 && st->jwGain != 0.0) {
            st->jwFdc += 2e-4 * (F - st->jwFdc);
            out[t] += st->jwGain
                * jw_tick(st, st->jwFprev * st->jwDrv);
            st->jwFprev = F - st->jwFdc;
        }
    }
    /* ---- modal-jawari POST-PASS (2026-07-21 night) ----
       serial replay of the exact inline machinery over the recorded
       drive (bit-exact vs the old inline block), or the PERSISTENT
       WORKER POOL when armed (bow_jt_set_threads / the offline env).
       The pool path works at any n (live 256-frame blocks included);
       per chunk: string-independent schedule, condvar broadcast to
       parked workers, fixed-order reduction. */
    if (jtFr) {
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
                out[t] += st->jtGain * jt_lp_step(st, st->jtHold);
                if (F > st->jtFmax) st->jtFmax = F;
                if (-F > st->jtFmax) st->jtFmax = -F;
            }
        } else {
            const int nth = st->jtPoolN;
            double *fdv = st->jtFdv;
            int *tkv = st->jtTkv;
            double *hp = st->jtHp;
            for (int c0 = 0; c0 < n; c0 += JT_POOL_CH) {
                const int cn = n - c0 < JT_POOL_CH ? n - c0 : JT_POOL_CH;
                /* 2a: drive schedule (string-independent recurrence) */
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
                        out[c0 + t] += st->jtGain
                            * jt_lp_step(st, st->jtHold);
                    continue;
                }
                /* 2b: hand the chunk to the parked workers */
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
                /* 2c: fixed-order reduction + output walk (the hold
                   updates at its tick sample BEFORE the add — the
                   serial machinery's exact semantics) */
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
                    out[c0 + t] += st->jtGain * jt_lp_step(st, hold);
                }
                st->jtHold = hold;
            }
        }
        if (jtFr != st->jtFrBuf)
            free(jtFr);
    }
    /* store state back (heap per-voice arrays were updated in place;
       stack-staged arrays + scalars copied out) */
    memcpy(st->bx1, bx1, sizeof bx1); memcpy(st->bx2, bx2, sizeof bx2);
    memcpy(st->by1, by1, sizeof by1); memcpy(st->by2, by2, sizeof by2);
    memcpy(st->tx1, tx1, sizeof tx1); memcpy(st->tx2, tx2, sizeof tx2);
    memcpy(st->ty1, ty1, sizeof ty1); memcpy(st->ty2, ty2, sizeof ty2);
    memcpy(st->buf1, buf1, sizeof buf1);
    memcpy(st->bufT, bufT, sizeof bufT);
    st->wti = wti; memcpy(st->buf2, buf2, sizeof buf2);
    memcpy(st->bufAB, bufAB, sizeof bufAB);
    memcpy(st->bufBA, bufBA, sizeof bufBA);
    memcpy(st->bufAM, bufAM, sizeof bufAM);
    memcpy(st->bufMA, bufMA, sizeof bufMA);
    memcpy(st->bufMB, bufMB, sizeof bufMB);
    memcpy(st->bufBM, bufBM, sizeof bufBM);
    memcpy(st->Tr3, Tr3, sizeof Tr3);
    st->ageDef = ageDef;
    memcpy(st->ageDef3, ageDef3, sizeof ageDef3);
    st->hairLp = hairLp;
    memcpy(st->hairLp3, hairLp3, sizeof hairLp3);
    st->crS = crS; st->crSB = crSB;
    memcpy(st->crS3, crS3, sizeof crS3);
    st->venv = venv;
    st->hpY = hpY; st->hpX1 = hpX1;
    st->wab = wab; st->wba = wba;
    st->wam = wam; st->wma = wma; st->wmb = wmb; st->wbm = wbm;
    st->w1i = w1i; st->w2i = w2i;
    st->nutLp = nutLp; st->brLp = brLp; st->pLp = pLp;
    st->nutLp2 = nutLp2; st->brLp2 = brLp2;
    st->vRet = vRet; st->vRet2 = vRet2;
    st->disp = disp;
    memcpy(st->apXs, apXs, sizeof apXs); memcpy(st->apYs, apYs, sizeof apYs);
    st->lcg = lcg;
    st->nz1 = nz1; st->nz2 = nz2; st->nz1b = nz1b; st->nz2b = nz2b;
    st->tEnv = tEnv; st->fbPrev = fbPrev;
    st->Vprev = Vprev;
    st->kGate = kGate;
}

void bow_free(void *vst)
{
    bow_state_t *st = (bow_state_t *)vst;
    if (!st) return;
    if (st->njw > 0) {
        free(st->jwN); free(st->jwOff); free(st->jwOi);
        free(st->jwLam2); free(st->jwMuk); free(st->jwS1h);
        free(st->jwA0); free(st->jwB0); free(st->jwKloc);
        free(st->jwFdrv); free(st->jwGainRow); free(st->jwOfrac);
        free(st->jwKcRow);
        free(st->jwB); free(st->jwU);
    }
    if (st->njt > 0) {
        jt_pool_stop(st);
        if (st->jtPoolInit) {
            pthread_mutex_destroy(&st->jtMx);
            pthread_cond_destroy(&st->jtCvW);
            pthread_cond_destroy(&st->jtCvD);
        }
        free(st->jtFrBuf); free(st->jtFdv); free(st->jtTkv);
        free(st->jtHp);
        free(st->jtM); free(st->jtMOff); free(st->jtZOff);
        free(st->jtCa); free(st->jtCb); free(st->jtCa4); free(st->jtCb4);
        free(st->jtWd); free(st->jtWdI);
        free(st->jtPhiO); free(st->jtPhiD);
        free(st->jtPhiU); free(st->jtPhiF); free(st->jtB);
        free(st->jtG); free(st->jtG4); free(st->jtGd); free(st->jtGd4);
        free(st->jtQ); free(st->jtP);
        free(st->jtDnTgt); free(st->jtDnEnv); free(st->jtDnBoost);
        free(st->jtDnLp); free(st->jtDnLp2); free(st->jtDnRng);
    }
    free(st->L);
    free(st->cs); free(st->cp); free(st->w0); free(st->w1); free(st->w2);
    free(st->w3); free(st->w4); free(st->g); free(st->lpA); free(st->wout);
    free(st->kap); free(st->alphaw); free(st->jw); free(st->jl);
    free(st->jn); free(st->zdrv); free(st->zi); free(st->twt);
    free(st->fv); free(st->dwt); free(st->dtg);
    free(st->ba1); free(st->ba2); free(st->bn0); free(st->bA); free(st->bC);
    free(st->off); free(st->arena); free(st->widx); free(st->vx1);
    free(st->vx2); free(st->vlp); free(st->jdc); free(st->jenv);
    free(st->sv);
    free(st->rollD);
    free(st->rollE);
    free(st->rollAv);
    free(st);
}

/* one-shot legacy entry point: init -> process(n) -> free.  Signature and
   output are BIT-IDENTICAL to the pre-streaming monolith. */
void bow_kernel_render(int n, double sr,
            /* controls (per sample, kernel rate) */
            const double *f0, const double *vb, const double *fb,
            const double *beta, const double *gate, const double *xv,
            /* voices */
            int nv, const int *L, const double *cs, const double *cp,
            const double *w0, const double *w1, const double *w2,
            const double *w3, const double *w4, const double *g,
            const double *lpA, const double *wout, const double *kap,
            const double *alphaw, const double *jw, const double *jl,
            const double *jn, const double *chg,
            const double *zdrv, const double *zi, const double *twt,
            /* body */
            int K, const double *ba1, const double *ba2, const double *bn0,
            const double *bA, const double *bC, double yinf, double c0,
            double dcRho,
            /* voice-force path + bow */
            double pgain, double pA, double bowW, double kret, double retA,
            double retMode, double rb0, double ra1, double ra2,
            double kdisp, double bowWidth, double bowCont,
            double Z, double Zt,
            double mu_s, double mu_d, double v0f, double nutA, double brA,
            double thLeak, double thA, double thD, double thFloor,
            double bowDisp, double jq, double jq2, double zload,
            double tdirect, double tshape, double tmix, double nA,
            double nT, double nPow, double nzHi, double nzLo,
            double nDir, double nzHiD, double passive,
            double gutG, double dispN, double nailK, double f0Open,
            double gutA2, double tdirUni,
            double torsRatio, double torsG, double torsC,
            double ageAp, double ageMs,
            double v0Powp, double v0Refp,
            double hairHzp, double hairRefp,
            double crWp, double crMsp,
            double jawRhop, double jawRollp, double jawRollAmpp,
            double *out)
{
    void *st = bow_init(sr, nv, L, cs, cp, w0, w1, w2, w3, w4, g, lpA,
                        wout, kap, alphaw, jw, jl, jn, chg, zdrv, zi, twt,
                        K, ba1, ba2, bn0, bA, bC, yinf, c0, dcRho,
                        pgain, pA, bowW, kret, retA, retMode, rb0, ra1, ra2,
                        kdisp, bowWidth, bowCont, Z, Zt, mu_s, mu_d, v0f,
                        nutA, brA, thLeak, thA, thD, thFloor, bowDisp, jq,
                        jq2, zload, tdirect, tshape, tmix, nA, nT, nPow,
                        nzHi, nzLo, nDir, nzHiD, passive,
                        gutG, dispN, nailK, f0Open, gutA2, tdirUni,
                        torsRatio, torsG, torsC, ageAp, ageMs,
                        v0Powp, v0Refp, hairHzp, hairRefp, crWp, crMsp,
                        jawRhop, jawRollp, jawRollAmpp);
    bow_process(st, n, f0, vb, fb, beta, gate, xv, out);
    bow_free(st);
}
