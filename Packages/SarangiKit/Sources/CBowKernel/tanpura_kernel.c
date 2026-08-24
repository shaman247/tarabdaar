/* TANPURA live kernel (2026-08-01): the r7 tanpura model
   (scripts/tanpura_tool.c — itself tanpura_modal.py run_modal semantics
   VERBATIM) as a playable slot instrument. One slot per keyboard note,
   mounted+settled ONCE at engine build (the settle runs through THIS
   kernel so q0 is the solver's own equilibrium — the jt startup-ping
   lesson), then plucked at note-on. Inactive slots cost nothing; a slot
   auto-idles when its output stays below the floor. Physics per slot:
   damped modal rotation (v bank + detuned w bank), implicit grid
   contact (solve_matrix = jt_web_tool.c VERBATIM), x4 substep at deep
   engagement, round-6 contact-mediated polarization (b_eff = b −
   w²/2R_t, lateral reaction −(w/R_t)·F_n), mid-string angled plucks.
   Tables are built in Swift (TanpuraTables — LOCKSTEP with
   tanpura_model.build_tables; the artifact params/tanpura_live.json
   carries the construction laws + pitch-calibration curve). */
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#endif
#include <stdio.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif

#define TP_MAXM 384   /* r29: corner-resolution mode counts
   (M*f0 ~ 21000 -> M up to 340; the stack-smash law) */
#define TP_MAXJ 64

/* float fast pow (bow_kernel.c jt_fastpow VERBATIM — the jt live law:
   pow() dominated the contact cost; float32 zone math with double
   modal state is the proven live precision split) */
static inline float tp_fastpow(float x, float A)
{
    union { float f; int32_t i; } u, v;
    u.f = x;
    const int e = ((u.i >> 23) & 255) - 127;
    u.i = (u.i & 0x007fffff) | 0x3f800000;
    const float m = u.f;
    const float lm = (((-7.915036575e-02f * m + 6.288157292e-01f) * m
                       - 2.081060203e+00f) * m + 4.028372767e+00f) * m
        - 2.496773768e+00f;
    const float y = A * ((float)e + lm);
    const float yi = floorf(y);
    const float yf = y - yi;
    const float p2 = ((7.901993961e-02f * yf + 2.241264441e-01f) * yf
                      + 6.968385764e-01f) * yf + 9.998119628e-01f;
    v.i = ((int32_t)yi + 127) << 23;
    return p2 * v.f;
}

/* the r7 implicit contact solve (12 under-relaxed outer + 10
   diag-Newton + Hunt-Crossley), float zone math + fastpow + an
   ACTIVE-column list (zero-force columns skip — measured numerically
   null offline, the jt active-set law) */
static void tp_solve(int nn, const float *eta0, const float *udot,
                     const float *Gm, const float *gdm,
                     float kc, float alpha, float hcB, float *F)
{
    /* F arrives WARM (the previous sample's converged forces — the
       fixed point moves slowly in steady ring, so the under-relaxed
       outer loop exits in 1-3 iterations instead of running all 12;
       the caller zeroes F on pluck/reset) */
    float c[TP_MAXJ], f[TP_MAXJ];
    int act[TP_MAXJ], aci[TP_MAXJ], nac;
    const float am1 = alpha - 1.0f;
    for (int o = 0; o < 12; o++) {
        nac = 0;
        for (int i = 0; i < nn; i++) {
            float gf = 0.0f;
            const float *Gr = Gm + (size_t)i * nn;
            for (int j = 0; j < nn; j++) gf += Gr[j] * F[j];
            c[i] = eta0[i] - (gf - gdm[i] * F[i]);
            act[i] = c[i] > 0.0f;
            if (act[i]) {
                f[i] = kc * c[i] * tp_fastpow(c[i], am1);
                aci[nac++] = i;
            } else f[i] = 0.0f;
        }
        for (int it = 0; it < 10; it++) {
            for (int a = 0; a < nac; a++) {
                const int i = aci[a];
                float eta = c[i] - gdm[i] * f[i];
                float g, gp;
                if (eta > 0.0f) {
                    g = f[i] - kc * eta * tp_fastpow(eta, am1);
                    gp = 1.0f + kc * alpha * gdm[i]
                         * tp_fastpow(eta > 1e-12f ? eta : 1e-12f, am1);
                } else { g = f[i]; gp = 1.0f; }
                float fn = f[i] - g / gp;
                if (fn < 0.0f) fn = 0.0f;
                float cap = c[i] / (gdm[i] > 1e-30f ? gdm[i] : 1e-30f);
                if (fn > cap) fn = cap;
                f[i] = fn;
            }
        }
        float dF = 0.0f, fm = 1e-2f;
        for (int i = 0; i < nn; i++) {
            float d = fabsf(f[i] - F[i]);
            if (d > dF) dF = d;
            if (f[i] > fm) fm = f[i];
        }
        for (int i = 0; i < nn; i++) F[i] += 0.5f * (f[i] - F[i]);
        if (dF < 1e-4f * fm) {   /* warm-start exit: converged ring
                                    states leave in 1-2 outers;
                                    transients run more (pool era —
                                    headroom favors fidelity).
                                    fm floor 1e-2 => ABSOLUTE floor
                                    1e-4*1e-2 = 1e-6 on quiet tails —
                                    the double tool's own quiet-regime
                                    tolerance (its 1e-6*fm with fm>=1).
                                    The old fm>=1 floor tolerated
                                    ~100% force error on tails (the
                                    -67 dB perpetual limit cycle /
                                    never-idle bug); a fully-relative
                                    exit instead ran all 12 outers on
                                    every quiet solve (note 69 alone
                                    measured 1.03x RT — the speed-gate
                                    blowup). Residual sub-audible
                                    floors are culled by the
                                    stagnation idle. (2026-08-03) */
            for (int i = 0; i < nn; i++) F[i] = f[i];
            break;
        }
    }
    /* F now holds the PRE-Hunt-Crossley converged forces (the warm
       state for the next call); the hc factor applies into Fout */
}

static void tp_hc(int nn, const float *udot, float hcB,
                  const float *F, float *Fout)
{
    for (int i = 0; i < nn; i++) {
        float hc = 1.0f + hcB * (-udot[i]);
        if (hc < 0.15f) hc = 0.15f;
        if (hc > 1.0f) hc = 1.0f;
        Fout[i] = F[i] * hc;
    }
}

typedef struct {
    int used, active, M, J;
    /* ---- FD CONTINUUM MODE (round 20, the live hybrid): when
       is_fd, the slot is a spatially-resolved Bilbao string with
       penalty contact (the offline tanpura_fd.simulate semantics at
       96 kHz internal rate); the modal fields above stay unused. */
    int is_fd, fdN, fdOi, fdSteps;   /* grid pts, obs node, steps/48k */
    double *fdU, *fdUp, *fdB, *fdPsh, *fdScr;
    double *fdUeq;                   /* settled wrap (touch anchor) */
    double fdTouch;                  /* finger damp at pluck (1 = off) */
    double fdLam2, fdMuk, fdS1h, fdA0, fdB0, fdKc, fdAlpha;
    double fdObsPrev;
    /* tables (owned) */
    double *ca, *cb, *ca4, *cb4, *ca2, *cb2, *cas, *cbs, *wd;
    double *caw, *cbw, *wdw;
    double *iwd, *iwdw;            /* 1/wd tables (the jt division law) */
    double *Phi, *phiF, *b, *q0;
    float *Phif, *phiFf;           /* float twins for the hot matvecs */
    float *Gf, *G4f, *gdf, *gd4f;
    float *G2f, *gd2f;             /* dt/2 compliance (= 4x G4) */
    double *phi_o, *dq;
    double kc, alpha, hcB, deep, dt, gain;
    double cg, sg, av, aw;      /* pol mixing + pluck-angle split */
    double rt;                  /* transverse curvature (0 = off) */
    /* THREAD ELEMENT (round 11): 1-DOF jiva oscillator riding the
       bone under gth; th_f = 0 = legacy rigid bump */
    double *gth;
    double thBase, thH;
    double thCa, thCb, thWd, thM;
    int rampN;                  /* pluck draw ramp (samples; round 13:
                                   one string period — 0 = instant) */
    int ovs;                    /* internal steps per OUTPUT sample
                                   (r29-live: tables at 96k, output
                                   48k -> ovs 2; the 48k contact rate
                                   RUNS AWAY at the r29 graze) */
    /* state */
    double *q, *p, *qw, *pw;
    double thz, thv;
    long rampLeft;
    double rampAmp, rampPrev;
    float Fw[TP_MAXJ];          /* warm contact forces (pre-hc) */
    double idle_env;            /* output envelope for auto-idle */
    double envPrev;             /* stagnation-idle: last block env */
    int stagn;                  /* blocks with no decay while quiet */
    double pen0;                /* settled STATIC wrap penetration:
                                   > deep marks a PERMANENT-DEEP slot
                                   (skip the doomed base attempt) */
    long deepRun;               /* consecutive dynamic-deep fires */
    long permaCount;            /* samples left in adaptive perma
                                   mode (re-probe when exhausted) */
    int forceDeep;              /* x4 contact ALWAYS (extrapolated
                                   register — see mount) */
    double costEma;             /* smoothed render cost (s/block) —
                                   the pool's heavy-first sort key */
    /* ---- ENERGY-STABLE (SAV) CONTACT (2026-08-03d, user-ratified
       vs legacy on the full gauge suite) — the modal contact path.
       kq/kp = exact constant-force-over-step response (dq=F kq,
       dp=F kp); svG = matching within-step compliance; psi/eta/bud
       = per-node aux state (RSAV dissipation budget). The deep/
       perma/forceDeep machinery is DEAD under SAV (passive at any
       rate/M by construction; midpoint-g owns brightness). */
    double *svKq, *svKp, *svG;
    double svPsi[TP_MAXJ], svEta[TP_MAXJ], svBud[TP_MAXJ];
    double svPsi0[TP_MAXJ], svEta0[TP_MAXJ], svBud0[TP_MAXJ];
    /* ---- LIVE BEND + RELEASE (Tarabdaar 2026-08-05): base copies of
       the mount tables let a bend rescale every mode's rotation in
       place (tp_apply_bend); relMul < 1 applies extra broadband
       decay toward the settled wrap each internal sample. ---- */
    double bendRatio;           /* current mode-frequency scale (1 = unbent) */
    double *wd0, *wdw0;         /* base (mount-time) mode frequencies */
    double *envE, *envEw;       /* per-mode damping envelopes hypot(ca,cb) */
    double relMul;              /* per-internal-sample release multiplier
                                   (1 = held/natural ring) */
    /* ---- PLUCK ISOLATION + PLUCK DRIVE (Tarabdaar 2026-08-15; the
       STRING-BANK rework, same day). The isolation value (op 3,
       `iso`) makes each pluck a SEPARATE STRING: at the pluck the
       primary slot's ringing state MIGRATES to a free CLONE slot
       (full jawari simulation continues there at the old pitch —
       the clone freezes copies of the 11 bend-mutable tables and
       aliases the rest), and the pluck lands on settled state. The
       kernel keeps the N most-recently-played strings alive
       (c->polyMax clones, global); overflow evicts the OLDEST clone
       into its owner's linear ghost bank ("decay without the full
       jawari simulation" — the pile-up tier), and auto-idle culls
       below audibility. iso scales how much of the old string's
       ring survives the migration (1 = in full). iso 0 = legacy:
       the pluck rides the ringing primary. `drive` scales the pluck
       displacement while gain rides gain0/drive — contact
       engagement vs radiated level, decoupled. ---- */
    double iso;                 /* pluck isolation (op 3; 0 = legacy) */
    int justMigrated;           /* pre-pluck bend already migrated */
    int isClone;                /* clone: owns only state + frozen
                                   tables; everything else aliased */
    int owner;                  /* clone: primary slot index */
    long long seq;              /* clone: pluck sequence (LRU key) */
    double drive;
    double gain0;               /* mount output gain (gain = gain0/drive) */
    /* ---- GHOST BANK (Tarabdaar 2026-08-15): the previous notes'
       ring-out. A deviation state that rotates through the SAME
       per-mode damping envelopes as the live string (correct pitches
       and t60s, full natural decay) but skips zone/contact/thread —
       the demoted-string law applied to old notes, so a slot's whole
       history of re-plucks costs one linear bank. Ghosts are LINEAR,
       so every handoff superposes exactly into the one bank. Tables
       are frozen at the first handoff (composed to OUTPUT rate:
       R_out = R_in^ovs) so a later bend retunes only the live
       string, not the ringing history. gGain freezes the output
       trim of the first handoff; later handoffs at a different live
       gain are pre-scaled by gain/gGain (linearity), so drive edits
       never step the ghost tail. ---- */
    int ghostOn;
    double *gq, *gp, *gqw, *gpw;            /* deviation state */
    double *gca, *gcb, *gwd, *giwd;         /* frozen v-bank rotation */
    double *gcaw, *gcbw, *gwdw, *giwdw;     /* frozen w-bank rotation */
    double gcg, gsg;                        /* frozen pol mix (output rate) */
    double gGain;
    double ghost_env;
    int demoted;                /* TAIL DEMOTION (perf, 2026-08-03e):
                                   below inaudibility the grazing-knee
                                   converts ~nothing (the knee law) —
                                   the voice rings LINEARLY about the
                                   wrap. q holds the DEVIATION from
                                   q0 (same rotation, no DC fall, no
                                   re-engagement slam); zone/contact/
                                   thread are skipped. Re-pluck
                                   promotes: q += q0, sv state from
                                   the settled snapshot. */
} tp_slot;

