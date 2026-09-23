#ifndef BOW_TONAL_H
#define BOW_TONAL_H
/* Worker-owned, allocation-free spectral radiation filter, fixed 96 kHz.
   Peaks must lie near integer multiples of fundamental_hz.
   Selectivity 0 allows wider harmonic bands; 1 requires stronger, narrower peaks.
   Latency is 2048–16384 samples, sized for >=8 FFT bins per harmonic spacing.
   fundamental_hz must be >=70 and <48000. 20 kHz is exact delayed bypass. */
void *bow_tonal_create(double fundamental_hz);
void bow_tonal_destroy(void *state);
int bow_tonal_latency(void *state);
double bow_tonal_tick(void *state, double sample, double cutoff_hz, double selectivity);
#endif
