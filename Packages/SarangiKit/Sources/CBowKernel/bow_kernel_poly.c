/* THE STRING KERNEL's played strings, body and render loop; the taraf
   half is bow_jt.c and the shared state bow_poly_internal.h. */
#include "bow_poly_internal.h"

/* Mount a fresh string. */
static void poly_mount_string(bow_poly_state_t *st, bow_pstring_t *S)
{
    memset(S, 0, sizeof(*S));
    /* finger-noise RNG: deterministic per slot (renders reproduce) */
    S->slRng = 0x9E3779B97F4A7C15ULL
        ^ ((unsigned long long)(S - st->strs) + 1ULL) * 0xBF58476D1CE4E5B9ULL;
}

/* Adopt the per-sample scalars onto a live state: plain scalar writes with
   the three guarded defaults. Shared by bow_poly_init and
   bow_poly_set_scalars so the two can never drift. Every field is always
   present. Does NOT touch hpG — that is an init-time derivation. */
static void poly_load_scalars(bow_poly_state_t *st, const bow_scalars_t *s)
{
    st->yinf = s->yinf; st->c0 = s->c0; st->dcRho = s->dcRho;
    st->pgain = s->pgain; st->pA = s->pA; st->bowW = s->bowW;
    st->kret = s->kret;
    st->retA = s->retA; st->retMode = s->retMode; st->rb0 = s->rb0;
    st->ra1 = s->ra1; st->ra2 = s->ra2; st->kdisp = s->kdisp;
    st->bowWidth = s->bowWidth; st->bowCont = s->bowCont;
    st->Z = s->Z; st->Zt = s->Zt;
    st->mu_s = s->mu_s; st->mu_d = s->mu_d; st->v0f = s->v0f;
    st->nutA = s->nutA; st->brA = s->brA;
    st->thLeak = s->thLeak; st->thA = s->thA; st->thD = s->thD;
    st->thFloor = s->thFloor;
    st->bowDisp = s->bowDisp; st->zload = s->zload;
    st->nA = s->nA; st->nT = s->nT; st->nPow = s->nPow;
    st->nzHi = s->nzHi; st->nzLo = s->nzLo; st->nDir = s->nDir;
    st->nzHiD = s->nzHiD;
    st->gutG = s->gutG; st->dispN = s->dispN; st->nailK = s->nailK;
    st->f0Open = s->f0Open; st->gutA2 = s->gutA2;
    st->torsRatio = s->torsRatio; st->torsG = s->torsG; st->torsC = s->torsC;
    st->v0Pow = s->v0Pow; st->v0Ref = s->v0Ref;
    st->hairHz = s->hairHz;
    st->hairRef = (s->hairRef > 1e-6 ? s->hairRef : 1.0);
    st->lossReg = s->lossReg;
    st->slideRate = (s->slideRate > 1.0 ? s->slideRate : 900.0);
    st->slideDull = s->slideDull;
    st->slideNoise = s->slideNoise;
    st->slideAcc = (s->slideAcc > 1.0 ? s->slideAcc : 25000.0);
    /* the per-sample constants the string loop reads */
    const double sr = st->sr;
    st->nutFc0 = -log(st->nutA) * sr / 6.283185307179586;
    st->kgAtk = kc_pole_tau_sr(0.003, sr);
    st->kgRel = kc_pole_tau_sr(0.008, sr);
    st->slCD = kc_onepole_tau_sr(0.010, sr);
    st->slAtk = kc_pole_tau_sr(0.015, sr);
    st->slRel = kc_pole_tau_sr(0.120, sr);
    st->slAAtk = kc_pole_tau_sr(0.010, sr);
    st->slARel = kc_pole_tau_sr(0.100, sr);
    static const double hl[3] = {0.92, 1.0, 1.09};
    for (int i = 0; i < 3; i++) st->thLeakPow[i] = pow(st->thLeak, hl[i]);
}

