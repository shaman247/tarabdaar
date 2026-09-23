#ifndef BOW_RADIATION_H
#define BOW_RADIATION_H

/* Full FIR convolution, with no added latency or allocations in tick. */
void *bow_radiation_create(const double *coefficients, int count);
double bow_radiation_tick(void *state, double input);
void bow_radiation_destroy(void *state);

#endif