static int tp_sav_contact(tp_slot *s, const float *beff,
                          const float *uf, const float *udf,
                          double *fth_out, float *Fn_out);

#define TP_ABLK 4096            /* max job block */
#define TP_ARING 8               /* job ring */
#define TP_OUTN 32768            /* rendered-audio ring */
#define TP_EVN 128               /* note-event ring */
#define TP_MAXW 8

typedef struct tp_ctx tp_ctx;
typedef struct { tp_ctx *c; int idx; } tp_warg;

#define TP_CLONES 16            /* string-bank clone pool (>= max poly) */

struct tp_ctx {
    int nslots;                  /* user slots + TP_CLONES */
    int nUser;                   /* mounted (pluckable) slots */
    long long pluckSeq;          /* global pluck counter (clone LRU) */
    int polyMax;                 /* live history strings (atomic-ish) */
    tp_slot *s;
    int deep_budget;             /* sync path: 3; pool path: huge */
    long resets;                 /* divergence-guard resets (telemetry) */
    /* ---- note-event SPSC ring (audio thread -> dispatcher) ---- */
    int evSlot[TP_EVN];
    int evOp[TP_EVN];            /* 0 note, 1 bend, 2 release */
    double evAmp[TP_EVN];        /* op 0: amp (<0 damps); op 1: ratio;
                                    op 2: rate 1/s */
    long long evW, evR;          /* atomic W (producer), R (dispatcher) */
    /* ---- async one-block-late machinery (the jt pattern) ---- */
    int poolN;                   /* workers (>=2 arms async) */
    int poolInit, quit;
    pthread_t wTid[TP_MAXW], dTid;
    tp_warg wArg[TP_MAXW];
    pthread_mutex_t mx;
    pthread_cond_t cvW, cvD;
    int gen, done, wPer, wN;     /* worker job state */
    double *wBuf;                /* per-worker accumulation buffers */
    int actList[96], actN;       /* active slots+clones, HEAVY-FIRST */
    int wCursor;                 /* work-stealing cursor (atomic) */
    int overN;                   /* controller streak (unused) */
    long lastUr;                 /* underrun-feedback watermark */
    int lastPluck;               /* most recent pluck slot (protected) */
    int jobN[TP_ARING];
    long long jobW, jobR;        /* atomic W (callback), R (dispatcher) */
    double outRing[TP_OUTN];
    long long outW, outR;        /* atomic W (dispatcher), R (callback) */
    long underruns;
    double lastOut;              /* fade-fill state on underrun */
};

void *tanpura_create(int nslots)
{
    tp_ctx *c = (tp_ctx *)calloc(1, sizeof(tp_ctx));
    c->nUser = nslots;
    c->nslots = nslots + TP_CLONES;
    c->polyMax = 6;
    c->s = (tp_slot *)calloc((size_t)c->nslots, sizeof(tp_slot));
    c->deep_budget = 3;
    /* clone pool: state + frozen-table buffers sized for any owner
       (TP_MAXM); everything else aliases the owner at migration */
    for (int i = nslots; i < c->nslots; i++) {
        tp_slot *s = &c->s[i];
        s->isClone = 1;
        s->used = 1;
        s->active = 0;
#define TPA(x, n) s->x = (double *)calloc((size_t)(n), sizeof(double))
        TPA(q, TP_MAXM); TPA(p, TP_MAXM);
        TPA(qw, TP_MAXM); TPA(pw, TP_MAXM);
        TPA(ca, TP_MAXM); TPA(cb, TP_MAXM);
        TPA(wd, TP_MAXM); TPA(iwd, TP_MAXM);
        TPA(caw, TP_MAXM); TPA(cbw, TP_MAXM);
        TPA(wdw, TP_MAXM); TPA(iwdw, TP_MAXM);
        TPA(svKq, TP_MAXM); TPA(svKp, TP_MAXM);
        TPA(svG, TP_MAXJ * TP_MAXJ);
#undef TPA
    }
    return c;
}

void tanpura_set_poly(void *vc, int n)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (n < 0) n = 0;
    if (n > TP_CLONES) n = TP_CLONES;
    __atomic_store_n(&c->polyMax, n, __ATOMIC_RELAXED);
}

static void tp_slot_free(tp_slot *s)
{
    if (!s->used) return;
    if (s->isClone) {
        /* clones own only their state + frozen bend-mutable tables;
           everything else aliases the owner — never free it here */
#define TPCF(x) free(s->x); s->x = 0
        TPCF(q); TPCF(p); TPCF(qw); TPCF(pw);
        TPCF(ca); TPCF(cb); TPCF(wd); TPCF(iwd);
        TPCF(caw); TPCF(cbw); TPCF(wdw); TPCF(iwdw);
        TPCF(svKq); TPCF(svKp); TPCF(svG);
#undef TPCF
        s->used = 0;
        return;
    }
#define TPF(x) free(s->x); s->x = 0
    TPF(fdU); TPF(fdUp); TPF(fdB); TPF(fdPsh); TPF(fdScr);
    TPF(fdUeq);
    TPF(ca); TPF(cb); TPF(ca4); TPF(cb4); TPF(ca2); TPF(cb2);
    TPF(cas); TPF(cbs); TPF(wd);
    TPF(caw); TPF(cbw); TPF(wdw);
    TPF(iwd); TPF(iwdw);
    TPF(Phi); TPF(phiF); TPF(b);
    TPF(Phif); TPF(phiFf); TPF(gth);
    TPF(Gf); TPF(G4f); TPF(gdf); TPF(gd4f); TPF(G2f); TPF(gd2f);
    TPF(phi_o); TPF(dq); TPF(q0); TPF(q); TPF(p); TPF(qw); TPF(pw);
    TPF(svKq); TPF(svKp); TPF(svG);
    TPF(wd0); TPF(wdw0); TPF(envE); TPF(envEw);
    TPF(gq); TPF(gp); TPF(gqw); TPF(gpw);
    TPF(gca); TPF(gcb); TPF(gwd); TPF(giwd);
    TPF(gcaw); TPF(gcbw); TPF(gwdw); TPF(giwdw);
#undef TPF
    s->used = 0;
}

void tanpura_free(void *vc)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (c->poolN >= 2) {
        pthread_mutex_lock(&c->mx);
        c->quit = 1;
        pthread_cond_broadcast(&c->cvW);
        pthread_mutex_unlock(&c->mx);
        for (int i = 0; i < c->poolN; i++)
            pthread_join(c->wTid[i], NULL);
        pthread_join(c->dTid, NULL);
        free(c->wBuf);
    }
    for (int i = 0; i < c->nslots; i++) tp_slot_free(&c->s[i]);
    free(c->s);
    free(c);
}

static double *tp_dup(const double *a, size_t n)
{
    double *d = (double *)malloc(n * sizeof(double));
    memcpy(d, a, n * sizeof(double));
    return d;
}

void tanpura_mount(void *vc, int slot, int M, int J,
                   const double *ca, const double *cb,
                   const double *ca4, const double *cb4,
                   const double *ca2, const double *cb2,
                   const double *cas, const double *cbs,
                   const double *wd,
                   const double *caw, const double *cbw,
                   const double *wdw,
                   const double *Phi, const double *phiF,
                   const double *b, const double *G, const double *G4,
                   const double *gd, const double *gd4,
                   const double *phi_o, const double *dq,
                   const double *g_th, double th_base, double th_h,
                   double th_f, double th_q, double th_k,
                   double kc, double alpha, double hcB, double deep,
                   double dt, double gain,
                   double pol_g, double pol_th, double pol_rt,
                   int ramp_n)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots || M > TP_MAXM || J > TP_MAXJ)
        return;
    tp_slot *s = &c->s[slot];
    tp_slot_free(s);
    s->M = M; s->J = J;
    s->ca = tp_dup(ca, M); s->cb = tp_dup(cb, M);
    s->ca4 = tp_dup(ca4, M); s->cb4 = tp_dup(cb4, M);
    s->ca2 = tp_dup(ca2, M); s->cb2 = tp_dup(cb2, M);
    s->cas = tp_dup(cas, M); s->cbs = tp_dup(cbs, M);
    s->wd = tp_dup(wd, M);
    s->caw = tp_dup(caw, M); s->cbw = tp_dup(cbw, M);
    s->wdw = tp_dup(wdw, M);
    s->iwd = (double *)malloc((size_t)M * sizeof(double));
    s->iwdw = (double *)malloc((size_t)M * sizeof(double));
    for (int i = 0; i < M; i++) {
        s->iwd[i] = 1.0 / wd[i];
        s->iwdw[i] = 1.0 / wdw[i];
    }
    /* live-bend base tables: mode freqs + damping envelopes (ca/cb
       are E*cos/sin(wd*dt), so E = hypot — exact) */
    s->wd0 = tp_dup(wd, M);
    s->wdw0 = tp_dup(wdw, M);
    s->envE = (double *)malloc((size_t)M * sizeof(double));
    s->envEw = (double *)malloc((size_t)M * sizeof(double));
    for (int i = 0; i < M; i++) {
        s->envE[i] = hypot(ca[i], cb[i]);
        s->envEw[i] = hypot(caw[i], cbw[i]);
    }
    s->bendRatio = 1.0;
    s->relMul = 1.0;
    s->Phi = tp_dup(Phi, (size_t)M * J);
    s->phiF = tp_dup(phiF, (size_t)M * J);
    s->Phif = (float *)malloc((size_t)M * J * sizeof(float));
    s->phiFf = (float *)malloc((size_t)M * J * sizeof(float));
    for (int i = 0; i < M * J; i++) {
        s->Phif[i] = (float)Phi[i];
        s->phiFf[i] = (float)phiF[i];
    }
    s->b = tp_dup(b, J);
    s->Gf = (float *)malloc((size_t)J * J * sizeof(float));
    s->G4f = (float *)malloc((size_t)J * J * sizeof(float));
    for (int i = 0; i < J * J; i++) {
        s->Gf[i] = (float)G[i];
        s->G4f[i] = (float)G4[i];
    }
    s->gdf = (float *)malloc((size_t)J * sizeof(float));
    s->gd4f = (float *)malloc((size_t)J * sizeof(float));
    for (int i = 0; i < J; i++) {
        s->gdf[i] = (float)gd[i];
        s->gd4f[i] = (float)gd4[i];
    }
    s->G2f = (float *)malloc((size_t)J * J * sizeof(float));
    s->gd2f = (float *)malloc((size_t)J * sizeof(float));
    for (int i = 0; i < J * J; i++) s->G2f[i] = 4.0f * s->G4f[i];
    for (int i = 0; i < J; i++) s->gd2f[i] = 4.0f * s->gd4f[i];
    s->phi_o = tp_dup(phi_o, M); s->dq = tp_dup(dq, M);
    s->q0 = (double *)calloc((size_t)M, sizeof(double));
    s->q = (double *)calloc((size_t)M, sizeof(double));
    s->p = (double *)calloc((size_t)M, sizeof(double));
    s->qw = (double *)calloc((size_t)M, sizeof(double));
    s->pw = (double *)calloc((size_t)M, sizeof(double));
    s->kc = kc; s->alpha = alpha; s->hcB = hcB;
    s->deep = deep; s->dt = dt; s->gain = gain;
    /* SAV tables: exact-response kick + matching compliance (built
       from the DOUBLE mount inputs; no artifact/lockstep change) */
    s->svKq = (double *)malloc((size_t)M * sizeof(double));
    s->svKp = (double *)malloc((size_t)M * sizeof(double));
    s->svG = (double *)malloc((size_t)J * J * sizeof(double));
    for (int k = 0; k < M; k++) {
        const double wdt = wd[k] * dt;
        s->svKq[k] = (1.0 - cos(wdt)) / (wd[k] * wd[k]);
        s->svKp[k] = sin(wdt) / wd[k];
    }
    for (int j = 0; j < J; j++)
        for (int i = 0; i < J; i++) {
            double a = 0.0;
            for (int k = 0; k < M; k++)
                a += Phi[(size_t)k * J + j] * s->svKq[k]
                     * phiF[(size_t)k * J + i];
            s->svG[(size_t)j * J + i] = a;
        }
    memset(s->svPsi, 0, sizeof(s->svPsi));
    memset(s->svEta, 0, sizeof(s->svEta));
    memset(s->svBud, 0, sizeof(s->svBud));
    s->cg = cos(pol_g * dt); s->sg = sin(pol_g * dt);
    s->av = cos(pol_th); s->aw = sin(pol_th);
    s->drive = 1.0;
    s->gain0 = gain;
    s->ghostOn = 0;
    s->ghost_env = 0.0;
    s->gcg = 1.0; s->gsg = 0.0;
    s->gGain = gain;
    s->gq = (double *)calloc((size_t)M, sizeof(double));
    s->gp = (double *)calloc((size_t)M, sizeof(double));
    s->gqw = (double *)calloc((size_t)M, sizeof(double));
    s->gpw = (double *)calloc((size_t)M, sizeof(double));
    s->gca = (double *)calloc((size_t)M, sizeof(double));
    s->gcb = (double *)calloc((size_t)M, sizeof(double));
    s->gwd = (double *)calloc((size_t)M, sizeof(double));
    s->giwd = (double *)calloc((size_t)M, sizeof(double));
    s->gcaw = (double *)calloc((size_t)M, sizeof(double));
    s->gcbw = (double *)calloc((size_t)M, sizeof(double));
    s->gwdw = (double *)calloc((size_t)M, sizeof(double));
    s->giwdw = (double *)calloc((size_t)M, sizeof(double));
    s->rt = pol_rt;
    s->gth = tp_dup(g_th, J);
    s->thBase = th_base; s->thH = th_h;
    if (th_f > 0.0) {
        const double w = 2.0 * 3.14159265358979323846 * th_f;
        const double sg = w / (2.0 * th_q);
        const double wd2 = sqrt(w * w - sg * sg > 1.0
                                ? w * w - sg * sg : 1.0);
        s->thWd = wd2;
        s->thCa = exp(-sg * dt) * cos(wd2 * dt);
        s->thCb = exp(-sg * dt) * sin(wd2 * dt);
        s->thM = th_k / (w * w);
    } else {
        s->thWd = 1.0; s->thCa = 1.0; s->thCb = 0.0; s->thM = 1.0;
    }
    s->thz = 0.0; s->thv = 0.0;
    s->rampN = ramp_n;
    s->rampLeft = 0; s->rampAmp = 0.0; s->rampPrev = 0.0;
    s->envPrev = 0.0; s->stagn = 0; s->pen0 = 0.0;
    s->demoted = 0;
    s->deepRun = 0; s->permaCount = 0;
    /* FORCE x4 contact above the tanpura's own register
       (2026-08-03b): 247-294 Hz self-oscillated LOUDLY at ANY M —
       the graze pulse crosses the zone in <2 samples at 96k there,
       but the band's wrap sits BELOW the pen0>deep bar so the
       permanent-deep path never engaged (deeper apex, pol_rt, and
       M 180-280 all probed inert; the reference strings <=131 Hz
       are extensively validated at base rate). wd[0]/2pi ~ f0. */
    s->forceDeep = (wd[0] / (2.0 * 3.14159265358979323846)) > 140.0;
    /* pre-measurement cost seed (base-path scale, ~3.6e-8*M matches
       the measured M321 note); perma-deep notes cost ~4x this and
       the pool's timing corrects the EMA within ~10 blocks — a
       deliberate UNDER-estimate, brief overshoot rides the ring
       slack rather than falsely stealing voices at mount */
    s->costEma = 3.6e-8 * (double)M;
    s->used = 1;
    s->active = 0;
    s->idle_env = 0.0;
}

