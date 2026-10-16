#ifndef BOW_COMPRESSOR_H
#define BOW_COMPRESSOR_H

/* Allocation-free chromatic radiation compressor; all state is render-owned.
   Thresholds use kernel-bus amplitude, before calibration/master gain and FX. */
typedef struct {
    double ratio, voiceRatio, floor;
    double envelope, reductionDB;
    double detectorRelease, attack, release;
} bow_chromatic_compressor_t;

void bow_chromatic_compressor_init(bow_chromatic_compressor_t *state, double sr);
void bow_chromatic_compressor_set(bow_chromatic_compressor_t *state,
                                 double ratio, double voiceRatio, double floorDB);
/* One linked gain for mid/side; voiceEnvelope is the recent played-voice peak. */
double bow_chromatic_compressor_gain(bow_chromatic_compressor_t *state,
                                    double mid, double side, double voiceEnvelope);

#endif