void *bow_poly_init(int nb, double sr,
                    int K, const double *ba1, const double *ba2,
                    const double *bn0, const double *bA, const double *bC,
                    const bow_scalars_t *s)
{
    bow_poly_state_t *st = (bow_poly_state_t *)calloc(1, sizeof(bow_poly_state_t));
    st->sr = sr;
    st->nb = nb < 1 ? 1 : (nb > 64 ? 64 : nb);   /* chunk scratch is [64] */
    st->K = K > 96 ? 96 : K;
    st->ba1 = kc_dup_d(ba1, K);   st->ba2 = kc_dup_d(ba2, K);
    st->bn0 = kc_dup_d(bn0, K);   st->bA = kc_dup_d(bA, K);
    st->bC = kc_dup_d(bC, K);
    poly_load_scalars(st, s);
    st->hpG = 0.5 * (1.0 + s->dcRho);
    st->lcg = 0x9E3779B97F4A7C15ULL;
    st->strs = (bow_pstring_t *)calloc(st->nb, sizeof(bow_pstring_t));
    for (int b = 0; b < st->nb; b++) poly_mount_string(st, &st->strs[b]);
    st->proc = (int *)malloc(sizeof(int) * st->nb);
    return (void *)st;
}

/* Regime tracker (telemetry, never feeds the audio): TPT state-variable
   band-passes at h*f0, h = 1..4 (g ~ pi*h*f0/sr, k = 1/Q, Q = 3, unity
   peak) on the bridge-side wave, and the leaky powers over ~4 periods. */