/* zone displacement/velocity from the modal state — the ONE hot
   matvec (float tables, 4-wide unrolled: clang will not vectorize
   float reductions without -ffast-math, the jt law) */
static void tp_zone(const tp_slot *s, float *uf, float *udf)
{
    const int M = s->M, J = s->J;
    for (int j = 0; j < J; j++) { uf[j] = 0.0f; udf[j] = 0.0f; }
    for (int k = 0; k < M; k++) {
        const float *Pr = s->Phif + (size_t)k * J;
        const float qk = (float)s->q[k], pk = (float)s->p[k];
        int j = 0;
        for (; j + 3 < J; j += 4) {
            uf[j] += Pr[j] * qk;     udf[j] += Pr[j] * pk;
            uf[j+1] += Pr[j+1] * qk; udf[j+1] += Pr[j+1] * pk;
            uf[j+2] += Pr[j+2] * qk; udf[j+2] += Pr[j+2] * pk;
            uf[j+3] += Pr[j+3] * qk; udf[j+3] += Pr[j+3] * pk;
        }
        for (; j < J; j++) { uf[j] += Pr[j] * qk; udf[j] += Pr[j] * pk; }
    }
}


/* uf-ONLY zone eval (perf round 2026-08-03e): SAV never reads the
   zone velocity (the legacy Hunt-Crossley consumer is gone) — the
   udf half of tp_zone was pure waste, twice per output sample per
   voice. BLAS gemv on the pool threads where available. */
static void tp_zone_u(const tp_slot *s, float *uf)
{
    const int M = s->M, J = s->J;
    /* hand loop beats BLAS here (measured): tall-thin transposed
       gemv is column-stride-hostile; the row accumulate keeps J=16
       accumulators in registers at stride 1 */
    for (int j = 0; j < J; j++) uf[j] = 0.0f;
    for (int k = 0; k < M; k++) {
        const float *Pr = s->Phif + (size_t)k * J;
        const float qk = (float)s->q[k];
        int j = 0;
        for (; j + 3 < J; j += 4) {
            uf[j] += Pr[j] * qk;
            uf[j+1] += Pr[j+1] * qk;
            uf[j+2] += Pr[j+2] * qk;
            uf[j+3] += Pr[j+3] * qk;
        }
        for (; j < J; j++) uf[j] += Pr[j] * qk;
    }
}

static void tp_wlat(const tp_slot *s, float *wl)
{
    const int M = s->M, J = s->J;
    for (int j = 0; j < J; j++) wl[j] = 0.0f;
    for (int k = 0; k < M; k++) {
        const float *Pr = s->Phif + (size_t)k * J;
        const float qk = (float)s->qw[k];
        for (int j = 0; j < J; j++) wl[j] += Pr[j] * qk;
    }
}

/* contact on precomputed zone state: solves, then applies the modal
   impulse AND (if rt) the fused lateral reaction in one phiF pass.
   Returns 1 if fired. */
static int tp_contact_apply(tp_slot *s, const float *beff,
                            const float *uf, const float *udf,
                            const float *wl, int sub, double dtv,
                            double *fth_out)
{
    const int M = s->M, J = s->J;
    float eta0[TP_MAXJ], F[TP_MAXJ], Gj[TP_MAXJ];
    int any = 0;
    for (int j = 0; j < J; j++) {
        eta0[j] = beff[j] - uf[j];
        if (eta0[j] > 0.0f) any = 1;
    }
    if (!any) {
        for (int j = 0; j < J; j++) s->Fw[j] = 0.0f;
        if (fth_out) *fth_out = 0.0;
        return 0;
    }
    const float *Gm = sub == 1 ? s->G4f : (sub == 2 ? s->G2f : s->Gf);
    const float *gm = sub == 1 ? s->gd4f : (sub == 2 ? s->gd2f : s->gdf);
    tp_solve(J, eta0, udf, Gm, gm,
             (float)s->kc, (float)s->alpha, (float)s->hcB, s->Fw);
    tp_hc(J, udf, (float)s->hcB, s->Fw, F);
    const int rt_on = s->rt > 0.0 && wl != 0;
    if (rt_on) {
        const float rtf = (float)s->rt;
        for (int j = 0; j < J; j++) Gj[j] = -wl[j] / rtf * F[j];
    }
    if (fth_out) {
        double a = 0.0;
        for (int j = 0; j < J; j++) a += s->gth[j] * (double)F[j];
        *fth_out = a;
    }
    const double h = dtv, h2 = dtv * dtv / 2.0;
    for (int k = 0; k < M; k++) {
        const float *Pr = s->phiFf + (size_t)k * J;
        float a = 0.0f, gaux = 0.0f;
        int j = 0;
        for (; j + 3 < J; j += 4) {
            a += Pr[j] * F[j] + Pr[j+1] * F[j+1]
               + Pr[j+2] * F[j+2] + Pr[j+3] * F[j+3];
            if (rt_on)
                gaux += Pr[j] * Gj[j] + Pr[j+1] * Gj[j+1]
                      + Pr[j+2] * Gj[j+2] + Pr[j+3] * Gj[j+3];
        }
        for (; j < J; j++) {
            a += Pr[j] * F[j];
            if (rt_on) gaux += Pr[j] * Gj[j];
        }
        s->p[k] += h * (double)a;
        s->q[k] += h2 * (double)a;
        if (rt_on) s->pw[k] += h * (double)gaux;
    }
    return 1;
}

/* settle onto the static wrap through THIS kernel (build-time only):
   heavy-damping rotation + full-dt contact, then store q -> q0.
   Run once per slot at engine build, OFF the audio thread. */
void tanpura_settle(void *vc, int slot, long n)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    const int M = s->M, J = s->J;
    float uf[TP_MAXJ], udf[TP_MAXJ], bf[TP_MAXJ];
    for (int j = 0; j < J; j++) bf[j] = (float)s->b[j];
    memset(s->q, 0, sizeof(double) * (size_t)M);
    memset(s->p, 0, sizeof(double) * (size_t)M);
    memset(s->Fw, 0, sizeof(s->Fw));
    for (long t = 0; t < n; t++) {
        for (int k = 0; k < M; k++) {
            double qk = s->q[k], pk = s->p[k];
            s->q[k] = s->cas[k] * qk + s->cbs[k] * (pk * s->iwd[k]);
            s->p[k] = -s->cbs[k] * (s->wd[k] * qk) + s->cas[k] * pk;
        }
        tp_zone_u(s, uf);
        tp_sav_contact(s, bf, uf, udf, 0, 0);
    }
    memcpy(s->q0, s->q, sizeof(double) * (size_t)M);
    /* snapshot the settled SAV state — idle-wake restores it with q0
       (a zeroed psi at the deep wrap free-falls; the settle already
       paid for this consistency once) */
    memcpy(s->svPsi0, s->svPsi, sizeof(s->svPsi));
    memcpy(s->svEta0, s->svEta, sizeof(s->svEta));
    memcpy(s->svBud0, s->svBud, sizeof(s->svBud));
    memset(s->p, 0, sizeof(double) * (size_t)M);
    memset(s->qw, 0, sizeof(double) * (size_t)M);
    memset(s->pw, 0, sizeof(double) * (size_t)M);
    /* settled static penetration: the deep-substep baseline */
    tp_zone(s, uf, udf);
    float p0 = 0.0f;
    for (int j = 0; j < J; j++) {
        const float d = bf[j] - uf[j];
        if (d > p0) p0 = d;
    }
    s->pen0 = (double)p0;
    /* PERMANENT-DEEP slots cost ~4x the base path — seed the cost
       estimate accordingly so pluck-time budget enforcement sheds
       voices BEFORE the overload, not one transient later */
    if (s->pen0 > s->deep || s->forceDeep) s->costEma *= 4.0;
    s->active = 0;
}

/* ---- FD continuum slot (round 20) ---- */
void tanpura_mount_fd(void *vc, int slot, int N,
                      const double *b, const double *pshape,
                      double lam2, double muk, double s1h,
                      double A0, double B0, double kc, double alpha,
                      int o_i, int ramp_n, int steps_per_out,
                      double gain, double dt, double touch)
{
    /* NOTE: kc arrives PRE-DIVIDED by MU (the offline stencil's
       dt^2*fc/MU term) — the Swift builder passes kc/MU.
       touch (round 21): finger damp at pluck — state blends toward
       the settled wrap by this factor (1.0 = legacy no-damp). */
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots) return;
    tp_slot *s = &c->s[slot];
    tp_slot_free(s);
    memset(s, 0, sizeof(*s));
    s->is_fd = 1;
    s->fdN = N;
    s->fdOi = o_i;
    s->fdSteps = steps_per_out;
    s->fdU = (double *)calloc((size_t)N + 1, sizeof(double));
    s->fdUp = (double *)calloc((size_t)N + 1, sizeof(double));
    s->fdScr = (double *)calloc((size_t)N + 1, sizeof(double));
    s->fdUeq = (double *)calloc((size_t)N + 1, sizeof(double));
    s->fdTouch = touch;
    s->fdB = tp_dup(b, (size_t)N + 1);
    s->fdPsh = tp_dup(pshape, (size_t)N + 1);
    s->fdLam2 = lam2; s->fdMuk = muk; s->fdS1h = s1h;
    s->fdA0 = A0; s->fdB0 = B0; s->fdKc = kc; s->fdAlpha = alpha;
    s->rampN = ramp_n;
    s->gain = gain; s->dt = dt;
    s->used = 1; s->active = 0;
}

