/* TANPURA live kernel: one slot per mounted pitch, settled onto its
   static wrap ONCE at build (through this kernel, so q0 is the solver's
   own equilibrium), plucked at note-on, auto-idling when quiet. Per
   slot: damped modal rotation (v + detuned w bank), energy-stable (SAV)
   grid contact, contact-mediated polarization (b_eff = b − w²/2R_t,
   lateral reaction −(w/R_t)·F_n), a 1-DOF jiva thread. */
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

#define TP_MAXM 384   /* mode-count ceiling; sizes the stack buffers */
#define TP_MAXJ 64

/* float fast pow (shared with bow_kernel.c): float32 zone math over
   double modal state */
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

typedef struct {
    int used, active, M, J;
    /* tables (owned) */
    double *ca, *cb, *ca4, *cb4, *ca2, *cb2, *cas, *cbs, *wd;
    double *caw, *cbw, *wdw;
    double *iwd, *iwdw;            /* 1/wd tables */
    double *Phi, *phiF, *b, *q0;
    float *Phif, *phiFf;           /* float twins for the hot matvecs */
    float *Gf, *G4f, *gdf, *gd4f;
    float *G2f, *gd2f;             /* dt/2 compliance (= 4x G4) */
    double *phi_o, *dq;
    double kc, alpha, hcB, deep, dt, gain;
    double cg, sg, av, aw;      /* pol mixing + pluck-angle split */
    double rt;                  /* transverse curvature (0 = off) */
    /* 1-DOF jiva thread under gth; th_f = 0 = rigid bump baked into b */
    double *gth;
    double thBase, thH;
    double thCa, thCb, thWd, thM;
    int rampN;                  /* pluck draw ramp (internal samples; 0 = instant) */
    int ovs;                    /* internal steps per OUTPUT sample */
    /* state */
    double *q, *p, *qw, *pw;
    double thz, thv;
    long rampLeft;
    double rampAmp, rampPrev;
    float Fw[TP_MAXJ];          /* warm contact forces (pre-hc) */
    double idle_env;            /* output envelope for auto-idle */
    double envPrev;             /* stagnation-idle: last window env */
    int stagn;                  /* blocks since the last window */
    double pen0;                /* settled static wrap penetration */
    int forceDeep;              /* f0 > 140 Hz: costEma seed x4 */
    double costEma;             /* smoothed render cost (s/sample) —
                                   the pool's heavy-first sort key */
    /* ---- SAV contact: kq/kp = exact constant-force-over-step response
       (dq = F kq, dp = F kp); svG = matching within-step compliance;
       psi/eta/bud = per-node auxiliary state (dissipation budget).
       Passive at any rate and M by construction. ---- */
    double *svKq, *svKp, *svG;
    double svPsi[TP_MAXJ], svEta[TP_MAXJ], svBud[TP_MAXJ];
    double svPsi0[TP_MAXJ], svEta0[TP_MAXJ], svBud0[TP_MAXJ];
    /* ---- live bend + release: base tables let a bend rescale every
       mode's rotation in place; relMul < 1 decays toward the wrap ---- */
    double bendRatio;           /* mode-frequency scale (1 = unbent) */
    double *wd0, *wdw0;         /* mount-time mode frequencies */
    double *envE, *envEw;       /* per-mode damping envelopes hypot(ca,cb) */
    double relMul;              /* per-internal-sample release multiplier */
    /* ---- string bank: with iso > 0 each pluck is a SEPARATE STRING —
       the primary's ringing state migrates to a CLONE slot (frozen
       pitch, full simulation), scaled by iso, and the pluck lands on
       settled state; past polyMax the OLDEST clone goes to the ghost. */
    double iso;                 /* pluck isolation (op 3; 0 = ride the ring) */
    int justMigrated;           /* pre-pluck bend already migrated */
    int isClone;                /* owns only state + frozen tables */
    int owner;                  /* clone: primary slot index */
    long long seq;              /* clone: pluck sequence (LRU key) */
    double drive;
    double gain0;               /* mount output gain (gain = gain0/drive) */
    /* ---- ghost bank: evicted notes ring out LINEARLY (same per-mode
       envelopes, no contact), superposed into one bank per slot. Tables
       freeze at the first handoff at OUTPUT rate (R_in^ovs). ---- */
    int ghostOn;
    double *gq, *gp, *gqw, *gpw;            /* deviation state */
    double *gca, *gcb, *gwd, *giwd;         /* frozen v-bank rotation */
    double *gcaw, *gcbw, *gwdw, *giwdw;     /* frozen w-bank rotation */
    double gcg, gsg;                        /* frozen pol mix */
    double gGain;
    double ghost_env;
    int demoted;                /* tail demotion: q holds the DEVIATION
                                   from q0 and rings linearly (no zone/
                                   contact/thread); re-pluck promotes */
} tp_slot;

