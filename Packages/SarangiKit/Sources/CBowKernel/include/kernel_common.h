/* Helpers both kernels use. Every function here is a fixed expression:
   a caller that spells the same law gets the same bits, so the render
   hashes hold. */
#ifndef KERNEL_COMMON_H
#define KERNEL_COMMON_H

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* One-pole coefficients. `kc_pole_*` is the feedback pole a (y += (1-a)x
   + a y); `kc_onepole_*` is the increment coefficient c = 1 - a. */
static inline double kc_pole_hz(double hz, double sr)
{
    return exp(-6.283185307179586 * hz / sr);
}
static inline double kc_pole_tau_sr(double tau, double sr)
{
    return exp(-1.0 / (tau * sr));
}
static inline double kc_onepole_tau_sr(double tau, double sr)
{
    return 1.0 - exp(-1.0 / (tau * sr));
}
static inline double kc_onepole_dt(double dt, double tau)
{
    return 1.0 - exp(-dt / tau);
}

/* xorshift64 step; the caller keeps the state and its own normalisation. */
static inline unsigned long long kc_xorshift64(unsigned long long x)
{
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

/* Zone evaluation: the modal state (double) projected onto the J contact
   points through the float32 shape matrix Phi (M×J, row-major). Each
   output accumulates over k in order, so the float rounding is fixed. */
static inline void kc_zone(int M, int J, const float *Phi,
                           const double *q, const double *p,
                           float *u, float *ud)
{
    for (int j = 0; j < J; j++) { u[j] = 0.0f; ud[j] = 0.0f; }
    for (int k = 0; k < M; k++) {
        const float *Pr = Phi + (size_t)k * J;
        const float qk = (float)q[k], pk = (float)p[k];
        int j = 0;
        for (; j + 3 < J; j += 4) {
            u[j] += Pr[j] * qk;     ud[j] += Pr[j] * pk;
            u[j+1] += Pr[j+1] * qk; ud[j+1] += Pr[j+1] * pk;
            u[j+2] += Pr[j+2] * qk; ud[j+2] += Pr[j+2] * pk;
            u[j+3] += Pr[j+3] * qk; ud[j+3] += Pr[j+3] * pk;
        }
        for (; j < J; j++) { u[j] += Pr[j] * qk; ud[j] += Pr[j] * pk; }
    }
}
/* displacement only — the per-sample hot matvec */
static inline void kc_zone_u(int M, int J, const float *Phi,
                             const double *q, float *u)
{
    for (int j = 0; j < J; j++) u[j] = 0.0f;
    for (int k = 0; k < M; k++) {
        const float *Pr = Phi + (size_t)k * J;
        const float qk = (float)q[k];
        int j = 0;
        for (; j + 3 < J; j += 4) {
            u[j] += Pr[j] * qk;
            u[j+1] += Pr[j+1] * qk;
            u[j+2] += Pr[j+2] * qk;
            u[j+3] += Pr[j+3] * qk;
        }
        for (; j < J; j++) u[j] += Pr[j] * qk;
    }
}

/* Owned copies of a table (the load ABI hands the kernel borrowed
   pointers). n == 0 still yields a valid allocation. */
static inline double *kc_dup_d(const double *a, size_t n)
{
    double *b = (double *)malloc(sizeof(double) * (n > 0 ? n : 1));
    if (n > 0) memcpy(b, a, sizeof(double) * n);
    return b;
}
static inline float *kc_dup_f(const double *a, size_t n)
{
    float *o = (float *)malloc(sizeof(float) * (n > 0 ? n : 1));
    for (size_t i = 0; i < n; i++) o[i] = (float)a[i];
    return o;
}

#endif