/* one internal FD step (the offline stencil VERBATIM: d2/d2p/d4 with
   simply-supported end fixups, capped one-sided penalty, ends
   pinned). extra_damp > 0 = the settle relaxation. */
static void tp_fd_step(tp_slot *s, double extra_damp)
{
    const int N = s->fdN;
    double *restrict u = s->fdU;
    double *restrict up = s->fdUp;
    double *restrict un = s->fdScr;
    const double *restrict b = s->fdB;
    const double lam2 = s->fdLam2, muk = s->fdMuk, s1h = s->fdS1h;
    const double A0 = s->fdA0, B0 = s->fdB0;
    const double kc = s->fdKc, alpha = s->fdAlpha;
    const double dt = s->dt;
    un[0] = 0.0; un[N] = 0.0;
    for (int i = 1; i < N; i++) {
        const double d2 = u[i + 1] - 2.0 * u[i] + u[i - 1];
        const double d2p = up[i + 1] - 2.0 * up[i] + up[i - 1];
        double d4;
        if (i == 1)
            d4 = u[3] - 4.0 * u[2] + 6.0 * u[1] - 4.0 * u[0]
                 + (-u[1]);
        else if (i == N - 1)
            d4 = u[N - 3] - 4.0 * u[N - 2] + 6.0 * u[N - 1]
                 - 4.0 * u[N] + (-u[N - 1]);
        else
            d4 = u[i + 2] - 4.0 * u[i + 1] + 6.0 * u[i]
                 - 4.0 * u[i - 1] + u[i - 2];
        /* IMPLICIT per-node contact (round-20 FD-live law: the
           explicit penalty is only stable when the grid bound covers
           the CONTACT frequency — at 96 kHz it diverges above
           ~180 Hz; the python reference diverges identically).
           Scalar Newton on f = kc*(eta* − cl*f)^alpha with
           cl = dt^2/A0 (kc arrives pre-divided by MU). */
        double v = (2.0 * u[i] - B0 * up[i] + lam2 * d2 - muk * d4
                    + s1h * (d2 - d2p)) / A0;
        double eta_s = b[i] - v;
        if (eta_s > 5e-4) eta_s = 5e-4;
        if (eta_s > 0.0) {
            const double cl = dt * dt / A0;
            double fi = kc * pow(eta_s, alpha);
            for (int it = 0; it < 8; it++) {
                double e = eta_s - cl * fi;
                if (e <= 0.0) { fi *= 0.5; continue; }
                double g = fi - kc * pow(e, alpha);
                double gp = 1.0 + kc * alpha * cl
                            * pow(e, alpha - 1.0);
                double fn = fi - g / gp;
                if (fn < 0.0) fn = 0.0;
                if (fabs(fn - fi) < 1e-9 * (fn > 1.0 ? fn : 1.0)) {
                    fi = fn;
                    break;
                }
                fi = fn;
            }
            v += dt * dt * fi / A0;
        }
        if (extra_damp > 0.0) v = u[i] + (v - u[i]) * (1.0 - extra_damp);
        un[i] = v;
    }
    /* rotate buffers: up <- u, u <- un (scr becomes the new up) */
    double *tmp = s->fdUp;
    s->fdUp = s->fdU;
    s->fdU = s->fdScr;
    s->fdScr = tmp;
}

/* build-time settle from the tent (mirrors the offline recipe);
   caller pre-loads fdU with the tent via tanpura_fd_set_state */
void tanpura_settle_fd(void *vc, int slot, long n)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used || !s->is_fd) return;
    /* mirror tanpura_fd._settle: HEAVY damping swapped into A0/B0
       (sigma*dt ~ 0.2 — the settle must actually settle; the old
       0.02 relative pull never reached the static wrap, and the
       resulting off-equilibrium contact point cost ~4-6 dB of
       jawari conversion at pluck) */
    const double a0s = s->fdA0, b0s = s->fdB0;
    const double sig = 2.0e4;
    s->fdA0 = 1.0 + sig * s->dt;
    s->fdB0 = 1.0 - sig * s->dt;
    for (long t = 0; t < n; t++) tp_fd_step(s, 0.0);
    s->fdA0 = a0s;
    s->fdB0 = b0s;
    memcpy(s->fdUp, s->fdU, sizeof(double) * ((size_t)s->fdN + 1));
    memcpy(s->fdUeq, s->fdU, sizeof(double) * ((size_t)s->fdN + 1));
    s->fdObsPrev = s->fdU[s->fdOi];
    s->active = 0;
}

void tanpura_set_oversample(void *vc, int slot, int steps)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots) return;
    c->s[slot].ovs = steps > 1 ? steps : 1;
}

void tanpura_fd_get_state(void *vc, int slot, double *u, double *up)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used || !s->is_fd) return;
    memcpy(u, s->fdU, sizeof(double) * ((size_t)s->fdN + 1));
    memcpy(up, s->fdUp, sizeof(double) * ((size_t)s->fdN + 1));
}

void tanpura_fd_set_state(void *vc, int slot, const double *u0)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used || !s->is_fd) return;
    memcpy(s->fdU, u0, sizeof(double) * ((size_t)s->fdN + 1));
    memcpy(s->fdUp, u0, sizeof(double) * ((size_t)s->fdN + 1));
}

/* concurrent-voice management: steal the QUIETEST ringing modal slot
   when a pluck would exceed EITHER the count cap or the COST budget
   (2026-08-03b). Each slot carries costEma (measured s/sample from
   the pool timing; seeded from M before first measurement); the
   budget is the serial-equivalent load the worker pool sustains
   RELIABLY under concurrency (measured: the 8-note M150 chord at
   ~5x RT serial fell behind persistently; ~3.5x holds). A slammed
   chord degrades to its loudest voices instead of underrunning the
   whole instrument — the stolen slot is the quietest, musically the
   least missed. */
#define TP_VOICE_CAP 24
#define TP_COST_BUDGET_XRT 5.0
static void tp_voice_cap(tp_ctx *c, int keep)
{
    const double perSample = 1.0 / 48000.0;
    const double budget = TP_COST_BUDGET_XRT * perSample;
    for (;;) {
        int nact = 0, qi = -1;
        double cost = 0.0, qe = 1e30;
        for (int k = 0; k < c->nslots; k++) {
            tp_slot *s = &c->s[k];
            if (!s->used || !s->active || s->is_fd) continue;
            nact++;
            cost += s->costEma;
            if (k != keep && s->idle_env < qe) {
                qe = s->idle_env;
                qi = k;
            }
        }
        if ((nact <= TP_VOICE_CAP && cost <= budget) || qi < 0
            || nact <= 2)   /* same 2-voice floor as the feedback shed */
            break;
        c->s[qi].active = 0;
    }
}

/* note-on: activate + add the angled pluck (amp in metres, TOTAL
   displacement; the v/w split is the mount's pol_th) */
/* GHOST HANDOFF (Tarabdaar 2026-08-15; string-bank rework): move
   `frac` of SRC's ringing deviation into DST's linear ghost bank.
   Under the string bank this is the PILE-UP tier only: it runs when
   the clone pool overflows (oldest history string evicted, full
   band) or when polyMax is 0 (no history strings at all — then
   `split` keeps only the partials above 2*f0, because the incoming
   same-slot pluck replaces the fundamental in the same instant; a
   full-band handoff there measured a 3.6-4.1 dB re-pluck level
   lottery from same-frequency phase summing). Ghost tables freeze
   from SRC (composed to output rate), so the evicted note keeps its
   own pitch; a releasing (note-off) string is finger-stopped and is
   never resurrected into the ghost. */
static void tp_ghost_handoff(tp_slot *dst, tp_slot *src, double frac,
                             int split)
{
    if (!(frac > 0.0) || !src->active || src->is_fd || dst->is_fd)
        return;
    if (frac > 1.0) frac = 1.0;
    const double keep = 1.0 - frac;
    const int M = src->M;
    const int toGhost = src->relMul >= 1.0;
    if (toGhost && !dst->ghostOn) {
        /* freeze SRC's dynamics, composed to output rate:
           R_out = R_in^ovs — same wd, envelope E^ovs, so the ghost
           decays exactly as the live string would have */
        const int ovs = src->ovs > 1 ? src->ovs : 1;
        for (int k = 0; k < M; k++) {
            double a = src->ca[k], b2 = src->cb[k];
            double aw = src->caw[k], bw = src->cbw[k];
            for (int i = 1; i < ovs; i++) {
                const double na = a * src->ca[k] - b2 * src->cb[k];
                b2 = a * src->cb[k] + b2 * src->ca[k];
                a = na;
                const double nw = aw * src->caw[k] - bw * src->cbw[k];
                bw = aw * src->cbw[k] + bw * src->caw[k];
                aw = nw;
            }
            dst->gca[k] = a; dst->gcb[k] = b2;
            dst->gcaw[k] = aw; dst->gcbw[k] = bw;
            dst->gwd[k] = src->wd[k]; dst->giwd[k] = src->iwd[k];
            dst->gwdw[k] = src->wdw[k]; dst->giwdw[k] = src->iwdw[k];
            dst->gq[k] = 0.0; dst->gp[k] = 0.0;
            dst->gqw[k] = 0.0; dst->gpw[k] = 0.0;
        }
        {
            double a = src->cg, b2 = src->sg;
            const int ovs2 = src->ovs > 1 ? src->ovs : 1;
            for (int i = 1; i < ovs2; i++) {
                const double na = a * src->cg - b2 * src->sg;
                b2 = a * src->sg + b2 * src->cg;
                a = na;
            }
            dst->gcg = a; dst->gsg = b2;
        }
        dst->gGain = src->gain;
        dst->ghostOn = 1;
    }
    /* superpose (linear): a handoff at a different gain pre-scales
       so it renders at the frozen gGain identically */
    const double gs = !toGhost ? 0.0
        : (dst->gGain != 0.0 ? frac * src->gain / dst->gGain : frac);
    const double w1 = src->wd[0];
    if (src->demoted) {
        /* demoted q already holds the deviation from q0 */
        for (int k = 0; k < M; k++) {
            double wk = 1.0;
            if (split) {
                wk = (src->wd[k] / w1 - 2.0) * 0.5;
                if (wk < 0.0) wk = 0.0;
                if (wk > 1.0) wk = 1.0;
            }
            const double g2 = gs * wk;
            dst->gq[k] += g2 * src->q[k];
            dst->gp[k] += g2 * src->p[k];
            dst->gqw[k] += g2 * src->qw[k];
            dst->gpw[k] += g2 * src->pw[k];
            src->q[k] *= keep; src->p[k] *= keep;
            src->qw[k] *= keep; src->pw[k] *= keep;
        }
    } else {
        for (int k = 0; k < M; k++) {
            double wk = 1.0;
            if (split) {
                wk = (src->wd[k] / w1 - 2.0) * 0.5;
                if (wk < 0.0) wk = 0.0;
                if (wk > 1.0) wk = 1.0;
            }
            const double g2 = gs * wk;
            dst->gq[k] += g2 * (src->q[k] - src->q0[k]);
            dst->gp[k] += g2 * src->p[k];
            dst->gqw[k] += g2 * src->qw[k];
            dst->gpw[k] += g2 * src->pw[k];
            src->q[k] = src->q0[k] + keep * (src->q[k] - src->q0[k]);
            src->p[k] *= keep; src->qw[k] *= keep; src->pw[k] *= keep;
        }
        for (int j = 0; j < src->J; j++) {
            src->svPsi[j] = src->svPsi0[j]
                + keep * (src->svPsi[j] - src->svPsi0[j]);
            src->svEta[j] = src->svEta0[j]
                + keep * (src->svEta[j] - src->svEta0[j]);
            src->svBud[j] = src->svBud0[j]
                + keep * (src->svBud[j] - src->svBud0[j]);
            src->Fw[j] *= (float)keep;
        }
    }
    src->thz *= keep; src->thv *= keep;
    if (toGhost) dst->ghost_env = 1.0;
}

/* PLUCK DRIVE (Tarabdaar 2026-08-15): the mellow<->buzzy axis at
   constant loudness. The SAV contact is a power law (kc*em^alpha),
   so how hard the string is driven into the jawari sets the buzz
   conversion — measured on the shipped voice: pluck level 0.25->2
   moved the attack centroid 2357->3269 Hz. Drive scales the pluck
   displacement by D and the slot's OUTPUT gain by 1/D, both applied
   sample-synchronously at the pluck: the note keeps its calibrated
   level while the contact sees a x D deeper (or shallower)
   engagement. D 1 is a strict no-op (gain untouched — bit-exact).
   NOTE: a drive EDIT between re-plucks of a still-ringing slot
   steps the old tail's level by Dold/Dnew at the pluck instant —
   with pluck touch active the tail is damped there anyway. */
static void tp_apply_drive(tp_slot *s, double d)
{
    if (d < 0.05) d = 0.05;
    if (d > 20.0) d = 20.0;
    s->drive = d;
}