static int tp_sav_contact(tp_slot *s, const float *beff,
                          const float *uf, const float *udf,
                          double *fth_out, float *Fn_out);

/* the settled SAV snapshot (psi/eta/dissipation budget) */
static void tp_restore_sav(tp_slot *s)
{
    memcpy(s->svPsi, s->svPsi0, sizeof(s->svPsi));
    memcpy(s->svEta, s->svEta0, sizeof(s->svEta));
    memcpy(s->svBud, s->svBud0, sizeof(s->svBud));
}

/* back to the settled static wrap: q = q0, everything else at rest.
   The ONE place a string is returned to its equilibrium (idle wake,
   migration, divergence reset). */
static void tp_reset_settled(tp_slot *s)
{
    memcpy(s->q, s->q0, sizeof(double) * (size_t)s->M);
    memset(s->p, 0, sizeof(double) * (size_t)s->M);
    memset(s->qw, 0, sizeof(double) * (size_t)s->M);
    memset(s->pw, 0, sizeof(double) * (size_t)s->M);
    memset(s->Fw, 0, sizeof(s->Fw));
    tp_restore_sav(s);
}

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
    int polyMax;                 /* live history strings (atomic) */
    tp_slot *s;
    long resets;                 /* divergence-guard resets (telemetry) */
    /* ---- note-event SPSC ring (producer -> dispatcher) ---- */
    int evSlot[TP_EVN];
    int evOp[TP_EVN];            /* 0 note 1 bend 2 release 3 iso 4 drive 6 pre-pluck bend */
    double evAmp[TP_EVN];        /* op 0 amp (<0 damps); 1/6 ratio; 2 rate 1/s */
    long long evW, evR;          /* atomic W (producer), R (dispatcher) */
    /* ---- async one-block-late machinery ---- */
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
    int overN;                   /* underrun-burst streak */
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
    /* clone pool: state + frozen-table buffers sized for any owner */
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
        /* clones alias the owner's other tables — never free them */
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
    /* live-bend base tables (ca/cb = E*cos/sin(wd*dt), so E = hypot) */
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
    /* SAV tables: exact-response kick + matching compliance */
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
    /* wd[0]/2pi ~ f0 */
    s->forceDeep = (wd[0] / (2.0 * 3.14159265358979323846)) > 140.0;
    /* pre-measurement cost seed — a deliberate under-estimate (the
       pool timing corrects it within ~10 blocks) so a brief overshoot
       rides the ring slack rather than stealing voices at mount */
    s->costEma = 3.6e-8 * (double)M;
    s->used = 1;
    s->active = 0;
    s->idle_env = 0.0;
}

/* zone displacement + velocity (float tables, unrolled: clang will not
   vectorize float reductions without -ffast-math) */
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


/* displacement-only zone eval — the per-sample hot matvec (SAV never
   reads the zone velocity) */
static void tp_zone_u(const tp_slot *s, float *uf)
{
    const int M = s->M, J = s->J;
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

/* build-time settle onto the static wrap: heavy-damping rotation +
   contact, then q -> q0. Off the audio thread. */
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
    /* settled SAV snapshot — every reset/idle-wake restores it with q0 */
    memcpy(s->svPsi0, s->svPsi, sizeof(s->svPsi));
    memcpy(s->svEta0, s->svEta, sizeof(s->svEta));
    memcpy(s->svBud0, s->svBud, sizeof(s->svBud));
    memset(s->p, 0, sizeof(double) * (size_t)M);
    memset(s->qw, 0, sizeof(double) * (size_t)M);
    memset(s->pw, 0, sizeof(double) * (size_t)M);
    tp_zone(s, uf, udf);
    float p0 = 0.0f;
    for (int j = 0; j < J; j++) {
        const float d = bf[j] - uf[j];
        if (d > p0) p0 = d;
    }
    s->pen0 = (double)p0;
    /* deep-wrap / high-register slots cost ~4x: seed so the pluck-time
       budget sheds BEFORE the overload */
    if (s->pen0 > s->deep || s->forceDeep) s->costEma *= 4.0;
    s->active = 0;
}