static inline void rg_track(bow_pstring_t *S, double x, double f0t, double sr)
{
    const double f = fmax(f0t, 40.0);
    const double k = 1.0 / 3.0;
    const double c = f / (4.0 * sr);   /* 1 - a, ~4 periods */
    for (int h = 0; h < 4; h++) {
        double g = 3.141592653589793 * f * (double)(h + 1) / sr;
        if (g > 1.0) g = 1.0;
        const double a1 = 1.0 / (1.0 + g * (g + k));
        const double a2 = g * a1;
        const double a3 = g * a2;
        const double v3 = x - S->rgIc2[h];
        const double v1 = a1 * S->rgIc1[h] + a2 * v3;
        const double v2 = S->rgIc2[h] + a2 * S->rgIc1[h] + a3 * v3;
        S->rgIc1[h] = 2.0 * v1 - S->rgIc1[h];
        S->rgIc2[h] = 2.0 * v2 - S->rgIc2[h];
        const double band = k * v1;
        S->rgP[h] += c * (band * band - S->rgP[h]);
    }
    S->rgPtot += c * (x * x - S->rgPtot);
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
    const double nutFc0 = st->nutFc0;

    double F = 0.0;
    double o2 = 0.0;
    int bowOn = bowW > 1e-9;
    double bowForce = fbt * gatet;
    double kga = bowForce > S->kGate ? st->kgAtk : st->kgRel;
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
            nutAf = kc_pole_hz(fcn, sr);
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
                    const double cD = st->slCD;
                    double slDp = S->slD;
                    S->slD += cD * (d - S->slD);
                    double r = 1731.234 * sr * fabs(S->slD);
                    double tgt = r < 80.0
                        ? 0.0 : r / (r + st->slideRate);
                    double a = tgt > S->slEnv ? st->slAtk : st->slRel;
                    S->slEnv = (1.0 - a) * tgt + a * S->slEnv;
                    if (st->slideNoise > 1e-12) {
                        S->slA += cD * ((S->slD - slDp) - S->slA);
                        double acc = 1731.234 * sr * sr * fabs(S->slA);
                        double tgtA = acc < 6000.0
                            ? 0.0 : acc / (acc + st->slideAcc);
                        double aA = tgtA > S->slEnvA ? st->slAAtk : st->slARel;
                        S->slEnvA = (1.0 - aA) * tgtA + aA * S->slEnvA;
                    }
                }
            }
            S->slF = f0t; S->slFValid = 1;
            if (st->slideNoise > 1e-12 && S->slEnvA > 1e-6) {
                S->slRng = kc_xorshift64(S->slRng);
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
        /* LOOP LENGTH = ONE PERIOD. The nut-side read cannot go under 2
           samples; once beta*T is shorter than the hair ribbon (+2) that
           floor would lengthen the round trip and the top of the range
           goes flat, so the excess comes off the bridge-side read instead
           (the bridge segment always has the room). Exact 0 below the
           corner: the reads are bit-identical there. */
        double nutNom = betat * T - bowWidth;
        double nutD = fmax(2.0, nutNom);
        double nutExcess = nutD - nutNom;
        double h1 = pfrac_read(S->buf1, MAXBOW, S->w1i, nutD);
        double dl = kdisp * st->disp;
        if (dl > 0.02) dl = 0.02; else if (dl < -0.02) dl = -0.02;
        double h2 = pfrac_read(S->buf2, MAXBOW, S->w2i,
                               fmax(2.0, ((1.0 - betat) * T - bowWidth
                                          - nutExcess) * (1.0 + dl)));
        double hBA = 0, hAB = 0;
        if (bowCont >= 2.5 && bowWidth >= 2.0) {
            /* three hair-group contacts, own friction solve per group */
            static const double hs2[3] = {0.88, 1.0, 1.12};
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
                    double lk = st->thLeakPow[g];
                    S->Tr3[g] = lk * S->Tr3[g]
                        + (1.0 - lk) * fabs(Ffg * dvh);
                    if (g == 0) {
                        int slip = fabs(stickF) > mSg * FbT;
                        if (slip && !S->rgSlipping) S->rgSlips++;
                        S->rgSlipping = slip;
                        S->rgSlipSmp += (unsigned long long)slip;
                        S->rgSmp++;
                        S->rgPeriods += f0t / sr;
                    }
                }
                if (hairHz > 1e-6) {
                    double fcH = hairHz * fmax(FbT * 3.0, 0.02) / hairRef;
                    if (fcH > 0.45 * sr) fcH = 0.45 * sr;
                    double aH = kc_pole_hz(fcH, sr);
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
                {
                    int slip = fabs(stickF) > muS * Fb;
                    if (slip && !S->rgSlipping) S->rgSlips++;
                    S->rgSlipping = slip;
                    S->rgSlipSmp += (unsigned long long)slip;
                    S->rgSmp++;
                    S->rgPeriods += f0t / sr;
                }
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
                double aH = kc_pole_hz(fcH, sr);
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
                double FbN = pow(Fb, nPow);
                Ff += (nA * FbN + nT * S->tEnv) * slipg
                    * (S->nz1 - S->nz2);
                *noiseDirAcc += nDir * FbN * slipg
                    * (S->nz2b - S->nz2);
            }
            {
                double dvh = (vh - vbt) + Ff / (2.0 * (Z / (1.0 + Z / Zt)));
                double P = fabs(Ff * dvh);
                for (int hgi = 0; hgi < 3; hgi++) {
                    double lk = st->thLeakPow[hgi];
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
        rg_track(S, S->brLp, f0t, sr);
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
    st->stWidthSl = kc_onepole_tau_sr(0.030, st->sr);
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

/* Per played-string REGIME read: out = {slip onsets, periods elapsed,
   samples in slip, bowed samples, fundamental share, fundamental
   dominance}; the first four are cumulative since the mount (the host
   diffs two reads), the last two are ~4-period running values. Racy
   telemetry. Returns 0 for a bad slot. */
int bow_poly_regime_slot(void *vst, int b, double out[6])
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || !st->strs || b < 0 || b >= st->nb) return 0;
    const bow_pstring_t *S = &st->strs[b];
    out[0] = (double)S->rgSlips;
    out[1] = S->rgPeriods;
    out[2] = (double)S->rgSlipSmp;
    out[3] = (double)S->rgSmp;
    out[4] = S->rgPtot > 1e-20 ? S->rgP[0] / S->rgPtot : 0.0;
    double hi = S->rgP[1];
    if (S->rgP[2] > hi) hi = S->rgP[2];
    if (S->rgP[3] > hi) hi = S->rgP[3];
    out[5] = hi > 1e-20 ? S->rgP[0] / hi : (S->rgP[0] > 1e-20 ? 10.0 : 0.0);
    return 1;
}

/* LIVE PARAMETERS: replace the per-sample scalars on a live state (the
   same derivations bow_poly_init applies); tables and all running state are
   left alone. Plain scalar writes. */
void bow_poly_set_scalars(void *vst, const bow_scalars_t *s)
{
    bow_poly_state_t *st = (bow_poly_state_t *)vst;
    if (!st || !s) return;
    poly_load_scalars(st, s);
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
            /* Coalesce short device callbacks into >=512-kernel-sample jobs
               for the experimental solver. A partial unpublished slot is
               exclusively producer-owned. Flush it before an oversized next
               chunk so no write can cross the ring-slot boundary. */
            if (st->jtDualPending && st->jtDualPending+n > JT_ABLK) {
                int w = st->jtDJobW;
                st->jtDJobN[w & (JT_ARING-1)] = st->jtDualPending;
                __atomic_store_n(&st->jtDJobW,w+1,__ATOMIC_RELEASE);
                st->jtDualPending = 0;
            }
            int wj = st->jtDJobW;
            int rj = __atomic_load_n(&st->jtDJobR, __ATOMIC_ACQUIRE);
            if (wj - rj < JT_ARING) {
                jtFr = st->jtDrvRing
                    + (size_t)(wj & (JT_ARING - 1)) * JT_ABLK + st->jtDualPending;
                jtCv = st->jtCapRing
                    + (size_t)(wj & (JT_ARING - 1)) * JT_ABLK + st->jtDualPending;
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
            int count = n + st->jtDualPending;
            /* A bank amortizes eight worker wakeups over 512 output frames;
               the one-row diagnostic retains its original 256-frame jobs. */
            if (st->jtDual && count < (st->jtDualCount > 1 ? 1024 : 512)) st->jtDualPending = count;
            else {
                int wj = st->jtDJobW;
                st->jtDJobN[wj & (JT_ARING - 1)] = count;
                __atomic_store_n(&st->jtDJobW, wj + 1, __ATOMIC_RELEASE);
                st->jtDualPending = 0;
                if (pthread_mutex_trylock(&st->jtMx) == 0) {
                    pthread_cond_broadcast(&st->jtCvW);
                    pthread_mutex_unlock(&st->jtMx);
                }
            }
        }
        long long ww = __atomic_load_n(&st->jtWebW, __ATOMIC_ACQUIRE);
        long long rr = st->jtWebR;
        int avail = (int)(ww - rr);
        int take = avail < n ? avail : n;
        /* Variable Newton cost plus worker wake jitter needs a reserve.
           Prime six worker jobs: 32 ms for one physical row, 64 ms for a
           full physical bank. This is a taraf-audio delay only; mechanical
           return is separate and the physical timestep is unchanged. */
        if (st->jtDual && !st->jtDualReady) {
            const int reserve = st->jtDualCount > 1 ? 6144 : 3072;
            if (avail >= (n > reserve ? n : reserve)) st->jtDualReady = 1;
            else take = 0;
        }
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
                    const double d = jt_drive_step(st);
                    const double dn = jt_drive_norm(st, d);
                    st->jtHold = jt_tick(st, st->jtFprev * d,
                                         jt_ev_step(st), cap, dn,
                                         jt_drive_comp_step(st, dn,
                                                            st->jtFprev),
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
        free(st->jtFrBuf); free(st->jtFdv); free(st->jtDnV); free(st->jtCmV); free(st->jtTkv);
        free(st->jtEvV);
        free(st->jtHp); free(st->jtHpS); free(st->jtHpC);
        free(st->jtWebScr); free(st->jtWebScrS);
        free(st->sjRing);
        free(st->jtDrvRing); free(st->jtWebRing);
        free(st->jtWebRingS);
        free(st->jtM); free(st->jtMOff); free(st->jtZOff);
        free(st->jtCa); free(st->jtCb); free(st->jtCa4); free(st->jtCb4);
        free(st->jtWd); free(st->jtWdI);
        free(st->jtPhiD);
        free(st->jtPhiU); free(st->jtPhiF); free(st->jtB);
        free(st->jtG); free(st->jtG4); free(st->jtGd); free(st->jtGd4);
        free(st->jtQ); free(st->jtP);
        free(st->jtDnTgt); free(st->jtDnEnv); free(st->jtDnBoost);
        free(st->jtDnLp); free(st->jtDnLp2); free(st->jtDnRng);
        free(st->jtDnPh);
        free(st->jtPulseRequest); free(st->jtPulseEnv); free(st->jtPulseLift);
        free(st->jtPulseDecay); free(st->jtPulseAttack); free(st->jtPulseLeft);
        free(st->jtBurstRequest); free(st->jtBurstEnv); free(st->jtBurstDecay);
        free(st->jtBurstPhase); free(st->jtBurstLeft);
        free(st->jtProfileTgt); free(st->jtProfileCur);
        free(st->jtOutputLevelTgt); free(st->jtOutputLevelCur);
        free(st->jtCapEnv); free(st->jtCapGain); free(st->jtCapRowGen);
        free(st->jtCapV); free(st->jtCapBuf); free(st->jtCapRing);
        free(st->scopeEnv); free(st->scopeMode); free(st->scopeCnt);
        free(st->jtRadScale); free(st->jtRadScaleCur); free(st->jtRadLp);
        free(st->jtRadPinScale); free(st->jtRadPinScaleCur);
        if(st->jtDual) {
            for(int row=0;row<st->njt;row++)jt_dual_free(st->jtDual[row]);
            free(st->jtDual);
        }
        free(st->jtCplScale); free(st->jtCplRing); free(st->jtCplLast);
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