/* STRING-BANK MIGRATION (Tarabdaar 2026-08-15): move the primary's
   ringing string onto a free clone — the old note keeps its FULL
   jawari simulation at its own (frozen) pitch while the primary is
   reset for the incoming pluck. The clone freezes copies of the 11
   bend-mutable tables (so later glides retune only the primary) and
   aliases everything else; `iso` scales how much of the old ring
   survives. When the pool is full past polyMax, the globally OLDEST
   clone is evicted into its owner's ghost bank first (split only if
   that owner is the slot being re-plucked — its fundamental gets
   replaced in the same instant). polyMax 0 skips clones entirely:
   the primary hands off straight to its own ghost (split). */
static void tp_migrate(tp_ctx *c, int slot, double iso)
{
    tp_slot *s = &c->s[slot];
    const int poly = __atomic_load_n(&c->polyMax, __ATOMIC_RELAXED);
    if (poly <= 0) {
        tp_ghost_handoff(s, s, 1.0, 1);
        goto reset_primary;
    }
    {
        tp_slot *cl = 0;
        int liveClones = 0;
        tp_slot *oldest = 0;
        for (int i = c->nUser; i < c->nslots; i++) {
            tp_slot *t = &c->s[i];
            if (!t->active) { if (!cl) cl = t; continue; }
            liveClones++;
            if (!oldest || t->seq < oldest->seq) oldest = t;
        }
        if (!cl || liveClones >= poly) {
            if (!oldest) return;            /* cannot happen */
            tp_ghost_handoff(&c->s[oldest->owner], oldest, 1.0,
                             oldest->owner == slot);
            oldest->active = 0;
            cl = oldest;
        }
        /* ---- copy the string onto the clone ---- */
        const int M = s->M, J = s->J;
        cl->M = M; cl->J = J;
        cl->owner = slot;
        cl->seq = ++c->pluckSeq;
        cl->is_fd = 0;
        /* frozen bend-mutable tables */
        memcpy(cl->ca, s->ca, sizeof(double) * (size_t)M);
        memcpy(cl->cb, s->cb, sizeof(double) * (size_t)M);
        memcpy(cl->wd, s->wd, sizeof(double) * (size_t)M);
        memcpy(cl->iwd, s->iwd, sizeof(double) * (size_t)M);
        memcpy(cl->caw, s->caw, sizeof(double) * (size_t)M);
        memcpy(cl->cbw, s->cbw, sizeof(double) * (size_t)M);
        memcpy(cl->wdw, s->wdw, sizeof(double) * (size_t)M);
        memcpy(cl->iwdw, s->iwdw, sizeof(double) * (size_t)M);
        memcpy(cl->svKq, s->svKq, sizeof(double) * (size_t)M);
        memcpy(cl->svKp, s->svKp, sizeof(double) * (size_t)M);
        memcpy(cl->svG, s->svG, sizeof(double) * (size_t)J * J);
        /* aliased read-only tables (bend never touches these) */
        cl->ca4 = s->ca4; cl->cb4 = s->cb4;
        cl->ca2 = s->ca2; cl->cb2 = s->cb2;
        cl->cas = s->cas; cl->cbs = s->cbs;
        cl->Phi = s->Phi; cl->phiF = s->phiF;
        cl->Phif = s->Phif; cl->phiFf = s->phiFf;
        cl->b = s->b; cl->gth = s->gth;
        cl->Gf = s->Gf; cl->G4f = s->G4f;
        cl->gdf = s->gdf; cl->gd4f = s->gd4f;
        cl->G2f = s->G2f; cl->gd2f = s->gd2f;
        cl->phi_o = s->phi_o; cl->dq = s->dq; cl->q0 = s->q0;
        cl->wd0 = s->wd0; cl->wdw0 = s->wdw0;
        cl->envE = s->envE; cl->envEw = s->envEw;
        /* scalars */
        cl->kc = s->kc; cl->alpha = s->alpha; cl->hcB = s->hcB;
        cl->deep = s->deep; cl->dt = s->dt; cl->gain = s->gain;
        cl->cg = s->cg; cl->sg = s->sg;
        cl->av = s->av; cl->aw = s->aw; cl->rt = s->rt;
        cl->thBase = s->thBase; cl->thH = s->thH;
        cl->thCa = s->thCa; cl->thCb = s->thCb;
        cl->thWd = s->thWd; cl->thM = s->thM;
        cl->ovs = s->ovs; cl->rampN = s->rampN;
        cl->forceDeep = s->forceDeep; cl->pen0 = s->pen0;
        cl->costEma = s->costEma;
        cl->bendRatio = s->bendRatio;
        /* state */
        memcpy(cl->q, s->q, sizeof(double) * (size_t)M);
        memcpy(cl->p, s->p, sizeof(double) * (size_t)M);
        memcpy(cl->qw, s->qw, sizeof(double) * (size_t)M);
        memcpy(cl->pw, s->pw, sizeof(double) * (size_t)M);
        memcpy(cl->Fw, s->Fw, sizeof(cl->Fw));
        memcpy(cl->svPsi, s->svPsi, sizeof(cl->svPsi));
        memcpy(cl->svEta, s->svEta, sizeof(cl->svEta));
        memcpy(cl->svBud, s->svBud, sizeof(cl->svBud));
        memcpy(cl->svPsi0, s->svPsi0, sizeof(cl->svPsi0));
        memcpy(cl->svEta0, s->svEta0, sizeof(cl->svEta0));
        memcpy(cl->svBud0, s->svBud0, sizeof(cl->svBud0));
        cl->thz = s->thz; cl->thv = s->thv;
        cl->rampLeft = s->rampLeft;
        cl->rampAmp = s->rampAmp; cl->rampPrev = s->rampPrev;
        cl->relMul = s->relMul;
        cl->demoted = s->demoted;
        cl->idle_env = s->idle_env;
        cl->envPrev = 0.0; cl->stagn = 0;
        cl->ghostOn = 0; cl->ghost_env = 0.0;
        cl->active = 1;
        /* iso < 1: only that much of the old ring survives */
        if (iso < 1.0) {
            for (int k = 0; k < M; k++) {
                if (cl->demoted) { cl->q[k] *= iso; }
                else cl->q[k] = cl->q0[k]
                    + iso * (cl->q[k] - cl->q0[k]);
                cl->p[k] *= iso; cl->qw[k] *= iso; cl->pw[k] *= iso;
            }
            cl->thz *= iso; cl->thv *= iso;
        }
    }
reset_primary:
    memcpy(s->q, s->q0, sizeof(double) * (size_t)s->M);
    memset(s->p, 0, sizeof(double) * (size_t)s->M);
    memset(s->qw, 0, sizeof(double) * (size_t)s->M);
    memset(s->pw, 0, sizeof(double) * (size_t)s->M);
    memset(s->Fw, 0, sizeof(s->Fw));
    memcpy(s->svPsi, s->svPsi0, sizeof(s->svPsi));
    memcpy(s->svEta, s->svEta0, sizeof(s->svEta));
    memcpy(s->svBud, s->svBud0, sizeof(s->svBud));
    s->thz = 0.0; s->thv = 0.0;
    s->demoted = 0;
    s->rampLeft = 0;
    s->relMul = 1.0;
}

void tanpura_pluck(void *vc, int slot, double amp)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used || s->isClone) return;
    /* pluck isolation (op 3 stored `iso`): the ringing string becomes
       a SEPARATE history string before the new pluck lands (unless a
       pre-pluck bend already migrated it at its old pitch) */
    if (!s->is_fd && s->iso > 0.0 && s->active && !s->justMigrated)
        tp_migrate(c, slot, s->iso);
    s->justMigrated = 0;
    /* pluck drive: deeper (or shallower) contact engagement at the
       calibrated radiated level (gain0/1.0 == gain0 exactly, so
       drive 1 leaves the mount gain bit-identical). Modal slots
       only — mount_fd never initializes drive/gain0. */
    if (!s->is_fd && s->drive > 0.0) {
        amp *= s->drive;
        s->gain = s->gain0 / s->drive;
    }
    if (s->demoted) {
        for (int k = 0; k < s->M; k++) s->q[k] += s->q0[k];
        memcpy(s->svPsi, s->svPsi0, sizeof(s->svPsi));
        memcpy(s->svEta, s->svEta0, sizeof(s->svEta));
        memcpy(s->svBud, s->svBud0, sizeof(s->svBud));
        s->demoted = 0;
    }
    if (!s->active) {
        /* waking from idle: state is the settled wrap (or decayed
           back to it); make that exact so long-idle drift never
           accumulates. A damped slot's ghost is stale — silence it
           (the empty->active handoff re-zeros the arrays). */
        memcpy(s->q, s->q0, sizeof(double) * (size_t)s->M);
        memset(s->p, 0, sizeof(double) * (size_t)s->M);
        memset(s->qw, 0, sizeof(double) * (size_t)s->M);
        memset(s->pw, 0, sizeof(double) * (size_t)s->M);
        memset(s->Fw, 0, sizeof(s->Fw));
        memcpy(s->svPsi, s->svPsi0, sizeof(s->svPsi));
        memcpy(s->svEta, s->svEta0, sizeof(s->svEta));
        memcpy(s->svBud, s->svBud0, sizeof(s->svBud));
        s->demoted = 0;
        s->ghostOn = 0;
        s->ghost_env = 0.0;
        s->active = 1;
    }
    if (s->is_fd) {
        if (s->fdTouch < 1.0) {
            for (int i = 0; i <= s->fdN; i++) {
                s->fdU[i] = s->fdUeq[i]
                    + s->fdTouch * (s->fdU[i] - s->fdUeq[i]);
                s->fdUp[i] = s->fdUeq[i]
                    + s->fdTouch * (s->fdUp[i] - s->fdUeq[i]);
            }
        }
        s->rampLeft = s->rampN > 0 ? s->rampN : 1;
        s->rampAmp = amp;
        s->rampPrev = 0.0;
        s->idle_env = 1.0;
        s->active = 1;
        return;
    }
    if (s->rampN > 0) {
        s->rampLeft = s->rampN;
        s->rampAmp = amp;
        s->rampPrev = 0.0;
    } else {
        for (int k = 0; k < s->M; k++) {
            s->q[k] += s->av * amp * s->dq[k];
            s->qw[k] += s->aw * amp * s->dq[k];
        }
    }
    s->idle_env = 1.0;
    s->relMul = 1.0;            /* a pluck is a held note again */
    c->lastPluck = slot;
    tp_voice_cap(c, slot);
}

/* hard-stop a slot (all-notes-off): the primary, its history
   clones, and its ghost bank */
void tanpura_damp(void *vc, int slot)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    s->active = 0;
    s->ghostOn = 0;
    s->ghost_env = 0.0;
    if (!s->isClone)
        for (int i = c->nUser; i < c->nslots; i++)
            if (c->s[i].active && c->s[i].owner == slot)
                c->s[i].active = 0;
}

/* LIVE RETUNE (Tarabdaar 2026-08-05): rescale every mode's rotation
   angle from the mount-time base tables. The rotation is exact at any
   angle, so this is a true retune, not an approximation; the damping
   envelope E (= hypot(ca,cb)) is preserved, so t60s ride along
   unchanged. The SAV exact-response kick tables (svKq/svKp) and the
   within-step compliance (svG) follow the new frequencies — the
   contact solve stays consistent with the rotation it interleaves.
   Modes whose bent frequency crosses ~the OUTPUT Nyquist get
   ca=cb=0 (state zeroes — silence, not aliasing); contact re-grows
   them when the bend comes back down. NEVER call concurrently with
   tp_render_slot on the same slot — the drain/sync contract. */
static void tp_apply_bend(tp_slot *s, double r)
{
    if (s->is_fd || !s->wd0) return;
    if (r < 0.25) r = 0.25;
    if (r > 4.0) r = 4.0;
    if (r == s->bendRatio) return;
    s->bendRatio = r;
    const int M = s->M, J = s->J;
    const double dt = s->dt;
    const int ovs = s->ovs > 1 ? s->ovs : 1;
    const double wlim = 0.95 * 3.14159265358979323846
                        / (dt * (double)ovs);
    for (int k = 0; k < M; k++) {
        const double w = s->wd0[k] * r;
        s->wd[k] = w;
        s->iwd[k] = 1.0 / w;
        if (w > wlim) {
            s->ca[k] = 0.0; s->cb[k] = 0.0;
        } else {
            s->ca[k] = s->envE[k] * cos(w * dt);
            s->cb[k] = s->envE[k] * sin(w * dt);
        }
        const double ww = s->wdw0[k] * r;
        s->wdw[k] = ww;
        s->iwdw[k] = 1.0 / ww;
        if (ww > wlim) {
            s->caw[k] = 0.0; s->cbw[k] = 0.0;
        } else {
            s->caw[k] = s->envEw[k] * cos(ww * dt);
            s->cbw[k] = s->envEw[k] * sin(ww * dt);
        }
        const double wdt = w * dt;
        s->svKq[k] = (1.0 - cos(wdt)) / (w * w);
        s->svKp[k] = sin(wdt) / w;
    }
    for (int j = 0; j < J; j++)
        for (int i = 0; i < J; i++) {
            double a = 0.0;
            for (int k = 0; k < M; k++)
                a += s->Phi[(size_t)k * J + j] * s->svKq[k]
                     * s->phiF[(size_t)k * J + i];
            s->svG[(size_t)j * J + i] = a;
        }
}

