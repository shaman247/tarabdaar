/* THE MODAL-JAWARI TARAF of the String kernel: the load ABI, the row
   ticks, the worker pool, the deferred post-pass and the bow_poly_jt_*
   setters. The played strings, the body and the render loop are
   bow_kernel_poly.c; the shared state is bow_poly_internal.h. */
#include "bow_poly_internal.h"

static double jt_maxpen(int M, int J, const float *phiU,
                        const float *b_, const double *q);

void bow_poly_jt_load(void *vst, int njt, int J, const int *M,
                 const double *ca, const double *cb,
                 const double *ca4, const double *cb4,
                 const double *wd, const double *radScale,
                 const double *pinScale, const double *cplScale,
                 const double *phiD,
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
    st->jtCa = kc_dup_d(ca, mtot);   st->jtCb = kc_dup_d(cb, mtot);
    st->jtCa4 = kc_dup_d(ca4, mtot); st->jtCb4 = kc_dup_d(cb4, mtot);
    st->jtWd = kc_dup_d(wd, mtot);
    st->jtWdI = (double *)malloc(sizeof(double) * mtot);
    for (int i = 0; i < mtot; i++) st->jtWdI[i] = 1.0 / wd[i];
    st->jtPhiD = kc_dup_d(phiD, mtot);
    st->jtPhiU = kc_dup_f(phiU, ztot); st->jtPhiF = kc_dup_f(phiF, ztot);
    st->jtB = kc_dup_f(b, njt * J);
    st->jtG = kc_dup_f(G, njt * J * J); st->jtG4 = kc_dup_f(G4, njt * J * J);
    st->jtGd = kc_dup_f(gd, njt * J);   st->jtGd4 = kc_dup_f(gd4, njt * J);
    st->jtKc = phys[0]; st->jtAlpha = phys[1]; st->jtHcB = phys[2];
    st->jtDeep = phys[3]; st->jtGain = phys[4]; st->jtDrv = phys[5];
    st->jtGainCur = st->jtGain;
    st->jtGainA = kc_onepole_tau_sr(0.040, st->sr);
    st->jtDiv = (int)(phys[6] + 0.5);
    if (st->jtDiv < 1) st->jtDiv = 1;
    st->jtPhase = 0; st->jtHold = 0.0; st->jtFacc = 0.0;
    st->jtLpY = 0.0;
    st->jtHpA = 0.0; st->jtHpY = 0.0;
    st->jtQ = kc_dup_d(q0, mtot);    /* settled static wrap (builder) */
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
        st->scopeRel = kc_onepole_dt(dtj, 0.120);
        st->scopeModeDk = (float)exp(-4.0 * dtj / 0.150);
    }
    st->scopeEnv = (double *)calloc(njt, sizeof(double));
    st->scopeMode = (float *)calloc((size_t)njt * (size_t)st->scopeK,
                                    sizeof(float));
    st->scopeCnt = (unsigned *)calloc(njt, sizeof(unsigned));
    /* bridge-force radiation: the per-row unit match from the builder;
       DC blockers primed to their first sample */
    st->jtRadA = 1.0 - exp(-2.0 * M_PI * 8.0 * (double)st->jtDiv / st->sr);
    st->jtRadScale = kc_dup_d(radScale, njt);
    st->jtRadScaleCur = kc_dup_d(radScale, njt);
    st->jtRadSlewA = kc_onepole_dt((double)st->jtDiv / st->sr, 0.040);
    st->jtRadLp = (double *)calloc(njt, sizeof(double));
    st->jtRadPrime = (unsigned char *)malloc((size_t)njt);
    memset(st->jtRadPrime, 1, (size_t)njt);
    /* termination (pin) force: the builder's per-row unit match, permanent */
    st->jtRadPinScale = kc_dup_d(pinScale, njt);
    st->jtRadPinScaleCur = kc_dup_d(pinScale, njt);
    /* two-way bridge coupling: the per-row reciprocal of the SHARED
       force->radiated factor of radScale/pinScale, so the tick's un-blocked
       sum reads in newtons. Off (byte-null) until bow_poly_jt_set_couple. */
    st->jtCplScale = kc_dup_d(cplScale, njt);
    st->jtCplLast = (double *)calloc(njt, sizeof(double));
    st->jtCplG = 0.0; st->jtCplCur = 0.0; st->jtCplOn = 0;
    st->jtCplHold = 0.0; st->jtCplOut = 0.0;
    st->jtCplW = 0; st->jtCplR = 0;
    st->jtCplA = kc_onepole_tau_sr(0.040, st->sr);
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
        st->jtCapTRel = kc_onepole_dt(dtj, 0.150);
        st->jtCapAtk = kc_onepole_dt(dtj, 0.003);
        st->jtCapRel = kc_onepole_dt(dtj, 0.120);
        st->jtCapVRel = kc_onepole_tau_sr(1.2, st->sr);
        st->jtDnA = kc_onepole_dt(dtj, 0.350);
        st->jtDnAAtk = kc_onepole_dt(dtj, 0.150);
        st->jtDnBDec = exp(-dtj / 0.500);
        st->jtDnALp = 1.0 - exp(-2.0 * 3.14159265358979 * 1600.0 * dtj);
        st->jtDnALp2 = 1.0 - exp(-2.0 * 3.14159265358979 * 25.0 * dtj);
        /* recruitment weights: all-ones (byte-null until the setter
           first arms jtDwOn) */
        st->jtDwOn = 0;
        st->jtDwA = kc_onepole_dt(dtj, 0.030);
        st->jtDwTgt = (double *)malloc(sizeof(double) * (size_t)njt);
        st->jtDwCur = (double *)malloc(sizeof(double) * (size_t)njt);
        /* evolution register offsets: zeros (byte-null until the
           setter first arms jtEvOfsOn) */
        st->jtEvOfsOn = 0;
        st->jtEvOfsA = kc_onepole_dt(dtj, 0.040);
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
        st->jtGMulA = kc_onepole_tau_sr(0.030, st->sr);
        st->jtGMulTgt = 1.0;
        st->jtGMulCur = 1.0;
        /* jt body radiation: off (byte-null until the setter arms) */
        st->jtBodyOn = 0;
        st->jtBodyA = kc_onepole_tau_sr(0.030, st->sr);
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
    st->jtEvA = kc_onepole_dt((double)st->jtDiv / st->sr, 0.040);
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
void jt_track_retune(bow_poly_state_t *st)
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
            && st->jtDnTgt[s] == 0.0) {
            /* TWO-WAY COUPLING: never STEP the returned load when a row
               falls asleep — fade the last value on the DC blocker's rate
               (see jtCplLast). The radiated output still truncates to 0;
               only the bridge return is continuous. The fade runs whether
               or not coupling is armed, so a later arm never finds a stale
               load parked on a sleeping row. */
            if (st->jtCplLast[s] != 0.0) {
                double c = st->jtCplLast[s] * (1.0 - st->jtRadA);
                if (c < 1e-30 && c > -1e-30) c = 0.0;
                st->jtCplLast[s] = c;
                if (cplOut) *cplOut += c;
            }
            return 0.0;
        }
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
                x = kc_xorshift64(x);
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
        kc_zone(Ms, J, phiU, q, p, u, ud);
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
                kc_zone(Ms, J, phiU, q, p, u, ud);
                jt_core(Ms, J, u, ud, phiF, bc_, G4_, gd4_,
                        kcR, alphaR, hcBR, dt4, q, p, &fsum);
            }
            fsum *= 0.25f;   /* mean over the substeps */
        } else {
            jt_core(Ms, J, u, ud, phiF, bc_, G_, gd_,
                    kcR, alphaR, hcBR, dtj, q, p, &fsum);
        }
        {
            /* the fitted 0.90 L drive tap — the ONE drive shape */
            const double *pd_ = st->jtPhiD + mo;
            for (int k = 0; k < Ms; k++) p[k] += dtj * Fd * pd_[k];
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
        double lp = st->jtRadLp[s];
        if (st->jtRadPrime[s]) { lp = fr; st->jtRadPrime[s] = 0; }
        lp += st->jtRadA * (fr - lp);
        st->jtRadLp[s] = lp;
        double yjt = fr - lp;
        /* TWO-WAY COUPLING pickup: the row's own bridge force in newtons,
           taken from the DC-BLOCKED load (the same `fr − lp` the radiation
           uses) and before the output cap (a radiation-side gain, not
           physics). The un-blocked load carries the row's STATIC WRAP
           preload as a DC term, so returning it would park a constant force
           on the played strings' bridge — a resting web must return ~0. */
        if (cplOut) {
            const double c = st->jtCplScale[s] * yjt;
            st->jtCplLast[s] = c;
            *cplOut += c;
        }
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

/* sideOut (nullable): accumulates the pan-weighted row sum for the stereo side
   path */
double jt_tick(bow_poly_state_t *st, double Fd, double ev,
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

void jt_pool_stop(bow_poly_state_t *st)
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

/* The gate's per-row wake bound, evaluated on the drive tap `phiD`: the
   drive that could ring the low modes back to the floor within ~one mode-1
   period (|p| ≈ π·Fd·phiD/wd1) — conservative. */
void jt_gate_eps(bow_poly_state_t *st, double refDisp)
{
    for (int s = 0; s < st->njt; s++) {
        const int mo = st->jtMOff[s];
        const double wd1 = st->jtWd[mo];
        double pdm = 0.0;
        for (int k = 0; k < st->jtM[s]; k++) {
            const double t = fabs(st->jtPhiD[mo + k]);
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

/* Overwrite the MODAL-JAWARI tables in place; the modal STATE is kept (the
   web relaxing to the new wrap IS the correct transient). Refuses when the
   shape moved. Mirrors bow_poly_jt_load's conversions. */
int bow_poly_jt_set_coeffs(void *vst, int njt, int J, const int *M,
              const double *ca, const double *cb,
              const double *ca4, const double *cb4, const double *wd,
              const double *radScale, const double *pinScale,
              const double *cplScale,
              const double *phiD,
              const double *phiU, const double *phiF,
              const double *b, const double *G, const double *G4,
              const double *gd, const double *gd4, const double *phys)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || njt != st->njt || J != st->jtJ || njt <= 0) return 0;
    if (!M || !ca || !cb || !ca4 || !cb4 || !wd || !radScale || !pinScale
        || !cplScale
        || !phiD || !phiU || !phiF || !b || !G || !G4 || !gd || !gd4
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

/* run one drive job to a web-signal buffer: schedule + pool (blocking is
   fine — this is the DISPATCHER thread) + hold walk. Same numerics as the
   sync post-pass. */
void jt_run_job_locked(bow_poly_state_t *st, const double *drv,
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
void jt_run_job(bow_poly_state_t *st, const double *drv,
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
    st->jtTrkSlew = kc_onepole_dt((double)st->jtTrkIval * dtj, 0.015);
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
    if (atkSec > 0.0) st->jtDnAAtk = kc_onepole_dt(dtj, atkSec);
    if (relSec > 0.0) st->jtDnA = kc_onepole_dt(dtj, relSec);
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