void tanpura_set_oversample(void *vc, int slot, int steps)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nslots) return;
    c->s[slot].ovs = steps > 1 ? steps : 1;
}

/* voice management: steal the QUIETEST ringing modal slot when a pluck
   would exceed the count cap or the cost budget (costEma = s/sample
   from the pool timing) — a slammed chord keeps its loudest voices
   instead of underrunning the whole instrument. */
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
            if (!s->used || !s->active) continue;
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

/* ghost handoff: move `frac` of SRC's ringing deviation into DST's
   ghost bank — on clone-pool overflow (full band) or with polyMax 0
   (`split`: only partials above 2*f0, since the same-slot pluck
   replaces the fundamental). A releasing string never enters. */
static void tp_ghost_handoff(tp_slot *dst, tp_slot *src, double frac,
                             int split)
{
    if (!(frac > 0.0) || !src->active) return;
    if (frac > 1.0) frac = 1.0;
    const double keep = 1.0 - frac;
    const int M = src->M;
    const int toGhost = src->relMul >= 1.0;
    if (toGhost && !dst->ghostOn) {
        /* freeze SRC's rotation composed to output rate (E^ovs) */
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
    /* linear superposition; pre-scale to the frozen gGain */
    const double gs = !toGhost ? 0.0
        : (dst->gGain != 0.0 ? frac * src->gain / dst->gGain : frac);
    const double w1 = src->wd[0];
    /* a DEMOTED string's q already holds the deviation, so its wrap
       anchor is 0 (x - 0 and 0 + keep*(x - 0) are exact identities) */
    const int dem = src->demoted;
    for (int k = 0; k < M; k++) {
        double wk = 1.0;
        if (split) {
            wk = (src->wd[k] / w1 - 2.0) * 0.5;
            if (wk < 0.0) wk = 0.0;
            if (wk > 1.0) wk = 1.0;
        }
        const double g2 = gs * wk;
        const double q0k = dem ? 0.0 : src->q0[k];
        dst->gq[k] += g2 * (src->q[k] - q0k);
        dst->gp[k] += g2 * src->p[k];
        dst->gqw[k] += g2 * src->qw[k];
        dst->gpw[k] += g2 * src->pw[k];
        src->q[k] = q0k + keep * (src->q[k] - q0k);
        src->p[k] *= keep; src->qw[k] *= keep; src->pw[k] *= keep;
    }
    if (!dem) {
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

/* pluck drive: displacement x D, output gain x 1/D at the pluck — the
   power-law contact sees D-times deeper engagement at calibrated level.
   D 1 is a strict no-op; a drive edit steps a ringing tail by Dold/Dnew. */
static void tp_apply_drive(tp_slot *s, double d)
{
    if (d < 0.05) d = 0.05;
    if (d > 20.0) d = 20.0;
    s->drive = d;
}

/* migration: move the primary's ringing string onto a free clone
   (frozen pitch; later glides retune only the primary), evicting the
   OLDEST clone to its owner's ghost when past polyMax (split only for
   the re-plucked slot); polyMax 0 hands off straight to the ghost. */
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
        const int M = s->M, J = s->J;
        cl->M = M; cl->J = J;
        cl->owner = slot;
        cl->seq = ++c->pluckSeq;
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
        /* aliased (bend never touches these) */
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
    tp_reset_settled(s);
    s->thz = 0.0; s->thv = 0.0;
    s->demoted = 0;
    s->rampLeft = 0;
    s->relMul = 1.0;
}

/* note-on: activate + add the angled pluck (amp = TOTAL displacement
   in metres; the v/w split is the mount's pol_th) */
void tanpura_pluck(void *vc, int slot, double amp)
{
    tp_ctx *c = (tp_ctx *)vc;
    tp_slot *s = &c->s[slot];
    if (!s->used || s->isClone) return;
    /* isolation: migrate the ringing string unless a pre-pluck bend
       already did */
    if (s->iso > 0.0 && s->active && !s->justMigrated)
        tp_migrate(c, slot, s->iso);
    s->justMigrated = 0;
    /* drive (drive 1 leaves gain bit-identical) */
    if (s->drive > 0.0) {
        amp *= s->drive;
        s->gain = s->gain0 / s->drive;
    }
    if (s->demoted) {
        for (int k = 0; k < s->M; k++) s->q[k] += s->q0[k];
        tp_restore_sav(s);
        s->demoted = 0;
    }
    if (!s->active) {
        /* waking from idle: exact settled wrap; a stale ghost is silenced */
        tp_reset_settled(s);
        s->demoted = 0;
        s->ghostOn = 0;
        s->ghost_env = 0.0;
        s->active = 1;
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

/* hard-stop a slot: primary, its clones, its ghost */
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

/* live retune: rescale every mode's rotation angle from the base tables
   (exact; envelope E preserved); the SAV tables follow. Modes past ~the
   output Nyquist get ca=cb=0 (silence, not aliasing). NEVER concurrent
   with tp_render_slot on the same slot. */
static void tp_apply_bend(tp_slot *s, double r)
{
    if (!s->wd0) return;
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

/* note-off release: demote immediately (q = deviation from the wrap,
   contact skipped) and decay by relMul per internal sample. Demotion is
   load-bearing: with contact live the pull toward q0 becomes a limit
   cycle that never dies; linearized it idles. A finger stop. */
static void tp_apply_release(tp_slot *s, double rate)
{
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

/* pluck isolation (sync path; pool path = op 3) */
void tanpura_set_touch(void *vc, int slot, double touch)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nUser) return;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    s->iso = touch < 0.0 ? 0.0 : (touch > 1.0 ? 1.0 : touch);
}

/* pre-pluck bend (op 6): a re-pluck at a DIFFERENT pitch migrates the
   ringing string first, then retunes the primary. Glide bends (op 1)
   never migrate. */
void tanpura_prepluck_bend(void *vc, int slot, double ratio)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (slot < 0 || slot >= c->nUser) return;
    tp_slot *s = &c->s[slot];
    if (!s->used) return;
    if (s->iso > 0.0 && s->active) {
        double rr = ratio < 0.25 ? 0.25 : (ratio > 4.0 ? 4.0 : ratio);
        if (rr != s->bendRatio) {
            tp_migrate(c, slot, s->iso);
            s->justMigrated = 1;
        }
    }
    tp_apply_bend(s, ratio);
}

/* pluck drive (sync path; pool path = op 4) */
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

/* scope telemetry: a slot's output envelope (block peak, 2%/block
   decay, output units), 0 when idle. Racy display read. */
double tanpura_slot_env(void *vc, int slot)
{
    tp_ctx *c = (tp_ctx *)vc;
    if (!c || slot < 0 || slot >= c->nslots) return 0.0;
    const tp_slot *s = &c->s[slot];
    return (s->used && s->active) ? s->idle_env : 0.0;
}

/* SAV modal contact: one J-system per internal sample, no iterations,
   no substeps; approach-only viscosity TP_SAV_CV. Returns 1 if any
   force fired. */
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
    /* exact-response kicks */
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

/* render one modal slot, ACCUMULATING into out */
static void tp_render_slot(tp_ctx *c, tp_slot *s, int n, double *out)
{
    const int M = s->M, J = s->J;
    const double dt = s->dt, dt4 = dt / 4.0;
    float uf[TP_MAXJ], udf[TP_MAXJ], wl[TP_MAXJ], bf[TP_MAXJ];
    double qs[TP_MAXM], ps[TP_MAXM];
    double peak = 0.0, gpeak = 0.0;
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
        /* damped rotation, zone eval, SAV solve */
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
                /* lateral reaction -(w/R_t)*F_n onto the w bank */
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
            /* thread 1-DOF update, clamped +-thH */
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
            /* release: decay toward the SETTLED WRAP (never toward
               zero — that would lift the string off the bone) */
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
                /* ghost bank: output-rate linear rotation, frozen tables */
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
        tp_reset_settled(s);
        s->demoted = 0;
        s->thz = 0.0; s->thv = 0.0;
        s->rampLeft = 0;
        s->ghostOn = 0;
        s->ghost_env = 0.0;
        s->active = 0;
        __atomic_add_fetch(&((tp_ctx *)c)->resets, 1,
                           __ATOMIC_RELAXED);
        return;
    }
    if (s->ghostOn) {
        s->ghost_env = gpeak > s->ghost_env ? gpeak
                                            : s->ghost_env * 0.98;
        if (s->ghost_env < 1e-3) s->ghostOn = 0;
    }
    s->idle_env = peak > s->idle_env ? peak : s->idle_env * 0.98;
    /* auto-idle at musical silence (~-86 dBFS post chain) */
    if (s->idle_env < 1e-3 && !s->ghostOn) s->active = 0;
    /* stagnation idle: an under-resolved contact can floor at a quiet
       limit cycle ABOVE the level bar; quiet + <1 dB decay over a ~2 s
       window = stuck, cull (a live ghost keeps the slot active). */
    if (++s->stagn >= 180) {
        if (s->idle_env < 1e-2 && s->envPrev > 0.0
            && s->idle_env > 0.89 * s->envPrev && !s->ghostOn)
            s->active = 0;
        s->envPrev = s->idle_env;
        s->stagn = 0;
    }
}

/* SYNC render (tests/bench/serial fallback) */
void tanpura_render(void *vc, int n, double *out)
{
    tp_ctx *c = (tp_ctx *)vc;
    for (int si = 0; si < c->nslots; si++) {
        tp_slot *s = &c->s[si];
        if (!s->used || !s->active) continue;
        tp_render_slot(c, s, n, out);
    }
}

long tanpura_reset_count(void *vc)
{
    tp_ctx *c = (tp_ctx *)vc;
    return __atomic_load_n(&c->resets, __ATOMIC_RELAXED);
}

/* ---- async one-block-late pool: the callback RECORDS events + READS
   completed audio; the dispatcher drains events and renders the next
   block with the workers. Overload fade-fills + counts an underrun. */

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
            /* op 0 note: the sync entry point's body */
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
        /* work-stealing over the heavy-first list bounds the makespan
           near max(slot) */
        for (;;) {
            const int i = __atomic_fetch_add(&c->wCursor, 1,
                                             __ATOMIC_RELAXED);
            if (i >= c->actN) break;
            tp_slot *s = &c->s[c->actList[i]];
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
            tp_render_slot(c, s, n, buf);
            clock_gettime(CLOCK_MONOTONIC_RAW, &t1);
            const double el = ((double)(t1.tv_sec - t0.tv_sec)
                + 1e-9 * (double)(t1.tv_nsec - t0.tv_nsec))
                / (double)(n > 0 ? n : 1);
            /* rise fast, decay slow (jitter spikes must not steal voices) */
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
    /* never below 2 voices, never the most recent pluck */
    int qi = -1, nact = 0;
    double qe = 1e30;
    for (int k = 0; k < c->nslots; k++) {
        tp_slot *s = &c->s[k];
        if (!s->used || !s->active) continue;
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
    /* underrun feedback: while the counter increments, shed the
       quietest voice (one per burst) until the instrument fits the
       machine — the pluck-time budget pre-sheds, this trims */
    {
        const long ur = __atomic_load_n(&c->underruns,
                                        __ATOMIC_RELAXED);
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
        /* batch all queued jobs into one pool run: wake/join/sum
           overheads paid once per batch */
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

/* arm the pool at engine build (NEVER on the audio thread); nworkers < 2
   keeps the serial sync path */
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
    c->gen = 0; c->done = 0; c->quit = 0;
    /* prefill three blocks of silence: ring slack for chord-pluck
       transients (~32 ms total latency, inaudible on a plucked drone) */
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

/* enqueue a note event — SPSC vs the dispatcher (the Swift engine
   serializes producers). Pool path only. */
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

/* async callback: read one block of COMPLETED audio (fade-fill an
   underrun), enqueue the next */
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
        /* underrun (startup fill or overload): fade out, no glitch */
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