void tanpura_bend(void *vc, int slot, double ratio)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots) return;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    tp_apply_bend(s, ratio);
}

/* note-off release: DEMOTE the ringing string immediately (the tail
   demotion transform — q becomes the deviation from the settled wrap,
   contact/zone/thread are skipped) and decay that deviation by relMul
   each internal sample. The demotion is load-bearing, not just perf:
   with contact live, the per-sample pull toward q0 perturbs the wrap
   equilibrium's periodic orbit and the contact re-corrects it — a
   sustained limit cycle ~26 dB under the ring that NEVER dies
   (measured). Linearized, the decay is exact and the slot auto-idles.
   Musically it is a finger stop: the jawari buzz cuts at note-off,
   the pitch rings down fast. Re-pluck promotes (the existing path). */
static void tp_apply_release(tp_slot *s, double rate)
{
    if (s->is_fd) return;
    if (rate <= 0.0) { s->relMul = 1.0; return; }
    s->relMul = exp(-rate * s->dt);
    if (s->active && !s->demoted) {
        for (int k = 0; k < s->M; k++) s->q[k] -= s->q0[k];
        s->demoted = 1;
        s->rampLeft = 0;          /* note-off mid-draw: the draw stops */
    }
}

void tanpura_release(void *vc, int slot, double rate)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots) return;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    tp_apply_release(s, rate);
}

/* pluck isolation: set how much of the ringing string becomes a
   separate history string at each subsequent pluck (string-bank
   rework — stored, consumed by the pluck/pre-pluck-bend ops; sync
   path, the pool path rides event op 3) */
void tanpura_set_touch(void *vc, int slot, double touch)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nUser) return;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    s->iso = touch < 0.0 ? 0.0 : (touch > 1.0 ? 1.0 : touch);
}

/* pre-pluck bend (op 6): a re-pluck landing at a DIFFERENT pitch —
   migrate the ringing string first (its clone freezes at the old
   pitch), then retune the primary for the incoming pluck. Glide
   bends (op 1 / tanpura_bend) never migrate: they retune the
   primary only, and the history clones keep their frozen pitch. */
void tanpura_prepluck_bend(void *vc, int slot, double ratio)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nUser) return;
    tp_slot *s = &c->s[slot];
    if (!s->used || s->is_fd) return;
    if (s->iso > 0.0 && s->active) {
        double rr = ratio < 0.25 ? 0.25 : (ratio > 4.0 ? 4.0 : ratio);
        if (rr != s->bendRatio) {
            tp_migrate(c, slot, s->iso);
            s->justMigrated = 1;
        }
    }
    tp_apply_bend(s, ratio);
}

/* set the pluck drive applied at each subsequent pluck (sync path;
   the pool path rides event op 4) */
void tanpura_set_drive(void *vc, int slot, double drive)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots) return;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    tp_apply_drive(s, drive);
}

int tanpura_active_count(void *vc)
{
    tp_ctx *c = (tp_ctx *)vc;
    int n = 0;
    for (int i = 0; i < c->nslots; i++)
        if (c->s[i].used && c->s[i].active) n++;
    return n;
}

/* render one slot for n samples, ACCUMULATING into out.
   deep_ok gates the x4 substep (the sync path budgets it; the pool
   path always allows it). Returns 1 if the slot took the deep path. */
static int tp_render_fd(tp_ctx *c, tp_slot *s, int n, double *out)
{
    double peak = 0.0;
    for (int t = 0; t < n; t++) {
        /* ramp injection rides the INTERNAL rate (rampN counts
           srSim samples — one increment per fd step, matching the
           python reference; per-output injection stretched the draw
           by fdSteps and softened every attack) */
        for (int k = 0; k < s->fdSteps; k++) {
            if (s->rampLeft > 0) {
                const double x = (double)(s->rampN - s->rampLeft + 1)
                                 / (double)s->rampN;
                const double w = 0.5 * (1.0
                    - cos(3.14159265358979323846 * x));
                const double inc = s->rampAmp * (w - s->rampPrev);
                s->rampPrev = w;
                s->rampLeft--;
                double *restrict u = s->fdU, *restrict up = s->fdUp;
                const double *restrict ps = s->fdPsh;
                for (int i = 0; i <= s->fdN; i++) {
                    u[i] += inc * ps[i];
                    up[i] += inc * ps[i];
                }
            }
            tp_fd_step(s, 0.0);
        }
        const double ob = s->fdU[s->fdOi];
        const double o = s->gain * (ob - s->fdObsPrev) * 48000.0;
        s->fdObsPrev = ob;
        out[t] += o;
        const double ao = fabs(o);
        if (ao > peak) peak = ao;
    }
    int fin = 1;
    for (int i = 0; i <= s->fdN; i += 7)
        if (!isfinite(s->fdU[i]) || fabs(s->fdU[i]) > 0.05) fin = 0;
    if (!fin) {
        memset(s->fdU, 0, sizeof(double) * ((size_t)s->fdN + 1));
        memset(s->fdUp, 0, sizeof(double) * ((size_t)s->fdN + 1));
        s->fdObsPrev = 0.0;
        s->rampLeft = 0;
        s->active = 0;
        __atomic_add_fetch(&c->resets, 1, __ATOMIC_RELAXED);
        return 0;
    }
    s->idle_env = peak > s->idle_env ? peak : s->idle_env * 0.98;
    /* auto-idle at MUSICAL silence (~-86 dBFS post gain+FIR), not
       1e-7: the float contact limit cycle floors ~1e-4, so a 1e-7
       bar meant slots NEVER idled and cost accumulated with every
       note ever played (2026-08-03 choppy-under-polyphony bug) */
    if (s->idle_env < 1e-3) s->active = 0;
    return 0;
}


/* ENERGY-STABLE (SAV) modal contact — the ratified scheme (see the
   slot-field comment). Double solve on the float zone eval; one
   J-system per sample, no iterations, no substeps. cv/appr fixed at
   the ratified offline values. Returns 1 if any force fired. */
#define TP_SAV_CV 10.0
static int tp_sav_contact(tp_slot *s, const float *beff,
                          const float *uf, const float *udf,
                          double *fth_out, float *Fn_out)
{
    const int M = s->M, J = s->J;
    const double dt = s->dt;
    const double kc = s->kc, alpha = s->alpha;
    double etaF[TP_MAXJ], g[TP_MAXJ], F[TP_MAXJ];
    int ai[TP_MAXJ];
    int na = 0;
    const double bleed = exp(-dt / 1e-3);
    for (int j = 0; j < J; j++) {
        etaF[j] = (double)beff[j] - (double)uf[j];
        double em = 0.5 * (s->svEta[j] + etaF[j]);
        if (em < 0.0) em = 0.0;
        if (em > 0.0) {
            const double V = kc * pow(em, alpha + 1.0) / (alpha + 1.0);
            g[j] = kc * pow(em, alpha) / sqrt(2.0 * V + 1e-30);
            ai[na++] = j;
        } else {
            g[j] = 0.0;
            const double pb = s->svPsi[j] * bleed;
            s->svBud[j] += 0.5 * (s->svPsi[j] * s->svPsi[j] - pb * pb);
            s->svPsi[j] = pb;
        }
        F[j] = 0.0;
    }
    if (na == 0) {
        for (int j = 0; j < J; j++) s->svEta[j] = etaF[j];
        if (fth_out) *fth_out = 0.0;
        if (Fn_out) for (int j = 0; j < J; j++) Fn_out[j] = 0.0f;
        return 0;
    }
    const double cvdt = TP_SAV_CV / dt;
    double A[TP_MAXJ * TP_MAXJ], rhs[TP_MAXJ], cvrow[TP_MAXJ];
    for (int j = 0; j < J; j++) cvrow[j] = cvdt;
    int vpass = 0;
sav_build:
    for (int a = 0; a < na; a++) {
        const int i = ai[a];
        const double g2h = 0.5 * g[i] * g[i] + cvrow[i];
        for (int b2 = 0; b2 < na; b2++) {
            const int j = ai[b2];
            A[a * na + b2] = (a == b2 ? 1.0 : 0.0)
                + g2h * s->svG[(size_t)i * J + j];
        }
        rhs[a] = g[i] * s->svPsi[i] + g2h * (etaF[i] - s->svEta[i]);
    }
    for (int col = 0; col < na; col++) {
        int mx = col;
        for (int r = col + 1; r < na; r++)
            if (fabs(A[r * na + col]) > fabs(A[mx * na + col])) mx = r;
        if (mx != col) {
            for (int cc = 0; cc < na; cc++) {
                double t = A[col * na + cc];
                A[col * na + cc] = A[mx * na + cc];
                A[mx * na + cc] = t;
            }
            double t = rhs[col]; rhs[col] = rhs[mx]; rhs[mx] = t;
        }
        const double d = A[col * na + col];
        if (fabs(d) < 1e-30) continue;
        for (int r = col + 1; r < na; r++) {
            const double m = A[r * na + col] / d;
            if (m == 0.0) continue;
            for (int cc = col; cc < na; cc++)
                A[r * na + cc] -= m * A[col * na + cc];
            rhs[r] -= m * rhs[col];
        }
    }
    for (int a = na - 1; a >= 0; a--) {
        double acc = rhs[a];
        for (int cc = a + 1; cc < na; cc++)
            acc -= A[a * na + cc] * F[ai[cc]];
        const double d = A[a * na + a];
        double fv = fabs(d) > 1e-30 ? acc / d : 0.0;
        F[ai[a]] = fv > 0.0 ? fv : 0.0;
    }
    if (vpass == 0) {
        vpass = 1;
        int changed = 0;
        for (int a = 0; a < na; a++) {
            const int i = ai[a];
            double gf2 = 0.0;
            for (int b2 = 0; b2 < na; b2++)
                gf2 += s->svG[(size_t)i * J + ai[b2]] * F[ai[b2]];
            if ((etaF[i] - s->svEta[i]) - gf2 < 0.0
                && cvrow[i] != 0.0) {
                cvrow[i] = 0.0;
                changed = 1;
            }
        }
        if (changed) {
            for (int j2 = 0; j2 < J; j2++) F[j2] = 0.0;
            goto sav_build;
        }
    }
    /* commit + RSAV budget */
    for (int j = 0; j < J; j++) {
        double gf = 0.0;
        for (int i = 0; i < J; i++)
            gf += s->svG[(size_t)j * J + i] * F[i];
        const double etaEnd = etaF[j] - gf;
        double V = 0.0;
        if (etaEnd > 0.0)
            V = kc * pow(etaEnd, alpha + 1.0) / (alpha + 1.0);
        if (s->svEta[j] <= 0.0 && etaEnd > 0.0) {
            s->svBud[j] += V;
            s->svPsi[j] = 0.0;
        } else {
            s->svPsi[j] += g[j] * (etaEnd - s->svEta[j]);
            if (s->svPsi[j] < 0.0) s->svPsi[j] = 0.0;
        }
        const double pc = sqrt(2.0 * V);
        if (s->svPsi[j] > pc) {
            s->svBud[j] += 0.5 * (s->svPsi[j] * s->svPsi[j] - pc * pc);
            s->svPsi[j] = pc;
        } else if (s->svPsi[j] < pc && s->svBud[j] > 0.0) {
            const double want = 0.5 * (pc * pc
                - s->svPsi[j] * s->svPsi[j]);
            const double take = want < s->svBud[j] ? want : s->svBud[j];
            s->svPsi[j] = sqrt(s->svPsi[j] * s->svPsi[j] + 2.0 * take);
            s->svBud[j] -= take;
        }
        s->svEta[j] = etaEnd;
    }
    /* exact-response kicks (double phiF; BLAS on the pool threads) */
    for (int k = 0; k < M; k++) {
        const double *Pr = s->phiF + (size_t)k * J;
        double im = 0.0;
        for (int j = 0; j < J; j++) im += Pr[j] * F[j];
        s->q[k] += s->svKq[k] * im;
        s->p[k] += s->svKp[k] * im;
    }
    if (fth_out) {
        double a = 0.0;
        for (int j = 0; j < J; j++) a += s->gth[j] * F[j];
        *fth_out = a;
    }
    if (Fn_out)
        for (int j = 0; j < J; j++) Fn_out[j] = (float)F[j];
    (void)udf;
    return 1;
}

static int tp_render_slot(tp_ctx *c, tp_slot *s, int n, double *out,
                          int deep_ok)
{
    if (s->is_fd) return tp_render_fd(c, s, n, out);
    const int M = s->M, J = s->J;
    const double dt = s->dt, dt4 = dt / 4.0;
    float uf[TP_MAXJ], udf[TP_MAXJ], wl[TP_MAXJ], bf[TP_MAXJ];
    double qs[TP_MAXM], ps[TP_MAXM];
    double peak = 0.0, gpeak = 0.0;
    int went_deep = 0;
    const int rt_on = s->rt > 0.0;
    const int th_on = s->thH > 0.0;
#define TP_DEMOTE 1e-2
    if (!s->demoted && s->idle_env > 0.0 && s->idle_env < TP_DEMOTE
        && s->rampLeft == 0) {
        for (int k = 0; k < M; k++) s->q[k] -= s->q0[k];
        s->demoted = 1;
    }
    for (int j = 0; j < J; j++) bf[j] = (float)s->b[j];
    const int ovs = s->ovs > 1 ? s->ovs : 1;
    for (int t = 0; t < n; t++) {
      for (int sub = 0; sub < ovs; sub++) {
        float beff[TP_MAXJ];
        const float *bcur = bf;
        if ((rt_on || th_on) && !s->demoted) {
            for (int j = 0; j < J; j++) beff[j] = bf[j];
            if (rt_on) {
                tp_wlat(s, wl);
                const float rtf2 = 2.0f * (float)s->rt;
                for (int j = 0; j < J; j++)
                    beff[j] -= wl[j] * wl[j] / rtf2;
            }
            if (th_on) {
                const float bump = (float)(s->thBase + s->thH + s->thz);
                for (int j = 0; j < J; j++) {
                    const float g = (float)s->gth[j];
                    const float tb = g * bump + (1.0f - g) * beff[j];
                    if (tb > beff[j]) beff[j] = tb;
                }
            }
            bcur = beff;
        }
        if (s->rampLeft > 0) {
            const double x = (double)(s->rampN - s->rampLeft + 1)
                             / (double)s->rampN;
            const double w = 0.5 * (1.0 - cos(3.14159265358979323846 * x));
            const double inc = s->rampAmp * (w - s->rampPrev);
            s->rampPrev = w;
            s->rampLeft--;
            for (int k = 0; k < M; k++) {
                s->q[k] += s->av * inc * s->dq[k];
                s->qw[k] += s->aw * inc * s->dq[k];
            }
        }
        double fth = 0.0;
        /* SAV modal contact (2026-08-03d, ratified): one damped
           rotation + zone eval + non-iterative energy-stable solve
           per internal sample. The perma/forceDeep/dynamic-deep
           machinery, the rewind snapshot, and the pen dispatch are
           all DEAD — passivity is structural (midpoint-g SAV with
           approach-only viscosity; see tp_sav_contact). */
        {
            double *restrict q = s->q, *restrict pp = s->p;
            const double *restrict ca = s->ca, *restrict cb = s->cb,
                         *restrict wd = s->wd, *restrict iw = s->iwd;
            for (int k = 0; k < M; k++) {
                double qk = q[k], pk = pp[k];
                q[k] = ca[k] * qk + cb[k] * (pk * iw[k]);
                pp[k] = -cb[k] * (wd[k] * qk) + ca[k] * pk;
            }
        }
        if (!s->demoted) {
        tp_zone_u(s, uf);
        {
            float Fn[TP_MAXJ];
            const int fired = tp_sav_contact(s, bcur, uf, udf,
                                             th_on ? &fth : 0,
                                             rt_on ? Fn : 0);
            if (fired && rt_on) {
                /* lateral reaction -(w/R_t)*F_n onto the w bank
                   (the offline SAV A/B path, ratified) */
                for (int k = 0; k < M; k++) {
                    const double *Pr = s->phiF + (size_t)k * J;
                    double s2 = 0.0;
                    for (int j = 0; j < J; j++)
                        s2 += Pr[j] * (-(double)wl[j] / s->rt)
                              * (double)Fn[j];
                    s->pw[k] += dt * s2;
                }
            }
        }
        }
        if (th_on && !s->demoted) {
            /* thread 1-DOF update (exact rotation, ZOH footprint
               force; clamped +-thH — the bistable-edge guard) */
            const double zk = s->thz, vk = s->thv;
            s->thz = s->thCa * zk + s->thCb * (vk / s->thWd);
            s->thv = -s->thCb * (s->thWd * zk) + s->thCa * vk;
            s->thv -= dt * fth / s->thM;
            if (s->thz > s->thH) {
                s->thz = s->thH;
                if (s->thv > 0) s->thv = 0;
            }
            if (s->thz < -s->thH) {
                s->thz = -s->thH;
                if (s->thv < 0) s->thv = 0;
            }
        }
        /* w rotation + pol mixing (after contact) */
        {
            double *restrict qw = s->qw, *restrict pw = s->pw;
            const double *restrict ca = s->caw, *restrict cb = s->cbw,
                         *restrict wd = s->wdw, *restrict iw = s->iwdw;
            for (int k = 0; k < M; k++) {
                double qk = qw[k], pk = pw[k];
                qw[k] = ca[k] * qk + cb[k] * (pk * iw[k]);
                pw[k] = -cb[k] * (wd[k] * qk) + ca[k] * pk;
            }
        }
        if (s->sg != 0.0) {
            for (int k = 0; k < M; k++) {
                double qv = s->q[k], qh = s->qw[k];
                s->q[k] = s->cg * qv + s->sg * qh;
                s->qw[k] = -s->sg * qv + s->cg * qh;
                double pv = s->p[k], ph = s->pw[k];
                s->p[k] = s->cg * pv + s->sg * ph;
                s->pw[k] = -s->sg * pv + s->cg * ph;
            }
        }
        if (s->relMul < 1.0) {
            /* NOTE-OFF RELEASE: extra broadband decay toward the
               SETTLED WRAP (q -> q0, momenta -> 0) — never toward
               zero, which would lift the string off the bone. The
               demoted state already holds the deviation from q0. */
            const double m = s->relMul;
            double *restrict q = s->q, *restrict pp = s->p;
            double *restrict qw = s->qw, *restrict pw = s->pw;
            if (s->demoted) {
                for (int k = 0; k < M; k++) {
                    q[k] *= m; pp[k] *= m; qw[k] *= m; pw[k] *= m;
                }
            } else {
                const double *restrict q0 = s->q0;
                for (int k = 0; k < M; k++) {
                    q[k] = q0[k] + m * (q[k] - q0[k]);
                    pp[k] *= m; qw[k] *= m; pw[k] *= m;
                }
            }
        }
        if (sub == ovs - 1) {
            double o = 0.0;
            {
                const double *restrict po = s->phi_o,
                             *restrict pp = s->p;
                for (int k = 0; k < M; k++) o += po[k] * pp[k];
            }
            o *= s->gain;
            out[t] += o;
            double ao = fabs(o);
            if (ao > peak) peak = ao;
            if (s->ghostOn) {
                /* GHOST BANK: one output-rate linear rotation per
                   bank (frozen tables) + the frozen pol mix — the
                   previous notes ringing out at their own pitches
                   and t60s, no contact */
                double og = 0.0;
                {
                    double *restrict q = s->gq, *restrict pp = s->gp;
                    double *restrict qw = s->gqw, *restrict pw = s->gpw;
                    const double *restrict ca = s->gca,
                                 *restrict cb = s->gcb,
                                 *restrict wd = s->gwd,
                                 *restrict iw = s->giwd,
                                 *restrict caw = s->gcaw,
                                 *restrict cbw = s->gcbw,
                                 *restrict wdw = s->gwdw,
                                 *restrict iww = s->giwdw,
                                 *restrict po = s->phi_o;
                    for (int k = 0; k < M; k++) {
                        double qk = q[k], pk = pp[k];
                        q[k] = ca[k] * qk + cb[k] * (pk * iw[k]);
                        pp[k] = -cb[k] * (wd[k] * qk) + ca[k] * pk;
                        qk = qw[k]; pk = pw[k];
                        qw[k] = caw[k] * qk + cbw[k] * (pk * iww[k]);
                        pw[k] = -cbw[k] * (wdw[k] * qk) + caw[k] * pk;
                        og += po[k] * pp[k];
                    }
                    if (s->gsg != 0.0) {
                        for (int k = 0; k < M; k++) {
                            const double qv = q[k], qh = qw[k];
                            q[k] = s->gcg * qv + s->gsg * qh;
                            qw[k] = -s->gsg * qv + s->gcg * qh;
                            const double pv = pp[k], ph = pw[k];
                            pp[k] = s->gcg * pv + s->gsg * ph;
                            pw[k] = -s->gsg * pv + s->gcg * ph;
                        }
                    }
                }
                og *= s->gGain;
                out[t] += og;
                const double ag = fabs(og);
                if (ag > gpeak) gpeak = ag;
            }
        }
      }
    }
    int fin = 1;
    for (int k = 0; k < M; k++)
        if (!isfinite(s->p[k]) || !isfinite(s->q[k])
            || !isfinite(s->pw[k]) || fabs(s->q[k]) > 0.05) fin = 0;
    if (!isfinite(s->thz) || !isfinite(s->thv)) fin = 0;
    if (s->ghostOn && (!isfinite(s->gp[0]) || !isfinite(s->gq[M - 1])))
        fin = 0;
    if (!fin) {
        memcpy(s->q, s->q0, sizeof(double) * (size_t)M);
        memset(s->p, 0, sizeof(double) * (size_t)M);
        memset(s->qw, 0, sizeof(double) * (size_t)M);
        memset(s->pw, 0, sizeof(double) * (size_t)M);
        memset(s->Fw, 0, sizeof(s->Fw));
        memcpy(s->svPsi, s->svPsi0, sizeof(s->svPsi));
        memcpy(s->svEta, s->svEta0, sizeof(s->svEta));
        memcpy(s->svBud, s->svBud0, sizeof(s->svBud));
        s->demoted = 0;
        s->thz = 0.0; s->thv = 0.0;
        s->rampLeft = 0;
        s->ghostOn = 0;
        s->ghost_env = 0.0;
        s->active = 0;
        __atomic_add_fetch(&((tp_ctx *)c)->resets, 1,
                           __ATOMIC_RELAXED);
        return went_deep;
    }
    if (s->ghostOn) {
        s->ghost_env = gpeak > s->ghost_env ? gpeak
                                            : s->ghost_env * 0.98;
        if (s->ghost_env < 1e-3) s->ghostOn = 0;
    }
    s->idle_env = peak > s->idle_env ? peak : s->idle_env * 0.98;
    /* auto-idle at MUSICAL silence (~-86 dBFS post gain+FIR), not
       1e-7: the float contact limit cycle floors ~1e-4, so a 1e-7
       bar meant slots NEVER idled and cost accumulated with every
       note ever played (2026-08-03 choppy-under-polyphony bug) */
    if (s->idle_env < 1e-3 && !s->ghostOn) s->active = 0;
    /* STAGNATION idle (2026-08-03b): under-resolved contact can
       floor at a quiet limit cycle ABOVE the level bar (measured
       -55 dB at 587 Hz/M150 — inaudible post-chain, but a permanent
       96k solve). Compare against a ~2 s-old envelope reference —
       the floor env WOBBLES a few % block-to-block, so a
       per-block no-decay test never fires; the long-window trend
       does. Quiet + <1 dB decay per window = stuck floor: cull.
       (A live ghost holds the slot active either way — the ring-out
       must finish; the ghost is linear and cannot stagnate.) */
    if (++s->stagn >= 180) {
        /* bar 1e-2 (-40 dB kernel ~= -74 dBFS post-chain): the
           highest measured stuck floors (-43 dB at 880 Hz) must
           qualify; the cut lands well under perception */
        if (s->idle_env < 1e-2 && s->envPrev > 0.0
            && s->idle_env > 0.89 * s->envPrev && !s->ghostOn)
            s->active = 0;
        s->envPrev = s->idle_env;
        s->stagn = 0;
    }
    return went_deep;
}

/* SYNC render (tests/bench/serial fallback): deep budget applies */
void tanpura_render(void *vc, int n, double *out)
{
    tp_ctx *c = (tp_ctx *)vc;
    int deep_used = 0;
    for (int si = 0; si < c->nslots; si++) {
        tp_slot *s = &c->s[si];
        if (!s->used || !s->active) continue;
        deep_used += tp_render_slot(c, s, n, out,
                                    deep_used < c->deep_budget);
    }
}

long tanpura_reset_count(void *vc)
{
    tp_ctx *c = (tp_ctx *)vc;
    return __atomic_load_n(&c->resets, __ATOMIC_RELAXED);
}

/* ---- async one-block-late pool (the jt live pattern): the audio
   callback RECORDS note events + READS completed audio; a dispatcher
   thread drains events and renders the next block with the worker
   pool on its own time. Constant one-block latency; overload
   fade-fills and counts an underrun instead of glitching. ---- */

static void tp_drain_events(tp_ctx *c)
{
    long long r = c->evR;
    const long long w = __atomic_load_n(&c->evW, __ATOMIC_ACQUIRE);
    for (; r < w; r++) {
        const int i = (int)(r & (TP_EVN - 1));
        const int slot = c->evSlot[i];
        const int op = c->evOp[i];
        const double amp = c->evAmp[i];
        if (slot < 0) {
            if (op == 0)
                for (int k = 0; k < c->nslots; k++) {
                    c->s[k].active = 0;
                    c->s[k].ghostOn = 0;
                    c->s[k].ghost_env = 0.0;
                }
        } else if (slot < c->nslots && c->s[slot].used) {
            tp_slot *s = &c->s[slot];
            if (op == 1) { tp_apply_bend(s, amp); continue; }
            if (op == 2) { tp_apply_release(s, amp); continue; }
            if (op == 3) {
                s->iso = amp < 0.0 ? 0.0 : (amp > 1.0 ? 1.0 : amp);
                continue;
            }
            if (op == 4) { tp_apply_drive(s, amp); continue; }
            if (op == 6) {
                tanpura_prepluck_bend((void *)c, slot, amp);
                continue;
            }
            if (amp < 0.0) { tanpura_damp((void *)c, slot); continue; }
            /* op 0 note: same body as the sync entry point
               (migration, drive, fd ramp, demote-promotion,
               injection, cap) */
            tanpura_pluck((void *)c, slot, amp);
        }
    }
    c->evR = r;
}

static void *tp_worker_run(void *va)
{
    tp_warg *a = (tp_warg *)va;
    tp_ctx *c = a->c;
    const int idx = a->idx;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    int mygen = 0;
    pthread_mutex_lock(&c->mx);
    for (;;) {
        while (c->gen == mygen && !c->quit)
            pthread_cond_wait(&c->cvW, &c->mx);
        if (c->quit) break;
        mygen = c->gen;
        const int n = c->wN;
        const int per = c->wPer;
        pthread_mutex_unlock(&c->mx);
        double *buf = c->wBuf + (size_t)idx * TP_ABLK;
        memset(buf, 0, sizeof(double) * (size_t)n);
        (void)per;
        /* WORK-STEALING over the heavy-first active list (2026-08-03b):
           the old static round-robin paired slots blindly — with
           mixed costs (high notes ~1x RT alone) an unlucky pair blew
           the block period while other workers idled. Greedy
           heavy-first stealing bounds the makespan near max(slot). */
        for (;;) {
            const int i = __atomic_fetch_add(&c->wCursor, 1,
                                             __ATOMIC_RELAXED);
            if (i >= c->actN) break;
            tp_slot *s = &c->s[c->actList[i]];
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
            tp_render_slot(c, s, n, buf, 1);
            clock_gettime(CLOCK_MONOTONIC_RAW, &t1);
            const double el = ((double)(t1.tv_sec - t0.tv_sec)
                + 1e-9 * (double)(t1.tv_nsec - t0.tv_nsec))
                / (double)(n > 0 ? n : 1);
            /* rise fast (overload must register within ~2 blocks),
               decay slow (jitter spikes shouldn't steal voices) */
            s->costEma = el > s->costEma
                ? 0.5 * s->costEma + 0.5 * el
                : 0.9 * s->costEma + 0.1 * el;
        }
        pthread_mutex_lock(&c->mx);
        c->done++;
        if (c->done >= c->poolN) pthread_cond_signal(&c->cvD);
    }
    pthread_mutex_unlock(&c->mx);
    return NULL;
}

static void tp_shed_quietest(tp_ctx *c)
{
    /* never below 2 voices (a tanpura that goes MUTE under load is
       worse than one that dips), never the most recent pluck (the
       note just played must sound) */
    int qi = -1, nact = 0;
    double qe = 1e30;
    for (int k = 0; k < c->nslots; k++) {
        tp_slot *s = &c->s[k];
        if (!s->used || !s->active || s->is_fd) continue;
        nact++;
        if (k == c->lastPluck) continue;
        if (s->idle_env < qe) { qe = s->idle_env; qi = k; }
    }
    if (qi >= 0 && nact > 2) c->s[qi].active = 0;
}

static void tp_run_job(tp_ctx *c, int n)
{
    tp_drain_events(c);
    const int nth = c->poolN;
    /* heavy-first active list for the stealing workers */
    int an = 0;
    for (int si = 0; si < c->nslots && an < 64; si++) {
        tp_slot *s = &c->s[si];
        if (!s->used || !s->active) continue;
        int j = an++;
        while (j > 0
               && c->s[c->actList[j - 1]].costEma < s->costEma) {
            c->actList[j] = c->actList[j - 1];
            j--;
        }
        c->actList[j] = si;
    }
    struct timespec j0, j1;
    clock_gettime(CLOCK_MONOTONIC_RAW, &j0);
    pthread_mutex_lock(&c->mx);
    c->actN = an;
    __atomic_store_n(&c->wCursor, 0, __ATOMIC_RELAXED);
    c->wN = n;
    c->wPer = nth;
    c->done = 0;
    c->gen++;
    pthread_cond_broadcast(&c->cvW);
    while (c->done < nth)
        pthread_cond_wait(&c->cvD, &c->mx);
    pthread_mutex_unlock(&c->mx);
    clock_gettime(CLOCK_MONOTONIC_RAW, &j1);
    (void)j0; (void)j1;
    long long w = c->outW;
    for (int t = 0; t < n; t++) {
        double acc = 0.0;
        for (int th = 0; th < nth; th++)
            acc += c->wBuf[(size_t)th * TP_ABLK + t];
        c->outRing[(w + t) & (TP_OUTN - 1)] = acc;
    }
    __atomic_store_n(&c->outW, w + n, __ATOMIC_RELEASE);
    /* UNDERRUN-FEEDBACK CONTROLLER (2026-08-03b — the third design;
       the first two mis-fired: makespan thresholds sit inside one
       heavy note's normal range, and ring slack GROWS during
       sustained underrun because failed callbacks don't consume).
       The underrun counter is the ground truth: while it's
       incrementing, shed the quietest voice, one per block, until
       the instrument fits the machine. The pluck-time budget bar
       (accurate pen0-informed seeds) pre-sheds the egregious so
       this trims, not rescues. */
    {
        const long ur = __atomic_load_n(&c->underruns,
                                        __ATOMIC_RELAXED);
        /* rate-limited: an underrun BURST is one overload event —
           shedding once per burst-window keeps a 4-block burst from
           killing 4 voices */
        if (ur > c->lastUr) {
            if (++c->overN >= 3) {
                tp_shed_quietest(c);
                c->overN = 0;
            }
        } else if (c->overN > 0) c->overN--;
        c->lastUr = ur;
    }
}

static void *tp_dispatch_run(void *va)
{
    tp_ctx *c = (tp_ctx *)va;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    pthread_mutex_lock(&c->mx);
    for (;;) {
        while (!c->quit
               && __atomic_load_n(&c->jobW, __ATOMIC_ACQUIRE)
                  == c->jobR) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 1000000;
            if (ts.tv_nsec >= 1000000000) {
                ts.tv_nsec -= 1000000000;
                ts.tv_sec += 1;
            }
            pthread_cond_timedwait(&c->cvW, &c->mx, &ts);
        }
        if (c->quit) break;
        /* JOB BATCHING (2026-08-03b): fold ALL queued jobs into one
           pool run. At the M150/x4 chord load the heaviest slot
           alone is ~0.96x the block period, leaving <0.5 ms for
           wake/join/sum overheads — jitter starved the pool one
           block at a time and the deficit compounded. Batching N
           queued blocks pays those overheads once per batch; the
           1536-sample prefill covers the extra in-flight depth. */
        int n = 0;
        long long jr = c->jobR;
        const long long jw =
            __atomic_load_n(&c->jobW, __ATOMIC_ACQUIRE);
        while (jr < jw && n + c->jobN[jr & (TP_ARING - 1)] <= TP_ABLK) {
            n += c->jobN[jr & (TP_ARING - 1)];
            jr++;
        }
        if (jr == c->jobR) { jr++; n = c->jobN[c->jobR & (TP_ARING - 1)]; }
        pthread_mutex_unlock(&c->mx);
        tp_run_job(c, n);
        pthread_mutex_lock(&c->mx);
        c->jobR = jr;
    }
    pthread_mutex_unlock(&c->mx);
    return NULL;
}

/* arm the pool (call at engine build, NEVER on the audio thread).
   nworkers < 2 keeps the serial sync path. */
void tanpura_set_threads(void *vc, int nworkers)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (nworkers > TP_MAXW) nworkers = TP_MAXW;
    if (c->poolN > 0) return;         /* one-shot arm (engine build) */
    if (nworkers < 2) return;
    if (!c->poolInit) {
        pthread_mutex_init(&c->mx, NULL);
        pthread_cond_init(&c->cvW, NULL);
        pthread_cond_init(&c->cvD, NULL);
        c->poolInit = 1;
    }
    c->wBuf = (double *)malloc(sizeof(double)
                               * (size_t)nworkers * TP_ABLK);
    c->deep_budget = 1 << 30;         /* pool path: no degradation */
    c->gen = 0; c->done = 0; c->quit = 0;
    /* prefill one block of silence: the callback then carries a block
       of ring slack beyond the in-flight job — transient absorption
       for chord plucks at +~21 ms total latency (fine for a plucked
       drone; the paced gate holds underruns to the startup fill) */
    /* three blocks of slack (was 1024 = 2): the M150/x4-deep config
       runs the 8-note chord at ~5x RT total — a per-block makespan
       ~0.9-1.0x the period, where scheduler jitter alone caused
       ~100 underruns in the 6 s gate. Latency 21 -> ~32 ms on the
       plucked drone only (the earlier 21 ms precedent: inaudible). */
    memset(c->outRing, 0, sizeof(double) * 1536);
    c->outW = 1536;
    c->poolN = nworkers;
    for (int i = 0; i < nworkers; i++) {
        c->wArg[i].c = c;
        c->wArg[i].idx = i;
        pthread_create(&c->wTid[i], NULL, tp_worker_run, &c->wArg[i]);
    }
    pthread_create(&c->dTid, NULL, tp_dispatch_run, c);
}

int tanpura_pool_size(void *vc) { return ((tp_ctx *)vc)->poolN; }
long tanpura_underruns(void *vc)
{
    return __atomic_load_n(&((tp_ctx *)vc)->underruns,
                           __ATOMIC_RELAXED);
}

/* enqueue a note event (audio/MIDI thread safe — SPSC vs the
   dispatcher; the Swift engine serializes producers). amp < 0 damps
   the slot; slot -1 damps all. Pool path only — the sync path
   mutates slots directly via tanpura_pluck/tanpura_damp. */
void tanpura_event2(void *vc, int slot, int op, double val)
{
    tp_ctx *c = (tp_ctx *)vc;
    const long long w = c->evW;
    if (w - __atomic_load_n(&c->evR, __ATOMIC_ACQUIRE) >= TP_EVN - 1)
        return;                       /* ring full: drop (never block) */
    const int i = (int)(w & (TP_EVN - 1));
    c->evSlot[i] = slot;
    c->evOp[i] = op;
    c->evAmp[i] = val;
    __atomic_store_n(&c->evW, w + 1, __ATOMIC_RELEASE);
}

void tanpura_event(void *vc, int slot, double amp)
{
    tanpura_event2(vc, slot, 0, amp);
}

/* the async callback: read one block of COMPLETED audio (fade-fill
   an underrun), then enqueue the render of the next block. */
void tanpura_render_async(void *vc, int n, double *out)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (c->poolN < 2) {               /* pool not armed: sync path */
        tanpura_render(vc, n, out);
        return;
    }
    const long long have =
        __atomic_load_n(&c->outW, __ATOMIC_ACQUIRE) - c->outR;
    if (have >= n) {
        long long r = c->outR;
        for (int t = 0; t < n; t++) {
            out[t] += c->outRing[(r + t) & (TP_OUTN - 1)];
            c->lastOut = c->outRing[(r + t) & (TP_OUTN - 1)];
        }
        c->outR = r + n;
    } else {
        /* underrun (startup fill or overload): fade the last sample
           to zero instead of glitching */
        double v = c->lastOut;
        for (int t = 0; t < n; t++) {
            v *= 0.999;
            out[t] += v;
        }
        c->lastOut = v;
        __atomic_add_fetch(&c->underruns, 1, __ATOMIC_RELAXED);
    }
    /* enqueue the next block */
    const long long jw = c->jobW;
    if (jw - c->jobR < TP_ARING) {
        c->jobN[jw & (TP_ARING - 1)] = n <= TP_ABLK ? n : TP_ABLK;
        __atomic_store_n(&c->jobW, jw + 1, __ATOMIC_RELEASE);
        if (pthread_mutex_trylock(&c->mx) == 0) {
            pthread_cond_broadcast(&c->cvW);
            pthread_mutex_unlock(&c->mx);
        }
    }
}
